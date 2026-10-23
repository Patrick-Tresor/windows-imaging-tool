<#
.SYNOPSIS
    Admin console for the imaging tool: images, driver library, media builder, deploy settings, dashboard and logs.
.DESCRIPTION
    Run on a Windows admin PC. Relaunches itself elevated and in STA mode, which WPF and DISM need.
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\src\Console\ImagingConsole.ps1
#>
[CmdletBinding()]
param()

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$srcDir = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ConsoleData.psm1') -Force
Import-Module (Join-Path $srcDir 'AnswerFile.psm1') -Force
Import-Module (Join-Path $srcDir 'DeployStatus.psm1') -Force
. (Join-Path $PSScriptRoot 'CaptureWizard.ps1')
. (Join-Path $PSScriptRoot 'AnswerEditor.ps1')

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

[xml]$xaml = Get-Content -Raw (Join-Path $PSScriptRoot 'MainWindow.xaml')
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$ui = @{}
$xns = 'http://schemas.microsoft.com/winfx/2006/xaml'
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $node.GetAttribute('Name', $xns)
    $ui[$name] = $window.FindName($name)
}

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
    $rows = if (Test-ContentRoot $script:root) { @(Get-AnswerFileRows -ContentRoot $script:root) } else { @() }
    $ui.GridAnswers.ItemsSource = $rows
    $ui.CmbDefaultAnswer.ItemsSource = @($rows.Name)
    $ui.TxtAnswerIssues.Text = ''
}

function Update-Drivers {
    $script:drivers.Clear()
    if (Test-ContentRoot $script:root) {
        foreach ($r in Get-DriverCatalogRows -ContentRoot $script:root) {
            $row = [DriverRow]::new()
            foreach ($p in 'Maker', 'Model', 'Sku', 'MachineType', 'ModelPattern', 'Path', 'Status') { $row.$p = $r.$p }
            $script:drivers.Add($row)
        }
    }
    $ui.GridDrivers.ItemsSource = $script:drivers
}

function Update-Settings {
    if (-not (Test-ContentRoot $script:root)) { return }
    $s = Get-DeploySettings -ContentRoot $script:root
    $ui.TxtSharePath.Text   = $s.share.path
    $ui.TxtShareUser.Text   = $s.share.user
    $ui.TxtSharePwFile.Text = $s.share.passwordFile
    $ui.CmbDefaultAnswer.SelectedItem = $s.defaultAnswerFile
    $ui.TxtReportPath.Text = if ($s.PSObject.Properties['reporting']) { $s.reporting.path } else { '' }
}

function Get-DashboardFolder {
    if (-not (Test-ContentRoot $script:root)) { return $null }
    Get-StatusFolder -ContentRoot $script:root -Settings (Get-DeploySettings -ContentRoot $script:root)
}

function Update-Dashboard {
    $folder = Get-DashboardFolder
    $rows = if ($folder) { @(Get-DeploymentStatus -Folder $folder) } else { @() }
    $sum = Get-DeploymentSummary -Rows $rows
    $ui.TxtDashRunning.Text   = $sum.Running
    $ui.TxtDashSucceeded.Text = $sum.Succeeded
    $ui.TxtDashWarning.Text   = $sum.Warning
    $ui.TxtDashFailed.Text    = $sum.Failed
    $ui.TxtDashTotal.Text     = $sum.Total

    $states = switch ($ui.CmbDashFilter.SelectedIndex) {
        1 { @('Running') }
        2 { @('Failed', 'Stalled') }
        3 { @('Succeeded', 'Warning', 'Cancelled') }
        default { $null }
    }
    if ($states) { $rows = @($rows | Where-Object State -in $states) }

    # Keep the selected PC selected across refreshes.
    $selectedId = if ($ui.GridDash.SelectedItem) { $ui.GridDash.SelectedItem.Id } else { $null }
    $ui.GridDash.ItemsSource = $rows
    if ($selectedId) { $ui.GridDash.SelectedItem = $rows | Where-Object Id -eq $selectedId | Select-Object -First 1 }
    Update-DashboardDetail
}

function Update-DashboardDetail {
    $r = $ui.GridDash.SelectedItem
    if (-not $r) { $ui.TxtDashDetail.Text = ''; $ui.TxtDashLog.Text = ''; return }
    $parts = @(
        "Image: $($r.Image)", "Drivers: $($r.DriverPack)", "MAC: $($r.MacAddress)", "Phase: $($r.Phase)",
        "Updated: $(if ($r.Updated) { $r.Updated.ToString('yyyy-MM-dd HH:mm:ss') })"
    )
    if ($r.Message)  { $parts += "Error: $($r.Message)" }
    if ($r.Warnings) { $parts += "Warnings: $($r.Warnings)" }
    $ui.TxtDashDetail.Text = $parts -join '    '
    $text = if ($r.LogPath) { try { [IO.File]::ReadAllText($r.LogPath) } catch { '' } } else { 'No log reported yet.' }
    if ($text -ne $ui.TxtDashLog.Text) { $ui.TxtDashLog.Text = $text; $ui.TxtDashLog.ScrollToEnd() }
}

function Update-Logs {
    $ui.GridLogs.ItemsSource = if (Test-ContentRoot $script:root) { @(Get-DeploymentLogs -ContentRoot $script:root) } else { $null }
    $ui.TxtLog.Text = ''
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

function Update-All {
    $ui.TxtRoot.Text = $script:root
    Update-Answers; Update-Images; Update-Drivers; Update-Settings; Update-Dashboard; Update-Logs
    Set-Status $(if (Test-ContentRoot $script:root) { "Loaded $($script:root)" } else { 'Choose a content root to start' })
}

#endregion

#region Content root

$ui.BtnBrowseRoot.Add_Click({ Invoke-Safely {
    $path = Select-Folder 'Choose the content root: a USB DEPLOY volume, a local folder, or the network share'
    if (-not $path) { return }
    $script:root = $path
    Save-ConsoleConfig ([pscustomobject]@{ contentRoot = $path })
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

$ui.BtnImagesRefresh.Add_Click({ Invoke-Safely { Update-Images; Set-Status 'Images refreshed' } })
$ui.BtnCapture.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    if (Show-CaptureWizard -Owner $window -ContentRoot $script:root -SrcDir $srcDir) {
        Set-Status 'Capture started in a separate window. Click Refresh on the Images tab when it finishes.'
    }
} })
$ui.BtnImagesOpen.Add_Click({ Invoke-Safely { if (Test-RootReady) { Invoke-Item (Join-Path $script:root 'Images') } } })

#endregion

#region Answer files

function Set-DefaultAnswerFile([string]$Name) {
    $s = Get-DeploySettings -ContentRoot $script:root
    if ($s.PSObject.Properties['defaultAnswerFile']) { $s.defaultAnswerFile = $Name }
    else { $s | Add-Member -NotePropertyName defaultAnswerFile -NotePropertyValue $Name }
    Save-DeploySettings -ContentRoot $script:root -Settings $s
}

function Edit-AnswerFile([string]$Path, [string]$NewName) {
    $saved = if ($Path) { Show-AnswerEditor -Owner $window -ContentRoot $script:root -Path $Path }
             else { Show-AnswerEditor -Owner $window -ContentRoot $script:root -NewName $NewName }
    if ($saved) { Update-Answers; Update-Images; Set-Status 'Answer file saved' }
}

$ui.BtnAnswerRefresh.Add_Click({ Invoke-Safely { Update-Answers; Update-Images; Set-Status 'Answer files refreshed' } })
$ui.BtnAnswerOpen.Add_Click({ Invoke-Safely { if (Test-RootReady) { Invoke-Item (Join-Path $script:root 'AnswerFiles') } } })

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

$ui.BtnAnswerImport.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Filter = 'SmartDeploy answer file (*.xml)|*.xml'
    if (-not $dlg.ShowDialog($window)) { return }
    $result = Import-SmartDeployAnswerFile -ContentRoot $script:root -Path $dlg.FileName
    Update-Answers; Update-Images
    $text = "Imported as $($result.Name). Passwords are not carried over: enter them in the editor that opens next.`n`nAlso check:`n" + (($result.Notes | ForEach-Object { "- $_" }) -join "`n")
    [Windows.MessageBox]::Show($window, $text, 'SmartDeploy import', 'OK', 'Information') | Out-Null
    Set-Status "Imported $($result.Name) from $($dlg.FileName)"
    Edit-AnswerFile -Path $result.Path
} })

$ui.BtnAnswerEdit.Add_Click({ Invoke-Safely {
    $row = $ui.GridAnswers.SelectedItem
    if (-not $row) { Show-Error 'Select an answer file first.'; return }
    Edit-AnswerFile -Path $row.FullName
} })

$ui.BtnAnswerDefault.Add_Click({ Invoke-Safely {
    $row = $ui.GridAnswers.SelectedItem
    if (-not $row) { Show-Error 'Select an answer file first.'; return }
    Set-DefaultAnswerFile $row.Name
    Update-Answers; Update-Settings
    Set-Status "Default answer file is now $($row.Name)"
} })

#endregion

#region Driver library

$ui.BtnDriversRefresh.Add_Click({ Invoke-Safely { Update-Drivers; Set-Status 'Driver library refreshed' } })
$ui.BtnDriversOpen.Add_Click({ Invoke-Safely { if (Test-RootReady) { Invoke-Item (Join-Path $script:root 'Drivers') } } })

$ui.BtnDriversRemove.Add_Click({ Invoke-Safely {
    $row = $ui.GridDrivers.SelectedItem
    if ($row -isnot [DriverRow]) { return }
    if (Confirm-Action "Remove the catalog entry for $($row.Maker) $(@($row.Model, $row.Sku, $row.MachineType, $row.ModelPattern) -ne '' | Select-Object -First 1)? The driver files stay on disk. Click Save to keep the change.") {
        [void]$script:drivers.Remove($row)
    }
} })

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

#region Media

$ui.BtnUsbRefresh.Add_Click({ Invoke-Safely { Update-UsbDisks } })
$ui.BtnOutput.Add_Click({ $p = Select-Folder 'Where to write the ISO or boot.wim'; if ($p) { $ui.TxtOutput.Text = $p } })
$ui.BtnPeDrivers.Add_Click({ $p = Select-Folder 'Folder of extra drivers for WinPE (NIC, storage)'; if ($p) { $ui.TxtPeDrivers.Text = $p } })

$ui.BtnBuild.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $settingsPath = Join-Path $script:root 'config\deploy-settings.json'
    $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg "$srcDir\New-DeploymentMedia.ps1"), '-SettingsPath', (ConvertTo-Arg $settingsPath))

    if ($ui.RbUsb.IsChecked) {
        $disk = $ui.CmbUsb.SelectedItem
        if (-not $disk) { Show-Error 'No USB disk selected. Plug one in and click Refresh.'; return }
        if (-not (Confirm-Action "Everything on USB disk $($disk.Label) will be erased. Continue?")) { return }
        $buildArgs += @('-Target', 'Usb', '-UsbDiskNumber', $disk.Number, '-Force')
        if ($ui.ChkCopyContent.IsChecked) { $buildArgs += @('-ContentSource', (ConvertTo-Arg $script:root)) }
    } else {
        if (-not $ui.TxtOutput.Text) { Show-Error 'Choose an output folder.'; return }
        $buildArgs += @('-Target', $(if ($ui.RbIso.IsChecked) { 'Iso' } else { 'Pxe' }), '-OutputPath', (ConvertTo-Arg $ui.TxtOutput.Text))
    }
    if ($ui.TxtPeDrivers.Text) { $buildArgs += @('-WinPEDrivers', (ConvertTo-Arg $ui.TxtPeDrivers.Text)) }

    # Its own window: the build takes minutes, shows ADK output, and must not freeze the console.
    $buildArgs = @('-NoExit') + $buildArgs
    Start-Process powershell.exe -ArgumentList $buildArgs
    Set-Status 'Media build started in a separate window'
} })

#endregion

#region Settings

$ui.BtnSettingsSave.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $s = Get-DeploySettings -ContentRoot $script:root
    $s.share.path         = $ui.TxtSharePath.Text.Trim()
    $s.share.user         = $ui.TxtShareUser.Text.Trim()
    $s.share.passwordFile = $ui.TxtSharePwFile.Text.Trim()
    if (-not $s.PSObject.Properties['reporting']) { $s | Add-Member -NotePropertyName reporting -NotePropertyValue ([pscustomobject]@{ path = '' }) }
    $s.reporting.path     = $ui.TxtReportPath.Text.Trim()
    Save-DeploySettings -ContentRoot $script:root -Settings $s
    if ($ui.CmbDefaultAnswer.SelectedItem) { Set-DefaultAnswerFile $ui.CmbDefaultAnswer.SelectedItem }
    Update-Answers; Update-Settings; Update-Dashboard
    Set-Status 'Deploy settings saved'
} })

#endregion

#region Dashboard

$ui.BtnDashRefresh.Add_Click({ Invoke-Safely { Update-Dashboard; Set-Status 'Dashboard refreshed' } })
$ui.CmbDashFilter.Add_SelectionChanged({ Invoke-Safely { Update-Dashboard } })
$ui.GridDash.Add_SelectionChanged({ Invoke-Safely { Update-DashboardDetail } })

$ui.BtnDashRemove.Add_Click({ Invoke-Safely {
    $r = $ui.GridDash.SelectedItem
    if (-not $r) { Show-Error 'Select a PC first.'; return }
    if ($r.State -eq 'Running' -and -not (Confirm-Action "$($r.ComputerName) ($($r.Serial)) is still deploying. Remove it from the dashboard anyway? It reappears at its next update.")) { return }
    Remove-DeploymentStatus -Rows @($r)
    Update-Dashboard
    Set-Status "Removed $($r.Serial) from the dashboard. Its final log stays in Deployment Logs."
} })

$ui.BtnDashClear.Add_Click({ Invoke-Safely {
    $folder = Get-DashboardFolder
    if (-not $folder) { return }
    $done = @(Get-DeploymentStatus -Folder $folder | Where-Object State -in 'Succeeded', 'Warning', 'Cancelled')
    if (-not $done) { Set-Status 'No finished deployments to clear'; return }
    if (-not (Confirm-Action "Clear $($done.Count) finished deployment(s) from the dashboard? Failed and stalled PCs stay, and final logs stay in Deployment Logs.")) { return }
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
    if (-not $ui.ChkDashAuto.IsChecked -or $ui.Tabs.SelectedItem -ne $ui.TabDashboard) { return }
    try { Update-Dashboard } catch { Set-Status "Dashboard refresh failed: $($_.Exception.Message)" }
})
$script:dashTimer.Start()
$ui.Tabs.Add_SelectionChanged({
    param($sender, $e)
    # SelectionChanged bubbles up from the grids and combo boxes inside the tabs; only react to tab switches.
    if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.TabDashboard) {
        try { Update-Dashboard } catch { Set-Status "Dashboard refresh failed: $($_.Exception.Message)" }
    }
})
$window.Add_Closed({ $script:dashTimer.Stop() })

#endregion

#region Logs

$ui.BtnLogsRefresh.Add_Click({ Invoke-Safely { Update-Logs; Set-Status 'Logs refreshed' } })
$ui.GridLogs.Add_SelectionChanged({ Invoke-Safely {
    $log = $ui.GridLogs.SelectedItem
    $ui.TxtLog.Text = if ($log) { Get-Content -Raw $log.FullName } else { '' }
} })

#endregion

Update-All
Invoke-Safely { Update-UsbDisks }
[void]$window.ShowDialog()
