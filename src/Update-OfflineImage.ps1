<#
.SYNOPSIS
    Applies Windows updates (.msu or .cab) to a captured golden image, offline, without a recapture.
.DESCRIPTION
    Runs on the admin PC (elevated, Windows 10/11 or Server with DISM). The console's
    Images > Update image... button runs it in its own window.

    For each edition (index) in the image it mounts the image, adds the packages in the
    order given, optionally cleans up the component store, and commits. The serviced image
    is then exported to a new file, which drops the space left behind by the replaced
    components, and replaces the original. The previous version is moved to
    Images\Previous\ unless -NoBackup is used.

    The work happens in a local folder (-WorkDir), because mounting from a share is slow and
    a mount must be on a local NTFS volume. It needs about three times the image size free.

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
    [Parameter(Mandatory)][string[]]$PackagePath,     # applied in this order
    [int[]]$Index,                                    # default: every edition in the image
    [switch]$Cleanup,                                 # DISM /StartComponentCleanup after the updates
    [switch]$ResetBase,                               # with -Cleanup: smaller, but the updates can no longer be removed
    [switch]$NoBackup,
    [int]$SplitSizeMB = 3800,                         # part size when the image is split (.swm)
    [string]$WorkDir = (Join-Path $env:ProgramData 'ImagingConsole\Servicing'),
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Console\ConsoleData.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force

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
$parts = if ($isSplit) { @(Get-ChildItem -LiteralPath $imagesDir -Filter "$name*.swm" | Where-Object { $_.BaseName -match "^$([regex]::Escape($name))\d*$" }) } else { @($image) }

# Logs go to the content root's Logs folder when the image is in <root>\Images, so the console shows them.
$contentRoot = Split-Path $imagesDir -Parent
$logDir = if ((Split-Path $imagesDir -Leaf) -eq 'Images' -and (Test-Path (Join-Path $contentRoot 'Logs'))) { Join-Path $contentRoot 'Logs' } else { $WorkDir }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$logPath = Join-Path $WorkDir 'Update-OfflineImage.log'
Set-Content -Path $logPath -Value $null
# DeployCommon logs to X:\ (WinPE) by default; point it at the work folder.
& (Get-Module DeployCommon) { param($p) $script:LogPath = $p } $logPath

function Invoke-Dism {
    # Like Invoke-Native, but returns the exit code so callers can accept "not applicable".
    param([string[]]$ArgumentList)
    Write-DeployLog "> dism.exe $($ArgumentList -join ' ')"
    & dism.exe @ArgumentList 2>&1 | ForEach-Object { Add-Content -Path $logPath -Value "  $_" }
    $LASTEXITCODE
}

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
    $packages = foreach ($p in $PackagePath) {
        $f = Get-Item -LiteralPath $p
        if ($f.Extension -notin '.msu', '.cab') { throw "$($f.Name) is not an .msu or .cab update package." }
        $f
    }

    # A previous run that crashed can leave a mount behind; DISM refuses to mount over it.
    Invoke-Dism @('/Cleanup-Mountpoints') | Out-Null
    if (Test-Path $mountDir) {
        if (@(Get-ChildItem -LiteralPath $mountDir -Force).Count) {
            Invoke-Dism @('/Unmount-Image', "/MountDir:$mountDir", '/Discard') | Out-Null
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
    if ($isSplit) {
        $swmPattern = Join-Path $imagesDir "$name*.swm"
        foreach ($i in (Get-WindowsImage -ImagePath $image.FullName).ImageIndex) {
            Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Export-Image', "/SourceImageFile:$($image.FullName)", "/SWMFile:$swmPattern",
                "/SourceIndex:$i", "/DestinationImageFile:$sourceWim", '/Compress:max', '/CheckIntegrity')
        }
    } else {
        Copy-Item -LiteralPath $image.FullName -Destination $sourceWim
    }
    Set-ItemProperty -LiteralPath $sourceWim -Name IsReadOnly -Value $false

    $editions = @(Get-WindowsImage -ImagePath $sourceWim)
    $targets = if ($Index) { @($editions | Where-Object ImageIndex -in $Index) } else { $editions }
    if (-not $targets) { throw "Index $($Index -join ', ') is not in $($image.Name)." }

    Write-DeployLog ("Updating {0} ({1}) with: {2}" -f $image.Name, (($targets | ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" }) -join '; '), ($packages.Name -join ', '))
    if (-not $NoPrompt -and (Read-Host 'Type YES to start') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }

    foreach ($t in $targets) {
        $before = (Get-WindowsImage -ImagePath $sourceWim -Index $t.ImageIndex).Version
        Write-DeployLog "Mounting index $($t.ImageIndex) ($($t.ImageName), build $before)"
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Mount-Image', "/ImageFile:$sourceWim", "/Index:$($t.ImageIndex)", "/MountDir:$mountDir")
        $mounted = $true

        foreach ($pkg in $packages) {
            $code = Invoke-Dism @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($pkg.FullName)", "/ScratchDir:$scratchDir")
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
    }

    # Exporting every edition to a fresh file drops the replaced components still stored in the old one.
    foreach ($e in $editions) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Export-Image', "/SourceImageFile:$sourceWim", "/SourceIndex:$($e.ImageIndex)",
            "/DestinationImageFile:$outWim", '/Compress:max', '/CheckIntegrity')
    }
    if (@(Get-WindowsImage -ImagePath $outWim).Count -ne $editions.Count) { throw 'The exported image is missing editions; the original was left unchanged.' }

    $swapping = $true
    if (-not $NoBackup) {
        # Archived as a version (with version.json), so the Versions dialog shows why and with what.
        $kept = Save-ImageVersion -ImagePath $image.FullName -Move -Reason 'Replaced by an offline update' -Note ($packages.Name -join ', ')
        $backup = $kept.Folder
        Write-DeployLog "Moved the previous version to $backup"
    } else {
        $parts | Remove-Item -Force
    }

    if ($isSplit) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Split-Image', "/ImageFile:$outWim", "/SWMFile:$(Join-Path $imagesDir "$name.swm")", "/FileSize:$SplitSizeMB")
    } else {
        Write-DeployLog "Copying the updated image to $imagesDir"
        Copy-Item -LiteralPath $outWim -Destination (Join-Path $imagesDir "$name.wim")
    }

    Add-ImageServicingRecord -ImagePath (Join-Path $imagesDir $image.Name) -Results $results `
        -Builds @(Get-WindowsImage -ImagePath $outWim | ForEach-Object { (Get-WindowsImage -ImagePath $outWim -Index $_.ImageIndex).Version } | Select-Object -Unique) `
        -Cleanup:$Cleanup -ResetBase:$ResetBase
    Write-DeployLog "Updated $($image.Name). Answer files that use it get the updates on the next deploy."
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    if ($mounted) { Invoke-Dism @('/Unmount-Image', "/MountDir:$mountDir", '/Discard') | Out-Null }
    if (-not $swapping) { Write-DeployLog 'The original image was not changed.' -Level WARN }
    elseif ($backup) { Write-DeployLog "Failed while replacing the image. The previous version is in $backup; move it back to $imagesDir." -Level WARN }
}
finally {
    Remove-Item -LiteralPath $sourceWim, $outWim, $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($status -ne 'CANCELLED') {
        Copy-Item $logPath (Join-Path $logDir ("SERVICE-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
