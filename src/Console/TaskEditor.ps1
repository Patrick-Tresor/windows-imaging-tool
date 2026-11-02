# Task editor window: a script for the task library (Tasks tab), typed here or imported, with when it runs,
# its arguments, timeout, success codes and which PCs get it.
# Dot-sourced by ImagingConsole.ps1 after AnswerEditor.ps1 (for Get-XamlControls); uses TaskPack.psm1 and ConsoleData.psm1.

function Get-TaskPhaseNote([string]$Phase) {
    switch ($Phase) {
        'POSTIMAGE'  { 'In WinPE, once the image and drivers are applied and before the PC restarts. The new Windows is %OSDRIVE% ($env:OSDRIVE in PowerShell), the content root %DEPLOYROOT%. WinPE has no .NET Framework programs and no user.' }
        'FIRSTBOOT'  { 'On the new Windows, as SYSTEM, the first time it starts, after the applications and before anyone logs on.' }
        'FIRSTLOGON' { 'When the first user logs on, as that user. Kept in C:\ProgramData\ImagingTool\Tasks on the PC.' }
        default      { '' }
    }
}

function Show-TaskEditor {
    <#
    .SYNOPSIS
        Opens the editor for a new task, or for Tasks\<Name> with -Name. Returns the saved name or $null.
    #>
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [string]$Name
    )
    $isNew = -not $Name
    $taskRoot = Join-Path $ContentRoot 'Tasks'
    $def = if ($isNew) { ConvertTo-TaskDefinition -Name 'NewTask' -Json ([pscustomobject]@{ script = 'script.ps1' }) }
           else { Read-TaskPack -TaskRoot $taskRoot -Name $Name }

    [xml]$tx = Get-Content -Raw (Join-Path $PSScriptRoot 'TaskEditor.xaml')
    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($tx))
    $win.Owner = $Owner
    Enable-WheelScrolling $win
    $e = Get-XamlControls $tx $win
    $win.Title = if ($isNew) { 'New task' } else { "Task: $Name" }
    $folder = if ($isNew) { $null } else { Join-Path $taskRoot $Name }
    # LoadedText: the script text as read, so an unchanged imported file is copied as is and not rewritten.
    $state = @{ Saved = $null; LoadedText = $null }
    $codes = { param($text) @($text -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
    $list  = { param($text) @($text -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    $e.CmbPhase.ItemsSource = @('POSTIMAGE', 'FIRSTBOOT', 'FIRSTLOGON')
    $e.TxtName.Text = $def.name
    $e.TxtName.IsReadOnly = -not $isNew
    $e.TxtDescription.Text = $def.description
    $e.CmbPhase.SelectedItem = $def.phase
    $e.CmbScript.Text = $def.script
    $e.TxtArguments.Text = $def.arguments
    $e.TxtCodes.Text = $def.successCodes -join ', '
    $e.TxtTimeout.Text = $def.timeoutMinutes
    $e.ChkStop.IsChecked = $def.stopOnFailure
    $e.TxtMakers.Text = @($def.requirements.makers) -join ', '
    $e.TxtModels.Text = @($def.requirements.models) -join ', '
    if ($folder) {
        $state.LoadedText = Get-TaskScriptText -Definition $def -Folder $folder
        if ($null -ne $state.LoadedText) { $e.TxtScript.Text = $state.LoadedText }
    }

    $sourceDir = {
        # Where the script files come from: the imported folder, the imported file's folder, or the saved task folder.
        $src = $e.TxtSource.Text.Trim()
        if ($src -and (Test-Path $src -PathType Container)) { return $src }
        if ($src -and (Test-Path $src -PathType Leaf)) { return Split-Path $src -Parent }
        $folder
    }
    $refreshFiles = {
        $dir = & $sourceDir
        $e.CmbScript.ItemsSource = @(if ($dir -and (Test-Path $dir)) {
            Get-ChildItem $dir -File | Where-Object { Get-TaskTypeFromFile $_.Name } | ForEach-Object Name
        })
    }
    $loadScript = {
        # Shows the chosen script's text from the import, so it can be checked or changed before saving.
        $dir = & $sourceDir
        $file = $e.CmbScript.Text.Trim()
        if (-not $dir -or -not $file) { return }
        $path = Join-Path $dir $file
        $type = Get-TaskTypeFromFile $file
        if ($type -and $type -ne 'exe' -and (Test-Path $path -PathType Leaf)) {
            $state.LoadedText = Get-Content -Raw -Path $path
            $e.TxtScript.Text = $state.LoadedText
        }
    }
    $updateNotes = {
        $file = $e.CmbScript.Text.Trim()
        $type = Get-TaskTypeFromFile $file
        $e.TxtType.Text = switch ($type) {
            'powershell' { 'Runs with Windows PowerShell 5.1 (powershell.exe -ExecutionPolicy Bypass -File).' }
            'cmd'        { 'Runs with cmd.exe.' }
            'exe'        { 'Runs the program from the task''s folder. Import it with File... or Folder...; there is no script text.' }
            default      { if ($file) { 'Use a .ps1, .cmd, .bat or .exe file name.' } else { '' } }
        }
        $e.TxtScript.IsEnabled = $type -ne 'exe'
        $e.TxtPhaseNote.Text = Get-TaskPhaseNote "$($e.CmbPhase.SelectedItem)"
        $e.TxtCommandLine.Text = if ($type) {
            $d = [pscustomobject]@{ script = $file; type = $type; arguments = $e.TxtArguments.Text.Trim() }
            "Runs: $(Get-TaskCommandLine -Definition $d -Folder '<task folder>')"
        } else { '' }
    }
    & $refreshFiles
    & $updateNotes

    $afterSource = {
        $src = $e.TxtSource.Text.Trim()
        & $refreshFiles
        if ($src -and (Test-Path $src -PathType Leaf)) { $e.CmbScript.Text = Split-Path $src -Leaf }
        elseif (@($e.CmbScript.ItemsSource).Count -eq 1) { $e.CmbScript.Text = @($e.CmbScript.ItemsSource)[0] }
        if ($isNew -and $e.TxtName.Text -eq 'NewTask' -and $src) {
            $e.TxtName.Text = ([IO.Path]::GetFileNameWithoutExtension($src) -replace '[^A-Za-z0-9._-]', '-')
        }
        & $loadScript
        & $updateNotes
    }
    $e.BtnSourceFile.Add_Click({
        $f = [Microsoft.Win32.OpenFileDialog]::new()
        $f.Filter = 'Scripts (*.ps1;*.cmd;*.bat;*.exe)|*.ps1;*.cmd;*.bat;*.exe|All files (*.*)|*.*'
        if ($f.ShowDialog($win)) { $e.TxtSource.Text = $f.FileName; & $afterSource }
    })
    $e.BtnSourceFolder.Add_Click({
        $f = [Windows.Forms.FolderBrowserDialog]::new()
        $f.Description = 'Folder with the script and the files it needs'
        if ($f.ShowDialog() -eq 'OK') { $e.TxtSource.Text = $f.SelectedPath; & $afterSource }
    })
    $e.CmbScript.Add_SelectionChanged({ $win.Dispatcher.BeginInvoke([Action]{ & $loadScript; & $updateNotes }) | Out-Null })
    $e.CmbScript.Add_LostFocus({ & $updateNotes })
    $e.CmbPhase.Add_SelectionChanged({ & $updateNotes })
    $e.TxtArguments.Add_TextChanged({ & $updateNotes })

    $collect = {
        $n = 0
        ConvertTo-TaskDefinition -Name $e.TxtName.Text.Trim() -Json ([pscustomobject]@{
            description    = $e.TxtDescription.Text.Trim()
            script         = $e.CmbScript.Text.Trim()
            arguments      = $e.TxtArguments.Text.Trim()
            phase          = "$($e.CmbPhase.SelectedItem)"
            timeoutMinutes = if ([int]::TryParse($e.TxtTimeout.Text, [ref]$n)) { $n } else { 0 }
            successCodes   = @(& $codes $e.TxtCodes.Text)
            stopOnFailure  = [bool]$e.ChkStop.IsChecked
            requirements   = @{ makers = @(& $list $e.TxtMakers.Text); models = @(& $list $e.TxtModels.Text) }
        })
    }

    $e.BtnCancel.Add_Click({ $win.Close() })
    $e.BtnSave.Add_Click({
        try {
            $d = & $collect
            $src = $e.TxtSource.Text.Trim()
            $save = @{ ContentRoot = $ContentRoot; Definition = $d; Source = $src; New = $isNew }
            # The typed text is written when it was changed, or when there is no file to copy it from.
            $text = $e.TxtScript.Text
            $fromFile = $src -or ($folder -and (Test-Path (Join-Path $folder $d.script)))
            if ($d.type -ne 'exe' -and ($text -ne $state.LoadedText -or -not $fromFile)) {
                if (-not $text.Trim() -and -not $fromFile) { throw 'Type the script, or import a file with File... or Folder....' }
                if ($text.Trim()) { $save.ScriptText = $text }
            }
            $win.Cursor = 'Wait'
            try { Save-Task @save | Out-Null } finally { $win.Cursor = $null }
            $state.Saved = $d.name
            $win.Close()
        } catch {
            $e.TxtProblems.Text = $_.Exception.Message
        }
    })

    [void]$win.ShowDialog()
    $state.Saved
}
