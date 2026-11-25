# Application pack builder window: installer, silent command, detection rules and which PCs get the app.
# Dot-sourced by ImagingConsole.ps1; loads its window with New-ConsoleWindow (XamlWindow.psm1) and uses AppPack.psm1 and ConsoleData.psm1.

class DetectionRow {
    [string]$Type
    [string]$Target
    [string]$Value
    [string]$Operator
    [string]$Version
}

function Show-AppPackEditor {
    <#
    .SYNOPSIS
        Opens the builder for a new application, or for Applications\<Name> with -Name. Returns the saved name or $null.
    #>
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [string]$Name,
        [string]$SuggestedName
    )
    $isNew = -not $Name
    $appRoot = Join-Path $ContentRoot 'Applications'
    $def = if ($isNew) { ConvertTo-AppDefinition -Name $(if ($SuggestedName) { $SuggestedName } else { 'NewApp' }) -Json ([pscustomobject]@{}) }
           else { Read-AppPack -AppRoot $appRoot -Name $Name }

    $form = New-ConsoleWindow 'AppPackEditor.xaml' -Owner $Owner
    $win = $form.Window
    $e = $form.Controls
    $win.Title = if ($isNew) { 'New application' } else { "Application: $Name" }
    $state = @{ Saved = $null; Template = $null; AppFolder = if ($isNew) { $null } else { Join-Path $appRoot $Name } }
    $templates = @(Get-AppTemplates)

    # --- Choices -------------------------------------------------------------------------------------------
    $e.CmbType.ItemsSource = @('msi', 'msix', 'nsis', 'inno', 'installshield', 'burn', 'advancedinstaller', 'squirrel', 'exe', 'script')
    Initialize-TemplatePicker -Controls $e -Templates $templates
    $e.GridRules.Columns[0].ItemsSource = @('msi', 'uninstall', 'file', 'registry', 'appx', 'script')
    $e.GridRules.Columns[3].ItemsSource = @('exists', '>=', '=')

    $folderFiles = {
        # Installer candidates in the chosen folder (or the saved app folder), for the "Installer to run" list.
        $dir = if ($e.TxtSource.Text -and (Test-Path $e.TxtSource.Text -PathType Container)) { $e.TxtSource.Text } else { $state.AppFolder }
        if (-not $dir -or -not (Test-Path $dir)) { return @() }
        @(Get-ChildItem $dir -File | Where-Object Extension -in '.msi', '.exe', '.msix', '.msixbundle', '.appx', '.appxbundle', '.ps1', '.cmd', '.bat' | ForEach-Object Name)
    }
    $installerPath = {
        # Full path of the installer to inspect: the picked file, or the chosen file inside the folder.
        $src = $e.TxtSource.Text.Trim()
        if ($src -and (Test-Path $src -PathType Leaf)) { return $src }
        $dir = if ($src -and (Test-Path $src -PathType Container)) { $src } else { $state.AppFolder }
        if ($dir -and $e.CmbInstaller.Text) { Join-Path $dir $e.CmbInstaller.Text }
    }

    # --- Load ------------------------------------------------------------------------------------------------
    $rules = [Collections.ObjectModel.ObservableCollection[DetectionRow]]::new()
    $load = {
        param($d)
        $e.TxtName.Text = $d.name
        $e.TxtDisplayName.Text = $d.displayName
        $e.TxtVersion.Text = $d.version
        $e.TxtPublisher.Text = $d.publisher
        # Notes come from the template; they show in the pack's details on the Apps and Tasks tab, not here.
        $state.Notes = "$($d.notes)"
        if ($d.installer) { $e.CmbInstaller.Text = $d.installer }
        $e.TxtDownloadUrl.Text = $d.downloadUrl
        $e.CmbType.Text = $d.installerType
        $e.TxtCommand.Text = $d.command
        $e.TxtCodes.Text = $d.successCodes -join ', '
        $e.TxtTimeout.Text = $d.timeoutMinutes
        $rules.Clear()
        foreach ($r in $d.detection.rules) {
            $row = [DetectionRow]::new()
            $row.Type = $r.type; $row.Target = $r.target; $row.Value = $r.value; $row.Operator = $r.operator; $row.Version = $r.version
            $rules.Add($row)
        }
        Set-RequirementBoxes -Controls $e -Definition $d
        $e.TxtTypeNote.Text = Get-InstallerTypeNote $d.installerType
    }
    & $load $def
    $e.GridRules.ItemsSource = $rules
    $e.TxtName.IsEnabled = $isNew
    # One Name box: the folder under Applications follows it for a new application, and stays once saved.
    $folderNote = { $e.TxtFolderNote.Text = if ($e.TxtName.Text) { "Saved in Applications\$($e.TxtName.Text)" } else { '' } }
    $e.TxtDisplayName.Add_TextChanged({
        if ($isNew -and $e.TxtDisplayName.IsKeyboardFocusWithin) { $e.TxtName.Text = ($e.TxtDisplayName.Text -replace '[^A-Za-z0-9._-]+', '-').Trim('-') }
        & $folderNote
    })
    $e.TxtName.Add_TextChanged({ & $folderNote })
    & $folderNote
    $e.CmbInstaller.ItemsSource = @(& $folderFiles)
    if ($isNew -and $SuggestedName) {
        # Rebuilding an imported .spk pack by name: preselect its template.
        $t = Find-AppTemplate -Name $SuggestedName -Templates $templates
        if ($t) { $e.CmbTemplate.SelectedIndex = [array]::IndexOf(@($templates), $t) + 1 }
    }

    # --- Behaviour -------------------------------------------------------------------------------------------
    $e.LstSections.Add_SelectionChanged({
        for ($i = 0; $i -lt 4; $i++) { $e["Sec$i"].Visibility = if ($i -eq $e.LstSections.SelectedIndex) { 'Visible' } else { 'Collapsed' } }
    })
    $e.LstSections.SelectedIndex = 0

    $collect = {
        $e.GridRules.CommitEdit('Row', $true) | Out-Null
        $n = 0
        $json = [pscustomobject]@{
            displayName      = $e.TxtDisplayName.Text.Trim()
            version          = $e.TxtVersion.Text.Trim()
            publisher        = $e.TxtPublisher.Text.Trim()
            installer        = $e.CmbInstaller.Text.Trim()
            downloadUrl      = $e.TxtDownloadUrl.Text.Trim()
            installerType    = $e.CmbType.Text.Trim()
            command          = $e.TxtCommand.Text.Trim()
            successCodes     = ConvertFrom-ListText $e.TxtCodes.Text -Numbers
            rebootCodes      = @(3010, 1641)     # always: the standard "restart needed" codes
            timeoutMinutes   = if ([int]::TryParse($e.TxtTimeout.Text, [ref]$n)) { $n } else { 60 }
            requirements     = Get-RequirementBoxes -Controls $e
            detection        = [pscustomobject]@{
                match = 'all'
                rules = @($rules | Where-Object { $_.Type -and $_.Target } | ForEach-Object {
                    [pscustomobject]@{ type = $_.Type; target = $_.Target.Trim(); value = "$($_.Value)".Trim(); operator = $_.Operator; version = "$($_.Version)".Trim() } })
            }
            skipIfDetected   = $true             # always skipped when every detection rule matches
            notes            = "$($state.Notes)"
        }
        ConvertTo-AppDefinition -Name $e.TxtName.Text.Trim() -Json $json
    }

    $applyInfo = {
        # Fills the empty fields (and the command and detection when there are none) from an inspected installer.
        param($info)
        if ($isNew -and ($e.TxtName.Text -in '', 'NewApp')) { $e.TxtName.Text = ($info.DisplayName -replace '[^A-Za-z0-9._-]+', '-').Trim('-') }
        if (-not $e.TxtDisplayName.Text -or $e.TxtDisplayName.Text -eq 'NewApp') { $e.TxtDisplayName.Text = $info.DisplayName }
        if ($info.Version) { $e.TxtVersion.Text = $info.Version }
        if ($info.Publisher -and -not $e.TxtPublisher.Text) { $e.TxtPublisher.Text = $info.Publisher }
        $e.CmbInstaller.Text = $info.Installer
        $e.CmbType.Text = $info.Type
        $e.TxtTypeNote.Text = $info.Note
        if (-not $e.TxtCommand.Text -or $e.TxtCommand.Text -eq $state.Suggested) { $e.TxtCommand.Text = $info.Command; $state.Suggested = $info.Command }
        if ($info.Detection -and -not $rules.Count) {
            $row = [DetectionRow]::new()
            $row.Type = $info.Detection.type; $row.Target = $info.Detection.target; $row.Operator = $info.Detection.operator
            $rules.Add($row)
        }
    }

    $inspect = {
        $path = & $installerPath
        if (-not $path -or -not (Test-Path $path -PathType Leaf)) { throw 'Pick an installer file (or a folder, then the installer to run) first.' }
        $info = Get-InstallerInfo -Path $path
        & $applyInfo $info
        # A matching template knows more than the file does (requirements, better detection).
        $t = Find-AppTemplate -Installer $info.Installer -Templates $templates
        if ($t) {
            $e.CmbTemplate.SelectedIndex = [array]::IndexOf(@($templates), $t) + 1
            $e.TxtTemplateNote.Text = "Matches the $($t.name) template: its settings are filled in. $($t.notes)"
        }
        $e.TxtProblems.Text = ''
    }

    $afterSource = {
        $e.CmbInstaller.ItemsSource = @(& $folderFiles)
        $src = $e.TxtSource.Text
        if (Test-Path $src -PathType Leaf) { $e.CmbInstaller.Text = Split-Path $src -Leaf }
        elseif (@($e.CmbInstaller.ItemsSource).Count) {
            # Prefer an MSI, then the largest .exe: setup.exe launchers are usually small helpers.
            $files = @(Get-ChildItem $src -File | Where-Object Name -in @($e.CmbInstaller.ItemsSource))
            $pick = ($files | Where-Object Extension -eq '.msi' | Select-Object -First 1)
            if (-not $pick) { $pick = $files | Sort-Object Length -Descending | Select-Object -First 1 }
            $e.CmbInstaller.Text = $pick.Name
        }
        try { & $inspect } catch { $e.TxtProblems.Text = $_.Exception.Message }
    }

    Register-SourceBrowse -Controls $e -Owner $win -FolderText 'Folder with the installer and the files it needs' -After { & $afterSource } `
        -Filter 'Installers (*.msi;*.exe;*.msix;*.msixbundle;*.appx;*.ps1;*.cmd;*.bat)|*.msi;*.exe;*.msix;*.msixbundle;*.appx;*.ps1;*.cmd;*.bat|All files (*.*)|*.*'
    # Picking another file of the folder reads that one at once (no Inspect button). Only when the operator picks it:
    # opening an existing application must not overwrite what it has.
    $e.CmbInstaller.Add_SelectionChanged({
        if (-not $e.CmbInstaller.IsKeyboardFocusWithin) { return }
        $win.Dispatcher.BeginInvoke([Action]{ if ($e.CmbInstaller.Text) { try { & $inspect } catch { $e.TxtProblems.Text = $_.Exception.Message } } }) | Out-Null
    })

    # Picking a template fills the form in at once (no Apply button).
    $applyTemplate = {
        $t = Get-PickedTemplate -Controls $e -Templates $templates
        if (-not $t) { return }
        $typed = $e.TxtName.Text.Trim()
        $name = if (-not $isNew) { $Name } elseif ($typed -and $typed -ne 'NewApp') { $typed } else { $t.name }
        # No installer picked and the template has a download: the PC downloads it at first boot.
        $online = -not $e.TxtSource.Text.Trim() -and -not $e.CmbInstaller.Text.Trim() -and $t.PSObject.Properties['download'] -and $t.download.url
        $d = New-AppDefinitionFromTemplate -Template $t -Installer $e.CmbInstaller.Text.Trim() -Name $name -Online:$online
        $state.Template = $t    # its extra files (Office's configuration.xml) are copied when the application is saved
        if (-not $d.version) { $d.version = $e.TxtVersion.Text.Trim() }
        if (-not $d.command -and $e.CmbInstaller.Text) {
            # Templates without known switches: use the inspected installer type.
            $type = if ($e.CmbType.Text) { $e.CmbType.Text } else { 'exe' }
            $d.installerType = $type
            $d.command = Get-SilentInstallCommand -Installer $e.CmbInstaller.Text.Trim() -Type $type
        }
        & $load $d
        $e.TxtProblems.Text = if ($d.command -match 'REPLACE_[A-Z_]+') { "Replace $($Matches[0]) in the install command (Install command)." } else { '' }
    }
    $e.CmbTemplate.Add_SelectionChanged({ & $applyTemplate })
    # A template picked before the form opened (rebuilding an imported pack by name) is filled in now.
    if ($e.CmbTemplate.SelectedIndex -gt 0) { & $applyTemplate }

    # Another installer type gives its silent command at once (no Suggest button), unless the command was typed by hand.
    $e.CmbType.Add_SelectionChanged({ $win.Dispatcher.BeginInvoke([Action]{
        $type = $e.CmbType.Text
        $e.TxtTypeNote.Text = Get-InstallerTypeNote $type
        if ($type -and $e.CmbType.IsKeyboardFocusWithin -and $e.CmbInstaller.Text -and (-not $e.TxtCommand.Text -or $e.TxtCommand.Text -eq $state.Suggested)) {
            $state.Suggested = Get-SilentInstallCommand -Installer $e.CmbInstaller.Text.Trim() -Type $type
            $e.TxtCommand.Text = $state.Suggested
        }
    }) | Out-Null })

    # Detection rules
    $e.BtnRuleAdd.Add_Click({ $r = [DetectionRow]::new(); $r.Type = 'uninstall'; $r.Operator = 'exists'; $rules.Add($r); $e.GridRules.SelectedItem = $r })
    $e.BtnRuleRemove.Add_Click({ $r = $e.GridRules.SelectedItem; if ($r -is [DetectionRow]) { [void]$rules.Remove($r) } })
    $e.BtnRuleTest.Add_Click({
        try {
            $d = & $collect
            $res = Test-AppDetection -Definition $d -AppFolder $state.AppFolder
            $e.TxtRuleTest.Text = if (-not $res.HasRules) { 'There are no rules to test.' } else {
                "On this PC: $(if ($res.Detected) { 'installed' } else { 'not installed' }).`n" +
                (($res.Details | ForEach-Object { "$(if ($_.Found) { 'found' } else { 'not found' }): $($_.Rule) ($($_.Detail))" }) -join "`n")
            }
        } catch { $e.TxtRuleTest.Text = $_.Exception.Message }
    })

    # --- Save ------------------------------------------------------------------------------------------------
    $e.BtnCancel.Add_Click({ $win.Close() })
    $e.BtnSave.Add_Click({
        try {
            $d = & $collect
            $src = $e.TxtSource.Text.Trim()
            if ($isNew -and -not $src -and -not $d.downloadUrl) { throw 'Pick the installer file or folder, or fill in Download from (Installer).' }
            $warnings = @(Test-AppPack -Definition $d | Where-Object { $_ -like 'Warning:*' })
            if ($warnings -and [Windows.MessageBox]::Show($win, "$($warnings -join "`n")`n`nSave anyway?", 'Application', 'YesNo', 'Warning') -ne 'Yes') { return }
            $win.Cursor = 'Wait'
            try {
                $dest = if ($isNew) { New-Application -ContentRoot $ContentRoot -Name $d.name -Source $src -Definition $d }
                        else { Save-Application -ContentRoot $ContentRoot -Definition $d -Source $src }
                if ($state.Template) { Copy-AppTemplateFiles -Template $state.Template -Destination "$(@($dest)[-1])" }
            } finally { $win.Cursor = $null }
            $state.Saved = $d.name
            $win.Close()
        } catch {
            $e.TxtProblems.Text = $_.Exception.Message
        }
    })

    [void]$win.ShowDialog()
    $state.Saved
}
