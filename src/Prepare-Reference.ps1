<#
.SYNOPSIS
    Run inside the reference machine: checks it is ready for capture, then runs sysprep and shuts down.
.DESCRIPTION
    Catches the usual reasons sysprep fails or a golden image ends up tied to one machine:
    a pending reboot, BitLocker, Store apps installed for one user only, and running on real hardware.
.EXAMPLE
    \\deploy-server\Deploy\Tools\Prepare-Reference.ps1
.EXAMPLE
    .\Prepare-Reference.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,        # report problems and stop, without running sysprep
    [switch]$RemoveUserApps,   # remove Store apps that are installed for a user but not provisioned (they break sysprep)
    [string]$Unattend          # optional answer file passed to sysprep /unattend
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell window.' }

$problems = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()

# Real hardware leaves its own drivers in the image. It still works, but a VM gives a cleaner image.
$model = (Get-CimInstance Win32_ComputerSystem).Model
if ($model -notmatch 'Virtual Machine|VMware|VirtualBox|KVM|QEMU') {
    $warnings.Add("This looks like physical hardware ($model). A Hyper-V VM makes a cleaner hardware-independent image.")
}

$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
if ($rebootKeys | Where-Object { Test-Path $_ }) { $problems.Add('A reboot is pending (Windows Update or servicing). Reboot, then run this again.') }

try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($bl.VolumeStatus -ne 'FullyDecrypted') {
        $problems.Add("BitLocker is $($bl.VolumeStatus) on $env:SystemDrive. Run 'manage-bde -off $env:SystemDrive' and wait for decryption to finish.")
    }
} catch { }  # BitLocker cmdlets are missing on some editions; nothing to check then

# Sysprep fails with 0x80073cf2 when a Store app is installed for a user but not provisioned for all users.
$provisioned = @(Get-AppxProvisionedPackage -Online | ForEach-Object { $_.PackageName })
$userOnly = @(Get-AppxPackage -AllUsers | Where-Object {
    -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -eq 'Store' -and
    $provisioned -notcontains $_.PackageFullName
})
if ($userOnly) {
    if ($RemoveUserApps) {
        foreach ($app in $userOnly) {
            Write-Host "Removing $($app.Name) (installed for one user only)"
            Remove-AppxPackage -Package $app.PackageFullName -AllUsers
        }
    } else {
        $problems.Add("These Store apps are installed for a user but not provisioned, and will make sysprep fail: $(($userOnly.Name | Sort-Object -Unique) -join ', '). Run again with -RemoveUserApps.")
    }
}

if (Test-Path "$env:WINDIR\System32\Sysprep\Panther\setuperr.log") {
    $warnings.Add("An earlier sysprep left errors in $env:WINDIR\System32\Sysprep\Panther\setuperr.log.")
}

foreach ($w in $warnings) { Write-Host "WARNING: $w" -ForegroundColor Yellow }
foreach ($p in $problems) { Write-Host "PROBLEM: $p" -ForegroundColor Red }
if ($problems.Count) { Write-Host "`nFix the problems above, then run this again." -ForegroundColor Red; exit 1 }
Write-Host 'Reference machine is ready for capture.' -ForegroundColor Green
if ($CheckOnly) { return }

$sysprepArgs = @('/generalize', '/oobe', '/shutdown')
if ($Unattend) { $sysprepArgs += "/unattend:$Unattend" }
Write-Host 'Running sysprep. The machine shuts down when it finishes; then boot it from the capture media.'
& "$env:WINDIR\System32\Sysprep\sysprep.exe" @sysprepArgs
