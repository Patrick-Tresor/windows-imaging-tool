# Plain-PowerShell tests for erasing the USB stick. Run: pwsh -File tests/UsbDisk.Tests.ps1
# The Storage cmdlets are replaced by fake functions over an in-memory disk, so it works on Windows and Linux.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/UsbDisk.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Fakes: functions win over cmdlets, also when the module calls them. Clear-Disk keeps the partition style,
# as it does on most sticks; Initialize-Disk fails on a disk that is not RAW, as the real one does.
$global:FakeDisk = $null
$global:FakeCalls = @()
function global:Get-Disk { param([int]$Number) [pscustomobject]($global:FakeDisk.Clone()) }
function global:Clear-Disk { param([int]$Number, [switch]$RemoveData, [switch]$RemoveOEM, [switch]$Confirm)
    $global:FakeCalls += 'Clear'; $global:FakeDisk.Partitions = 0 }
function global:Initialize-Disk { param([int]$Number, [string]$PartitionStyle)
    if ($global:FakeDisk.PartitionStyle -ne 'RAW') { throw 'The disk has already been initialized.' }
    $global:FakeCalls += "Initialize $PartitionStyle"; $global:FakeDisk.PartitionStyle = $PartitionStyle }
function global:Set-Disk { param([int]$Number, [string]$PartitionStyle, $IsOffline, $IsReadOnly)
    if ($PartitionStyle) {
        if ($global:FakeDisk.Partitions) { throw 'The disk has partitions.' }
        $global:FakeCalls += "SetStyle $PartitionStyle"; $global:FakeDisk.PartitionStyle = $PartitionStyle
    }
    if ($null -ne $IsOffline) { $global:FakeCalls += "Online"; $global:FakeDisk.IsOffline = $IsOffline }
    if ($null -ne $IsReadOnly) { $global:FakeCalls += "Writable"; $global:FakeDisk.IsReadOnly = $IsReadOnly }
}

function Reset-Fake([hashtable]$Changes) {
    $global:FakeDisk = @{ Number = 2; FriendlyName = 'SanDisk Ultra'; BusType = 'USB'; PartitionStyle = 'MBR'; Partitions = 2
        IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false }
    foreach ($k in $Changes.Keys) { $global:FakeDisk[$k] = $Changes[$k] }
    $global:FakeCalls = @()
}

function Get-Error([scriptblock]$Block) { try { & $Block; '' } catch { $_.Exception.Message } }

Reset-Fake @{}
Reset-UsbDisk -DiskNumber 2
Assert-Equal ($global:FakeCalls -join ', ') 'Clear' 'an MBR stick (the reported error) is cleared and not initialized again'
Assert-Equal $global:FakeDisk.PartitionStyle 'MBR' 'the MBR stick stays MBR'

Reset-Fake @{ PartitionStyle = 'GPT' }
Reset-UsbDisk -DiskNumber 2
Assert-Equal ($global:FakeCalls -join ', ') 'Clear, SetStyle MBR' 'a GPT stick is cleared and switched to MBR'

Reset-Fake @{ PartitionStyle = 'RAW'; Partitions = 0 }
Reset-UsbDisk -DiskNumber 2
Assert-Equal ($global:FakeCalls -join ', ') 'Initialize MBR' 'a new RAW stick is only initialized'

Reset-Fake @{ IsOffline = $true; IsReadOnly = $true }
Reset-UsbDisk -DiskNumber 2
Assert-Equal ($global:FakeCalls -join ', ') 'Online, Writable, Clear' 'an offline read-only stick is brought online and made writable first'

Reset-Fake @{ BusType = 'NVMe' }
Assert-Equal ((Get-Error { Reset-UsbDisk -DiskNumber 2 }) -like '*NVMe, not USB*') $true 'an internal disk is refused'
Assert-Equal $global:FakeCalls.Count 0 'nothing is erased on the internal disk'

Reset-Fake @{ IsBoot = $true }
Assert-Equal ((Get-Error { Get-UsbTargetDisk -DiskNumber 2 }) -like '*running Windows*Refusing*') $true 'a USB disk Windows boots from is refused'

Reset-Fake @{ IsSystem = $true }
Assert-Equal ((Get-Error { Reset-UsbDisk -DiskNumber 2 }) -like '*boot partition*Refusing*') $true 'a USB disk with the system partition is refused'
Assert-Equal $global:FakeCalls.Count 0 'nothing is erased on the system disk'

Reset-Fake @{}
Assert-Equal (Get-UsbTargetDisk -DiskNumber 2).FriendlyName 'SanDisk Ultra' 'a plain USB stick is accepted'

$script = Get-Content -Raw (Join-Path $repo 'src/New-DeploymentMedia.ps1')
Assert-Equal ($script -match 'Initialize-Disk') $false 'New-DeploymentMedia leaves initializing to Reset-UsbDisk'

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All USB disk tests passed.' -ForegroundColor Green
