# What a USB stick's DEPLOY partition needs so it deploys offline: the chosen answer files, the image each one
# names (its pinned version when it has one), the drivers, applications and BIOS tools they use, and config.
# Used by New-DeploymentMedia.ps1 and the console's Media tab. PowerShell 5.1 compatible.

Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1')
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1')

function Join-MediaPath {
    # Content paths use backslashes (they are read in WinPE); normalize so the module also runs in tests off Windows.
    param([string]$Root, [string]$Child)
    Join-Path $Root ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
}

function ConvertTo-MediaRelative([string]$Path) {
    ($Path -replace '/', '\') -replace '^\\+|\\+$', ''
}

function Split-MediaPath([string]$Path) {
    # Folder and base name of a content path with backslashes, the same on Windows and in tests off Windows.
    $rel = ConvertTo-MediaRelative $Path
    $dir = ''
    $leaf = $rel
    if ($rel -match '^(.*)\\([^\\]*)$') { $dir = $Matches[1]; $leaf = $Matches[2] }
    $base = $leaf -replace '\.[^.]*$', ''
    if (-not $base) { $base = $leaf }
    New-Object PSObject -Property @{ Dir = $dir; Base = $base }
}

function Join-MediaRelative([string[]]$Parts) {
    @($Parts | Where-Object { $_ }) -join '\'
}

function Test-MediaRooted([string]$Path) {
    # Y:\... or \\server\... (read at deploy time), also when the tests run off Windows.
    [IO.Path]::IsPathRooted($Path) -or $Path -match '^([A-Za-z]:|\\\\)'
}

function Test-MediaWithin([string]$Path, [string[]]$Folders) {
    # True when $Path is inside one of $Folders (not equal to it).
    foreach ($f in $Folders) { if ($Path.StartsWith("$f\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

function Get-MediaAnswerFileNames {
    param([Parameter(Mandatory)][string]$ContentRoot)
    @(Get-ChildItem -Path (Join-MediaPath $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object BaseName)
}

function Get-MediaContent {
    <#
    .SYNOPSIS
        The folders and files to copy from a content root to a USB stick for the given answer files (all of them
        when none are named). Problems are things that would make the stick fail at deploy time; the build stops
        on them before the stick is erased. Paths in Folders and Files are relative to the content root.
    #>
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [string[]]$AnswerFiles,
        [string]$DefaultAnswerFile
    )
    $all = Get-MediaAnswerFileNames -ContentRoot $ContentRoot
    $names = @(if ($AnswerFiles) { $AnswerFiles } else { $all })
    # Plain arrays: everything is added with +=, and paths are deduplicated at the end.
    $folders = @(); $files = @(); $problems = @(); $notes = @(); $rows = @()

    if (-not $all) { $problems += "There are no answer files in $ContentRoot\AnswerFiles. Create one on the Answer Files tab: it says which image the stick deploys." }
    elseif (-not $names) { $problems += 'Choose at least one answer file to put on the USB stick.' }

    # Always: settings, driver catalog, naming list, password files, and the BIOS tools.
    foreach ($dir in 'config', 'Tools') { if (Test-Path (Join-MediaPath $ContentRoot $dir)) { $folders += $dir } }

    foreach ($name in $names) {
        $path = Join-MediaPath $ContentRoot "AnswerFiles\$name.xml"
        if (-not (Test-Path $path)) { $problems += "Answer file $name is not in $ContentRoot\AnswerFiles."; continue }
        $files += "AnswerFiles\$name.xml"
        $a = $null
        try { $a = Read-AnswerFile -Path $path -SkipValidation } catch { $problems += "Answer file $name can't be read: $($_.Exception.Message)" }
        if (-not $a) { continue }

        $image = "$($a.ImageFile)"
        $size = [int64]0
        if (-not $image) { $problems += "Answer file $name names no image. Choose one on its Image page." }
        elseif (Test-MediaRooted $image) {
            $notes += "Answer file $name reads its image from $image, which is not copied: the PC needs that path at deploy time."
        } else {
            $current = Join-MediaPath $ContentRoot $image
            $sp = Split-MediaPath $image
            if ($a.ImageVersion) {
                # A pinned answer file deploys the copy in Images\Previous\<name>_<version>; copy that whole folder.
                $pinned = $null
                try { $pinned = Get-ImageVersionPath -ImagePath $current -Version $a.ImageVersion }
                catch { $problems += "Answer file $name uses image $image version $($a.ImageVersion): $($_.Exception.Message)" }
                if ($pinned) {
                    $folders += Join-MediaRelative $sp.Dir, 'Previous', "$($sp.Base)_$($a.ImageVersion)"
                    $size = [int64](Get-ImagePartFiles -ImagePath $pinned | Measure-Object Length -Sum).Sum
                }
            } else {
                $parts = @(Get-ImagePartFiles -ImagePath $current)
                if (-not $parts) { $problems += "Answer file $name uses image $image, which is not in $ContentRoot. Capture it or pick another image on the answer file's Image page." }
                foreach ($part in $parts) { $files += Join-MediaRelative $sp.Dir, $part.Name }
                if (Test-Path (Join-Path (Split-Path $current -Parent) "$($sp.Base).updates.json")) {
                    $files += Join-MediaRelative $sp.Dir, "$($sp.Base).updates.json"
                }
                if ($parts) { $size = [int64]($parts | Measure-Object Length -Sum).Sum }
            }
        }
        $rows += [pscustomobject]@{ Name = $name; Image = $image; Version = $a.ImageVersion; Size = $size }

        # The deploy wizard offers every application in the library, so copy the whole folder, not only this file's.
        foreach ($dir in @($a.DriverRoot, $a.AppLocation, $a.Bios.ToolsRoot)) {
            if (-not $dir) { continue }
            if (Test-MediaRooted $dir) { $notes += "Answer file $name reads $dir at deploy time; it is not copied."; continue }
            if (Test-Path (Join-MediaPath $ContentRoot $dir)) { $folders += $dir }
        }
    }

    # Same path once, in the order first seen; a folder already copied whole covers the files and folders inside it.
    $folders = @($folders | ForEach-Object { ConvertTo-MediaRelative $_ } | Where-Object { $_ } | Select-Object -Unique)
    $files = @($files | ForEach-Object { ConvertTo-MediaRelative $_ } | Where-Object { $_ } | Select-Object -Unique)
    $outer = $folders
    $folders = @($folders | Where-Object { -not (Test-MediaWithin $_ $outer) })
    $files = @($files | Where-Object { -not (Test-MediaWithin $_ $outer) })

    if ($DefaultAnswerFile -and $names -and $DefaultAnswerFile -notin $names) {
        $notes += "The default answer file $DefaultAnswerFile is not on this stick, so the deploy wizard asks which one to use."
    }
    [pscustomobject]@{
        AnswerFiles = $rows
        Folders     = $folders
        Files       = $files
        Problems    = $problems
        Notes       = $notes
    }
}

function Get-MediaAnswerChoices {
    # One row per answer file for the Media tab's list: name, the image it deploys, and that image's size.
    param([Parameter(Mandatory)][string]$ContentRoot)
    foreach ($name in Get-MediaAnswerFileNames -ContentRoot $ContentRoot) {
        $c = Get-MediaContent -ContentRoot $ContentRoot -AnswerFiles $name
        $r = $c.AnswerFiles | Select-Object -First 1
        $image = if (-not $r) { '(unreadable)' } elseif (-not $r.Image) { '(no image)' } elseif ($r.Version) { "$($r.Image) version $($r.Version)" } else { $r.Image }
        $size = if ($r -and $r.Size) { ' ({0:N1} GB)' -f ($r.Size / 1GB) } else { '' }
        $state = if ($c.Problems) { "  - $($c.Problems[0])" } else { '' }
        [pscustomobject]@{ Name = $name; Label = "$name  ->  $image$size$state"; Ready = -not $c.Problems }
    }
}

Export-ModuleMember -Function Get-MediaAnswerFileNames, Get-MediaContent, Get-MediaAnswerChoices
