# Plain-PowerShell tests for user data migration: USMT arguments, rule files and the backup plan. The WinPE
# parts (finding the old Windows, emptying the partition, running USMT) need real disks and are not covered. Run: pwsh -File tests/UserState.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
Import-Module (Join-Path $repo 'src/UserState.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$a = Read-AnswerFile -Path (Join-Path $repo 'config/answer-files/Default.xml')
$a.MigrateUserData = $true

# Rule files.
Assert-Equal (Resolve-UsmtRuleFile -Rule 'MigDocs.xml' -UsmtDir 'X:\Deploy\USMT' -ContentRoot 'Z:') 'X:\Deploy\USMT\MigDocs.xml' 'built-in rules come from the USMT folder'
Assert-Equal (Resolve-UsmtRuleFile -Rule 'config\usmt\Custom.xml' -UsmtDir 'X:\Deploy\USMT' -ContentRoot 'Z:') 'Z:\config\usmt\Custom.xml' 'own rules are relative to the content root'
Assert-Equal (Resolve-UsmtRuleFile -Rule 'Y:\rules\Lab.xml' -UsmtDir 'X:\Deploy\USMT' -ContentRoot 'Z:') 'Y:\rules\Lab.xml' 'absolute rule paths are kept'
Assert-Equal (Resolve-UsmtRuleFile -Rule 'config\usmt\Custom.xml' -UsmtDir 'C:\Deploy\USMT') 'C:\Deploy\USMT\Custom.xml' 'on the PC every rule is in the copied USMT folder'

# Store names.
Assert-Equal (Get-UserStateStoreName 'PF3X 9K/1') 'PF3X9K1' 'store name is the cleaned serial'
Assert-Equal (Get-UserStateStoreName '') 'NO-SERIAL' 'a PC without a serial still gets a store name'

# ScanState and LoadState, Local store (hard links).
$rules = 'X:\Deploy\USMT\MigDocs.xml', 'X:\Deploy\USMT\MigApp.xml'
$a.UserDataExclude = @('*\Administrator')
$scan = Get-ScanStateArguments -Answer $a -StorePath 'D:\UserState' -WindowsDir 'D:\Windows' -RuleFiles $rules
Assert-Equal ($scan -join ' ') 'D:\UserState /offlineWinDir:D:\Windows /i:X:\Deploy\USMT\MigDocs.xml /i:X:\Deploy\USMT\MigApp.xml /o /c /v:5 /l:X:\Windows\Temp\ScanState.log /progress:X:\Windows\Temp\ScanStateProgress.log /hardlink /nocompress /ue:*\Administrator' 'offline hard-link ScanState'
$load = Get-LoadStateArguments -Answer $a -StorePath 'C:\UserState' -RuleFiles 'C:\Deploy\USMT\MigDocs.xml', 'C:\Deploy\USMT\MigApp.xml'
Assert-Equal ($load -join ' ') 'C:\UserState /i:C:\Deploy\USMT\MigDocs.xml /i:C:\Deploy\USMT\MigApp.xml /c /v:5 /l:C:\Windows\Temp\LoadState.log /progress:C:\Windows\Temp\LoadStateProgress.log /hardlink /nocompress' 'hard-link LoadState'

# Share store: compressed, encrypted, local accounts.
$a.UserDataStore = 'Share'; $a.UserDataExclude = @(); $a.UserDataLocalAccounts = $true
$scan = Get-ScanStateArguments -Answer $a -StorePath 'Z:\UserState\PF3X' -WindowsDir 'D:\Windows' -RuleFiles $rules -KeyFile 'Z:\config\secrets\usmt.txt'
Assert-Equal (($scan | Where-Object { $_ -match '^/(hardlink|nocompress|encrypt|keyfile)' }) -join ' ') '/encrypt:AES_256 /keyfile:Z:\config\secrets\usmt.txt' 'Share ScanState is compressed and encrypted'
$load = Get-LoadStateArguments -Answer $a -StorePath 'C:\UserState' -RuleFiles 'C:\Deploy\USMT\MigDocs.xml' -KeyFile 'C:\Deploy\usmt.key'
Assert-Equal (($load | Where-Object { $_ -match '^/(lac|hardlink|decrypt|keyfile)' }) -join ' ') '/lac /decrypt:AES_256 /keyfile:C:\Deploy\usmt.key' 'Share LoadState decrypts and recreates local accounts'
$scan = Get-ScanStateArguments -Answer $a -StorePath 'Z:\UserState\PF3X' -WindowsDir 'D:\Windows' -RuleFiles $rules
Assert-Equal (@($scan | Where-Object { $_ -like '/encrypt*' }).Count) 0 'no key, no encryption'

# Exit codes.
Assert-Equal "$(Test-UsmtExitCode 0)|$(Test-UsmtExitCode 3)|$(Test-UsmtExitCode 26)" 'True|True|False' 'USMT exit codes 0 and 3 are success'

# The plan, decided before the disk is touched. Disks and files are faked inside the module.
$mod = Get-Module UserState
function Get-Plan($Answer, $Source, [string[]]$Files) {
    & $mod { param($src, $files) $script:FakeSource = $src; $script:FakeFiles = $files } $Source $Files
    try { Get-UserStatePlan -Answer $Answer -ContentRoot 'Z:\' -UsmtDir 'X:\Deploy\USMT' -Serial 'PF3X' -SharePath 'Z:\UserState' }
    catch { "THROWS: $($_.Exception.Message)" }
}
& $mod {
    function script:Find-UserStateSource { param($DiskNumber) $script:FakeSource }
    function script:Test-Path { param($Path) $Path -in $script:FakeFiles }
    function script:Join-Path { param($Path, $ChildPath) '{0}\{1}' -f $Path.TrimEnd('\'), $ChildPath }
}
$usmtFiles = 'X:\Deploy\USMT\scanstate.exe', 'X:\Deploy\USMT\MigDocs.xml', 'X:\Deploy\USMT\MigApp.xml'
$win = { param($enc) [pscustomobject]@{ PartitionNumber = 3; Drive = 'D:'; Encryption = $enc; HasWindows = $true; HasStore = $false } }
$gpt = [pscustomobject]@{ PartitionStyle = 'GPT'; EspPartition = 1; Volume = (& $win 'None') }
$a = Read-AnswerFile -Path (Join-Path $repo 'config/answer-files/Default.xml')
$a.MigrateUserData = $true

Assert-Equal ((Get-Plan $a $gpt @()) -like 'THROWS: *USMT isn''t in this boot image*') $true 'no USMT in WinPE stops the deploy'
$p = Get-Plan $a $gpt $usmtFiles
Assert-Equal "$($p.Mode)|$($p.StorePath)" 'Backup|D:\UserState' 'Local store backs up into the old Windows partition'
$locked = [pscustomobject]@{ PartitionStyle = 'GPT'; EspPartition = 1; Volume = (& $win 'Locked') }
Assert-Equal ((Get-Plan $a $locked $usmtFiles) -like 'THROWS: *locked by BitLocker*') $true 'a BitLocker-locked disk stops the deploy'
$enc = [pscustomobject]@{ PartitionStyle = 'GPT'; EspPartition = 1; Volume = (& $win 'Unlocked') }
Assert-Equal ((Get-Plan $a $enc $usmtFiles) -like 'THROWS: *BitLocker encrypted*') $true 'Local store refuses an encrypted partition'
$mbr = [pscustomobject]@{ PartitionStyle = 'MBR'; EspPartition = $null; Volume = (& $win 'None') }
Assert-Equal ((Get-Plan $a $mbr $usmtFiles) -like 'THROWS: *MBR*') $true 'Local store refuses a disk without an EFI partition'
$retry = [pscustomobject]@{ PartitionStyle = 'GPT'; EspPartition = 1; Volume = [pscustomobject]@{ PartitionNumber = 3; Drive = 'D:'; Encryption = 'None'; HasWindows = $false; HasStore = $true } }
Assert-Equal (Get-Plan $a $retry $usmtFiles).Mode 'Reuse' 'Local store left by a failed attempt is restored'
$blank = [pscustomobject]@{ PartitionStyle = 'RAW'; EspPartition = $null; Volume = $null }
Assert-Equal (Get-Plan $a $blank $usmtFiles).Mode 'None' 'a new PC is deployed without user data'

$a.UserDataStore = 'Share'
$p = Get-Plan $a $mbr $usmtFiles
Assert-Equal "$($p.Mode)|$($p.StorePath)" 'Backup|Z:\UserState\PF3X' 'Share store backs up to a folder named after the serial, even from MBR'
Assert-Equal (Get-Plan $a $blank ($usmtFiles + 'Z:\UserState\PF3X\USMT')).Mode 'Reuse' 'Share store from a failed attempt is restored'
$a.UserDataEncrypt = $true; $a.UserDataKeyFile = 'config\secrets\usmt.txt'
Assert-Equal ((Get-Plan $a $gpt $usmtFiles) -like 'THROWS: *key file not found*') $true 'a missing encryption key stops the deploy'
Assert-Equal (Get-Plan $a $gpt ($usmtFiles + 'Z:\config\secrets\usmt.txt')).KeyFile 'Z:\config\secrets\usmt.txt' 'the key file is passed to ScanState'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
