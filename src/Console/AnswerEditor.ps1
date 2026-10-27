# Answer file editor window: every setting of an answer file as a form, like SmartDeploy's answer file wizard.
# Dot-sourced by ImagingConsole.ps1, which loads WPF, ConsoleData.psm1 and AnswerFile.psm1.

# Real .NET types so the editable grids can bind two-way.
class TaskRow {
    [string]$Phase
    [string]$Command
}

class BiosRow {
    [string]$Maker
    [string]$Name
    [string]$Value
}

class ShareRow {
    [string]$LocalName
    [string]$RemoteName
    [string]$Username
    [string]$Domain
    [string]$PasswordFile
}

function Get-XamlControls($Xaml, $Window) {
    $map = @{}
    foreach ($node in $Xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $map[$name] = $Window.FindName($name)
    }
    $map
}

function Show-AnswerEditor {
    <#
    .SYNOPSIS
        Opens the editor for an existing answer file (-Path) or a new one (-NewName). Returns $true when saved.
    #>
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [string]$Path,
        [string]$NewName
    )
    $isNew = -not $Path
    $a = if ($isNew) { Get-NewAnswer -Name $NewName } else { Read-AnswerFile -Path $Path -SkipValidation }

    [xml]$ex = Get-Content -Raw (Join-Path $PSScriptRoot 'AnswerEditor.xaml')
    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($ex))
    $win.Owner = $Owner
    Enable-WheelScrolling $win
    $e = Get-XamlControls $ex $win
    $win.Title = if ($isNew) { 'New answer file' } else { "Answer file: $($a.Name)" }
    $state = @{ Saved = $false; SharePasswords = @{} }

    # --- Choices -------------------------------------------------------------------------------------------
    $images = @(Get-ImageList -ContentRoot $ContentRoot)
    $e.CmbImage.ItemsSource = @($images | ForEach-Object { "Images\$($_.Name)" })
    $e.CmbTimeZone.ItemsSource = @([TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object Id)
    $cultures = @([Globalization.CultureInfo]::GetCultures('SpecificCultures') | Sort-Object Name | ForEach-Object Name)
    foreach ($c in 'CmbInputLocale', 'CmbUserLocale', 'CmbSystemLocale', 'CmbUILanguage') { $e[$c].ItemsSource = $cultures }
    $e.GridTasks.Columns[0].ItemsSource = @('POSTIMAGE', 'FIRSTBOOT', 'FIRSTLOGON')
    $e.GridBios.Columns[0].ItemsSource = @('Dell', 'HP', 'Lenovo')
    $e.CmbBiosPreset.ItemsSource = @('Dell', 'HP', 'Lenovo')
    $e.CmbBiosPreset.SelectedIndex = 0
    $e.CmbBlMethod.ItemsSource = @('XtsAes256', 'XtsAes128', 'Aes256', 'Aes128')

    $updateIndexes = {
        # Editions from the selected image, as "index: name". A pinned version lists that copy's editions.
        # Falls back to typing a number.
        $img = $images | Where-Object { "Images\$($_.Name)" -eq $e.CmbImage.Text } | Select-Object -First 1
        $pinned = if ($e.CmbVersion.SelectedItem) { $e.CmbVersion.SelectedItem.Version } else { '' }
        if ($img -and $pinned) {
            $editions = @()
            try { $editions = @(Get-ImageEditions -ImagePath (Get-ImageVersionPath -ImagePath (Join-Path (Join-Path $ContentRoot 'Images') $img.Name) -Version $pinned)) } catch { }
            $e.CmbIndex.ItemsSource = $editions
        } else {
            $e.CmbIndex.ItemsSource = @(if ($img -and $img.Indexes) { $img.Indexes -split '; ' })
        }
    }
    $updateVersions = {
        # Current plus the versions kept in Images\Previous for an image in the Images folder, with $Want selected.
        param([string]$Want)
        $state.VersionsFor = $e.CmbImage.Text
        $items = @([pscustomobject]@{ Version = ''; Display = 'Current (follows recaptures, updates and rollbacks)' })
        $img = $images | Where-Object { "Images\$($_.Name)" -eq $e.CmbImage.Text } | Select-Object -First 1
        if ($img) {
            $items += @(Get-ImageVersionRows -ContentRoot $ContentRoot -ImageName $img.Name | Where-Object Version | ForEach-Object {
                [pscustomobject]@{ Version = $_.Version; Display = ('{0}   {1}{2}' -f $_.Version, $_.Reason, $(if ($_.Note) { " - $($_.Note)" })) }
            })
        }
        if ($Want -and -not ($items | Where-Object Version -eq $Want)) {
            $items += [pscustomobject]@{ Version = $Want; Display = "$Want   (missing from Images\Previous)" }
        }
        $e.CmbVersion.ItemsSource = $items
        $e.CmbVersion.SelectedItem = $items | Where-Object Version -eq $Want | Select-Object -First 1
        & $updateIndexes
    }
    $e.CmbVersion.Add_SelectionChanged({ & $updateIndexes })
    $e.CmbImage.Add_SelectionChanged({ $win.Dispatcher.BeginInvoke([Action]{ if ($e.CmbImage.Text -ne $state.VersionsFor) { & $updateVersions '' } else { & $updateIndexes } }) | Out-Null })

    # --- Load ------------------------------------------------------------------------------------------------
    $e.TxtName.Text = $a.Name
    $e.TxtName.IsEnabled = $isNew
    $e.RbInteractive.IsChecked = $a.Mode -ne 'Unattended'
    $e.RbUnattended.IsChecked = $a.Mode -eq 'Unattended'
    $e.TxtDelay.Text = $a.UnattendDelay
    $e.RbShutdown.IsChecked = $a.Shutdown
    $e.RbReboot.IsChecked = -not $a.Shutdown -and $a.Reboot
    $e.RbStay.IsChecked = -not $a.Shutdown -and -not $a.Reboot

    $e.CmbImage.Text = $a.ImageFile
    & $updateVersions "$($a.ImageVersion)"
    $e.CmbIndex.Text = $a.ImageIndex
    $e.TxtDisk.Text = $a.DiskNumber
    $e.CmbWin11Check.SelectedIndex = [math]::Max(0, [array]::IndexOf(@('Block', 'Warn', 'Off'), "$($a.Windows11Check)"))
    $e.TxtDrivers.Text = $a.DriverRoot

    $selected = [Collections.ObjectModel.ObservableCollection[string]]::new()
    foreach ($n in $a.Applications) { $selected.Add($n) }
    $e.LstSelected.ItemsSource = $selected
    $refreshAvailable = {
        $e.LstAvailable.ItemsSource = @(Get-ApplicationList -ContentRoot $ContentRoot | Where-Object { $selected -notcontains $_.Name })
    }
    & $refreshAvailable

    $e.TxtFullName.Text = $a.FullName
    $e.TxtOrg.Text = $a.Organization
    $e.TxtProductKey.Text = $a.ProductKey
    $e.CmbTimeZone.Text = $a.TimeZone
    $e.CmbInputLocale.Text = $a.InputLocale
    $e.CmbUserLocale.Text = $a.UserLocale
    $e.CmbSystemLocale.Text = $a.SystemLocale
    $e.CmbUILanguage.Text = $a.UILanguage
    $e.ChkNoRestore.IsChecked = $a.DisableSystemRestore
    $e.ChkAdmin.IsChecked = $a.EnableAdministrator
    $pwState = { param($file) if (Test-SecretFile -ContentRoot $ContentRoot -RelativePath $file) { 'A password is saved. Leave empty to keep it.' } else { 'No password saved yet.' } }
    $e.TxtAdminPwState.Text = & $pwState $a.AdminPasswordFile

    $e.RbNameWmi.IsChecked = $a.NamingMode -eq 'WMI'
    $e.RbNameCustom.IsChecked = $a.NamingMode -eq 'Custom'
    $e.RbNamePrompt.IsChecked = $a.NamingMode -eq 'Prompt'
    $e.TxtPrefix.Text = $a.Prefix
    $e.CmbWmi.Text = $a.WmiQuery
    $e.TxtScheme.Text = $a.CustomScheme

    $e.RbDomain.IsChecked = $a.Membership -eq 'Domain'
    $e.RbWorkgroup.IsChecked = $a.Membership -ne 'Domain'
    $e.TxtDomain.Text = $a.Domain
    $e.TxtOU.Text = $a.OrganizationalUnit
    $e.TxtJoinUser.Text = $a.JoinUser
    $e.TxtJoinDomain.Text = $a.JoinDomain
    $e.TxtWorkgroup.Text = $a.Workgroup
    $e.TxtJoinPwState.Text = & $pwState $a.JoinPasswordFile

    $tasks = [Collections.ObjectModel.ObservableCollection[TaskRow]]::new()
    foreach ($t in $a.Tasks) { $r = [TaskRow]::new(); $r.Phase = $t.Phase; $r.Command = $t.Command; $tasks.Add($r) }
    $e.GridTasks.ItemsSource = $tasks

    $shares = [Collections.ObjectModel.ObservableCollection[ShareRow]]::new()
    foreach ($s in $a.Shares) {
        $r = [ShareRow]::new()
        foreach ($p in 'LocalName', 'RemoteName', 'Username', 'Domain', 'PasswordFile') { $r.$p = $s.$p }
        $shares.Add($r)
    }
    $e.GridShares.ItemsSource = $shares

    $bios = [Collections.ObjectModel.ObservableCollection[BiosRow]]::new()
    foreach ($s in $a.Bios.Settings) { $r = [BiosRow]::new(); $r.Maker = $s.Maker; $r.Name = $s.Name; $r.Value = $s.Value; $bios.Add($r) }
    $e.GridBios.ItemsSource = $bios
    $e.ChkBios.IsChecked = $a.Bios.Enabled
    $e.TxtBiosTools.Text = $a.Bios.ToolsRoot
    $e.ChkBiosStop.IsChecked = $a.Bios.StopOnError
    $e.TxtBiosPwState.Text = if ($a.Bios.PasswordFile) { & $pwState $a.Bios.PasswordFile } else { 'No password saved: the PCs have none.' }

    $bl = $a.BitLocker
    $e.ChkBitLocker.IsChecked = $bl.Enabled
    $e.CmbBlMethod.SelectedItem = $bl.EncryptionMethod
    $e.ChkBlUsedSpace.IsChecked = $bl.UsedSpaceOnly
    $e.RbBlTpm.IsChecked = $bl.Protector -ne 'TpmPin'
    $e.RbBlTpmPin.IsChecked = $bl.Protector -eq 'TpmPin'
    $e.TxtBlPinState.Text = & $pwState $bl.PinFile
    $e.ChkBlAD.IsChecked = $bl.BackupToAD
    $e.TxtBlFolder.Text = $bl.RecoveryKeyFolder
    $e.ChkBlRequire.IsChecked = $bl.RequireBackup

    $e.ChkMigrate.IsChecked = $a.MigrateUserData
    $e.RbStoreLocal.IsChecked = $a.UserDataStore -ne 'Share'
    $e.RbStoreShare.IsChecked = $a.UserDataStore -eq 'Share'
    $e.TxtStorePath.Text = $a.UserDataPath
    $e.ChkEncrypt.IsChecked = $a.UserDataEncrypt
    $e.TxtUsmtKeyState.Text = & $pwState $a.UserDataKeyFile
    $e.ChkMigDocs.IsChecked = 'MigDocs.xml' -in $a.UserDataRules
    $e.ChkMigApp.IsChecked = 'MigApp.xml' -in $a.UserDataRules
    $e.TxtExtraRules.Text = @($a.UserDataRules | Where-Object { $_ -notin 'MigDocs.xml', 'MigApp.xml' }) -join '; '
    $e.TxtExcludeUsers.Text = @($a.UserDataExclude) -join '; '
    $e.ChkLocalAccounts.IsChecked = $a.UserDataLocalAccounts
    $e.ChkKeepStore.IsChecked = $a.UserDataKeepStore

    # --- Behaviour -------------------------------------------------------------------------------------------
    $e.LstSections.Add_SelectionChanged({
        for ($i = 0; $i -lt $e.LstSections.Items.Count; $i++) { $e["Sec$i"].Visibility = if ($i -eq $e.LstSections.SelectedIndex) { 'Visible' } else { 'Collapsed' } }
    })
    $e.LstSections.SelectedIndex = 0

    $syncEnabled = {
        $e.TxtDelay.IsEnabled = [bool]$e.RbUnattended.IsChecked
        $e.PwdAdmin.IsEnabled = [bool]$e.ChkAdmin.IsChecked
        $e.CmbWmi.IsEnabled = -not $e.RbNameCustom.IsChecked
        $e.TxtScheme.IsEnabled = [bool]$e.RbNameCustom.IsChecked
        $dom = [bool]$e.RbDomain.IsChecked
        foreach ($c in 'TxtDomain', 'TxtOU', 'TxtJoinUser', 'TxtJoinDomain', 'PwdJoin') { $e[$c].IsEnabled = $dom }
        $e.TxtWorkgroup.IsEnabled = -not $dom
        $on = [bool]$e.ChkBios.IsChecked
        foreach ($c in 'PwdBios', 'TxtBiosTools', 'ChkBiosStop', 'GridBios', 'BtnBiosAdd', 'BtnBiosRemove', 'CmbBiosPreset', 'BtnBiosPreset') { $e[$c].IsEnabled = $on }
        $on = [bool]$e.ChkBitLocker.IsChecked
        foreach ($c in 'CmbBlMethod', 'ChkBlUsedSpace', 'RbBlTpm', 'RbBlTpmPin', 'TxtBlFolder', 'ChkBlRequire') { $e[$c].IsEnabled = $on }
        $e.PwdBlPin.IsEnabled = $on -and $e.RbBlTpmPin.IsChecked
        # Recovery keys only go to AD from a domain-joined PC.
        $e.ChkBlAD.IsEnabled = $on -and $dom
        if (-not $dom) { $e.ChkBlAD.IsChecked = $false }
        $e.GridMigrate.IsEnabled = [bool]$e.ChkMigrate.IsChecked
        $share = [bool]$e.RbStoreShare.IsChecked
        $e.TxtStorePath.IsEnabled = $share
        $e.ChkEncrypt.IsEnabled = $share
        $e.PwdUsmtKey.IsEnabled = $share -and [bool]$e.ChkEncrypt.IsChecked
    }
    foreach ($c in 'RbInteractive', 'RbUnattended', 'RbNameWmi', 'RbNameCustom', 'RbNamePrompt', 'RbDomain', 'RbWorkgroup', 'RbBlTpm', 'RbBlTpmPin', 'RbStoreLocal', 'RbStoreShare') { $e[$c].Add_Checked($syncEnabled) }
    foreach ($c in 'ChkAdmin', 'ChkBios', 'ChkBitLocker', 'ChkMigrate', 'ChkEncrypt') { $e[$c].Add_Click($syncEnabled) }
    & $syncEnabled

    # Applications
    $e.BtnAppAdd.Add_Click({ $app = $e.LstAvailable.SelectedItem; if ($app) { $selected.Add($app.Name); & $refreshAvailable } })
    $e.LstAvailable.Add_MouseDoubleClick({ $app = $e.LstAvailable.SelectedItem; if ($app) { $selected.Add($app.Name); & $refreshAvailable } })
    $e.BtnAppRemove.Add_Click({ $n = $e.LstSelected.SelectedItem; if ($n) { [void]$selected.Remove($n); & $refreshAvailable } })
    $e.BtnAppUp.Add_Click({ $i = $e.LstSelected.SelectedIndex; if ($i -gt 0) { $selected.Move($i, $i - 1); $e.LstSelected.SelectedIndex = $i - 1 } })
    $e.BtnAppDown.Add_Click({ $i = $e.LstSelected.SelectedIndex; if ($i -ge 0 -and $i -lt $selected.Count - 1) { $selected.Move($i, $i + 1); $e.LstSelected.SelectedIndex = $i + 1 } })
    $e.BtnNewApp.Add_Click({
        # With a missing app selected in the install order (e.g. from a SmartDeploy import), build that one.
        $sel = $e.LstSelected.SelectedItem
        $missing = if ($sel -and -not (Test-Path (Join-Path $ContentRoot "Applications\$sel\app.json"))) { $sel }
        $name = if ($missing) { Show-AppPackEditor -Owner $win -ContentRoot $ContentRoot -SuggestedName $missing }
                else { Show-AppPackEditor -Owner $win -ContentRoot $ContentRoot }
        if ($name -and $selected -notcontains $name) { $selected.Add($name) }
        if ($name) { & $refreshAvailable }
    })

    # Tasks
    $e.BtnTaskAdd.Add_Click({ $r = [TaskRow]::new(); $r.Phase = 'FIRSTBOOT'; $tasks.Add($r); $e.GridTasks.SelectedItem = $r })
    $e.BtnTaskRemove.Add_Click({ $r = $e.GridTasks.SelectedItem; if ($r -is [TaskRow]) { [void]$tasks.Remove($r) } })
    $e.BtnTaskUp.Add_Click({ $i = $e.GridTasks.SelectedIndex; if ($i -gt 0) { $tasks.Move($i, $i - 1) } })
    $e.BtnTaskDown.Add_Click({ $i = $e.GridTasks.SelectedIndex; if ($i -ge 0 -and $i -lt $tasks.Count - 1) { $tasks.Move($i, $i + 1) } })

    # BIOS settings
    $e.BtnBiosAdd.Add_Click({
        $r = [BiosRow]::new(); $r.Maker = $e.CmbBiosPreset.SelectedItem
        $bios.Add($r); $e.GridBios.SelectedItem = $r
    })
    $e.BtnBiosRemove.Add_Click({ $r = $e.GridBios.SelectedItem; if ($r -is [BiosRow]) { [void]$bios.Remove($r) } })
    $e.BtnBiosPreset.Add_Click({
        # Adds the maker's recommended settings, replacing the value of any row with the same name.
        foreach ($p in Get-BiosPreset -Maker $e.CmbBiosPreset.SelectedItem) {
            $row = $bios | Where-Object { $_.Maker -eq $p.Maker -and $_.Name -eq $p.Name } | Select-Object -First 1
            if (-not $row) { $row = [BiosRow]::new(); $row.Maker = $p.Maker; $row.Name = $p.Name; $bios.Add($row) }
            $row.Value = $p.Value
        }
        $e.GridBios.Items.Refresh()
    })

    # Shares: the password box applies to the selected row and is kept until Save.
    $e.BtnShareAdd.Add_Click({
        $used = @($shares | ForEach-Object LocalName)
        $r = [ShareRow]::new()
        $r.LocalName = [char[]](89..68) | ForEach-Object { "$($_):" } | Where-Object { $_ -notin $used -and $_ -notin 'X:', 'W:' } | Select-Object -First 1
        $shares.Add($r); $e.GridShares.SelectedItem = $r
    })
    $e.BtnShareRemove.Add_Click({ $r = $e.GridShares.SelectedItem; if ($r -is [ShareRow]) { [void]$shares.Remove($r) } })
    $e.GridShares.Add_SelectionChanged({
        $r = $e.GridShares.SelectedItem
        $e.PwdShare.Password = ''
        $e.TxtSharePwState.Text = if ($r -is [ShareRow]) { if ($state.SharePasswords[$r.LocalName]) { 'New password set.' } else { & $pwState $r.PasswordFile } } else { '' }
    })
    $e.PwdShare.Add_PasswordChanged({
        $r = $e.GridShares.SelectedItem
        if ($r -is [ShareRow] -and $e.PwdShare.Password) { $state.SharePasswords[$r.LocalName] = $e.PwdShare.Password }
    })

    # --- Collect and save ------------------------------------------------------------------------------------
    $collect = {
        $e.GridTasks.CommitEdit('Row', $true) | Out-Null
        $e.GridShares.CommitEdit('Row', $true) | Out-Null
        $e.GridBios.CommitEdit('Row', $true) | Out-Null
        $n = 0
        $a.Name          = $e.TxtName.Text.Trim()
        $a.Mode          = if ($e.RbUnattended.IsChecked) { 'Unattended' } else { 'Interactive' }
        $a.UnattendDelay = if ([int]::TryParse($e.TxtDelay.Text, [ref]$n)) { $n } else { 10 }
        $a.Reboot        = [bool]$e.RbReboot.IsChecked
        $a.Shutdown      = [bool]$e.RbShutdown.IsChecked
        $a.ImageFile     = $e.CmbImage.Text.Trim()
        $a.ImageIndex    = if ($e.CmbIndex.Text -match '^\s*(\d+)') { [int]$Matches[1] } else { 0 }
        $a.ImageVersion  = if ($e.CmbVersion.SelectedItem) { $e.CmbVersion.SelectedItem.Version } else { '' }
        $a.DiskNumber    = if ([int]::TryParse($e.TxtDisk.Text, [ref]$n)) { $n } else { 0 }
        $a.Windows11Check = @('Block', 'Warn', 'Off')[[math]::Max(0, $e.CmbWin11Check.SelectedIndex)]
        $a.DriverRoot    = $e.TxtDrivers.Text.Trim()
        $a.Applications  = @($selected)
        $a.FullName      = $e.TxtFullName.Text.Trim()
        $a.Organization  = $e.TxtOrg.Text.Trim()
        $a.ProductKey    = $e.TxtProductKey.Text.Trim()
        $a.TimeZone      = $e.CmbTimeZone.Text.Trim()
        $a.InputLocale   = $e.CmbInputLocale.Text.Trim()
        $a.UserLocale    = $e.CmbUserLocale.Text.Trim()
        $a.SystemLocale  = $e.CmbSystemLocale.Text.Trim()
        $a.UILanguage    = $e.CmbUILanguage.Text.Trim()
        $a.DisableSystemRestore = [bool]$e.ChkNoRestore.IsChecked
        $a.EnableAdministrator  = [bool]$e.ChkAdmin.IsChecked
        $a.NamingMode    = if ($e.RbNameCustom.IsChecked) { 'Custom' } elseif ($e.RbNamePrompt.IsChecked) { 'Prompt' } else { 'WMI' }
        $a.Prefix        = $e.TxtPrefix.Text.Trim()
        $a.WmiQuery      = $e.CmbWmi.Text.Trim()
        $a.CustomScheme  = $e.TxtScheme.Text.Trim()
        $a.Membership    = if ($e.RbDomain.IsChecked) { 'Domain' } else { 'Workgroup' }
        $a.Domain        = $e.TxtDomain.Text.Trim()
        $a.OrganizationalUnit = $e.TxtOU.Text.Trim()
        $a.JoinUser      = $e.TxtJoinUser.Text.Trim()
        $a.JoinDomain    = $e.TxtJoinDomain.Text.Trim()
        $a.Workgroup     = $e.TxtWorkgroup.Text.Trim()
        $a.Tasks         = @($tasks | Where-Object { $_.Command } | ForEach-Object { [pscustomobject]@{ Phase = $_.Phase; Command = $_.Command.Trim() } })
        $a.Shares        = @($shares | Where-Object { $_.RemoteName } | ForEach-Object {
            [pscustomobject]@{ LocalName = "$($_.LocalName)".Trim().ToUpperInvariant(); RemoteName = $_.RemoteName.Trim()
                               Username = $_.Username; Domain = $_.Domain; PasswordFile = $_.PasswordFile }
        })
        $a.Bios.Enabled     = [bool]$e.ChkBios.IsChecked
        $a.Bios.ToolsRoot   = $e.TxtBiosTools.Text.Trim()
        $a.Bios.StopOnError = [bool]$e.ChkBiosStop.IsChecked
        $a.Bios.Settings    = @($bios | Where-Object { $_.Name } | ForEach-Object {
            [pscustomobject]@{ Maker = $_.Maker; Name = $_.Name.Trim(); Value = "$($_.Value)".Trim() }
        })
        $a.BitLocker.Enabled           = [bool]$e.ChkBitLocker.IsChecked
        $a.BitLocker.EncryptionMethod  = "$($e.CmbBlMethod.SelectedItem)"
        $a.BitLocker.UsedSpaceOnly     = [bool]$e.ChkBlUsedSpace.IsChecked
        $a.BitLocker.Protector         = if ($e.RbBlTpmPin.IsChecked) { 'TpmPin' } else { 'Tpm' }
        $a.BitLocker.BackupToAD        = [bool]$e.ChkBlAD.IsChecked
        $a.BitLocker.RecoveryKeyFolder = $e.TxtBlFolder.Text.Trim()
        $a.BitLocker.RequireBackup     = [bool]$e.ChkBlRequire.IsChecked
        $split = { param($t) @("$t" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $a.MigrateUserData   = [bool]$e.ChkMigrate.IsChecked
        $a.UserDataStore     = if ($e.RbStoreShare.IsChecked) { 'Share' } else { 'Local' }
        $a.UserDataPath      = $e.TxtStorePath.Text.Trim()
        $a.UserDataEncrypt   = $a.UserDataStore -eq 'Share' -and [bool]$e.ChkEncrypt.IsChecked
        $a.UserDataRules     = @(@(if ($e.ChkMigDocs.IsChecked) { 'MigDocs.xml' }) + @(if ($e.ChkMigApp.IsChecked) { 'MigApp.xml' }) + (& $split $e.TxtExtraRules.Text))
        $a.UserDataExclude   = & $split $e.TxtExcludeUsers.Text
        $a.UserDataLocalAccounts = [bool]$e.ChkLocalAccounts.IsChecked
        $a.UserDataKeepStore = [bool]$e.ChkKeepStore.IsChecked
    }

    $e.BtnNamePreview.Add_Click({
        & $collect
        try {
            $wmi = Get-WmiNamingValue -Query $a.WmiQuery
            $e.TxtNamePreview.Text = Resolve-ComputerName -Answer $a -WmiValue $wmi -Serial (Get-CimInstance Win32_BIOS).SerialNumber
        } catch { $e.TxtNamePreview.Text = "Query failed: $($_.Exception.Message)" }
    })

    $e.BtnCancel.Add_Click({ $win.Close() })
    $e.BtnSave.Add_Click({
        try {
            & $collect
            # A domain join or Administrator password is required the first time; later it can stay as saved.
            if ($a.Membership -eq 'Domain' -and -not $e.PwdJoin.Password -and -not (Test-SecretFile -ContentRoot $ContentRoot -RelativePath $a.JoinPasswordFile)) {
                throw 'Enter the join account password (Domain or workgroup).'
            }
            if ($a.EnableAdministrator -and -not $e.PwdAdmin.Password -and -not (Test-SecretFile -ContentRoot $ContentRoot -RelativePath $a.AdminPasswordFile)) {
                throw 'Enter the Administrator password (Windows settings).'
            }
            if ($a.BitLocker.Enabled -and $a.BitLocker.Protector -eq 'TpmPin' -and -not $e.PwdBlPin.Password -and -not (Test-SecretFile -ContentRoot $ContentRoot -RelativePath $a.BitLocker.PinFile)) {
                throw 'Enter the BitLocker startup PIN (BitLocker).'
            }
            if ($a.MigrateUserData -and $a.UserDataEncrypt -and -not $e.PwdUsmtKey.Password -and -not (Test-SecretFile -ContentRoot $ContentRoot -RelativePath $a.UserDataKeyFile)) {
                throw 'Enter the encryption key (User data).'
            }
            Save-AnswerFromEditor -ContentRoot $ContentRoot -Answer $a -JoinPassword $e.PwdJoin.Password `
                -AdminPassword $e.PwdAdmin.Password -SharePasswords $state.SharePasswords `
                -BiosPassword $e.PwdBios.Password -BitLockerPin $e.PwdBlPin.Password -UserDataKey $e.PwdUsmtKey.Password -IsNew:$isNew | Out-Null
            $state.Saved = $true
            $win.Close()
        } catch {
            $e.TxtProblems.Text = $_.Exception.Message
        }
    })

    [void]$win.ShowDialog()
    $state.Saved
}
