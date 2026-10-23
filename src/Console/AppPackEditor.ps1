# Application pack builder window: installer, silent command, detection rules and which PCs get the app.
# Dot-sourced by ImagingConsole.ps1 after AnswerEditor.ps1 (for Get-XamlControls); uses AppPack.psm1 and ConsoleData.psm1.

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

    [xml]$px = Get-Content -Raw (Join-Path $PSScriptRoot 'AppPackEditor.xaml')
    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($px))
    $win.Owner = $Owner
    $e = Get-XamlControls $px $win
    $win.Title = if ($isNew) { 'New application' } else { "Application: $Name" }
    $state = @{ Saved = $null; AppFolder = if ($isNew) { $null } else { Join-Path $appRoot $Name } }
    $templates = @(Get-AppTemplates)

    # --- Choices -------------------------------------------------------------------------------------------
    $e.CmbType.ItemsSource = @('msi', 'msix', 'nsis', 'inno', 'installshield', 'burn', 'advancedinstaller', 'squirrel', 'exe', 'script')
    $e.CmbTemplate.ItemsSource = @('(none)') + @($templates | ForEach-Object { "$($_.name)$(if ($_.verify) { ' (verify)' })" })
    $e.CmbTemplate.SelectedIndex = 0
    $e.GridRules.Columns[0].ItemsSource = @('msi', 'uninstall', 'file', 'registry', 'appx', 'script')
    $e.GridRules.Columns[3].ItemsSource = @('exists', '>=', '=')
    $codes = { param($text) @($text -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
    $list  = { param($text) @($text -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

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
        $e.TxtNotes.Text = $d.notes
        if ($d.installer) { $e.CmbInstaller.Text = $d.installer }
        $e.CmbType.Text = $d.installerType
        $e.TxtCommand.Text = $d.command
        $e.TxtUninstall.Text = $d.uninstallCommand
        $e.TxtCodes.Text = $d.successCodes -join ', '
        $e.TxtRebootCodes.Text = $d.rebootCodes -join ', '
        $e.TxtTimeout.Text = $d.timeoutMinutes
        $e.RbMatchAny.IsChecked = $d.detection.match -eq 'any'
        $e.RbMatchAll.IsChecked = $d.detection.match -ne 'any'
        $e.ChkSkip.IsChecked = $d.skipIfDetected
        $rules.Clear()
        foreach ($r in $d.detection.rules) {
            $row = [DetectionRow]::new()
            $row.Type = $r.type; $row.Target = $r.target; $row.Value = $r.value; $row.Operator = $r.operator; $row.Version = $r.version
            $rules.Add($row)
        }
        $e.TxtMakers.Text = @($d.requirements.makers) -join ', '
        $e.TxtModels.Text = @($d.requirements.models) -join ', '
        $e.TxtTypeNote.Text = Get-InstallerTypeNote $d.installerType
    }
    & $load $def
    $e.GridRules.ItemsSource = $rules
    $e.TxtName.IsEnabled = $isNew
    $e.CmbInstaller.ItemsSource = & $folderFiles
    if ($isNew -and $SuggestedName) {
        # Rebuilding a SmartDeploy pack by name: preselect its template.
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
            installerType    = $e.CmbType.Text.Trim()
            command          = $e.TxtCommand.Text.Trim()
            uninstallCommand = $e.TxtUninstall.Text.Trim()
            successCodes     = & $codes $e.TxtCodes.Text
            rebootCodes      = & $codes $e.TxtRebootCodes.Text
            timeoutMinutes   = if ([int]::TryParse($e.TxtTimeout.Text, [ref]$n)) { $n } else { 60 }
            requirements     = [pscustomobject]@{ makers = & $list $e.TxtMakers.Text; models = & $list $e.TxtModels.Text }
            detection        = [pscustomobject]@{
                match = if ($e.RbMatchAny.IsChecked) { 'any' } else { 'all' }
                rules = @($rules | Where-Object { $_.Type -and $_.Target } | ForEach-Object {
                    [pscustomobject]@{ type = $_.Type; target = $_.Target.Trim(); value = "$($_.Value)".Trim(); operator = $_.Operator; version = "$($_.Version)".Trim() } })
            }
            skipIfDetected   = [bool]$e.ChkSkip.IsChecked
            notes            = $e.TxtNotes.Text.Trim()
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
        if (-not $e.TxtCommand.Text) { $e.TxtCommand.Text = $info.Command }
        if ($info.UninstallCommand -and -not $e.TxtUninstall.Text) { $e.TxtUninstall.Text = $info.UninstallCommand }
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
            $e.TxtTemplateNote.Text = "Matches the $($t.name) template: click Apply to use its settings. $($t.notes)"
        }
        $e.TxtProblems.Text = ''
    }

    $afterSource = {
        $e.CmbInstaller.ItemsSource = & $folderFiles
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

    $e.BtnSourceFile.Add_Click({
        $f = [Microsoft.Win32.OpenFileDialog]::new()
        $f.Filter = 'Installers (*.msi;*.exe;*.msix;*.msixbundle;*.appx;*.ps1;*.cmd;*.bat)|*.msi;*.exe;*.msix;*.msixbundle;*.appx;*.ps1;*.cmd;*.bat|All files (*.*)|*.*'
        if ($f.ShowDialog($win)) { $e.TxtSource.Text = $f.FileName; & $afterSource }
    })
    $e.BtnSourceFolder.Add_Click({
        $f = [Windows.Forms.FolderBrowserDialog]::new()
        $f.Description = 'Folder with the installer and the files it needs'
        if ($f.ShowDialog() -eq 'OK') { $e.TxtSource.Text = $f.SelectedPath; & $afterSource }
    })
    $e.BtnInspect.Add_Click({ try { & $inspect } catch { $e.TxtProblems.Text = $_.Exception.Message } })

    $e.CmbTemplate.Add_SelectionChanged({
        $i = $e.CmbTemplate.SelectedIndex
        if ($i -gt 0) {
            $t = $templates[$i - 1]
            $e.TxtTemplateNote.Text = "$(if ($t.verify) { 'Best guess, test it on a VM first. ' })$($t.notes)"
        } else { $e.TxtTemplateNote.Text = '' }
    })
    $e.BtnTemplate.Add_Click({
        $i = $e.CmbTemplate.SelectedIndex
        if ($i -le 0) { return }
        $t = $templates[$i - 1]
        $typed = $e.TxtName.Text.Trim()
        $name = if (-not $isNew) { $Name } elseif ($typed -and $typed -ne 'NewApp') { $typed } else { $t.name }
        $d = New-AppDefinitionFromTemplate -Template $t -Installer $e.CmbInstaller.Text.Trim() -Name $name
        if (-not $d.version) { $d.version = $e.TxtVersion.Text.Trim() }
        if (-not $d.command -and $e.CmbInstaller.Text) {
            # Templates without known switches: use the inspected installer type.
            $type = if ($e.CmbType.Text) { $e.CmbType.Text } else { 'exe' }
            $d.installerType = $type
            $d.command = Get-SilentInstallCommand -Installer $e.CmbInstaller.Text.Trim() -Type $type
        }
        & $load $d
        $e.TxtProblems.Text = if ($d.command -match 'REPLACE_[A-Z_]+') { "Replace $($Matches[0]) in the install command (Install command)." } else { '' }
    })

    $e.BtnSuggest.Add_Click({
        if (-not $e.CmbInstaller.Text) { $e.TxtProblems.Text = 'Pick the installer to run first.'; return }
        $type = if ($e.CmbType.Text) { $e.CmbType.Text } else { 'exe' }
        $e.TxtCommand.Text = Get-SilentInstallCommand -Installer $e.CmbInstaller.Text.Trim() -Type $type
        $e.TxtTypeNote.Text = Get-InstallerTypeNote $type
    })
    $e.CmbType.Add_SelectionChanged({ $win.Dispatcher.BeginInvoke([Action]{ $e.TxtTypeNote.Text = Get-InstallerTypeNote $e.CmbType.Text }) | Out-Null })

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
            if ($isNew -and -not $src) { throw 'Pick the installer file or folder (Installer).' }
            $warnings = @(Test-AppPack -Definition $d | Where-Object { $_ -like 'Warning:*' })
            if ($warnings -and [Windows.MessageBox]::Show($win, "$($warnings -join "`n")`n`nSave anyway?", 'Application', 'YesNo', 'Warning') -ne 'Yes') { return }
            $win.Cursor = 'Wait'
            try {
                if ($isNew) { New-Application -ContentRoot $ContentRoot -Name $d.name -Source $src -Definition $d | Out-Null }
                else { Save-Application -ContentRoot $ContentRoot -Definition $d -Source $src | Out-Null }
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
