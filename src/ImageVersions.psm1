# Image versions: earlier copies of a golden image kept in Images\Previous\<name>_<yyyyMMdd-HHmm>\, so a bad
# capture or update can be rolled back and an answer file can stay on a known-good version.
# Used by Capture-VMImage.ps1, by Deploy-Image.ps1 in WinPE and by the admin console. PowerShell 5.1 compatible.
#
# A version folder holds the image's parts with their original names, the image's <name>.updates.json when it
# had one, and version.json (archived date, reason, note). Update-OfflineImage.ps1 (offline updates) moves the
# old image to the same place, so its backups show up as versions too, just without version.json.

Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1')
Import-Module (Join-Path $PSScriptRoot 'JsonFile.psm1')

$script:StampFormat = 'yyyyMMdd-HHmm'
$script:VersionPattern = '^\d{8}-\d{4}(-\d+)?$'

function Test-ImageVersionName {
    # A version is the folder's time stamp, e.g. 20261022-1530 (or 20261022-1530-2 for a second one that minute).
    param([string]$Version)
    $Version -match $script:VersionPattern
}

function Get-ExistingImageFiles {
    # The image files named -Name in -ImagesDir, whatever their kind: Name.wim, Name.esd (Smallest compression) or
    # the first part of a split image, Name.swm.
    param([Parameter(Mandatory)][string]$ImagesDir, [Parameter(Mandatory)][string]$Name)
    @(foreach ($ext in '.wim', '.esd', '.swm') {
        $p = [IO.Path]::Combine($ImagesDir, "$Name$ext")
        if ([IO.File]::Exists($p)) { $p }
    })
}

function Get-ImageFileExtension {
    # The extension a capture ends up with: .esd with the Smallest (recovery) compression, else .wim.
    # Captures are no longer split (the stick and the share are NTFS); older split images (.swm) still deploy.
    param([string]$Compression)
    if ($Compression -eq 'recovery') { '.esd' } else { '.wim' }
}

function Get-CaptureImageArgs {
    # DISM's /Capture-Image arguments for Capture-VMImage.ps1. Smallest (recovery) captures with max first:
    # DISM cannot capture to recovery directly, Convert-ImageToEsd recompresses it after.
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][string]$CaptureDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$Compression = 'max',
        [string]$Description
    )
    $a = @('/Capture-Image', "/ImageFile:$WimPath", "/CaptureDir:$CaptureDir", "/Name:$Name",
        "/Compress:$(if ($Compression -eq 'recovery') { 'max' } else { $Compression })", '/CheckIntegrity')
    if ($Description) { $a += "/Description:$Description" }
    $a
}

function Convert-ImageToEsd {
    <#
    .SYNOPSIS
        Recompresses a captured .wim into Name.esd with DISM's recovery compression (about a quarter smaller than
        Maximum, so less to copy to a stick; the capture takes longer and applying it a bit longer). Deletes the .wim.
    .DESCRIPTION
        Needs DeployCommon.psm1 (Invoke-Native / Invoke-NativeWithProgress) imported by the caller. Returns the .esd path.
    #>
    param([Parameter(Mandatory)][string]$WimPath, [scriptblock]$OnProgress)
    $esd = [IO.Path]::ChangeExtension($WimPath, '.esd')
    if ([IO.File]::Exists($esd)) { [IO.File]::Delete($esd) }
    $count = 1
    if (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue) {
        try { $count = @(Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop).Count } catch { $count = 1 }
    }
    for ($i = 1; $i -le [Math]::Max(1, $count); $i++) {
        $exportArgs = @('/Export-Image', "/SourceImageFile:$WimPath", "/SourceIndex:$i", "/DestinationImageFile:$esd", '/Compress:recovery', '/CheckIntegrity')
        if ($OnProgress) { Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList $exportArgs -OnProgress $OnProgress }
        else { Invoke-Native -FilePath 'dism.exe' -ArgumentList $exportArgs }
    }
    [IO.File]::Delete($WimPath)
    $esd
}

function Get-ImagePartFiles {
    # The files that make up an image: the .wim, or every part of a split image (Name.swm, Name2.swm, ...).
    param([Parameter(Mandatory)][string]$ImagePath)
    $dir = Split-Path $ImagePath -Parent
    $leaf = Split-Path $ImagePath -Leaf
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    if ($leaf -like '*.swm') {
        $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
        @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -eq '.swm' -and $_.BaseName -match "^$([regex]::Escape($base))\d*$" } | Sort-Object Name)
    } else {
        @(Get-ChildItem -LiteralPath $dir -File | Where-Object Name -eq $leaf)
    }
}

function Get-ImageSidecarFiles {
    # Files next to the image that describe it and travel with it between versions.
    param([Parameter(Mandatory)][string]$ImagePath)
    $dir = Split-Path $ImagePath -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($ImagePath)
    @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object Name -eq "$base.updates.json")
}

function Get-ImageVersionFolder {
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][string]$Version)
    $base = [IO.Path]::GetFileNameWithoutExtension($ImagePath)
    Join-Path (Join-Path (Split-Path $ImagePath -Parent) 'Previous') "$($base)_$Version"
}

function Get-ImageVersions {
    <#
    .SYNOPSIS
        The archived versions of an image, newest first. Folders without the image file in them are skipped.
    #>
    param([Parameter(Mandatory)][string]$ImagePath)
    $previous = Join-Path (Split-Path $ImagePath -Parent) 'Previous'
    if (-not (Test-Path -LiteralPath $previous)) { return @() }
    $leaf = Split-Path $ImagePath -Leaf
    $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
    $versions = foreach ($d in Get-ChildItem -LiteralPath $previous -Directory) {
        if ($d.Name -notmatch "^$([regex]::Escape($base))_(\d{8}-\d{4}(-\d+)?)$") { continue }
        $version = $Matches[1]
        $first = Join-Path $d.FullName $leaf
        if (-not (Test-Path -LiteralPath $first)) { continue }
        $info = $null
        $infoPath = Join-Path $d.FullName 'version.json'
        if (Test-Path -LiteralPath $infoPath) { try { $info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json } catch { } }
        $archived = [datetime]::ParseExact($version.Substring(0, 13), $script:StampFormat, [Globalization.CultureInfo]::InvariantCulture)
        $parts = @(Get-ImagePartFiles -ImagePath $first)
        [pscustomobject]@{
            Version   = $version
            Archived  = $archived
            Reason    = if ($info -and $info.reason) { $info.reason } else { 'Kept by an offline update' }
            Note      = if ($info -and $info.note) { $info.note } else { '' }
            SizeGB    = [Math]::Round((($parts | Measure-Object Length -Sum).Sum) / 1GB, 2)
            ImagePath = $first
            Folder    = $d.FullName
        }
    }
    @($versions | Sort-Object Archived, Version -Descending)
}

function Get-ImageVersionUsage {
    # Version -> names of the answer files deploying it, for one image. '' is the current image.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ImageName)
    Get-AnswerFileUsage -ContentRoot $ContentRoot -Keys {
        param($a) if ((Split-Path ($a.ImageFile -replace '\\', '/') -Leaf) -eq $ImageName) { "$($a.ImageVersion)" }
    }.GetNewClosure()
}

function Get-VersionsToKeep {
    # How many earlier versions to keep of each image: versionsToKeep in deploy-settings.json, else 0 (keep all).
    # One number for every image, set in the Versions window. (An older per-image Images\<name>.versions.json is
    # no longer read.)
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$ImagePath)
    $settingsPath = Join-Path (Join-Path $ContentRoot 'config') 'deploy-settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return 0 }
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    if ($settings.PSObject.Properties['versionsToKeep']) { [int]$settings.versionsToKeep } else { 0 }
}

function Set-VersionsToKeep {
    # Saves the one keep count for every image in deploy-settings.json (0 keeps every version).
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][int]$Keep)
    if ($Keep -lt 0) { throw 'Keep must be 0 or more.' }
    $settingsPath = Join-Path (Join-Path $ContentRoot 'config') 'deploy-settings.json'
    $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json } else { [pscustomobject]@{} }
    $settings | Add-Member -NotePropertyName versionsToKeep -NotePropertyValue $Keep -Force
    Save-JsonFile -Path $settingsPath -InputObject $settings -Depth 6
}

function Invoke-ImageVersionRetention {
    # Deletes the oldest unpinned versions beyond the newest N (N from Get-VersionsToKeep unless -Keep is given).
    # Versions an answer file is pinned to, and -Protect (e.g. the version just rolled back to), are never deleted.
    # Returns the versions deleted.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ImagePath, [int]$Keep = -1, [string[]]$Protect = @())
    if ($Keep -lt 0) { $Keep = Get-VersionsToKeep -ContentRoot $ContentRoot -ImagePath $ImagePath }
    if ($Keep -le 0) { return @() }
    $pinned = @((Get-ImageVersionUsage -ContentRoot $ContentRoot -ImageName (Split-Path $ImagePath -Leaf)).Keys) + $Protect
    $old = @(Get-ImageVersionsToPrune -ImagePath $ImagePath -Keep $Keep -Pinned $pinned)
    foreach ($v in $old) { Remove-ImageVersion -ImagePath $ImagePath -Version $v.Version }
    $old
}

function Test-ImageHardLinks {
    # True when the folder's volume can make hard links, so a rollback links the image instead of copying it.
    param([Parameter(Mandatory)][string]$Path)
    $a = Join-Path $Path ('.linktest-' + [guid]::NewGuid().ToString('N'))
    $b = "$a-link"
    try {
        Set-Content -LiteralPath $a -Value 'x'
        New-Item -ItemType HardLink -Path $b -Target $a -ErrorAction Stop | Out-Null
        $true
    }
    catch { $false }
    finally { Remove-Item -LiteralPath $a, $b -Force -ErrorAction SilentlyContinue }
}

function Get-ImageVersionPath {
    # Path of an archived version's image file, for Deploy-Image.ps1. Empty version = the current image.
    param([Parameter(Mandatory)][string]$ImagePath, [string]$Version)
    if (-not $Version) { return $ImagePath }
    if (-not (Test-ImageVersionName $Version)) { throw "'$Version' is not an image version (expected a time stamp like 20261022-1530)." }
    $path = Join-Path (Get-ImageVersionFolder -ImagePath $ImagePath -Version $Version) (Split-Path $ImagePath -Leaf)
    if (-not (Test-Path -LiteralPath $path)) { throw "Version $Version of $(Split-Path $ImagePath -Leaf) is not in $(Split-Path $ImagePath -Parent)\Previous." }
    $path
}

function Save-ImageVersion {
    <#
    .SYNOPSIS
        Archives the current image as a version. -Move empties the current slot (before a recapture or rollback);
        otherwise the image is copied, as a snapshot. Returns the new version.
    #>
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [string]$Reason = 'Kept a copy',
        [string]$Note,
        [switch]$Move,
        [datetime]$Date = (Get-Date)
    )
    $parts = @(Get-ImagePartFiles -ImagePath $ImagePath)
    if (-not $parts) { throw "Image not found: $ImagePath" }

    $stamp = $Date.ToString($script:StampFormat, [Globalization.CultureInfo]::InvariantCulture)
    $version = $stamp
    $n = 1
    while (Test-Path -LiteralPath (Get-ImageVersionFolder -ImagePath $ImagePath -Version $version)) { $n++; $version = "$stamp-$n" }
    $folder = Get-ImageVersionFolder -ImagePath $ImagePath -Version $version
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    $moved = @()
    try {
        foreach ($f in $parts) {
            if ($Move) { Move-Item -LiteralPath $f.FullName -Destination $folder; $moved += $f }
            else { Copy-Item -LiteralPath $f.FullName -Destination $folder }
        }
        # The update history is copied, not moved: it stays with the image slot and the version gets a snapshot.
        foreach ($f in Get-ImageSidecarFiles -ImagePath $ImagePath) { Copy-Item -LiteralPath $f.FullName -Destination $folder }
    } catch {
        # Put back the parts that were moved, and drop the half-made version.
        foreach ($f in $moved) { Move-Item -LiteralPath (Join-Path $folder $f.Name) -Destination (Split-Path $ImagePath -Parent) -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Save-JsonFile -Path (Join-Path $folder 'version.json') -InputObject ([pscustomobject]@{ image = (Split-Path $ImagePath -Leaf)
        archived = $Date.ToString('yyyy-MM-dd HH:mm'); reason = $Reason; note = "$Note" })
    Get-ImageVersions -ImagePath $ImagePath | Where-Object Version -eq $version
}

function Set-ImageVersionNote {
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][string]$Version, [AllowEmptyString()][string]$Note)
    $v = Get-ImageVersions -ImagePath $ImagePath | Where-Object Version -eq $Version
    if (-not $v) { throw "Version $Version of $(Split-Path $ImagePath -Leaf) was not found." }
    Save-JsonFile -Path (Join-Path $v.Folder 'version.json') -InputObject ([pscustomobject]@{ image = (Split-Path $ImagePath -Leaf)
        archived = $v.Archived.ToString('yyyy-MM-dd HH:mm'); reason = $v.Reason; note = "$Note" })
}

function Set-ImageFileLink {
    # Makes Destination the same file as Source when the volume allows a hard link, else a copy. A rollback then takes
    # no time and no extra space. Nothing writes an image file in place (captures, updates and rollbacks all write new
    # files), so the two names can share the data safely. Don't add an in-place writer for the current image.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    try { New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null }
    catch { Copy-Item -LiteralPath $Source -Destination $Destination -Force }
}

function Restore-ImageVersion {
    <#
    .SYNOPSIS
        Rolls an image back: the current image becomes a new version, then the chosen version becomes current again (linked, not copied).
        The chosen version stays archived, so answer files pinned to it keep working. Returns the version that now
        holds the image that was current.
    #>
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][string]$Version, [datetime]$Date = (Get-Date))
    $source = Get-ImageVersionPath -ImagePath $ImagePath -Version $Version
    $dir = Split-Path $ImagePath -Parent
    $sourceParts = @(Get-ImagePartFiles -ImagePath $source)
    $sourceSidecars = @(Get-ImageSidecarFiles -ImagePath $source)

    $archived = $null
    if (@(Get-ImagePartFiles -ImagePath $ImagePath).Count) {
        $archived = Save-ImageVersion -ImagePath $ImagePath -Move -Date $Date -Reason "Replaced by a rollback to $Version"
    } else {
        Get-ImageSidecarFiles -ImagePath $ImagePath | Remove-Item -Force
    }
    try {
        # The image files are linked. The update history is copied, because it is rewritten in place after a rollback.
        foreach ($f in $sourceParts) { Set-ImageFileLink -Source $f.FullName -Destination (Join-Path $dir $f.Name) }
        foreach ($f in $sourceSidecars) { Copy-Item -LiteralPath $f.FullName -Destination $dir -Force }
    } catch {
        # Undo: drop the partial copy and put the image that was current back.
        foreach ($f in $sourceParts + $sourceSidecars) { Remove-Item -LiteralPath (Join-Path $dir $f.Name) -Force -ErrorAction SilentlyContinue }
        if ($archived) {
            $archivedImage = Join-Path $archived.Folder (Split-Path $ImagePath -Leaf)
            foreach ($f in Get-ImagePartFiles -ImagePath $archivedImage) { Move-Item -LiteralPath $f.FullName -Destination $dir -Force }
            foreach ($f in Get-ImageSidecarFiles -ImagePath $archivedImage) { Copy-Item -LiteralPath $f.FullName -Destination $dir -Force }
            Remove-Item -LiteralPath $archived.Folder -Recurse -Force
        }
        throw
    }
    $archived
}

function Remove-ImageVersion {
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][string]$Version)
    $v = Get-ImageVersions -ImagePath $ImagePath | Where-Object Version -eq $Version
    if (-not $v) { throw "Version $Version of $(Split-Path $ImagePath -Leaf) was not found." }
    Remove-Item -LiteralPath $v.Folder -Recurse -Force
}

function Get-ImageVersionsToPrune {
    # Versions beyond the newest -Keep, leaving out the ones answer files are pinned to.
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][int]$Keep, [string[]]$Pinned = @())
    if ($Keep -lt 0) { throw 'Keep must be 0 or more.' }
    @(Get-ImageVersions -ImagePath $ImagePath | Select-Object -Skip $Keep | Where-Object { $_.Version -notin $Pinned })
}

function Publish-CapturedImage {
    <#
    .SYNOPSIS
        After a capture into -Staging: keeps the image it replaces (-Existing) as a version, moves the new files into
        -ImagesDir and applies the image's keep limit. Returns the new file name (Name.wim, Name.esd or Name.swm).
    .DESCRIPTION
        Used by Capture-VMImage.ps1, which imports DeployCommon.psm1 for Write-DeployLog.
        $State.Swapping turns true once the old image starts moving: from then on the staging folder may hold the
        only copy of the new capture, so the caller must not delete it.
    #>
    param(
        [Parameter(Mandatory)][string]$Staging,
        [Parameter(Mandatory)][string]$ImagesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$Compression,
        [string[]]$Existing,
        [string]$ContentRoot,
        [Parameter(Mandatory)][hashtable]$State
    )
    if ($Existing) {
        $State.Swapping = $true
        foreach ($old in $Existing) {
            $v = Save-ImageVersion -ImagePath $old -Move -Reason 'Replaced by a new capture'
            Write-DeployLog "Kept the previous $(Split-Path $old -Leaf) as version $($v.Version)"
        }
    }
    if ($Staging -ne $ImagesDir) {
        Get-ChildItem -LiteralPath $Staging -File | Move-Item -Destination $ImagesDir
        Remove-Item -LiteralPath $Staging -Recurse -Force
    }
    $newLeaf = $Name + (Get-ImageFileExtension -Compression $Compression)
    if ($Existing) {
        if ($Existing | Where-Object { (Split-Path $_ -Leaf) -ne $newLeaf }) {
            Write-DeployLog "The new version is $newLeaf but the old one was $(($Existing | ForEach-Object { Split-Path $_ -Leaf }) -join ', '). Point answer files at Images\$newLeaf." -Level WARN
        }
        if ($ContentRoot) {
            try {
                $pruned = @(Invoke-ImageVersionRetention -ContentRoot $ContentRoot -ImagePath (Join-Path $ImagesDir $newLeaf))
                if ($pruned) { Write-DeployLog "Deleted older versions beyond the keep limit: $(($pruned.Version) -join ', ')" }
            } catch { Write-DeployLog "Could not apply the keep limit: $($_.Exception.Message)" -Level WARN }
        }
    }
    $newLeaf
}

Export-ModuleMember -Function Get-ExistingImageFiles, Get-ImageFileExtension, Get-CaptureImageArgs, Convert-ImageToEsd, Publish-CapturedImage, Test-ImageVersionName, Get-ImagePartFiles, Get-ImageVersions, Get-ImageVersionPath,
    Save-ImageVersion, Set-ImageVersionNote, Restore-ImageVersion, Remove-ImageVersion, Get-ImageVersionsToPrune,
    Get-ImageVersionUsage, Get-VersionsToKeep, Set-VersionsToKeep, Invoke-ImageVersionRetention,
    Test-ImageHardLinks
