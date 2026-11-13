# Tests for the Deploy Settings page's data side (ConsoleData.psm1): USB only or network share, the share account's
# password file, the checks before saving, and the share connection test. Run: pwsh -File tests/DeploySettings.Tests.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
Import-Module (Join-Path $repo 'src/SecretVault.psm1') -Force
$common = Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force -PassThru

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
$onWindows = $env:OS -eq 'Windows_NT'

Assert-Equal (Get-UncRoot '\\srv01\Deploy\Status') '\\srv01\Deploy' 'UNC root of a sub folder'
Assert-Equal (Get-UncRoot 'D:\Deploy') '' 'a local path has no UNC root'
Assert-Equal (Test-ExampleShare '\\deploy-server\Deploy') $true 'the repo example share is spotted'
Assert-Equal (Test-ExampleShare '\\SRV01\Deploy') $false 'a real server is not an example'
Assert-Equal (Get-ShareErrorText 1326) 'wrong user name or password' 'net use 1326 in words'

# Checks before saving: one short sentence per problem.
$p = @(Get-DeploySettingsProblems -Mode Usb)
Assert-Equal $p.Count 0 'USB only with nothing else: nothing to fix'
$p = @(Get-DeploySettingsProblems -Mode Share -SharePath '\\deploy-server\Deploy' -ShareUser 'DOMAIN\svc-deploy' -PasswordSaved $true)
Assert-Equal $p.Count 2 'the example share and account are both refused'
Assert-Equal ($p[0] -like '*example value*') $true 'and called the example value'
$p = @(Get-DeploySettingsProblems -Mode Share -SharePath 'SRV01\Deploy')
Assert-Equal ($p[0] -like '*must look like \\SERVER01\Deploy*') $true 'a share without \\ is refused'
$p = @(Get-DeploySettingsProblems -Mode Share -SharePath '\\SRV01\Deploy' -ShareUser 'svc-deploy')
Assert-Equal ($p[0] -like '*DOMAIN\user or user@domain.com*') $true 'an account without a domain is refused'
$p = @(Get-DeploySettingsProblems -Mode Share -SharePath '\\SRV01\Deploy' -ShareUser 'CORP\svc-deploy')
Assert-Equal ($p[0]) 'Type the password of CORP\svc-deploy.' 'an account with no password saved needs one'
$p = @(Get-DeploySettingsProblems -Mode Share -SharePath '\\SRV01\Deploy' -ShareUser 'svc-deploy@corp.example.com' -NewPassword 'x')
Assert-Equal $p.Count 0 'a UPN account with a typed password is fine'
$p = @(Get-DeploySettingsProblems -Mode Usb -ReportElsewhere $true -ReportPath '')
Assert-Equal ($p[0] -like 'Type the share PCs report to*') $true 'a Dashboard share must be typed when chosen'
$p = @(Get-DeploySettingsProblems -Mode Usb -ShareUser 'DOMAIN\x')
Assert-Equal $p.Count 0 'USB only ignores the account'
$p = @(Get-DeploySettingsProblems -Mode Usb -VersionsToKeep 'two')
Assert-Equal ($p[0] -like 'Older image versions*') $true 'versions to keep must be a number'

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-settings-" + [guid]::NewGuid())
try {
    Initialize-ContentRoot -Path $root
    $settingsFile = Join-ContentPath $root 'config\deploy-settings.json'
    $v = Get-DeploySettingsView -ContentRoot $root
    Assert-Equal $v.Mode 'Share' 'the example settings read as a network share'
    Assert-Equal $v.PasswordSaved $false 'no password file yet'

    # The old default: the password in config\share.cred. Saving encrypts it into the settings and deletes the file.
    $s = Get-DeploySettings -ContentRoot $root
    $s.share | Add-Member -NotePropertyName passwordFile -NotePropertyValue 'config\share.cred' -Force
    Save-DeploySettings -ContentRoot $root -Settings $s
    Set-Content -LiteralPath (Join-ContentPath $root 'config\share.cred') -Value 'Old-Pass1' -NoNewline
    Assert-Equal (Get-DeploySettingsView -ContentRoot $root).PasswordSaved $true 'a password in the old file counts as saved'
    $r = Save-DeploySettingsPage -ContentRoot $root -Mode Share -SharePath '\\SRV01\Deploy\' -ShareUser 'CORP\svc-deploy' -VersionsToKeep 3
    $s = Get-DeploySettings -ContentRoot $root
    Assert-Equal $s.share.path '\\SRV01\Deploy' 'share saved without the trailing backslash'
    Assert-Equal ($null -eq $s.share.PSObject.Properties['passwordFile']) $true 'no passwordFile in the settings any more'
    Assert-Equal (Test-Path -LiteralPath (Join-ContentPath $root 'config\share.cred')) $false 'the old plain file is deleted'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-ContentPath $root 'config\secrets') -File | Where-Object Name -ne 'answer-key.txt').Count) 0 'and no new password file is made'
    Assert-Equal ($s.share.encryptedPassword -like 'aes256:*') $true 'the password is in the settings, encrypted'
    Assert-Equal ((Get-Content -Raw $settingsFile) -like '*Old-Pass1*') $false 'never as plain text'
    Assert-Equal (Get-SharePassword -ContentRoot $root) 'Old-Pass1' 'and decrypts to the same password'
    Assert-Equal (Get-DeploySettingsView -ContentRoot $root).PasswordSaved $true 'the page shows it as saved'
    Assert-Equal $s.versionsToKeep 3 'versions to keep saved'
    Assert-Equal $r.MediaOutOfDate $true 'a new share means the stick needs updating'

    $r = Save-DeploySettingsPage -ContentRoot $root -Mode Share -SharePath '\\SRV01\Deploy' -ShareUser 'CORP\svc-deploy' -VersionsToKeep 2
    Assert-Equal $r.MediaOutOfDate $false 'only the versions changed: the stick is still up to date'
    Assert-Equal (Get-SharePassword -ContentRoot $root) 'Old-Pass1' 'saving again keeps the password'
    $r = Save-DeploySettingsPage -ContentRoot $root -Mode Share -SharePath '\\SRV01\Deploy' -ShareUser 'CORP\svc-deploy' -NewPassword 'N3w-Pass!' -VersionsToKeep 2
    Assert-Equal $r.MediaOutOfDate $true 'a new password means the stick needs updating'
    Assert-Equal (Get-SharePassword -ContentRoot $root) 'N3w-Pass!' 'the typed password is saved'

    # WinPE reads it from the boot image's copy of the settings with the answer file key, no passwordFile needed.
    & $common { param($p) $script:LogPath = $p } (Join-Path $root 'test.log')
    $key = Get-AnswerKey -ContentRoot $root
    $cred = Get-ShareCredential -SettingsPath $settingsFile -Decrypt { param($v) Unprotect-AnswerPassword -Value $v -Key $key }
    Assert-Equal "$($cred.User)|$($cred.Password)" 'CORP\svc-deploy|N3w-Pass!' 'WinPE decrypts the share password from the settings'

    # USB only: no share, no account; the encrypted password stays so switching back finds it.
    $null = Save-DeploySettingsPage -ContentRoot $root -Mode Usb -SharePath '\\SRV01\Deploy' -ShareUser 'CORP\svc-deploy'
    $s = Get-DeploySettings -ContentRoot $root
    Assert-Equal "$($s.share.path)|$($s.share.user)" '|' 'USB only clears the share and account'
    $v = Get-DeploySettingsView -ContentRoot $root
    Assert-Equal "$($v.Mode) $($v.PasswordSaved)" 'Usb True' 'and reads back as USB only, password still there'

    # USB deploys that report to a server keep the account for the Status share.
    $null = Save-DeploySettingsPage -ContentRoot $root -Mode Usb -ShareUser 'CORP\svc-deploy' -ReportPath '\\SRV01\Deploy\Status'
    $s = Get-DeploySettings -ContentRoot $root
    Assert-Equal "$($s.share.path)|$($s.share.user)|$($s.reporting.path)" '|CORP\svc-deploy|\\SRV01\Deploy\Status' 'USB with a Dashboard share keeps the account'

    if ($onWindows) {
        # The connection test on a local folder (no account): the Status folder is created and written.
        $content = Join-Path $root 'share'
        New-Item -ItemType Directory -Path (Join-Path $content 'Images') -Force | Out-Null
        $t = Test-ShareConnection -SharePath $content
        Assert-Equal $t.Ok $true 'connection test passes on a writable folder'
        Assert-Equal (Test-Path (Join-Path $content 'Status')) $true 'and creates the Status folder'
        Assert-Equal (@(Get-ChildItem (Join-Path $content 'Status') -Force).Count) 0 'leaving no test file behind'
        $t = Test-ShareConnection -SharePath (Join-Path $root 'missing')
        Assert-Equal $t.Ok $false 'a missing folder fails'

        # A refused sign-in, from a stand-in for net.exe.
        $fake = Join-Path $root 'net.cmd'
        Set-Content -LiteralPath $fake -Encoding ascii -Value "@echo off`r`nif `"%2`"==`"`" exit /b 0`r`necho System error 1326 has occurred.`r`nexit /b 2"
        $t = Test-ShareConnection -SharePath '\\SRV01\Deploy' -User 'CORP\svc-deploy' -Password 'bad' -NetExe $fake
        Assert-Equal $t.Message 'Could not connect to \\SRV01\Deploy: wrong user name or password.' 'a refused sign-in is one line'
        $t = Test-ShareConnection -SharePath '\\SRV01\Deploy' -User 'CORP\svc-deploy' -NetExe $fake
        Assert-Equal ($t.Message -like 'No password for*') $true 'no password: not even tried'
    }
} finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# Every control the console script uses is in MainWindow.xaml (a renamed box would be $null at startup).
$xamlText = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Console/MainWindow.xaml')
$names = @([regex]::Matches($xamlText, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$consoleText = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Console/ImagingConsole.ps1')
$used = @([regex]::Matches($consoleText, '\$ui\.([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-Equal (@($used | Where-Object { $_ -notin $names }) -join ', ') '' 'every $ui control exists in MainWindow.xaml'
foreach ($n in 'RbSettingsUsb', 'RbSettingsShare', 'PwdShare', 'BtnShareTest', 'RbReportShare', 'BdrSettingsStale') {
    Assert-Equal ($n -in $names) $true "Deploy Settings has $n"
}
Assert-Equal ($names -contains 'TxtSharePwFile') $false 'no password file box any more'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
