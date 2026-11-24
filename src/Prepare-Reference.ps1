<#
.SYNOPSIS
    Run inside the reference machine: checks it is ready for capture, then runs sysprep and shuts down.
.DESCRIPTION
    Catches the usual reasons sysprep fails or a golden image ends up tied to one machine:
    a pending reboot, BitLocker, Store apps installed for one user only, a missing Microsoft Store, and running
    on real hardware. Step by step guide: docs\REFERENCE-PC.md.

    Before sysprep it frees space so the captured image is smaller: Windows Update downloads, the Delivery
    Optimization cache, temp folders, the recycle bin, and old copies of updated Windows components (DISM component
    cleanup with /ResetBase, so updates already installed can no longer be uninstalled). -SkipCleanup skips that;
    -CleanupOnly frees the space and stops without sysprep (for a VM captured with sysprep at deploy); add -ShutDown
    to shut the VM down fully after.
.EXAMPLE
    \\deploy-server\Deploy\Tools\Prepare-Reference.ps1
.EXAMPLE
    .\Prepare-Reference.ps1 -CheckOnly
.EXAMPLE
    .\Prepare-Reference.ps1 -CleanupOnly
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,        # report problems and stop, without running sysprep
    [switch]$RemoveUserApps,   # remove Store apps that are installed for a user but not provisioned (they break sysprep); never the Store itself
    [string]$Unattend,         # optional answer file passed to sysprep /unattend
    [switch]$SkipRebootCheck,  # a pending restart is only a warning (sysprep at deploy restarts by itself first)
    [switch]$SkipCleanup,      # don't free space before sysprep
    [switch]$CleanupOnly,      # free space, then stop without sysprep (a VM captured with sysprep at deploy)
    [switch]$ShutDown          # with -CleanupOnly: then shut down fully (shutdown /s /t 0, not Fast Startup's hibernation)
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

function Get-CleanupFolders {
    # Returns the folders whose contents are deleted before capture: Windows Update downloads, the Delivery
    # Optimization cache and the temp folders (Windows and every user profile). Windows fills them again by itself.
    param([Parameter(Mandatory)][string]$WinDir, [Parameter(Mandatory)][string]$UsersDir)
    $list = @(
        [IO.Path]::Combine($WinDir, 'SoftwareDistribution', 'Download'),
        [IO.Path]::Combine($WinDir, 'ServiceProfiles', 'NetworkService', 'AppData', 'Local', 'Microsoft', 'Windows', 'DeliveryOptimization', 'Cache'),
        [IO.Path]::Combine($WinDir, 'Temp')
    )
    if ([IO.Directory]::Exists($UsersDir)) {
        foreach ($userDir in [IO.Directory]::GetDirectories($UsersDir)) {
            $list += [IO.Path]::Combine($userDir, 'AppData', 'Local', 'Temp')
        }
    }
    @($list | Where-Object { [IO.Directory]::Exists($_) })
}

function Clear-FolderContents {
    # Deletes what is in Folder, not the folder itself. Files in use stay. Paths in Keep (this script's folder, the
    # answer file) and the folders that hold them are never deleted. Returns how many items could not be deleted.
    param([Parameter(Mandatory)][string]$Folder, [string[]]$Keep = @())
    $keepFull = @($Keep | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    $left = 0
    try { $items = [IO.Directory]::GetFileSystemEntries($Folder) } catch { return 1 }
    foreach ($item in $items) {
        $full = [IO.Path]::GetFullPath($item).TrimEnd('\')
        if (@($keepFull | Where-Object { $_ -eq $full -or $_.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
        try { Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction Stop } catch { $left++ }
    }
    $left
}

function Invoke-ReferenceCleanup {
    # Frees space on the system drive before capture, so the image is smaller. Prints how much was freed.
    param([string[]]$Keep = @())
    $drive = [IO.DriveInfo]::new($env:SystemDrive)
    $freeBefore = $drive.AvailableFreeSpace
    Write-Host 'Freeing space before capture (update downloads, temp folders, recycle bin, old components).'
    # Windows Update and Delivery Optimization hold their downloads open while they run.
    $services = @(Get-Service -Name wuauserv, bits, dosvc -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')
    foreach ($svc in $services) { Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue }
    $left = 0
    foreach ($folder in Get-CleanupFolders -WinDir $env:WINDIR -UsersDir ([IO.Path]::Combine($env:SystemDrive + '\', 'Users'))) {
        $left += Clear-FolderContents -Folder $folder -Keep $Keep
    }
    foreach ($svc in $services) { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue }
    if ($left) { Write-Host "  $left file(s) in use were left." }
    try { Clear-RecycleBin -Force -ErrorAction Stop } catch { }
    # Old versions of updated Windows components. /ResetBase removes them for good: installed updates can no longer
    # be uninstalled, which a golden image doesn't need. It can take 10 to 30 minutes.
    Write-Host 'Removing old Windows component versions (DISM component cleanup, can take 10 to 30 minutes).'
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /English | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: DISM component cleanup ended with exit code $LASTEXITCODE; the image is still fine, only bigger." -ForegroundColor Yellow }
    $drive = [IO.DriveInfo]::new($env:SystemDrive)
    $freed = [Math]::Max(0, $drive.AvailableFreeSpace - $freeBefore)
    Write-Host ('Freed {0:N1} GB.' -f ($freed / 1GB)) -ForegroundColor Green
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
# Optional packages (Microsoft.OneDrive.Photos, added by Photos) are left out of Get-AppxPackage by default, but sysprep
# fails on them too (the 5521, 2026-11-23).
$installedApps = @(Get-AppxPackage -AllUsers -PackageTypeFilter Main, Framework, Optional)
$storeProblem = Get-StoreProblem -Installed $installedApps -Provisioned $provisioned
if ($storeProblem) { $problems.Add($storeProblem) }
$updated = @(Get-UpdatedInboxApps -Installed $installedApps -Provisioned $provisioned)
if ($updated) {
    $warnings.Add("The Store updated these Windows apps after Windows was installed: $(($updated.Name | Sort-Object -Unique) -join ', '). They are kept. If sysprep fails on one of them, revert the VM and keep the Store from updating apps before capture (docs\REFERENCE-PC.md); sysprep at deploy removes such an app for the user by itself.")
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
# -CleanupOnly is for a VM captured for sysprep at deploy: each PC runs the checks again (and remove apps
# installed for one user), so a problem here doesn't stop the clean-up.
if ($problems.Count -and $CleanupOnly) { Write-Host 'Each deployed PC runs these checks again before its sysprep; fix the problems above in the VM if you can.' -ForegroundColor Yellow }
elseif ($problems.Count) { Write-Host "`nFix the problems above, then run this again." -ForegroundColor Red; exit 1 }
else { Write-Host 'Reference machine is ready for capture.' -ForegroundColor Green }
if ($CheckOnly -and -not $CleanupOnly) { return }

if ($SkipCleanup -and -not $CleanupOnly) { Write-Host 'Skipping the clean-up before capture (-SkipCleanup).' }
else { Invoke-ReferenceCleanup -Keep @($PSScriptRoot, $Unattend) }
if ($CleanupOnly) {
    if ($ShutDown) { Write-Host 'Clean-up done. Shutting down; then capture the disk.' -ForegroundColor Green; & shutdown.exe /s /t 0; return }
    Write-Host 'Clean-up done. Shut the VM down (shutdown /s /t 0), then capture its disk.' -ForegroundColor Green; return
}

# Sysprep refuses to generalize while reserved storage is in use ("Audit mode cannot be turned on if reserved storage
# is in use", hr 0x800F0975). Turning it off only gives back the space Windows keeps for updates.
$reserve = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'
$rv = Get-ItemProperty -Path $reserve -ErrorAction SilentlyContinue
if ($rv -and (@('ActiveScenario', 'ShippedWithReserves') | Where-Object { $rv.PSObject.Properties[$_] -and [int]$rv.$_ -ne 0 })) {
    Write-Host 'Turning reserved storage off so sysprep can run.'
    foreach ($n in 'ActiveScenario', 'ShippedWithReserves') { Set-ItemProperty -Path $reserve -Name $n -Value 0 -Type DWord -ErrorAction SilentlyContinue }
    & dism.exe /Online /Set-ReservedStorageState /State:Disabled /English | Out-Null
}

$sysprepArgs = @('/generalize', '/oobe', '/shutdown')
if ($Unattend) { $sysprepArgs += "/unattend:$Unattend" }
Write-Host 'Running sysprep. The machine shuts down when it finishes; then capture its disk with the capture wizard in the console.'
& "$env:WINDIR\System32\Sysprep\sysprep.exe" @sysprepArgs
