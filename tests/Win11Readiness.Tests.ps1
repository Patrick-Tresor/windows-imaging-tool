# Plain-PowerShell tests for the Windows 11 readiness check: processor matching, each requirement,
# image detection and the block/warn decision. Run: pwsh -File tests/Win11Readiness.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Win11Readiness.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Processors, as Win32_Processor names them.
$cpus = [ordered]@{
    'Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz'          = 'Supported'
    'Intel(R) Core(TM) i7-7700 CPU @ 3.60GHz'           = 'Unsupported'
    'Intel(R) Core(TM) i7-1165G7 @ 2.80GHz'             = 'Supported'
    'Intel(R) Core(TM) i5-10210U CPU @ 1.60GHz'         = 'Supported'
    'Intel(R) Core(TM) i9-13900K'                       = 'Supported'
    'Intel(R) Core(TM) i5-2500K CPU @ 3.30GHz'          = 'Unsupported'
    'Intel(R) Core(TM) i7 CPU 920 @ 2.67GHz'            = 'Unknown'
    'Intel(R) Core(TM) i5-520M CPU @ 2.40GHz'           = 'Unsupported'
    'Intel(R) Core(TM) Ultra 7 155H'                    = 'Supported'
    'Intel(R) Core(TM) 7 150U'                          = 'Supported'
    'Intel(R) N100'                                     = 'Supported'
    'Intel(R) Core(TM)2 Duo CPU E8400 @ 3.00GHz'        = 'Unsupported'
    'Intel(R) Xeon(R) W-2245 CPU @ 3.90GHz'             = 'Unknown'
    'AMD Ryzen 5 PRO 4650U with Radeon Graphics'        = 'Supported'
    'AMD Ryzen 7 2700X Eight-Core Processor'            = 'Supported'
    'AMD Ryzen 5 2500U with Radeon Vega Mobile Gfx'     = 'Unsupported'
    'AMD Ryzen 7 1700 Eight-Core Processor'             = 'Unsupported'
    'AMD Ryzen 9 7950X 16-Core Processor'               = 'Supported'
    'AMD Ryzen AI 9 HX 370 w/ Radeon 890M'              = 'Supported'
    'AMD Ryzen Threadripper 1950X 16-Core Processor'    = 'Unsupported'
    'AMD A10-9700 RADEON R7, 10 COMPUTE CORES 4C+6G'    = 'Unsupported'
    'AMD FX(tm)-8350 Eight-Core Processor'              = 'Unsupported'
}
foreach ($name in $cpus.Keys) {
    $maker = if ($name -like 'AMD*') { 'AuthenticAMD' } else { 'GenuineIntel' }
    Assert-Equal (Get-CpuWin11Support -Name $name -Manufacturer $maker) $cpus[$name] "cpu: $name"
}

# A PC that meets everything.
$good = [pscustomobject]@{
    IsUefi = $true; SecureBootOn = $true; TpmPresent = $true; TpmEnabled = $true; TpmSpecVersion = '2.0, 0, 1.59'; TpmError = $null
    CpuName = 'Intel(R) Core(TM) i5-1245U'; CpuManufacturer = 'GenuineIntel'; CpuCores = 10; CpuMHz = 1600; MemoryGB = 15.7; DiskGB = 477
}
$r = @(Test-Win11Readiness -Facts $good)
Assert-Equal (($r | ForEach-Object { "$($_.Check)=$($_.Result)" }) -join ' ') 'TPM 2.0=Pass UEFI=Pass Secure Boot=Pass Processor=Pass Memory=Pass Disk=Pass' 'supported PC passes every check'

function Test-One($Change, $Check) {
    $f = $good.PSObject.Copy()
    foreach ($k in $Change.Keys) { $f.$k = $Change[$k] }
    $row = Test-Win11Readiness -Facts $f | Where-Object Check -eq $Check
    "$($row.Result)"
}
Assert-Equal (Test-One @{ TpmPresent = $false } 'TPM 2.0') 'Fail' 'no TPM fails'
Assert-Equal (Test-One @{ TpmSpecVersion = '1.2, 2, 3' } 'TPM 2.0') 'Fail' 'TPM 1.2 fails'
Assert-Equal (Test-One @{ TpmEnabled = $false } 'TPM 2.0') 'Fail' 'TPM turned off fails'
Assert-Equal (Test-One @{ TpmPresent = $false; TpmError = 'Access denied' } 'TPM 2.0') 'Warn' 'unreadable TPM only warns'
Assert-Equal (Test-One @{ IsUefi = $false } 'UEFI') 'Fail' 'legacy BIOS boot fails'
Assert-Equal (Test-One @{ SecureBootOn = $false } 'Secure Boot') 'Warn' 'Secure Boot off only warns (capable is enough)'
Assert-Equal (Test-One @{ CpuName = 'Intel(R) Core(TM) i7-6700 CPU' } 'Processor') 'Fail' 'old processor fails'
Assert-Equal (Test-One @{ CpuName = 'Intel(R) Celeron(R) N4020' } 'Processor') 'Warn' 'unmatched processor only warns'
Assert-Equal (Test-One @{ CpuCores = 1 } 'Processor') 'Fail' 'single core fails'
Assert-Equal (Test-One @{ MemoryGB = 3.9 } 'Memory') 'Pass' '4 GB that reads as 3.9 passes'
Assert-Equal (Test-One @{ MemoryGB = 2 } 'Memory') 'Fail' '2 GB fails'
Assert-Equal (Test-One @{ DiskGB = 32 } 'Disk') 'Fail' '32 GB disk fails'

# Image detection.
Assert-Equal (Test-Win11Image -ImagePath 'Images\x.wim' -ImageInfo ([pscustomobject]@{ Version = '10.0.26100.1742'; ImageName = 'Windows Enterprise' })) 'True' 'build 26100 is Windows 11'
Assert-Equal (Test-Win11Image -ImagePath 'Images\x.wim' -ImageInfo ([pscustomobject]@{ Version = '10.0.19045.4651'; ImageName = 'Windows 10 Enterprise' })) 'False' 'build 19045 is Windows 10'
Assert-Equal (Test-Win11Image -ImagePath 'Images\Win11-Enterprise.wim' -ImageInfo ([pscustomobject]@{ ImageName = 'Golden' })) 'True' 'file name is used when the version is missing'
Assert-Equal "$(Test-Win11Image -ImagePath 'Images\Golden.wim' -ImageInfo ([pscustomobject]@{ ImageName = 'Golden' }))" '' 'unknown image returns null'

# Decision.
$bad = @(Test-Win11Readiness -Facts ($good.PSObject.Copy() | ForEach-Object { $_.TpmPresent = $false; $_ }))
Assert-Equal (Get-Win11ReadinessDecision -Mode Block -IsWin11 $true -Results $bad).Action 'Block' 'Block mode stops a failing PC'
Assert-Equal (Get-Win11ReadinessDecision -Mode Block -IsWin11 $true -Results $bad).Summary 'NOT READY: TPM 2.0' 'summary names the failed checks'
Assert-Equal (Get-Win11ReadinessDecision -Mode Warn -IsWin11 $true -Results $bad).Action 'Proceed' 'Warn mode carries on'
Assert-Equal (Get-Win11ReadinessDecision -Mode Block -IsWin11 $true -Results $bad -Override).Action 'Proceed' 'override carries on'
Assert-Equal (Get-Win11ReadinessDecision -Mode Block -IsWin11 $null -Results $bad).Action 'Proceed' 'unknown image never blocks'
Assert-Equal (Get-Win11ReadinessDecision -Mode Block -IsWin11 $true -Results $r).Summary 'ready' 'passing PC is ready'

# Answer file setting: default, validation and round trip.
$default = Read-AnswerFile -Path (Join-Path $repo 'config/answer-files/Default.xml')
Assert-Equal $default.Windows11Check 'Block' 'sample answer file blocks unsupported PCs'
$a = $default.PSObject.Copy(); $a.Windows11Check = 'Sometimes'
Assert-Equal ((@(Test-AnswerFile $a)) -join '') "image/windows11Check must be Block, Warn or Off, not 'Sometimes'." 'bad check mode is rejected'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("win11-test-" + [guid]::NewGuid() + '.xml')
try {
    $a.Windows11Check = 'Warn'
    Export-AnswerFile -Answer $a -Path $tmp
    Assert-Equal (Read-AnswerFile -Path $tmp).Windows11Check 'Warn' 'check mode survives export and re-read'
}
finally { Remove-Item $tmp -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
