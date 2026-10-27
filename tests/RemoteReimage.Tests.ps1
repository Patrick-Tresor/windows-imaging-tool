# Plain-PowerShell tests for remote reimaging: Wake-on-LAN packets, network boot entry selection,
# the computer list and reimage jobs. Run: pwsh -File tests/RemoteReimage.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/RemoteReimage.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function Assert-Throws([scriptblock]$Action, $Name) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true $Name
}

# MAC addresses and magic packets
Assert-Equal (ConvertTo-MacKey '00:15:5d:0a:1b:2c') '00155D0A1B2C' 'MAC with colons is normalized'
Assert-Equal (ConvertTo-MacKey '0015.5d0a.1b2c') '00155D0A1B2C' 'Cisco-style MAC is normalized'
Assert-Equal (Format-MacAddress '00155d0a1b2c') '00-15-5D-0A-1B-2C' 'MAC is formatted with dashes'
Assert-Throws { ConvertTo-MacKey '00-15-5D-0A-1B' } 'a short MAC is rejected'
Assert-Throws { ConvertTo-MacKey 'GG-15-5D-0A-1B-2C' } 'a MAC with non-hex digits is rejected'

$packet = New-MagicPacket '00-15-5D-0A-1B-2C'
Assert-Equal $packet.GetType().Name 'Byte[]' 'magic packet is a byte array'
Assert-Equal $packet.Length 102 'magic packet is 102 bytes'
Assert-Equal (($packet[0..5] | ForEach-Object { '{0:X2}' -f $_ }) -join '') 'FFFFFFFFFFFF' 'magic packet starts with six 0xFF'
Assert-Equal (($packet[96..101] | ForEach-Object { '{0:X2}' -f $_ }) -join '') '00155D0A1B2C' 'magic packet ends with the MAC'

Assert-Equal (Get-BroadcastAddress -IPAddress '10.1.20.37' -PrefixLength 24) '10.1.20.255' '/24 directed broadcast'
Assert-Equal (Get-BroadcastAddress -IPAddress '172.16.5.9' -PrefixLength 22) '172.16.7.255' '/22 directed broadcast'
Assert-Equal (Get-PrefixLength '255.255.252.0') 22 'subnet mask to prefix length'
Assert-Equal ((Get-WakeTargets ([pscustomobject]@{ mac = '00155D0A1B2C'; ip = '10.1.20.37'; prefixLength = 24 })) -join ',') '255.255.255.255,10.1.20.255' 'wake goes to the local and the subnet broadcast'
Assert-Equal ((Get-WakeTargets ([pscustomobject]@{ mac = '00155D0A1B2C'; ip = ''; prefixLength = 0 })) -join ',') '255.255.255.255' 'without an IP only the local broadcast is used'

# Network boot entry from bcdedit /enum firmware, in English and French
$bcdEnglish = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {bootmgr}
                        {5c1b2a10-1111-11ee-9a6e-806e6f6e6963}
                        {5c1b2a11-1111-11ee-9a6e-806e6f6e6963}
                        {5c1b2a12-1111-11ee-9a6e-806e6f6e6963}
timeout                 0

Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume1
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {5c1b2a10-1111-11ee-9a6e-806e6f6e6963}
description             UEFI: SanDisk USB

Firmware Application (101fffff)
-------------------------------
identifier              {5c1b2a11-1111-11ee-9a6e-806e6f6e6963}
description             UEFI: PXE IPv6 Intel(R) Ethernet Connection I219-LM

Firmware Application (101fffff)
-------------------------------
identifier              {5c1b2a12-1111-11ee-9a6e-806e6f6e6963}
description             UEFI: PXE IPv4 Intel(R) Ethernet Connection I219-LM
'@
Assert-Equal (Select-PxeBootEntry $bcdEnglish) '{5c1b2a12-1111-11ee-9a6e-806e6f6e6963}' 'the IPv4 PXE entry is chosen over IPv6 and USB'

# Accented letters are built with [char] so this file stays ASCII (Windows PowerShell 5.1 reads it as ANSI).
$bcdFrench = @'
Gestionnaire de demarrage du microprogramme
-------------------------------------------
identificateur          {fwbootmgr}
displayorder            {bootmgr}
                        {7a7e0c01-2222-11ee-9a6e-806e6f6e6963}
                        {7a7e0c02-2222-11ee-9a6e-806e6f6e6963}

Application du microprogramme (101fffff)
----------------------------------------
identificateur          {7a7e0c01-2222-11ee-9a6e-806e6f6e6963}
description             Windows Boot Manager

Application du microprogramme (101fffff)
----------------------------------------
identificateur          {7a7e0c02-2222-11ee-9a6e-806e6f6e6963}
description             Onboard NIC(IPV4)
'@ -replace 'demarrage', "d$([char]0xE9)marrage"
Assert-Equal (Select-PxeBootEntry $bcdFrench) '{7a7e0c02-2222-11ee-9a6e-806e6f6e6963}' 'French bcdedit output: the Dell onboard NIC entry is found'
Assert-Equal (Select-PxeBootEntry ($bcdFrench -replace 'Onboard NIC\(IPV4\)', "Carte r$([char]0xE9)seau")) '{7a7e0c02-2222-11ee-9a6e-806e6f6e6963}' 'a French "reseau" description is a network entry'
Assert-Equal ($null -eq (Select-PxeBootEntry ($bcdEnglish -replace 'PXE IPv[46] Intel\(R\) Ethernet Connection I219-LM', 'Hard Drive'))) $true 'no network entry gives nothing'
Assert-Equal ($null -eq (Select-PxeBootEntry '')) $true 'empty output gives nothing'

# Computer list and reimage jobs on a content root
$root = Join-Path ([IO.Path]::GetTempPath()) ("reimage-test-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'AnswerFiles') -Force | Out-Null
    Set-Content (Join-Path $root 'AnswerFiles/Lab-W11.xml') '<x/>'

    $pc = Save-KnownComputer -ContentRoot $root -Mac '00:15:5d:0a:1b:2c' -Fields @{ name = 'lab-b204-01'; group = 'Lab-B204' }
    Assert-Equal "$($pc.name)|$($pc.mac)" 'LAB-B204-01|00-15-5D-0A-1B-2C' 'a PC is saved with its name upper-cased'
    [void](Save-KnownComputer -ContentRoot $root -Mac '00155D0A1B2C' -Fields @{ model = 'OptiPlex 7010' })
    $pc = Get-KnownComputer -ContentRoot $root -Mac '00-15-5D-0A-1B-2C'
    Assert-Equal "$($pc.name)|$($pc.group)|$($pc.model)" 'LAB-B204-01|Lab-B204|OptiPlex 7010' 'updating one field keeps the others'

    $csv = Join-Path $root 'pcs.csv'
    Set-Content $csv "Name;MAC;Group;Relay`nLAB-B204-02;00-15-5D-0A-1B-2D;Lab-B204;LAB-B204-01`nLAB-B204-03;not-a-mac;Lab-B204;`n;00-15-5D-0A-1B-2E;;"
    $imp = Import-KnownComputerCsv -ContentRoot $root -Path $csv
    Assert-Equal "$($imp.Added)|$(@($imp.Skipped).Count)" '1|2' 'CSV import with semicolons adds valid rows and reports the rest'
    Assert-Equal (Get-KnownComputer -ContentRoot $root -Mac '00155D0A1B2D').relay 'LAB-B204-01' 'CSV import keeps the relay'

    $info = [pscustomobject]@{ ComputerName = 'LAB-B204-04'; Model = 'EliteDesk 800 G9'; Serial = 'CZC123'
        Adapters = @([pscustomobject]@{ Mac = '00:15:5D:00:00:01'; IP = '10.1.20.50'; Mask = '255.255.255.0'; Name = 'Intel(R) Wi-Fi 6E AX211' },
                     [pscustomobject]@{ Mac = '00:15:5D:00:00:02'; IP = '10.1.20.51'; Mask = '255.255.255.0'; Name = 'Intel(R) Ethernet Connection I219-LM' }) }
    $read = Update-KnownComputerFromInfo -ContentRoot $root -Info $info -Existing ([pscustomobject]@{ name = 'LAB-B204-04'; mac = '' })
    Assert-Equal "$($read.mac)|$($read.ip)|$($read.prefixLength)|$($read.serial)" '00-15-5D-00-00-02|10.1.20.51|24|CZC123' 'reading a PC keeps its wired adapter, not Wi-Fi'

    $now = [datetime]'2026-10-23T08:00:00'
    $job = New-ReimageJob -ContentRoot $root -Mac '00155D0A1B2C' -AnswerFile 'Lab-W11' -ComputerName 'LAB-B204-01' -ExpiresHours 12 -Now $now
    Assert-Equal $job.answerFile 'Lab-W11' 'a job is queued'
    Assert-Throws { New-ReimageJob -ContentRoot $root -Mac '00155D0A1B2C' -AnswerFile 'Missing' } 'a job needs an existing answer file'
    $rows = @(Get-KnownComputerRows -ContentRoot $root -Now $now.AddMinutes(1))
    Assert-Equal (($rows | Where-Object Name -eq 'LAB-B204-01').Job) 'Waiting: Lab-W11' 'the console shows the waiting job'

    Assert-Equal ($null -eq (Receive-ReimageJob -ContentRoot $root -Mac @('00-15-5D-0A-1B-2C') -Now $now.AddHours(13))) $true 'an expired job is not taken'
    Assert-Equal ((@(Get-KnownComputerRows -ContentRoot $root -Now $now.AddHours(13)) | Where-Object Name -eq 'LAB-B204-01').Job) 'Expired' 'the console shows an expired job'

    $taken = Receive-ReimageJob -ContentRoot $root -Mac @('AA-BB-CC-DD-EE-FF', '00:15:5D:0A:1B:2C') -Now $now.AddMinutes(5)
    Assert-Equal "$($taken.answerFile)|$($taken.computerName)" 'Lab-W11|LAB-B204-01' 'WinPE takes the job for one of its MACs'
    Assert-Equal ($null -eq (Get-ReimageJob -ContentRoot $root -Mac '00155D0A1B2C')) $true 'taking a job removes it, so the PC is not reimaged twice'
    Assert-Equal ($null -eq (Receive-ReimageJob -ContentRoot $root -Mac @('00155D0A1B2C') -Now $now.AddMinutes(6))) $true 'a second network boot finds no job'
    Assert-Equal ($null -ne (Get-StartedJob -ContentRoot $root -Mac '00155D0A1B2C' -Since $now)) $true 'the reimage script sees the deploy started'
    Assert-Equal ($null -eq (Get-StartedJob -ContentRoot $root -Mac '00155D0A1B2C' -Since $now.AddHours(1))) $true 'an older start does not count for a new reimage'

    [void](New-ReimageJob -ContentRoot $root -Mac '00155D0A1B2D' -AnswerFile 'Lab-W11')
    Remove-ReimageJob -ContentRoot $root -Mac '00155D0A1B2D'
    Assert-Equal ($null -eq (Get-ReimageJob -ContentRoot $root -Mac '00155D0A1B2D')) $true 'a job can be cancelled'

    $hw = [pscustomobject]@{ Maker = 'Dell'; Model = 'OptiPlex 7010'; Serial = 'ABC1234' }
    $nic = [pscustomobject]@{ Mac = '00:15:5D:0A:1B:2F'; IP = '10.1.20.60'; Mask = '255.255.255.0' }
    $dep = Save-DeployedComputer -ContentRoot $root -Adapter $nic -Identity $hw -ComputerName 'LAB-B204-09' -AnswerFile 'Lab-W11' -Result 'OK'
    Assert-Equal "$($dep.name)|$($dep.serial)|$($dep.lastResult)|$($dep.prefixLength)" 'LAB-B204-09|ABC1234|OK|24' 'a deployed PC is added to the list'

    Remove-KnownComputer -ContentRoot $root -Mac '00155D0A1B2F'
    Assert-Equal ($null -eq (Get-KnownComputer -ContentRoot $root -Mac '00155D0A1B2F')) $true 'a PC can be removed'

    $settings = [pscustomobject]@{ wds = [pscustomobject]@{ server = 'wds01' } }
    Assert-Equal (Get-WdsServerName $settings) 'wds01' 'the WDS server falls back to the PXE publishing setting'
    $settings | Add-Member -NotePropertyName remote -NotePropertyValue ([pscustomobject]@{ wdsServer = 'wds02' })
    Assert-Equal (Get-WdsServerName $settings) 'wds02' 'remote.wdsServer wins'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
