# Copies the USB stick's content (Get-MediaContent's Folders and Files) with progress: a Write-Progress bar for
# the whole copy and for the current file (percent, GB copied, speed, time left), and text lines so a log or a
# host without progress bars still shows the copy moving. Used by New-DeploymentMedia.ps1. PowerShell 5.1 compatible.

function Join-CopyPath {
    # Content paths use backslashes; normalize so the module also runs in tests off Windows.
    param([string]$Root, [string]$Child)
    if (-not $Child) { return $Root }
    Join-Path $Root ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
}

function Format-MediaSize {
    # 1536 -> '1.5 KB', 734003200 -> '700 MB', 5905580032 -> '5.50 GB'.
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    "$Bytes bytes"
}

function Format-MediaDuration {
    # 42 -> '42s', 192 -> '3m 12s', 3900 -> '1h 05m'.
    param([double]$Seconds)
    $s = [int64][Math]::Max(0, [Math]::Round($Seconds))
    if ($s -ge 3600) { return ('{0}h {1:00}m' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60)) }
    if ($s -ge 60) { return ('{0}m {1:00}s' -f [Math]::Floor($s / 60), ($s % 60)) }
    "${s}s"
}

function Get-MediaCopyPlan {
    <#
    .SYNOPSIS
        Every file to copy for the given content folders and files, with its size, and the total, so the copy can
        show overall progress and the build can check the stick is big enough before it is erased.
        Relative paths use backslashes, as in Get-MediaContent.
    #>
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [string[]]$Folders,
        [string[]]$Files
    )
    $items = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    $missing = @()
    $rootFull = (Get-Item -LiteralPath $ContentRoot).FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
    foreach ($folder in @($Folders | Where-Object { $_ })) {
        $full = Join-CopyPath $ContentRoot $folder
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { $missing += $folder; continue }
        [void]$dirs.Add($folder)
        # Sorted so the copy order (and the tests) are the same on every run; -Force includes hidden files like robocopy.
        foreach ($d in Get-ChildItem -LiteralPath $full -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName) {
            [void]$dirs.Add((($d.FullName.Substring($rootFull.Length + 1)) -replace '/', '\'))
        }
        foreach ($f in Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName) {
            $rel = $f.FullName.Substring($rootFull.Length + 1) -replace '/', '\'
            $row = [pscustomobject]@{ Relative = $rel; Source = $f.FullName; Length = [int64]$f.Length }
            [void]$items.Add($row)
        }
    }
    foreach ($file in @($Files | Where-Object { $_ })) {
        $full = Join-CopyPath $ContentRoot $file
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing += $file; continue }
        $f = Get-Item -LiteralPath $full -Force
        $row = [pscustomobject]@{ Relative = ($file -replace '/', '\'); Source = $f.FullName; Length = [int64]$f.Length }
        [void]$items.Add($row)
    }
    $total = [int64]0
    foreach ($i in $items) { $total += $i.Length }
    [pscustomobject]@{
        Items       = @($items)
        Directories = @($dirs)
        TotalBytes  = $total
        FileCount   = $items.Count
        Missing     = $missing
    }
}

function Copy-MediaContent {
    <#
    .SYNOPSIS
        Copies a Get-MediaCopyPlan to Destination in chunks, showing progress, and returns what it copied.
    .PARAMETER OnProgress
        Called with each progress update (tests use it; the build shows Write-Progress and text lines instead).
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Destination,
        [int]$BufferSize = 8MB,
        # Bytes written between flushes to the stick: big enough to keep the stick busy, small enough that the
        # progress shows what is on the stick rather than in the PC's write cache.
        [int64]$FlushEvery = 256MB,
        # Files at least this big get a text line every 10 percent, so the console never looks stuck on one file.
        [int64]$LineEvery10PercentFrom = 256MB,
        [scriptblock]$OnProgress,
        [switch]$Quiet
    )
    $total = [int64]$Plan.TotalBytes
    $done = [int64]0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastShown = -1000
    $index = 0
    $count = @($Plan.Items).Count
    $buffer = New-Object byte[] $BufferSize

    foreach ($d in @($Plan.Directories)) { New-Item -ItemType Directory -Path (Join-CopyPath $Destination $d) -Force | Out-Null }

    $show = {
        param($item, [int64]$fileDone, [bool]$force)
        $now = $clock.ElapsedMilliseconds
        # Write-Progress is slow in Windows PowerShell 5.1: at most four updates a second.
        if (-not $force -and ($now - $lastShown) -lt 250) { return }
        Set-Variable -Name lastShown -Value $now -Scope 1
        $secs = [Math]::Max(0.001, $now / 1000.0)
        $speed = $done / $secs
        $overall = if ($total -gt 0) { [int][Math]::Min(100, [Math]::Floor($done * 100.0 / $total)) } else { 100 }
        $filePct = if ($item.Length -gt 0) { [int][Math]::Min(100, [Math]::Floor($fileDone * 100.0 / $item.Length)) } else { 100 }
        $left = if ($speed -gt 0 -and $total -gt $done) { ($total - $done) / $speed } else { 0 }
        $state = [pscustomobject]@{
            File           = $item.Relative
            FileIndex      = $index
            FileCount      = $count
            FileBytesDone  = $fileDone
            FileBytes      = $item.Length
            FilePercent    = $filePct
            BytesDone      = $done
            TotalBytes     = $total
            Percent        = $overall
            BytesPerSecond = $speed
            SecondsLeft    = $left
        }
        if ($OnProgress) { & $OnProgress $state }
        if (-not $Quiet) {
            $status = '{0} of {1} ({2}%)  {3}/s  about {4} left' -f (Format-MediaSize $done), (Format-MediaSize $total), $overall, (Format-MediaSize ([int64]$speed)), (Format-MediaDuration $left)
            Write-Progress -Id 1 -Activity 'Copying content to the USB stick' -Status $status -PercentComplete $overall
            Write-Progress -Id 2 -ParentId 1 -Activity "File $index of ${count}: $($item.Relative)" -Status ('{0} of {1} ({2}%)' -f (Format-MediaSize $fileDone), (Format-MediaSize $item.Length), $filePct) -PercentComplete $filePct
        }
    }

    try {
        foreach ($item in @($Plan.Items)) {
            $index++
            $target = Join-CopyPath $Destination $item.Relative
            $parent = Split-Path $target -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $big = $item.Length -ge $LineEvery10PercentFrom
            if (-not $Quiet) { Write-Host ("Copying {0} ({1})..." -f $item.Relative, (Format-MediaSize $item.Length)) }
            $fileClock = [Diagnostics.Stopwatch]::StartNew()
            $fileDone = [int64]0
            $nextLine = 10
            $in = $null; $out = $null
            try {
                $in = New-Object IO.FileStream($item.Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
                # Cached writes (write-through made every chunk wait for the stick and roughly halved the speed), flushed
                # to the stick every FlushEvery bytes so the progress never runs far ahead of what is really written.
                $out = New-Object IO.FileStream($target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None)
                $sinceFlush = [int64]0
                $out.SetLength($item.Length)
                & $show $item 0 $true
                while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $read)
                    $sinceFlush += $read
                    if ($sinceFlush -ge $FlushEvery) { $out.Flush($true); $sinceFlush = 0 }
                    $fileDone += $read
                    $done += $read
                    & $show $item $fileDone $false
                    if ($big -and -not $Quiet -and $item.Length -gt 0) {
                        $pct = [Math]::Floor($fileDone * 100.0 / $item.Length)
                        if ($pct -ge $nextLine -and $pct -lt 100) {
                            Write-Host ('  {0}%  {1} of {2}' -f $pct, (Format-MediaSize $fileDone), (Format-MediaSize $item.Length))
                            $nextLine = ([Math]::Floor($pct / 10) + 1) * 10
                        }
                    }
                }
                $out.Flush($true)
            } catch {
                $msg = $_.Exception.Message
                if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                throw "Copying $($item.Relative) to the USB stick failed: $msg Is the stick full or was it unplugged?"
            } finally {
                if ($out) { $out.Dispose() }
                if ($in) { $in.Dispose() }
            }
            # Same timestamps as the source, as robocopy keeps them.
            try { [IO.File]::SetLastWriteTimeUtc($target, [IO.File]::GetLastWriteTimeUtc($item.Source)) } catch { }
            & $show $item $fileDone $true
            if ($big -and -not $Quiet) { Write-Host ('  done in {0}' -f (Format-MediaDuration $fileClock.Elapsed.TotalSeconds)) }
        }
    } finally {
        if (-not $Quiet) {
            Write-Progress -Id 2 -Activity 'Copying' -Completed
            Write-Progress -Id 1 -Activity 'Copying content to the USB stick' -Completed
        }
    }
    [pscustomobject]@{
        FileCount = $index
        Bytes     = $done
        Seconds   = $clock.Elapsed.TotalSeconds
    }
}

Export-ModuleMember -Function Format-MediaSize, Format-MediaDuration, Get-MediaCopyPlan, Copy-MediaContent
