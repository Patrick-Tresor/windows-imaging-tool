# The window WinPE shows while Deploy-Image.ps1 works: hardware, what is being deployed, the current step and a
# progress bar, the end of the log, then the result with Restart, Shut down, View log and Command prompt buttons.
# It runs in its own process (DeployProgressWindow.ps1) so it stays responsive while DISM runs, and reads the
# progress file that DeployStatus.psm1 writes (Start-LocalProgress). WinForms, because WinPE-NetFX has no WPF.
# Get-ProgressView and Get-LogTail have no UI code, so they are tested anywhere.

Import-Module (Join-Path $PSScriptRoot 'DeployWizard.psm1')
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1')

function Read-ProgressFile {
    # The progress record, or $null while it does not exist yet or is being replaced.
    param([Parameter(Mandatory)][string]$Path)
    try { Get-Content -Raw -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json } catch { $null }
}

function Get-LogTail {
    # The last lines of the deploy log, for the window's details box.
    param([Parameter(Mandatory)][string]$Path, [int]$Lines = 14)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try { @([IO.File]::ReadAllText($Path) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last $Lines) } catch { @() }
}

function Get-ProgressView {
    <#
    .SYNOPSIS
        What the progress window shows for a progress record: title, step, percent, colours and which buttons.
    .PARAMETER DeployRunning
        Whether Deploy-Image.ps1 is still running. A record left Running by a script that ended means it crashed.
    #>
    param(
        $Record,
        [bool]$DeployRunning = $true,
        [datetime]$Now = (Get-Date)
    )
    $state = if ($Record) { "$($Record.state)" } else { 'Running' }
    if ($state -eq 'Running' -and -not $DeployRunning) { $state = 'Stopped' }
    $countdown = if ($Record -and $Record.PSObject.Properties['countdown']) { [int]$Record.countdown } else { 0 }
    $step = if ($Record) { "$($Record.step)" } else { 'Starting' }
    $percent = if ($Record) { [Math]::Max(0, [Math]::Min(100, [int]$Record.percent)) } else { 0 }
    $whenDone = if ($Record -and $Record.PSObject.Properties['whenDone']) { "$($Record.whenDone)" } else { '' }
    $warnings = @(if ($Record) { @($Record.warnings) | Where-Object { $_ } })

    $title = $null; $detail = $step; $message = ''; $color = 'Normal'
    switch ($state) {
        'Running' {
            if ($countdown -gt 0) {
                $title = "Starting in $countdown s"
                $detail = 'The deployment starts on its own. Click Change settings to pick the answer file, name or disk yourself.'
            }
            elseif ($step -eq 'Waiting for the operator') { $title = 'Waiting for your choices' }
            elseif ($step -eq 'Starting' -or $percent -lt 5) { $title = 'Getting ready' }
            else { $title = 'Installing Windows' }
            if ($warnings) { $message = 'Warning: ' + ($warnings -join '; ') }
        }
        { $_ -in 'Succeeded', 'Warning' } {
            $title = 'Windows is installed'
            $percent = 100
            $color = if ($state -eq 'Warning') { 'Warning' } else { 'Good' }
            $detail = switch ($whenDone) {
                'restart'  { 'Restarting into Windows. Setup and the applications finish there.' }
                'shutdown' { 'Shutting down. Windows finishes setting up the next time the PC starts.' }
                default    { 'Restart the PC to finish setting up Windows and install the applications.' }
            }
            if ($warnings) { $message = 'Finished with warnings: ' + ($warnings -join '; ') }
        }
        'Cancelled' {
            $title = 'Deployment cancelled'
            $detail = 'Nothing was erased. Restart to start again.'
        }
        'Failed' {
            $title = 'Deployment failed'; $color = 'Bad'
            $detail = "Failed while: $step"
            $message = "$($Record.message)"
        }
        'Stopped' {
            $title = 'Deployment stopped'; $color = 'Bad'
            $detail = "The deploy script ended during: $step"
            $message = 'See the log for the last thing it did.'
        }
    }

    $finished = $state -ne 'Running'
    $elapsed = $null
    if ($Record -and $Record.started) {
        $end = if ($finished -and $Record.finished) { [datetime]$Record.finished } else { $Now }
        $elapsed = Format-Duration ($end - [datetime]$Record.started)
    }
    $facts = @(if ($Record) {
        if ($Record.computerName) { "Computer name:  $($Record.computerName)" }
        if ($Record.answerFile)   { "Answer file:    $($Record.answerFile)" }
        if ($Record.image)        { "Image:          $($Record.image)" }
        if ($Record.answerFile)   { "Drivers:        $(if ($Record.driverPack) { $Record.driverPack } else { 'checking' })" }
    })

    [pscustomobject]@{
        State        = $state
        Title        = $title
        Detail       = $detail
        Message      = $message
        Percent      = $percent
        PercentText  = "$percent %$(if ($elapsed) { "    $(if ($finished) { 'Took' } else { 'Elapsed' }) $elapsed" })"
        Color        = $color
        Hardware     = if ($Record) { ("$($Record.maker) $($Record.model)".Trim() + $(if ($Record.serial) { "   Serial $($Record.serial)" })) } else { '' }
        Facts        = $facts
        Finished     = $finished
        # Sidebar step: 4 Install Windows while it runs, 5 Finish once it ended (well or not).
        SidebarStep  = if ($finished) { 5 } elseif ($step -eq 'Waiting for the operator' -or $countdown -gt 0) { 0 } else { 4 }
        ShowChange   = $state -eq 'Running' -and $countdown -gt 0
        ShowPower    = $finished -and $whenDone -notin 'restart', 'shutdown'
        Busy         = -not $finished -and $countdown -le 0 -and $step -ne 'Waiting for the operator'
    }
}

function New-DeployProgressForm {
    # Builds the window. Returns its controls by name; Update-DeployProgressForm fills them from a view.
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $font = New-Object Drawing.Font('Segoe UI', 10)
    $ui = @{}
    $ui.Form = New-Object Windows.Forms.Form -Property @{
        Text = 'Deploy Windows'; ClientSize = New-Object Drawing.Size(920, 540); Font = $font
        StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $true
        BackColor = [Drawing.Color]::White
    }
    $ui.Title = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(224, 16)); Size = (New-Object Drawing.Size(672, 34)); Font = New-Object Drawing.Font('Segoe UI', 16) }
    $ui.Hardware = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(224, 52)); Size = (New-Object Drawing.Size(672, 22)); ForeColor = [Drawing.Color]::DimGray }
    $ui.Facts = New-Object Windows.Forms.Label -Property @{
        Location = (New-Object Drawing.Point(224, 84)); Size = (New-Object Drawing.Size(672, 84))
        Font = New-Object Drawing.Font([Drawing.FontFamily]::GenericMonospace, 10)
    }
    $ui.Detail = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(224, 174)); Size = (New-Object Drawing.Size(672, 44)); Font = New-Object Drawing.Font('Segoe UI', 11) }
    $ui.Bar = New-Object Windows.Forms.ProgressBar -Property @{ Location = (New-Object Drawing.Point(224, 222)); Size = (New-Object Drawing.Size(672, 26)); Minimum = 0; Maximum = 100; Style = 'Continuous' }
    $ui.Percent = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(224, 252)); Size = (New-Object Drawing.Size(672, 22)); ForeColor = [Drawing.Color]::DimGray }
    $ui.Message = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(224, 276)); Size = (New-Object Drawing.Size(672, 44)) }
    $ui.Log = New-Object Windows.Forms.TextBox -Property @{
        Location = (New-Object Drawing.Point(224, 324)); Size = (New-Object Drawing.Size(672, 160)); Multiline = $true; ReadOnly = $true
        ScrollBars = 'Vertical'; WordWrap = $false; BackColor = [Drawing.Color]::WhiteSmoke
        Font = New-Object Drawing.Font([Drawing.FontFamily]::GenericMonospace, 8)
    }
    $ui.ViewLog  = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(224, 496)); Size = (New-Object Drawing.Size(100, 32)); Text = 'View log' }
    $ui.Cmd      = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(330, 496)); Size = (New-Object Drawing.Size(150, 32)); Text = 'Command prompt' }
    $ui.Change   = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(646, 496)); Size = (New-Object Drawing.Size(250, 32)); Text = 'Change settings' }
    $ui.Shutdown = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(690, 496)); Size = (New-Object Drawing.Size(100, 32)); Text = 'Shut down' }
    $ui.Restart  = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(796, 496)); Size = (New-Object Drawing.Size(100, 32)); Text = 'Restart' }
    $ui.Form.Controls.AddRange(@($ui.Title, $ui.Hardware, $ui.Facts, $ui.Detail, $ui.Bar, $ui.Percent, $ui.Message, $ui.Log,
        $ui.ViewLog, $ui.Cmd, $ui.Change, $ui.Shutdown, $ui.Restart))
    $ui.Sidebar = New-DeploySidebar -Form $ui.Form
    $ui
}

function Update-DeployProgressForm {
    # Shows a view (Get-ProgressView) and the log tail. Only changed text is set, so the window does not flicker.
    param([Parameter(Mandatory)][hashtable]$Ui, [Parameter(Mandatory)]$View, [string[]]$LogLines = @())
    $colors = @{
        Normal  = [Drawing.Color]::Black
        Good    = [Drawing.Color]::ForestGreen
        Warning = [Drawing.Color]::DarkOrange
        Bad     = [Drawing.Color]::Firebrick
    }
    $set = { param($Control, $Text) if ($Control.Text -cne $Text) { $Control.Text = $Text } }
    & $set $Ui.Title $View.Title
    $Ui.Title.ForeColor = $colors[$View.Color]
    & $set $Ui.Hardware $View.Hardware
    & $set $Ui.Facts ($View.Facts -join "`r`n")
    & $set $Ui.Detail $View.Detail
    & $set $Ui.Percent $View.PercentText
    & $set $Ui.Message $View.Message
    $Ui.Message.ForeColor = if ($View.Color -eq 'Bad') { $colors.Bad } else { $colors.Warning }
    $Ui.Bar.Value = $View.Percent
    $log = $LogLines -join "`r`n"
    if ($Ui.Log.Text -cne $log) {
        $Ui.Log.Text = $log
        $Ui.Log.SelectionStart = $Ui.Log.TextLength
        $Ui.Log.ScrollToCaret()
    }
    $Ui.Change.Visible = $View.ShowChange
    $Ui.Shutdown.Visible = $View.ShowPower
    $Ui.Restart.Visible = $View.ShowPower
    $Ui.Form.Cursor = if ($View.Busy) { [Windows.Forms.Cursors]::AppStarting } else { [Windows.Forms.Cursors]::Default }
    Set-DeploySidebarStep -Labels $Ui.Sidebar -Current $View.SidebarStep
}

function Show-DeployProgressWindow {
    <#
    .SYNOPSIS
        Shows the progress window until it is closed, refreshing every second.
    .PARAMETER DeployProcessId
        Deploy-Image.ps1's process. When it ends with the record still Running, the window says the deployment stopped.
    #>
    param(
        [Parameter(Mandatory)][string]$ProgressPath,
        [string]$LogPath = 'X:\Windows\Temp\Deploy.log',
        [int]$DeployProcessId
    )
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $ui = New-DeployProgressForm
    # Event handlers run outside this function's scope, so everything they share lives here.
    $script:progress = @{ Ui = $ui; Path = $ProgressPath; Log = $LogPath; Pid = $DeployProcessId; View = $null }

    $refresh = {
        $p = $script:progress
        try {
            $running = if ($p.Pid) { [bool](Get-Process -Id $p.Pid -ErrorAction SilentlyContinue) } else { $true }
            $p.View = Get-ProgressView -Record (Read-ProgressFile -Path $p.Path) -DeployRunning $running
            Update-DeployProgressForm -Ui $p.Ui -View $p.View -LogLines (Get-LogTail -Path $p.Log)
        } catch { }   # a half-written file or a closing window: the next tick tries again
    }
    $script:progress.Refresh = $refresh

    $ui.ViewLog.add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$($script:progress.Log)`"" })
    $ui.Cmd.add_Click({ Start-Process -FilePath 'cmd.exe' })
    $ui.Change.add_Click({
        # Deploy-Image.ps1 sees the file at the next tick of its countdown and opens the wizard instead.
        Set-Content -Path (Get-ProgressCancelPath $script:progress.Path) -Value 'change' -Encoding ascii
        $script:progress.Ui.Change.Enabled = $false
    })
    $ui.Restart.add_Click({ Start-Process -FilePath 'wpeutil.exe' -ArgumentList 'reboot' -WindowStyle Hidden })
    $ui.Shutdown.add_Click({ Start-Process -FilePath 'wpeutil.exe' -ArgumentList 'shutdown' -WindowStyle Hidden })
    $ui.Form.add_FormClosing({
        param($s, $e)
        # Closing the window does not stop the deployment, so ask before hiding a running one.
        $v = $script:progress.View
        if ($v -and -not $v.Finished -and $e.CloseReason -eq 'UserClosing') {
            $answer = [Windows.Forms.MessageBox]::Show('The deployment keeps running without this window. Close it anyway?',
                'Deploy Windows', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { $e.Cancel = $true }
        }
    })

    $timer = New-Object Windows.Forms.Timer -Property @{ Interval = 1000 }
    $timer.add_Tick({ & $script:progress.Refresh })
    $ui.Form.add_Shown({ & $script:progress.Refresh; $script:progress.Ui.Form.Activate() })
    $timer.Start()
    [Windows.Forms.Application]::Run($ui.Form)
    $timer.Dispose()
    $ui.Form.Dispose()
    $script:progress = $null
}

Export-ModuleMember -Function Read-ProgressFile, Get-LogTail, Get-ProgressView, New-DeployProgressForm, Update-DeployProgressForm,
    Show-DeployProgressWindow
