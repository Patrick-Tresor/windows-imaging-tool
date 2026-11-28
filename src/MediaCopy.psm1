# Copies the USB stick's content (Get-MediaContent's Folders and Files) with progress: a Write-Progress bar for
# the whole copy and for the current file (percent, GB copied, speed, time left), and text lines so a log or a
# host without progress bars still shows the copy moving. Used by New-DeploymentMedia.ps1. PowerShell 5.1 compatible.

Import-Module (Join-Path $PSScriptRoot 'Format.psm1')
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1')
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1')   # Join-ContentPath

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
        $full = Join-ContentPath $ContentRoot $folder
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
        $full = Join-ContentPath $ContentRoot $file
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
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace ImagingTool {
    // Copies a list of files, one after the other, on one background thread with CopyFileEx and no flags: the
    // buffered copy that File Explorer, Copy-Item and File.Copy use. PowerShell polls Done for the progress bar.
    // History on Patrick's Kingston stick: CopyFileEx unbuffered (COPY_FILE_NO_BUFFERING, robocopy /J style) gave
    // 3 MB/s, a chunked FileStream copy 6-7 MB/s, Explorer about 40 MB/s. Thousands of small driver files go in one
    // list, so PowerShell does no work (thread, paths, polling) per file. A file of FlushFrom bytes or more is
    // flushed to the stick at its end, so 100% means written.
    public class MediaBatchCopy {
        delegate uint ProgressRoutine(long total, long transferred, long streamSize, long streamTransferred,
            uint streamNumber, uint reason, IntPtr source, IntPtr destination, IntPtr data);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CopyFileEx(string source, string destination, ProgressRoutine progress, IntPtr data,
            IntPtr cancel, uint flags);

        readonly object gate = new object();
        long finished;      // bytes of the files already copied (their planned length)
        long current;       // bytes of the file being copied
        int completed;      // files already copied
        readonly string[] sources;
        readonly string[] destinations;
        readonly long[] lengths;
        readonly long flushFrom;
        ProgressRoutine callback;
        Thread thread;

        public volatile bool Cancel;
        public string ErrorMessage;
        public int FailedIndex = -1;

        public MediaBatchCopy(string[] sources, string[] destinations, long[] lengths, long flushFrom) {
            this.sources = sources;
            this.destinations = destinations;
            this.lengths = lengths;
            this.flushFrom = flushFrom;
        }

        // Bytes copied so far over the whole list, the files done and the current file's bytes, read together.
        public long[] Snapshot() { lock (gate) { return new long[] { finished + current, completed, current }; } }

        public void Start() {
            callback = OnProgress;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        public bool Wait(int milliseconds) { return thread.Join(milliseconds); }

        void Run() {
            for (int i = 0; i < sources.Length; i++) {
                if (Cancel) { FailedIndex = i; ErrorMessage = "The copy was cancelled."; return; }
                string source = sources[i];
                string destination = destinations[i];
                try {
                    string parent = Path.GetDirectoryName(destination);
                    if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
                    // CopyFileEx can't replace a read-only or hidden file (an update, or a stick built before):
                    // make it a plain file first.
                    if (File.Exists(destination)) File.SetAttributes(destination, FileAttributes.Normal);
                    if (!CopyFileEx(source, destination, callback, IntPtr.Zero, IntPtr.Zero, 0)) {
                        FailedIndex = i;
                        ErrorMessage = Cancel ? "The copy was cancelled." : new Win32Exception(Marshal.GetLastWin32Error()).Message;
                        return;
                    }
                    // The copy keeps the source's attributes; a read-only file would block the next update of the stick.
                    var attributes = File.GetAttributes(destination);
                    if ((attributes & FileAttributes.ReadOnly) != 0) File.SetAttributes(destination, attributes & ~FileAttributes.ReadOnly);
                    if (lengths[i] >= flushFrom) {
                        using (var f = new FileStream(destination, FileMode.Open, FileAccess.Write, FileShare.Read)) { f.Flush(true); }
                    }
                } catch (Exception e) {
                    FailedIndex = i;
                    ErrorMessage = e.Message;
                    return;
                }
                lock (gate) { finished += lengths[i]; current = 0; completed = i + 1; }
            }
        }

        uint OnProgress(long total, long transferred, long streamSize, long streamTransferred, uint streamNumber,
            uint reason, IntPtr source, IntPtr destination, IntPtr data) {
            lock (gate) { current = transferred; }
            return Cancel ? 1u : 0u;  // PROGRESS_CANCEL : PROGRESS_CONTINUE
        }
    }
}
'@

function Test-NativeCopy {
    # True when the copy helper (CopyFileEx, Windows only) is there, compiling it the first time.
    if ([IO.Path]::DirectorySeparatorChar -ne '\') { return $false }
    if (-not ('ImagingTool.MediaBatchCopy' -as [type])) { Add-Type -TypeDefinition $script:NativeCopySource }
    $true
}

function Copy-MediaContent {
    <#
    .SYNOPSIS
        Copies a Get-MediaCopyPlan to Destination on a background thread (ImagingTool.MediaBatchCopy: CopyFileEx
        buffered, as File Explorer copies; big files flushed at their end), while PowerShell only reads the byte
        count for the progress bar. Returns what it copied.
    .PARAMETER OnProgress
        Called with each progress update (tests use it; the build shows Write-Progress and text lines instead).
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Destination,
        # Files at least this big are flushed to the stick at their end and get their own text lines and progress updates.
        [int64]$LineEvery10PercentFrom = 256MB,
        [scriptblock]$OnProgress,
        [switch]$Quiet
    )
    if (-not (Test-NativeCopy)) { throw 'Copying to the USB stick needs Windows.' }
    $total = [int64]$Plan.TotalBytes
    $done = [int64]0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastShown = -1000
    # Bytes done over the last few seconds, for the speed shown: an average since the start mixes the thousands of
    # small driver files (slow on a stick) with the big image (fast), so neither the speed nor the time left was right.
    $samples = New-Object System.Collections.Generic.Queue[object]
    $index = 0
    $count = @($Plan.Items).Count

    foreach ($d in @($Plan.Directories)) { New-Item -ItemType Directory -Path (Join-ContentPath $Destination $d) -Force | Out-Null }

    $show = {
        param($item, [int64]$fileDone, [bool]$force)
        $now = $clock.ElapsedMilliseconds
        # Write-Progress is slow in Windows PowerShell 5.1 (milliseconds per call): at most four updates a second,
        # whatever the number of files, so thousands of small driver files don't spend their time redrawing the bar.
        if (-not $force -and ($now - $lastShown) -lt 250) { return }
        Set-Variable -Name lastShown -Value $now -Scope 1
        $secs = [Math]::Max(0.001, $now / 1000.0)
        $average = $done / $secs
        $samples.Enqueue(@($now, $done))
        while ($samples.Count -gt 1 -and ($now - $samples.Peek()[0]) -gt 15000) { [void]$samples.Dequeue() }
        $first = $samples.Peek()
        $speed = if (($now - $first[0]) -ge 3000) { ($done - $first[1]) / (($now - $first[0]) / 1000.0) } else { $average }
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
            AverageBytesPerSecond = $average
            SecondsLeft    = $left
        }
        if ($OnProgress) { & $OnProgress $state }
        if (-not $Quiet) {
            $status = '{0} of {1} ({2}%)  {3}/s  about {4} left' -f (Format-ByteSize $done), (Format-ByteSize $total), $overall, (Format-ByteSize ([int64]$speed)), (Format-Duration $left)
            Write-Progress -Id 1 -Activity 'Copying content to the USB stick' -Status $status -PercentComplete $overall
            Write-Progress -Id 2 -ParentId 1 -Activity "File $index of ${count}: $($item.Relative)" -Status ('{0} of {1} ({2}%)' -f (Format-ByteSize $fileDone), (Format-ByteSize $item.Length), $filePct) -PercentComplete $filePct
        }
    }
    $lines = {
        # A text line every 10 percent of a big file, so a log or a host without progress bars shows it moving.
        param($item, [int64]$fileDone)
        if (-not $big -or $Quiet -or $item.Length -le 0) { return }
        $pct = [Math]::Floor($fileDone * 100.0 / $item.Length)
        if ($pct -ge $nextLine -and $pct -lt 100) {
            Write-Host ('  {0}%  {1} of {2}' -f $pct, (Format-ByteSize $fileDone), (Format-ByteSize $item.Length))
            Set-Variable -Name nextLine -Value (([Math]::Floor($pct / 10) + 1) * 10) -Scope 1
        }
    }

    $item = $null
    $fileDone = [int64]0
    $items = @($Plan.Items)
    $smallFiles = 0; $smallBytes = [int64]0; $smallSecs = 0.0
    $at = 0
    try {
        while ($at -lt $count) {
            # One big file on its own (its own text lines, flushed at its end), or every small file up to the next
            # big one in one batch: the copy thread runs through them with no PowerShell work per file.
            $first = $items[$at]
            $big = $first.Length -ge $LineEvery10PercentFrom
            $batch = @(if ($big) { $first } else {
                $end = $at
                while ($end -lt $count -and $items[$end].Length -lt $LineEvery10PercentFrom) { $items[$end]; $end++ }
            })
            $sources = [string[]]@($batch | ForEach-Object { $_.Source })
            $targets = [string[]]@($batch | ForEach-Object { Join-ContentPath $Destination $_.Relative })
            $lengths = [int64[]]@($batch | ForEach-Object { [int64]$_.Length })
            $batchBytes = [int64]0
            foreach ($l in $lengths) { $batchBytes += $l }
            # Only big files get a line of their own: a line per driver file would be thousands of slow console writes.
            if ($big -and -not $Quiet) { Write-Host ("Copying {0} ({1})..." -f $first.Relative, (Format-ByteSize $first.Length)) }
            $fileClock = [Diagnostics.Stopwatch]::StartNew()
            $doneBefore = $done
            $nextLine = 10
            $item = $first; $index = $at + 1; $fileDone = [int64]0
            & $show $item 0 $big
            $job = New-Object ImagingTool.MediaBatchCopy($sources, $targets, $lengths, $LineEvery10PercentFrom)
            $job.Start()
            try {
                while (-not $job.Wait(250)) {
                    $snap = $job.Snapshot()
                    $n = [int][Math]::Min($snap[1], $batch.Count - 1)
                    $item = $batch[$n]; $index = $at + $n + 1; $fileDone = $snap[2]
                    $done = $doneBefore + $snap[0]
                    & $show $item $fileDone $false
                    & $lines $item $fileDone
                }
            } finally {
                # Ctrl+C: stop the copy thread too.
                if (-not $job.Wait(0)) { $job.Cancel = $true; [void]$job.Wait(5000) }
            }
            if ($job.ErrorMessage) {
                $failed = $batch[[Math]::Max(0, $job.FailedIndex)]
                throw "Copying $($failed.Relative) to the USB stick failed: $($job.ErrorMessage) Is the stick full or was it unplugged?"
            }
            $at += $batch.Count
            $item = $batch[-1]; $index = $at
            $fileDone = $item.Length
            $done = $doneBefore + $batchBytes
            & $show $item $fileDone $big
            $secs = [Math]::Max(0.001, $fileClock.Elapsed.TotalSeconds)
            if ($big) {
                if (-not $Quiet) { Write-Host ('  done in {0} ({1}/s)' -f (Format-Duration $secs), (Format-ByteSize ([int64]($item.Length / $secs)))) }
            } else {
                $smallFiles += $batch.Count; $smallBytes += $batchBytes; $smallSecs += $secs
            }
        }
        if ($item) { & $show $item $fileDone $true }
        # Where the time went: thousands of small files write far slower to a stick than one big image.
        if ($smallFiles -and -not $Quiet) {
            Write-Host ('Small files: {0} file(s), {1} in {2} ({3}/s)' -f $smallFiles, (Format-ByteSize $smallBytes), (Format-Duration $smallSecs), (Format-ByteSize ([int64]($smallBytes / [Math]::Max(0.001, $smallSecs)))))
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
        $target = Join-ContentPath $Destination $i.Relative
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
        $full = Join-ContentPath $Destination $folder
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
    foreach ($f in @($UpdatePlan.Stale)) { Remove-Item -LiteralPath (Join-ContentPath $Destination $f.Relative) -Force -ErrorAction SilentlyContinue }
    foreach ($folder in $script:ManagedFolders) {
        $full = Join-ContentPath $Destination $folder
        if (-not (Test-Path -LiteralPath $full)) { continue }
        Get-ChildItem -LiteralPath $full -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Clear-StickContent {
    # A stick made WinPE only: its answer files, images, drivers, applications, tasks, tools and config are deleted
    # (Logs and Status stay), so WinPE loads all of it from the share. Returns the bytes freed.
    param([Parameter(Mandatory)][string]$Destination)
    $freed = [int64]0
    foreach ($folder in $script:ManagedFolders) {
        $full = [IO.Path]::Combine($Destination, $folder)
        if (-not [IO.Directory]::Exists($full)) { continue }
        foreach ($f in [IO.Directory]::GetFiles($full, '*', [IO.SearchOption]::AllDirectories)) {
            $fi = New-Object IO.FileInfo $f
            $freed += $fi.Length
            if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
        }
        [IO.Directory]::Delete($full, $true)
    }
    $freed
}

Export-ModuleMember -Function Get-MediaCopyPlan, Copy-MediaContent, Test-NativeCopy, Get-MediaUpdatePlan, Remove-StaleMediaFiles, Clear-StickContent
