# Plain-PowerShell tests for starting the deployed Windows after the restart instead of WinPE again:
# the Windows Boot Manager entry from bcdedit /enum firmware, the bcdedit calls, and the "deployed but never
# started" marker that stops an Unattended countdown from wiping the PC twice. Run: pwsh -File tests/BootNext.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# WinPE booted from a USB stick, right after bcdboot W:\Windows /s S: /f UEFI.
$bcdEnglish = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {5c1b2a10-1111-11ee-9a6e-806e6f6e6963}
                        {bootmgr}
                        {5c1b2a12-1111-11ee-9a6e-806e6f6e6963}
timeout                 0

Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=S:
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager
locale                  en-US

Firmware Application (101fffff)
-------------------------------
identifier              {5c1b2a10-1111-11ee-9a6e-806e6f6e6963}
description             UEFI: SanDisk USB

Firmware Application (101fffff)
-------------------------------
identifier              {5c1b2a12-1111-11ee-9a6e-806e6f6e6963}
description             UEFI: PXE IPv4 Intel(R) Ethernet Connection I219-LM
'@
Assert-Equal (Select-WindowsBootEntry -BcdText $bcdEnglish) '{bootmgr}' 'the Windows Boot Manager on S: is chosen over the USB stick'

# French labels; an older Windows Boot Manager on another disk comes first but is not the one just written.
$bcdFrench = @'
Gestionnaire de demarrage du microprogramme
--------------------------------------------
identificateur          {fwbootmgr}
displayorder            {7a7a7a7a-2222-11ee-9a6e-806e6f6e6963}
                        {9dea862c-5cdd-4e70-acc1-f32b344d4795}

Application du microprogramme (101fffff)
----------------------------------------
identificateur          {7a7a7a7a-2222-11ee-9a6e-806e6f6e6963}
peripherique            partition=\Device\HarddiskVolume7
chemin                  \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Gestionnaire de demarrage Windows
---------------------------------
identificateur          {9dea862c-5cdd-4e70-acc1-f32b344d4795}
peripherique            partition=S:
chemin                  \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager
'@
Assert-Equal (Select-WindowsBootEntry -BcdText $bcdFrench) '{9dea862c-5cdd-4e70-acc1-f32b344d4795}' 'French output: the entry on the new system partition wins'

# The system partition has no letter in bcdedit's output: {bootmgr} (what bcdboot writes) is still found.
$bcdNoLetter = $bcdEnglish -replace 'partition=S:', 'partition=\Device\HarddiskVolume3'
Assert-Equal (Select-WindowsBootEntry -BcdText $bcdNoLetter) '{bootmgr}' 'without a drive letter the {bootmgr} entry is used'

$bcdNoWindows = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {5c1b2a10-1111-11ee-9a6e-806e6f6e6963}

Firmware Application (101fffff)
-------------------------------
identifier              {5c1b2a10-1111-11ee-9a6e-806e6f6e6963}
description             UEFI: SanDisk USB
'@
Assert-Equal "$(Select-WindowsBootEntry -BcdText $bcdNoWindows)" '' 'no Windows Boot Manager: nothing is chosen'
Assert-Equal "$(Select-WindowsBootEntry -BcdText '')" '' 'empty output: nothing is chosen'

$calls = @(Get-WindowsBootNextArgs -Entry '{bootmgr}')
Assert-Equal $calls.Count 2 'two bcdedit calls'
Assert-Equal ($calls[0] -join ' ') '/set {fwbootmgr} displayorder {bootmgr} /addfirst' 'Windows goes first in the boot order'
Assert-Equal ($calls[1] -join ' ') '/set {fwbootmgr} bootsequence {bootmgr}' 'Windows is the next boot'

# Set-WindowsBootNext with a stand-in for bcdedit that records its arguments.
$work = Join-Path ([IO.Path]::GetTempPath()) ("bootnext-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $record = Join-Path $work 'calls.txt'
    $enumFile = Join-Path $work 'enum.txt'
    Set-Content -LiteralPath $enumFile -Value $bcdEnglish
    $fake = Join-Path $work 'bcdedit.ps1'
    Set-Content -LiteralPath $fake -Value @"
if (`$args[0] -eq '/enum') { Get-Content -LiteralPath '$enumFile'; exit 0 }
Add-Content -LiteralPath '$record' -Value (`$args -join ' ')
if (`$env:FAKE_BCDEDIT_FAIL) { 'The parameter is incorrect.'; exit 1 }
exit 0
"@
    $r = Set-WindowsBootNext -SystemDrive 'S:' -BcdEdit $fake
    Assert-Equal "$($r.Ok)|$($r.Entry)" 'True|{bootmgr}' 'boot next is set to Windows Boot Manager'
    Assert-Equal ((Get-Content -LiteralPath $record) -join ';') '/set {fwbootmgr} displayorder {bootmgr} /addfirst;/set {fwbootmgr} bootsequence {bootmgr}' 'bcdedit got both calls'

    $env:FAKE_BCDEDIT_FAIL = '1'
    try { $r = Set-WindowsBootNext -SystemDrive 'S:' -BcdEdit $fake } finally { Remove-Item Env:\FAKE_BCDEDIT_FAIL }
    Assert-Equal $r.Ok $false 'a failing bcdedit is reported, not thrown'
    Assert-Equal ($r.Message -like '*displayorder*exit 1*') $true 'the failure names the call and exit code'

    Set-Content -LiteralPath $enumFile -Value $bcdNoWindows
    $r = Set-WindowsBootNext -SystemDrive 'S:' -BcdEdit $fake
    Assert-Equal "$($r.Ok)|$($r.Message)" 'False|No Windows Boot Manager entry in the firmware boot list.' 'no entry is reported'

    $r = Set-WindowsBootNext -SystemDrive 'S:' -BcdEdit (Join-Path $work 'missing.exe')
    Assert-Equal $r.Ok $false 'a missing bcdedit is reported, not thrown'

    # Marker: Windows deployed to this PC but never started.
    $disk = Join-Path $work 'C'; $stick = Join-Path $work 'D'
    New-Item -ItemType Directory -Path (Join-Path $disk 'Temp'), (Join-Path $stick 'Temp') -Force | Out-Null
    $hw = [pscustomobject]@{ Serial = 'ABC123' }
    New-DeployedMarker -Identity $hw -AnswerFile 'W11-Staff' -ComputerName 'LAB-01' | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $disk 'Temp\deployed.json')
    $m = Find-UnstartedDeployment -Serial 'ABC123' -Roots @($stick, $disk)
    Assert-Equal "$($m.serial)|$($m.answerFile)|$($m.computerName)" 'ABC123|W11-Staff|LAB-01' 'the marker of this PC is found'
    Assert-Equal "$(Find-UnstartedDeployment -Serial 'OTHER' -Roots @($disk))" '' 'a marker for another serial (disk moved from another PC) is ignored'
    Assert-Equal "$(Find-UnstartedDeployment -Serial 'ABC123' -Roots @($stick))" '' 'no marker: nothing found'
    Set-Content -LiteralPath (Join-Path $stick 'Temp\deployed.json') -Value 'not json'
    Assert-Equal "$(Find-UnstartedDeployment -Serial 'ABC123' -Roots @($stick))" '' 'a damaged marker is ignored'
    # Deployed by an older version, which staged in \Deploy instead of \Temp.
    $old = Join-Path $work 'E'
    New-Item -ItemType Directory -Path (Join-Path $old 'Deploy') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $disk 'Temp\deployed.json') -Destination (Join-Path $old 'Deploy\deployed.json')
    Assert-Equal "$((Find-UnstartedDeployment -Serial 'ABC123' -Roots @($old)).serial)" 'ABC123' 'a marker in the old \Deploy folder is still found'

    # A volume PowerShell has no drive for (the old Windows at C: of a Dell Latitude 5521 in WinPE): Join-Path threw
    # "A drive with the name 'C' does not exist" and stopped the deploy. It must be skipped, and the next root read.
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $free = @([char[]]'QRSTUVWXYZJKLMNOP' | Where-Object { "$_" -notin $used -and -not (Get-PSDrive -Name "$_" -ErrorAction SilentlyContinue) }) | Select-Object -First 1
    if ($free) {
        $m = Find-UnstartedDeployment -Serial 'ABC123' -Roots @("${free}:\", $disk)
        Assert-Equal "$($m.serial)" 'ABC123' "a drive PowerShell does not have (${free}:) is skipped, not thrown on"
    }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All boot next tests passed' -ForegroundColor Green
