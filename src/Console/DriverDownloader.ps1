# Driver pack downloads. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg and imports
# DriverPacks.psm1. The downloads run hidden through Get-DriverPacks.ps1 so the console stays usable. Their progress
# shows in the Driver library itself: the model's row appears at once and its Status says it is downloading
# (Patrick, 2026-11-27: show the download in the driver library instead of opening another window).

# A driver library row. C# so the grid redraws a row's Status and bar when a download moves on, and still a plain
# type the editable grid can add rows of and bind two-way.
if (-not ('ImagingTool.DriverRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace ImagingTool {
    public class DriverRow : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        void Changed(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
        string maker, model, sku, machineType, modelPattern, path, status, statusTip;
        double percent; bool busy, indeterminate, failed;
        public string Maker { get { return maker; } set { if (maker != value) { maker = value; Changed("Maker"); } } }
        public string Model { get { return model; } set { if (model != value) { model = value; Changed("Model"); } } }
        public string Sku { get { return sku; } set { if (sku != value) { sku = value; Changed("Sku"); } } }
        public string MachineType { get { return machineType; } set { if (machineType != value) { machineType = value; Changed("MachineType"); } } }
        public string ModelPattern { get { return modelPattern; } set { if (modelPattern != value) { modelPattern = value; Changed("ModelPattern"); } } }
        public string Path { get { return path; } set { if (path != value) { path = value; Changed("Path"); } } }
        public string Status { get { return status; } set { if (status != value) { status = value; Changed("Status"); } } }
        public string StatusTip { get { return statusTip; } set { if (statusTip != value) { statusTip = value; Changed("StatusTip"); } } }
        public double Percent { get { return percent; } set { if (percent != value) { percent = value; Changed("Percent"); } } }
        public bool Busy { get { return busy; } set { if (busy != value) { busy = value; Changed("Busy"); } } }
        public bool Indeterminate { get { return indeterminate; } set { if (indeterminate != value) { indeterminate = value; Changed("Indeterminate"); } } }
        public bool Failed { get { return failed; } set { if (failed != value) { failed = value; Changed("Failed"); } } }
        // Download bookkeeping, not shown: the row only exists for a download (not in the catalog yet), the job and
        // pack it shows, and the Status the library gave it before the download.
        public bool IsDownloadEntry { get; set; }
        public object DownloadJob { get; set; }
        public int DownloadIndex { get; set; }
        public string LibraryStatus { get; set; }
    }
}
'@
}

function Start-DriverPackDownload {
    # Hands the packs to Get-DriverPacks.ps1 through a job file. It runs hidden, in its own process so the console
    # stays usable, and each pack's row in the Driver library shows it: download percent, time left, then checking,
    # extracting and adding it to the library (Patrick, 2026-11-11: no PowerShell window with the BITS bar).
    # When it ends the driver library refreshes by itself. Used by Find a model online and the Unknown models window.
    param(
        [Parameter(Mandatory)][object[]]$Packs,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)]$Owner,
        [switch]$KeepDownload
    )
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $job = Join-Path ([IO.Path]::GetTempPath()) "driverpacks-$stamp-$tag.json"
    Save-JsonFile -Path $job -InputObject @($Packs) -Depth 4
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (ConvertTo-Arg (Join-Path $SrcDir 'Get-DriverPacks.ps1')),
        '-ContentRoot', (ConvertTo-Arg $ContentRoot), '-JobFile', (ConvertTo-Arg $job))
    if ($KeepDownload) { $runArgs += '-KeepDownload' }
    $run = Start-ConsoleJob -Name 'driverpacks' -ArgumentList $runArgs -Hidden
    $title = if (@($Packs).Count -eq 1) { "$(Format-DriverPackName @($Packs)[0]) driver pack" } else { "$(@($Packs).Count) driver packs" }
    # No Progress window: each pack shows in its library row (Update-DriverDownloadRows). A download that worked
    # leaves after 5 seconds, its row then shows its drivers; a failed one stays with its reason until Remove row.
    $ctx = Show-BuildProgress -Owner $Owner -ProgressFile $run.ProgressFile -LogPath $run.LogPath -Process $run.Process -Title "Downloading the $title" `
        -Noun 'download' -Hidden -RemoveWhenDoneSeconds 5 -NoWindow -OnFinished { try { Update-Drivers } catch { } } `
        -OnUpdate { param($job) Update-DriverDownloadRows }
    $ctx.Packs = @($Packs)
    $ctx.Dismissed = @{}
    Update-DriverDownloadRows
    $ctx
}

function Get-DriverDownloadStatus {
    # What a pack's library row says while it downloads, from its step row in the job (Get-BuildStepView: State,
    # Percent, Status '40%, under 1 min left', Detail 'Downloading 812 MB', Indeterminate) and the job's view
    # (SummaryState, Summary, Finished). $null once the pack is in the library: the row then shows its drivers.
    param($Step, $Job)
    $jobFailed = $Job -and "$($Job.SummaryState)" -eq 'error'
    $stopped = if ($jobFailed) { 'Download failed: it stopped before the end' }
    $state = if ($Step) { "$($Step.State)" } else { '' }
    if ($state -in 'done', 'reused') { return $null }
    if ($state -eq 'failed') {
        $why = "$($Step.Detail)".Trim()
        return [pscustomobject]@{ Text = $(if ($why) { "Download failed: $why" } else { 'Download failed' }); Percent = 0; Busy = $false; Indeterminate = $false; Failed = $true }
    }
    if ($stopped -or ($Job -and $Job.Finished)) {
        return [pscustomobject]@{ Text = $(if ($stopped) { $stopped } else { 'Download failed' }); Percent = 0; Busy = $false; Indeterminate = $false; Failed = $true }
    }
    if ($state -eq 'running') {
        $pct = [double]$Step.Percent
        if ("$($Step.Detail)" -like 'Downloading*' -and -not $Step.Indeterminate -and "$($Step.Status)") {
            return [pscustomobject]@{ Text = "Downloading $($Step.Status)"; Percent = $pct; Busy = $true; Indeterminate = $false; Failed = $false }
        }
        $what = if ("$($Step.Detail)" -like 'Downloading*') { 'Downloading' } elseif ("$($Step.Detail)" -eq 'Starting' -or -not "$($Step.Detail)") { 'Starting the download' }
            else { ("$($Step.Detail)" -replace '\s*\(.*\)$', '') }
        return [pscustomobject]@{ Text = $what; Percent = 0; Busy = $true; Indeterminate = $true; Failed = $false }
    }
    if ($state -eq 'pending') { return [pscustomobject]@{ Text = 'Waiting to download'; Percent = 0; Busy = $true; Indeterminate = $false; Failed = $false } }
    [pscustomobject]@{ Text = 'Starting the download'; Percent = 0; Busy = $true; Indeterminate = $true; Failed = $false }
}

function Test-DriverRowForPack {
    # True when a library row is the pack's model: same maker and the same model, or a SKU / machine type they share.
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Pack)
    if ("$($Row.Maker)" -ne "$($Pack.Maker)") { return $false }
    if ($Row.Model -and "$($Row.Model)" -eq "$($Pack.Model)") { return $true }
    $split = { param($v) @("$v" -split '\s*[,;]\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $ids = @(@($Pack.Skus) + @($Pack.MachineTypes) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    [bool](@(@(& $split $Row.Sku) + @(& $split $Row.MachineType) | Where-Object { $_ -in $ids }).Count)
}

function Update-DriverDownloadRows {
    # Puts every download on its row of the Driver library ($script:drivers): the model's row when it is there
    # already (a re-download), else a new row on top. Rows whose download ended get their library Status back, and
    # rows that only existed for a download go.
    $rows = $script:drivers
    if ($null -eq $rows) { return }
    $shown = New-Object Collections.ArrayList
    foreach ($job in @($script:WindowlessJobs | Where-Object { $_.Packs })) {
        $packs = @($job.Packs)
        for ($i = 0; $i -lt $packs.Count; $i++) {
            if ($job.Dismissed -and $job.Dismissed.ContainsKey($i)) { continue }
            $step = if ($i -lt $job.Rows.Count) { $job.Rows[$i] } else { $null }
            $st = Get-DriverDownloadStatus -Step $step -Job $job.View
            if (-not $st) { continue }
            $p = $packs[$i]
            $row = @($rows | Where-Object { $_.DownloadJob -eq $job -and $_.DownloadIndex -eq $i })[0]
            if (-not $row) { $row = @($rows | Where-Object { -not $_.DownloadJob -and (Test-DriverRowForPack -Row $_ -Pack $p) })[0] }
            if (-not $row) {
                $row = New-Object ImagingTool.DriverRow
                $row.Maker = $p.Maker; $row.Model = $p.Model; $row.IsDownloadEntry = $true
                $row.Sku = @($p.Skus | Where-Object { $_ }) -join ', '
                $row.MachineType = @($p.MachineTypes | Where-Object { $_ }) -join ', '
                $rows.Insert(0, $row)
            }
            if (-not $row.DownloadJob) { $row.LibraryStatus = $row.Status }
            $row.DownloadJob = $job; $row.DownloadIndex = $i
            $row.Status = $st.Text; $row.Percent = $st.Percent; $row.Busy = $st.Busy; $row.Indeterminate = $st.Indeterminate; $row.Failed = $st.Failed
            $row.StatusTip = if ($st.Failed) { "$($st.Text)`nDouble-click the row to open the log. Remove row takes the message off." } else { "$(Format-DriverPackName $p): $($st.Text)" }
            [void]$shown.Add($row)
        }
    }
    foreach ($row in @($rows | Where-Object { $_.DownloadJob -and -not $shown.Contains($_) })) {
        if ($row.IsDownloadEntry) { [void]$rows.Remove($row); continue }
        Clear-DriverRowDownload $row
    }
}

function Clear-DriverRowDownload {
    # A library row back to its own Status, without its download.
    param([Parameter(Mandatory)]$Row)
    $Row.Status = $Row.LibraryStatus; $Row.StatusTip = $null
    $Row.Busy = $false; $Row.Indeterminate = $false; $Row.Failed = $false; $Row.Percent = 0
    $Row.DownloadJob = $null; $Row.LibraryStatus = $null
}

function Remove-DriverDownloadRow {
    # Remove row on a row that shows a download. Returns what to tell the person, or '' when it is not a download
    # row (Remove row then removes the catalog entry as usual). Still running: it stays. Ended: the message goes
    # (its row too when it only existed for the download), and the job with it once none of its packs is shown.
    param([Parameter(Mandatory)]$Row)
    $job = $Row.DownloadJob
    if (-not $job) { return '' }
    if ($Row.Busy) { return "$($Row.Maker) $($Row.Model) is still downloading. It can be removed once it ends." }
    $job.Dismissed[$Row.DownloadIndex] = $true
    if ($Row.IsDownloadEntry) { [void]$script:drivers.Remove($Row) } else { Clear-DriverRowDownload $Row }
    if (-not @($script:drivers | Where-Object { $_.DownloadJob -eq $job }).Count) { Remove-ProgressJob -Ctx $job }
    "Removed the failed download of $($Row.Maker) $($Row.Model)."
}

function Open-DriverDownloadLog {
    # Double-click on a row that shows a download: its log in Notepad. False when the row has none.
    param($Row)
    if (-not $Row -or -not $Row.DownloadJob) { return $false }
    Invoke-ProgressJobButton -Ctx $Row.DownloadJob -Action 'log'
    $true
}
