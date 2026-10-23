<#
.SYNOPSIS
    Admin console for the imaging tool: images, driver library, media builder, deploy settings and logs.
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
Import-Module (Join-Path $srcDir 'RemoteReimage.psm1') -Force
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
    Update-Answers; Update-Images; Update-Drivers; Update-Settings; Update-Logs; Update-Pcs
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

#region Remote reimage

$script:pcRows = @()
$script:online = @{}

function Show-PcRows {
    $group = $ui.CmbPcGroup.SelectedItem
    $ui.GridPcs.ItemsSource = @($script:pcRows | Where-Object { -not $group -or $group -eq '(all)' -or $_.Group -eq $group } | ForEach-Object {
        $state = if ($script:online.ContainsKey($_.Mac)) { if ($script:online[$_.Mac]) { 'Yes' } else { 'No' } } else { '' }
        $_ | Add-Member -NotePropertyName Online -NotePropertyValue $state -Force -PassThru
    })
}

function Update-Pcs {
    if (-not (Test-ContentRoot $script:root)) { $script:pcRows = @(); $ui.GridPcs.ItemsSource = $null; return }
    $script:pcRows = @(Get-KnownComputerRows -ContentRoot $script:root)
    $groups = @('(all)') + @($script:pcRows | ForEach-Object Group | Where-Object { $_ } | Sort-Object -Unique)
    $current = $ui.CmbPcGroup.SelectedItem
    $ui.CmbPcGroup.ItemsSource = $groups
    $ui.CmbPcGroup.SelectedItem = if ($current -and $groups -contains $current) { $current } else { '(all)' }
    Show-PcRows

    $s = Get-DeploySettings -ContentRoot $script:root
    $answers = @(Get-ChildItem (Join-Path $script:root 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue | ForEach-Object BaseName)
    $picked = $ui.CmbReimageAnswer.SelectedItem
    $ui.CmbReimageAnswer.ItemsSource = $answers
    $ui.CmbReimageAnswer.SelectedItem = if ($picked -and $answers -contains $picked) { $picked } else { $s.defaultAnswerFile }
    $ui.TxtReimageWds.Text = if ($s.remote) { $s.remote.wdsServer } else { '' }
}

function Get-SelectedPcs {
    $rows = @($ui.GridPcs.SelectedItems)
    if (-not $rows) { Show-Error 'Select one or more PCs first (Ctrl+click or Shift+click for several).' }
    $rows
}

function Save-ReimageWdsServer {
    $s = Get-DeploySettings -ContentRoot $script:root
    if (-not $s.PSObject.Properties['remote']) { $s | Add-Member -NotePropertyName remote -NotePropertyValue ([pscustomobject]@{ wakePort = 9; wdsServer = '' }) }
    if (-not $s.remote.PSObject.Properties['wdsServer']) { $s.remote | Add-Member -NotePropertyName wdsServer -NotePropertyValue '' }
    $s.remote.wdsServer = $ui.TxtReimageWds.Text.Trim()
    Save-DeploySettings -ContentRoot $script:root -Settings $s
}

$ui.CmbPcGroup.Add_SelectionChanged({ Invoke-Safely { Show-PcRows } })
$ui.BtnPcRefresh.Add_Click({ Invoke-Safely { Update-Pcs; Set-Status 'Computer list refreshed' } })

$ui.GridPcs.Add_SelectionChanged({
    $rows = @($ui.GridPcs.SelectedItems)
    if ($rows.Count -ne 1) { return }
    $ui.TxtPcName.Text = $rows[0].Name; $ui.TxtPcMac.Text = $rows[0].Mac; $ui.TxtPcAddress.Text = $rows[0].Computer.address
    $ui.TxtPcGroup.Text = $rows[0].Group; $ui.TxtPcRelay.Text = $rows[0].Relay
})

$ui.BtnPcClear.Add_Click({ foreach ($t in 'TxtPcName', 'TxtPcMac', 'TxtPcAddress', 'TxtPcGroup', 'TxtPcRelay') { $ui[$t].Text = '' } })

$ui.BtnPcSave.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $name = $ui.TxtPcName.Text.Trim(); $mac = $ui.TxtPcMac.Text.Trim(); $address = $ui.TxtPcAddress.Text.Trim()
    if (-not $name) { Show-Error 'Name is required.'; return }
    if (-not $mac) {
        # No MAC typed: read it from the PC, which must be on.
        Set-Status "Reading the MAC address from $name..."
        $info = Get-RemoteComputerInfo -ComputerName $(if ($address) { $address } else { $name })
        $mac = (Update-KnownComputerFromInfo -ContentRoot $script:root -Info $info -Existing ([pscustomobject]@{ name = $name; mac = '' })).mac
    }
    $pc = Save-KnownComputer -ContentRoot $script:root -Mac $mac -Fields @{
        name = $name; address = $address; group = $ui.TxtPcGroup.Text.Trim(); relay = $ui.TxtPcRelay.Text.Trim() }
    Update-Pcs
    Set-Status "Saved $($pc.name) ($($pc.mac))"
} })

$ui.BtnPcRemove.Add_Click({ Invoke-Safely {
    $rows = Get-SelectedPcs; if (-not $rows) { return }
    if (-not (Confirm-Action "Remove $($rows.Count) PC(s) from the list? $(($rows.Name) -join ', ')")) { return }
    foreach ($r in $rows) { Remove-KnownComputer -ContentRoot $script:root -Mac $r.Mac }
    Update-Pcs
    Set-Status "Removed $($rows.Count) PC(s)"
} })

$ui.BtnPcImport.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    if (-not $dlg.ShowDialog($window)) { return }
    $result = Import-KnownComputerCsv -ContentRoot $script:root -Path $dlg.FileName
    Update-Pcs
    Set-Status "Imported $($result.Added) PC(s) from $($dlg.FileName)"
    if ($result.Skipped) { Show-Error ("Imported $($result.Added) PC(s). Skipped:`n" + (($result.Skipped | ForEach-Object { "- $_" }) -join "`n")) }
} })

$ui.BtnPcCheck.Add_Click({ Invoke-Safely {
    $rows = @($ui.GridPcs.ItemsSource)
    if (-not $rows) { return }
    $window.Cursor = 'Wait'
    try { $up = Test-WinRMReachable -ComputerName @($rows.Address) } finally { $window.Cursor = $null }
    foreach ($r in $rows) { $script:online[$r.Mac] = [bool]$up[$r.Address] }
    Show-PcRows
    Set-Status "$(@($rows | Where-Object { $up[$_.Address] }).Count) of $($rows.Count) PCs answer on PowerShell remoting"
} })

$ui.BtnPcRead.Add_Click({ Invoke-Safely {
    $rows = Get-SelectedPcs; if (-not $rows) { return }
    $window.Cursor = 'Wait'
    $failed = [Collections.Generic.List[string]]::new()
    try {
        foreach ($r in $rows) {
            try {
                $pc = Update-KnownComputerFromInfo -ContentRoot $script:root -Info (Get-RemoteComputerInfo -ComputerName $r.Address) -Existing $r.Computer
                # The PC's wired MAC differs from the one listed (a typo, or a new network card): keep only the real one.
                if ((ConvertTo-MacKey $pc.mac) -ne (ConvertTo-MacKey $r.Mac)) {
                    [void](Save-KnownComputer -ContentRoot $script:root -Mac $pc.mac -Fields @{ address = $r.Computer.address; group = $r.Group; relay = $r.Relay })
                    Remove-KnownComputer -ContentRoot $script:root -Mac $r.Mac
                }
                $script:online[$pc.mac] = $true
            } catch { $failed.Add("$($r.Name): $($_.Exception.Message)") }
        }
    } finally { $window.Cursor = $null }
    Update-Pcs
    Set-Status "Read $($rows.Count - $failed.Count) of $($rows.Count) PC(s)"
    if ($failed.Count) { Show-Error ("Could not read:`n" + ($failed -join "`n")) }
} })

$ui.BtnPcWake.Add_Click({ Invoke-Safely {
    $rows = Get-SelectedPcs; if (-not $rows) { return }
    $s = Get-DeploySettings -ContentRoot $script:root
    $port = if ($s.remote -and $s.remote.wakePort) { [int]$s.remote.wakePort } else { 9 }
    foreach ($r in $rows) { Send-WakeOnLan -Computer $r.Computer -Port $port }
    Set-Status "Wake-on-LAN sent to $($rows.Count) PC(s). Click Check online in a minute or two."
} })

$ui.BtnPcReimage.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $rows = Get-SelectedPcs; if (-not $rows) { return }
    $answer = $ui.CmbReimageAnswer.SelectedItem
    if (-not $answer) { Show-Error 'Choose the answer file to deploy.'; return }
    $text = "ERASE and reimage $($rows.Count) PC(s) with answer file $answer?`n`n$(($rows.Name) -join ', ')`n`n" +
        "Running PCs restart after a 60 second warning, and anyone logged on loses unsaved work. PCs that are off are woken up."
    if (-not (Confirm-Action $text)) { return }
    Save-ReimageWdsServer
    $reimageArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg "$srcDir\Start-RemoteReimage.ps1"),
        '-ContentRoot', (ConvertTo-Arg $script:root), '-AnswerFile', (ConvertTo-Arg $answer), '-Mac', (($rows | ForEach-Object { ConvertTo-MacKey $_.Mac }) -join ','))
    if ($ui.ChkKeepNames.IsChecked) { $reimageArgs += '-KeepNames' }
    if ($ui.ChkSkipF12.IsChecked) { $reimageArgs += '-SkipPxePrompt' }
    # Its own window: it waits up to 20 minutes for the PCs to start their deploy.
    Start-Process powershell.exe -ArgumentList $reimageArgs
    Start-Sleep -Milliseconds 1500   # let it write the jobs so the list shows them
    Update-Pcs
    Set-Status "Reimage of $($rows.Count) PC(s) started in a separate window"
} })

$ui.BtnPcCancel.Add_Click({ Invoke-Safely {
    $rows = Get-SelectedPcs; if (-not $rows) { return }
    $wds = Get-WdsServerName (Get-DeploySettings -ContentRoot $script:root)
    foreach ($r in $rows) {
        Remove-ReimageJob -ContentRoot $script:root -Mac $r.Mac
        try { Set-WdsNoPrompt -Server $wds -Mac $r.Mac -Remove } catch { }
    }
    Update-Pcs
    Set-Status "Cancelled the reimage of $($rows.Count) PC(s). A PC that already started its deploy is not stopped."
} })

#endregion

#region Settings

$ui.BtnSettingsSave.Add_Click({ Invoke-Safely {
    if (-not (Test-RootReady)) { return }
    $s = Get-DeploySettings -ContentRoot $script:root
    $s.share.path         = $ui.TxtSharePath.Text.Trim()
    $s.share.user         = $ui.TxtShareUser.Text.Trim()
    $s.share.passwordFile = $ui.TxtSharePwFile.Text.Trim()
    Save-DeploySettings -ContentRoot $script:root -Settings $s
    if ($ui.CmbDefaultAnswer.SelectedItem) { Set-DefaultAnswerFile $ui.CmbDefaultAnswer.SelectedItem }
    Update-Answers; Update-Settings
    Set-Status 'Deploy settings saved'
} })

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
