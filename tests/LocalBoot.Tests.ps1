# Plain-PowerShell tests for reimaging without PXE (WinPE booted from the PC's own disk) and for backing up the
# old Windows before the wipe. Run: pwsh -File tests/LocalBoot.Tests.ps1. Works on Windows and Linux.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/RemoteReimage.psm1') -Force
Import-Module (Join-Path $repo 'src/UserState.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# bcdedit /create output, English and French.
$g = '{0f4a1d2c-1111-4a2b-9c3d-123456789abc}'
Assert-Equal (Get-BcdGuid "The entry $g was successfully created.") $g 'GUID from English bcdedit'
Assert-Equal (Get-BcdGuid "L'entree $g a ete creee.") $g 'GUID from another language'
Assert-Equal ($null -eq (Get-BcdGuid 'An error occurred.')) $true 'no GUID: nothing'

$ram = '{11111111-2222-3333-4444-555555555555}'; $ldr = '{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}'
$cmds = @(Get-LocalBootCommands -RamdiskId $ram -LoaderId $ldr)
$text = @($cmds | ForEach-Object { $_ -join ' ' })
Assert-Equal $text[0] "/set $ram ramdisksdidevice partition=C:" 'RAM disk on C:'
Assert-Equal $text[1] "/set $ram ramdisksdipath \_ImagingBoot\boot.sdi" 'boot.sdi path'
Assert-Equal $text[2] "/set $ldr device ramdisk=[C:]\_ImagingBoot\boot.wim,$ram" 'loader device is the boot.wim RAM disk'
Assert-Equal ($text -contains "/set $ldr path \windows\system32\boot\winload.efi") $true 'UEFI: winload.efi'
Assert-Equal ($text -contains "/set $ldr winpe yes") $true 'WinPE flag'
Assert-Equal $text[-1] "/bootsequence $ldr" 'one-time boot, last'
$bios = @(Get-LocalBootCommands -RamdiskId $ram -LoaderId $ldr -Firmware BIOS | ForEach-Object { $_ -join ' ' })
Assert-Equal ($bios -contains "/set $ldr path \windows\system32\boot\winload.exe") $true 'BIOS: winload.exe'

# The job asks WinPE for the backup.
$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-localboot-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'AnswerFiles') -Force | Out-Null
    Set-Content (Join-Path $root 'AnswerFiles/Lab.xml') '<deployment/>'
    $j = New-ReimageJob -ContentRoot $root -Mac '00-15-5D-0A-1B-2C' -AnswerFile Lab -Backup
    Assert-Equal $j.backup $true 'job: backup asked'
    $j = New-ReimageJob -ContentRoot $root -Mac '00-15-5D-0A-1B-2C' -AnswerFile Lab
    Assert-Equal $j.backup $false 'job: no backup by default'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# Backup of the old Windows.
$now = [datetime]'2026-11-03T10:15:00'
$win = [pscustomobject]@{ Volume = [pscustomobject]@{ Drive = 'D:'; Encryption = 'None'; HasWindows = $true } }
$p = Get-WindowsBackupPlan -DiskNumber 0 -ContentRoot 'Z:\' -Serial 'ABC 1' -Now $now -Source $win
Assert-Equal $p.Mode 'Backup' 'Windows found: backed up'
Assert-Equal ($p.ImagePath -replace '/', '\') 'Z:\Backups\ABC_1-20261103-1015.wim' 'to Backups\<serial>-<time>.wim'
$p = Get-WindowsBackupPlan -DiskNumber 0 -ContentRoot 'Z:\' -Serial 'X' -Now $now -Source ([pscustomobject]@{ Volume = $null })
Assert-Equal $p.Mode 'None' 'new PC: nothing to back up'
$r = try { Get-WindowsBackupPlan -DiskNumber 0 -ContentRoot 'D:\' -Serial 'X' -IsNetworkRoot $false -Source $win; 'ran' } catch { 'stopped' }
Assert-Equal $r 'stopped' 'from a USB stick: stops before the wipe'
$locked = [pscustomobject]@{ Volume = [pscustomobject]@{ Drive = 'D:'; Encryption = 'Locked'; HasWindows = $false } }
$r = try { Get-WindowsBackupPlan -DiskNumber 0 -ContentRoot 'Z:\' -Serial 'X' -Source $locked; 'ran' } catch { 'stopped' }
Assert-Equal $r 'stopped' 'BitLocker locked: stops before the wipe'
Assert-Equal ((Get-WindowsBackupArgs -Drive 'D:' -ImagePath 'Z:\Backups\a.wim' -Name 'n') -join ' ') '/Capture-Image /ImageFile:Z:\Backups\a.wim /CaptureDir:D:\ /Name:n /Compress:fast /CheckIntegrity' 'DISM capture arguments'

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All local boot and backup checks passed' -ForegroundColor Green
