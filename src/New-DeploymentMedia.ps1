<#
.SYNOPSIS
    Builds the WinPE boot image with the deploy tool inside, then a USB stick, an ISO, or a boot.wim for PXE.
.DESCRIPTION
    Run as admin on a workstation with the Windows ADK and the WinPE add-on installed.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Pxe -OutputPath C:\WDS\Boot
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Iso -CaptureConfig D:\DeployShare\config\capture.json -BootVM Win11-Ref
    Builds capture media and boots the Hyper-V VM Win11-Ref from it.
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
    [string]$CaptureConfig,          # capture.json to bake in: the media then captures instead of deploying
    [string]$BootVM,                 # with -Target Iso: attach the ISO to this Hyper-V VM and start it
    [switch]$Force                   # skip the USB erase prompt (the console confirms before calling)
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'AdkCheck.psm1') -Force

# Check the ADK first: without it nothing below can work, and copype's own errors are cryptic.
$adkStatus = Get-AdkStatus
if (-not $adkStatus.Ready) { throw ("Can't build media on this PC yet:`n - " + ($adkStatus.Problems -join "`n - ")) }
Write-Host $adkStatus.Summary
foreach ($w in $adkStatus.Warnings) { Write-Warning $w }
$adk = $adkStatus.Root
$peRoot = "$adk\Windows Preinstallation Environment"

if (-not $SettingsPath) { $SettingsPath = "$repo\config\deploy-settings.json" }
if ($BootVM -and $Target -ne 'Iso') { throw '-BootVM needs -Target Iso.' }
if ($BootVM) {
    # Check the VM before spending minutes on the build.
    $vm = Get-VM -Name $BootVM
    if ($vm.Generation -ne 2) { throw "VM $BootVM is generation $($vm.Generation). Only generation 2 (UEFI) VMs are supported." }
    if ($vm.State -ne 'Off') { throw "VM $BootVM is $($vm.State). Let sysprep shut it down first." }
}

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
    foreach ($oc in Get-WinPEComponentNames) {
        Add-WindowsPackage -Path $mount -PackagePath "$ocs\$oc.cab" | Out-Null
        $lang = "$ocs\en-us\$($oc)_en-us.cab"
        if (Test-Path $lang) { Add-WindowsPackage -Path $mount -PackagePath $lang | Out-Null }
    }
    if ($WinPEDrivers) { Add-WindowsDriver -Path $mount -Driver $WinPEDrivers -Recurse | Out-Null }

    $deployDir = Join-Path $mount 'Deploy'
    New-Item -ItemType Directory -Path "$deployDir\config" -Force | Out-Null
    Copy-Item "$repo\src\*.ps1", "$repo\src\*.psm1" $deployDir
    Copy-Item $SettingsPath "$deployDir\config\deploy-settings.json"
    if ($CaptureConfig) { Copy-Item $CaptureConfig "$deployDir\config\capture.json" }
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
        $iso = Join-Path $OutputPath $(if ($CaptureConfig) { 'Capture-WinPE.iso' } else { 'Deploy-WinPE.iso' })
        if (Test-Path $iso) { Remove-Item $iso }
        # Capture ISOs boot without the "Press any key to boot from CD" prompt so an unattended VM starts WinPE.
        $efi = if ($CaptureConfig) { "$adk\Deployment Tools\amd64\Oscdimg\efisys_noprompt.bin" } else { "$WorkDir\fwfiles\efisys.bin" }
        $bootData = "2#p0,e,b`"$WorkDir\fwfiles\etfsboot.com`"#pEF,e,b`"$efi`""
        & cmd /c "oscdimg -m -o -u2 -udfver102 -bootdata:$bootData `"$WorkDir\media`" `"$iso`""
        if ($LASTEXITCODE -ne 0) { throw 'oscdimg failed' }
        Write-Host "ISO written to $iso"

        if ($BootVM) {
            $dvd = Get-VMDvdDrive -VMName $BootVM | Select-Object -First 1
            if ($dvd) { Set-VMDvdDrive -VMName $BootVM -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $iso }
            else { $dvd = Add-VMDvdDrive -VMName $BootVM -Path $iso -Passthru }
            Set-VMFirmware -VMName $BootVM -FirstBootDevice (Get-VMDvdDrive -VMName $BootVM | Select-Object -First 1)
            Start-VM -Name $BootVM
            Write-Host "Started $BootVM from $iso. Watch it with: vmconnect localhost `"$BootVM`""

            # The capture shuts the VM down when it finishes. Then eject the ISO and boot from disk again,
            # or the next start would capture a second time.
            Write-Host 'Waiting for the capture to finish and the VM to shut down...'
            while ((Get-VM -Name $BootVM).State -ne 'Off') { Start-Sleep -Seconds 30 }
            Set-VMDvdDrive -VMName $BootVM -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $null
            $disk = Get-VMHardDiskDrive -VMName $BootVM | Select-Object -First 1
            if ($disk) { Set-VMFirmware -VMName $BootVM -FirstBootDevice $disk }
            Write-Host "$BootVM is off, the ISO is ejected and it boots from its disk again. Check the Logs folder for the capture result."
        }
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
        # Find-ContentRoot recognizes the stick by its Images folder; capture media saves there too.
        New-Item -ItemType Directory -Path "${dataLetter}:\Images" -Force | Out-Null
        if ($ContentSource) {
            foreach ($dir in 'Images', 'Drivers', 'config') {
                robocopy (Join-Path $ContentSource $dir) "${dataLetter}:\$dir" /E /NFL /NDL | Out-Null
            }
        }
        Write-Host "USB ready: WinPE on ${bootLetter}:, content on ${dataLetter}: (DEPLOY)"
    }
}
