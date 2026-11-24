<#
.SYNOPSIS
    Runs once on the deployed PC, as SYSTEM, from SetupComplete.cmd before anyone logs on.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\Temp with firstboot.json and the answer file's applications.
    Installs the applications in order, applies options, runs FIRSTBOOT tasks, turns on BitLocker, runs the post-deploy checks
    (PostDeployChecks.psm1), then removes what it staged in C:\Temp. The checks and their state stay in C:\ProgramData\ImagingTool,
    where Test-Deployment.ps1 can run them again later.
    Each step is recorded in C:\Temp\firstboot-progress.json (FirstBootState.psm1). When the PC restarts in the middle
    (an installer or a task that restarts it), the startup task starts this again and it carries on after the last
    finished step; the step the restart cut short is not run again. It gives up after 5 starts.
    When firstboot.json has a status folder, reports progress to the console's dashboard from 90 to 100 %.
    That folder is a UNC path written as the computer account (SYSTEM), so the share must let Domain Computers
    write to it; if it cannot be reached the deployment still finishes and the dashboard shows it as Stalled.
#>
param(
    # Started by the ImagingTool\FirstBoot startup task (created in specialize), not by SetupComplete.cmd.
    [switch]$FromTask
)
$ErrorActionPreference = 'Continue'
$log = "$env:WINDIR\Temp\FirstBoot.log"
Import-Module (Join-Path $PSScriptRoot 'ScriptLog.psm1') -Force
function Write-Log([string]$Message) { Write-ScriptLog -Path $log -Message $Message }

$deployDir = $PSScriptRoot
# Two ways in: SetupComplete.cmd, or the startup task for when Windows skips SetupComplete.cmd (it does with an OEM
# product key, which Dell, HP and Lenovo PCs have in the firmware, on editions other than Enterprise).
# Only one run goes at a time (firstboot.lock); the other stops, so nothing installs twice. The task stays until first
# boot has finished, so a restart in the middle starts it again.
$taskName = 'ImagingTool\FirstBoot'
function Get-FirstBootCleanupCommand([string]$Dir, [switch]$KeepScript) {
    # -KeepScript: the startup task could not be deleted, so FirstBoot.ps1 (admins only) stays where the task points;
    # its next start sees first boot finished and tries again. Nobody else can then put a script there.
    # firstboot-progress.json stays as the record that first boot finished.
    $d = $Dir.TrimEnd('\')
    $folders = 'Apps', 'Tasks' | ForEach-Object { "rd /s /q `"$d\$_`"" }
    $names = @('DeployStatus.psm1', 'PostDeployChecks.psm1', 'Test-Deployment.ps1', 'AppPack.psm1', 'TaskPack.psm1', 'LibraryPack.psm1', 'ScriptLog.psm1', 'firstboot.json', 'deployed.json', 'firstboot.lock')
    if (-not $KeepScript) { $names = @('FirstBoot.ps1', 'FirstBootState.psm1') + $names }
    $files = $names | ForEach-Object { "del /f /q `"$d\$_`"" }
    (@($folders) + @($files)) -join ' & '
}
Import-Module ([IO.Path]::Combine($deployDir, 'FirstBootState.psm1')) -Force
$progressPath = [IO.Path]::Combine($deployDir, 'firstboot-progress.json')
if ($FromTask) {
    # Let Windows setup finish (SetupComplete.cmd, when it runs, runs before that and claims the run first).
    for ($i = 0; $i -lt 120; $i++) {
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
        if (-not $setup -or (-not $setup.SystemSetupInProgress -and -not $setup.OOBEInProgress)) { break }
        Start-Sleep -Seconds 30
    }
}
$who = if ($FromTask) { 'startup task' } else { 'SetupComplete.cmd' }
# Held until this process ends (a restart ends it too).
$script:FirstBootLock = Get-FirstBootLock -Path ([IO.Path]::Combine($deployDir, 'firstboot.lock'))
if (-not $script:FirstBootLock) { Write-Log "First boot is running already; this run ($who) stops"; exit 0 }
$progress = Read-FirstBootProgress -Path $progressPath
if ((Get-FirstBootStepState -Progress $progress -Step 'finished') -eq 'Done') {
    & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    Write-Log "First boot finished earlier; this run ($who) stops. Startup task $taskName removed: exit $LASTEXITCODE"
    exit 0
}
$progress.runs = [int]$progress.runs + 1
Save-FirstBootProgress -Progress $progress -Path $progressPath
$giveUp = -not (Test-FirstBootRunsLeft -Progress $progress)
if ($progress.runs -gt 1) {
    Write-Log "Started again by the $who after a restart (start $($progress.runs)); carrying on after the last finished step"
} else {
    Write-Log $(if ($FromTask) { 'Started by the startup task: Windows did not run SetupComplete.cmd (OEM product key?)' } else { 'Started by SetupComplete.cmd' })
}
if ($giveUp) { Write-Log "WARNING: the PC restarted during first boot $($progress.runs - 1) times; the steps left are skipped (see the lines above for the last one that ran)" }
function Save-Progress { try { Save-FirstBootProgress -Progress $progress -Path $progressPath } catch { Write-Log "Could not save first boot progress: $($_.Exception.Message)" } }
$plan = Get-Content -Raw (Join-Path $deployDir 'firstboot.json') | ConvertFrom-Json
Write-Log "First boot for answer file $($plan.answerFile)"
# A PC that ran sysprep at its first start (image captured without sysprep): its scripts are done. The answer file
# copy in there is normally gone already; the log stays in C:\Windows\Temp\SysprepAtDeploy.log.
Remove-Item 'C:\ProgramData\ImagingTool\Sysprep' -Recurse -Force -ErrorAction SilentlyContinue
# Setup ran, so sysprep did finish: a failure notice the first start left on the logon screen (it gave up waiting
# while sysprep was still busy) is wrong now. Only that notice, never one the organization set.
$noticeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if ((Get-ItemProperty -Path $noticeKey -Name legalnoticecaption -ErrorAction SilentlyContinue).legalnoticecaption -eq 'Deployment not finished: sysprep failed') {
    Set-ItemProperty -Path $noticeKey -Name legalnoticecaption -Value '' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $noticeKey -Name legalnoticetext -Value '' -ErrorAction SilentlyContinue
    Write-Log 'Removed the sysprep failure notice from the logon screen: sysprep finished after all.'
}
# Windows has started, so WinPE may wipe this disk again on a later Unattended deploy (see Find-UnstartedDeployment).
Remove-Item (Join-Path $deployDir 'deployed.json') -Force -ErrorAction SilentlyContinue

$reporting = $false
if ($plan.PSObject.Properties['status'] -and $plan.status.folder) {
    Import-Module (Join-Path $deployDir 'DeployStatus.psm1') -Force
    # The network can take a moment after setup; retry for about a minute before giving up on reporting.
    for ($i = 0; $i -lt 6 -and -not $reporting; $i++) {
        $reporting = Resume-DeployStatus -Folder $plan.status.folder -Id $plan.status.id -LogPath @("$env:WINDIR\Temp\Deploy.log", $log) 3>$null
        if (-not $reporting) { Start-Sleep -Seconds 10 }
    }
    Write-Log $(if ($reporting) { "Reporting status to $($plan.status.folder)" } else { "Status folder $($plan.status.folder) unreachable; not reporting" })
}
$script:nextStatusTry = (Get-Date).AddMinutes(2)
function Set-Progress([string]$Step, [int]$Percent, [string]$Warning) {
    # The status share was not reachable yet (network, domain join, or the computer account's rights still on their
    # way): try again every 2 minutes, so the dashboard picks the PC up instead of leaving it Stalled.
    if (-not $script:reporting -and $plan.PSObject.Properties['status'] -and $plan.status.folder -and (Get-Date) -ge $script:nextStatusTry) {
        $script:nextStatusTry = (Get-Date).AddMinutes(2)
        $script:reporting = Resume-DeployStatus -Folder $plan.status.folder -Id $plan.status.id -LogPath @("$env:WINDIR\Temp\Deploy.log", $log) 3>$null
        if ($script:reporting) { Write-Log "Reporting status to $($plan.status.folder)" }
    }
    if ($script:reporting) { Set-DeployStatus -Step $Step -Percent $Percent -Phase 'FirstBoot' -Warning $Warning -Fields @{ computerName = $env:COMPUTERNAME } }
}
Set-Progress 'First boot: starting' 91
# Each app is skipped when its detection rules find it already installed, and checked again after it runs.
# No sleep until first boot ends: a laptop left at the logon screen went to sleep in the middle of the Office install.
Import-Module (Join-Path $deployDir 'LibraryPack.psm1') -Force
Set-SystemAwake -Continuous
Import-Module (Join-Path $deployDir 'AppPack.psm1') -Force
$total = @($plan.applications).Count
$n = 0
# Results of earlier starts (before a restart) are kept.
$appResults = @($progress.appResults)

foreach ($plain in $plan.applications) {
    $app = ConvertTo-AppDefinition -Name $plain.name -Json $plain
    $dir = Join-Path $deployDir "Apps\$($app.name)"
    $n++
    $step = "app:$n"
    $state = Get-FirstBootStepState -Progress $progress -Step $step
    if ($state -eq 'Done' -or $giveUp) { continue }
    if ($state -eq 'Interrupted') {
        Write-Log "$($app.name): the PC restarted during its install; not run again"
        $r = try { Get-InterruptedAppResult -Detection (Test-AppDetection -Definition $app -AppFolder $dir) }
             catch { Get-InterruptedAppResult -Detection ([pscustomobject]@{ HasRules = $false; Detected = $false }) }
    } else {
        Start-FirstBootStep -Progress $progress -Step $step; Save-Progress
        Write-Log "Installing $($app.name)"
        Set-Progress "Installing $($app.name) ($n of $total)" (91 + [int](7 * ($n - 1) / [Math]::Max(1, $total)))
        $r = try { Invoke-AppInstall -Definition $app -AppFolder $dir -LogPath "$env:WINDIR\Temp\App-$($app.name).log" -Log { param($m) Write-Log $m } }
             catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; RebootNeeded = $false; Message = $_.Exception.Message } }
    }
    $ok = $r.Status -in 'Installed', 'AlreadyInstalled'
    Write-Log "  $($app.name) $(if ($ok) { 'OK' } else { 'FAILED' }) ($($r.Status)): $($r.Message)"
    # ok and exitCode are what the post-deploy checks read.
    $appResults += [pscustomobject]@{ name = $app.name; status = $r.Status; ok = $ok; exitCode = $r.ExitCode; rebootNeeded = $r.RebootNeeded; message = $r.Message }
    $progress.appResults = @($appResults)
    Complete-FirstBootStep -Progress $progress -Step $step; Save-Progress
    if (-not $ok) {
        Set-Progress "Installed $($app.name)" (91 + [int](7 * $n / [Math]::Max(1, $total))) "$($app.name) failed ($($r.Status))"
    }
}
# Kept after C:\Temp is cleared, for whoever checks the PC (and the deployment dashboard).
$appResults | ConvertTo-Json -Depth 3 | Set-Content "$env:WINDIR\Temp\FirstBoot-apps.json" -Encoding utf8

if (-not $giveUp -and (Get-FirstBootStepState -Progress $progress -Step 'options') -ne 'Done') {
    Start-FirstBootStep -Progress $progress -Step 'options'; Save-Progress
    if ($plan.enableAdministrator) {
        # By SID (RID 500): the account is "Administrateur" on French Windows, and net user Administrator failed there.
        $admin = Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object { $_.SID -like 'S-1-5-21-*-500' } | Select-Object -First 1
        if ($admin) {
            & net.exe user $admin.Name /active:yes | Out-Null
            Write-Log "Built-in Administrator ($($admin.Name)) enabled: exit $LASTEXITCODE"
        } else { Write-Log 'WARNING: built-in Administrator account not found; not enabled' }
    }
    Complete-FirstBootStep -Progress $progress -Step 'options'; Save-Progress
}

function Enable-DeployBitLocker($cfg) {
    # Recovery password first and backed up before anything is encrypted, then the TPM protector.
    $mount = $env:SystemDrive
    $vol = Get-BitLockerVolume -MountPoint $mount
    if ($vol.VolumeStatus -ne 'FullyDecrypted') { Write-Log "BitLocker: $mount is already $($vol.VolumeStatus); left as is"; return }
    $tpm = Get-Tpm
    if (-not $tpm.TpmPresent -or -not $tpm.TpmReady) {
        Write-Log "BitLocker NOT enabled: TPM present $($tpm.TpmPresent), ready $($tpm.TpmReady). Turn the TPM on (BIOS settings) and redeploy."
        return
    }
    $vol = Add-BitLockerKeyProtector -MountPoint $mount -RecoveryPasswordProtector -WarningAction SilentlyContinue
    $rp = $vol.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -Last 1
    $saved = @()
    if ($cfg.backupToAD) {
        # The network and domain controller may not be up yet this early; try for about a minute.
        for ($i = 1; $i -le 4 -and 'AD' -notin $saved; $i++) {
            try { Backup-BitLockerKeyProtector -MountPoint $mount -KeyProtectorId $rp.KeyProtectorId -ErrorAction Stop | Out-Null; $saved += 'AD' }
            catch { Write-Log "  AD backup attempt $i failed: $($_.Exception.Message)"; Start-Sleep -Seconds 15 }
        }
    }
    if ($cfg.recoveryKeyFolder) {
        # As SYSTEM the share sees the computer account, so Domain Computers need write access to the folder.
        $serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
        $file = Join-Path $cfg.recoveryKeyFolder ("{0}_{1}.txt" -f $env:COMPUTERNAME, $serial)
        try {
            @("Computer: $env:COMPUTERNAME", "Serial: $serial", "Date: $(Get-Date -Format s)",
              "Recovery key ID: $($rp.KeyProtectorId)", "Recovery password: $($rp.RecoveryPassword)") |
                Set-Content -Path $file -ErrorAction Stop
            $saved += 'folder'
        } catch { Write-Log "  Could not write the recovery key to $($cfg.recoveryKeyFolder): $($_.Exception.Message)" }
    }
    Write-Log "BitLocker recovery key $($rp.KeyProtectorId) saved to: $(if ($saved) { $saved -join ', ' } else { 'nowhere' })"
    if (-not $saved -and $cfg.requireBackup) {
        Remove-BitLockerKeyProtector -MountPoint $mount -KeyProtectorId $rp.KeyProtectorId | Out-Null
        Write-Log 'BitLocker NOT enabled: the recovery key could not be backed up (bitlocker/requireBackup).'
        return
    }

    Enable-BitLocker -MountPoint $mount -EncryptionMethod XtsAes256 -UsedSpaceOnly:([bool]$cfg.usedSpaceOnly) -SkipHardwareTest -TpmProtector | Out-Null
    Write-Log "BitLocker enabled on $mount (TPM, XtsAes256); encryption continues in the background"
}

# FIRSTBOOT tasks in the answer file's order, all through Invoke-TaskPack: library tasks (Tasks tab) from
# C:\Temp\Tasks\<name>, plain commands with cmd /c, each with its timeout and success codes (0 for a plain command).
# Each one logs to C:\Windows\Temp\Task-<name>.log, next to FirstBoot.log.
if (@($plan.tasks).Count -and -not $giveUp) { Set-Progress 'Running first boot tasks' 98 }
Import-Module (Join-Path $deployDir 'TaskPack.psm1') -Force
$taskResults = @($progress.taskResults)
$k = 0
foreach ($t in @($plan.tasks)) {
    $k++
    $step = "task:$k"
    $state = Get-FirstBootStepState -Progress $progress -Step $step
    if ($state -eq 'Done' -or $giveUp) { continue }
    if ($t -is [string]) { $t = [pscustomobject]@{ name = $t; command = $t; task = $null; arguments = '' } }
    # A plan from an older stick has no definition for a plain command.
    $def = if ($t.task) { ConvertTo-TaskDefinition -Name $t.name -Json $t.task } else { New-CommandTaskDefinition "$($t.command)" }
    $label = $def.name
    if ($state -eq 'Interrupted') {
        Write-Log "FIRSTBOOT task ${label}: the PC restarted while it ran; not run again"
        $r = Get-InterruptedTaskResult
        $taskResults += [pscustomobject]@{ name = $label; status = $r.Status; ok = $false; exitCode = $null; message = $r.Message }
    } else {
        Start-FirstBootStep -Progress $progress -Step $step; Save-Progress
        Write-Log "FIRSTBOOT task $label"
        Set-Progress "Running task $label" 98
        $folder = if ($def.type -ne 'command') { Join-Path $deployDir "Tasks\$label" }
        $r = try { Invoke-TaskPack -Definition $def -Folder $folder -ExtraArguments $t.arguments `
                       -LogPath "$env:WINDIR\Temp\$(Get-TaskLogName $label)" -Log { param($m) Write-Log $m } }
             catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; Message = $_.Exception.Message } }
        $ok = $r.Status -eq 'Succeeded'
        Write-Log "  $label $(if ($ok) { 'OK' } else { 'FAILED' }) ($($r.Status)): $($r.Message)"
        $taskResults += [pscustomobject]@{ name = $label; status = $r.Status; ok = $ok; exitCode = $r.ExitCode; message = $r.Message }
        if (-not $ok) { Set-Progress "Ran task $label" 98 "Task $label failed ($($r.Status))" }
    }
    $progress.taskResults = @($taskResults)
    Complete-FirstBootStep -Progress $progress -Step $step; Save-Progress
}
# Kept after C:\Temp is cleared, next to FirstBoot-apps.json.
if ($taskResults) { ConvertTo-Json -InputObject @($taskResults) -Depth 3 | Set-Content "$env:WINDIR\Temp\FirstBoot-tasks.json" -Encoding utf8 }

# Run again when a restart cut it short: it leaves a drive that is already encrypting as it is.
if ($plan.bitlocker -and -not $giveUp -and (Get-FirstBootStepState -Progress $progress -Step 'bitlocker') -ne 'Done') {
    Start-FirstBootStep -Progress $progress -Step 'bitlocker'; Save-Progress
    try { Enable-DeployBitLocker $plan.bitlocker }
    catch { Write-Log "BitLocker FAILED: $($_.Exception.Message)" }
    Complete-FirstBootStep -Progress $progress -Step 'bitlocker'; Save-Progress
}
if ($plan.bitlocker -and $giveUp -and (Get-FirstBootStepState -Progress $progress -Step 'bitlocker') -ne 'Done') { Write-Log 'BitLocker NOT enabled: first boot gave up after too many restarts' }

# Post-deploy checks. Their files move to C:\ProgramData\ImagingTool so Test-Deployment.ps1 can re-run them
# after C:\Temp is cleared, for example once a missing driver is added.
if ($plan.PSObject.Properties['checks'] -and $plan.checks) {
    Set-Progress 'Running post-deploy checks' 99
    try {
        $toolDir = "$env:ProgramData\ImagingTool"
        New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
        Copy-Item (Join-Path $deployDir 'PostDeployChecks.psm1'), (Join-Path $deployDir 'DeployStatus.psm1'), (Join-Path $deployDir 'Test-Deployment.ps1') $toolDir -Force
        [pscustomobject]@{
            checks     = $plan.checks
            status     = if ($plan.PSObject.Properties['status']) { $plan.status } else { $null }
            appResults = $appResults
            taskResults = @($taskResults)
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $toolDir 'checks.json') -Encoding utf8

        Import-Module (Join-Path $toolDir 'PostDeployChecks.psm1') -Force
        $run = Start-PostDeployCheck -Plan $plan.checks -AppResults $appResults -TaskResults $taskResults -ReportPath (Join-Path $toolDir 'last-check.json')
        foreach ($r in $run.Results) { Write-Log ("  check {0,-8} {1}: {2}" -f $r.result, $r.name, $r.detail) }
        Write-Log "Post-deploy checks: $($run.Summary.Text)"
        $script:nextStatusTry = Get-Date; Set-Progress 'Post-deploy checks done' 98   # one more try at the status share first
        if ($reporting) { Set-DeployCheckResult -Results $run.Results -Summary $run.Summary -Warning (ConvertTo-CheckWarning $run.Summary) }
    } catch { Write-Log "Post-deploy checks could not run: $($_.Exception.Message)" }
}

# C:\Windows\Panther\unattend.xml stays where it is: SetupComplete.cmd runs before the OOBE screens, and OOBE still
# reads the oobeSystem settings (account page, Administrator password) from it after this script ends. Deleting it
# here made OOBE ask for a local account on the Dell 5521. Windows Setup is not relied on to blank the passwords:
# a SYSTEM logon task runs Clear-UnattendPasswords.ps1 (staged by Deploy-Image.ps1), which waits until OOBE is over,
# removes every password value, then deletes itself and the task.
# A copy with every password value removed is also kept in C:\Windows\Temp\unattend-deployed.xml.
$clearScript = "$env:ProgramData\ImagingTool\Clear-UnattendPasswords.ps1"
if (Test-Path $clearScript) {
    & schtasks.exe /Create /F /TN 'ImagingTool\ClearUnattend' /SC ONLOGON /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$clearScript`"" 2>&1 | Out-Null
    Write-Log "Logon task ImagingTool\ClearUnattend (removes the passwords from unattend.xml after OOBE) created: exit $LASTEXITCODE"
    # Started by the startup task after OOBE: nobody may log on for a while, so clean now (the task stays if this fails).
    $setupNow = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
    if ($setupNow -and -not $setupNow.SystemSetupInProgress -and -not $setupNow.OOBEInProgress) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clearScript -LogPath $log
    }
} else { Write-Log "No ${clearScript}: the passwords in unattend.xml are left to Windows Setup" }
$unattend = "$env:WINDIR\Panther\unattend.xml"
if (Test-Path $unattend) {
    try {
        (Get-Content -Raw $unattend) -replace '(?s)(<(Value|Password)>).*?(</\2>)', '$1*removed*$3' |
            Set-Content "$env:WINDIR\Temp\unattend-deployed.xml" -Encoding utf8
        Write-Log 'Copy of unattend.xml without passwords kept in C:\Windows\Temp\unattend-deployed.xml'
    } catch { Write-Log "Could not keep a copy of unattend.xml: $($_.Exception.Message)" }
}
# First boot is over: the startup task is no longer needed.
& schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
$taskDeleted = $LASTEXITCODE -eq 0
if (-not $taskDeleted) { & schtasks.exe /Query /TN $taskName 2>&1 | Out-Null; $taskDeleted = $LASTEXITCODE -ne 0 }
Write-Log "Startup task $taskName removed: $taskDeleted"
Complete-FirstBootStep -Progress $progress -Step 'finished'; Save-Progress
# One clear result for this PC: ready or not, drivers, applications, tasks, join, BitLocker and total time.
# Kept in C:\Windows\Temp\DeployResult.txt next to FirstBoot.log; the Dashboard shows the same lines.
try {
    # Not -Force: importing it again would drop the status record that reporting to the dashboard uses.
    if (-not (Get-Command Get-DeployResultSummary -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $deployDir 'DeployStatus.psm1') }
    $deployInfo = if ($plan.PSObject.Properties['deploy'] -and $plan.deploy) { $plan.deploy } else { [pscustomobject]@{ answerFile = $plan.answerFile } }
    $deployInfo | Add-Member -NotePropertyName finished -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $deployInfo | Add-Member -NotePropertyName state -NotePropertyValue 'Succeeded' -Force
    if (-not $deployInfo.PSObject.Properties['computerName'] -or -not $deployInfo.computerName) { $deployInfo | Add-Member -NotePropertyName computerName -NotePropertyValue $env:COMPUTERNAME -Force }
    # Without post-deploy checks, the install and task results alone.
    $checkResults = if ((Get-Variable run -ErrorAction SilentlyContinue) -and $run) { @($run.Results) } else {
        @(@($appResults) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ name = "App: $($_.name)"; result = $(if ($_.ok) { 'Passed' } else { 'Failed' }); detail = "$($_.status): $($_.message)" } }) +
        @(@($taskResults) | Where-Object { $_ -and $_.status -ne 'Ran' } | ForEach-Object { [pscustomobject]@{ name = "Task: $($_.name)"; result = $(if ($_.ok) { 'Passed' } else { 'Failed' }); detail = "$($_.message)" } })
    }
    $summary = Get-DeployResultSummary -Deploy $deployInfo -Checks $checkResults
    Set-Content -Path "$env:WINDIR\Temp\DeployResult.txt" -Value $summary.Text -Encoding utf8
    Write-Log ('Deployment result:' + [Environment]::NewLine + $summary.Text)
} catch { Write-Log "Could not write the deployment result: $($_.Exception.Message)" }
Write-Log "First boot finished; removing what deploy staged in $deployDir"
if (-not $reporting) { $script:nextStatusTry = Get-Date; Set-Progress 'Finishing first boot' 99 }   # a last try at the status share
if ($reporting) { Set-DeployStatus -Step 'Deployment complete' -Percent 100 -State Succeeded -Fields @{ computerName = $env:COMPUTERNAME } }
# C:\Temp can hold other files (the golden image's, or an installer's), so only what Deploy-Image.ps1 staged goes.
# firstboot-progress.json stays: it says first boot finished, should the startup task still start this.
Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & $(Get-FirstBootCleanupCommand $deployDir -KeepScript:(-not $taskDeleted))" -WindowStyle Hidden
