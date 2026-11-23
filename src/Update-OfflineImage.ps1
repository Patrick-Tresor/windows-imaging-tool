<#
.SYNOPSIS
    Applies Windows updates (.msu or .cab) to a captured golden image, offline, without a recapture.
.DESCRIPTION
    Runs on the admin PC (elevated, Windows 10/11 or Server with DISM). The console's
    Images > Update image... button runs it hidden, with its steps as a card in the Progress window (-ProgressFile).

    For each edition (index) in the image it mounts the image, adds the packages in the
    order given, optionally cleans up the component store, and commits. The serviced image
    is then exported to a new file, which drops the space left behind by the replaced
    components, and replaces the original. The previous version is always moved to
    Images\Previous\ (a version the Versions window can roll back to).

    The work happens in a local folder (-WorkDir), because mounting from a share is slow and
    a mount must be on a local NTFS volume. It needs about three times the image size free.

    -LatestUpdate first finds the newest cumulative update for the image's Windows version in the Microsoft Update
    Catalog and downloads it into the content root's Updates folder (src/UpdateCatalog.psm1). The catalog has no
    API, so this can break when Microsoft changes its pages: the error then says to download the .msu by hand.

    Order matters: a standalone servicing stack update (SSU) goes before the cumulative
    update, and the .NET cumulative update after it. Windows 11 24H2 "checkpoint" updates
    must all be in the same folder: DISM finds the earlier checkpoint next to the later one.
.EXAMPLE
    .\src\Update-OfflineImage.ps1 -ImagePath D:\DeployShare\Images\Win11-24H2-Enterprise.wim `
        -PackagePath D:\DeployShare\Updates\windows11.0-kb5044284-x64.msu -Cleanup
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImagePath,
    [string[]]$PackagePath = @(),                     # applied in this order, after -LatestUpdate's
    [switch]$LatestUpdate,                            # download the newest cumulative update first
    [int[]]$Index,                                    # default: every edition in the image
    [switch]$Cleanup,                                 # DISM /StartComponentCleanup after the updates
    [switch]$ResetBase,                               # with -Cleanup: smaller, but the updates can no longer be removed
    [int]$SplitSizeMB = 3800,                         # part size when the image is split (.swm)
    [string]$WorkDir = (Join-Path $env:ProgramData 'ImagingConsole\Servicing'),
    [switch]$NoPrompt,
    [string]$ProgressFile,                            # step-by-step progress for the console's Progress window
    [string]$LogPath                                  # default: Update-OfflineImage.log in -WorkDir
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Console\ConsoleData.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UpdateCatalog.psm1') -Force
if (-not $LatestUpdate -and -not $PackagePath) { throw 'Give -PackagePath, -LatestUpdate or both.' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (DISM needs administrator rights).' }

# DISM exit code for a package that does not apply to this image (wrong version, or already superseded).
$notApplicable = @(-2146498530, 2148468766)   # 0x800F081E
$rebootRequired = 3010

$image = Get-Item -LiteralPath $ImagePath
$name = $image.BaseName
$imagesDir = $image.DirectoryName
$isSplit = $image.Extension -eq '.swm'
# An .esd (Smallest compression) cannot be mounted: it is exported to a .wim to service, and back to .esd at the end.
$isEsd = $image.Extension -eq '.esd'
$parts = if ($isSplit) { @(Get-ChildItem -LiteralPath $imagesDir -Filter "$name*.swm" | Where-Object { $_.BaseName -match "^$([regex]::Escape($name))\d*$" }) } else { @($image) }

# Logs go to the content root's Logs folder when the image is in <root>\Images, so the console shows them.
$contentRoot = Split-Path $imagesDir -Parent
$logDir = if ((Split-Path $imagesDir -Leaf) -eq 'Images' -and (Test-Path (Join-Path $contentRoot 'Logs'))) { Join-Path $contentRoot 'Logs' } else { $WorkDir }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$logPath = if ($LogPath) { $LogPath } else { Join-Path $WorkDir 'Update-OfflineImage.log' }
Set-DeployLogPath -Path $logPath -New
$steps = @()
if ($LatestUpdate) { $steps += , @('download', 'Downloading the latest cumulative update') }
Start-BuildProgress -Path $ProgressFile -Title "Updating $($image.Name)" -LogPath $logPath -Steps (@($steps) + @(
    @('copy', 'Copying the image to the work folder'), @('update', 'Adding the updates'),
    @('export', 'Exporting the updated image'), @('save', 'Saving it in Images')))

$mountDir = Join-Path $WorkDir 'Mount'
$scratchDir = Join-Path $WorkDir 'Scratch'
$sourceWim = Join-Path $WorkDir 'source.wim'
$outWim = Join-Path $WorkDir 'serviced.wim'
$mounted = $false
$backup = $null
$swapping = $false
$status = 'FAILED'
$results = @()

try {
    if ($LatestUpdate) {
        # Before anything is copied: when the catalog fails, the image is not touched.
        Start-BuildStep 'download'
        $build = (Get-WindowsImage -ImagePath $image.FullName -Index (@(Get-WindowsImage -ImagePath $image.FullName)[0].ImageIndex)).Version
        $updatesDir = if ((Split-Path $imagesDir -Leaf) -eq 'Images') { Join-Path $contentRoot 'Updates' } else { Join-Path $WorkDir 'Updates' }
        try {
            $latest = Save-LatestCumulativeUpdate -Build $build -Folder $updatesDir -OnFile {
                param($FileName, $Number, $Count)
                Write-DeployLog "Downloading $FileName ($Number of $Count)"
                Set-BuildStepProgress 'download' -Percent (100 * ($Number - 1) / $Count) -Detail $FileName
            }
        } catch {
            $why = "$($_.Exception.Message) Put its .msu from the Microsoft Update Catalog in $updatesDir and pick it in Update image."
            if (-not $PackagePath) { throw $why }
            Write-DeployLog $why -Level WARN
            $latest = $null
        }
        if ($latest) {
            Write-DeployLog "Latest cumulative update for build ${build}: $($latest.Title)"
            # The downloaded files go first; a package chosen by hand that is the same file is not added twice.
            $PackagePath = @($latest.Files) + @($PackagePath | Where-Object { [IO.Path]::GetFileName($_) -notin @($latest.Files | ForEach-Object { [IO.Path]::GetFileName($_) }) })
            Complete-BuildStep 'download' -Detail $latest.Kb
        } else {
            Complete-BuildStep 'download' -State failed -Detail 'Not downloaded, only the chosen packages are added'
        }
    }

    $packages = foreach ($p in $PackagePath) {
        $f = Get-Item -LiteralPath $p
        if ($f.Extension -notin '.msu', '.cab') { throw "$($f.Name) is not an .msu or .cab update package." }
        $f
    }

    # A previous run that crashed can leave a mount behind; DISM refuses to mount over it.
    Invoke-Native dism.exe -NoThrow -ArgumentList @('/Cleanup-Mountpoints') | Out-Null
    if (Test-Path $mountDir) {
        if (@(Get-ChildItem -LiteralPath $mountDir -Force).Count) {
            Invoke-Native dism.exe -NoThrow -ArgumentList @('/Unmount-Image', "/MountDir:$mountDir", '/Discard') | Out-Null
        }
        Remove-Item -LiteralPath $mountDir -Recurse -Force
    }
    Remove-Item -LiteralPath $sourceWim, $outWim -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $mountDir, $scratchDir -Force | Out-Null

    $imageBytes = ($parts | Measure-Object Length -Sum).Sum
    $drive = Get-PSDrive -Name (Split-Path $WorkDir -Qualifier).TrimEnd(':')
    if ($drive.Free -lt ($imageBytes * 3 + 10GB)) {
        throw ('{0} has {1:N0} GB free; servicing this {2:N1} GB image needs about {3:N0} GB. Use -WorkDir on a bigger drive.' -f `
            $drive.Root, ($drive.Free / 1GB), ($imageBytes / 1GB), (($imageBytes * 3 + 10GB) / 1GB))
    }

    # Work on a local single-file copy. Split images are joined back into one .wim first.
    Write-DeployLog "Copying $($image.Name) to $WorkDir"
    Start-BuildStep 'copy' -Detail $WorkDir
    if ($isSplit) {
        $swmPattern = Join-Path $imagesDir "$name*.swm"
        foreach ($i in (Get-WindowsImage -ImagePath $image.FullName).ImageIndex) {
            Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Export-Image', "/SourceImageFile:$($image.FullName)", "/SWMFile:$swmPattern",
                "/SourceIndex:$i", "/DestinationImageFile:$sourceWim", '/Compress:max', '/CheckIntegrity')
        }
    } elseif ($isEsd) {
        foreach ($i in (Get-WindowsImage -ImagePath $image.FullName).ImageIndex) {
            Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Export-Image', "/SourceImageFile:$($image.FullName)", "/SourceIndex:$i",
                "/DestinationImageFile:$sourceWim", '/Compress:max', '/CheckIntegrity')
        }
    } else {
        Copy-Item -LiteralPath $image.FullName -Destination $sourceWim
    }
    Set-ItemProperty -LiteralPath $sourceWim -Name IsReadOnly -Value $false
    Complete-BuildStep 'copy'

    $editions = @(Get-WindowsImage -ImagePath $sourceWim)
    $targets = if ($Index) { @($editions | Where-Object ImageIndex -in $Index) } else { $editions }
    if (-not $targets) { throw "Index $($Index -join ', ') is not in $($image.Name)." }

    Write-DeployLog ("Updating {0} ({1}) with: {2}" -f $image.Name, (($targets | ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" }) -join '; '), ($packages.Name -join ', '))
    if (-not $NoPrompt -and (Read-Host 'Type YES to start') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }

    Start-BuildStep 'update'
    $done = 0
    foreach ($t in $targets) {
        Set-BuildStepProgress 'update' -Percent (100 * $done / $targets.Count) -Detail "Edition $($t.ImageIndex): $($t.ImageName)"
        $before = (Get-WindowsImage -ImagePath $sourceWim -Index $t.ImageIndex).Version
        Write-DeployLog "Mounting index $($t.ImageIndex) ($($t.ImageName), build $before)"
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Mount-Image', "/ImageFile:$sourceWim", "/Index:$($t.ImageIndex)", "/MountDir:$mountDir")
        $mounted = $true

        foreach ($pkg in $packages) {
            $code = Invoke-Native dism.exe -NoThrow -ArgumentList @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($pkg.FullName)", "/ScratchDir:$scratchDir")
            $result = if ($code -eq 0 -or $code -eq $rebootRequired) { 'Installed' }
                      elseif ($code -in $notApplicable) { 'Not applicable' }
                      else { throw ("Adding {0} to index {1} failed with DISM code 0x{2:X8}. See {3}." -f $pkg.Name, $t.ImageIndex, $code, $logPath) }
            $level = if ($result -eq 'Installed') { 'INFO' } else { 'WARN' }
            Write-DeployLog "$($pkg.Name): $result" -Level $level
            $results += [pscustomobject]@{ index = $t.ImageIndex; package = $pkg.Name; result = $result }
        }

        if ($Cleanup) {
            $cleanupArgs = @("/Image:$mountDir", '/Cleanup-Image', '/StartComponentCleanup', "/ScratchDir:$scratchDir")
            if ($ResetBase) { $cleanupArgs += '/ResetBase' }
            Invoke-Native -FilePath 'dism.exe' -ArgumentList $cleanupArgs
        }

        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Unmount-Image', "/MountDir:$mountDir", '/Commit')
        $mounted = $false
        $after = (Get-WindowsImage -ImagePath $sourceWim -Index $t.ImageIndex).Version
        Write-DeployLog "Index $($t.ImageIndex): build $before -> $after"
        $done++
    }
    Complete-BuildStep 'update' -Detail ('{0} installed, {1} not applicable' -f @($results | Where-Object result -eq 'Installed').Count, @($results | Where-Object result -ne 'Installed').Count)

    # Exporting every edition to a fresh file drops the replaced components still stored in the old one.
    Start-BuildStep 'export'
    foreach ($e in $editions) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Export-Image', "/SourceImageFile:$sourceWim", "/SourceIndex:$($e.ImageIndex)",
            "/DestinationImageFile:$outWim", '/Compress:max', '/CheckIntegrity')
    }
    if (@(Get-WindowsImage -ImagePath $outWim).Count -ne $editions.Count) { throw 'The exported image is missing editions; the original was left unchanged.' }
    $builds = @(Get-WindowsImage -ImagePath $outWim | ForEach-Object { (Get-WindowsImage -ImagePath $outWim -Index $_.ImageIndex).Version } | Select-Object -Unique)
    $outFile = $outWim
    if ($isEsd) {
        Write-DeployLog 'Compressing the updated image back to .esd (Smallest)'
        $outFile = Convert-ImageToEsd -WimPath $outWim
    }

    Complete-BuildStep 'export' -Detail "build $($builds -join ', ')"
    Start-BuildStep 'save' -Detail $imagesDir
    $swapping = $true
    # Archived as a version (with version.json), so the Versions dialog shows why and with what.
    $kept = Save-ImageVersion -ImagePath $image.FullName -Move -Reason 'Replaced by an offline update' -Note ($packages.Name -join ', ')
    $backup = $kept.Folder
    Write-DeployLog "Moved the previous version to $backup"

    if ($isSplit) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Split-Image', "/ImageFile:$outWim", "/SWMFile:$(Join-Path $imagesDir "$name.swm")", "/FileSize:$SplitSizeMB")
    } else {
        Write-DeployLog "Copying the updated image to $imagesDir"
        Copy-Item -LiteralPath $outFile -Destination (Join-Path $imagesDir $image.Name)
    }

    Add-ImageServicingRecord -ImagePath (Join-Path $imagesDir $image.Name) -Results $results `
        -Builds $builds `
        -Cleanup:$Cleanup -ResetBase:$ResetBase
    Write-DeployLog "Updated $($image.Name). Answer files that use it get the updates on the next deploy."
    Complete-BuildStep 'save' -Detail $(if ($backup) { 'Previous version kept' } else { '' })
    Stop-BuildProgress
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    Stop-BuildProgress -Message $_.Exception.Message
    if ($mounted) { Invoke-Native dism.exe -NoThrow -ArgumentList @('/Unmount-Image', "/MountDir:$mountDir", '/Discard') | Out-Null }
    if (-not $swapping) { Write-DeployLog 'The original image was not changed.' -Level WARN }
    elseif ($backup) { Write-DeployLog "Failed while replacing the image. The previous version is in $backup; move it back to $imagesDir." -Level WARN }
}
finally {
    Remove-Item -LiteralPath $sourceWim, $outWim, ([IO.Path]::ChangeExtension($outWim, '.esd')), $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($status -ne 'CANCELLED') {
        Copy-Item $logPath (Join-Path $logDir ("SERVICE-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
