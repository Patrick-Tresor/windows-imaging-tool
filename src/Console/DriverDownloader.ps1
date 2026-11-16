# Driver pack downloads. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg and imports
# DriverPacks.psm1. The downloads run hidden through Get-DriverPacks.ps1 so the console stays usable; their progress
# is listed on the Driver Library page (Add-DriverDownloadJob).

function Start-DriverPackDownload {
    # Hands the packs to Get-DriverPacks.ps1 through a job file. It runs hidden, in its own process so the console
    # stays usable, and the console's progress window shows each pack: download percent, time left, then checking,
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
    $progressFile = $run.ProgressFile; $logPath = $run.LogPath; $proc = $run.Process
    $title = if (@($Packs).Count -eq 1) { "$(Format-DriverPackName @($Packs)[0]) driver pack" } else { "$(@($Packs).Count) driver packs" }
    # The progress goes in the Driver Library page, under the library, where it stays until it is removed
    # (Patrick, 2026-11-11: no separate window, and a closed window could not be opened again).
    if ($script:ui -and $script:ui.LstDriverDownloads) {
        Add-DriverDownloadJob -Panel $script:ui.GrpDriverDownloads -List $script:ui.LstDriverDownloads -ProgressFile $progressFile `
            -LogPath $logPath -Process $proc -Title $title -OnFinished { try { Update-Drivers } catch { } }
    } else {
        Show-BuildProgress -Owner $Owner -ProgressFile $progressFile -LogPath $logPath -Process $proc -Title "Downloading the $title" -Noun 'download' -Hidden `
            -OnFinished { try { Update-Drivers } catch { } }
    }
}

# --- Downloads list on the Driver Library page ------------------------------------------------------------------

# One download (one Get-DriverPacks.ps1 run) in the list; Steps holds its packs as ImagingTool.BuildStepRow rows
# (BuildProgress.ps1). Property changes redraw only that bit.
if (-not ('ImagingTool.DriverDownloadRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace ImagingTool {
    public class DriverDownloadRow : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        string id, title, summary, elapsed, outcome; bool finished; object steps;
        void Changed(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
        public string Id { get { return id; } set { id = value; } }
        public string Title { get { return title; } set { if (title != value) { title = value; Changed("Title"); } } }
        public string Summary { get { return summary; } set { if (summary != value) { summary = value; Changed("Summary"); } } }
        public string Elapsed { get { return elapsed; } set { if (elapsed != value) { elapsed = value; Changed("Elapsed"); } } }
        public string Outcome { get { return outcome; } set { if (outcome != value) { outcome = value; Changed("Outcome"); } } }
        public bool Finished { get { return finished; } set { if (finished != value) { finished = value; Changed("Finished"); } } }
        public object Steps { get { return steps; } set { steps = value; Changed("Steps"); } }
    }
}
'@
}

# Id -> what the timer needs for each download. Handlers run after the function that set them up has returned,
# so everything they use is in script scope.
$script:DriverDownloads = @{}
$script:DriverDownloadPanel = $null
$script:DriverDownloadList = $null
$script:DriverDownloadTimer = $null

function Add-DriverDownloadJob {
    # Adds a download to the list (newest on top), shows the list and starts reading progress twice a second.
    param(
        [Parameter(Mandatory)]$Panel,
        [Parameter(Mandatory)]$List,
        [Parameter(Mandatory)][string]$ProgressFile,
        [string]$LogPath,
        $Process,
        [string]$Title = 'Driver packs',
        [scriptblock]$OnFinished
    )
    $script:DriverDownloadPanel = $Panel
    $script:DriverDownloadList = $List
    if ($null -eq $List.ItemsSource) {
        $List.ItemsSource = New-Object 'Collections.ObjectModel.ObservableCollection[ImagingTool.DriverDownloadRow]'
        $List.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
            param($sender, $e)
            $btn = $e.OriginalSource
            if ($btn -isnot [Windows.Controls.Button] -or $btn.DataContext -isnot [ImagingTool.DriverDownloadRow]) { return }
            $e.Handled = $true
            Invoke-DriverDownloadAction -Row $btn.DataContext -Action "$($btn.Tag)"
        })
    }
    $row = New-Object ImagingTool.DriverDownloadRow
    $row.Id = [guid]::NewGuid().ToString('N')
    $row.Title = $Title
    $row.Summary = 'Starting...'
    $row.Elapsed = '00:00'
    $row.Steps = New-Object 'Collections.ObjectModel.ObservableCollection[ImagingTool.BuildStepRow]'
    $List.ItemsSource.Insert(0, $row)
    $script:DriverDownloads[$row.Id] = @{ Row = $row; ProgressFile = $ProgressFile; LogPath = $LogPath; Process = $Process
        Started = [DateTime]::UtcNow; OnFinished = $OnFinished; Done = $false; FinishedRan = $false; RemoveTimer = $null }
    $Panel.Visibility = 'Visible'
    if (-not $script:DriverDownloadTimer) {
        $script:DriverDownloadTimer = New-Object Windows.Threading.DispatcherTimer
        $script:DriverDownloadTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:DriverDownloadTimer.Add_Tick({ Update-DriverDownloads })
    }
    Update-DriverDownloads
    if (@($script:DriverDownloads.Values | Where-Object { -not $_.Done }).Count) { $script:DriverDownloadTimer.Start() }
    $row
}

function Invoke-DriverDownloadAction {
    # The Open log and Remove buttons of one download.
    param([Parameter(Mandatory)]$Row, [string]$Action)
    $ctx = $script:DriverDownloads[$Row.Id]
    switch ($Action) {
        'log' {
            if ($ctx -and $ctx.LogPath -and [IO.File]::Exists($ctx.LogPath)) { Start-Process notepad.exe -ArgumentList "`"$($ctx.LogPath)`"" }
        }
        'remove' {
            if ($ctx -and -not $ctx.Done) { return }   # a running download stays listed
            if ($ctx -and $ctx.RemoveTimer) { $ctx.RemoveTimer.Stop() }
            $script:DriverDownloads.Remove($Row.Id)
            [void]$script:DriverDownloadList.ItemsSource.Remove($Row)
            if ($script:DriverDownloadList.ItemsSource.Count -eq 0) { $script:DriverDownloadPanel.Visibility = 'Collapsed' }
        }
    }
}

function Update-DriverDownloads {
    # One timer tick: every running download reads its progress file; the timer stops when none is left running.
    foreach ($ctx in @($script:DriverDownloads.Values | Where-Object { -not $_.Done })) { Update-DriverDownloadJob $ctx }
    if ($script:DriverDownloadTimer -and -not @($script:DriverDownloads.Values | Where-Object { -not $_.Done }).Count) { $script:DriverDownloadTimer.Stop() }
}

# Seconds a download that worked stays listed ("Done in ...") before it takes itself off the list (Patrick,
# 2026-11-11: close by itself when the download is done). A failed one stays until Remove, for its log.
$script:DriverDownloadKeepSeconds = 5

function Complete-DriverDownloadJob {
    # Marks a download finished (OK or failed), runs OnFinished once (the library refreshes) and, when it worked,
    # removes it from the list after DriverDownloadKeepSeconds.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Outcome)
    $Ctx.Done = $true
    $Ctx.Row.Outcome = $Outcome
    $Ctx.Row.Finished = $true
    if ($Outcome -eq 'ok' -and -not $Ctx.RemoveTimer) {
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds($script:DriverDownloadKeepSeconds)
        $t.Tag = $Ctx.Row
        $t.Add_Tick({ param($sender) $sender.Stop(); Invoke-DriverDownloadAction -Row $sender.Tag -Action 'remove' })
        $Ctx.RemoveTimer = $t
        $t.Start()
    }
    if ($Ctx.FinishedRan -or -not $Ctx.OnFinished) { return }
    $Ctx.FinishedRan = $true
    try { & $Ctx.OnFinished } catch { }
}

function Update-DriverDownloadJob {
    # Reads one download's progress file and redraws its row and pack rows.
    param([Parameter(Mandatory)]$Ctx)
    $row = $Ctx.Row
    $proc = $Ctx.Process
    try {
        $data = Read-BuildProgress -Path $Ctx.ProgressFile
        if (-not $data) {
            $gone = $proc -and $proc.HasExited
            $row.Summary = if ($gone) { 'The download stopped before it started. Click Open log to see why.' }
                elseif (([DateTime]::UtcNow - $Ctx.Started).TotalSeconds -gt 60) { 'The download has not started. Click Open log to see why.' }
                else { 'Starting...' }
            if ($gone) { Complete-DriverDownloadJob $Ctx 'failed' }
            return
        }
        $view = Get-BuildStepView -Data $data
        $row.Elapsed = $view.Elapsed
        $row.Summary = $view.Summary
        Update-BuildStepRows -Target $row.Steps -Rows @($view.Rows)
        if ($view.Finished) {
            Complete-DriverDownloadJob $Ctx $(if ($view.Failed) { 'failed' } else { 'ok' })
        } elseif ($proc -and $proc.HasExited) {
            $row.Summary = 'The download stopped before the end. Click Open log to see why.'
            Complete-DriverDownloadJob $Ctx 'failed'
        }
    } catch { $row.Summary = "Can't read the download progress: $($_.Exception.Message)" }
}
