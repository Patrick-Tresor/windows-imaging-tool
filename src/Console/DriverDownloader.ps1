# Driver pack download window. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg and imports
# DriverPacks.psm1. The downloads run hidden through Get-DriverPacks.ps1 so the console stays usable; their progress
# is listed on the Driver Library page (Add-DriverDownloadJob).

# A real .NET type so the check box column binds two-way.
class DriverPackRow {
    [bool]$Selected
    [string]$Model
    [string]$Ids
    [string]$Release
    [string]$Version
    [string]$Released
    [string]$SizeMB
    [string]$Installed
    [object]$Pack
}

function Start-DriverPackDownload {
    # Hands the packs to Get-DriverPacks.ps1 through a job file. It runs hidden, in its own process so the console
    # stays usable, and the console's progress window shows each pack: download percent, time left, then checking,
    # extracting and adding it to the library (Patrick, 2026-11-11: no PowerShell window with the BITS bar).
    # When it ends the driver library refreshes by itself. Also used by the Download from vendor and Unknown Models windows.
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
    ConvertTo-Json -InputObject @($Packs) -Depth 4 | Set-Content -Path $job -Encoding utf8
    $progressFile = Join-Path ([IO.Path]::GetTempPath()) "driverpacks-$stamp-$tag-progress.json"
    $logDir = [IO.Path]::Combine($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }), 'ImagingConsole', 'Logs')
    $logPath = [IO.Path]::Combine($logDir, "driverpacks-$stamp.log")
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (ConvertTo-Arg (Join-Path $SrcDir 'Get-DriverPacks.ps1')),
        '-ContentRoot', (ConvertTo-Arg $ContentRoot), '-JobFile', (ConvertTo-Arg $job),
        '-ProgressFile', (ConvertTo-Arg $progressFile), '-LogPath', (ConvertTo-Arg $logPath))
    if ($KeepDownload) { $runArgs += '-KeepDownload' }
    $proc = Start-Process powershell.exe -ArgumentList $runArgs -WindowStyle Hidden -PassThru
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
        Started = [DateTime]::UtcNow; OnFinished = $OnFinished; Done = $false; FinishedRan = $false }
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

function Complete-DriverDownloadJob {
    # Marks a download finished (OK or failed) and runs OnFinished once: the library refreshes.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Outcome)
    $Ctx.Done = $true
    $Ctx.Row.Outcome = $Outcome
    $Ctx.Row.Finished = $true
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

function Show-DriverDownloader {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir
    )

    [xml]$dxaml = Get-Content -Raw (Join-Path $PSScriptRoot 'DriverDownloader.xaml')
    $dlg = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($dxaml))
    $dlg.Owner = $Owner
    Enable-WheelScrolling $dlg
    $d = @{}
    foreach ($node in $dxaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $d[$name] = $dlg.FindName($name)
    }
    $state = @{ Rows = @(); Started = $false }

    function Show-DownloaderError([string]$Text) {
        [Windows.MessageBox]::Show($dlg, $Text, 'Download Driver Packs', 'OK', 'Warning') | Out-Null
    }

    $updateSelection = {
        $sel = @($state.Rows | Where-Object Selected)
        $mb = ($sel | ForEach-Object { [double]"0$($_.SizeMB)" } | Measure-Object -Sum).Sum
        $d.TxtSelection.Text = '{0} of {1} models selected, {2:N1} GB to download' -f $sel.Count, $state.Rows.Count, ($mb / 1KB)
    }

    $applyFilter = {
        $q = $d.TxtSearch.Text.Trim()
        $d.GridPacks.ItemsSource = @(if ($q) { $state.Rows | Where-Object { $_.Model -like "*$q*" -or $_.Ids -like "*$q*" } } else { $state.Rows })
        & $updateSelection
    }

    $load = {
        param([bool]$Refresh)
        $maker = $d.CmbVendor.SelectedItem.Content
        $dlg.Cursor = 'Wait'
        $d.TxtSelection.Text = "Reading the $maker catalog..."
        $dlg.Dispatcher.Invoke([action]{}, 'Background')   # let the text paint before the download blocks
        try {
            $state.Rows = @(Get-VendorDriverPacks -Maker $maker -Refresh:$Refresh | Add-DriverPackLibraryStatus -ContentRoot $ContentRoot | ForEach-Object {
                $row = [DriverPackRow]::new()
                $row.Model = $_.Model; $row.Release = ("$($_.Os) $($_.Release)" -replace '^Windows ', 'Win').Trim(); $row.Version = $_.Version; $row.Released = $_.Released
                $row.SizeMB = $_.SizeMB; $row.Installed = $_.Installed; $row.Pack = $_
                $row.Ids = (@($_.Skus) + @($_.MachineTypes)) -join ' '
                $row
            })
        } catch {
            $state.Rows = @()
            Show-DownloaderError "Could not read the $maker catalog: $($_.Exception.Message)"
        } finally { $dlg.Cursor = $null }
        & $applyFilter
    }

    $d.CmbVendor.Add_SelectionChanged({ & $load $false })
    $d.BtnReload.Add_Click({ & $load $true })
    $d.TxtSearch.Add_TextChanged({ & $applyFilter })
    # Check box clicks change Selected on the row; refresh the count when they do.
    $d.GridPacks.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{ & $updateSelection })

    $d.BtnSelectUpdates.Add_Click({
        foreach ($r in $state.Rows) { if ($r.Installed -like 'Update*') { $r.Selected = $true } }
        $d.GridPacks.Items.Refresh(); & $updateSelection
    })
    $d.BtnClearSelection.Add_Click({
        foreach ($r in $state.Rows) { $r.Selected = $false }
        $d.GridPacks.Items.Refresh(); & $updateSelection
    })

    $d.BtnDownload.Add_Click({
        try {
            $packs = @($state.Rows | Where-Object Selected | ForEach-Object Pack)
            if (-not $packs) { Show-DownloaderError 'Tick at least one model.'; return }
            Start-DriverPackDownload -Packs $packs -ContentRoot $ContentRoot -SrcDir $SrcDir -Owner $Owner -KeepDownload:$d.ChkKeep.IsChecked
            $state.Started = $true
            $dlg.Close()
        } catch { Show-DownloaderError $_.Exception.Message }
    })
    $d.BtnClose.Add_Click({ $dlg.Close() })

    $dlg.Add_ContentRendered({ & $load $false })
    [void]$dlg.ShowDialog()
    $state.Started
}
