# Image versions: earlier copies of a golden image kept in Images\Previous\<name>_<yyyyMMdd-HHmm>\, so a bad
# capture or update can be rolled back and an answer file can stay on a known-good version.
# Used by Capture-GoldenImage.ps1 and Deploy-Image.ps1 in WinPE and by the admin console. PowerShell 5.1 compatible.
#
# A version folder holds the image's parts with their original names, the image's <name>.updates.json when it
# had one, and version.json (archived date, reason, note). Update-OfflineImage.ps1 (offline updates) moves the
# old image to the same place, so its backups show up as versions too, just without version.json.

Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1')

$script:StampFormat = 'yyyyMMdd-HHmm'
$script:VersionPattern = '^\d{8}-\d{4}(-\d+)?$'

function Test-ImageVersionName {
    # A version is the folder's time stamp, e.g. 20261022-1530 (or 20261022-1530-2 for a second one that minute).
    param([string]$Version)
    $Version -match $script:VersionPattern
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
    $usage = @{}
    foreach ($f in Get-ChildItem -Path (Join-Path $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
        try { $a = Read-AnswerFile -Path $f.FullName -SkipValidation } catch { continue }
        if ((Split-Path ($a.ImageFile -replace '\\', '/') -Leaf) -ne $ImageName) { continue }
        $key = "$($a.ImageVersion)"
        if (-not $usage.ContainsKey($key)) { $usage[$key] = @() }
        $usage[$key] += $f.BaseName
    }
    $usage
}

function Get-ImageVersionLimitPath {
    # Images\<name>.versions.json: the image's own "keep newest N" limit. Not a version, so Get-ImageList ignores it.
    param([Parameter(Mandatory)][string]$ImagePath)
    Join-Path (Split-Path $ImagePath -Parent) ([IO.Path]::GetFileNameWithoutExtension($ImagePath) + '.versions.json')
}

function Get-ImageVersionLimit {
    # The image's own limit, or $null when it uses the default from deploy-settings.json.
    param([Parameter(Mandatory)][string]$ImagePath)
    $path = Get-ImageVersionLimitPath -ImagePath $ImagePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $value = (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).keep
    if ($null -eq $value) { return $null }
    [int]$value
}

function Set-ImageVersionLimit {
    # Sets the image's own limit. With -Keep $null the image goes back to the default.
    param([Parameter(Mandatory)][string]$ImagePath, $Keep)
    $path = Get-ImageVersionLimitPath -ImagePath $ImagePath
    if ($null -eq $Keep) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return }
    if ([int]$Keep -lt 0) { throw 'Keep must be 0 or more.' }
    [pscustomobject]@{ keep = [int]$Keep } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
}

function Get-VersionsToKeep {
    # How many versions to keep for an image: its own limit, else versionsToKeep in deploy-settings.json, else 0 (keep all).
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ImagePath)
    $own = Get-ImageVersionLimit -ImagePath $ImagePath
    if ($null -ne $own) { return $own }
    $settingsPath = Join-Path (Join-Path $ContentRoot 'config') 'deploy-settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return 0 }
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    if ($settings.PSObject.Properties['versionsToKeep']) { [int]$settings.versionsToKeep } else { 0 }
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
    [pscustomobject]@{ image = (Split-Path $ImagePath -Leaf); archived = $Date.ToString('yyyy-MM-dd HH:mm'); reason = $Reason; note = "$Note" } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'version.json') -Encoding utf8
    Get-ImageVersions -ImagePath $ImagePath | Where-Object Version -eq $version
}

function Set-ImageVersionNote {
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][string]$Version, [AllowEmptyString()][string]$Note)
    $v = Get-ImageVersions -ImagePath $ImagePath | Where-Object Version -eq $Version
    if (-not $v) { throw "Version $Version of $(Split-Path $ImagePath -Leaf) was not found." }
    [pscustomobject]@{ image = (Split-Path $ImagePath -Leaf); archived = $v.Archived.ToString('yyyy-MM-dd HH:mm'); reason = $v.Reason; note = "$Note" } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $v.Folder 'version.json') -Encoding utf8
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

Export-ModuleMember -Function Test-ImageVersionName, Get-ImagePartFiles, Get-ImageVersions, Get-ImageVersionPath,
    Save-ImageVersion, Set-ImageVersionNote, Restore-ImageVersion, Remove-ImageVersion, Get-ImageVersionsToPrune,
    Get-ImageVersionUsage, Get-ImageVersionLimit, Set-ImageVersionLimit, Get-VersionsToKeep, Invoke-ImageVersionRetention,
    Test-ImageHardLinks
