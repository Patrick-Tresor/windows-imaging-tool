<#
.SYNOPSIS
    Admin console for the imaging tool: images, answer files, applications, driver library, media builder,
    deploy settings, dashboard and logs.
.DESCRIPTION
    Run on a Windows admin PC. Relaunches itself elevated and in STA mode, which WPF and DISM need.
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\src\Console\ImagingConsole.ps1
#>
[CmdletBinding()]
param(
    # Hide this PowerShell's black console window, so only the console's own window shows (ImagingConsole.cmd).
    [switch]$HideConsole
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    # The elevated copy runs hidden too: started from a PowerShell prompt, it still opens its own console window.
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-HideConsole')
    return
}

if ($HideConsole) {
    # -WindowStyle Hidden can leave the window up for a moment, or for good when it was opened another way (the .cmd
    # run as administrator from an older copy, a shortcut); hiding it here catches those. Tools the console runs
    # inline (cmd /c, winget, dism) share this hidden window, so they don't flash one either.
    try {
        Add-Type -Namespace ImagingTool -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        $h = [ImagingTool.ConsoleWindow]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][ImagingTool.ConsoleWindow]::ShowWindow($h, 0) }   # 0 = SW_HIDE
    } catch { }
}

# The console runs inside powershell.exe, so Windows grouped it under PowerShell on the taskbar and showed
# PowerShell's icon. Its own app ID, set before any window opens, gives it a taskbar button of its own that shows
# the window's icon (the logo, Set-ConsoleLogo in XamlWindow.psm1).
try {
    Add-Type -Namespace ImagingTool -Name AppId -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
'@
    [void][ImagingTool.AppId]::SetCurrentProcessExplicitAppUserModelID('ImagingTool.ImagingConsole')
} catch { }

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# With the console window hidden, an error that stops the console before (or after) its window opens would leave
# nothing on screen. Show it in a message box and keep it in %LOCALAPPDATA%\ImagingConsole\console-error.log, with
# every inner exception (type, message, .NET stack) and the PowerShell stack, so the real cause is in the log and
# not only the line that opened the window.
function Write-ConsoleErrorLog($ErrorRecord) {
    $log = [IO.Path]::Combine($env:LOCALAPPDATA, 'ImagingConsole', 'console-error.log')
    $nl = [Environment]::NewLine
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $ErrorRecord.Exception.Message))
    $where = "$($ErrorRecord.InvocationInfo.PositionMessage)"
    if ($where) { $lines.Add($where) }
    $ex = $ErrorRecord.Exception; $depth = 0
    while ($ex -and $depth -lt 10) {
        $lines.Add(('{0}{1}: {2}' -f ('  ' * $depth), $ex.GetType().FullName, $ex.Message))
        if ($ex.ErrorRecord -and $ex.ErrorRecord.InvocationInfo -and $ex.ErrorRecord -ne $ErrorRecord) {
            $lines.Add("$($ex.ErrorRecord.InvocationInfo.PositionMessage)")
        }
        if ($ex.StackTrace) { $lines.Add("$($ex.StackTrace)") }
        $ex = $ex.InnerException; $depth++
    }
    if ($ErrorRecord.ScriptStackTrace) { $lines.Add('PowerShell stack:'); $lines.Add("$($ErrorRecord.ScriptStackTrace)") }
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($log))
        [IO.File]::AppendAllText($log, (($lines -join $nl) + $nl + $nl))
    } catch { }
    $log
}
trap {
    $msg = "$($_.Exception.Message)"
    $log = Write-ConsoleErrorLog $_
    try { [void][Windows.MessageBox]::Show("The imaging console stopped: $msg`n`nDetails: $log", 'Imaging Console', 'OK', 'Error') } catch { }
    break
}
$srcDir = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ConsoleData.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WheelScroll.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'XamlWindow.psm1') -Force
Import-Module (Join-Path $srcDir 'AnswerFile.psm1') -Force
Import-Module (Join-Path $srcDir 'JsonFile.psm1') -Force
Import-Module (Join-Path $srcDir 'ImageVersions.psm1') -Force
Import-Module (Join-Path $srcDir 'AdkCheck.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DriverPacks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DriverReport.psm1') -Force
Import-Module (Join-Path $srcDir 'DeployStatus.psm1') -Force
Import-Module (Join-Path $srcDir 'AppPack.psm1') -Force
Import-Module (Join-Path $srcDir 'TaskPack.psm1') -Force
Import-Module (Join-Path $srcDir 'VMwareVM.psm1') -Force
Import-Module (Join-Path $srcDir 'CaptureCheck.psm1') -Force
Import-Module (Join-Path $srcDir 'Format.psm1') -Force
Import-Module (Join-Path $srcDir 'MediaContent.psm1') -Force
Import-Module (Join-Path $srcDir 'BuildSteps.psm1') -Force
Import-Module (Join-Path $srcDir 'ActiveDirectory.psm1') -Force
Import-Module (Join-Path $srcDir 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $srcDir 'ImagingAgent.psm1') -Force
Import-Module (Join-Path $srcDir 'ToolVersion.psm1') -Force
. (Join-Path $PSScriptRoot 'CaptureWizard.ps1')
. (Join-Path $PSScriptRoot 'AnswerEditor.ps1')
. (Join-Path $PSScriptRoot 'ImageVersions.ps1')
. (Join-Path $PSScriptRoot 'UpdateImage.ps1')
. (Join-Path $PSScriptRoot 'DriverDownloader.ps1')
. (Join-Path $PSScriptRoot 'AppPackEditor.ps1')
. (Join-Path $PSScriptRoot 'TaskEditor.ps1')
. (Join-Path $PSScriptRoot 'BuildProgress.ps1')

# A real .NET type so the editable grid can add rows and bind two-way.
class DriverRow {
    [string]$Maker
    [string]$Model
    [string]$Sku
    [string]$MachineType
    [string]$ModelPattern
    [string]$Path
    [string]$Status
}

$form = New-ConsoleWindow 'MainWindow.xaml'
$window = $form.Window
$ui = $form.Controls

# This copy's version in the header; a stick built with an older one gets a banner (Update-StickVersionBanner).
$script:toolVersion = Get-ToolVersion -SourceRoot $srcDir
$ui.TxtToolVersion.Text = if ($script:toolVersion.Release) { $script:toolVersion.Release } else { "version $($script:toolVersion.Text)" }
$script:stickOldHidden = ''

$config = Get-ConsoleConfig
$script:root = $config.contentRoot
$script:drivers = [Collections.ObjectModel.ObservableCollection[DriverRow]]::new()

#region Helpers

function Set-Status([string]$Text) { $ui.TxtStatus.Text = $Text }

function Show-Error([string]$Text) {
    Set-Status "Error: $Text"
    [Windows.MessageBox]::Show($window, $Text, 'Imaging Console', 'OK', 'Error') | Out-Null
}

function Confirm-Action([string]$Text) {
    [Windows.MessageBox]::Show($window, $Text, 'Imaging Console', 'YesNo', 'Warning') -eq 'Yes'
}

function Select-Folder([string]$Description) {
    $dlg = [Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = $Description
    if ($dlg.ShowDialog() -eq 'OK') { $dlg.SelectedPath }
}

function ConvertTo-Arg([string]$Value) {
    # Quotes a path for a command line; a trailing backslash (E:\) must be doubled or it escapes the quote.
    '"' + ($Value -replace '\\$', '\\') + '"'
}

function Invoke-Safely([scriptblock]$Action) {
    # Every button runs through here so one failure shows a message instead of closing the console.
    try { & $Action } catch { Show-Error $_.Exception.Message }
}

function Test-RootReady {
    if (Test-ContentRoot $script:root) { return $true }
    Show-Error 'Choose a content root first (Browse...).'
    $false
}

#endregion

#region Loaders

function Update-Images {
    if (-not (Test-ContentRoot $script:root)) { $ui.GridImages.ItemsSource = $null; return }
    $usage = Get-ImageUsage -ContentRoot $script:root
    $ui.GridImages.ItemsSource = @(Get-ImageList -ContentRoot $script:root | ForEach-Object {
        $_ | Add-Member -NotePropertyName UsedBy -NotePropertyValue ($(if ($usage.ContainsKey($_.Name)) { $usage[$_.Name] -join ', ' } else { '' })) -PassThru
    })
}

function Update-Answers {
    # @() outside the if: an if statement unrolls its output, so one answer file would come back as a lone object.
    $rows = @(if (Test-ContentRoot $script:root) { Get-AnswerFileRows -ContentRoot $script:root })
    $ui.GridAnswers.ItemsSource = $rows
    $ui.TxtAnswerIssues.Text = ''
    Update-MediaAnswers
    Update-ScanTip
}

function Update-ScanTip {
    # Defender exclusions for the build folders: the console adds them itself (Add-ScanExclusions.ps1, hidden, once
    # per set of folders) and the Media tab's tip shows only when Windows refused, with the folders to add by hand.
    $root = if (Test-ContentRoot $script:root) { $script:root } else { '' }
    $todo = @(Get-ScanExclusionTodo -ContentRoot $root)
    $key = $todo -join '|'
    $show = $false
    if ($todo.Count -and -not $script:scanRun) {
        if ($script:scanTriedKey -ne $key) { $script:scanTriedKey = $key; Start-ScanExclusions $todo }
        else { $show = $true }
    }
    $tip = if ($show) { Get-ScanExclusionTip -ContentRoot $root -Reason $script:scanFailReason }
    $ui.BdrScanTip.Visibility = if ($tip) { 'Visible' } else { 'Collapsed' }
    $ui.TxtScanTip.Text = if ($tip) { $tip.Text } else { '' }
}

function Start-ScanExclusions([string[]]$Folders) {
    $id = [guid]::NewGuid().ToString('N')
    $logDir = [IO.Path]::Combine($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }), 'ImagingConsole', 'Logs')
    $run = @{ Folders = $Folders; ResultPath = [IO.Path]::Combine($env:TEMP, "scan-exclusions-$id.json")
        LogPath = [IO.Path]::Combine($logDir, 'defender-exclusions.log'); Started = Get-Date; Proc = $null }
    try {
        $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg (Join-Path $srcDir 'Add-ScanExclusions.ps1')),
            '-Folder', (ConvertTo-Arg ($Folders -join '|')), '-ResultPath', (ConvertTo-Arg $run.ResultPath), '-LogPath', (ConvertTo-Arg $run.LogPath))
        $run.Proc = Start-Process powershell.exe -ArgumentList $runArgs -WindowStyle Hidden -PassThru
        $null = $run.Proc.Handle   # PowerShell 5.1 only keeps HasExited if the handle was read
        $script:scanRun = $run
        $script:scanTimer.Start()
    } catch { $script:scanFailReason = 'the helper script could not start (Defender may have blocked it)' }
}

function Complete-ScanExclusions {
    $run = $script:scanRun
    if (-not $run) { $script:scanTimer.Stop(); return }
    if (-not $run.Proc.HasExited) {
        if (((Get-Date) - $run.Started).TotalMinutes -lt 2) { return }
        try { $run.Proc.Kill() } catch { }
    }
    $script:scanTimer.Stop()
    $script:scanRun = $null
    $r = Read-ScanExclusionResult -Path $run.ResultPath
    try { [IO.File]::Delete($run.ResultPath) } catch { }
    if ($r.Ok) {
        $script:scanFailReason = $null
        Save-ConsoleConfig (Add-ScanExclusionsDone -Config (Get-ConsoleConfig) -Folders $run.Folders)
        if (@($r.Added).Count) { Set-Status 'Microsoft Defender now skips the build folders, so builds and captures are faster.' }
    }
    else { $script:scanFailReason = "$($r.Message)" }
    Update-ScanTip
}

$script:scanRun = $null
$script:scanTriedKey = ''
$script:scanFailReason = $null
$script:scanTimer = [Windows.Threading.DispatcherTimer]::new()
$script:scanTimer.Interval = [timespan]::FromSeconds(1)
$script:scanTimer.Add_Tick({ try { Complete-ScanExclusions } catch { $script:scanTimer.Stop(); $script:scanRun = $null; Set-Status "Defender exclusions: $($_.Exception.Message)" } })

function Update-MediaPacks {
    # The Media tab's driver pack list: keeps what was unchecked, checks packs that are new since last time.
    $old = @{}
    foreach ($i in @($ui.LstMediaPacks.Items)) { $old[$i.Path] = $ui.LstMediaPacks.SelectedItems.Contains($i) }
    $packs = @(if (Test-ContentRoot $script:root) { Get-MediaDriverPacks -ContentRoot $script:root })
    $ui.LstMediaPacks.ItemsSource = $packs
    foreach ($p in $packs) {
        if (-not $old.ContainsKey($p.Path) -or $old[$p.Path]) { [void]$ui.LstMediaPacks.SelectedItems.Add($p) }
    }
    Update-MediaPackTotal
}

function Update-MediaPackTotal {
    $all = @($ui.LstMediaPacks.Items)
    $picked = @($ui.LstMediaPacks.SelectedItems)
    $size = [int64](($picked | Measure-Object Size -Sum).Sum)
    $ui.TxtMediaPacks.Text = if (-not $all) { 'No driver packs in the catalog yet.' }
                             else { '{0} of {1} packs, {2:N1} GB' -f $picked.Count, $all.Count, ($size / 1GB) }
}

function Update-MediaAnswers {
    # The Media tab's answer file list: keeps what was unchecked, checks answer files that are new since last time.
    $old = @{}
    foreach ($i in @($ui.LstMediaAnswers.Items)) { $old[$i.Name] = $ui.LstMediaAnswers.SelectedItems.Contains($i) }
    $choices = @(if (Test-ContentRoot $script:root) { Get-MediaAnswerChoices -ContentRoot $script:root })
    $ui.LstMediaAnswers.ItemsSource = $choices
    foreach ($c in $choices) {
        if (-not $old.ContainsKey($c.Name) -or $old[$c.Name]) { [void]$ui.LstMediaAnswers.SelectedItems.Add($c) }
    }
}

function Update-Drivers {
    $script:driversEdited = $false
    $script:drivers.Clear()
    if (Test-ContentRoot $script:root) {
        # The example rows new content roots used to get (Latitude 5440, EliteBook 840 G9...): gone unless they hold drivers.
        try { $gone = Remove-SampleDriverEntries -ContentRoot $script:root; if ($gone) { Set-Status "Removed $gone example rows from the driver library" } } catch { }
        # Lenovo rows keyed on the SystemSKU text (older Unknown models report): merged into the model's own row.
        try { $merged = Merge-LenovoSkuEntries -ContentRoot $script:root; if ($merged) { Set-Status "Merged $merged duplicate Lenovo row(s) in the driver library" } } catch { }
        foreach ($r in Get-DriverCatalogRows -ContentRoot $script:root) {
            $row = [DriverRow]::new()
            foreach ($p in 'Maker', 'Model', 'Sku', 'MachineType', 'ModelPattern', 'Path', 'Status') { $row.$p = $r.$p }
            $script:drivers.Add($row)
        }
    }
    $ui.GridDrivers.ItemsSource = $script:drivers
    Update-MediaPacks
    # Models deployed without their driver pack, above the library; hidden when every deployed PC got its pack.
    $unknown = @()
    if (Test-ContentRoot $script:root) { try { $unknown = @(Get-UnknownModels -ContentRoot $script:root) } catch { } }
    $ui.GridUnknown.ItemsSource = $unknown
    $pcs = ($unknown | Measure-Object PCs -Sum).Sum
    $ui.TxtUnknown.Text = "$($unknown.Count) model(s) on $pcs PC(s) deployed without their driver pack. Select one and click Find its pack, then Download."
    $ui.BdrUnknown.Visibility = if ($unknown) { 'Visible' } else { 'Collapsed' }
}

function Update-Settings {
    if (-not (Test-ContentRoot $script:root)) { return }
    $s = Get-DeploySettings -ContentRoot $script:root
    $v = Get-DeploySettingsView -ContentRoot $script:root
    $ui.TxtSharePath.Text = $v.SharePath
    $ui.TxtShareUser.Text = $v.ShareUser
    $ui.PwdShare.Password = ''
    $script:sharePwSaved = $v.PasswordSaved
    $ui.TxtShareTest.Text = ''
    $ui.TxtSettingsProblem.Text = ''
    $c = if ($s.PSObject.Properties['checks'] -and $s.checks) { $s.checks } else { [pscustomobject]@{} }
    $get = { param($name, $default) if ($c.PSObject.Properties[$name] -and "$($c.$name)" -ne '') { $c.$name } else { $default } }
    $ui.TxtCheckIgnore.Text = @(& $get 'ignoreDevices' @()) -join '; '
    $ui.TxtAdServer.Text = "$((Get-AdSettings).server)"
    Update-SettingsState
}

function Update-SettingsState {
    # Greys out the account without a share, and says whether the share password is saved.
    $share = [bool]$ui.TxtSharePath.Text.Trim()
    $ui.PnlShareAccount.IsEnabled = $share
    $ui.PnlShareAccount.Opacity = if ($share) { 1 } else { 0.5 }
    $ui.TxtSharePwState.Text = if ($ui.PwdShare.Password) { 'New password, saved when you click Save.' }
                               elseif ($script:sharePwSaved) { 'Password saved.' }
                               elseif ($ui.TxtShareUser.Text.Trim()) { 'No password saved yet.' }
                               else { '' }
}

function Get-DashboardFolder {
    if (-not (Test-ContentRoot $script:root)) { return $null }
    Get-StatusFolder -ContentRoot $script:root -Settings (Get-DeploySettings -ContentRoot $script:root)
}

function Import-StickDashboard([string]$Folder) {
    # PCs deployed from a USB stick with no network folder to report to left their status on the stick: move it into
    # the dashboard whenever a DEPLOY stick is plugged into this PC. Never fails the refresh.
    $n = 0
    foreach ($stick in Get-DeployStickRoots) {
        try { $n += Import-StickDeployStatus -StickRoot $stick -Folder $Folder -LogFolder (Join-Path $script:root 'Logs') }
        catch { Set-Status "Could not read the deployments on the USB stick $stick : $($_.Exception.Message)" }
    }
    if ($n) {
        Set-Status "Added $n deployment(s) from the USB stick to the dashboard"
    }
}

$script:agentCache = $null
function Get-ConsoleAgentCheckIns {
    # Every agent's last check-in (Status\Agents on the share); none when it can't be read. Read again at most every
    # 30 seconds: the Dashboard refreshes often, and the agents check in every few minutes.
    $folder = Get-DashboardFolder
    if (-not $folder) { return @() }
    $c = $script:agentCache
    if ($c -and $c.Folder -eq $folder -and ((Get-Date) - $c.At).TotalSeconds -lt 30) { return $c.Rows }
    $rows = try { @(Get-AgentCheckIns -StatusFolder $folder) } catch { @() }
    $script:agentCache = [pscustomobject]@{ Folder = $folder; At = Get-Date; Rows = $rows }
    $rows
}

# The agent the console has (Get-AgentCodeHash of src): an online agent with other code gets it as a signed update
# job, once per PC while the console runs (Send-AgentUpdates, from the Computers tab and the Dashboard).
$script:agentCode = try { Get-AgentCodeHash -Folder $srcDir } catch { '' }
$script:agentUpdatesSent = @{}
function Send-AgentUpdates([object[]]$CheckIns) {
    # Never fails the page: an update that can't go now is tried at the next refresh (or the next console start).
    try {
        if (-not $script:agentCode -or -not (Test-ContentRoot $script:root)) { return }
        $todo = @(Select-AgentsToUpdate -CheckIns @($CheckIns) -CurrentCode $script:agentCode -Sent $script:agentUpdatesSent)
        if (-not $todo) { return }
        $folder = Get-DashboardFolder
        $key = Get-AgentSigningKey -ContentRoot $script:root
        if (-not $folder -or -not $key) { return }
        foreach ($a in $todo) {
            # A job already waiting for this PC (a reimage, apps) is left alone: the update goes after it.
            if ([IO.File]::Exists([IO.Path]::Combine((Get-AgentJobFolder -StatusFolder $folder -Serial "$($a.serial)"), 'job.json'))) { continue }
            $script:agentUpdatesSent["$($a.serial)"] = $script:agentCode
            try {
                $null = New-AgentJob -StatusFolder $folder -PrivateKey $key -CheckIn $a -Action update -SourceDir $srcDir -Message 'Agent update'
                Set-Status "Sent $($a.computerName) the new agent ($script:agentCode)."
            } catch { Set-Status "Could not send $($a.computerName) the new agent: $($_.Exception.Message)" }
        }
    } catch { }
}

$script:dashFilter = 'All'   # All, Running, Succeeded, Warning, Attention or History (the count boxes)
function Update-Dashboard {
    $folder = Get-DashboardFolder
    if ($folder) { Import-StickDashboard $folder }
    $rows = @(if ($folder) { Get-DeploymentStatus -Folder $folder })
    # Finished more than 7 days ago: off the Dashboard by itself, the final log stays under History.
    $expired = @(Get-ExpiredDeployments -Rows $rows)
    if ($expired) {
        Remove-DeploymentStatus -Rows $expired
        $rows = @($rows | Where-Object { $expired -notcontains $_ })
    }
    $sum = Get-DeploymentSummary -Rows $rows
    $ui.TxtDashRunning.Text   = $sum.Running
    $ui.TxtDashSucceeded.Text = $sum.Succeeded
    $ui.TxtDashWarning.Text   = $sum.Warning
    $ui.TxtDashFailed.Text    = $sum.Failed
    $ui.TxtDashTotal.Text     = $sum.Total

    # Notices for PCs that finished or failed since the last read (also on other tabs: see the timer below).
    Show-DashboardNotices -Rows $rows

    $filter = $script:dashFilter
    if ($filter -eq 'History') {
        # Deployments removed or cleared from the Dashboard, from their final log in Logs\.
        $onDash = @($rows | ForEach-Object LogFile)
        $rows = @(if (Test-ContentRoot $script:root) { Get-DeploymentHistoryRows -ContentRoot $script:root -DashboardLogFiles $onDash })
    } else {
        $states = @(Get-DashboardFilterStates $filter)
        if ($states) { $rows = @($rows | Where-Object State -in $states) }
    }
    Update-DashboardCards
    $ui.TxtDashShowing.Text = switch ($filter) {
        'History'   { 'Showing: history (deployments removed or cleared from here). Click a box to go back.' }
        'Running'   { 'Showing: deploying now' }
        'Succeeded' { 'Showing: ready' }
        'Warning'   { 'Showing: ready, with warnings' }
        'Attention' { 'Showing: failed, stalled or not ready' }
        default     { '' }
    }

    # One Last seen: the agent's last check-in (by serial) when it is newer than the deployment's last report,
    # otherwise that report; and the address the agent has now.
    $checkIns = Get-ConsoleAgentCheckIns
    Send-AgentUpdates $checkIns
    # Agents gone quiet for over a day: a reimage or Retry failed apps would not reach those PCs.
    $silent = @(Get-SilentAgents -CheckIns @($checkIns))
    $ui.TxtDashAgents.Text = if ($silent) {
        $names = @($silent | Select-Object -First 6 | ForEach-Object { "$($_.computerName) ($("$($_.LastSeenText)".ToLowerInvariant()))" })
        "$($silent.Count) agent(s) have not checked in for over a day: $($names -join ', ')$(if ($silent.Count -gt 6) { ', ...' }). The PC is off or its agent stopped."
    } else { '' }
    $ui.TxtDashAgents.Visibility = if ($silent) { 'Visible' } else { 'Collapsed' }
    foreach ($r in $rows) {
        $a = if ($checkIns -and $r.Serial) { Find-AgentCheckIn -CheckIns $checkIns -Serial "$($r.Serial)" } else { $null }
        $seen = if ($a -and $a.LastSeen -and (-not $r.Updated -or $a.LastSeen -gt $r.Updated)) { $a.LastSeenText }
                elseif ($r.Updated) { Format-AgentLastSeen -LastSeen $r.Updated } else { '' }
        $r | Add-Member -NotePropertyName LastSeenText -NotePropertyValue $seen -Force
        if ($a -and $a.Online -and $a.ipAddress) { $r | Add-Member -NotePropertyName IpAddress -NotePropertyValue "$($a.ipAddress)" -Force }
        $r | Add-Member -NotePropertyName Agent -NotePropertyValue $a -Force
        # The Status column: the step while it deploys, the state once it ends; the tooltip has both and the percent.
        $step = "$(if ($r.PSObject.Properties['Step']) { $r.Step })"
        $text = switch ("$($r.State)") { 'Running' { $step } 'Stalled' { "Stalled: $step" } default { "$($r.State)" } }
        $r | Add-Member -NotePropertyName StatusText -NotePropertyValue $text -Force
        $r | Add-Member -NotePropertyName StatusTip -NotePropertyValue ("$($r.State): $step ($($r.Percent) %)".Replace(':  (', ': (')) -Force
    }

    # Keep the selected PC selected across refreshes.
    $selectedId = if ($ui.GridDash.SelectedItem) { $ui.GridDash.SelectedItem.Id } else { $null }
    $ui.GridDash.ItemsSource = $rows
    if ($selectedId) { $ui.GridDash.SelectedItem = $rows | Where-Object Id -eq $selectedId | Select-Object -First 1 }
    Update-DashboardDetail
}

function Get-DashboardFilterStates([string]$Filter) {
    switch ($Filter) {
        'Running'   { 'Running' }
        'Succeeded' { 'Succeeded' }
        'Warning'   { 'Warning' }
        'Attention' { 'Failed', 'Stalled', 'Not ready' }
    }
}

function Update-DashboardCards {
    # The count box that filters the list now is outlined in the accent colour.
    foreach ($card in $ui.CardDashRunning, $ui.CardDashSucceeded, $ui.CardDashWarning, $ui.CardDashFailed, $ui.CardDashTotal) {
        $on = "$($card.Tag)" -eq $script:dashFilter
        if ($on) {
            $card.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'AccentBrush')
            $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'AccentSoftBrush')
        } else {
            $card.ClearValue([Windows.Controls.Border]::BorderBrushProperty)
            $card.ClearValue([Windows.Controls.Border]::BackgroundProperty)
        }
    }
}

function Update-DashboardDetail {
    $r = $ui.GridDash.SelectedItem
    $history = $r -and $r.PSObject.Properties['IsHistory']
    $live = $r -and -not $history
    $ui.BtnDashLog.IsEnabled = [bool]($r -and $r.LogPath)
    $ui.BtnDashReimage.IsEnabled = [bool]($live -and $r.ComputerName -and $r.State -ne 'Running')
    $failed = @(if ($live) { Get-FailedApps -Row $r })
    $ui.BtnDashRetry.IsEnabled = [bool]($failed -and $r.State -notin 'Running', 'Stalled')
    $ui.BtnDashRetry.Content = if ($failed.Count -eq 1) { "Retry $($failed[0])" } else { 'Retry failed apps' }
    if (-not $r) {
        $ui.TxtDashVerdict.Text = 'Select a PC to see its details.'; $ui.TxtDashInfo.Text = ''
        $ui.LstDashChecks.ItemsSource = $null; $ui.TxtDashLog.Text = ''; return
    }
    if ($history) {
        $ui.TxtDashVerdict.Text = "Final log of $($r.Serial), $($r.State), $($r.Started.ToString('yyyy-MM-dd HH:mm'))"
        $ui.TxtDashInfo.Text = ''
        $ui.LstDashChecks.ItemsSource = $null
        Set-DashboardLogVisible $true
    } else {
        $name = (@($r.ComputerName, $(if ($r.Model) { "($($r.Model))" })) | Where-Object { $_ }) -join ' '
        $ui.TxtDashVerdict.Text = (@($name, $(if ($r.Result) { $r.Result } else { $r.StatusText })) | Where-Object { $_ }) -join ' - '
        $info = @()
        if ($r.Serial)     { $info += "Serial $($r.Serial)" }
        if ($r.AnswerFile) { $info += "Answer file $($r.AnswerFile)" }
        if ($r.MacAddress) { $info += "MAC $($r.MacAddress)" }
        if ($r.Phase)      { $info += "Phase $($r.Phase)" }
        if ($r.Updated)    { $info += "Updated $($r.Updated.ToString('yyyy-MM-dd HH:mm'))" }
        if ($r.Checked)    { $info += "Checked $($r.Checked.ToString('yyyy-MM-dd HH:mm'))" }
        if ($r.Agent -and $r.Agent.PSObject.Properties['job'] -and $r.Agent.job -and $r.Agent.job.state) {
            $info += "Agent job: $($r.Agent.job.action) $($r.Agent.job.state)$(if ($r.Agent.job.message) { " ($($r.Agent.job.message))" })"
        }
        $ui.TxtDashInfo.Text = $info -join '    '
        $lines = @(Get-DeployChecklist -Row $r)
        if ($r.Message)  { $lines = @([pscustomobject]@{ Item = 'Error'; Result = 'Failed'; Detail = "$($r.Message)" }) + $lines }
        if ($r.Warnings) { $lines += [pscustomobject]@{ Item = 'Warnings'; Result = 'Warning'; Detail = "$($r.Warnings)" } }
        if (-not $lines) { $lines = @([pscustomobject]@{ Item = 'Progress'; Result = 'Info'; Detail = "$($r.StatusText) ($($r.Percent) %)" }) }
        $ui.LstDashChecks.ItemsSource = $lines
        Set-DashboardLogVisible ([bool]$ui.ChkDashLog.IsChecked)
    }
    if ($ui.TxtDashLog.Visibility -eq 'Visible') {
        $text = if ($r.LogPath) { try { [IO.File]::ReadAllText($r.LogPath) } catch { '' } } else { 'No log reported yet.' }
        if ($text -ne $ui.TxtDashLog.Text) { $ui.TxtDashLog.Text = $text; $ui.TxtDashLog.ScrollToEnd() }
    }
}

function Set-DashboardLogVisible([bool]$Show) {
    $ui.TxtDashLog.Visibility = if ($Show) { 'Visible' } else { 'Collapsed' }
    $ui.ScrDashChecks.Visibility = if ($Show) { 'Collapsed' } else { 'Visible' }
}

#region Dashboard notices

# A Windows notification (tray balloon: it needs no Start menu shortcut) and a flashing taskbar button when a PC
# finishes or fails, while the console is not in front on the Dashboard.
$script:dashLastStates = $null
$script:dashNotifyIcon = $null
Add-Type -Namespace ImagingTool -Name TaskbarFlash -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
[DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
public static void Flash(IntPtr hwnd) {
    FLASHWINFO f = new FLASHWINFO(); f.cbSize = (uint)Marshal.SizeOf(f); f.hwnd = hwnd; f.dwFlags = 3 | 12; f.uCount = 0; f.dwTimeout = 0;
    FlashWindowEx(ref f);
}
'@ -ErrorAction SilentlyContinue

function Show-DashboardNotices([object[]]$Rows) {
    $notices = @(Get-DeployNotices -Rows $Rows -Previous $script:dashLastStates)
    $script:dashLastStates = @{}
    foreach ($r in $Rows) { $script:dashLastStates["$($r.Id)"] = "$($r.State)" }
    if (-not $notices) { return }
    if ($window.IsActive -and $ui.Tabs.SelectedItem -eq $ui.TabDashboard) { return }
    try {
        if (-not $script:dashNotifyIcon) {
            $icon = New-Object Windows.Forms.NotifyIcon
            $ico = Join-Path $srcDir 'Assets\logo.ico'
            $icon.Icon = if (Test-Path $ico) { New-Object Drawing.Icon $ico } else { [Drawing.SystemIcons]::Information }
            $icon.Text = 'Imaging Console'
            $icon.Add_BalloonTipClicked({ Invoke-Safely { Open-DashboardFromNotice } })
            $icon.Add_MouseClick({ Invoke-Safely { Open-DashboardFromNotice } })
            $script:dashNotifyIcon = $icon
        }
        $script:dashNotifyIcon.Visible = $true
        $n = $notices[-1]
        $title = if ($notices.Count -gt 1) { "$($notices.Count) PCs finished or need attention" } else { $n.Title }
        $text = if ($notices.Count -gt 1) { ($notices | ForEach-Object Title) -join "`n" } else { $n.Text }
        $script:dashNoticeId = $n.Id
        $script:dashNotifyIcon.ShowBalloonTip(10000, $title, $(if ($text) { $text } else { ' ' }), $(if (@($notices | Where-Object Bad)) { 'Warning' } else { 'Info' }))
    } catch { }
    try {
        if (-not $window.IsActive) { [ImagingTool.TaskbarFlash]::Flash((New-Object Windows.Interop.WindowInteropHelper $window).Handle) }
    } catch { }
}

function Open-DashboardFromNotice {
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    [void]$window.Activate()
    $ui.Tabs.SelectedItem = $ui.TabDashboard
    if ($script:dashNoticeId) {
        $row = @($ui.GridDash.ItemsSource | Where-Object { "$($_.Id)" -eq $script:dashNoticeId })[0]
        if ($row) { $ui.GridDash.SelectedItem = $row; $ui.GridDash.ScrollIntoView($row) }
    }
}

#endregion

function Update-Library {
    # Applications and tasks in one list (Apps and Tasks tab); the selection stays when the row is still there.
    $keep = $ui.GridLibrary.SelectedItem
    $rows = @(if (Test-ContentRoot $script:root) { Get-LibraryRows -ContentRoot $script:root })
    $ui.GridLibrary.ItemsSource = $rows
    if ($keep) { $ui.GridLibrary.SelectedItem = @($rows | Where-Object { $_.Kind -eq $keep.Kind -and $_.Name -eq $keep.Name })[0] }
    if (-not $ui.GridLibrary.SelectedItem) { $ui.TxtLibIssues.Text = '' }
}

function Get-UsbDiskChoices {
    # Ours: a stick this tool built (WINPE and DEPLOY partitions), which Build media updates in place.
    Get-Disk | Where-Object BusType -eq 'USB' | ForEach-Object {
        $n = $_.Number
        $labels = @(try { Get-Partition -DiskNumber $n -ErrorAction Stop | Get-Volume -ErrorAction SilentlyContinue | ForEach-Object FileSystemLabel } catch { })
        [pscustomobject]@{
            Number = $n
            Ours   = Test-ToolStickLabels $labels
            Label  = '{0}: {1} ({2:N1} GB)' -f $n, $_.FriendlyName, ($_.Size / 1GB)
        }
    }
}

function Update-UsbDisks {
    $ui.CmbUsb.ItemsSource = @(Get-UsbDiskChoices)
    if ($ui.CmbUsb.Items.Count) { $ui.CmbUsb.SelectedIndex = 0 }
    Update-UsbMode
}

function Initialize-WinPEPassword {
    # The password of the last build, remembered for this Windows account: no typing it twice for every update.
    $script:winPeSaved = Read-WinPEPassword
    $ui.PwdWinPE.Password = $script:winPeSaved
    $ui.PwdWinPE2.Password = $script:winPeSaved
    Update-WinPEPasswordAgain
}

function Update-WinPEPasswordAgain {
    # "Again" only when the password is new or changed; the remembered one was already typed twice once.
    $same = $script:winPeSaved -and $ui.PwdWinPE.Password -eq $script:winPeSaved
    $ui.PnlWinPEAgain.Visibility = if ($same) { 'Collapsed' } else { 'Visible' }
    if ($same) { $ui.PwdWinPE2.Password = $script:winPeSaved }
    elseif ($ui.PwdWinPE2.Password -eq $script:winPeSaved) { $ui.PwdWinPE2.Password = '' }
}

function Update-UsbMode {
    # Says what Build media will do with the selected stick: update one this tool built, or erase any other.
    $d = $ui.CmbUsb.SelectedItem
    $ui.TxtUsbMode.Text = if (-not $d) { '' }
        elseif ($d.Ours) { 'Built by this tool before: it is updated in place. WinPE is replaced and only the files that changed are copied. To start it fresh, format it in File Explorer and click Refresh.' }
        else { 'Not built by this tool: everything on it is erased.' }
}

function Update-StickVersionBanner {
    # A banner at the top when a plugged-in stick was built with an older version of the tool: the fix the operator
    # expects is then not on the stick. "Not now" hides it until another stick (or another version) is plugged in.
    # (An older network boot image needs no banner: Reimage rebuilds it first.)
    $msg = Get-StaleStickMessage -Console $script:toolVersion -StickRoots (Get-DeployStickRoots)
    if ($msg -and $msg -ne $script:stickOldHidden) {
        $ui.TxtStickOld.Text = $msg
        $ui.BdrStickOld.Visibility = 'Visible'
    } else {
        $ui.BdrStickOld.Visibility = 'Collapsed'
    }
}

function Select-StickForUpdate {
    # "Update the stick", one click: the Media tab with the old stick's disk (updated in place, it is ours), the answer
    # files and driver packs the stick already holds checked, and the build started (it still asks before it
    # writes, and for the WinPE password when that box is empty).
    $ui.Tabs.SelectedItem = $ui.TabMedia
    Update-UsbDisks
    $old = @(Get-DeployStickRoots | Where-Object { (Compare-ToolVersion -Console $script:toolVersion -Stick (Get-StickToolVersion -StickRoot $_)) -eq 'Older' })
    $item = $null
    if ($old) {
        $disk = try { (Get-Partition -DriveLetter $old[0].Substring(0, 1) -ErrorAction Stop).DiskNumber } catch { $null }
        $item = @($ui.CmbUsb.Items | Where-Object { $null -ne $disk -and $_.Number -eq $disk })[0]
        if ($item) { $ui.CmbUsb.SelectedItem = $item }
    }
    if (-not $item) { Set-Status 'Pick the stick, check the answer files and driver packs, then click Build media.'; return }
    $on = Get-StickContentChoice -StickRoot $old[0]
    $answers = @($ui.LstMediaAnswers.Items | Where-Object { $on.AnswerFiles -contains $_.Name })
    if ($answers) {
        $ui.LstMediaAnswers.SelectedItems.Clear()
        foreach ($a in $answers) { [void]$ui.LstMediaAnswers.SelectedItems.Add($a) }
    }
    if ($on.DriverPacks) {
        $ui.LstMediaPacks.SelectedItems.Clear()
        foreach ($p in @($ui.LstMediaPacks.Items | Where-Object { $on.DriverPacks -contains $_.Path })) { [void]$ui.LstMediaPacks.SelectedItems.Add($p) }
    }
    $ui.BtnBuild.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
}

function Update-AdkStatus {
    # Shown on the Media tab; media builds and captures need the ADK and the WinPE add-on.
    $s = Get-AdkStatus
    $text = $s.Summary
    if ($s.Warnings) { $text += ' ' + ($s.Warnings -join ' ') }
    $ui.TxtAdk.Text = $text
    $ok = $s.Ready -and -not $s.Warnings
    $tone = if ($s.Ready) { if ($ok) { 'Success' } else { 'Warning' } } else { 'Error' }
    $ui.BrdAdk.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, "${tone}SoftBrush")
    $ui.BrdAdk.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, "${tone}LineBrush")
    $ui.BtnAdkDownload.Visibility = if ($s.Ready) { 'Collapsed' } else { 'Visible' }
    $s
}

function Update-All {
    $ui.TxtRoot.Text = $script:root
    Update-Answers; Update-Images; Update-Library; Update-Drivers; Update-Settings; Update-Computers; Update-Dashboard
    Set-Status $(if (Test-ContentRoot $script:root) { "Loaded $($script:root)" } else { 'Choose a content root to start' })
}

#endregion

#region Content root

$ui.BtnShowProgress.Add_Click({ Invoke-Safely { Show-ProgressWindows } })

$ui.BtnOpenRoot.Add_Click({ Invoke-Safely { if (Test-RootReady) { Invoke-Item $script:root } } })

$ui.BtnBrowseRoot.Add_Click({ Invoke-Safely {
    $path = Select-Folder 'Choose the content root: a USB DEPLOY volume, a local folder, or the network share'
    if (-not $path) { return }
    $script:root = $path
    # Keeps the rest of console.json (the Computers tab's Active Directory settings).
    $cfg = Get-ConsoleConfig
    $cfg | Add-Member -NotePropertyName contentRoot -NotePropertyValue $path -Force
    Save-ConsoleConfig $cfg
    # A new folder becomes a content root right away (nothing existing is overwritten).
    $created = -not (Test-ContentRoot $path)
    if ($created) { Initialize-ContentRoot -Path $path }
    Update-All
    if ($created) { Set-Status "Created the content folders (Images, Drivers, AnswerFiles, Applications, Tasks, config, Logs) in $path" }
} })

#endregion

#region Images

$ui.BtnCapture.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    if (Show-CaptureWizard -Owner $window -ContentRoot $script:root -SrcDir $srcDir) {
        Set-Status 'Capture started. Click Refresh on the Images tab when it finishes.'
    }
} })
$ui.BtnImageVersions.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $image = $ui.GridImages.SelectedItem
    if (-not $image) { Show-Error 'Select an image first.'; return }
    if (Show-ImageVersionsDialog -Owner $window -ContentRoot $script:root -SrcDir $srcDir -Image $image) {
        Update-Images; Update-Answers
        Set-Status "Versions of $($image.Name) changed. A copy or rollback shows in the Progress window; the list refreshes when it ends."
    }
} })
$ui.GridImages.Add_MouseDoubleClick({ Invoke-Safely { if ($ui.GridImages.SelectedItem) { $ui.BtnImageVersions.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) } } })
$ui.BtnImageUpdate.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $image = $ui.GridImages.SelectedItem
    if (-not $image) { Show-Error 'Select an image first.'; return }
    if (Show-UpdateImageDialog -Owner $window -ContentRoot $script:root -SrcDir $srcDir -Image $image) {
        Set-Status "Updating $($image.Name). The Progress window shows each step; Open log shows its log when it finishes."
    }
} })
$ui.BtnImageLog.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $image = $ui.GridImages.SelectedItem
    if (-not $image) { Show-Error 'Select an image first.'; return }
    $log = Get-ImageLogPath -ContentRoot $script:root -ImageName ([IO.Path]::GetFileNameWithoutExtension($image.Name))
    if (-not $log) { Show-Error "No capture or update log for $($image.Name) yet."; return }
    Invoke-Item $log
} })

#endregion

#region Answer files

function Edit-AnswerFile([string]$Path, [string]$NewName) {
    $saved = if ($Path) { Show-AnswerEditor -Owner $window -ContentRoot $script:root -Path $Path }
             else { Show-AnswerEditor -Owner $window -ContentRoot $script:root -NewName $NewName }
    if ($saved) { Update-Answers; Update-Images; Update-Library; Set-Status 'Answer file saved' }
}


$ui.GridAnswers.Add_SelectionChanged({
    $row = $ui.GridAnswers.SelectedItem
    $ui.TxtAnswerIssues.Text = if ($row -and $row.Issues) { ($row.Issues | ForEach-Object { "- $_" }) -join "`r`n" } else { '' }
})

$ui.GridAnswers.Add_MouseDoubleClick({ Invoke-Safely { $row = $ui.GridAnswers.SelectedItem; if ($row) { Edit-AnswerFile -Path $row.FullName } } })

$ui.BtnAnswerNew.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $existing = @(Get-ChildItem (Join-Path $script:root 'AnswerFiles') -Filter *.xml | ForEach-Object BaseName)
    $name = 'Win11-Standard'; $i = 2
    while ($existing -contains $name) { $name = "Win11-Standard-$i"; $i++ }
    Edit-AnswerFile -NewName $name
} })

$ui.BtnAnswerEdit.Add_Click({ Invoke-Safely {
    $row = $ui.GridAnswers.SelectedItem
    if (-not $row) { Show-Error 'Select an answer file first.'; return }
    Edit-AnswerFile -Path $row.FullName
} })

$ui.BtnAnswerDelete.Add_Click({ Invoke-Safely {
    $row = $ui.GridAnswers.SelectedItem
    if (-not $row) { Show-Error 'Select an answer file first.'; return }
    $check = Get-AnswerFileDeleteCheck -ContentRoot $script:root -Name $row.Name
    if (-not (Confirm-Action $check.Text)) { return }
    [void](Remove-AnswerFile -ContentRoot $script:root -Name $row.Name)
    Update-Answers; Update-Images; Update-Library
    Set-Status "Deleted $($row.Name)"
} })

#endregion

#region Applications and tasks

# Delete an application or a task the same way.
$script:libraryKinds = @{
    Application = @{ Folder = 'Applications'; Files = 'its installer files' }
    Task        = @{ Folder = 'Tasks'; Files = 'its script files' }
}

function Remove-LibraryRow($Row) {
    if (-not $Row) { return }
    $t = $script:libraryKinds[$Row.Kind]
    if (-not (Confirm-Action "Delete $($t.Folder)\$($Row.Name) and $($t.Files)?")) { return }
    Remove-LibraryItem -Kind $Row.Kind -ContentRoot $script:root -Name $Row.Name
    Update-Library
    Set-Status "Deleted $($Row.Name)"
}

function Get-SelectedLibraryRow {
    $row = $ui.GridLibrary.SelectedItem
    if (-not $row) { Show-Error 'Select an application or a task first.'; return }
    $row
}

function Edit-App([string]$Name) {
    $saved = if ($Name) { Show-AppPackEditor -Owner $window -ContentRoot $script:root -Name $Name }
             else { Show-AppPackEditor -Owner $window -ContentRoot $script:root }
    if ($saved) { Update-Library; Update-Answers; Set-Status "Application $saved saved" }
}

function Edit-Task([string]$Name) {
    $saved = if ($Name) { Show-TaskEditor -Owner $window -ContentRoot $script:root -Name $Name }
             else { Show-TaskEditor -Owner $window -ContentRoot $script:root }
    if ($saved) { Update-Library; Update-Answers; Set-Status "Task $saved saved" }
}

function Edit-LibraryRow($Row) {
    if (-not $Row) { return }
    if ($Row.Kind -eq 'Task') { Edit-Task $Row.Name } else { Edit-App $Row.Name }
}

$ui.BtnAppNew.Add_Click({ Invoke-Safely { if (Test-RootReady) { Edit-App } } })
$ui.BtnTaskNew.Add_Click({ Invoke-Safely { if (Test-RootReady) { Edit-Task } } })
$ui.BtnLibEdit.Add_Click({ Invoke-Safely { Edit-LibraryRow (Get-SelectedLibraryRow) } })
$ui.GridLibrary.Add_MouseDoubleClick({ Invoke-Safely { Edit-LibraryRow $ui.GridLibrary.SelectedItem } })
$ui.BtnLibDelete.Add_Click({ Invoke-Safely { Remove-LibraryRow (Get-SelectedLibraryRow) } })

# Find an app online: winget's catalog gives the publisher's download address and the file's SHA256.
$script:appFound = @()
function Find-AppOnline {
    $query = $ui.TxtAppFind.Text.Trim()
    if (-not $query) { Set-Status 'Type the name of an application to find.'; return }
    $ui.CmbAppFound.Items.Clear(); $ui.CmbAppFound.IsEnabled = $false; $ui.BtnAppFoundAdd.IsEnabled = $false
    Set-Status "Searching the winget catalog for $query..."
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try { $script:appFound = @(Find-WingetPackage -Query $query) }
    finally { $window.Cursor = $null }
    foreach ($p in $script:appFound) { [void]$ui.CmbAppFound.Items.Add("$($p.Name)  ($($p.Id) $($p.Version))") }
    if (-not $script:appFound.Count) { Set-Status "Nothing found online for $query. Try another name."; return }
    $ui.CmbAppFound.SelectedIndex = 0; $ui.CmbAppFound.IsEnabled = $true; $ui.BtnAppFoundAdd.IsEnabled = $true
    $ui.CmbAppFound.IsDropDownOpen = $script:appFound.Count -gt 1
    Set-Status "$($script:appFound.Count) found for $query. Pick one and click Add."
}
$ui.BtnAppFind.Add_Click({ Invoke-Safely { Find-AppOnline } })
$ui.TxtAppFind.Add_KeyDown({ param($s, $e)
    if ($e.Key -eq [Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-Safely { Find-AppOnline } } })
$ui.BtnAppFoundAdd.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $i = $ui.CmbAppFound.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:appFound.Count) { return }
    $p = $script:appFound[$i]
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try { $d = New-AppFromWinget -AppRoot (Join-Path $script:root 'Applications') -Id $p.Id -Version $p.Version -DisplayName $p.Name }
    finally { $window.Cursor = $null }
    Update-Library; Update-Answers
    $ui.GridLibrary.SelectedItem = @($ui.GridLibrary.ItemsSource | Where-Object { $_.Kind -eq 'Application' -and $_.Name -eq $d.name })[0]
    Set-Status "Added $($d.name) $($p.Version): the PC downloads it from the publisher when it installs it"
} })

$ui.GridLibrary.Add_SelectionChanged({
    $row = $ui.GridLibrary.SelectedItem
    $ui.TxtLibIssues.Text = if (-not $row) { '' } elseif ($row.Kind -eq 'Application') {
        $lines = @("Install: $($row.Command)")
        if ($row.Download) { $lines += "Downloaded at install from: $($row.Download)" }
        if ($row.Detection) { $lines += "Detection: $($row.Detection)" }
        if ($row.Definition -and $row.Definition.notes) { $lines += "Notes: $($row.Definition.notes)" }
        $lines += @($row.Issues | ForEach-Object { "- $_" })
        $lines -join "`r`n"
    } else {
        $lines = @()
        if ($row.CommandLine) { $lines += "Runs: $($row.CommandLine)" }
        if ($row.Definition) { $lines += "Timeout $($row.Definition.timeoutMinutes) min, success codes $($row.Definition.successCodes -join ', ')$(if ($row.Definition.stopOnFailure) { ', stops the deployment when it fails' })" }
        $lines += @($row.Issues | ForEach-Object { "- $_" })
        $lines -join "`r`n"
    }
})

#endregion

#region Driver library

# Find a model online: type the PC model, pick the pack, download it (the progress shows in the Progress window).
$script:driverFound = @()
function Find-DriverPackOnline {
    $query = $ui.TxtDriverFind.Text.Trim()
    if (-not $query) { Set-Status 'Type the PC model to find, for example Latitude 5521.'; return }
    $ui.CmbDriverFound.Items.Clear(); $ui.CmbDriverFound.IsEnabled = $false; $ui.BtnDriverFoundDownload.IsEnabled = $false
    Set-Status "Searching the Dell, HP and Lenovo catalogs for $query..."
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $window.Dispatcher.Invoke([action]{}, 'Background')   # let the status paint before the catalogs download
    try { $r = Find-VendorDriverPackOnline -Query $query -ContentRoot $(if (Test-ContentRoot $script:root) { $script:root }) }
    finally { $window.Cursor = $null }
    $script:driverFound = @($r.Packs | Select-Object -First 50)
    foreach ($p in $script:driverFound) { [void]$ui.CmbDriverFound.Items.Add((Format-VendorDriverPack $p)) }
    $err = if ($r.Errors) { " $(@($r.Errors)[0])" } else { '' }
    if (-not $script:driverFound.Count) { Set-Status "No driver pack found for $query. Try fewer words or the SKU.$err"; return }
    $ui.CmbDriverFound.SelectedIndex = 0; $ui.CmbDriverFound.IsEnabled = $true; $ui.BtnDriverFoundDownload.IsEnabled = $true
    $ui.CmbDriverFound.IsDropDownOpen = $script:driverFound.Count -gt 1
    $more = if (@($r.Packs).Count -gt 50) { ' (first 50 shown, type more of the name)' } else { '' }
    Set-Status "$($script:driverFound.Count) found for $query$more. Pick one and click Download.$err"
}
$ui.BtnDriverFind.Add_Click({ Invoke-Safely { Find-DriverPackOnline } })
$ui.TxtDriverFind.Add_KeyDown({ param($s, $e)
    if ($e.Key -eq [Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-Safely { Find-DriverPackOnline } } })
$ui.BtnDriverFoundDownload.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $i = $ui.CmbDriverFound.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:driverFound.Count) { return }
    $p = $script:driverFound[$i]
    if ($p.Installed -like 'Yes*' -and -not (Confirm-Action "$($p.Maker) $($p.Model) $($p.Version) is already in the library. Download it again?")) { return }
    Start-DriverPackDownload -Packs @($p) -ContentRoot $script:root -SrcDir $srcDir -Owner $window
    Set-Status "Downloading the $(Format-DriverPackName $p) driver pack ($($p.SizeMB) MB). The Progress window shows it; the library refreshes when it is done."
} })

function Show-DriverPacksFound([object[]]$Packs) {
    # Puts packs in the Find a model online box, the first one picked, ready for Download.
    $ui.CmbDriverFound.Items.Clear()
    $script:driverFound = @($Packs)
    foreach ($p in $script:driverFound) { [void]$ui.CmbDriverFound.Items.Add((Format-VendorDriverPack $p)) }
    $ui.CmbDriverFound.SelectedIndex = 0; $ui.CmbDriverFound.IsEnabled = $true; $ui.BtnDriverFoundDownload.IsEnabled = $true
}
$ui.BtnUnknownFind.Add_Click({ Invoke-Safely {
    $m = $ui.GridUnknown.SelectedItem
    if (-not $m) { Set-Status 'Select a model in the list first.'; return }
    # Its maker's catalog by SKU or machine type first (exact), then a search by name.
    Set-Status "Looking up the $($m.Maker) $($m.Model) pack..."
    $window.Cursor = [Windows.Input.Cursors]::Wait
    $window.Dispatcher.Invoke([action]{}, 'Background')
    try { $hit = @(Add-UnknownModelPacks -Models @($m.PSObject.Copy()) 3>$null)[0] } finally { $window.Cursor = $null }
    $ui.TxtDriverFind.Text = if ($m.Sku) { $m.Sku } elseif ($m.MachineType) { $m.MachineType } else { $m.Model }
    if ($hit.Pack) {
        Show-DriverPacksFound @($hit.Pack)
        Set-Status "Found $($hit.PackText). Click Download."
    } else {
        $ui.TxtDriverFind.Text = $m.Model
        Find-DriverPackOnline
    }
} })
$ui.BtnUnknownInbox.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $rows = @($ui.GridUnknown.SelectedItems)
    if (-not $rows) { Set-Status 'Select the models that need no driver pack first.'; return }
    if (-not (Confirm-Action ("Deploy these with Windows inbox drivers only, without a warning?`n`n" + (($rows | ForEach-Object { "$($_.Maker) $($_.Model)" }) -join "`n")))) { return }
    foreach ($r in $rows) { Set-UnknownModelInbox -ContentRoot $script:root -Model $r }
    Update-Drivers
    Set-Status "$($rows.Count) model(s) set to Windows inbox drivers"
} })

$ui.BtnDriversRemove.Add_Click({ Invoke-Safely {
    $row = $ui.GridDrivers.SelectedItem
    if ($row -isnot [DriverRow]) { return }
    if (Confirm-Action "Remove the catalog entry for $($row.Maker) $(@($row.Model, $row.Sku, $row.MachineType, $row.ModelPattern) -ne '' | Select-Object -First 1)? The driver files stay on disk. Click Save to keep the change.") {
        [void]$script:drivers.Remove($row)
        $script:driversEdited = $true
    }
} })

# Typed in the grid and not saved yet: opening the tab again does not reload (and lose) it.
$ui.GridDrivers.Add_CellEditEnding({ $script:driversEdited = $true })

$ui.BtnDriversSave.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $ui.GridDrivers.CommitEdit('Row', $true) | Out-Null
    Save-DriverCatalog -ContentRoot $script:root -Rows @($script:drivers)
    Update-Drivers
    Set-Status "Saved $($script:drivers.Count) driver catalog entries"
} })

$ui.BtnSrcFolder.Add_Click({ $p = Select-Folder 'Choose an extracted driver pack folder'; if ($p) { $ui.TxtSource.Text = $p } })
$ui.BtnSrcFile.Add_Click({
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Filter = 'Driver packs (*.cab;*.zip)|*.cab;*.zip'
    if ($dlg.ShowDialog($window)) { $ui.TxtSource.Text = $dlg.FileName }
})

$ui.BtnImport.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $model = $ui.TxtModel.Text.Trim()
    if (-not $model -or -not $ui.TxtSource.Text) { Show-Error 'Model and source are required.'; return }
    $maker = Get-DriverPackMaker -Model $model -Source $ui.TxtSource.Text
    if (-not $maker) { Show-Error 'Could not tell the maker. Start the model with Dell, HP or Lenovo, for example Dell Latitude 5521.'; return }
    # 'Dell Latitude 5521' is stored as maker Dell, model Latitude 5521.
    $model = ($model -replace "^(?i)(dell|hp|hewlett[- ]packard|lenovo)\s+", '').Trim()
    if (-not $model) { Show-Error 'Type the model after the maker, for example Dell Latitude 5521.'; return }
    $window.Cursor = 'Wait'
    Set-Status "Importing $maker $model..."
    try {
        # The SKUs / machine types come from the maker's catalog; without them the pack matches by model name.
        $ids = Find-DriverPackIds -Maker $maker -Model $model
        $result = Import-DriverPack -ContentRoot $script:root -Source $ui.TxtSource.Text -Maker $maker -Model $model `
            -Sku "$($ids.Sku)" -MachineType "$($ids.MachineType)"
    } finally { $window.Cursor = $null }
    Update-Drivers
    $ui.TxtModel.Text = ''; $ui.TxtSource.Text = ''
    $idText = (@($ids.Sku, $ids.MachineType) | Where-Object { $_ }) -join ', '
    Set-Status ("Imported $($result.InfCount) drivers to Drivers\$($result.Path)" +
        $(if ($idText) { " (matches $idText)" } else { ' (not in the maker''s catalog: matches by model name)' }))
    if ($result.InfCount -eq 0) { Show-Error 'No .inf files were found after import. The pack may need extracting first.' }
} })

#endregion

#region Computers (Active Directory)

$script:adRows = @()
$script:adOnline = @{}

function Get-AdSettings {
    # The Computers tab's domain controller (set on Deploy Settings), kept in console.json (never a password).
    # domain is only what an older console saved.
    $c = Get-ConsoleConfig
    if ($c.PSObject.Properties['activeDirectory'] -and $c.activeDirectory) { return $c.activeDirectory }
    [pscustomobject]@{ domain = ''; server = '' }
}

function Save-AdSettings {
    param([string]$Server)
    $c = Get-ConsoleConfig
    $old = Get-AdSettings
    $ad = [pscustomobject]@{
        domain     = "$($old.domain)"
        server     = $(if ($PSBoundParameters.ContainsKey('Server')) { $Server.Trim() } else { "$($old.server)" })
    }
    $c | Add-Member -NotePropertyName activeDirectory -NotePropertyValue $ad -Force
    Save-ConsoleConfig $c
}

function Get-ShareAccount {
    # The account on the Deploy Settings tab, or $null when none is set there.
    if (-not (Test-ContentRoot $script:root)) { return $null }
    $v = Get-DeploySettingsView -ContentRoot $script:root
    if (-not $v.ShareUser) { return $null }
    $v
}

function Get-AdConnection {
    # Where the Computers tab reads Active Directory: the domain controller from Deploy Settings and its domain.
    $ad = Get-AdSettings
    $share = Get-ShareAccount
    $server = "$($ad.server)".Trim()
    [pscustomobject]@{
        Server = $server
        Domain = Resolve-AdDomain -Server $server -Account $(if ($share) { $share.ShareUser }) -Saved "$($ad.domain)" -Default (Get-AdDefaultDomain)
    }
}

function Get-AdCredential {
    # The Deploy Settings account with the password saved there, never asked; $null (the account the console runs
    # as) when Deploy Settings has no account.
    $share = Get-ShareAccount
    if (-not $share) { return $null }
    $pw = Get-SharePassword -ContentRoot $script:root
    if (-not $pw) { throw "No password saved for $($share.ShareUser) on the Deploy Settings tab. Save it there first." }
    [pscredential]::new($share.ShareUser, (ConvertTo-SecureString $pw -AsPlainText -Force))
}

function Get-ReimageShare {
    # Reimage jobs go on the deployment share, where WinPE looks for them.
    "$((Get-DeploySettings -ContentRoot $script:root).share.path)".Trim()
}

function Get-NetworkBootRebuild {
    # Why Reimage must build the network boot image first, or $null when it is ready (Get-NetworkBootRebuildReason).
    $stale = try { Get-StaleBootImageMessage -Console $script:toolVersion -ContentRoot $script:root } catch { $null }
    $boot = Get-NetworkBootImage -ContentRoot $script:root
    $settingsFile = Join-Path $script:root 'config\deploy-settings.json'
    $newer = $boot.Exists -and (Test-Path -LiteralPath $settingsFile) -and
        (Get-Item -LiteralPath $settingsFile).LastWriteTime -gt (Get-Item -LiteralPath $boot.Path).LastWriteTime
    Get-NetworkBootRebuildReason -Settings (Get-DeploySettings -ContentRoot $script:root) -Boot $boot -Stale "$stale" -SettingsNewer:$newer
}

function Update-AdBootStatus {
    if (-not (Test-ContentRoot $script:root)) { $ui.TxtAdBoot.Text = ''; return }
    $boot = Get-NetworkBootImage -ContentRoot $script:root
    $problems = @(Get-RemoteReimageProblems -Settings (Get-DeploySettings -ContentRoot $script:root) -Boot $boot)
    $rebuild = if (-not $problems) { Get-NetworkBootRebuild }
    $ui.TxtAdBoot.Text = if ($problems) { $problems[0] }
        elseif ($script:bootBuilding) { 'Building the network boot image (Progress window); the reimage starts when it is done.' }
        elseif ($rebuild) { "Network boot image: $rebuild. Reimage builds it first (a few minutes)." }
        else { "Network boot image built $($boot.Built), maps $($boot.Share). Boot\Deploy-WinPE.iso boots a VM or a PC from the same share." }
    $ui.TxtAdBoot.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($problems) { 'WarningBrush' } elseif ($rebuild -or $script:bootBuilding) { 'MutedBrush' } else { 'SuccessBrush' }))
}

function Show-AdRows {
    $states = @{}
    if ($script:adRows -and (Test-ContentRoot $script:root)) {
        $share = Get-ReimageShare
        if ($share) { try { $states = Get-ReimageStates -ContentRoot $share } catch { } }
    }
    $checkIns = @(if ($script:adRows) { Get-ConsoleAgentCheckIns })
    Send-AgentUpdates $checkIns
    # Keep the selected PCs selected when Online fills in.
    $picked = @($ui.GridAd.SelectedItems | ForEach-Object Name)
    $ui.GridAd.ItemsSource = @($script:adRows | ForEach-Object {
        $check = if ($script:adOnline.ContainsKey($_.Address)) { $script:adOnline[$_.Address] }
        $agent = Find-AgentCheckIn -CheckIns $checkIns -ComputerName $_.Name
        $view = Get-AgentRowView -Check $check -Agent $agent -Name $_.Name -CurrentCode $script:agentCode
        $online = if (-not $check -and $script:adCheck -and $view.Online -ne 'Agent') { 'Checking...' } else { $view.Online }
        $_ | Add-Member -NotePropertyName Online -NotePropertyValue $online -Force
        # The address the online check reached; when the network check got no way in, the one the PC's agent reported
        # lately (the PC's own word, DNS can be old); a PC found by IP shows that IP.
        $agentIp = if ($agent -and $agent.Online -and $agent.ipAddress) { "$($agent.ipAddress)" } else { '' }
        $ip = if ($check -and $check.Ip -and ($check.Online -or -not $agentIp)) { $check.Ip } elseif ($agentIp) { $agentIp } elseif ($check -and $check.Ip) { $check.Ip } elseif ($_.Address -match '^\d+(\.\d+){3}$') { $_.Address } else { '' }
        $_ | Add-Member -NotePropertyName IpAddress -NotePropertyValue $ip -Force
        $_ | Add-Member -NotePropertyName OnlineDetail -NotePropertyValue $view.OnlineDetail -Force
        $_ | Add-Member -NotePropertyName Agent -NotePropertyValue $view.Agent -Force
        $_ | Add-Member -NotePropertyName AgentDetail -NotePropertyValue $view.AgentDetail -Force
        $_ | Add-Member -NotePropertyName AgentVersion -NotePropertyValue $view.AgentVersion -Force
        $_ | Add-Member -NotePropertyName AgentVersionDetail -NotePropertyValue $view.AgentVersionDetail -Force
        $_ | Add-Member -NotePropertyName HasAgent -NotePropertyValue ([bool]($agent -and $agent.Online)) -Force
        $_ | Add-Member -NotePropertyName Reimage -NotePropertyValue $(if ($states.ContainsKey($_.Name)) { $states[$_.Name] } else { '' }) -Force -PassThru
    })
    if ($picked) { foreach ($row in @($ui.GridAd.ItemsSource | Where-Object { $picked -contains $_.Name })) { [void]$ui.GridAd.SelectedItems.Add($row) } }
}

function Update-Computers {
    $answers = @(if (Test-ContentRoot $script:root) { Get-ChildItem (Join-Path $script:root 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue | ForEach-Object BaseName })
    $picked = $ui.CmbAdAnswer.SelectedItem
    $ui.CmbAdAnswer.ItemsSource = $answers
    # No default answer file: keep the one picked, or the only one there is.
    $ui.CmbAdAnswer.SelectedItem = if ($picked -and $answers -contains $picked) { $picked } elseif ($answers.Count -eq 1) { $answers[0] } else { $null }
    Update-AdBootStatus
    Update-AgentInstaller
    Show-AdRows
}

function Update-AgentInstaller {
    # <share>\Agent\Install-Agent.cmd: for a PC the console cannot reach, run on it as administrator. Never fails the tab.
    try {
        $share = Get-ReimageShare
        $statusFolder = Get-DashboardFolder
        if (-not $share -or $share -notlike '\\*' -or -not $statusFolder -or $statusFolder -notlike '\\*') { return }
        $settings = Get-DeploySettings -ContentRoot $script:root
        $cfg = if ($settings -and $settings.PSObject.Properties['agent']) { $settings.agent } else { $null }
        if ($cfg -and $cfg.PSObject.Properties['enabled'] -and -not $cfg.enabled) { return }
        $minutes = if ($cfg -and $cfg.PSObject.Properties['checkInMinutes'] -and $cfg.checkInMinutes) { [int]$cfg.checkInMinutes } else { 5 }
        $key = Get-AgentPublicKey -ContentRoot $script:root -Create
        $config = New-AgentConfig -StatusFolder $statusFolder -PublicKeys @($key) -CheckInMinutes $minutes `
            -Deploy ([pscustomobject]@{ answerFile = ''; image = ''; toolVersion = ''; deployedAt = '' })
        $folder = Publish-AgentInstaller -Folder "$($share.TrimEnd('\'))\Agent" -SourceDir $srcDir -Config $config
        $ui.BtnAdAgent.ToolTip = "Puts the agent on the selected PCs over PowerShell remoting or file sharing, for PCs imaged before the agent existed. " +
            "For a PC the console cannot reach: on that PC, right-click $folder\Install-Agent.cmd and pick Run as administrator."
    } catch { }
}

function Search-AdComputers {
    # The whole domain: no OU choice (Patrick, 2026-11-23). A PC typed by IP can still be found without Active Directory.
    $window.Cursor = 'Wait'
    $localNote = ''
    try {
        # The Name box takes a name or pattern, an IP address, or both (GWHZLG3 10.1.2.34). With an IP, the PC is
        # reached at that address, so an old DNS record doesn't matter.
        $find = ConvertFrom-AdSearchText $ui.TxtAdName.Text
        if ($find.Ip -and -not $find.Name) {
            Set-Status "Asking $($find.Ip) for its name..."
            $find.Name = Resolve-AdComputerNameFromIp -Ip $find.Ip
        }
        $found = @()
        if ($find.Name -or -not $find.Ip) {
            Set-Status 'Searching Active Directory...'
            try {
                $cred = Get-AdCredential
                $conn = Get-AdConnection
                $found = @(Get-AdComputers -Domain $conn.Domain -Server $conn.Server -Name $find.Name -Credential $cred)
            } catch {
                # A PC typed by IP can still be reimaged without Active Directory (a laptop outside the domain).
                if (-not $find.Ip) { throw }
                $found = @()
            }
        }
        if ($find.Ip) {
            $found = @($found | Where-Object { $find.Name -and $_.Name -eq $find.Name.ToUpperInvariant() })
            if (-not $found) {
                # Not in Active Directory (or no name answered): a PC outside the domain, reimaged with its own local
                # administrator account, asked for at Reimage (Patrick, 2026-11-22).
                $found = @(New-LocalComputerRow -Ip $find.Ip -Name $find.Name)
                $localNote = " $($find.Ip) is not in Active Directory: Reimage asks for its local administrator account."
            }
            foreach ($r in $found) { $r.Address = $find.Ip }
        }
        $script:adRows = $found
        # The list shows now; Online fills in when the check in the background is done (Patrick, 2026-11-25: the
        # tab waited for every PC's network check before it showed anything).
        Start-AdOnlineCheck -Note $localNote
    } finally { $window.Cursor = $null }
    Show-AdRows
    Set-Status "$($script:adRows.Count) computer(s) found.$(if ($script:adCheck) { ' Checking which are online...' })$localNote"
}

$script:adCheck = $null
$script:adCheckTimer = [Windows.Threading.DispatcherTimer]::new()
$script:adCheckTimer.Interval = [timespan]::FromMilliseconds(250)
$script:adCheckTimer.Add_Tick({ try { Complete-AdOnlineCheck } catch { $script:adCheckTimer.Stop(); $script:adCheck = $null; Set-Status "Online check failed: $($_.Exception.Message)" } })

function Stop-AdOnlineCheck {
    # A new search replaces the check still running: it is told to stop and its answer is dropped.
    $c = $script:adCheck
    $script:adCheck = $null
    $script:adCheckTimer.Stop()
    if ($c) { try { [void]$c.PS.BeginStop($null, $null) } catch { } }
}

function Start-AdOnlineCheck {
    # Get-RemoteOnlineState in its own runspace, so the window stays free while it runs; Complete-AdOnlineCheck
    # takes its answer. The addresses a PC's agent reported in its last check-in are knocked on first: DNS can be
    # old or give a second adapter's address.
    param([string]$Note = '')
    Stop-AdOnlineCheck
    $script:adOnline = @{}
    if (-not $script:adRows) { return }
    $known = @{}
    $checkIns = @(Get-ConsoleAgentCheckIns)
    foreach ($r in @($script:adRows)) {
        $a = Find-AgentCheckIn -CheckIns $checkIns -ComputerName $r.Name
        if ($a -and $a.Online) { $known[$r.Address] = @(@($a.ipAddresses) + "$($a.ipAddress)" | Where-Object { $_ }) }
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($Module, $Names, $Known)
        Import-Module $Module -Force
        Get-RemoteOnlineState -ComputerName $Names -KnownAddress $Known
    }).AddArgument((Join-Path $srcDir 'RemoteReimage.psm1')).AddArgument([string[]]@($script:adRows | ForEach-Object Address)).AddArgument($known)
    $script:adCheck = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Note = $Note }
    $script:adCheckTimer.Start()
}

function Complete-AdOnlineCheck {
    # Timer tick: when the background check is done, its answer fills Online and IP address.
    $c = $script:adCheck
    if (-not $c) { $script:adCheckTimer.Stop(); return }
    if (-not $c.Handle.IsCompleted) { return }
    $script:adCheckTimer.Stop()
    $script:adCheck = $null
    try {
        $out = @($c.PS.EndInvoke($c.Handle))
        $h = if ($out) { $out[0] } else { $null }
        # Every object is -is [psobject], and .BaseObject on a hashtable is a key lookup: unwrap through .PSObject.
        if ($null -ne $h) { $h = $h.PSObject.BaseObject }
        $script:adOnline = if ($h -is [hashtable]) { $h } else { @{} }
        if (-not ($h -is [hashtable]) -and $c.PS.Streams.Error.Count) { throw $c.PS.Streams.Error[0].Exception }
    } catch {
        $script:adOnline = @{}
        Show-AdRows
        Set-Status "$($script:adRows.Count) computer(s) found. Online check failed: $($_.Exception.Message)$($c.Note)"
        return
    } finally { try { $c.PS.Dispose() } catch { } }
    Show-AdRows
    Set-Status "$($script:adRows.Count) computer(s) found. $(Get-AdOnlineSummary)$($c.Note)"
}

function Get-AdOnlineSummary {
    # One line: how many answer on PowerShell remoting, and what to do about the first one that does not.
    Get-OnlineSummaryText -Rows @($script:adRows | Where-Object { $script:adOnline[$_.Address] } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; State = $script:adOnline[$_.Address].State } })
}

function Invoke-AdAutoConnect {
    # The first time the Computers tab opens: list the computers by itself, unless the Deploy
    # Settings account has no saved password yet. A failure is one line in the status bar; Search tries again.
    if (-not (Test-ContentRoot $script:root)) { return }
    if ((Get-ShareAccount) -and -not (Get-SharePassword -ContentRoot $script:root)) { return }
    try { Search-AdComputers }
    catch {
        $window.Cursor = $null
        Set-Status "Could not connect to Active Directory by itself: $($_.Exception.Message)"
    }
}

$ui.BtnAdSearch.Add_Click({ Invoke-Safely { Search-AdComputers } })
$ui.TxtAdName.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { Invoke-Safely { Search-AdComputers } } })

function Start-NetworkBootBuild {
    # Builds the network boot image, then starts the reimage waiting in $script:pendingReimage. Reimage calls it when
    # the image is missing, maps another share or is older than the tool (there is no button for it).
    $adk = Update-AdkStatus
    if (-not $adk.Ready) { Show-Error ("Can't build the network boot image on this PC yet:`n`n" + ($adk.Problems -join "`n`n")); return $false }
    $out = Join-Path $script:root 'Boot'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    # No WinPE password: nobody is at the PCs to type it. The share password goes in encrypted with the answer file key.
    $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg "$srcDir\New-DeploymentMedia.ps1"),
        '-SettingsPath', (ConvertTo-Arg (Join-Path $script:root 'config\deploy-settings.json')), '-Target', 'Wim', '-OutputPath', (ConvertTo-Arg $out))
    $job = Start-ConsoleJob -Name 'network-boot' -ArgumentList $buildArgs -Hidden
    $script:bootBuilding = $true
    Show-BuildProgress -Owner $window -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title 'Building the network boot image' -Hidden -OnFinished {
        $script:bootBuilding = $false
        try { Update-AdBootStatus } catch { }
        Invoke-Safely { Start-PendingReimage }
    }
    Set-Status 'Building the network boot image first; the reimage starts when it is done.'
    $true
}

function Start-PendingReimage {
    # The reimage prepared by Reimage..., once the network boot image is ready.
    $p = $script:pendingReimage
    $script:pendingReimage = $null
    if (-not $p) { return }
    $why = Get-NetworkBootRebuild
    if ($why) { Show-Error "The reimage did not start: the network boot image build did not finish ($why). Its log is in the Progress window."; return }
    $job = Start-ConsoleJob -Name 'reimage' -ArgumentList $p.RunArgs -Hidden
    Show-BuildProgress -Owner $window -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title $p.Title `
        -Noun 'reimage' -Hidden -OnFinished { try { Show-AdRows } catch { } }
    Set-Status "Reimage of $($p.Count) PC(s) started. Each deploy then shows on the Dashboard."
}

$ui.BtnAdReimage.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $rows = @($ui.GridAd.SelectedItems)
    if (-not $rows) { Show-Error 'Select one or more PCs first (Ctrl+click or Shift+click for several).'; return }
    $answer = $ui.CmbAdAnswer.SelectedItem
    if (-not $answer) { Show-Error 'Choose the answer file to deploy.'; return }
    $self = @($rows | Where-Object { $_.Name -eq "$env:COMPUTERNAME".ToUpperInvariant() })
    if ($self) { Show-Error "$($self[0].Name) is this PC, the one running the console: reimage it from the USB stick."; return }
    $problems = @(Get-RemoteReimageProblems -Settings (Get-DeploySettings -ContentRoot $script:root))
    if ($problems) { Show-Error $problems[0]; return }
    if ($script:bootBuilding -or $script:pendingReimage) { Show-Error 'A reimage is already waiting for the network boot image build. Try again when it has started.'; return }
    $rebuild = Get-NetworkBootRebuild
    $share = Get-ReimageShare
    if (-not (Test-Path -LiteralPath (Join-Path $share "AnswerFiles\$answer.xml"))) {
        Show-Error "Answer file $answer is not on $share, where the PCs read it. Use the share as the content root, or copy the answer file and its image there."; return
    }
    $off = @($rows | Where-Object { -not $_.HasAgent -and $script:adOnline.ContainsKey($_.Address) -and -not $script:adOnline[$_.Address].Online })
    $text = "ERASE and reinstall Windows on $($rows.Count) PC(s) with answer file ${answer}?`n`n$(($rows | ForEach-Object Name) -join ', ')`n`n" +
        'Each PC restarts after a 60 second warning, and anyone logged on loses unsaved work.'
    if ($off) { $text += "`n`n$($off.Count) of them were offline at the last check; they are skipped if they still are." }
    if ($rebuild) { $text += "`n`nThe network boot image is built first ($rebuild), which takes a few minutes." }
    if (-not (Confirm-Action $text)) { return }

    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    # PCs outside the domain sign in with their own local administrator account, asked for each one. For the hidden
    # process each goes in a file protected with this Windows account (DPAPI), deleted as soon as it is read.
    $localCreds = @{}
    $n = 0
    foreach ($r in @($rows | Where-Object { $_.PSObject.Properties['NotInDomain'] -and $_.NotInDomain })) {
        $c = Get-Credential -UserName 'Administrator' -Message ("Local administrator account on $($r.Name) ($($r.Address)), which is not in the domain. " +
            'Its built-in Administrator works; another local admin account needs remote admin allowed on that PC.')
        if (-not $c) { Set-Status 'Reimage cancelled: no account given.'; return }
        $c = [pscredential]::new((ConvertTo-LocalAccountName -User $c.UserName -Computer $r.Address), $c.Password)
        $f = Join-Path $env:TEMP "reimage-$stamp-$tag-local$n.xml"; $n++
        $c | Export-Clixml -Path $f
        $localCreds[$r.Address] = $f
    }
    # Also for PCs with an agent: the network is the way in when the agent does not take its job.
    $cred = if (@($rows | Where-Object { -not $localCreds.ContainsKey($_.Address) })) { Get-AdCredential } else { $null }
    $targetsFile = Join-Path $env:TEMP "reimage-$stamp-$tag-targets.json"
    Save-JsonFile -Path $targetsFile -InputObject @($rows | ForEach-Object {
        $local = $localCreds.ContainsKey($_.Address)
        [ordered]@{ name = $_.Name; address = $_.Address; ou = $_.JoinOU; local = $local; credentialFile = $(if ($local) { $localCreds[$_.Address] } else { '' }) }
    })
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (ConvertTo-Arg "$srcDir\Start-RemoteReimage.ps1"),
        '-ContentRoot', (ConvertTo-Arg $share), '-BootWim', (ConvertTo-Arg (Get-NetworkBootImage -ContentRoot $script:root).Path),
        '-AnswerFile', (ConvertTo-Arg $answer), '-TargetsFile', (ConvertTo-Arg $targetsFile))
    # PCs with an agent go through it: it checks in to the Dashboard's folder, and jobs are signed with this content
    # root's key.
    $statusFolder = Get-DashboardFolder
    if ($statusFolder) { $runArgs += @('-StatusFolder', (ConvertTo-Arg $statusFolder), '-KeyRoot', (ConvertTo-Arg $script:root)) }
    # Each PC keeps its name and joins back into the OU it is in now.
    $runArgs += @('-KeepNames', '-KeepOU')
    if ($cred) {
        # For the hidden process: protected with this Windows account (DPAPI), deleted as soon as it is read.
        $credFile = Join-Path $env:TEMP "reimage-$stamp-$tag-cred.xml"
        $cred | Export-Clixml -Path $credFile
        $runArgs += @('-CredentialFile', (ConvertTo-Arg $credFile))
    }
    $script:pendingReimage = @{ RunArgs = $runArgs; Count = $rows.Count; Title = "Reimaging $($rows.Count) PC(s) with $answer" }
    if ($rebuild) {
        if (-not (Start-NetworkBootBuild)) { $script:pendingReimage = $null }
        Update-AdBootStatus
        return
    }
    Start-PendingReimage
} })

$ui.BtnAdCancel.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $rows = @($ui.GridAd.SelectedItems)
    if (-not $rows) { Show-Error 'Select the PCs whose reimage to cancel.'; return }
    $share = Get-ReimageShare
    if (-not $share) { return }
    $n = 0
    foreach ($r in $rows) {
        $job = Find-ReimageJobByName -ContentRoot $share -ComputerName $r.Name
        if ($job) {
            Remove-ReimageJob -ContentRoot $share -Serial $job.serial; $n++
            $statusFolder = Get-DashboardFolder
            if ($statusFolder) { try { Remove-AgentJob -StatusFolder $statusFolder -Serial $job.serial } catch { } }
        }
    }
    Show-AdRows
    Set-Status "Cancelled $n waiting reimage(s). A PC already restarting into WinPE then waits for someone at its screen."
} })

$ui.BtnAdAgent.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $rows = @($ui.GridAd.SelectedItems)
    if (-not $rows) { Show-Error 'Select the PCs to put the agent on (Ctrl+click or Shift+click for several).'; return }
    $statusFolder = Get-DashboardFolder
    if (-not (Get-ReimageShare) -or -not $statusFolder -or $statusFolder -notlike '\\*') {
        Show-Error 'Set Network share on the Deploy Settings tab first: the agents check in to its Status folder.'; return
    }
    $local = @($rows | Where-Object { $_.PSObject.Properties['NotInDomain'] -and $_.NotInDomain })
    if ($local) { Show-Error "$($local[0].Name) is not in the domain: the agent checks in as the computer account, so it only works on domain PCs."; return }
    # The key pair is made the first time: the PCs get the public key, the jobs are signed with the private one.
    $null = Get-AgentPublicKey -ContentRoot $script:root -Create
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $targetsFile = Join-Path $env:TEMP "agent-$stamp-$tag-targets.json"
    Save-JsonFile -Path $targetsFile -InputObject @($rows | ForEach-Object { [ordered]@{ name = $_.Name; address = $_.Address; ou = ''; local = $false; credentialFile = '' } })
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (ConvertTo-Arg "$srcDir\Install-RemoteAgent.ps1"),
        '-ContentRoot', (ConvertTo-Arg $script:root), '-StatusFolder', (ConvertTo-Arg $statusFolder), '-TargetsFile', (ConvertTo-Arg $targetsFile))
    $cred = Get-AdCredential
    if ($cred) {
        $credFile = Join-Path $env:TEMP "agent-$stamp-$tag-cred.xml"
        $cred | Export-Clixml -Path $credFile
        $runArgs += @('-CredentialFile', (ConvertTo-Arg $credFile))
    }
    $job = Start-ConsoleJob -Name 'agent' -ArgumentList $runArgs -Hidden
    Show-BuildProgress -Owner $window -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title "Installing the agent on $($rows.Count) PC(s)" `
        -Noun 'install' -Hidden -OnFinished { try { Show-AdRows } catch { } }
    Set-Status "Installing the agent on $($rows.Count) PC(s). Each one checks in within a few minutes."
} })

#endregion

#region Media

$ui.LstMediaPacks.Add_SelectionChanged({ Update-MediaPackTotal })
$ui.BtnMediaPacksAll.Add_Click({ Invoke-Safely { $ui.LstMediaPacks.SelectAll() } })
$ui.BtnMediaPacksNone.Add_Click({ Invoke-Safely { $ui.LstMediaPacks.UnselectAll() } })
$ui.BtnUsbRefresh.Add_Click({ Invoke-Safely { Update-UsbDisks } })
$ui.CmbUsb.Add_SelectionChanged({ Invoke-Safely { Update-UsbMode } })
$ui.PwdWinPE.Add_PasswordChanged({ Update-WinPEPasswordAgain })
$ui.BtnAdkCheck.Add_Click({ Invoke-Safely { $s = Update-AdkStatus; Set-Status $(if ($s.Ready) { 'Windows ADK and WinPE add-on found' } else { 'Windows ADK or WinPE add-on missing' }) } })
$ui.BtnAdkDownload.Add_Click({ Invoke-Safely { Start-Process (Get-AdkDownloadUrl) } })

$ui.BtnBuild.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $adk = Update-AdkStatus
    if (-not $adk.Ready) { Show-Error ("Can't build media on this PC yet:`n`n" + ($adk.Problems -join "`n`n")); return }
    $settingsPath = Join-Path $script:root 'config\deploy-settings.json'
    $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg "$srcDir\New-DeploymentMedia.ps1"), '-SettingsPath', (ConvertTo-Arg $settingsPath))

    $disk = $ui.CmbUsb.SelectedItem
    if (-not $disk) { Show-Error 'No USB disk selected. Plug one in and click Refresh.'; return }
    # A stick always has a WinPE password: the answer files' passwords and the key that decrypts them are on it.
    $pePw = $ui.PwdWinPE.Password
    if (-not $pePw) { Show-Error 'Type the WinPE password. Every stick needs one: it locks the passwords on the stick.'; [void]$ui.PwdWinPE.Focus(); return }
    if ($pePw -ne $ui.PwdWinPE2.Password) { Show-Error 'The two WinPE passwords are not the same.'; [void]$ui.PwdWinPE2.Focus(); return }
    if ($pePw.Length -lt 8) { Show-Error 'The WinPE password needs at least 8 characters.'; [void]$ui.PwdWinPE.Focus(); return }
    # Check the answer files and their images before erasing the stick: without them it boots but can't deploy.
    $names = @($ui.LstMediaAnswers.SelectedItems | ForEach-Object Name)
    if (-not $names) { Show-Error 'Check at least one answer file to put on the USB stick. It says which image the stick deploys.'; return }
    # Every pack checked: the whole driver folder, as before. Otherwise only the checked packs.
    $packArgs = @{}
    $allPacks = @($ui.LstMediaPacks.Items)
    $packs = @($ui.LstMediaPacks.SelectedItems | ForEach-Object Path)
    if ($allPacks -and $packs.Count -lt $allPacks.Count) { $packArgs.DriverPacks = $packs }
    $content = Get-MediaContent -ContentRoot $script:root -AnswerFiles $names @packArgs
    if ($content.Problems) { Show-Error ("The USB stick would not deploy:`n`n" + ($content.Problems -join "`n`n")); return }
    if ($allPacks -and -not $packs -and -not (Confirm-Action 'No driver packs are checked, so PCs deployed from this stick get Windows inbox drivers only. Continue?')) { return }
    if ($disk.Ours) {
        if (-not (Confirm-Action "USB disk $($disk.Label) is updated in place: WinPE is replaced, changed files are copied and files the new content no longer has are deleted (its Logs folder is kept). Continue?")) { return }
    } elseif (-not (Confirm-Action "Everything on USB disk $($disk.Label) will be erased. Continue?")) { return }
    # Deployments the stick holds go to the dashboard first: erasing it would lose them.
    $dashFolder = Get-DashboardFolder
    if ($dashFolder) { Import-StickDashboard $dashFolder }
    $buildArgs += @('-Target', 'Usb', '-UsbDiskNumber', $disk.Number, '-Force')
    if ($disk.Ours) { $buildArgs += '-UpdateOnly' }
    $buildArgs += @('-ContentSource', (ConvertTo-Arg $script:root), '-AnswerFiles', ($names -join ','))
    if ($packArgs.ContainsKey('DriverPacks')) {
        if ($packs) { $buildArgs += @('-DriverPacks', (ConvertTo-Arg ($packs -join '|'))) } else { $buildArgs += '-NoDriverPacks' }
    }
    # WinPE password: checked here, handed to the build in a file in %TEMP% that the build deletes once read
    # (a command line argument would show in the process list).
    # Required (checked before anything is asked, see the top of this handler).
    $pwFile = Join-Path $env:TEMP ("winpe-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($pwFile, $ui.PwdWinPE.Password, (New-Object Text.UTF8Encoding($false)))
    try { Save-WinPEPassword -Password $pePw; $script:winPeSaved = $pePw; Update-WinPEPasswordAgain } catch { }
    $buildArgs += @('-WinPEPasswordFile', (ConvertTo-Arg $pwFile))

    # Its own hidden process: the build takes minutes and must not freeze the console. The Progress window shows
    # each step; the build's log (Open log) has every line.
    $job = Start-ConsoleJob -Name 'media-build' -ArgumentList $buildArgs -Hidden
    Show-BuildProgress -Owner $window -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title "Building USB stick $($disk.Label)" -Hidden
    Set-Status 'Media build started. The Build progress window shows each step.'
} })

#endregion

#region Settings

function Set-ShareTestText([string]$Text, [string]$Brush) {
    $ui.TxtShareTest.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $Brush)
    $ui.TxtShareTest.Text = $Text
}
$ui.TxtSharePath.Add_TextChanged({ Update-SettingsState })
$ui.PwdShare.Add_PasswordChanged({ Update-SettingsState })
$ui.TxtShareUser.Add_TextChanged({ Update-SettingsState })

$ui.BtnShareTest.Add_Click({ Invoke-Safely {
    $target = $ui.TxtSharePath.Text.Trim()
    if (-not (Get-UncRoot $target)) { Set-ShareTestText 'Type a share like \\SERVER01\Deploy first.' 'ErrorBrush'; return }
    $user = $ui.TxtShareUser.Text.Trim()
    $pw = $ui.PwdShare.Password
    if ($user -and -not $pw -and $script:sharePwSaved) { $pw = Get-SharePassword -ContentRoot $script:root }
    Set-ShareTestText "Connecting to $target..." 'MutedBrush'
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        $window.Dispatcher.Invoke([action]{}, 'Background')   # let the line paint before net use blocks
        $r = Test-ShareConnection -SharePath $target -User $user -Password $pw
    } finally { $window.Cursor = $null; $pw = $null }
    Set-ShareTestText $r.Message $(if ($r.Ok) { 'SuccessBrush' } else { 'ErrorBrush' })
    Set-Status $(if ($r.Ok) { 'Share connection works' } else { 'Share connection failed' })
} })

$ui.BtnScanTipOpen.Add_Click({ Invoke-Safely { Start-Process 'windowsdefender://threatsettings' } })
$ui.BtnScanTipCopy.Add_Click({ Invoke-Safely {
    $tip = Get-ScanExclusionTip -ContentRoot $(if (Test-ContentRoot $script:root) { $script:root } else { '' })
    if ($tip) { [Windows.Clipboard]::SetText(($tip.Folders -join [Environment]::NewLine)); Set-Status 'Folders copied: paste each one in Windows Security, Add an exclusion, Folder.' }
} })
$ui.BtnScanTipDone.Add_Click({ Invoke-Safely {
    $c = Get-ConsoleConfig
    $tip = Get-ScanExclusionTip -ContentRoot $(if (Test-ContentRoot $script:root) { $script:root } else { '' }) -Config $c
    $hide = @(@(if ($c.PSObject.Properties['scanTipDismissed']) { @($c.scanTipDismissed) }) + @(if ($tip) { $tip.Folders }) | Where-Object { $_ } | Select-Object -Unique)
    $c | Add-Member -NotePropertyName scanTipDismissed -NotePropertyValue $hide -Force
    Save-ConsoleConfig $c
    Update-ScanTip
} })


$ui.BtnSettingsSave.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $problems = @(Get-DeploySettingsProblems -SharePath $ui.TxtSharePath.Text -ShareUser $ui.TxtShareUser.Text `
        -PasswordSaved $script:sharePwSaved -NewPassword $ui.PwdShare.Password)
    if ($problems) { $ui.TxtSettingsProblem.Text = $problems[0]; Set-Status "Not saved: $($problems[0])"; return }
    $ui.TxtSettingsProblem.Text = ''
    $r = Save-DeploySettingsPage -ContentRoot $script:root -SharePath $ui.TxtSharePath.Text -ShareUser $ui.TxtShareUser.Text `
        -NewPassword $ui.PwdShare.Password
    $s = Get-DeploySettings -ContentRoot $script:root
    $checks = [pscustomobject]@{
        enabled       = $true
        ignoreDevices = @($ui.TxtCheckIgnore.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($s.PSObject.Properties['checks']) { $s.checks = $checks } else { $s | Add-Member -NotePropertyName checks -NotePropertyValue $checks }
    Save-DeploySettings -ContentRoot $script:root -Settings $s
    # The domain controller is this console's own (console.json). The Computers tab's next Search uses this account
    # and domain controller.
    Save-AdSettings -Server $ui.TxtAdServer.Text
    # The Computers tab uses this account and share: show the change there too.
    Update-Answers; Update-Settings; Update-Computers; Update-Dashboard
    if ($r.MediaOutOfDate) { $ui.BdrSettingsStale.Visibility = 'Visible' }
    Set-Status 'Deploy settings saved'
} })

#endregion

#region Dashboard

# The count boxes filter the list (PCs listed: all); History shows deployments removed or cleared from here.
foreach ($card in $ui.CardDashRunning, $ui.CardDashSucceeded, $ui.CardDashWarning, $ui.CardDashFailed, $ui.CardDashTotal) {
    $card.Add_MouseLeftButtonUp({ param($sender, $e) Invoke-Safely { $script:dashFilter = "$($sender.Tag)"; Update-Dashboard } })
}
$ui.BtnDashHistory.Add_Click({ Invoke-Safely { $script:dashFilter = 'History'; Update-Dashboard } })
$ui.ChkDashLog.Add_Click({ Invoke-Safely { Update-DashboardDetail } })

$ui.BtnDashLog.Add_Click({ Invoke-Safely {
    $r = $ui.GridDash.SelectedItem
    if (-not $r -or -not $r.LogPath) { Show-Error 'This PC has not sent a log yet.'; return }
    Start-Process -FilePath notepad.exe -ArgumentList (ConvertTo-Arg $r.LogPath)
} })

$ui.BtnDashReimage.Add_Click({ Invoke-Safely {
    # The Computers tab has the answer file, the boot image and the confirmation: open the PC there.
    $r = $ui.GridDash.SelectedItem
    if (-not $r -or -not $r.ComputerName) { return }
    $name = "$($r.ComputerName)".ToUpperInvariant()
    $ui.Tabs.SelectedItem = $ui.TabComputers
    $row = @($ui.GridAd.ItemsSource | Where-Object { "$($_.Name)" -eq $name })[0]
    if (-not $row) {
        $ui.TxtAdName.Text = $name
        Search-AdComputers
        $row = @($ui.GridAd.ItemsSource | Where-Object { "$($_.Name)" -eq $name })[0]
    }
    if ($row) {
        $ui.GridAd.SelectedItems.Clear(); $ui.GridAd.SelectedItem = $row; $ui.GridAd.ScrollIntoView($row)
        Set-Status "$name is selected: choose the answer file and click Reimage."
    } else { Set-Status "$name is not in the domain list: search for it by name or IP on this tab." }
} })

$ui.BtnDashRetry.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $r = $ui.GridDash.SelectedItem
    if (-not $r -or $r.PSObject.Properties['IsHistory']) { return }
    $apps = @(Get-FailedApps -Row $r)
    if (-not $apps) { Show-Error 'No application failed on this PC.'; return }
    $statusFolder = Get-DashboardFolder
    $agent = if ($r.Agent) { $r.Agent } else { Find-AgentCheckIn -CheckIns (Get-ConsoleAgentCheckIns) -Serial "$($r.Serial)" }
    if (-not $agent) { Show-Error "$($r.ComputerName) has no agent checking in. Install it from the Computers tab (Install agent), then try again."; return }
    if (-not $agent.Online) { Show-Error "$($r.ComputerName)'s agent last checked in $("$($agent.LastSeenText)".ToLowerInvariant()). Turn the PC on (and connect it to the network), then try again."; return }
    $appRoot = Join-Path $script:root 'Applications'
    $missing = @($apps | Where-Object { -not (Test-Path -LiteralPath (Join-Path $appRoot $_)) })
    if ($missing) { Show-Error "The application pack $($missing -join ', ') is not in $appRoot."; return }
    if (-not (Confirm-Action "Install $($apps -join ', ') again on $($r.ComputerName)?`n`nIts agent takes the job within a minute and installs in the background; whoever is signed in can keep working. The result shows here when it is done.")) { return }
    $key = Get-AgentSigningKey -ContentRoot $script:root
    if (-not $key) { Show-Error 'This content root has no agent key (config\secrets\agent-key.xml): the PCs would not trust the job.'; return }
    $job = New-AgentJob -StatusFolder $statusFolder -PrivateKey $key -CheckIn $agent -Action installapps -Apps $apps -AppRoot $appRoot `
        -Message "IT is installing $($apps -join ', ') on this PC."
    $script:agentCache = $null
    Set-Status "Sent $($r.ComputerName) a job to install $($apps -join ', ') (job $($job.id.Substring(0, 8))). Agent job shows its progress under the list."
} })
$ui.GridDash.Add_SelectionChanged({ Invoke-Safely { Update-DashboardDetail } })

$ui.BtnDashRemove.Add_Click({ Invoke-Safely {
    $r = $ui.GridDash.SelectedItem
    if (-not $r) { Show-Error 'Select a PC first.'; return }
    if ($r.PSObject.Properties['IsHistory']) { Show-Error 'This deployment is already off the Dashboard.'; return }
    if ($r.State -eq 'Running' -and -not (Confirm-Action "$($r.ComputerName) ($($r.Serial)) is still deploying. Remove it from the dashboard anyway? It reappears at its next update.")) { return }
    Remove-DeploymentStatus -Rows @($r)
    Update-Dashboard
    Set-Status "Removed $($r.Serial) from the dashboard. History has its final log."
} })

$ui.BtnDashOpen.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $folder = Get-DashboardFolder
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Invoke-Item $folder
} })

# Live refresh while the Dashboard tab is open. Errors go to the status bar, not a dialog every 10 seconds.
$script:dashTimer = [Windows.Threading.DispatcherTimer]::new()
$script:dashTimer.Interval = [timespan]::FromSeconds(10)
$script:dashTick = 0
$script:dashTimer.Add_Tick({
    $script:dashTick++
    if ($ui.Tabs.SelectedItem -ne $ui.TabDashboard) {
        # On another tab: every 30 seconds, only look for PCs that finished or failed, to tell you.
        if ($script:dashTick % 3) { return }
        try { $f = Get-DashboardFolder; if ($f) { Show-DashboardNotices -Rows @(Get-DeploymentStatus -Folder $f) } } catch { }
        return
    }
    try { Update-Dashboard } catch { Set-Status "Dashboard refresh failed: $($_.Exception.Message)" }
})
$script:dashTimer.Start()
$ui.Tabs.Add_SelectionChanged({
    param($sender, $e)
    # SelectionChanged bubbles up from the grids and combo boxes inside the tabs; only react to tab switches.
    # Each tab reloads when it is opened (no Refresh buttons). The Driver Library keeps rows being edited until Save.
    if ($e.OriginalSource -eq $ui.Tabs -and (Test-ContentRoot $script:root)) {
        $tab = $ui.Tabs.SelectedItem
        try {
            if ($tab -eq $ui.TabDashboard) { Update-Dashboard }
            elseif ($tab -eq $ui.TabImages) { Update-Images }
            elseif ($tab -eq $ui.TabAnswers) { Update-Answers }
            elseif ($tab -eq $ui.TabLibrary) { Update-Library }
            elseif ($tab -eq $ui.TabDrivers -and -not $script:driversEdited) { Update-Drivers }
        } catch { Set-Status "Refresh failed: $($_.Exception.Message)" }
    }
    if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.TabComputers -and -not $script:adAutoTried) {
        # Once per console session, after the tab has painted.
        $script:adAutoTried = $true
        # Priority first: BeginInvoke(action, 'Background') passes 'Background' as an argument to the action, which
        # takes none, and WPF then stops the console with 'Parameter count mismatch'.
        [void]$window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action]{
            try { Invoke-AdAutoConnect } catch { Set-Status "Could not connect to Active Directory by itself: $($_.Exception.Message)" }
        })
    }
})
# An error in a timer or a queued UI callback (not a button, which runs through Invoke-Safely) would otherwise
# stop the whole console at ShowDialog: log it in full, show one line, and keep the console open.
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    $rec = [Management.Automation.ErrorRecord]::new($e.Exception, 'ConsoleUnhandled', 'NotSpecified', $null)
    $log = Write-ConsoleErrorLog $rec
    $e.Handled = $true
    try { Show-Error "$($e.Exception.Message) (details in $log)" } catch { }
})
# Progress windows hide instead of closing while their work runs; when the console closes, they close with it.
$window.Add_Closing({ $script:ConsoleClosing = $true })
$window.Add_Closed({ Close-ProgressHub })
$window.Add_Closed({ if ($script:dashNotifyIcon) { try { $script:dashNotifyIcon.Visible = $false; $script:dashNotifyIcon.Dispose() } catch { } } })
$window.Add_Closed({ $script:dashTimer.Stop(); $script:scanTimer.Stop(); $script:stickTimer.Stop(); Stop-AdOnlineCheck })

# A stick can be plugged in at any time: look every 5 seconds (DriveInfo only, no disk queries).
$ui.BtnStickOldUpdate.Add_Click({ Invoke-Safely { Select-StickForUpdate } })
$ui.BtnStickOldHide.Add_Click({ $script:stickOldHidden = $ui.TxtStickOld.Text; $ui.BdrStickOld.Visibility = 'Collapsed' })
$script:stickTimer = [Windows.Threading.DispatcherTimer]::new()
$script:stickTimer.Interval = [timespan]::FromSeconds(5)
$script:stickTimer.Add_Tick({ try { Update-StickVersionBanner } catch { $script:stickTimer.Stop(); Set-Status "USB stick version check failed: $($_.Exception.Message)" } })
$script:stickTimer.Start()

#endregion


Update-All
Invoke-Safely { Update-UsbDisks }
Invoke-Safely { Initialize-WinPEPassword }
Invoke-Safely { Update-AdkStatus | Out-Null }
[void]$window.ShowDialog()
