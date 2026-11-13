<#
.SYNOPSIS
    Runs on a deployed PC whose image was captured without sysprep: generalizes it at its first start.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\ProgramData\ImagingTool\Sysprep with Prepare-Reference.ps1, the module
    SysprepAtDeploy.psm1, sysprep.json and the deploy's answer file, and makes Windows run it once at its next
    start, before the logon screen (-Stage Hook, from HKLM\SYSTEM\Setup CmdLine).

    -Stage Hook starts the SYSTEM task ImagingTool\SysprepAtDeploy, which runs this with -Stage Run (the Task
    Scheduler and every other service are up by then), and waits for it. While the hook waits, Windows does not
    show its logon screen, so whoever deploys sees the boot spinner until the PC restarts into setup, as with a
    sysprepped image. The startup command stays set until sysprep has run, so a restart Windows needs first comes
    back to the hook. When the task cannot be created, the Run stage runs in the hook itself.

    -Stage Run restarts first when Windows servicing waits for one (up to 2 restarts; Windows Update's own flag alone
    is no reason), runs Prepare-Reference.ps1 -CheckOnly -RemoveUserApps -SkipRebootCheck (BitLocker, Store apps
    that break sysprep, a missing Microsoft Store), then
    sysprep /generalize /oobe /reboot /unattend. After the restart Windows setup applies the answer file and
    SetupComplete.cmd starts FirstBoot.ps1, as with a sysprepped image.

    When anything fails, the startup command is turned off, the logon screen says so (the PC is still a copy of the reference VM) and the details
    are in C:\Windows\Temp\SysprepAtDeploy.log.
#>
[CmdletBinding()]
param([ValidateSet('Hook', 'Run')][string]$Stage = 'Run')

# Continue: Windows PowerShell 5.1 turns a native tool's stderr (schtasks, reg) into a terminating error under Stop.
# Each step checks its own result; the steps that must not fail quietly say -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$folder = $PSScriptRoot
$logPath = 'C:\Windows\Temp\SysprepAtDeploy.log'
$taskName = 'ImagingTool\SysprepAtDeploy'
$noticeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Import-Module ([IO.Path]::Combine($folder, 'SysprepAtDeploy.psm1')) -Force -ErrorAction Stop

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [{2}] {3}' -f (Get-Date), $Level, $Stage, $Message
    try { Add-Content -LiteralPath $logPath -Value $line } catch { }
}

function Read-Plan {
    $path = [IO.Path]::Combine($folder, 'sysprep.json')
    if ([IO.File]::Exists($path)) { return [IO.File]::ReadAllText($path) | ConvertFrom-Json }
    [pscustomobject]@{}
}

function Set-Notice([string]$Caption, [string]$Text) {
    try {
        if (-not (Test-Path $noticeKey)) { New-Item -Path $noticeKey -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $noticeKey -Name legalnoticecaption -Value $Caption -ErrorAction Stop
        Set-ItemProperty -Path $noticeKey -Name legalnoticetext -Value $Text -ErrorAction Stop
    } catch { Write-Log "Could not set the logon notice: $($_.Exception.Message)" 'WARN' }
}

$script:InHook = $false

function Wait-ForRestart {
    # In the hook, returning would let Windows carry on with this boot (and, after sysprep, with the startup
    # command sysprep set for the next one), so wait for the restart already under way.
    if ($script:InHook) { Start-Sleep -Seconds 600 }
}

function Set-RunState([string]$State) {
    # What the waiting hook reads: running, restart, sysprep, done or failed.
    try { [IO.File]::WriteAllText([IO.Path]::Combine($folder, 'state.txt'), $State) } catch { }
}

function Get-RunState {
    $path = [IO.Path]::Combine($folder, 'state.txt')
    try { if ([IO.File]::Exists($path)) { return [IO.File]::ReadAllText($path).Trim() } } catch { }
    ''
}

function Clear-StartupHook {
    # Windows then shows its logon screen after this boot, and never runs the hook again.
    Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name SetupType -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name CmdLine -Value '' -ErrorAction SilentlyContinue
}

function Set-StartupHook {
    # Windows turns SetupType back to 0 once it has started the hook, so a restart before sysprep would come back
    # to the logon screen (the Yoga's log: runs 2 and 3 had no hook). Setting it again before each restart keeps
    # the boot spinner up until sysprep has run.
    Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name CmdLine -Value (Get-SysprepHookCommand -Folder $folder) -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name SetupType -Value 2 -Type DWord -ErrorAction SilentlyContinue
}

function Stop-WithFailure([string]$Reason) {
    # Leaves the PC as it is (a copy of the reference VM that never generalized) and says so on the logon screen.
    Write-Log $Reason 'ERROR'
    Clear-StartupHook
    Set-RunState 'failed'
    & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    $notice = Get-SysprepFailureNotice -Reason $Reason -LogPath $logPath
    Set-Notice -Caption $notice.Caption -Text $notice.Text
    $unattend = [IO.Path]::Combine($folder, 'unattend.xml')
    if ([IO.File]::Exists($unattend)) { [IO.File]::Delete($unattend) }   # it holds the deploy's passwords
    exit 1
}

function Invoke-RunStage {
    $plan = Read-Plan
    $attemptFile = [IO.Path]::Combine($folder, 'attempts.txt')
    $attempt = if ([IO.File]::Exists($attemptFile)) { [int]([IO.File]::ReadAllText($attemptFile).Trim()) } else { 0 }
    $attempt++
    [IO.File]::WriteAllText($attemptFile, "$attempt")
    Set-RunState 'running'
    Write-Log "Run $attempt on $env:COMPUTERNAME (still the reference VM's name until sysprep)"

    $markers = @(Get-PendingRebootMarkers -ExistingKeys @(@(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    ) | Where-Object { Test-Path $_ }))
    if ($markers.Count) { Write-Log "Windows says a restart is needed: $($markers -join ', ')" }
    if (Test-RebootPendingFor -Markers $markers -Attempt $attempt) {
        # The hook (still set) starts this again after the restart, without a logon screen in between.
        Write-Log 'Windows servicing is waiting for a restart; restarting before sysprep.' 'WARN'
        Set-RunState 'restart'
        Set-StartupHook
        & shutdown.exe /r /t 0 2>&1 | Out-Null
        Wait-ForRestart
        exit 0
    }
    if ($markers.Count) {
        # The restarts this stage could do are done (or only Windows Update's flag is left, which a restart does not
        # clear on a copied Windows). Sysprep checks for itself what really blocks it and says so when it fails.
        Write-Log 'Going on with sysprep anyway; sysprep reports it if this really blocks it.' 'WARN'
    }

    # The reference checks, on this PC: BitLocker, Store apps installed for one user only (removed), the Store.
    $prepare = [IO.Path]::Combine($folder, 'Prepare-Reference.ps1')
    # -SkipRebootCheck: this stage has already handled the pending restart above.
    Write-Log 'Running Prepare-Reference.ps1 -CheckOnly -RemoveUserApps -SkipRebootCheck'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prepare -CheckOnly -RemoveUserApps -SkipRebootCheck 2>&1
    $prepareExit = $LASTEXITCODE
    foreach ($line in @($out)) { if ("$line".Trim()) { Write-Log "  $line" } }
    if ($prepareExit -ne 0) {
        $problem = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match '^PROBLEM:' }) | Select-Object -First 1
        Stop-WithFailure "The checks before sysprep failed. $(if ($problem) { $problem.Trim() } else { "Prepare-Reference exit $prepareExit." })"
    }

    # Nothing of ours may survive into the generalized Windows: the task would run again after setup, and device
    # encryption has to be allowed again. Nothing is shown on screen while this runs; only a failure is.
    & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    if ($plan.PSObject.Properties['preventDeviceEncryptionSet'] -and $plan.preventDeviceEncryptionSet) {
        Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name PreventDeviceEncryption -ErrorAction SilentlyContinue
        Write-Log 'Device encryption allowed again'
    }

    $unattend = [IO.Path]::Combine($folder, 'unattend.xml')
    $sysprepArgs = Get-SysprepArguments -UnattendPath $unattend
    Write-Log "Running sysprep $($sysprepArgs -join ' ')"
    Set-RunState 'sysprep'
    $sysprep = [IO.Path]::Combine($env:WINDIR, 'System32\Sysprep\sysprep.exe')
    $proc = Start-Process -FilePath $sysprep -ArgumentList $sysprepArgs -Wait -PassThru -ErrorAction Stop
    # sysprep keeps its own copy in Windows\Panther; this one holds the deploy's passwords.
    if ([IO.File]::Exists($unattend)) { try { [IO.File]::Delete($unattend) } catch { } }

    $ini = [IO.Path]::Combine($env:WINDIR, 'Setup\State\State.ini')
    $state = if ([IO.File]::Exists($ini)) {
        @([IO.File]::ReadAllLines($ini) | ForEach-Object { if ($_ -match '^\s*ImageState\s*=\s*(\S+)') { $Matches[1] } }) | Select-Object -First 1
    } else { '' }
    $errLog = [IO.Path]::Combine($env:WINDIR, 'System32\Sysprep\Panther\setuperr.log')
    $errors = if ([IO.File]::Exists($errLog)) { [IO.File]::ReadAllLines($errLog) } else { @() }
    $outcome = Get-SysprepOutcome -ImageState $state -ExitCode $proc.ExitCode -ErrorLines $errors
    if ($outcome.Ok) { Set-RunState 'done'; Write-Log 'Sysprep finished; Windows restarts into setup.'; Wait-ForRestart; exit 0 }
    Stop-WithFailure $outcome.Reason
}

try {
    if ($Stage -eq 'Hook') {
        # A hook that keeps coming back (a restart loop) gives up: the Run stage allows 3 restarts.
        $hookFile = [IO.Path]::Combine($folder, 'hook-runs.txt')
        $hookRuns = 1 + $(if ([IO.File]::Exists($hookFile)) { [int]([IO.File]::ReadAllText($hookFile).Trim()) } else { 0 })
        [IO.File]::WriteAllText($hookFile, "$hookRuns")
        if ($hookRuns -gt 5) { Stop-WithFailure "The first start was interrupted $($hookRuns - 1) times before sysprep could finish." }
        Write-Log "First start of a deployed image that was not sysprepped (start $hookRuns)"
        Set-RunState ''
        $run = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$folder\Invoke-SysprepAtDeploy.ps1`" -Stage Run"
        $created = & schtasks.exe /Create /TN $taskName /TR $run /SC ONSTART /DELAY 0000:30 /RU SYSTEM /RL HIGHEST /F 2>&1
        $ok = $LASTEXITCODE -eq 0
        if ($ok) {
            $started = & schtasks.exe /Run /TN $taskName 2>&1
            $ok = $LASTEXITCODE -eq 0
            if (-not $ok) { Write-Log "Could not start the task $taskName ($started)." 'WARN' }
        } else { Write-Log "Could not create the task $taskName ($created)." 'WARN' }
        if (-not $ok) {
            Write-Log 'Running sysprep here instead.' 'WARN'
            & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
            $script:InHook = $true
            $Stage = 'Run'
            Invoke-RunStage
        }
        Write-Log "Task $taskName started; waiting for it (no logon screen meanwhile)"
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $state = ''
        # The limit grows once sysprep itself runs (Get-SysprepWaitMinutes), so a slow sysprep is not called failed.
        while ($clock.Elapsed.TotalMinutes -lt (Get-SysprepWaitMinutes -State $state)) {
            Start-Sleep -Seconds 5
            $state = Get-RunState
            if (Test-SysprepHookDone -State $state) { break }
        }
        if ($state -in 'done', 'restart') {
            # Windows is restarting. Returning now would let Windows carry on with the startup command sysprep has
            # just set for the next start, so wait for the restart instead.
            Start-Sleep -Seconds 600
            exit 0
        }
        if ($state -ne 'failed') { Stop-WithFailure "Sysprep did not finish within $(Get-SysprepWaitMinutes -State $state) minutes (last state: $(if ($state) { $state } else { 'not started' }))." }
        exit 1
    }
    Invoke-RunStage
}
catch {
    Stop-WithFailure "Unexpected error: $($_.Exception.Message)"
}
