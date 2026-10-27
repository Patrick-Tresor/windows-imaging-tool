<#
.SYNOPSIS
    Runs once on the deployed PC, as SYSTEM, from SetupComplete.cmd before anyone logs on.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\Deploy with firstboot.json and the answer file's applications.
    Installs the applications in order, applies options, restores the user data (LoadState), runs FIRSTBOOT tasks, turns on BitLocker, runs the post-deploy checks
    (PostDeployChecks.psm1), then removes C:\Deploy. The checks and their state stay in C:\ProgramData\ImagingTool,
    where Test-Deployment.ps1 can run them again later.
    When firstboot.json has a status folder, reports progress to the console's dashboard from 90 to 100 %.
    That folder is a UNC path written as the computer account (SYSTEM), so the share must let Domain Computers
    write to it; if it cannot be reached the deployment still finishes and the dashboard shows it as Stalled.
#>
$ErrorActionPreference = 'Continue'
$log = "$env:WINDIR\Temp\FirstBoot.log"
function Write-Log([string]$Message) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) }

$deployDir = $PSScriptRoot
$plan = Get-Content -Raw (Join-Path $deployDir 'firstboot.json') | ConvertFrom-Json
Write-Log "First boot for answer file $($plan.answerFile)"

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
$total = @($plan.applications).Count
$n = 0
$appResults = @()

foreach ($app in $plan.applications) {
    $dir = Join-Path $deployDir "Apps\$($app.name)"
    $n++
    Write-Log "Installing $($app.name): $($app.command)"
    Set-Progress "Installing $($app.name) ($n of $total)" (91 + [int](7 * ($n - 1) / [Math]::Max(1, $total)))
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $($app.command)" -WorkingDirectory $dir -Wait -PassThru -WindowStyle Hidden
    $appResults += [pscustomobject]@{ name = $app.name; exitCode = $p.ExitCode; ok = $app.successCodes -contains $p.ExitCode }
    if ($app.successCodes -contains $p.ExitCode) { Write-Log "  $($app.name) OK (exit $($p.ExitCode))" }
    else {
        Write-Log "  $($app.name) FAILED (exit $($p.ExitCode))"
        Set-Progress "Installed $($app.name)" (91 + [int](7 * $n / [Math]::Max(1, $total))) "$($app.name) failed (exit $($p.ExitCode))"
    }
}

if ($plan.disableSystemRestore) {
    Disable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-Log 'System Restore disabled'
}
if ($plan.enableAdministrator) {
    & net.exe user Administrator /active:yes | Out-Null
    Write-Log 'Built-in Administrator enabled'
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

# User data after the applications, so their settings land on installed applications.
if ($plan.userState) {
    $us = $plan.userState
    Write-Log "Restoring user data from $($us.store)"
    $loadArgs = @($us.arguments)
    & $us.loadState @loadArgs | Out-Null
    $code = $LASTEXITCODE
    if ($code -in 0, 3) {
        Write-Log "  user data restored (exit $code$(if ($code -eq 3) { ', some files skipped: see C:\Windows\Temp\LoadState.log' }))"
        if (-not $us.keepStore) {
            # Deleting a hard-link store only removes its links; the restored files stay in the profiles.
            & cmd.exe /c "rd /s /q `"$($us.store)`"" 2>&1 | Out-Null
            if (Test-Path $us.store) { Write-Log "  couldn't remove all of $($us.store); delete it by hand" }
        }
    } else {
        Write-Log "  user data restore FAILED (exit $code); the store is kept in $($us.store). See C:\Windows\Temp\LoadState.log"
    }
}

if (@($plan.tasks).Count) { Set-Progress 'Running first boot tasks' 98 }
foreach ($cmd in $plan.tasks) {
    Write-Log "FIRSTBOOT task: $cmd"
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $cmd" -Wait -PassThru -WindowStyle Hidden
    Write-Log "  exit $($p.ExitCode)"
}

if ($plan.bitlocker) {
    try { Enable-DeployBitLocker $plan.bitlocker }
    catch { Write-Log "BitLocker FAILED: $($_.Exception.Message)" }
}

# Post-deploy checks. Their files move to C:\ProgramData\ImagingTool so Test-Deployment.ps1 can re-run them
# after C:\Deploy is gone, for example once a missing driver is added.
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
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $toolDir 'checks.json') -Encoding utf8

        Import-Module (Join-Path $toolDir 'PostDeployChecks.psm1') -Force
        $run = Start-PostDeployCheck -Plan $plan.checks -AppResults $appResults -ReportPath (Join-Path $toolDir 'last-check.json')
        foreach ($r in $run.Results) { Write-Log ("  check {0,-8} {1}: {2}" -f $r.result, $r.name, $r.detail) }
        Write-Log "Post-deploy checks: $($run.Summary.Text)"
        if ($reporting) { Set-DeployCheckResult -Results $run.Results -Summary $run.Summary -Warning (ConvertTo-CheckWarning $run.Summary) }
    } catch { Write-Log "Post-deploy checks could not run: $($_.Exception.Message)" }
}

# Setup already blanked the passwords in the cached unattend.xml; remove it and the installers anyway.
Remove-Item "$env:WINDIR\Panther\unattend.xml" -Force -ErrorAction SilentlyContinue
Write-Log 'First boot finished; removing C:\Deploy'
if ($reporting) { Set-DeployStatus -Step 'Deployment complete' -Percent 100 -State Succeeded -Fields @{ computerName = $env:COMPUTERNAME } }
Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & rd /s /q `"$deployDir`"" -WindowStyle Hidden
