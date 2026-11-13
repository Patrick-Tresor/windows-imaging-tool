<#
.SYNOPSIS
    Run inside the reference machine: checks it is ready for capture, then runs sysprep and shuts down.
.DESCRIPTION
    Catches the usual reasons sysprep fails or a golden image ends up tied to one machine:
    a pending reboot, BitLocker, Store apps installed for one user only, a missing Microsoft Store, and running
    on real hardware. Step by step guide: docs\REFERENCE-PC.md.
.EXAMPLE
    \\deploy-server\Deploy\Tools\Prepare-Reference.ps1
.EXAMPLE
    .\Prepare-Reference.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,        # report problems and stop, without running sysprep
    [switch]$RemoveUserApps,   # remove Store apps that are installed for a user but not provisioned (they break sysprep); never the Store itself
    [string]$Unattend,         # optional answer file passed to sysprep /unattend
    [switch]$SkipRebootCheck   # a pending restart is only a warning (sysprep at deploy restarts by itself first)
)

$ErrorActionPreference = 'Stop'

function Get-UserOnlyApps {
    # Returns the Store apps installed for a user but not provisioned, the ones that make sysprep fail.
    # The Store itself and the packages it needs are never returned, even after the Store has updated them for a
    # user: removing them with -AllUsers left a deployed image with no Microsoft Store and no way to open it.
    param([object[]]$Installed, [object[]]$Provisioned)
    $keep = 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller',
            'Microsoft.Services.Store.Engagement', 'Microsoft.SecHealthUI', 'Microsoft.WindowsAppRuntime*', 'Microsoft.UI.Xaml*',
            'Microsoft.VCLibs*', 'Microsoft.NET.Native*'
    # An app provisioned at any version is part of Windows (Notepad, Photos, Terminal...) that the Store updated
    # for a user. Removing it with -AllUsers took it out of the image too, so it is never returned either.
    $provFull = @($Provisioned | ForEach-Object { "$($_.PackageName)" })
    $provNames = @($Provisioned | ForEach-Object { "$($_.DisplayName)" })
    @($Installed | Where-Object {
        $name = "$($_.Name)"
        -not $_.IsFramework -and -not $_.NonRemovable -and "$($_.SignatureKind)" -eq 'Store' -and
        $provFull -notcontains $_.PackageFullName -and $provNames -notcontains $name -and
        -not @($keep | Where-Object { $name -like $_ }).Count
    })
}

function Get-UpdatedInboxApps {
    # Returns the apps provisioned in Windows that the Store has since updated for a user (a newer version that is
    # not provisioned). They are left alone; sysprep can still fail on one of them.
    param([object[]]$Installed, [object[]]$Provisioned)
    $provFull = @($Provisioned | ForEach-Object { "$($_.PackageName)" })
    $provNames = @($Provisioned | ForEach-Object { "$($_.DisplayName)" })
    @($Installed | Where-Object {
        -not $_.IsFramework -and -not $_.NonRemovable -and "$($_.SignatureKind)" -eq 'Store' -and
        $provNames -contains "$($_.Name)" -and $provFull -notcontains $_.PackageFullName
    })
}

function Get-StoreProblem {
    # Returns why deployed PCs would have no Microsoft Store, or nothing when the Store is provisioned.
    param([object[]]$Installed, [object[]]$Provisioned)
    if (@($Provisioned | Where-Object { "$($_.DisplayName)" -eq 'Microsoft.WindowsStore' }).Count) { return }
    $why = if (@($Installed | Where-Object { "$($_.Name)" -eq 'Microsoft.WindowsStore' }).Count) {
        'It is installed for a user (wsreset -i does that) but not provisioned, so sysprep would fail on it and new users would not get it.'
    } else { 'It is not installed or provisioned.' }
    "The Microsoft Store is missing from this Windows, so every PC deployed from it would have no Store. $why " +
    'Revert the VM to a snapshot taken before Prepare-Reference -RemoveUserApps first ran, or install Windows fresh in the VM.'
}

function Get-SysprepErrors {
    # Returns the sysprep error lines in setuperr.log under $LogDir, from the latest sysprep run at or after $Since.
    # Windows upgrades write setuperr.log in the same folder (MOUPG, CONX, BFSVC lines); those say nothing about
    # sysprep, so only SYSPRP lines and sysprep failures count. setupact.log marks where each sysprep run begins.
    param([Parameter(Mandatory)][string]$LogDir, [datetime]$Since = [datetime]::MinValue)
    $errLog = Join-Path $LogDir 'setuperr.log'
    if (-not (Test-Path -LiteralPath $errLog)) { return }
    if ((Get-Item -LiteralPath $errLog).LastWriteTime -lt $Since) { return }
    $stamp = '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $actLog = Join-Path $LogDir 'setupact.log'
    if (Test-Path -LiteralPath $actLog) {
        foreach ($m in Select-String -LiteralPath $actLog -Pattern 'Beginning of a new sysprep run') {
            if ($m.Line -match $stamp) {
                $start = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $culture)
                if ($start -gt $Since) { $Since = $start }
            }
        }
    }
    $time = $null
    foreach ($line in Get-Content -LiteralPath $errLog) {
        # Lines without a time (continuations) belong to the line above.
        if ($line -match $stamp) { $time = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $culture) }
        if ($line -notmatch '\bSYSPRP\b|sysprep(\.exe)?\b.*\bfail') { continue }
        if ($time -and $time -lt $Since) { continue }
        $line.Trim()
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell window.' }

$problems = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()

# Real hardware leaves its own drivers in the image. It still works, but a VM gives a cleaner image.
$model = (Get-CimInstance Win32_ComputerSystem).Model
if ($model -notmatch 'Virtual Machine|VMware|VirtualBox|KVM|QEMU') {
    $warnings.Add("This looks like physical hardware ($model). A VM makes a cleaner hardware-independent image.")
}

$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
if ($rebootKeys | Where-Object { Test-Path $_ }) {
    if ($SkipRebootCheck) { $warnings.Add('Windows says a restart is pending (Windows Update or servicing).') }
    else { $problems.Add('A reboot is pending (Windows Update or servicing). Reboot, then run this again.') }
}

try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($bl.VolumeStatus -ne 'FullyDecrypted') {
        $problems.Add("BitLocker is $($bl.VolumeStatus) on $env:SystemDrive. Run 'manage-bde -off $env:SystemDrive' and wait for decryption to finish.")
    }
} catch { }  # BitLocker cmdlets are missing on some editions; nothing to check then

# Sysprep fails with 0x80073cf2 when a Store app is installed for a user but not provisioned for all users.
$provisioned = @(Get-AppxProvisionedPackage -Online)
$installedApps = @(Get-AppxPackage -AllUsers)
$storeProblem = Get-StoreProblem -Installed $installedApps -Provisioned $provisioned
if ($storeProblem) { $problems.Add($storeProblem) }
$updated = @(Get-UpdatedInboxApps -Installed $installedApps -Provisioned $provisioned)
if ($updated) {
    $warnings.Add("The Store updated these Windows apps after Windows was installed: $(($updated.Name | Sort-Object -Unique) -join ', '). They are kept. If sysprep fails on one of them, revert the VM and keep the Store from updating apps before capture (docs\REFERENCE-PC.md).")
}
# A Store policy set while building the reference would be captured and apply to every deployed PC.
$storePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
foreach ($value in 'AutoDownload', 'RemoveWindowsStore', 'DisableStoreApps') {
    $set = (Get-ItemProperty -Path $storePolicy -Name $value -ErrorAction SilentlyContinue).$value
    if ($null -ne $set) { $warnings.Add("The Store policy $value=$set is set in $storePolicy and will be in the image. Delete it before capture unless deployed PCs should have it.") }
}
$userOnly = @(Get-UserOnlyApps -Installed $installedApps -Provisioned $provisioned)
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

# Only a sysprep failure since the last boot counts; an older or unrelated setuperr.log (a Windows upgrade writes one
# in the same folder) is no reason to worry.
$panther = "$env:WINDIR\System32\Sysprep\Panther"
$lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$sysprepErrors = @(Get-SysprepErrors -LogDir $panther -Since $lastBoot)
if ($sysprepErrors) {
    $warnings.Add("The last sysprep run failed ($($sysprepErrors.Count) error line(s) in $panther\setuperr.log). First: $($sysprepErrors[0])")
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
