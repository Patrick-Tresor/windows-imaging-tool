<#
.SYNOPSIS
    Runs once on the deployed PC, as SYSTEM, from SetupComplete.cmd before anyone logs on.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\Temp with firstboot.json and the answer file's applications.
    Installs the applications in order, applies options, runs FIRSTBOOT tasks, turns on BitLocker, runs the post-deploy checks
    (PostDeployChecks.psm1), then removes what it staged in C:\Temp. The checks and their state stay in C:\ProgramData\ImagingTool,
    where Test-Deployment.ps1 can run them again later.
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
function Write-Log([string]$Message) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) }

$deployDir = $PSScriptRoot
# Two ways in: SetupComplete.cmd, or the startup task for when Windows skips SetupComplete.cmd (it does with an OEM
# product key, which Dell, HP and Lenovo PCs have in the firmware, on editions other than Enterprise).
# Whichever comes second finds firstboot.started and stops, so nothing installs twice.
$taskName = 'ImagingTool\FirstBoot'
function Get-FirstBootCleanupCommand([string]$Dir) {
    $d = $Dir.TrimEnd('\')
    $folders = 'Apps', 'Tasks' | ForEach-Object { "rd /s /q `"$d\$_`"" }
    $files = 'FirstBoot.ps1', 'DeployStatus.psm1', 'PostDeployChecks.psm1', 'Test-Deployment.ps1', 'AppPack.psm1', 'TaskPack.psm1', 'firstboot.json', 'deployed.json' |
        ForEach-Object { "del /f /q `"$d\$_`"" }
    (@($folders) + @($files)) -join ' & '
}
if ($FromTask) {
    # Let Windows setup finish (SetupComplete.cmd, when it runs, runs before that and claims the run first).
    for ($i = 0; $i -lt 120; $i++) {
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
        if (-not $setup -or (-not $setup.SystemSetupInProgress -and -not $setup.OOBEInProgress)) { break }
        Start-Sleep -Seconds 30
    }
}
try {
    $claim = [IO.File]::Open([IO.Path]::Combine($deployDir, 'firstboot.started'), [IO.FileMode]::CreateNew)
    $claim.Close()
} catch {
    Write-Log "First boot already started earlier; this run ($(if ($FromTask) { 'startup task' } else { 'SetupComplete.cmd' })) stops"
    if ($FromTask) { & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null }
    exit 0
}
Write-Log $(if ($FromTask) { 'Started by the startup task: Windows did not run SetupComplete.cmd (OEM product key?)' } else { 'Started by SetupComplete.cmd' })
# One run is enough: the task would otherwise start this again at every boot.
& schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
Write-Log "Startup task $taskName removed: exit $LASTEXITCODE"
$plan = Get-Content -Raw (Join-Path $deployDir 'firstboot.json') | ConvertFrom-Json
Write-Log "First boot for answer file $($plan.answerFile)"
# A PC that ran sysprep at its first start (image captured without sysprep): its scripts are done. The answer file
# copy in there is normally gone already; the log stays in C:\Windows\Temp\SysprepAtDeploy.log.
Remove-Item 'C:\ProgramData\ImagingTool\Sysprep' -Recurse -Force -ErrorAction SilentlyContinue
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
function Set-Progress([string]$Step, [int]$Percent, [string]$Warning) {
    if ($reporting) { Set-DeployStatus -Step $Step -Percent $Percent -Phase 'FirstBoot' -Warning $Warning -Fields @{ computerName = $env:COMPUTERNAME } }
}
Set-Progress 'First boot: starting' 91
# Each app is skipped when its detection rules find it already installed, and checked again after it runs.
Import-Module (Join-Path $deployDir 'AppPack.psm1') -Force
$total = @($plan.applications).Count
$n = 0
$appResults = @()

foreach ($plain in $plan.applications) {
    $app = ConvertTo-AppDefinition -Name $plain.name -Json $plain
    $dir = Join-Path $deployDir "Apps\$($app.name)"
    $n++
    Write-Log "Installing $($app.name)"
    Set-Progress "Installing $($app.name) ($n of $total)" (91 + [int](7 * ($n - 1) / [Math]::Max(1, $total)))
    $r = try { Invoke-AppInstall -Definition $app -AppFolder $dir -Log { param($m) Write-Log $m } }
         catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; RebootNeeded = $false; Message = $_.Exception.Message } }
    $ok = $r.Status -in 'Installed', 'AlreadyInstalled'
    Write-Log "  $($app.name) $(if ($ok) { 'OK' } else { 'FAILED' }) ($($r.Status)): $($r.Message)"
    # ok and exitCode are what the post-deploy checks read.
    $appResults += [pscustomobject]@{ name = $app.name; status = $r.Status; ok = $ok; exitCode = $r.ExitCode; rebootNeeded = $r.RebootNeeded; message = $r.Message }
    if (-not $ok) {
        Set-Progress "Installed $($app.name)" (91 + [int](7 * $n / [Math]::Max(1, $total))) "$($app.name) failed ($($r.Status))"
    }
}
# Kept after C:\Temp is cleared, for whoever checks the PC (and the deployment dashboard).
$appResults | ConvertTo-Json -Depth 3 | Set-Content "$env:WINDIR\Temp\FirstBoot-apps.json" -Encoding utf8

if ($plan.disableSystemRestore) {
    Disable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-Log 'System Restore disabled'
}
if ($plan.enableAdministrator) {
    # By SID (RID 500): the account is "Administrateur" on French Windows, and net user Administrator failed there.
    $admin = Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object { $_.SID -like 'S-1-5-21-*-500' } | Select-Object -First 1
    if ($admin) {
        & net.exe user $admin.Name /active:yes | Out-Null
        Write-Log "Built-in Administrator ($($admin.Name)) enabled: exit $LASTEXITCODE"
    } else { Write-Log 'WARNING: built-in Administrator account not found; not enabled' }
}

function Enable-DeployBitLocker($cfg) {
    # Recovery password first and backed up before anything is encrypted, then the TPM (or TPM + PIN) protector.
    $mount = $env:SystemDrive
    $vol = Get-BitLockerVolume -MountPoint $mount
    if ($vol.VolumeStatus -ne 'FullyDecrypted') { Write-Log "BitLocker: $mount is already $($vol.VolumeStatus); left as is"; return }
    $tpm = Get-Tpm
    if (-not $tpm.TpmPresent -or -not $tpm.TpmReady) {
        Write-Log "BitLocker NOT enabled: TPM present $($tpm.TpmPresent), ready $($tpm.TpmReady). Turn the TPM on (BIOS settings) and redeploy."
        return
    }
    if ($cfg.protector -eq 'TpmPin') {
        # Same as the "Require additional authentication at startup" policy with a TPM startup PIN allowed.
        $fve = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
        New-Item -Path $fve -Force | Out-Null
        foreach ($v in @(('UseAdvancedStartup', 1), ('EnableBDEWithNoTPM', 0), ('UseTPM', 2), ('UseTPMPIN', 2), ('UseTPMKey', 2), ('UseTPMKeyPIN', 2))) {
            Set-ItemProperty -Path $fve -Name $v[0] -Value $v[1] -Type DWord
        }
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

    $enable = @{ MountPoint = $mount; EncryptionMethod = $cfg.encryptionMethod; UsedSpaceOnly = [bool]$cfg.usedSpaceOnly; SkipHardwareTest = $true }
    if ($cfg.protector -eq 'TpmPin') {
        Enable-BitLocker @enable -TpmAndPinProtector -Pin (ConvertTo-SecureString $cfg.pin -AsPlainText -Force) | Out-Null
    } else {
        Enable-BitLocker @enable -TpmProtector | Out-Null
    }
    Write-Log "BitLocker enabled on $mount ($($cfg.protector), $($cfg.encryptionMethod)); encryption continues in the background"
}

# FIRSTBOOT tasks in the answer file's order: plain commands with cmd /c, library tasks (Tasks tab) from
# C:\Temp\Tasks\<name> with their timeout and success codes. Each library task logs to C:\Windows\Temp\Task-<name>.log, next to FirstBoot.log.
if (@($plan.tasks).Count) { Set-Progress 'Running first boot tasks' 98 }
Import-Module (Join-Path $deployDir 'TaskPack.psm1') -Force
$taskResults = @()
foreach ($t in @($plan.tasks)) {
    if ($t -is [string]) { $t = [pscustomobject]@{ name = $t; command = $t; task = $null; arguments = '' } }
    if (-not $t.task) {
        Write-Log "FIRSTBOOT task: $($t.command)"
        $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $($t.command)" -Wait -PassThru -WindowStyle Hidden
        Write-Log "  exit $($p.ExitCode)"
        $taskResults += [pscustomobject]@{ name = $t.command; status = 'Ran'; ok = $true; exitCode = $p.ExitCode; message = "exit $($p.ExitCode)" }
        continue
    }
    $def = ConvertTo-TaskDefinition -Name $t.name -Json $t.task
    Write-Log "FIRSTBOOT task $($def.name)"
    Set-Progress "Running task $($def.name)" 98
    $r = try { Invoke-TaskPack -Definition $def -Folder (Join-Path $deployDir "Tasks\$($def.name)") -ExtraArguments $t.arguments `
                   -LogPath "$env:WINDIR\Temp\Task-$($def.name).log" -Log { param($m) Write-Log $m } }
         catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; Message = $_.Exception.Message } }
    $ok = $r.Status -eq 'Succeeded'
    Write-Log "  $($def.name) $(if ($ok) { 'OK' } else { 'FAILED' }) ($($r.Status)): $($r.Message)"
    $taskResults += [pscustomobject]@{ name = $def.name; status = $r.Status; ok = $ok; exitCode = $r.ExitCode; message = $r.Message }
    if (-not $ok) { Set-Progress "Ran task $($def.name)" 98 "Task $($def.name) failed ($($r.Status))" }
}
# Kept after C:\Temp is cleared, next to FirstBoot-apps.json.
if ($taskResults) { ConvertTo-Json -InputObject @($taskResults) -Depth 3 | Set-Content "$env:WINDIR\Temp\FirstBoot-tasks.json" -Encoding utf8 }

if ($plan.bitlocker) {
    try { Enable-DeployBitLocker $plan.bitlocker }
    catch { Write-Log "BitLocker FAILED: $($_.Exception.Message)" }
}

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
        if ($reporting) { Set-DeployCheckResult -Results $run.Results -Summary $run.Summary -Warning (ConvertTo-CheckWarning $run.Summary) }
    } catch { Write-Log "Post-deploy checks could not run: $($_.Exception.Message)" }
}

# C:\Windows\Panther\unattend.xml stays where it is: SetupComplete.cmd runs before the OOBE screens, and OOBE still
# reads the oobeSystem settings (account page, Administrator password) from it after this script ends. Deleting it
# here made OOBE ask for a local account on the Dell 5521. Setup blanks the passwords in it after use.
# A copy with every password value removed is also kept in C:\Windows\Temp\unattend-deployed.xml.
$unattend = "$env:WINDIR\Panther\unattend.xml"
if (Test-Path $unattend) {
    try {
        (Get-Content -Raw $unattend) -replace '(?s)(<(Value|Password)>).*?(</\2>)', '$1*removed*$3' |
            Set-Content "$env:WINDIR\Temp\unattend-deployed.xml" -Encoding utf8
        Write-Log 'Copy of unattend.xml without passwords kept in C:\Windows\Temp\unattend-deployed.xml'
    } catch { Write-Log "Could not keep a copy of unattend.xml: $($_.Exception.Message)" }
}
Write-Log "First boot finished; removing what deploy staged in $deployDir"
if ($reporting) { Set-DeployStatus -Step 'Deployment complete' -Percent 100 -State Succeeded -Fields @{ computerName = $env:COMPUTERNAME } }
# C:\Temp can hold other files (the golden image's, or an installer's), so only what Deploy-Image.ps1 staged goes.
# firstboot.started stays: it keeps the startup task, if it is still there, from running first boot again.
Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & $(Get-FirstBootCleanupCommand $deployDir)" -WindowStyle Hidden
