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
        [string[]]$Files,
        # Relative folders or files left out, with everything under them (config\secrets).
        [string[]]$Exclude
    )
    $skip = @($Exclude | Where-Object { $_ } | ForEach-Object { ($_ -replace '/', '\').Trim('\') })
    $isSkipped = {
        param([string]$Rel)
        foreach ($x in $skip) { if ($Rel -ieq $x -or $Rel.StartsWith("$x\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        $false
    }
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
            $relDir = ($d.FullName.Substring($rootFull.Length + 1)) -replace '/', '\'
            if (-not (& $isSkipped $relDir)) { [void]$dirs.Add($relDir) }
        }
        foreach ($f in Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName) {
            $rel = $f.FullName.Substring($rootFull.Length + 1) -replace '/', '\'
            if (& $isSkipped $rel) { continue }
            $row = [pscustomobject]@{ Relative = $rel; Source = $f.FullName; Length = [int64]$f.Length }
            [void]$items.Add($row)
        }
    }
    foreach ($file in @($Files | Where-Object { $_ })) {
        if (& $isSkipped ($file -replace '/', '\')) { continue }
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

$script:NativeCopySource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace ImagingTool {
    // Copies one file with CopyFileEx on a background thread; PowerShell polls Done for the progress bar.
    public class MediaFileCopy {
        delegate uint ProgressRoutine(long total, long transferred, long streamSize, long streamTransferred,
            uint streamNumber, uint reason, IntPtr source, IntPtr destination, IntPtr data);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CopyFileEx(string source, string destination, ProgressRoutine progress, IntPtr data,
            IntPtr cancel, uint flags);

        const uint CopyFileNoBuffering = 0x1000;
        long done;
        readonly string source;
        readonly string destination;
        readonly uint flags;
        ProgressRoutine callback;
        Thread thread;

        public volatile bool Cancel;
        public int Error;

        public MediaFileCopy(string source, string destination, bool unbuffered) {
            this.source = source;
            this.destination = destination;
            this.flags = unbuffered ? CopyFileNoBuffering : 0;
        }

        public long Done { get { return Interlocked.Read(ref done); } }

        public void Start() {
            callback = OnProgress;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        public bool Wait(int milliseconds) { return thread.Join(milliseconds); }

        void Run() {
            if (!CopyFileEx(source, destination, callback, IntPtr.Zero, IntPtr.Zero, flags)) {
                Error = Marshal.GetLastWin32Error();
            }
        }

        uint OnProgress(long total, long transferred, long streamSize, long streamTransferred, uint streamNumber,
            uint reason, IntPtr source, IntPtr destination, IntPtr data) {
            Interlocked.Exchange(ref done, transferred);
            return Cancel ? 1u : 0u;  // PROGRESS_CANCEL : PROGRESS_CONTINUE
        }
    }
}
'@

function Test-NativeCopy {
    # True when CopyFileEx is there (Windows), compiling the helper the first time.
    if ([IO.Path]::DirectorySeparatorChar -ne '\') { return $false }
    if (-not ('ImagingTool.MediaFileCopy' -as [type])) { Add-Type -TypeDefinition $script:NativeCopySource }
    $true
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
        # Native: Windows' own CopyFileEx on a background thread (what Explorer and robocopy use), unbuffered for big
        # files like robocopy /J, while PowerShell only reads the byte count for the progress bar. Stream: a chunked
        # copy in PowerShell, used off Windows (tests). Auto picks Native on Windows.
        [ValidateSet('Auto', 'Native', 'Stream')][string]$Method = 'Auto',
        # Files at least this big are copied unbuffered (Native) and get their own text lines and progress updates.
        [int64]$LineEvery10PercentFrom = 256MB,
        # Stream method only: chunk size, and bytes written between flushes so progress shows what is on the disk.
        [int]$BufferSize = 8MB,
        [int64]$FlushEvery = 256MB,
        [scriptblock]$OnProgress,
        [switch]$Quiet
    )
    if ($Method -eq 'Auto') { $Method = if (Test-NativeCopy) { 'Native' } else { 'Stream' } }
    if ($Method -eq 'Native' -and -not (Test-NativeCopy)) { throw 'The native copy needs Windows.' }
    $total = [int64]$Plan.TotalBytes
    $done = [int64]0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastShown = -1000
    $index = 0
    $count = @($Plan.Items).Count
    $buffer = $null
    if ($Method -eq 'Stream') { $buffer = New-Object byte[] $BufferSize }

    foreach ($d in @($Plan.Directories)) { New-Item -ItemType Directory -Path (Join-CopyPath $Destination $d) -Force | Out-Null }

    $show = {
        param($item, [int64]$fileDone, [bool]$force)
        $now = $clock.ElapsedMilliseconds
        # Write-Progress is slow in Windows PowerShell 5.1 (milliseconds per call): at most four updates a second,
        # whatever the number of files, so thousands of small driver files don't spend their time redrawing the bar.
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
    $lines = {
        # A text line every 10 percent of a big file, so a log or a host without progress bars shows it moving.
        param($item, [int64]$fileDone)
        if (-not $big -or $Quiet -or $item.Length -le 0) { return }
        $pct = [Math]::Floor($fileDone * 100.0 / $item.Length)
        if ($pct -ge $nextLine -and $pct -lt 100) {
            Write-Host ('  {0}%  {1} of {2}' -f $pct, (Format-MediaSize $fileDone), (Format-MediaSize $item.Length))
            Set-Variable -Name nextLine -Value (([Math]::Floor($pct / 10) + 1) * 10) -Scope 1
        }
    }

    $item = $null
    $fileDone = [int64]0
    try {
        foreach ($item in @($Plan.Items)) {
            $index++
            $target = Join-CopyPath $Destination $item.Relative
            $parent = Split-Path $target -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $big = $item.Length -ge $LineEvery10PercentFrom
            # Only big files get a line of their own: a line per driver file would be thousands of slow console writes.
            if ($big -and -not $Quiet) { Write-Host ("Copying {0} ({1})..." -f $item.Relative, (Format-MediaSize $item.Length)) }
            $fileClock = [Diagnostics.Stopwatch]::StartNew()
            $fileDone = [int64]0
            $doneBefore = $done
            $nextLine = 10
            & $show $item 0 $big
            if ($Method -eq 'Native') {
                $job = New-Object ImagingTool.MediaFileCopy($item.Source, $target, $big)
                $job.Start()
                try {
                    while (-not $job.Wait(250)) {
                        $fileDone = $job.Done
                        $done = $doneBefore + $fileDone
                        & $show $item $fileDone $false
                        & $lines $item $fileDone
                    }
                } finally {
                    # Ctrl+C: stop the copy thread too.
                    if (-not $job.Wait(0)) { $job.Cancel = $true; [void]$job.Wait(5000) }
                }
                if ($job.Error) {
                    $msg = (New-Object ComponentModel.Win32Exception($job.Error)).Message
                    throw "Copying $($item.Relative) to the USB stick failed: $msg Is the stick full or was it unplugged?"
                }
                $fileDone = $item.Length
                $done = $doneBefore + $fileDone
            } else {
                $in = $null; $out = $null
                try {
                    $in = New-Object IO.FileStream($item.Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
                    # Cached writes, flushed every FlushEvery bytes (write-through made every chunk wait for the stick).
                    $out = New-Object IO.FileStream($target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None)
                    $sinceFlush = [int64]0
                    while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $out.Write($buffer, 0, $read)
                        $sinceFlush += $read
                        if ($sinceFlush -ge $FlushEvery) { $out.Flush($true); $sinceFlush = 0 }
                        $fileDone += $read
                        $done += $read
                        & $show $item $fileDone $false
                        & $lines $item $fileDone
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
                # Same timestamps as the source, as CopyFileEx and robocopy keep them.
                try { [IO.File]::SetLastWriteTimeUtc($target, [IO.File]::GetLastWriteTimeUtc($item.Source)) } catch { }
            }
            & $show $item $fileDone $big
            if ($big -and -not $Quiet) { Write-Host ('  done in {0}' -f (Format-MediaDuration $fileClock.Elapsed.TotalSeconds)) }
        }
        if ($item) { & $show $item $fileDone $true }
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

# Folders the build manages on the DEPLOY partition. An update deletes files in them that the new content no
# longer has (an old image, a driver pack left off, password files from a stick built before they were left off).
# Logs (copied from WinPE) and anything else on the stick are never touched.
$script:ManagedFolders = 'AnswerFiles', 'Images', 'Drivers', 'Applications', 'Tasks', 'Tools', 'config'

function Get-MediaUpdatePlan {
    <#
    .SYNOPSIS
        What updating a stick in place has to do: the files of Plan (Get-MediaCopyPlan) missing on Destination or
        different there (size, or modified time more than 2 s apart: FAT and NTFS round times differently), and
        the files on the stick to delete. Copy is a plan for Copy-MediaContent.
    #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$Destination, [string[]]$Keep = @('Drivers\_WinPE'))
    $wanted = @{}
    $copy = New-Object System.Collections.ArrayList
    $same = 0; $sameBytes = [int64]0; $replacedBytes = [int64]0
    foreach ($i in @($Plan.Items)) {
        $wanted[$i.Relative.ToLowerInvariant()] = $true
        $target = Join-CopyPath $Destination $i.Relative
        $existing = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-Item -LiteralPath $target -Force } else { $null }
        if ($existing -and $existing.Length -eq $i.Length -and
            [Math]::Abs(($existing.LastWriteTimeUtc - [IO.File]::GetLastWriteTimeUtc($i.Source)).TotalSeconds) -le 2) {
            $same++; $sameBytes += $i.Length; continue
        }
        if ($existing) { $replacedBytes += $existing.Length }
        [void]$copy.Add($i)
    }
    $destFull = (Get-Item -LiteralPath $Destination).FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $stale = New-Object System.Collections.ArrayList
    $staleBytes = [int64]0
    $keepAll = @($Keep | Where-Object { $_ } | ForEach-Object { ($_ -replace '/', '\').Trim('\').ToLowerInvariant() })
    foreach ($folder in $script:ManagedFolders) {
        $full = Join-CopyPath $Destination $folder
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName) {
            $rel = $f.FullName.Substring($destFull.Length + 1) -replace '/', '\'
            $low = $rel.ToLowerInvariant()
            if ($wanted.ContainsKey($low)) { continue }
            if (@($keepAll | Where-Object { $low -eq $_ -or $low.StartsWith("$_\") }).Count) { continue }
            [void]$stale.Add([pscustomobject]@{ Relative = $rel; Length = [int64]$f.Length })
            $staleBytes += $f.Length
        }
    }
    $total = [int64]0
    foreach ($i in $copy) { $total += $i.Length }
    [pscustomobject]@{
        Copy           = [pscustomobject]@{ Items = @($copy); Directories = @($Plan.Directories); TotalBytes = $total; FileCount = $copy.Count; Missing = @($Plan.Missing) }
        Stale          = @($stale)
        StaleBytes     = $staleBytes
        Unchanged      = $same
        UnchangedBytes = $sameBytes
        ReplacedBytes  = $replacedBytes
        # Extra room the update needs on the stick: what it copies, less what it overwrites or deletes.
        NeededBytes    = [int64]($total - $replacedBytes - $staleBytes)
    }
}

function Remove-StaleMediaFiles {
    # Deletes Get-MediaUpdatePlan's Stale files, then the folders they leave empty.
    param([Parameter(Mandatory)]$UpdatePlan, [Parameter(Mandatory)][string]$Destination)
    foreach ($f in @($UpdatePlan.Stale)) { Remove-Item -LiteralPath (Join-CopyPath $Destination $f.Relative) -Force -ErrorAction SilentlyContinue }
    foreach ($folder in $script:ManagedFolders) {
        $full = Join-CopyPath $Destination $folder
        if (-not (Test-Path -LiteralPath $full)) { continue }
        Get-ChildItem -LiteralPath $full -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Format-MediaSize, Format-MediaDuration, Get-MediaCopyPlan, Copy-MediaContent, Test-NativeCopy, Get-MediaUpdatePlan, Remove-StaleMediaFiles
