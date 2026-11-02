# Plain-PowerShell tests for the join account check in WinPE (Test-JoinAccount) and for reading password files.
# Run: pwsh -File tests/JoinCheck.Tests.ps1. A fake net.exe stands in for the domain, so it runs anywhere.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# net use's error number.
Assert-Equal (Get-NetUseErrorCode -Output @('System error 1326 has occurred.', '', 'The user name or password is incorrect.')) 1326 'net use: the error number in English'
Assert-Equal (Get-NetUseErrorCode -Output @('Systemfehler 53 aufgetreten.')) 53 'net use: the first number in another language'
Assert-Equal (Get-NetUseErrorCode -Output @()) -1 'net use: no output, no number'

# What each answer means. Only a domain that answered and turned the account down stops the deploy.
$r = Get-JoinCheckResult -Code 1326
Assert-Equal "$($r.Result)|$($r.Reason)" 'Refused|wrong user name or password' 'wrong user name or password is refused'
Assert-Equal (Get-JoinCheckResult -Code 1909).Result 'Refused' 'a locked out account is refused'
Assert-Equal (Get-JoinCheckResult -Code 1330).Result 'Refused' 'an expired password is refused'
Assert-Equal (Get-JoinCheckResult -Code 0).Result 'Passed' 'signed in'
Assert-Equal "$((Get-JoinCheckResult -Code 53).Result)|$((Get-JoinCheckResult -Code 53).Reason)" 'NotChecked|could not reach the domain from WinPE (network or DNS)' 'an unreachable domain is only noted'
Assert-Equal (Get-JoinCheckResult -Code 1937).Result 'NotChecked' 'NTLM blocked for WinPE does not stop the deploy'
Assert-Equal (Get-JoinCheckResult -Code 87).Result 'NotChecked' 'an unknown error does not stop the deploy'

# Signing in: once per account and password, so the wizard's Next costs no more failed logons.
$global:NetCalls = @()
function global:Invoke-FakeNet {
    $global:NetCalls += ($args -join ' ')
    if ($args -contains '/delete') { $global:LASTEXITCODE = 0; return }
    if ($args[2] -eq 'good') { $global:LASTEXITCODE = 0; 'The command completed successfully.' }
    else { $global:LASTEXITCODE = 2; 'System error 1326 has occurred.'; ''; 'The user name or password is incorrect.' }
}
$r = Test-JoinAccount -Domain 'corp.example.com' -Account 'CORP\svc' -Password 'bad' -NetExe 'Invoke-FakeNet'
Assert-Equal "$($r.Result)|$($r.Code)|$($r.Cached)" 'Refused|1326|False' 'a wrong password is refused'
Assert-Equal $global:NetCalls[0] 'use \\corp.example.com\IPC$ bad /user:CORP\svc /persistent:no' 'signs in to the domain as the join account'
$r = Test-JoinAccount -Domain 'corp.example.com' -Account 'CORP\svc' -Password 'bad' -NetExe 'Invoke-FakeNet'
Assert-Equal "$($r.Result)|$($r.Cached)|$($global:NetCalls.Count)" 'Refused|True|1' 'the same wrong password is not tried again'
$r = Test-JoinAccount -Domain 'corp.example.com' -Account 'CORP\svc' -Password 'good' -NetExe 'Invoke-FakeNet'
Assert-Equal "$($r.Result)|$($r.Cached)|$($global:NetCalls.Count)" 'Passed|False|3' 'a new password is tried, signs in, then disconnects'
Assert-Equal $global:NetCalls[2] 'use \\corp.example.com\IPC$ /delete /y' 'the connection is removed after the check'
$r = Test-JoinAccount -Domain 'corp.example.com' -Account 'CORP\svc' -Password '' -NetExe 'Invoke-FakeNet'
Assert-Equal "$($r.Result)|$($global:NetCalls.Count)" 'NotChecked|3' 'an empty password is not tried (net use would ask for one and hang)'
function global:Invoke-FakeNet { throw 'System error 53 has occurred.' }
$r = Test-JoinAccount -Domain 'other.example.com' -Account 'OTHER\svc' -Password 'x' -NetExe 'Invoke-FakeNet'
Assert-Equal "$($r.Result)|$($r.Code)" 'NotChecked|53' 'an error thrown by net use is classified, not passed on'

# Password files, whatever saved them. An e with an acute accent is the usual victim.
$e = [char]0xE9
$want = "Caf$($e)-2026"
Assert-Equal (ConvertFrom-SecretBytes ([byte[]](@(0xEF, 0xBB, 0xBF) + @([Text.Encoding]::UTF8.GetBytes($want))))) $want 'password file: UTF-8 with a BOM (the console)'
Assert-Equal (ConvertFrom-SecretBytes ([Text.Encoding]::UTF8.GetBytes($want))) $want 'password file: UTF-8 without a BOM (Notepad on Windows 11)'
Assert-Equal (ConvertFrom-SecretBytes ([byte[]](@(0xFF, 0xFE) + @([Text.Encoding]::Unicode.GetBytes($want))))) $want 'password file: UTF-16 (Unicode in older Notepad)'
Assert-Equal (ConvertFrom-SecretBytes ([byte[]](0x43, 0x61, 0x66, 0xE9, 0x2D, 0x32, 0x30, 0x32, 0x36))) $want 'password file: ANSI (older Notepad)'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("secret-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $tmp 'config/secrets') -Force | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $tmp 'config/secrets/join.txt'), "$want`r`n", [Text.UTF8Encoding]::new($false))
    Assert-Equal (Read-SecretFile -ContentRoot $tmp -RelativePath 'config\secrets\join.txt') $want 'Read-SecretFile: BOM-less UTF-8 with a line break reads back the password'
}
finally { Remove-Item -Recurse -Force $tmp }

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All join check tests passed.' -ForegroundColor Green
