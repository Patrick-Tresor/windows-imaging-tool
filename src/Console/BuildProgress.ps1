# Build progress window: one row per media build step (name, elapsed time, bar, Complete), read twice a second
# from the progress file New-DeploymentMedia.ps1 writes (src\BuildSteps.psm1). Dot-sourced by ImagingConsole.ps1.
# Not modal: the console stays usable, and closing the window leaves the build running in its own window.

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
}
'@
}

$script:BuildWindowNative = @'
using System;
using System.Runtime.InteropServices;
namespace ImagingTool {
    public static class BuildWindow {
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
'@

function ConvertTo-BuildBrush([string]$Color) { [Windows.Media.BrushConverter]::new().ConvertFromString($Color) }

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

function Show-BuildProgress {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ProgressFile,
        [string]$LogPath,
        # The build's powershell.exe (Start-Process -PassThru), to bring its window up and notice it closing.
        $Process,
        [string]$Title = 'Building media'
    )

    [xml]$bxaml = Get-Content -Raw (Join-Path $PSScriptRoot 'BuildProgress.xaml')
    $dlg = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($bxaml))
    $dlg.Owner = $Owner
    Enable-WheelScrolling $dlg
    $b = @{}
    foreach ($node in $bxaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $b[$name] = $dlg.FindName($name)
    }
    $b.TxtTitle.Text = $Title
    $b.BtnLog.IsEnabled = [bool]$LogPath
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    # Show() returns at once, so the handlers can't see this function's variables: everything they need rides on
    # the timer's and the window's Tag, and each build window keeps its own.
    $rows = New-Object 'Collections.ObjectModel.ObservableCollection[ImagingTool.BuildStepRow]'
    $b.LstSteps.ItemsSource = $rows
    $ctx = @{ B = $b; Rows = $rows; ProgressFile = $ProgressFile; Process = $Process; LogPath = $LogPath; Timer = $timer; Started = [DateTime]::UtcNow }
    $timer.Tag = $ctx
    $dlg.Tag = $ctx
    $timer.Add_Tick({ param($sender) Update-BuildProgressWindow $sender.Tag })
    $b.BtnLog.Add_Click({
        param($sender)
        $c = [Windows.Window]::GetWindow($sender).Tag
        if ($c.LogPath -and (Test-Path -LiteralPath $c.LogPath)) { Start-Process notepad.exe -ArgumentList "`"$($c.LogPath)`"" }
    })
    $b.BtnWindow.Add_Click({
        param($sender)
        try {
            $p = ([Windows.Window]::GetWindow($sender).Tag).Process
            if (-not $p -or $p.HasExited) { return }
            if (-not ('ImagingTool.BuildWindow' -as [type])) { Add-Type -TypeDefinition $script:BuildWindowNative }
            $p.Refresh()
            $h = $p.MainWindowHandle
            if ($h -ne [IntPtr]::Zero) { [void][ImagingTool.BuildWindow]::ShowWindow($h, 9); [void][ImagingTool.BuildWindow]::SetForegroundWindow($h) }   # 9 = SW_RESTORE
        } catch { }
    })
    $b.BtnClose.Add_Click({ param($sender) [Windows.Window]::GetWindow($sender).Close() })
    $dlg.Add_Closed({ param($sender) $sender.Tag.Timer.Stop() })

    Update-BuildProgressWindow $ctx
    $timer.Start()
    $dlg.Show()
}

function Update-BuildProgressWindow {
    # One timer tick: read the progress file and redraw what changed.
    param([Parameter(Mandatory)]$Ctx)
    $b = $Ctx.B
    $proc = $Ctx.Process
    try {
        $data = Read-BuildProgress -Path $Ctx.ProgressFile
        if (-not $data) {
            # Nothing yet: the build is still starting, or it stopped before its first line (a bad parameter).
            $gone = $proc -and $proc.HasExited
            $b.TxtSummary.Text = if ($gone) { 'The build window closed before the build started.' }
                elseif (([DateTime]::UtcNow - $Ctx.Started).TotalSeconds -gt 60) { 'The build has not started. Click Show build window to see why.' }
                else { 'Starting...' }
            if ($gone) { $Ctx.Timer.Stop() }
            return
        }
        $view = Get-BuildStepView -Data $data
        $b.TxtElapsed.Text = $view.Elapsed
        $b.TxtSummary.Text = $view.Summary
        $b.TxtSummary.Foreground = ConvertTo-BuildBrush $(if ($view.Failed) { '#C4314B' } elseif ($view.Finished) { '#2E9E5B' } else { '#5B6170' })
        Update-BuildStepRows -Target $Ctx.Rows -Rows @($view.Rows)
        if ($view.Finished) {
            $Ctx.Timer.Stop()
            if (-not $view.Failed) { $b.BtnClose.Content = 'Done' }
        } elseif ($proc -and $proc.HasExited) {
            $Ctx.Timer.Stop()
            $b.TxtSummary.Text = 'The build window was closed before the build finished.'
            $b.TxtSummary.Foreground = ConvertTo-BuildBrush '#C4314B'
        }
    } catch { $b.TxtSummary.Text = "Can't read the build progress: $($_.Exception.Message)" }
}
