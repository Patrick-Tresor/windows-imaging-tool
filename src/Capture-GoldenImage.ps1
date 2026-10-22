<#
.SYNOPSIS
    Captures a sysprepped reference PC (ideally a Hyper-V VM) to a WIM, from WinPE.
.DESCRIPTION
    Before running: on the reference machine run
        C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
    then boot it from the deployment media and run this script.
.EXAMPLE
    X:\Deploy\Capture-GoldenImage.ps1 -Name Win11-24H2-Enterprise -Destination Z:\Images
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Destination,
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [ValidateSet('fast', 'max')][string]$Compression = 'max',
    [int]$SplitSizeMB = 0   # e.g. 3800 to fit a FAT32 USB; 0 = no split
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force

# WinPE assigns letters unpredictably: find the volume that holds a generalized Windows install.
$windows = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' } |
    Where-Object { Test-Path "$($_.DriveLetter):\Windows\System32\config\SYSTEM" } |
    Select-Object -First 1
if (-not $windows) { throw 'No offline Windows installation found.' }
$source = "$($windows.DriveLetter):\"

# Refuse to capture an image that skipped sysprep, since it would not be hardware-independent.
$setupState = "$source\Windows\Setup\State\State.ini"
if ((Test-Path $setupState) -and -not (Select-String -Path $setupState -Pattern 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -Quiet)) {
    throw "Windows on $source was not generalized with sysprep. Run sysprep /generalize /oobe /shutdown first."
}

if (-not $Destination) { $Destination = Join-Path (Find-ContentRoot -SettingsPath $SettingsPath) 'Images' }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$wim = Join-Path $Destination "$Name.wim"

Invoke-Native -FilePath 'dism.exe' -ArgumentList @(
    '/Capture-Image', "/ImageFile:$wim", "/CaptureDir:$source", "/Name:$Name",
    "/Compress:$Compression", '/CheckIntegrity', '/Verify')

if ($SplitSizeMB -gt 0) {
    Invoke-Native -FilePath 'dism.exe' -ArgumentList @(
        '/Split-Image', "/ImageFile:$wim", "/SWMFile:$(Join-Path $Destination "$Name.swm")", "/FileSize:$SplitSizeMB")
    Remove-Item $wim
}

Write-DeployLog "Captured $source to $Destination"
