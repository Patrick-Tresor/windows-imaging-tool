# Progress window: one window for everything that runs (media builds, captures, driver downloads, reimages, image
# updates and versions), one card each, with one row per step (name, elapsed time, bar, Complete), read twice a
# second from the progress file the job writes (src\BuildSteps.psm1). Dot-sourced by ImagingConsole.ps1.
# Not modal: the console stays usable, and closing the window leaves the work running.
# Closing the window while work runs only hides it: Show progress in the console header brings it back
# (Patrick, 2026-11-22: a closed progress window could not be opened again; then: one window, not one per reimage).
# It has no owner (Patrick, 2026-11-23: the window stayed black in the taskbar and would not come up). An owned window
# is placed from its owner (off screen when the console is minimized), hides and shows with it, and its taskbar
# button can fail to bring it up. Its own window, centred on the screen and drawn in software, avoids all three.

if (-not $script:ProgressWindows) { $script:ProgressWindows = New-Object Collections.ArrayList }

# A C# row so each property change redraws only that bit: a busy bar keeps running while its time counts up.
if (-not ('ImagingTool.BuildStepRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace ImagingTool {
    public class BuildStepRow : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        string name, state, time, status, detail; double percent; bool indeterminate;
        void Changed(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
        public string Name { get { return name; } set { if (name != value) { name = value; Changed("Name"); } } }
        public string State { get { return state; } set { if (state != value) { state = value; Changed("State"); } } }
        public string Time { get { return time; } set { if (time != value) { time = value; Changed("Time"); } } }
        public string Status { get { return status; } set { if (status != value) { status = value; Changed("Status"); } } }
        public string Detail { get { return detail; } set { if (detail != value) { detail = value; Changed("Detail"); } } }
        public double Percent { get { return percent; } set { if (percent != value) { percent = value; Changed("Percent"); } } }
        public bool Indeterminate { get { return indeterminate; } set { if (indeterminate != value) { indeterminate = value; Changed("Indeterminate"); } } }
    }
    // One card in the Progress window: a build, capture, download or reimage.
    public class BuildJobView : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        string title, elapsed, summary, summaryState; bool hasLog, finished; object rows;
        void Changed(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
        public string Title { get { return title; } set { if (title != value) { title = value; Changed("Title"); } } }
        public string Elapsed { get { return elapsed; } set { if (elapsed != value) { elapsed = value; Changed("Elapsed"); } } }
        public string Summary { get { return summary; } set { if (summary != value) { summary = value; Changed("Summary"); } } }
        public string SummaryState { get { return summaryState; } set { if (summaryState != value) { summaryState = value; Changed("SummaryState"); } } }
        public bool HasLog { get { return hasLog; } set { if (hasLog != value) { hasLog = value; Changed("HasLog"); } } }
        public bool Finished { get { return finished; } set { if (finished != value) { finished = value; Changed("Finished"); } } }
        public object Rows { get { return rows; } set { rows = value; Changed("Rows"); } }
    }
}
'@
}


function Update-BuildStepRows {
    # Copies Get-BuildStepView rows onto the window's rows (made once, then changed in place); done steps get a
    # tick in front of Complete.
    param([Parameter(Mandatory)]$Target, [object[]]$Rows)
    $tick = [string][char]0x2713
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ($i -ge $Target.Count) { $Target.Add((New-Object ImagingTool.BuildStepRow)) }
        $row = $Target[$i]; $r = $Rows[$i]
        $row.Name = $r.Name; $row.State = $r.State; $row.Time = $r.Time; $row.Detail = $r.Detail
        $row.Percent = [double]$r.Percent; $row.Indeterminate = [bool]$r.Indeterminate
        $row.Status = if ($r.State -in 'done', 'reused') { "$tick $($r.Status)" } else { $r.Status }
    }
    while ($Target.Count -gt $Rows.Count) { $Target.RemoveAt($Target.Count - 1) }
}

function Start-ConsoleJob {
    # Runs a script in its own powershell.exe so the console stays usable, with a progress file in TEMP and a log
    # in %LOCALAPPDATA%\ImagingConsole\Logs\<Name>-<time>.log for Show-BuildProgress. -ArgumentList is the command
    # line, to which -ProgressFile and -LogPath are added, or a script block that gets both paths and returns it.
    # Returns Process, ProgressFile and LogPath.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$ArgumentList,
        [switch]$Hidden
    )
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $temp = [IO.Path]::GetTempPath()
    $progressFile = [IO.Path]::Combine($temp, "$Name-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json")
    $logPath = [IO.Path]::Combine($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $temp }), 'ImagingConsole', 'Logs', "$Name-$stamp.log")
    $runArgs = if ($ArgumentList -is [scriptblock]) { & $ArgumentList $progressFile $logPath }
               else { @($ArgumentList) + @('-ProgressFile', (ConvertTo-Arg $progressFile), '-LogPath', (ConvertTo-Arg $logPath)) }
    $proc = Start-Process powershell.exe -ArgumentList $runArgs -WindowStyle $(if ($Hidden) { 'Hidden' } else { 'Minimized' }) -PassThru
    [pscustomobject]@{ Process = $proc; ProgressFile = $progressFile; LogPath = $logPath }
}

function Get-ProgressHub {
    # The one Progress window, made the first time something runs and again after it was really closed.
    # -Owner is the console window: the console closes this window when it closes (Close-ProgressHub).
    param([Parameter(Mandatory)]$Owner)
    if ($script:ProgressHub) { return $script:ProgressHub }
    $form = New-ConsoleWindow 'BuildProgress.xaml'
    $dlg = $form.Window
    # Drawn by the CPU: some graphics drivers leave a WPF window black after it was hidden or minimized.
    $dlg.Add_SourceInitialized({
        param($sender)
        try {
            $src = [Windows.Interop.HwndSource]::FromVisual($sender)
            if ($src) { $src.CompositionTarget.RenderMode = [Windows.Interop.RenderMode]::SoftwareOnly }
        } catch { }
    })
    $b = $form.Controls
    $jobs = New-Object 'Collections.ObjectModel.ObservableCollection[ImagingTool.BuildJobView]'
    $b.LstJobs.ItemsSource = $jobs
    $hub = @{ Window = $dlg; B = $b; Jobs = $jobs }
    $dlg.Tag = $hub
    # The buttons on each card (Tag log or remove) find their job by the card's view.
    $dlg.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($sender, $e)
        $btn = $e.OriginalSource
        if (-not ($btn -is [Windows.Controls.Button]) -or "$($btn.Tag)" -notin 'log', 'remove') { return }
        $c = @($script:ProgressWindows | Where-Object { $_.View -eq $btn.DataContext })[0]
        if ($c) { Invoke-ProgressJobButton -Ctx $c -Action "$($btn.Tag)" }
    })
    $b.BtnClose.Add_Click({ param($sender) [Windows.Window]::GetWindow($sender).Close() })
    $dlg.Add_Closing({
        param($sender, $e)
        # WPF refuses Hide() inside Closing, so it is queued just after.
        if (Test-ProgressWindowKeep) {
            $e.Cancel = $true
            $w = $sender
            [void]$w.Dispatcher.BeginInvoke([action]{ $w.Hide() }.GetNewClosure())
        }
    })
    $dlg.Add_Closed({
        foreach ($c in @($script:ProgressWindows)) { $c.Timer.Stop() }
        $script:ProgressWindows.Clear()
        $script:ProgressHub = $null
        Update-ShowProgressButton
    })
    $script:ProgressHub = $hub
    $hub
}

function Show-BuildProgress {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ProgressFile,
        [string]$LogPath,
        # The job's powershell.exe (Start-Process -PassThru), to notice it closing.
        $Process,
        [string]$Title = 'Building media',
        # What runs, for the card's wording: 'build' (media), 'download' (driver packs), 'reimage'.
        [string]$Noun = 'build',
        # The process runs hidden (driver pack downloads): no window of its own on the taskbar.
        [switch]$Hidden,
        # Run once when it finishes (OK or failed), in the console: the driver download refreshes the library.
        [scriptblock]$OnFinished,
        # A job that worked takes its card off after this many seconds (driver downloads, Patrick 2026-11-11: gone
        # by itself when done). A failed one stays, for its log. 0: stays until Remove.
        [int]$RemoveWhenDoneSeconds = 0
    )
    $hub = Get-ProgressHub -Owner $Owner
    $view = New-Object ImagingTool.BuildJobView
    $view.Title = $Title
    $view.Summary = 'Starting...'
    $view.SummaryState = 'muted'
    $view.HasLog = [bool]$LogPath
    $rows = New-Object 'Collections.ObjectModel.ObservableCollection[ImagingTool.BuildStepRow]'
    $view.Rows = $rows
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    # Show() returns at once, so the handlers can't see this function's variables: everything they need rides on
    # the timer's Tag, and each job keeps its own.
    $ctx = @{ View = $view; Rows = $rows; ProgressFile = $ProgressFile; Process = $Process; LogPath = $LogPath; Timer = $timer; Started = [DateTime]::UtcNow
        Noun = $Noun; Hidden = [bool]$Hidden; OnFinished = $OnFinished; Window = $hub.Window; RemoveWhenDoneSeconds = $RemoveWhenDoneSeconds; RemoveTimer = $null }
    $timer.Tag = $ctx
    $timer.Add_Tick({ param($sender) Update-BuildProgressWindow $sender.Tag })
    [void]$script:ProgressWindows.Add($ctx)
    $hub.Jobs.Add($view)
    Update-ShowProgressButton

    # Started before the first read, so the count sees it running (a first read that finds it done stops it again).
    $timer.Start()
    Update-ProgressHubCount
    Update-BuildProgressWindow $ctx
    Show-ProgressWindows
    Show-ProgressWindows -Later
    try { $hub.B.ScrollJobs.ScrollToEnd() } catch { }
}

function Invoke-ProgressJobButton {
    # A card's button: Open log or Remove (a finished job only).
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Action)
    switch ($Action) {
        'log' { if ($Ctx.LogPath -and (Test-Path -LiteralPath $Ctx.LogPath)) { Start-Process notepad.exe -ArgumentList "`"$($Ctx.LogPath)`"" } }
        'remove' { Remove-ProgressJob -Ctx $Ctx }
    }
}

function Remove-ProgressJob {
    # Takes a finished job off the window; the window closes when nothing is left.
    param([Parameter(Mandatory)]$Ctx)
    if ($Ctx.Timer.IsEnabled -or -not $script:ProgressWindows.Contains($Ctx)) { return }
    if ($Ctx.RemoveTimer) { $Ctx.RemoveTimer.Stop() }
    $script:ProgressWindows.Remove($Ctx)
    $hub = $script:ProgressHub
    if ($hub) {
        [void]$hub.Jobs.Remove($Ctx.View)
        if (-not $hub.Jobs.Count) { $hub.Window.Close() } else { Update-ProgressHubCount }
    }
    Update-ShowProgressButton
}

function Test-ProgressWindowKeep {
    # True when closing the Progress window should only hide it: some work still runs and the console stays open.
    if ($script:ConsoleClosing) { return $false }
    [bool](@($script:ProgressWindows | Where-Object { $_.Timer -and $_.Timer.IsEnabled }).Count)
}

function Update-ProgressHubCount {
    # "2 running, 1 finished" next to the window's title.
    $hub = $script:ProgressHub
    if (-not $hub) { return }
    $running = @($script:ProgressWindows | Where-Object { $_.Timer.IsEnabled }).Count
    $done = $script:ProgressWindows.Count - $running
    $parts = @()
    if ($running) { $parts += "$running running" }
    if ($done) { $parts += "$done finished" }
    $hub.B.TxtCount.Text = $parts -join ', '
}

function Update-ShowProgressButton {
    # The header's Show progress button: shown while the Progress window has anything on it, open or hidden.
    $btn = if ($script:ui) { $script:ui.BtnShowProgress } else { $null }
    if (-not $btn) { return }
    $n = $script:ProgressWindows.Count
    $btn.Visibility = if ($n) { 'Visible' } else { 'Collapsed' }
    $btn.Content = if ($n -gt 1) { "Show progress ($n)" } else { 'Show progress' }
}

function Show-ProgressWindows {
    # Brings back the Progress window, hidden, minimized, off screen or behind the console.
    param([switch]$Later)
    $hub = $script:ProgressHub
    if (-not $hub) { return }
    $w = $hub.Window
    if ($Later) {
        # Again once the click that started the job is over: a wizard or dialog closing after it hands the focus
        # back to the console, which would cover the window just shown.
        [void]$w.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{ Show-ProgressWindows })
        return
    }
    try {
        if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
        if (-not $w.IsVisible) { $w.Show() }
        Move-WindowOnScreen $w
        # Topmost for a moment puts it over the console even when Windows refuses to hand over the focus.
        $w.Topmost = $true
        [void]$w.Activate()
        $w.Topmost = $false
    } catch { }
}

function Move-WindowOnScreen {
    # Centres a window on the main screen's work area when less than 100 pixels of it are on any screen.
    param([Parameter(Mandatory)]$Window)
    $v = [Windows.SystemParameters]
    $left = [double]$Window.Left; $top = [double]$Window.Top
    $w = [math]::Max([double]$Window.ActualWidth, [double]$Window.Width)
    $h = [math]::Max([double]$Window.ActualHeight, [double]$Window.Height)
    if ([double]::IsNaN($left) -or [double]::IsNaN($top) -or [double]::IsNaN($w) -or [double]::IsNaN($h)) { return }
    $visibleW = [math]::Min($left + $w, $v::VirtualScreenLeft + $v::VirtualScreenWidth) - [math]::Max($left, $v::VirtualScreenLeft)
    $visibleH = [math]::Min($top + $h, $v::VirtualScreenTop + $v::VirtualScreenHeight) - [math]::Max($top, $v::VirtualScreenTop)
    if ($visibleW -ge 100 -and $visibleH -ge 40) { return }
    $area = $v::WorkArea
    $Window.Width = [math]::Min($w, $area.Width); $Window.Height = [math]::Min($h, $area.Height)
    $Window.Left = $area.Left + ($area.Width - $Window.Width) / 2
    $Window.Top = $area.Top + ($area.Height - $Window.Height) / 2
}

function Close-ProgressHub {
    # The console is closing: the Progress window goes with it (it has no owner to take it along).
    $hub = $script:ProgressHub
    if ($hub) { try { $hub.Window.Close() } catch { } }
}

function Invoke-BuildFinished {
    # The OnFinished callback, once; a failure in it must not break the progress window.
    param($Ctx)
    if ($Ctx.FinishedRan -or -not $Ctx.OnFinished) { return }
    $Ctx.FinishedRan = $true
    try { & $Ctx.OnFinished } catch { }
}

function Stop-ProgressJob {
    # The job is over (done, failed or its process gone): stop reading, offer Remove, run OnFinished. A job that
    # worked and has RemoveWhenDoneSeconds takes its card off after that long.
    param([Parameter(Mandatory)]$Ctx)
    $Ctx.Timer.Stop()
    $Ctx.View.Finished = $true
    Update-ProgressHubCount
    if ($Ctx.RemoveWhenDoneSeconds -gt 0 -and $Ctx.View.SummaryState -eq 'success' -and -not $Ctx.RemoveTimer) {
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds($Ctx.RemoveWhenDoneSeconds)
        $t.Tag = $Ctx
        $t.Add_Tick({ param($sender) $sender.Stop(); Remove-ProgressJob -Ctx $sender.Tag })
        $Ctx.RemoveTimer = $t
        $t.Start()
    }
    Invoke-BuildFinished $Ctx
}

function Update-BuildProgressWindow {
    # One timer tick for one job: read its progress file and redraw what changed on its card.
    param([Parameter(Mandatory)]$Ctx)
    $v = $Ctx.View
    $proc = $Ctx.Process
    try {
        $data = Read-BuildProgress -Path $Ctx.ProgressFile
        if (-not $data) {
            # Nothing yet: the job is still starting, or it stopped before its first line (a bad parameter).
            $gone = $proc -and $proc.HasExited
            $n = $Ctx.Noun
            $v.Summary = if ($gone) { $(if ($Ctx.Hidden) { "The $n stopped before it started. Click Open log to see why." } else { "The $n window closed before the $n started." }) }
                elseif (([DateTime]::UtcNow - $Ctx.Started).TotalSeconds -gt 60) { $(if ($Ctx.Hidden) { "The $n has not started. Click Open log to see why." } else { ("The $n has not started. Click Open log, or open its PowerShell window on the taskbar, to see why.") }) }
                else { 'Starting...' }
            if ($gone) { $v.SummaryState = 'error'; Stop-ProgressJob $Ctx }
            return
        }
        $view = Get-BuildStepView -Data $data
        $v.Elapsed = $view.Elapsed
        $v.Summary = $view.Summary
        $v.SummaryState = if ($view.Failed) { 'error' } elseif ($view.Finished) { 'success' } else { 'muted' }
        Update-BuildStepRows -Target $Ctx.Rows -Rows @($view.Rows)
        if ($view.Finished) {
            Stop-ProgressJob $Ctx
        } elseif ($proc -and $proc.HasExited) {
            $v.Summary = if ($Ctx.Hidden) { "The $($Ctx.Noun) stopped before the end. Click Open log to see why." } else { "The $($Ctx.Noun) window was closed before the $($Ctx.Noun) finished." }
            $v.SummaryState = 'error'
            Stop-ProgressJob $Ctx
        }
    } catch { $v.Summary = "Can't read the progress: $($_.Exception.Message)" }
}
