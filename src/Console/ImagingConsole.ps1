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
Import-Module (Join-Path $PSScriptRoot 'ConsoleData.psm1') -Force
$srcDir = Split-Path $PSScriptRoot -Parent

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
    $default = (Get-DeploySettings -ContentRoot $script:root).defaultImage
    $images = @(Get-ImageList -ContentRoot $script:root | ForEach-Object {
        $_ | Add-Member -NotePropertyName IsDefault -NotePropertyValue $(if ($_.Name -eq $default) { 'Yes' } else { '' }) -PassThru
    })
    $ui.GridImages.ItemsSource = $images
    $ui.CmbDefaultImage.ItemsSource = @($images.Name)
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
    $ui.CmbDefaultImage.Text = $s.defaultImage
    $ui.TxtImageIndex.Text  = $s.imageIndex
    $ui.TxtDiskNumber.Text  = $s.diskNumber
    $ui.TxtNamePattern.Text = $s.computerNamePattern
    $ui.ChkPrompt.IsChecked = [bool]$s.prompt
    $ui.ChkReboot.IsChecked = [bool]$s.rebootWhenDone
}

function Update-Logs {
    $ui.GridLogs.ItemsSource = if (Test-ContentRoot $script:root) { @(Get-DeploymentLogs -ContentRoot $script:root) } else { $null }
    $ui.TxtLog.Text = ''
}

function Update-UsbDisks {
    $ui.CmbUsb.ItemsSource = @(Get-Disk | Where-Object BusType -eq 'USB' | ForEach-Object {
        [pscustomobject]@{
            Number = $_.Number
            Label  = '{0}: {1} ({2:N1} GB)' -f $_.Number, $_.FriendlyName, ($_.Size / 1GB)
        }
    })
    if ($ui.CmbUsb.Items.Count) { $ui.CmbUsb.SelectedIndex = 0 }
}

function Update-All {
    $ui.TxtRoot.Text = $script:root
    Update-Images; Update-Drivers; Update-Settings; Update-Logs
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
    Set-Status "Created Images, Drivers, config and Logs in $($script:root)"
} })

#endregion

#region Images

$ui.BtnImagesRefresh.Add_Click({ Invoke-Safely { Update-Images; Set-Status 'Images refreshed' } })
$ui.BtnImagesOpen.Add_Click({ Invoke-Safely { if (Test-RootReady) { Invoke-Item (Join-Path $script:root 'Images') } } })
$ui.BtnImageDefault.Add_Click({ Invoke-Safely {
    $img = $ui.GridImages.SelectedItem
    if (-not $img) { Show-Error 'Select an image first.'; return }
    $s = Get-DeploySettings -ContentRoot $script:root
    $s.defaultImage = $img.Name
    Save-DeploySettings -ContentRoot $script:root -Settings $s
    Update-Images; Update-Settings
    Set-Status "Default image is now $($img.Name)"
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
    $index = 0; $disk = 0
    if (-not [int]::TryParse($ui.TxtImageIndex.Text, [ref]$index) -or $index -lt 1) { Show-Error 'Image index must be a number of 1 or more.'; return }
    if (-not [int]::TryParse($ui.TxtDiskNumber.Text, [ref]$disk) -or $disk -lt 0) { Show-Error 'Disk number must be 0 or more.'; return }

    $s = Get-DeploySettings -ContentRoot $script:root
    $s.share.path          = $ui.TxtSharePath.Text.Trim()
    $s.share.user          = $ui.TxtShareUser.Text.Trim()
    $s.share.passwordFile  = $ui.TxtSharePwFile.Text.Trim()
    $s.defaultImage        = $ui.CmbDefaultImage.Text.Trim()
    $s.imageIndex          = $index
    $s.diskNumber          = $disk
    $s.computerNamePattern = $ui.TxtNamePattern.Text.Trim()
    $s.prompt              = [bool]$ui.ChkPrompt.IsChecked
    $s.rebootWhenDone      = [bool]$ui.ChkReboot.IsChecked
    Save-DeploySettings -ContentRoot $script:root -Settings $s
    Update-Images
    Set-Status 'Deploy settings saved'
} })

$ui.BtnUnattend.Add_Click({ Invoke-Safely {
    if (Test-RootReady) { Start-Process notepad.exe -ArgumentList "`"$(Join-Path $script:root 'config\unattend.xml')`"" }
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
