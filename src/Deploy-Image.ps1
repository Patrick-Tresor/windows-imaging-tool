<#
.SYNOPSIS
    Deploys the golden image to this PC from WinPE and injects the matching OEM driver pack.
.DESCRIPTION
    Launched by startnet.cmd. Finds content on a USB volume labelled DEPLOY, or on the network
    share in deploy-settings.json (LAN or PXE boot). Wipes the target disk. UEFI/GPT only in v1.
.EXAMPLE
    X:\Deploy\Deploy-Image.ps1 -ImageName Win11-24H2-Enterprise.wim -NoPrompt
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [string]$ImageName,
    [int]$ImageIndex,
    [int]$DiskNumber = -1,
    [string]$ComputerName,
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force

$settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
if (-not $ImageName)   { $ImageName  = $settings.defaultImage }
if (-not $ImageIndex)  { $ImageIndex = $settings.imageIndex }
if ($DiskNumber -lt 0) { $DiskNumber = $settings.diskNumber }
$prompt = $settings.prompt -and -not $NoPrompt

try {
    $hw = Get-HardwareIdentity
    Write-DeployLog ("Hardware: {0} | {1} | type {2} | SKU {3} | serial {4} | UEFI {5}" -f
        $hw.Maker, $hw.Model, $hw.MachineType, $hw.Sku, $hw.Serial, $hw.IsUefi)
    if (-not $hw.IsUefi) { throw 'This PC booted WinPE in legacy BIOS mode. Switch the firmware to UEFI and boot again.' }

    $root      = Find-ContentRoot -SettingsPath $SettingsPath

    # Settings on the content root (edited in the console) override the copy baked into the media,
    # so the default image can change without rebuilding USB sticks. Explicit parameters still win.
    $rootSettings = Join-Path $root 'config\deploy-settings.json'
    if (Test-Path $rootSettings) {
        $settings = Get-Content -Raw $rootSettings | ConvertFrom-Json
        if (-not $PSBoundParameters.ContainsKey('ImageName'))  { $ImageName  = $settings.defaultImage }
        if (-not $PSBoundParameters.ContainsKey('ImageIndex')) { $ImageIndex = $settings.imageIndex }
        if (-not $PSBoundParameters.ContainsKey('DiskNumber')) { $DiskNumber = $settings.diskNumber }
        $prompt = $settings.prompt -and -not $NoPrompt
        Write-DeployLog "Using settings from $rootSettings"
    }
    $imagePath = Join-Path $root "Images\$ImageName"
    if (-not (Test-Path $imagePath)) { throw "Image not found: $imagePath" }

    $driverPack = Resolve-DriverPack -Identity $hw -CatalogPath (Join-Path $root 'config\driver-catalog.json') -DriverRoot (Join-Path $root 'Drivers')

    if (-not $ComputerName) { $ComputerName = $settings.computerNamePattern -replace '\{SERIAL\}', $hw.Serial }
    $ComputerName = ($ComputerName -replace '[^A-Za-z0-9-]', '')
    $ComputerName = $ComputerName.Substring(0, [Math]::Min(15, $ComputerName.Length))

    $disk = Get-Disk -Number $DiskNumber
    Write-DeployLog ("Target disk {0}: {1} {2:N0} GB" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB))

    if ($prompt) {
        Write-Host ''
        Write-Host "Image:       $ImageName (index $ImageIndex)"
        Write-Host "Drivers:     $(if ($driverPack) { $driverPack } else { 'inbox only' })"
        Write-Host "Name:        $ComputerName"
        Write-Host "ERASE disk:  $($disk.Number) $($disk.FriendlyName)" -ForegroundColor Red
        if ((Read-Host 'Type YES to continue') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; return }
    }

    # 1. Partition: EFI, MSR, Windows, Recovery (Microsoft's recommended UEFI layout).
    $dp = Join-Path $env:TEMP 'diskpart.txt'
    @"
select disk $DiskNumber
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=1024
format quick fs=ntfs label="Windows"
assign letter=W
create partition primary
format quick fs=ntfs label="Recovery"
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
exit
"@ | Set-Content -Path $dp -Encoding ascii
    Invoke-Native -FilePath 'diskpart.exe' -ArgumentList @('/s', $dp)

    # 2. Apply the image. Split images (.swm) need /SWMFile.
    $applyArgs = @('/Apply-Image', "/ImageFile:$imagePath", "/Index:$ImageIndex", '/ApplyDir:W:\')
    if ($imagePath -like '*.swm') { $applyArgs += "/SWMFile:$($imagePath -replace '\.swm$', '*.swm')" }
    Invoke-Native -FilePath 'dism.exe' -ArgumentList $applyArgs

    # 3. Inject the OEM driver pack offline.
    if ($driverPack) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Image:W:\', '/Add-Driver', "/Driver:$driverPack", '/Recurse', '/ForceUnsigned:No')
    }

    # 4. Unattend: set the computer name and drop it where Setup looks for it.
    $unattendSrc = Join-Path $root $settings.unattend
    if (Test-Path $unattendSrc) {
        New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
        (Get-Content -Raw $unattendSrc) -replace '%COMPUTERNAME%', $ComputerName |
            Set-Content -Path 'W:\Windows\Panther\unattend.xml' -Encoding utf8
        Write-DeployLog "Unattend applied with computer name $ComputerName"
    } else {
        Write-DeployLog "No unattend at $unattendSrc; Windows will run full OOBE" -Level WARN
    }

    # 5. Boot files.
    Invoke-Native -FilePath 'W:\Windows\System32\bcdboot.exe' -ArgumentList @('W:\Windows', '/s', 'S:', '/f', 'UEFI')

    Write-DeployLog 'Deployment finished'
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    $status = 'FAILED'
}
finally {
    # Keep the log on the deployed disk and, when available, on the content root for central review.
    if (Test-Path 'W:\Windows') { Copy-Item 'X:\Windows\Temp\Deploy.log' 'W:\Windows\Temp\Deploy.log' -ErrorAction SilentlyContinue }
    if ($root -and $hw) {
        $logDir = Join-Path $root 'Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item 'X:\Windows\Temp\Deploy.log' (Join-Path $logDir ("{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $hw.Serial, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'OK' -and $settings.rebootWhenDone) { & wpeutil.exe reboot }
if ($status -ne 'OK') { exit 1 }
