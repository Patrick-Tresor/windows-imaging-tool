<#
.SYNOPSIS
    Runs on a deployed PC whose image was captured without sysprep: generalizes it at its first start.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\ProgramData\ImagingTool\Sysprep with Prepare-Reference.ps1, the module
    SysprepAtDeploy.psm1, sysprep.json and the deploy's answer file, and makes Windows run it once at its next
    start, before the logon screen (-Stage Hook, from HKLM\SYSTEM\Setup CmdLine).

    -Stage Hook turns that startup command off again and starts the SYSTEM task ImagingTool\SysprepAtDeploy, which runs this with -Stage Run once the PC has fully
    started (all services up). When the task cannot be created there, the Run stage runs right away instead.

    -Stage Run restarts first when Windows waits for one (up to 3 times), runs Prepare-Reference.ps1 -CheckOnly
    -RemoveUserApps (BitLocker, Store apps that break sysprep, a missing Microsoft Store), then
    sysprep /generalize /oobe /reboot /unattend. After the restart Windows setup applies the answer file and
    SetupComplete.cmd starts FirstBoot.ps1, as with a sysprepped image.

    When anything fails, the logon screen says so (the PC is still a copy of the reference VM) and the details
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

function Stop-WithFailure([string]$Reason) {
    # Leaves the PC as it is (a copy of the reference VM that never generalized) and says so on the logon screen.
    Write-Log $Reason 'ERROR'
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
    Write-Log "Run $attempt on $env:COMPUTERNAME (still the reference VM's name until sysprep)"

    $pending = [bool](@(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    ) | Where-Object { Test-Path $_ })
    if (Test-RebootPendingFor -Pending $pending -Attempt $attempt) {
        # The startup task runs this again after the restart.
        Write-Log 'Windows is waiting for a restart (servicing or Windows Update); restarting before sysprep.' 'WARN'
        & shutdown.exe /r /t 5 /c 'Restarting before sysprep (deployment)' 2>&1 | Out-Null
        exit 0
    }
    if ($pending) { Write-Log 'A restart is still pending after several restarts; trying sysprep anyway.' 'WARN' }

    # The reference checks, on this PC: BitLocker, Store apps installed for one user only (removed), the Store.
    $prepare = [IO.Path]::Combine($folder, 'Prepare-Reference.ps1')
    Write-Log 'Running Prepare-Reference.ps1 -CheckOnly -RemoveUserApps'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prepare -CheckOnly -RemoveUserApps 2>&1
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
    if ($outcome.Ok) { Write-Log 'Sysprep finished; Windows restarts into setup.'; exit 0 }
    Stop-WithFailure $outcome.Reason
}

try {
    if ($Stage -eq 'Hook') {
        # Once is enough: a failure below must not start this again at every boot.
        Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name SetupType -Value 0 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name CmdLine -Value '' -ErrorAction Stop
        Write-Log 'First start of a deployed image that was not sysprepped'
        # The task runs once all services are up (Store apps, BitLocker and sysprep need them), and again after
        # a restart, until it removes itself.
        $run = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$folder\Invoke-SysprepAtDeploy.ps1`" -Stage Run"
        $created = & schtasks.exe /Create /TN $taskName /TR $run /SC ONSTART /RU SYSTEM /RL HIGHEST /DELAY 0000:30 /F 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Could not create the task $taskName ($created); running sysprep now instead." 'WARN'
            $Stage = 'Run'
            Invoke-RunStage
        }
        $started = & schtasks.exe /Run /TN $taskName 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log "Task $taskName started" }
        else {
            # The task's start-up trigger runs it after a restart.
            Write-Log "Could not start the task now ($started); restarting so it runs at startup." 'WARN'
            & shutdown.exe /r /t 10 /c 'Restarting to run sysprep (deployment)' 2>&1 | Out-Null
        }
        exit 0
    }
    Invoke-RunStage
}
catch {
    Stop-WithFailure "Unexpected error: $($_.Exception.Message)"
}
