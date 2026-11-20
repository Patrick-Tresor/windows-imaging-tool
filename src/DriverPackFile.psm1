# Driver packs as one file each on the USB stick. A model's driver pack is thousands of small files (.inf, .sys,
# .cat), and a USB stick writes small files far slower than one big file: Patrick's stick copied 12 GB of drivers
# (4,573 files) at a few MB/s. The build packs each catalog driver folder into one .wim (Windows' own archive
# format, which DISM in WinPE unpacks without any extra tool), cached on the console PC so it is packed only once;
# the deploy unpacks the chosen pack onto the new Windows partition and adds the drivers from there.
# Drivers\_WinPE stays plain files: WinPE loads those itself at start. PowerShell 5.1 compatible.

# Bump when how a pack file is made changes, so old cached files are not reused.
$script:DriverPackFileFormat = 1

function Get-DriverPackFolders {
    <#
    .SYNOPSIS
        The driver pack folders of a copy plan that go on the stick as one file: every catalog path (entries and
        maker fallbacks) under each driver root, relative to the content root, that has files in the plan.
        A catalog path inside another one (or holding one) stays plain files, so no file is packed twice.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$CatalogPath,
        [string[]]$DriverRoots = @('Drivers')
    )
    if (-not (Test-Path -LiteralPath $CatalogPath)) { return @() }
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $paths = @(@($catalog.entries | ForEach-Object { $_.path }) +
        @(if ($catalog.fallbacks) { $catalog.fallbacks.PSObject.Properties | ForEach-Object { $_.Value } }) |
        Where-Object { $_ } | ForEach-Object { "$_".Replace('/', '\').Trim('\') } | Where-Object { $_ })
    $candidates = @(foreach ($root in @($DriverRoots | Where-Object { $_ } | ForEach-Object { "$_".Replace('/', '\').Trim('\') } | Select-Object -Unique)) {
        foreach ($p in $paths) {
            $dir = "$root\$p"
            if ($p -ieq '_WinPE' -or $p.StartsWith('_WinPE\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $dir
        }
    })
    $candidates = @($candidates | Sort-Object -Unique)
    $prefix = { param($a, $b) $a.StartsWith("$b\", [StringComparison]::OrdinalIgnoreCase) }
    @(foreach ($dir in $candidates) {
        $nested = @($candidates | Where-Object { $_ -ine $dir -and ((& $prefix $_ $dir) -or (& $prefix $dir $_)) })
        if ($nested) { continue }
        $has = @($Plan.Items | Where-Object { & $prefix $_.Relative $dir } | Select-Object -First 1)
        if ($has) { $dir }
    })
}

function Get-DriverPackFileKey {
    # Changes when any file in the pack changes (name, size or modified time), so a changed pack is packed again.
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$Folder)
    $lines = @("format $script:DriverPackFileFormat") + @($Items | Sort-Object Relative | ForEach-Object {
        '{0}|{1}|{2}' -f $_.Relative.Substring($Folder.Length + 1).ToLowerInvariant(), $_.Length, [IO.File]::GetLastWriteTimeUtc($_.Source).Ticks
    })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))) } finally { $sha.Dispose() }
    (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 24)
}

function New-DriverPackWim {
    # Packs Folder into one .wim with DISM (LZX: driver files shrink by about half, and the stick is the slow part).
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Destination, [string]$Name = 'Drivers')
    $out = & dism.exe /English /Capture-Image "/ImageFile:$Destination" "/CaptureDir:$($Folder.TrimEnd('\'))" "/Name:$Name" /Compress:max 2>&1
    if ($LASTEXITCODE -ne 0) {
        $last = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -Last 1
        throw "DISM could not pack $Folder (exit code $LASTEXITCODE): $last"
    }
}

function ConvertTo-PackedDriverPlan {
    <#
    .SYNOPSIS
        Replaces the files of each driver pack folder in a copy plan (Get-MediaCopyPlan) with one file
        <folder>.wim, made in CacheRoot (or reused from it), and drops those folders from Directories so the stick
        has only the .wim. Returns the new plan with Packed (rows: Folder, Files, Bytes, PackedBytes, Reused) and
        Failed (folders left as plain files, with the reason).
    .PARAMETER Packer
        Makes one pack file: param($Folder, $Destination, $Name). Default: DISM (New-DriverPackWim). Tests pass their own.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string[]]$Folders,
        [Parameter(Mandatory)][string]$CacheRoot,
        [scriptblock]$Packer,
        # Called before each folder: param($Folder, $Index, $Count, $Reused).
        [scriptblock]$OnPack
    )
    if (-not $Packer) { $Packer = { param($f, $d, $n) New-DriverPackWim -Folder $f -Destination $d -Name $n } }
    [void][IO.Directory]::CreateDirectory($CacheRoot)
    $items = @($Plan.Items)
    $dirs = @($Plan.Directories)
    $packed = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($folder in @($Folders)) {
        $n++
        $inside = @($items | Where-Object { $_.Relative.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase) })
        if (-not $inside) { continue }
        $key = Get-DriverPackFileKey -Items $inside -Folder $folder
        $cached = [IO.Path]::Combine($CacheRoot, "$key.wim")
        $reused = [IO.File]::Exists($cached)
        if ($OnPack) { & $OnPack $folder $n @($Folders).Count $reused }
        if (-not $reused) {
            $tmp = "$cached.partial"
            try {
                if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
                & $Packer ([IO.Path]::Combine($ContentRoot, ($folder -replace '\\', [IO.Path]::DirectorySeparatorChar))) $tmp ($folder.Split('\')[-1])
                [IO.File]::Move($tmp, $cached)
            } catch {
                if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch { } }
                [void]$failed.Add([pscustomobject]@{ Folder = $folder; Reason = $_.Exception.Message })
                continue
            }
        }
        $bytes = [int64]0
        foreach ($i in $inside) { $bytes += $i.Length }
        $length = ([IO.FileInfo]$cached).Length
        $items = @($items | Where-Object { -not $_.Relative.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase) }) +
            @([pscustomobject]@{ Relative = "$folder.wim"; Source = $cached; Length = [int64]$length })
        $dirs = @($dirs | Where-Object { $_ -ine $folder -and -not $_.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase) })
        [void]$packed.Add([pscustomobject]@{ Folder = $folder; Files = $inside.Count; Bytes = $bytes; PackedBytes = [int64]$length; Reused = $reused })
    }
    $total = [int64]0
    foreach ($i in $items) { $total += $i.Length }
    $out = $Plan.PSObject.Copy()
    $out.Items = $items; $out.Directories = $dirs; $out.TotalBytes = $total; $out.FileCount = $items.Count
    $out | Add-Member -NotePropertyName Packed -NotePropertyValue @($packed) -Force
    $out | Add-Member -NotePropertyName Failed -NotePropertyValue @($failed) -Force
    $out
}

function Remove-OldDriverPackFiles {
    # Keeps the cache from growing forever: pack files this build doesn't use, made more than Days ago, are deleted
    # (a stick that still needs one packs it again).
    param([Parameter(Mandatory)][string]$CacheRoot, [string[]]$InUse, [int]$Days = 60)
    if (-not [IO.Directory]::Exists($CacheRoot)) { return }
    $keep = @($InUse | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFileName($_).ToLowerInvariant() })
    foreach ($f in [IO.Directory]::GetFiles($CacheRoot, '*.wim')) {
        if ($keep -contains [IO.Path]::GetFileName($f).ToLowerInvariant()) { continue }
        if ([IO.File]::GetLastWriteTimeUtc($f) -lt [DateTime]::UtcNow.AddDays(-$Days)) {
            try { [IO.File]::Delete($f) } catch { }
        }
    }
}

Export-ModuleMember -Function Get-DriverPackFolders, Get-DriverPackFileKey, New-DriverPackWim, ConvertTo-PackedDriverPlan, Remove-OldDriverPackFiles
