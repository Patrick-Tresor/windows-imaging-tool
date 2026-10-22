<#
.SYNOPSIS
    Builds the WinPE boot image with the deploy tool inside, then a USB stick, an ISO, or a boot.wim for PXE.
.DESCRIPTION
    Run as admin on a workstation with the Windows ADK and the WinPE add-on installed.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Pxe -OutputPath C:\WDS\Boot
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Usb', 'Iso', 'Pxe')][string]$Target,
    [string]$WorkDir = 'C:\WinPE_Build',
    [int]$UsbDiskNumber = -1,
    [string]$ContentSource,          # Images, Drivers, config to copy to the USB's DEPLOY partition
    [string]$OutputPath = (Get-Location).Path,
    [string]$WinPEDrivers,           # optional NIC/storage drivers WinPE itself needs on newer hardware
    [string]$SettingsPath,           # deploy-settings.json to bake in; defaults to the repo copy
    [switch]$Force                   # skip the USB erase prompt (the console confirms before calling)
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $SettingsPath) { $SettingsPath = "$repo\config\deploy-settings.json" }

$adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$peRoot = "$adk\Windows Preinstallation Environment"
if (-not (Test-Path $peRoot)) { throw 'Windows ADK WinPE add-on not found. Install the ADK and the WinPE add-on first.' }

# copype and MakeWinPEMedia expect the ADK environment variables that DandISetEnv.bat sets.
$envBat = "$adk\Deployment Tools\DandISetEnv.bat"
cmd /c "`"$envBat`" && set" | ForEach-Object { if ($_ -match '^(.*?)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } }

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
& cmd /c "copype amd64 `"$WorkDir`""
if ($LASTEXITCODE -ne 0) { throw 'copype failed' }

$mount = Join-Path $WorkDir 'mount'
$bootWim = Join-Path $WorkDir 'media\sources\boot.wim'
Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $mount | Out-Null
try {
    # PowerShell, WMI, and storage cmdlets inside WinPE. Order matters: dependencies first.
    $ocs = "$peRoot\amd64\WinPE_OCs"
    foreach ($oc in 'WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell',
                    'WinPE-StorageWMI', 'WinPE-DismCmdlets', 'WinPE-SecureStartup') {
        Add-WindowsPackage -Path $mount -PackagePath "$ocs\$oc.cab" | Out-Null
        $lang = "$ocs\en-us\$($oc)_en-us.cab"
        if (Test-Path $lang) { Add-WindowsPackage -Path $mount -PackagePath $lang | Out-Null }
    }
    if ($WinPEDrivers) { Add-WindowsDriver -Path $mount -Driver $WinPEDrivers -Recurse | Out-Null }

    $deployDir = Join-Path $mount 'Deploy'
    New-Item -ItemType Directory -Path "$deployDir\config" -Force | Out-Null
    Copy-Item "$repo\src\*.ps1", "$repo\src\*.psm1" $deployDir
    Copy-Item $SettingsPath "$deployDir\config\deploy-settings.json"
    Copy-Item "$repo\winpe\startnet.cmd" "$mount\Windows\System32\startnet.cmd" -Force
}
catch {
    Dismount-WindowsImage -Path $mount -Discard | Out-Null
    throw
}
Dismount-WindowsImage -Path $mount -Save | Out-Null

switch ($Target) {
    'Pxe' {
        Copy-Item $bootWim (Join-Path $OutputPath 'boot.wim')
        Write-Host "boot.wim written to $OutputPath. Import it into WDS (Boot Images > Add Boot Image)."
    }
    'Iso' {
        $iso = Join-Path $OutputPath 'Deploy-WinPE.iso'
        & cmd /c "MakeWinPEMedia /ISO /F `"$WorkDir`" `"$iso`""
        if ($LASTEXITCODE -ne 0) { throw 'MakeWinPEMedia /ISO failed' }
        Write-Host "ISO written to $iso"
    }
    'Usb' {
        if ($UsbDiskNumber -lt 0) { throw 'Pass -UsbDiskNumber (see Get-Disk). That disk will be erased.' }
        $disk = Get-Disk -Number $UsbDiskNumber
        if ($disk.BusType -ne 'USB') { throw "Disk $UsbDiskNumber is $($disk.BusType), not USB. Refusing to erase it." }
        if (-not $Force -and (Read-Host "ERASE disk $UsbDiskNumber ($($disk.FriendlyName))? Type YES") -ne 'YES') { return }

        # Two partitions: FAT32 to boot UEFI, NTFS for images larger than 4 GB.
        Clear-Disk -Number $UsbDiskNumber -RemoveData -RemoveOEM -Confirm:$false
        Initialize-Disk -Number $UsbDiskNumber -PartitionStyle MBR
        $boot = New-Partition -DiskNumber $UsbDiskNumber -Size 2GB -IsActive -AssignDriveLetter
        Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'WINPE' -Confirm:$false | Out-Null
        $data = New-Partition -DiskNumber $UsbDiskNumber -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $data -FileSystem NTFS -NewFileSystemLabel 'DEPLOY' -Confirm:$false | Out-Null

        $bootLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $boot.PartitionNumber).DriveLetter
        $dataLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $data.PartitionNumber).DriveLetter
        robocopy "$WorkDir\media" "${bootLetter}:\" /E /NFL /NDL | Out-Null
        if ($ContentSource) {
            foreach ($dir in 'Images', 'Drivers', 'config') {
                robocopy (Join-Path $ContentSource $dir) "${dataLetter}:\$dir" /E /NFL /NDL | Out-Null
            }
        }
        Write-Host "USB ready: WinPE on ${bootLetter}:, content on ${dataLetter}: (DEPLOY)"
    }
}
