# Answer file editor window: every setting of an answer file as a form.
# Dot-sourced by ImagingConsole.ps1, which loads WPF, ConsoleData.psm1 and AnswerFile.psm1.

# Real .NET types so the editable grids can bind two-way.
class TaskRow {
    [string]$Phase
    [string]$Script
    [string]$Command
    [string]$Task      # what the Task column shows: the library task, or Command for an older answer file's plain command
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

    $form = New-ConsoleWindow 'AnswerEditor.xaml' -Owner $Owner
    $win = $form.Window
    $e = $form.Controls
    $win.Title = if ($isNew) { 'New answer file' } else { "Answer file: $($a.Name)" }
    $state = @{ Saved = $false }

    # --- Choices -------------------------------------------------------------------------------------------
    $images = @(Get-ImageList -ContentRoot $ContentRoot)
    $e.CmbImage.ItemsSource = @($images | ForEach-Object { "Images\$($_.Name)" })
    $e.CmbTimeZone.ItemsSource = @([TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object Id)
    $cultures = @([Globalization.CultureInfo]::GetCultures('SpecificCultures') | Sort-Object Name | ForEach-Object Name)
    foreach ($c in 'CmbLanguage', 'CmbFallback') { $e[$c].ItemsSource = $cultures }
    $e.GridTasks.Columns[0].ItemsSource = @('POSTIMAGE', 'FIRSTBOOT', 'FIRSTLOGON')
    $refreshTaskLibrary = {
        # Available: the library's tasks (a task missing from the library still shows in the run order, and
        # Get-AnswerFileIssues reports it).
        $e.LstTaskLibrary.ItemsSource = @(Get-TaskList -ContentRoot $ContentRoot)
    }

    $showIndex = {
        # One edition (every capture of this tool): it is the one, so the Edition row is hidden. Several editions,
        # or an image the console can't read (a number is typed): the row shows.
        $one = $e.CmbIndex.Items.Count -eq 1
        if ($one) { $e.CmbIndex.Text = "$($e.CmbIndex.Items[0])" }
        foreach ($c in $e.LblIndex, $e.CmbIndex) { $c.Visibility = if ($one) { 'Collapsed' } else { 'Visible' } }
    }
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
        & $showIndex
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

    $e.CmbImage.Text = $a.ImageFile
    & $updateVersions "$($a.ImageVersion)"
    $e.CmbIndex.Text = $a.ImageIndex
    & $showIndex

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
    # Two languages only; keyboards, formats and locales follow from them (Get-RegionalSettings).
    $e.CmbLanguage.Text = if ($a.UILanguage) { $a.UILanguage } else { $a.SystemLocale }
    $e.CmbFallback.Text = $a.UILanguageFallback
    $e.ChkAdmin.IsChecked = $a.EnableAdministrator
    $pwState = { param($file, $enc) if ((Test-SavedPassword -ContentRoot $ContentRoot -RelativePath $file -Encrypted $enc)) { 'A password is saved (encrypted in the answer file). Leave empty to keep it.' } else { 'No password saved yet.' } }
    $e.TxtAdminPwState.Text = & $pwState $a.AdminPasswordFile $a.AdminPasswordEncrypted

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
    $e.TxtJoinPwState.Text = & $pwState $a.JoinPasswordFile $a.JoinPasswordEncrypted

    $tasks = [Collections.ObjectModel.ObservableCollection[TaskRow]]::new()
    foreach ($t in $a.Tasks) {
        $r = [TaskRow]::new(); $r.Phase = $t.Phase; $r.Command = $t.Command
        $r.Script = if ($t.PSObject.Properties['Script']) { $t.Script } else { '' }
        # An older answer file's plain command keeps running; its Arguments box holds the command itself.
        $r.Task = if ($r.Script) { $r.Script } else { 'Command' }
        $tasks.Add($r)
    }
    $e.GridTasks.ItemsSource = $tasks
    & $refreshTaskLibrary



    $bl = $a.BitLocker
    $e.ChkBitLocker.IsChecked = $bl.Enabled
    $e.ChkBlAD.IsChecked = $bl.BackupToAD
    $e.TxtBlFolder.Text = $bl.RecoveryKeyFolder

    # --- Behaviour -------------------------------------------------------------------------------------------
    $e.LstSections.Add_SelectionChanged({
        for ($i = 0; $i -lt $e.LstSections.Items.Count; $i++) { $e["Sec$i"].Visibility = if ($i -eq $e.LstSections.SelectedIndex) { 'Visible' } else { 'Collapsed' } }
    })
    $e.LstSections.SelectedIndex = 0

    $syncEnabled = {
        $e.PwdAdmin.IsEnabled = [bool]$e.ChkAdmin.IsChecked
        $e.CmbWmi.IsEnabled = -not $e.RbNameCustom.IsChecked
        $e.TxtScheme.IsEnabled = [bool]$e.RbNameCustom.IsChecked
        $dom = [bool]$e.RbDomain.IsChecked
        foreach ($c in 'TxtDomain', 'TxtOU', 'TxtJoinUser', 'TxtJoinDomain', 'PwdJoin') { $e[$c].IsEnabled = $dom }
        $e.TxtWorkgroup.IsEnabled = -not $dom
        $on = [bool]$e.ChkBitLocker.IsChecked
        $e.TxtBlFolder.IsEnabled = $on
        # Recovery keys only go to AD from a domain-joined PC.
        $e.ChkBlAD.IsEnabled = $on -and $dom
        if (-not $dom) { $e.ChkBlAD.IsChecked = $false }
    }
    foreach ($c in 'RbInteractive', 'RbUnattended', 'RbNameWmi', 'RbNameCustom', 'RbNamePrompt', 'RbDomain', 'RbWorkgroup') { $e[$c].Add_Checked($syncEnabled) }
    foreach ($c in 'ChkAdmin', 'ChkBitLocker') { $e[$c].Add_Click($syncEnabled) }
    & $syncEnabled

    # Applications
    $e.BtnAppAdd.Add_Click({ $app = $e.LstAvailable.SelectedItem; if ($app) { $selected.Add($app.Name); & $refreshAvailable } })
    $e.LstAvailable.Add_MouseDoubleClick({ $app = $e.LstAvailable.SelectedItem; if ($app) { $selected.Add($app.Name); & $refreshAvailable } })
    $e.BtnAppRemove.Add_Click({ $n = $e.LstSelected.SelectedItem; if ($n) { [void]$selected.Remove($n); & $refreshAvailable } })
    $e.BtnAppUp.Add_Click({ $i = $e.LstSelected.SelectedIndex; if ($i -gt 0) { $selected.Move($i, $i - 1); $e.LstSelected.SelectedIndex = $i - 1 } })
    $e.BtnAppDown.Add_Click({ $i = $e.LstSelected.SelectedIndex; if ($i -ge 0 -and $i -lt $selected.Count - 1) { $selected.Move($i, $i + 1); $e.LstSelected.SelectedIndex = $i + 1 } })
    $e.BtnNewApp.Add_Click({
        # With a missing app selected in the install order (e.g. from an answer file import), build that one.
        $sel = $e.LstSelected.SelectedItem
        $missing = if ($sel -and -not (Test-Path (Join-Path $ContentRoot "Applications\$sel\app.json"))) { $sel }
        $name = if ($missing) { Show-AppPackEditor -Owner $win -ContentRoot $ContentRoot -SuggestedName $missing }
                else { Show-AppPackEditor -Owner $win -ContentRoot $ContentRoot }
        if ($name -and $selected -notcontains $name) { $selected.Add($name) }
        if ($name) { & $refreshAvailable }
    })

    # Tasks: picked from the library like the applications (the same task can run twice, e.g. with other arguments).
    $addTask = {
        # A library task, at the time it is set to run by default.
        param($Row)
        if (-not $Row) { return }
        $r = [TaskRow]::new(); $r.Script = $Row.Name; $r.Task = $Row.Name; $r.Command = ''
        $r.Phase = if ($Row.Definition -and $Row.Definition.phase) { $Row.Definition.phase } else { 'FIRSTBOOT' }
        $tasks.Add($r); $e.GridTasks.SelectedItem = $r
    }
    $e.BtnTaskAdd.Add_Click({ & $addTask $e.LstTaskLibrary.SelectedItem })
    $e.LstTaskLibrary.Add_MouseDoubleClick({ & $addTask $e.LstTaskLibrary.SelectedItem })
    $e.BtnTaskNew.Add_Click({
        $name = Show-TaskEditor -Owner $win -ContentRoot $ContentRoot
        if (-not $name) { return }
        & $refreshTaskLibrary
        & $addTask (@($e.LstTaskLibrary.ItemsSource) | Where-Object Name -eq $name | Select-Object -First 1)
    })
    $e.BtnTaskRemove.Add_Click({ $r = $e.GridTasks.SelectedItem; if ($r -is [TaskRow]) { [void]$tasks.Remove($r) } })
    $e.BtnTaskUp.Add_Click({ $i = $e.GridTasks.SelectedIndex; if ($i -gt 0) { $tasks.Move($i, $i - 1); $e.GridTasks.SelectedIndex = $i - 1 } })
    $e.BtnTaskDown.Add_Click({ $i = $e.GridTasks.SelectedIndex; if ($i -ge 0 -and $i -lt $tasks.Count - 1) { $tasks.Move($i, $i + 1); $e.GridTasks.SelectedIndex = $i + 1 } })


    # --- Collect and save ------------------------------------------------------------------------------------
    $collect = {
        $e.GridTasks.CommitEdit('Row', $true) | Out-Null
        $a.Name          = $e.TxtName.Text.Trim()
        $a.Mode          = if ($e.RbUnattended.IsChecked) { 'Unattended' } else { 'Interactive' }
        # The PC always restarts into Windows when the deploy is done (the result screen still has Shut down).
        $a.Reboot        = $true
        $a.Shutdown      = $false
        $a.ImageFile     = $e.CmbImage.Text.Trim()
        $a.ImageIndex    = if ($e.CmbIndex.Text -match '^\s*(\d+)') { [int]$Matches[1] } else { 0 }
        $a.ImageVersion  = if ($e.CmbVersion.SelectedItem) { $e.CmbVersion.SelectedItem.Version } else { '' }
        $a.Applications  = @($selected)
        $a.FullName      = $e.TxtFullName.Text.Trim()
        $a.Organization  = $e.TxtOrg.Text.Trim()
        $a.ProductKey    = $e.TxtProductKey.Text.Trim()
        $a.TimeZone      = $e.CmbTimeZone.Text.Trim()
        $regional = Get-RegionalSettings $e.CmbLanguage.Text $e.CmbFallback.Text
        foreach ($n in 'InputLocale', 'SystemLocale', 'UILanguage', 'UILanguageFallback', 'UserLocale') { $a.$n = $regional.$n }
        $a.EnableAdministrator  = [bool]$e.ChkAdmin.IsChecked
        $a.NamingMode    = if ($e.RbNameCustom.IsChecked) { 'Custom' } elseif ($e.RbNamePrompt.IsChecked) { 'Prompt' } else { 'WMI' }
        $a.Prefix        = $e.TxtPrefix.Text.Trim()
        $a.WmiQuery      = $e.CmbWmi.Text.Trim()
        $a.CustomScheme  = $e.TxtScheme.Text.Trim()
        $a.Membership    = if ($e.RbDomain.IsChecked) { 'Domain' } else { 'Workgroup' }
        $a.Domain        = $e.TxtDomain.Text.Trim()
        $a.OrganizationalUnit = $e.TxtOU.Text.Trim()
        $join = Split-JoinAccount -User $e.TxtJoinUser.Text -Domain $e.TxtJoinDomain.Text
        $a.JoinUser      = $join.User
        $a.JoinDomain    = $join.Domain
        $a.Workgroup     = $e.TxtWorkgroup.Text.Trim()
        $a.Tasks         = @($tasks | Where-Object { $_.Command -or $_.Script } | ForEach-Object {
            [pscustomobject]@{ Phase = $_.Phase; Script = "$($_.Script)".Trim(); Command = "$($_.Command)".Trim() }
        })
        $a.BitLocker.Enabled           = [bool]$e.ChkBitLocker.IsChecked
        $a.BitLocker.UsedSpaceOnly     = $true
        $a.BitLocker.BackupToAD        = [bool]$e.ChkBlAD.IsChecked
        $a.BitLocker.RecoveryKeyFolder = $e.TxtBlFolder.Text.Trim()
        $a.BitLocker.RequireBackup     = $true
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
            $joinPwSaved = Test-SavedPassword -ContentRoot $ContentRoot -RelativePath $a.JoinPasswordFile -Encrypted $a.JoinPasswordEncrypted
            $joinProblem = Get-DomainJoinProblem -Answer $a -PasswordTyped ([bool]$e.PwdJoin.Password) -PasswordSaved $joinPwSaved
            if ($joinProblem) {
                # Show the page and put the cursor in the field that is missing.
                $e.LstSections.SelectedIndex = 5
                $win.UpdateLayout()
                [void]$e[$joinProblem.Control].Focus()
                throw $joinProblem.Message
            }
            # Windows Setup reads these at Getting ready, after the disk is erased: a password typed in the product
            # key box stopped a deploy there (specialize, Microsoft-Windows-Shell-Setup).
            $settingProblem = @((Test-ProductKeyValue $a.ProductKey), (Test-TimeZoneId $a.TimeZone)) | Where-Object { $_ } | Select-Object -First 1
            if ($settingProblem) {
                $e.LstSections.SelectedIndex = 3
                $win.UpdateLayout()
                if (Test-ProductKeyValue $a.ProductKey) { [void]$e.TxtProductKey.Focus() } else { [void]$e.CmbTimeZone.Focus() }
                throw $settingProblem
            }
            if ($a.EnableAdministrator -and -not $e.PwdAdmin.Password -and -not (Test-SavedPassword -ContentRoot $ContentRoot -RelativePath $a.AdminPasswordFile -Encrypted $a.AdminPasswordEncrypted)) {
                throw 'Enter the Administrator password (Windows settings).'
            }
            Save-AnswerFromEditor -ContentRoot $ContentRoot -Answer $a -JoinPassword $e.PwdJoin.Password `
                -AdminPassword $e.PwdAdmin.Password -IsNew:$isNew | Out-Null
            $state.Saved = $true
            $win.Close()
        } catch {
            $e.TxtProblems.Text = $_.Exception.Message
        }
    })

    [void]$win.ShowDialog()
    $state.Saved
}
