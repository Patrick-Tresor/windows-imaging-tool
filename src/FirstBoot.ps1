<#
.SYNOPSIS
    Runs once on the deployed PC, as SYSTEM, from SetupComplete.cmd before anyone logs on.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\Deploy with firstboot.json and the answer file's applications.
    Installs the applications in order, applies options, runs FIRSTBOOT tasks, turns on BitLocker, then removes C:\Deploy.
#>
$ErrorActionPreference = 'Continue'
$log = "$env:WINDIR\Temp\FirstBoot.log"
function Write-Log([string]$Message) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) }

$deployDir = $PSScriptRoot
$plan = Get-Content -Raw (Join-Path $deployDir 'firstboot.json') | ConvertFrom-Json
Write-Log "First boot for answer file $($plan.answerFile)"

foreach ($app in $plan.applications) {
    $dir = Join-Path $deployDir "Apps\$($app.name)"
    Write-Log "Installing $($app.name): $($app.command)"
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $($app.command)" -WorkingDirectory $dir -Wait -PassThru -WindowStyle Hidden
    if ($app.successCodes -contains $p.ExitCode) { Write-Log "  $($app.name) OK (exit $($p.ExitCode))" }
    else { Write-Log "  $($app.name) FAILED (exit $($p.ExitCode))" }
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

foreach ($cmd in $plan.tasks) {
    Write-Log "FIRSTBOOT task: $cmd"
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $cmd" -Wait -PassThru -WindowStyle Hidden
    Write-Log "  exit $($p.ExitCode)"
}

if ($plan.bitlocker) {
    try { Enable-DeployBitLocker $plan.bitlocker }
    catch { Write-Log "BitLocker FAILED: $($_.Exception.Message)" }
}

# Setup already blanked the passwords in the cached unattend.xml; remove it and the installers anyway.
Remove-Item "$env:WINDIR\Panther\unattend.xml" -Force -ErrorAction SilentlyContinue
Write-Log 'First boot finished; removing C:\Deploy'
Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & rd /s /q `"$deployDir`"" -WindowStyle Hidden
