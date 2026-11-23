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
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# With the console window hidden, an error that stops the console before (or after) its window opens would leave
# nothing on screen. Show it in a message box and keep it in %LOCALAPPDATA%\ImagingConsole\console-error.log.
trap {
    $msg = "$($_.Exception.Message)"
    $where = "$($_.InvocationInfo.PositionMessage)"
    $log = [IO.Path]::Combine($env:LOCALAPPDATA, 'ImagingConsole', 'console-error.log')
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($log))
        [IO.File]::AppendAllText($log, ('{0:yyyy-MM-dd HH:mm:ss} {1}{2}{3}{2}{2}' -f (Get-Date), $msg, [Environment]::NewLine, $where))
    } catch { }
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
$ui.TxtToolVersion.Text = "version $($script:toolVersion.Text)"
$script:stickOldHidden = ''
$script:bootOldMsg = $null

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

function Get-WinPEDriverArgs {
    # The Media tab's extra WinPE drivers as build arguments: the USB build and the network boot image use the same.
    # Dell's and HP's WinPE driver packs always go in (New-DeploymentMedia's default).
    $a = @()
    if ($ui.TxtPeDrivers.Text) { $a += @('-WinPEDrivers', (ConvertTo-Arg $ui.TxtPeDrivers.Text)) }
    $a
}

function Invoke-Safely([scriptblock]$Action) {
    # Every button runs through here so one failure shows a message instead of closing the console.
    try { & $Action } catch { Show-Error $_.Exception.Message }
}

function Test-RootReady {
    if (Test-ContentRoot $script:root) { return $true }
    Show-Error 'Choose a content root first (Browse...), then click Create folders if it is new.'
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
    $ui.ChkChecksEnabled.IsChecked = "$(& $get 'enabled' $true)" -notmatch '^(false|0|no|off)$'
    $ui.TxtCheckIgnore.Text = @(& $get 'ignoreDevices' @()) -join '; '
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

function Update-Dashboard {
    $folder = Get-DashboardFolder
    if ($folder) { Import-StickDashboard $folder }
    $rows = @(if ($folder) { Get-DeploymentStatus -Folder $folder })
    $sum = Get-DeploymentSummary -Rows $rows
    $ui.TxtDashRunning.Text   = $sum.Running
    $ui.TxtDashSucceeded.Text = $sum.Succeeded
    $ui.TxtDashWarning.Text   = $sum.Warning
    $ui.TxtDashFailed.Text    = $sum.Failed
    $ui.TxtDashTotal.Text     = $sum.Total

    if ($ui.CmbDashFilter.SelectedIndex -eq 4) {
        # History: deployments removed or cleared from the Dashboard, from their final log in Logs\.
        $onDash = @($rows | ForEach-Object LogFile)
        $rows = @(if (Test-ContentRoot $script:root) { Get-DeploymentHistoryRows -ContentRoot $script:root -DashboardLogFiles $onDash })
    } else {
        $states = @(switch ($ui.CmbDashFilter.SelectedIndex) {
            1 { 'Running' }
            2 { 'Failed', 'Stalled' }
            3 { 'Succeeded', 'Warning', 'Cancelled' }
        })
        if ($states) { $rows = @($rows | Where-Object State -in $states) }
    }

    # Keep the selected PC selected across refreshes.
    $selectedId = if ($ui.GridDash.SelectedItem) { $ui.GridDash.SelectedItem.Id } else { $null }
    $ui.GridDash.ItemsSource = $rows
    if ($selectedId) { $ui.GridDash.SelectedItem = $rows | Where-Object Id -eq $selectedId | Select-Object -First 1 }
    Update-DashboardDetail
}

function Update-DashboardDetail {
    $r = $ui.GridDash.SelectedItem
    if (-not $r) { $ui.TxtDashDetail.Text = ''; $ui.TxtDashLog.Text = ''; return }
    if ($r.PSObject.Properties['IsHistory']) {
        $ui.TxtDashDetail.Text = "Final log of $($r.Serial), $($r.State), $($r.Started.ToString('yyyy-MM-dd HH:mm'))"
        $text = try { [IO.File]::ReadAllText($r.LogPath) } catch { '' }
        if ($text -ne $ui.TxtDashLog.Text) { $ui.TxtDashLog.Text = $text; $ui.TxtDashLog.ScrollToEnd() }
        return
    }
    # The deployment's result first (one line each: drivers, applications, tasks, join, BitLocker, time), then the rest.
    $parts = @("MAC: $($r.MacAddress)", "Phase: $($r.Phase)", "Updated: $(if ($r.Updated) { $r.Updated.ToString('yyyy-MM-dd HH:mm:ss') })")
    if ($r.Message)  { $parts += "Error: $($r.Message)" }
    if ($r.Warnings) { $parts += "Warnings: $($r.Warnings)" }
    $ui.TxtDashDetail.Text = $(if ($r.ResultText) { $r.ResultText + "`n" } else { '' }) + ($parts -join '    ')
    if ($r.Checked) { $ui.TxtDashDetail.Text += "    Checked: $($r.Checked.ToString('yyyy-MM-dd HH:mm'))" }
    $text = if ($r.LogPath) { try { [IO.File]::ReadAllText($r.LogPath) } catch { '' } } else { 'No log reported yet.' }
    if ($text -ne $ui.TxtDashLog.Text) { $ui.TxtDashLog.Text = $text; $ui.TxtDashLog.ScrollToEnd() }
}

function Update-Library {
    # Applications and tasks in one list (Apps and Tasks tab); the selection stays when the row is still there.
    $keep = $ui.GridLibrary.SelectedItem
    $rows = @(if (Test-ContentRoot $script:root) { Get-LibraryRows -ContentRoot $script:root })
    $ui.GridLibrary.ItemsSource = $rows
    if ($keep) { $ui.GridLibrary.SelectedItem = @($rows | Where-Object { $_.Kind -eq $keep.Kind -and $_.Name -eq $keep.Name })[0] }
    if (-not $ui.GridLibrary.SelectedItem) { $ui.TxtLibIssues.Text = '' }
}

function Get-UsbDiskChoices {
    Get-Disk | Where-Object BusType -eq 'USB' | ForEach-Object {
        [pscustomobject]@{
            Number = $_.Number
            Label  = '{0}: {1} ({2:N1} GB)' -f $_.Number, $_.FriendlyName, ($_.Size / 1GB)
        }
    }
}

function Update-UsbDisks {
    $ui.CmbUsb.ItemsSource = @(Get-UsbDiskChoices)
    if ($ui.CmbUsb.Items.Count) { $ui.CmbUsb.SelectedIndex = 0 }
}

function Update-StickVersionBanner {
    # A banner at the top when a plugged-in stick was built with an older version of the tool: the fix the operator
    # expects is then not on the stick. "Not now" hides it until another stick (or another version) is plugged in.
    # The network boot image gets the same banner, with a Rebuild button (checked on refresh, not on the timer).
    $stick = Get-StaleStickMessage -Console $script:toolVersion -StickRoots (Get-DeployStickRoots)
    $msg = (@($stick, $script:bootOldMsg) | Where-Object { $_ }) -join ' '
    if ($msg -and $msg -ne $script:stickOldHidden) {
        $ui.TxtStickOld.Text = $msg
        $ui.BtnStickOldUpdate.Visibility = if ($stick) { 'Visible' } else { 'Collapsed' }
        $ui.BtnBootOldRebuild.Visibility = if ($script:bootOldMsg) { 'Visible' } else { 'Collapsed' }
        $ui.BdrStickOld.Visibility = 'Visible'
    } else {
        $ui.BdrStickOld.Visibility = 'Collapsed'
    }
}

function Update-BootVersionBanner {
    # Is <content root>\Boot\boot.wim older than this console? Then the banner says so (Update-StickVersionBanner).
    $script:bootOldMsg = if ($script:root) { try { Get-StaleBootImageMessage -Console $script:toolVersion -ContentRoot $script:root } catch { $null } }
    Update-StickVersionBanner
}

function Select-StickForUpdate {
    # "Update the stick", one click: the Media tab with the old stick's disk, "Update a stick" ticked, the answer
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
    $ui.ChkUsbUpdate.IsChecked = $true
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
    try { Update-BootVersionBanner } catch { }
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
    if (-not (Test-ContentRoot $path)) { Set-Status 'This folder is not a content root yet. Click Create folders.' }
    Update-All
} })

$ui.BtnInitRoot.Add_Click({ Invoke-Safely {
    if (-not $script:root) { Show-Error 'Choose a folder with Browse... first.'; return }
    Initialize-ContentRoot -Path $script:root
    Update-All
    Set-Status "Created the content folders (Images, Drivers, AnswerFiles, Applications, config, Logs) in $($script:root)"
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

function Get-SelectedLibraryRow([string]$Kind) {
    # The selected row; with -Kind only a row of that kind (Test detection is for applications).
    $row = $ui.GridLibrary.SelectedItem
    if (-not $row -or ($Kind -and $row.Kind -ne $Kind)) {
        Show-Error $(if ($Kind -eq 'Application') { 'Select an application first.' } else { 'Select an application or a task first.' })
        return
    }
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

$ui.BtnAppTest.Add_Click({ Invoke-Safely {
    $row = Get-SelectedLibraryRow Application
    if (-not $row -or -not $row.Definition) { return }
    $res = Test-AppDetection -Definition $row.Definition -AppFolder $row.FullName
    $ui.TxtLibIssues.Text = if (-not $res.HasRules) { "$($row.Name) has no detection rules." } else {
        "$($row.Name) on this PC: $(if ($res.Detected) { 'installed' } else { 'not installed' })`r`n" +
        (($res.Details | ForEach-Object { "$(if ($_.Found) { 'found' } else { 'not found' }): $($_.Rule) ($($_.Detail))" }) -join "`r`n")
    }
    Set-Status "Detection tested for $($row.Name)"
} })

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
    $maker = $ui.CmbMaker.Text.Trim()
    $model = $ui.TxtModel.Text.Trim()
    if (-not $maker -or -not $model -or -not $ui.TxtSource.Text) { Show-Error 'Maker, model and source are required.'; return }
    $window.Cursor = 'Wait'
    Set-Status "Importing $maker $model..."
    try {
        $result = Import-DriverPack -ContentRoot $script:root -Source $ui.TxtSource.Text -Maker $maker -Model $model `
            -Sku $ui.TxtSku.Text.Trim() -MachineType $ui.TxtMachineType.Text.Trim()
    } finally { $window.Cursor = $null }
    Update-Drivers
    $ui.TxtModel.Text = ''; $ui.TxtSku.Text = ''; $ui.TxtMachineType.Text = ''; $ui.TxtSource.Text = ''
    Set-Status "Imported $($result.InfCount) drivers to Drivers\$($result.Path)"
    if ($result.InfCount -eq 0) { Show-Error 'No .inf files were found after import. The pack may need extracting first.' }
} })

#endregion

#region Computers (Active Directory)

$script:adRows = @()
$script:adOnline = @{}
$script:adCredential = $null
$script:adCredentialUser = ''
$script:adLoaded = $false

function Get-AdSettings {
    # The Computers tab's domain, domain controller, account and OU, kept in console.json (never a password).
    $c = Get-ConsoleConfig
    if ($c.PSObject.Properties['activeDirectory'] -and $c.activeDirectory) { return $c.activeDirectory }
    [pscustomobject]@{ domain = ''; server = ''; user = ''; searchBase = ''; useShareAccount = $true }
}

function Save-AdSettings {
    $c = Get-ConsoleConfig
    $ad = [pscustomobject]@{
        domain = $ui.TxtAdDomain.Text.Trim(); server = $ui.TxtAdServer.Text.Trim()
        # The Deploy Settings account is not copied here: it is read from deploy-settings.json each time.
        user = $(if ($ui.ChkAdUseShare.IsChecked) { "$($script:adOwnUser)" } else { $ui.TxtAdUser.Text.Trim() })
        useShareAccount = [bool]$ui.ChkAdUseShare.IsChecked
        searchBase = $(if ($ui.CmbAdOu.SelectedItem) { "$($ui.CmbAdOu.SelectedItem.DN)" } else { '' })
    }
    $c | Add-Member -NotePropertyName activeDirectory -NotePropertyValue $ad -Force
    Save-ConsoleConfig $c
}

$script:adOwnUser = ''

function Get-ShareAccount {
    # The account on the Deploy Settings tab, or $null when none is set there.
    if (-not (Test-ContentRoot $script:root)) { return $null }
    $v = Get-DeploySettingsView -ContentRoot $script:root
    if (-not $v.ShareUser) { return $null }
    $v
}

function Update-AdAccount {
    # Shows which account the Computers tab uses: the Deploy Settings one (read only here, change it there) or its own.
    $share = Get-ShareAccount
    if ($ui.ChkAdUseShare.IsChecked) {
        $ui.TxtAdUser.Text = if ($share) { $share.ShareUser } else { '' }
        $ui.TxtAdUser.IsReadOnly = $true
        $ui.TxtAdUser.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'ControlHoverBrush')
    } else {
        $ui.TxtAdUser.Text = "$($script:adOwnUser)"
        $ui.TxtAdUser.IsReadOnly = $false
        $ui.TxtAdUser.ClearValue([Windows.Controls.Control]::BackgroundProperty)
    }
    # The domain from that account (user@corp.local), else the one this PC is joined to, when none is typed.
    if (-not $ui.TxtAdDomain.Text.Trim()) {
        $d = Get-AdDomainFromAccount $ui.TxtAdUser.Text
        $ui.TxtAdDomain.Text = if ($d) { $d } else { Get-AdDefaultDomain }
    }
}

function Get-AdCredential {
    # With Use the Deploy Settings account: that account and the password saved there, never asked.
    # Otherwise the account typed on the tab, its password asked once per console session and kept in memory only.
    # $null = the account the console runs as.
    if ($ui.ChkAdUseShare.IsChecked) {
        $share = Get-ShareAccount
        if (-not $share) { throw 'No account on the Deploy Settings tab yet. Set it there, or untick Use the Deploy Settings account.' }
        $pw = Get-SharePassword -ContentRoot $script:root
        if (-not $pw) { throw "No password saved for $($share.ShareUser) on the Deploy Settings tab. Save it there, or untick Use the Deploy Settings account." }
        return [pscredential]::new($share.ShareUser, (ConvertTo-SecureString $pw -AsPlainText -Force))
    }
    $user = $ui.TxtAdUser.Text.Trim()
    if (-not $user) { return $null }
    if ($script:adCredential -and $script:adCredentialUser -eq $user) { return $script:adCredential }
    $cred = Get-Credential -UserName $user -Message 'Password for Active Directory and the PCs to reimage'
    if (-not $cred) { throw 'No password given.' }
    $script:adCredential = $cred; $script:adCredentialUser = $user
    $cred
}

function Get-ReimageShare {
    # Reimage jobs go on the deployment share, where WinPE looks for them.
    "$((Get-DeploySettings -ContentRoot $script:root).share.path)".Trim()
}

function Update-AdBootStatus {
    if (-not (Test-ContentRoot $script:root)) { $ui.TxtAdBoot.Text = ''; return }
    $boot = Get-NetworkBootImage -ContentRoot $script:root
    $problems = @(Get-RemoteReimageProblems -Settings (Get-DeploySettings -ContentRoot $script:root) -Boot $boot)
    $ui.TxtAdBoot.Text = if ($problems) { $problems[0] } else { "Network boot image built $($boot.Built), maps $($boot.Share). Boot\Deploy-WinPE.iso boots a VM or a PC from the same share." }
    $ui.TxtAdBoot.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($problems) { 'WarningBrush' } else { 'SuccessBrush' }))
}

function Show-AdRows {
    $states = @{}
    if ($script:adRows -and (Test-ContentRoot $script:root)) {
        $share = Get-ReimageShare
        if ($share) { try { $states = Get-ReimageStates -ContentRoot $share } catch { } }
    }
    $ui.GridAd.ItemsSource = @($script:adRows | ForEach-Object {
        $check = if ($script:adOnline.ContainsKey($_.Address)) { $script:adOnline[$_.Address] }
        $_ | Add-Member -NotePropertyName Online -NotePropertyValue $(if ($check) { $check.State } else { '' }) -Force
        # The address the online check reached; a PC found by IP shows that IP before any check.
        $ip = if ($check -and $check.Ip) { $check.Ip } elseif ($_.Address -match '^\d+(\.\d+){3}$') { $_.Address } else { '' }
        $_ | Add-Member -NotePropertyName IpAddress -NotePropertyValue $ip -Force
        $_ | Add-Member -NotePropertyName OnlineDetail -NotePropertyValue $(if ($check) { "$($_.Name) $($check.Detail)" } else { $null }) -Force
        $_ | Add-Member -NotePropertyName Reimage -NotePropertyValue $(if ($states.ContainsKey($_.Name)) { $states[$_.Name] } else { '' }) -Force -PassThru
    })
}

function Update-Computers {
    if (-not $script:adLoaded) {
        $script:adLoaded = $true
        $ad = Get-AdSettings
        $ui.TxtAdDomain.Text = "$($ad.domain)"
        $ui.TxtAdServer.Text = "$($ad.server)"
        $script:adOwnUser = "$($ad.user)"
        # Older console.json files have no useShareAccount: use the Deploy Settings account unless one was typed here.
        $ui.ChkAdUseShare.IsChecked = if ($ad.PSObject.Properties['useShareAccount']) { [bool]$ad.useShareAccount } else { -not $ad.user }
        $ou = if ($ad.searchBase) { [pscustomobject]@{ Path = (ConvertTo-AdFriendlyPath "$($ad.searchBase)"); DN = "$($ad.searchBase)" } }
              else { [pscustomobject]@{ Path = '(whole domain)'; DN = '' } }
        $ui.CmbAdOu.ItemsSource = @($ou)
        $ui.CmbAdOu.SelectedIndex = 0
    }
    $answers = @(if (Test-ContentRoot $script:root) { Get-ChildItem (Join-Path $script:root 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue | ForEach-Object BaseName })
    $picked = $ui.CmbAdAnswer.SelectedItem
    $ui.CmbAdAnswer.ItemsSource = $answers
    # No default answer file: keep the one picked, or the only one there is.
    $ui.CmbAdAnswer.SelectedItem = if ($picked -and $answers -contains $picked) { $picked } elseif ($answers.Count -eq 1) { $answers[0] } else { $null }
    Update-AdAccount
    Update-AdBootStatus
    Show-AdRows
}

function Search-AdComputers {
    $base = if ($ui.CmbAdOu.SelectedItem) { "$($ui.CmbAdOu.SelectedItem.DN)" } else { '' }
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
                $found = @(Get-AdComputers -Domain $ui.TxtAdDomain.Text.Trim() -Server $ui.TxtAdServer.Text.Trim() -SearchBase $base -Name $find.Name `
                    -Credential $cred)
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
        Set-Status "Checking which of the $($script:adRows.Count) computers are online..."
        Update-AdOnline
    } finally { $window.Cursor = $null }
    Save-AdSettings
    Show-AdRows
    Set-Status "$($script:adRows.Count) computer(s) found. $(Get-AdOnlineSummary)$localNote"
}

function Update-AdOnline {
    $script:adOnline = if ($script:adRows) { Get-RemoteOnlineState -ComputerName @($script:adRows | ForEach-Object Address) } else { @{} }
}

function Get-AdOnlineSummary {
    # One line: how many answer on PowerShell remoting, and what to do about the first one that does not.
    Get-OnlineSummaryText -Rows @($script:adRows | Where-Object { $script:adOnline[$_.Address] } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; State = $script:adOnline[$_.Address].State } })
}

function Connect-AdDirectory {
    # Reads the OUs and lists the computers. Connect runs it, and so does opening the tab (Invoke-AdAutoConnect).
    $cred = Get-AdCredential
    $window.Cursor = 'Wait'
    try {
        Set-Status 'Reading the OUs from Active Directory...'
        $ous = @(Get-AdOrganizationalUnits -Domain $ui.TxtAdDomain.Text.Trim() -Server $ui.TxtAdServer.Text.Trim() -Credential $cred)
    } finally { $window.Cursor = $null }
    $keep = "$((Get-AdSettings).searchBase)"
    $items = @([pscustomobject]@{ Path = '(whole domain)'; DN = '' }) + $ous
    $ui.CmbAdOu.ItemsSource = $items
    $sel = @($items | Where-Object { $_.DN -eq $keep })
    $ui.CmbAdOu.SelectedItem = if ($sel) { $sel[0] } else { $items[0] }
    Search-AdComputers
}

function Invoke-AdAutoConnect {
    # The first time the Computers tab opens: connect by itself when nothing has to be typed (the Deploy Settings
    # account with its saved password, or this PC's own sign-in), and fold the Connect box away. A failure leaves
    # the box open with one line in the status bar.
    if (-not (Test-ContentRoot $script:root)) { return }
    if ($ui.ChkAdUseShare.IsChecked) {
        if (-not (Get-ShareAccount) -or -not (Get-SharePassword -ContentRoot $script:root)) { return }
    } elseif ($ui.TxtAdUser.Text.Trim() -and -not ($script:adCredential -and $script:adCredentialUser -eq $ui.TxtAdUser.Text.Trim())) { return }
    try {
        Connect-AdDirectory
        $ui.GrpAdConnect.Visibility = 'Collapsed'
        $ui.BtnAdShowConnect.Visibility = 'Visible'
    } catch {
        $window.Cursor = $null
        Set-Status "Could not connect to Active Directory by itself: $($_.Exception.Message)"
    }
}

$ui.BtnAdConnect.Add_Click({ Invoke-Safely { Connect-AdDirectory } })
$ui.BtnAdShowConnect.Add_Click({
    $ui.GrpAdConnect.Visibility = 'Visible'
    $ui.BtnAdShowConnect.Visibility = 'Collapsed'
})

$ui.ChkAdUseShare.Add_Click({ Invoke-Safely {
    # Turned on: keep what was typed in the box, to show it again when turned off.
    if ($ui.ChkAdUseShare.IsChecked) { $script:adOwnUser = $ui.TxtAdUser.Text.Trim() }
    Update-AdAccount
    Save-AdSettings
} })

$ui.BtnAdSearch.Add_Click({ Invoke-Safely { Search-AdComputers } })
$ui.TxtAdName.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { Invoke-Safely { Search-AdComputers } } })

$ui.BtnAdOnline.Add_Click({ Invoke-Safely {
    if (-not $script:adRows) { Show-Error 'Click Connect or Search first.'; return }
    $window.Cursor = 'Wait'
    try { Update-AdOnline } finally { $window.Cursor = $null }
    Show-AdRows
    Set-Status (Get-AdOnlineSummary)
} })

$ui.BtnAdBuildBoot.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $adk = Update-AdkStatus
    if (-not $adk.Ready) { Show-Error ("Can't build media on this PC yet:`n`n" + ($adk.Problems -join "`n`n")); return }
    if (-not (Get-ReimageShare)) { Show-Error 'Set Network share on the Deploy Settings tab first: WinPE loads the image from there.'; return }
    $out = Join-Path $script:root 'Boot'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    # No WinPE password: nobody is at the PCs to type it. The share password goes in encrypted with the answer file key.
    $buildArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg "$srcDir\New-DeploymentMedia.ps1"),
        '-SettingsPath', (ConvertTo-Arg (Join-Path $script:root 'config\deploy-settings.json')), '-Target', 'Wim', '-OutputPath', (ConvertTo-Arg $out))
    $buildArgs += Get-WinPEDriverArgs
    $job = Start-ConsoleJob -Name 'network-boot' -ArgumentList $buildArgs
    Show-BuildProgress -Owner $window -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title 'Building the network boot image' -OnFinished { try { Update-AdBootStatus; Update-BootVersionBanner } catch { } }
    Set-Status 'Network boot image build started.'
} })

$ui.BtnAdReimage.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $rows = @($ui.GridAd.SelectedItems)
    if (-not $rows) { Show-Error 'Select one or more PCs first (Ctrl+click or Shift+click for several).'; return }
    $answer = $ui.CmbAdAnswer.SelectedItem
    if (-not $answer) { Show-Error 'Choose the answer file to deploy.'; return }
    $self = @($rows | Where-Object { $_.Name -eq "$env:COMPUTERNAME".ToUpperInvariant() })
    if ($self) { Show-Error "$($self[0].Name) is this PC, the one running the console: reimage it from the USB stick."; return }
    $problems = @(Get-RemoteReimageProblems -Settings (Get-DeploySettings -ContentRoot $script:root) -Boot (Get-NetworkBootImage -ContentRoot $script:root))
    if ($problems) { Show-Error $problems[0]; return }
    $share = Get-ReimageShare
    if (-not (Test-Path -LiteralPath (Join-Path $share "AnswerFiles\$answer.xml"))) {
        Show-Error "Answer file $answer is not on $share, where the PCs read it. Use the share as the content root, or copy the answer file and its image there."; return
    }
    $off = @($rows | Where-Object { $script:adOnline.ContainsKey($_.Address) -and -not $script:adOnline[$_.Address].Online })
    $text = "ERASE and reinstall Windows on $($rows.Count) PC(s) with answer file ${answer}?`n`n$(($rows | ForEach-Object Name) -join ', ')`n`n" +
        'Each PC restarts after a 60 second warning, and anyone logged on loses unsaved work.'
    if ($off) { $text += "`n`n$($off.Count) of them were offline at the last check; they are skipped if they still are." }
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
    $cred = if (@($rows | Where-Object { -not $localCreds.ContainsKey($_.Address) })) { Get-AdCredential } else { $null }
    $targetsFile = Join-Path $env:TEMP "reimage-$stamp-$tag-targets.json"
    Save-JsonFile -Path $targetsFile -InputObject @($rows | ForEach-Object {
        $local = $localCreds.ContainsKey($_.Address)
        [ordered]@{ name = $_.Name; address = $_.Address; ou = $_.JoinOU; local = $local; credentialFile = $(if ($local) { $localCreds[$_.Address] } else { '' }) }
    })
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (ConvertTo-Arg "$srcDir\Start-RemoteReimage.ps1"),
        '-ContentRoot', (ConvertTo-Arg $share), '-BootWim', (ConvertTo-Arg (Get-NetworkBootImage -ContentRoot $script:root).Path),
        '-AnswerFile', (ConvertTo-Arg $answer), '-TargetsFile', (ConvertTo-Arg $targetsFile))
    # Each PC keeps its name and joins back into the OU it is in now.
    $runArgs += @('-KeepNames', '-KeepOU')
    if ($cred) {
        # For the hidden process: protected with this Windows account (DPAPI), deleted as soon as it is read.
        $credFile = Join-Path $env:TEMP "reimage-$stamp-$tag-cred.xml"
        $cred | Export-Clixml -Path $credFile
        $runArgs += @('-CredentialFile', (ConvertTo-Arg $credFile))
    }
    $job = Start-ConsoleJob -Name 'reimage' -ArgumentList $runArgs -Hidden
    Show-BuildProgress -Owner $window -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title "Reimaging $($rows.Count) PC(s) with $answer" `
        -Noun 'reimage' -Hidden -OnFinished { try { Show-AdRows } catch { } }
    Set-Status "Reimage of $($rows.Count) PC(s) started. Each deploy then shows on the Dashboard."
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
        if ($job) { Remove-ReimageJob -ContentRoot $share -Serial $job.serial; $n++ }
    }
    Show-AdRows
    Set-Status "Cancelled $n waiting reimage(s). A PC already restarting into WinPE then waits for someone at its screen."
} })

#endregion

#region Media

$ui.LstMediaPacks.Add_SelectionChanged({ Update-MediaPackTotal })
$ui.BtnMediaPacksAll.Add_Click({ Invoke-Safely { $ui.LstMediaPacks.SelectAll() } })
$ui.BtnMediaPacksNone.Add_Click({ Invoke-Safely { $ui.LstMediaPacks.UnselectAll() } })
$ui.BtnUsbRefresh.Add_Click({ Invoke-Safely { Update-UsbDisks } })
$ui.BtnAdkCheck.Add_Click({ Invoke-Safely { $s = Update-AdkStatus; Set-Status $(if ($s.Ready) { 'Windows ADK and WinPE add-on found' } else { 'Windows ADK or WinPE add-on missing' }) } })
$ui.BtnAdkDownload.Add_Click({ Invoke-Safely { Start-Process (Get-AdkDownloadUrl) } })
$ui.BtnPeDrivers.Add_Click({ $p = Select-Folder 'Folder of extra drivers for WinPE (NIC, storage)'; if ($p) { $ui.TxtPeDrivers.Text = $p } })

$ui.BtnBuild.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $adk = Update-AdkStatus
    if (-not $adk.Ready) { Show-Error ("Can't build media on this PC yet:`n`n" + ($adk.Problems -join "`n`n")); return }
    $settingsPath = Join-Path $script:root 'config\deploy-settings.json'
    $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg "$srcDir\New-DeploymentMedia.ps1"), '-SettingsPath', (ConvertTo-Arg $settingsPath))

    $disk = $ui.CmbUsb.SelectedItem
    if (-not $disk) { Show-Error 'No USB disk selected. Plug one in and click Refresh.'; return }
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
    if ($ui.ChkUsbUpdate.IsChecked) {
        if (-not (Confirm-Action "USB disk $($disk.Label) is updated in place: WinPE is replaced, changed files are copied and files the new content no longer has are deleted (its Logs folder is kept). Continue?")) { return }
    } elseif (-not (Confirm-Action "Everything on USB disk $($disk.Label) will be erased. Continue?")) { return }
    # Deployments the stick holds go to the dashboard first: erasing it would lose them.
    $dashFolder = Get-DashboardFolder
    if ($dashFolder) { Import-StickDashboard $dashFolder }
    $buildArgs += @('-Target', 'Usb', '-UsbDiskNumber', $disk.Number, '-Force')
    if ($ui.ChkUsbUpdate.IsChecked) { $buildArgs += '-UpdateOnly' }
    $buildArgs += @('-ContentSource', (ConvertTo-Arg $script:root), '-AnswerFiles', ($names -join ','))
    if ($packArgs.ContainsKey('DriverPacks')) {
        if ($packs) { $buildArgs += @('-DriverPacks', (ConvertTo-Arg ($packs -join '|'))) } else { $buildArgs += '-NoDriverPacks' }
    }
    $buildArgs += Get-WinPEDriverArgs
    # WinPE password: checked here, handed to the build in a file in %TEMP% that the build deletes once read
    # (a command line argument would show in the process list).
    $pePw = $ui.PwdWinPE.Password
    if ($pePw -or $ui.PwdWinPE2.Password) {
        if ($pePw -ne $ui.PwdWinPE2.Password) { Show-Error 'The two WinPE passwords are not the same.'; return }
        if ($pePw.Length -lt 8) { Show-Error 'The WinPE password needs at least 8 characters.'; return }
        $pwFile = Join-Path $env:TEMP ("winpe-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($pwFile, $pePw, (New-Object Text.UTF8Encoding($false)))
        $buildArgs += @('-WinPEPasswordFile', (ConvertTo-Arg $pwFile))
    } else {
        if (-not (Confirm-Action 'No WinPE password: the deploy asks for nothing, because the answer files carry their passwords encrypted and the key is in boot.wim. But anyone with the stick can boot it, and could take that key out of boot.wim to decrypt the passwords. Set a WinPE password to lock the stick. Continue?')) { return }
    }

    # Its own process, minimized: the build takes minutes and must not freeze the console. The Build progress
    # window shows each step; the build's window (Show build window) and its log have every line.
    $job = Start-ConsoleJob -Name 'media-build' -ArgumentList (@('-NoExit') + $buildArgs)
    Show-BuildProgress -Owner $window -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title "Building USB stick $($disk.Label)"
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

$ui.BtnSettingsMedia.Add_Click({ $ui.Tabs.SelectedItem = $ui.TabMedia })

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
        enabled       = [bool]$ui.ChkChecksEnabled.IsChecked
        ignoreDevices = @($ui.TxtCheckIgnore.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($s.PSObject.Properties['checks']) { $s.checks = $checks } else { $s | Add-Member -NotePropertyName checks -NotePropertyValue $checks }
    Save-DeploySettings -ContentRoot $script:root -Settings $s
    # The Computers tab uses this account and share: show the change there too.
    Update-Answers; Update-Settings; Update-Computers; Update-Dashboard
    if ($r.MediaOutOfDate) { $ui.BdrSettingsStale.Visibility = 'Visible' }
    Set-Status 'Deploy settings saved'
} })

#endregion

#region Dashboard

$ui.CmbDashFilter.Add_SelectionChanged({ Invoke-Safely { Update-Dashboard } })
$ui.GridDash.Add_SelectionChanged({ Invoke-Safely { Update-DashboardDetail } })

$ui.BtnDashRemove.Add_Click({ Invoke-Safely {
    $r = $ui.GridDash.SelectedItem
    if (-not $r) { Show-Error 'Select a PC first.'; return }
    if ($r.PSObject.Properties['IsHistory']) { Show-Error 'This deployment is already off the Dashboard.'; return }
    if ($r.State -eq 'Running' -and -not (Confirm-Action "$($r.ComputerName) ($($r.Serial)) is still deploying. Remove it from the dashboard anyway? It reappears at its next update.")) { return }
    Remove-DeploymentStatus -Rows @($r)
    Update-Dashboard
    Set-Status "Removed $($r.Serial) from the dashboard. Show: History has its final log."
} })

$ui.BtnDashClear.Add_Click({ Invoke-Safely {
    $folder = Get-DashboardFolder
    if (-not $folder) { return }
    $done = @(Get-DeploymentStatus -Folder $folder | Where-Object State -in 'Succeeded', 'Warning', 'Cancelled')
    if (-not $done) { Set-Status 'No finished deployments to clear'; return }
    if (-not (Confirm-Action "Clear $($done.Count) finished deployment(s) from the dashboard? Failed and stalled PCs stay. Their final logs stay under Show: History.")) { return }
    Remove-DeploymentStatus -Rows $done
    Update-Dashboard
    Set-Status "Cleared $($done.Count) finished deployment(s)"
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
$script:dashTimer.Add_Tick({
    if ($ui.Tabs.SelectedItem -ne $ui.TabDashboard) { return }
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
        [void]$window.Dispatcher.BeginInvoke([action]{ Invoke-AdAutoConnect }, 'Background')
    }
})
# Progress windows hide instead of closing while their work runs; when the console closes, they close with it.
$window.Add_Closing({ $script:ConsoleClosing = $true })
$window.Add_Closed({ $script:dashTimer.Stop(); $script:scanTimer.Stop(); $script:stickTimer.Stop() })

# A stick can be plugged in at any time: look every 5 seconds (DriveInfo only, no disk queries).
$ui.BtnStickOldUpdate.Add_Click({ Invoke-Safely { Select-StickForUpdate } })
$ui.BtnBootOldRebuild.Add_Click({ $ui.BtnAdBuildBoot.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) })
$ui.BtnStickOldHide.Add_Click({ $script:stickOldHidden = $ui.TxtStickOld.Text; $ui.BdrStickOld.Visibility = 'Collapsed' })
$script:stickTimer = [Windows.Threading.DispatcherTimer]::new()
$script:stickTimer.Interval = [timespan]::FromSeconds(5)
$script:stickTimer.Add_Tick({ try { Update-StickVersionBanner } catch { $script:stickTimer.Stop(); Set-Status "USB stick version check failed: $($_.Exception.Message)" } })
$script:stickTimer.Start()

#endregion


Update-All
Invoke-Safely { Update-UsbDisks }
Invoke-Safely { Update-AdkStatus | Out-Null }
[void]$window.ShowDialog()
