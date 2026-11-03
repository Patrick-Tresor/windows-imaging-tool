# Plain-PowerShell tests for keeping passwords off the USB stick: the WinPE password vault (SecretVault.psm1),
# leaving config\secrets out of the stick's copy, and the WinPE password prompt wiring in the build and deploy.
# Run: pwsh -File tests/SecretVault.Tests.ps1. Works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/MediaContent.psm1') -Force
Import-Module (Join-Path $repo 'src/MediaCopy.psm1') -Force
Import-Module (Join-Path $repo 'src/SecretVault.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Paths agree between the build (Windows paths) and WinPE whatever the case or slashes.
Assert-Equal (ConvertTo-SecretKey 'config/secrets/Staff-Join.txt') 'config\secrets\staff-join.txt' 'key: slashes and case'
Assert-Equal (ConvertTo-SecretKey '.\config\secrets\a.txt') 'config\secrets\a.txt' 'key: leading .\ dropped'

# Round trip through JSON, as the build writes it and WinPE reads it. Few iterations: the test, not the PC, is slow.
$accent = 'p@ss ' + [char]0xE9
$v = New-SecretVault -Password 'correct horse' -Secrets @{ 'config\secrets\Staff-join.txt' = $accent; 'config/secrets/share-z.txt' = 'z' } -Iterations 1000
$json = $v | ConvertTo-Json
Assert-Equal ($json -match [regex]::Escape($accent)) $false 'the vault file does not hold a password in plain text'
Assert-Equal ($json -match 'Staff-join') $false 'nor the file names'
$read = $json | ConvertFrom-Json
$open = Unlock-SecretVault -Vault $read -Password 'correct horse'
Assert-Equal $open['config\secrets\staff-join.txt'] $accent 'right password: the join password, accent kept'
Assert-Equal $open['config\secrets\share-z.txt'] 'z' 'right password: the share password'
Assert-Equal $open.Count 2 'right password: every password file'
Assert-Equal ($null -eq (Unlock-SecretVault -Vault $read -Password 'Correct horse')) $true 'wrong password: nothing'
Assert-Equal ($null -eq (Unlock-SecretVault -Vault $read -Password '')) $true 'empty password: nothing'
$tampered = $json | ConvertFrom-Json
$bytes = [Convert]::FromBase64String($tampered.data); $bytes[0] = $bytes[0] -bxor 1
$tampered.data = [Convert]::ToBase64String($bytes)
Assert-Equal ($null -eq (Unlock-SecretVault -Vault $tampered -Password 'correct horse')) $true 'changed file: nothing'
$empty = New-SecretVault -Password 'correct horse' -Iterations 1000 | ConvertTo-Json | ConvertFrom-Json
Assert-Equal (Unlock-SecretVault -Vault $empty -Password 'correct horse').Count 0 'no password files: unlocks, empty'
$short = try { New-SecretVault -Password 'short' -Iterations 1000; 'made' } catch { 'refused' }
Assert-Equal $short 'refused' 'a WinPE password under 8 characters is refused'
Assert-Equal ((New-SecretVault -Password 'correct horse' -Iterations 1000).salt -ne (New-SecretVault -Password 'correct horse' -Iterations 1000).salt) $true 'a new salt every build'

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-secrets-" + [guid]::NewGuid())
try {
    Initialize-ContentRoot -Path $root
    Set-Content (Join-Path $root 'Images/Win11-Enterprise.wim') 'wim'
    $secrets = Join-Path $root 'config/secrets'
    New-Item -ItemType Directory -Path $secrets -Force | Out-Null
    Set-Content (Join-Path $secrets 'Default-join.txt') 'JoinPw1' -NoNewline
    Set-Content (Join-Path $root 'config/share.txt') 'SharePw' -NoNewline
    $settings = Join-Path $root 'config/deploy-settings.json'
    $s = Get-Content -Raw $settings | ConvertFrom-Json
    $s.share | Add-Member -NotePropertyName user -NotePropertyValue 'CORP\svc' -Force
    $s.share | Add-Member -NotePropertyName passwordFile -NotePropertyValue 'config\share.txt' -Force
    $s | ConvertTo-Json -Depth 6 | Set-Content $settings

    # What goes into the vault: config\secrets and the share account's password file.
    $found = Get-ContentSecrets -ContentRoot $root -SettingsPath $settings
    Assert-Equal $found['config\secrets\default-join.txt'] 'JoinPw1' 'vault gets config\secrets'
    Assert-Equal $found['config\share.txt'] 'SharePw' 'vault gets the share password file from the settings'

    # The stick: config is copied, config\secrets is not, unless asked for.
    $c = Get-MediaContent -ContentRoot $root
    Assert-Equal ($c.Exclude -join ';') 'config\secrets' 'secrets left out by default'
    Assert-Equal (($c.Notes -join ' ') -like '*Password files (config\secrets) are not copied*') $true 'and the build says so'
    $plan = Get-MediaCopyPlan -ContentRoot $root -Folders $c.Folders -Files $c.Files -Exclude $c.Exclude
    Assert-Equal (@($plan.Items | Where-Object { $_.Relative -like 'config\secrets*' }).Count) 0 'no password file in the copy'
    Assert-Equal (@($plan.Directories | Where-Object { $_ -like 'config\secrets*' }).Count) 0 'not even the empty folder'
    Assert-Equal (@($plan.Items | Where-Object Relative -eq 'config\deploy-settings.json').Count) 1 'the rest of config is copied'
    $with = Get-MediaContent -ContentRoot $root -IncludeSecrets
    Assert-Equal $with.Exclude.Count 0 '-IncludeSecrets: nothing left out'
    $plan = Get-MediaCopyPlan -ContentRoot $root -Folders $with.Folders -Files $with.Files -Exclude $with.Exclude
    Assert-Equal (@($plan.Items | Where-Object { $_.Relative -eq 'config\secrets\Default-join.txt' }).Count) 1 '-IncludeSecrets: password files copied'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# Wiring: the deploy asks for the WinPE password before anything else and takes every password through
# Get-DeploySecret; startnet.cmd gives no command prompt after a refused WinPE password.
$deploy = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
$unlockAt = [regex]::Match($deploy, '(?m)^Unlock-DeployMedia\s*$').Index
Assert-Equal ($unlockAt -gt 0 -and $unlockAt -lt $deploy.IndexOf('Find-ContentRoot -SettingsPath')) $true 'WinPE password asked before the content is looked for'
Assert-Equal ([regex]::Matches($deploy, 'Read-SecretFile -ContentRoot \$root').Count) 0 'no password read straight from the media in the deploy'
Assert-Equal ($deploy -match 'exit 3') $true 'refused WinPE password exits 3'
$startnet = Get-Content -Raw (Join-Path $repo 'winpe/startnet.cmd')
Assert-Equal ($startnet.IndexOf('if errorlevel 3') -lt $startnet.IndexOf('Deployment failed')) $true 'startnet: exit 3 checked before the command prompt'
$build = Get-Content -Raw (Join-Path $repo 'src/New-DeploymentMedia.ps1')
Assert-Equal ($build -match 'winpeshl\.ini') $true 'locked media start the shell with cmd /c'

# Get-AnswerSecrets: every password an answer file needs, once each, so the wizard asks for all of them on one
# page before Confirm and nothing pops up while Windows installs.
$full = [pscustomobject]@{
    EnableAdministrator = $true; AdminPasswordFile = 'config\secrets\admin.txt'
    Membership = 'Domain'; Domain = 'corp.example.com'; JoinUser = 'CORP\svc-join'; JoinDomain = ''; JoinPasswordFile = 'config\secrets\Join.txt'
    Shares = @([pscustomobject]@{ LocalName = 'Y:'; RemoteName = '\\srv\images'; Username = 'svc-read'; PasswordFile = 'config/secrets/share.txt' },
               [pscustomobject]@{ LocalName = 'Z:'; RemoteName = '\\srv\apps'; Username = 'svc-join'; PasswordFile = 'config\secrets\join.txt' })
    BitLocker = [pscustomobject]@{ Enabled = $true; Protector = 'TpmPin'; PinFile = 'config\secrets\pin.txt' }
}
$needed = @(Get-AnswerSecrets -Answer $full)
Assert-Equal (($needed | ForEach-Object Key) -join ',') 'config\secrets\admin.txt,config\secrets\join.txt,config\secrets\share.txt,config\secrets\pin.txt' 'answer secrets: every password once, the shared join file only once'
Assert-Equal $needed[1].Label 'Join account password (CORP\svc-join)' 'answer secrets: the join account is named'
Assert-Equal "$($needed[2].Share)|$($needed[0].Share)" 'Y:|' 'answer secrets: share passwords say which drive'
$bare = [pscustomobject]@{
    EnableAdministrator = $false; AdminPasswordFile = 'config\secrets\admin.txt'; Membership = 'Workgroup'; JoinPasswordFile = 'config\secrets\join.txt'
    Shares = @(); BitLocker = [pscustomobject]@{ Enabled = $true; Protector = 'Tpm'; PinFile = 'config\secrets\pin.txt' }
}
Assert-Equal @(Get-AnswerSecrets -Answer $bare).Count 0 'answer secrets: nothing for settings that are off'

# Wiring: the wizard gets the missing passwords up front, the plan asks for any left in one window, and
# every password the deploy reads is one Get-AnswerSecrets knows about.
Assert-Equal ($deploy -match '-MissingSecrets \$missingSecrets -SaveSecrets \$saveSecrets') $true 'wizard is given the missing passwords'
$planAt = $deploy.IndexOf('function Get-DeployPlan(')
Assert-Equal ($deploy.IndexOf('Request-DeploySecrets -Root $Root -Answer $Answer', $planAt) -lt $deploy.IndexOf('foreach ($share in $Answer.Shares)', $planAt)) $true 'plan asks for missing passwords before mapping shares'
foreach ($m in [regex]::Matches($deploy, 'Get-DeploySecret(?:Path)? -Root \$\w+ -RelativePath \$(\w+(?:\.\w+)+)')) {
    $field = ($m.Groups[1].Value -split '\.')[-1]
    Assert-Equal ((Get-Content -Raw (Join-Path $repo 'src/SecretVault.psm1')) -match [regex]::Escape(".$field")) $true "answer secrets cover $($m.Groups[1].Value)"
}

# Passwords kept in the answer file, encrypted with the content root's answer file key.
$key = New-AnswerKey
$other = New-AnswerKey
$enc = Protect-AnswerPassword -Password $accent -Key $key
Assert-Equal (Test-AnswerPasswordText $enc) $true 'answer password: the encrypted form is recognized'
Assert-Equal ($enc -match [regex]::Escape($accent)) $false 'answer password: no plain text'
Assert-Equal (Get-AnswerPasswordKeyId $enc) (Get-AnswerKeyId $key) 'answer password: names the key it was made with'
Assert-Equal (Unprotect-AnswerPassword -Value $enc -Key $key) $accent 'answer password: decrypts with the key, accent kept'
Assert-Equal ((Protect-AnswerPassword -Password $accent -Key $key) -ne $enc) $true 'answer password: same password, different text each time'
Assert-Equal (Unprotect-AnswerPassword -Value (Protect-AnswerPassword -Password '' -Key $key) -Key $key) '' 'answer password: an empty password round trips'
$msg = try { Unprotect-AnswerPassword -Value $enc -Key $other; '' } catch { $_.Exception.Message }
Assert-Equal ($msg -like '*another answer file key*') $true 'answer password: another key is named as such'
$parts = $enc -split ':'
$b = [Convert]::FromBase64String($parts[2]); $b[20] = $b[20] -bxor 1
$msg = try { Unprotect-AnswerPassword -Value "$($parts[0]):$($parts[1]):$([Convert]::ToBase64String($b))" -Key $key; '' } catch { $_.Exception.Message }
Assert-Equal ($msg -like '*was changed*') $true 'answer password: a changed byte is caught'
$msg = try { Protect-AnswerPassword -Password 'x' -Key 'bm90IGEga2V5'; '' } catch { $_.Exception.Message }
Assert-Equal ($msg -like '*not valid*') $true 'answer password: a broken key file is refused'

# Unattend.xml-style "encryption" is only base64; this is not. The answer file round trip keeps the encrypted values.
$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-answerpw-" + [guid]::NewGuid())
try {
    Initialize-ContentRoot -Path $root
    Assert-Equal ($null -eq (Get-AnswerKey -ContentRoot $root)) $true 'answer key: none until one is needed'
    $k1 = Get-AnswerKey -ContentRoot $root -Create
    Assert-Equal (Get-AnswerKey -ContentRoot $root -Create) $k1 'answer key: made once, then reused'
    Assert-Equal (Test-Path (Join-Path $root 'config/secrets/answer-key.txt')) $true 'answer key: kept in config\secrets (left off the stick)'

    # Find-AnswerKey, as WinPE runs it: vault first, then boot.wim (X:\Deploy\config), then the content root.
    $pe = Join-Path $root 'pe'; New-Item -ItemType Directory -Path (Join-Path $pe 'config') -Force | Out-Null
    Assert-Equal (Find-AnswerKey -ScriptRoot $pe -ContentRoot $root) $k1 'find key: from the content root (network share)'
    [IO.File]::WriteAllText((Join-Path $pe 'config/answer-key.txt'), $key)
    Assert-Equal (Find-AnswerKey -ScriptRoot $pe -ContentRoot $root) $key 'find key: boot.wim copy first'
    Assert-Equal (Find-AnswerKey -Vault @{ 'config\secrets\answer-key.txt' = $other } -ScriptRoot $pe -ContentRoot $root) $other 'find key: the WinPE password vault first'
    Assert-Equal ($null -eq (Find-AnswerKey -ScriptRoot (Join-Path $root 'nowhere') -ContentRoot 'Q:\')) $true 'find key: nothing, no error, for a missing drive'

    # Sync: the password files an answer file names go into it, encrypted, keeping its comments.
    $af = Join-Path $root 'AnswerFiles/Default.xml'
    $xml = [IO.File]::ReadAllText($af) -replace '<membership>Workgroup</membership>', '<membership>Domain</membership>'
    [IO.File]::WriteAllText($af, $xml)
    Set-Content (Join-Path $root 'config/secrets/join.txt') 'J0in pw' -NoNewline
    $lines = @(Sync-AnswerFilePasswords -ContentRoot $root)
    Assert-Equal $lines.Count 1 'sync: one answer file updated'
    $raw = [IO.File]::ReadAllText($af)
    Assert-Equal ($raw -match 'J0in pw') $false 'sync: no plain password in the answer file'
    Assert-Equal ($raw -match 'Passwords|everything one deployment needs') $true 'sync: comments kept'
    $a = Read-AnswerFile -Path $af -SkipValidation
    Assert-Equal (Unprotect-AnswerPassword -Value $a.JoinPasswordEncrypted -Key $k1) 'J0in pw' 'sync: the join password is in the answer file'
    Assert-Equal "$($a.AdminPasswordEncrypted)" '' 'sync: no password file, nothing added'
    Assert-Equal @(Sync-AnswerFilePasswords -ContentRoot $root).Count 0 'sync: nothing to do the second time'
    Set-Content (Join-Path $root 'config/secrets/join.txt') 'N3w pw' -NoNewline
    $null = Sync-AnswerFilePasswords -ContentRoot $root
    Assert-Equal (Unprotect-AnswerPassword -Value (Read-AnswerFile -Path $af -SkipValidation).JoinPasswordEncrypted -Key $k1) 'N3w pw' 'sync: a changed password file updates the answer file'
    $null = Sync-AnswerFilePasswords -ContentRoot $root -Names 'Other'
    Assert-Equal @(Get-AnswerSecrets -Answer $a)[0].Encrypted $a.JoinPasswordEncrypted 'answer secrets: carry the encrypted password'

    # Export-AnswerFile (the editor's save) keeps the encrypted values; the stick needs no password file.
    $a = Read-AnswerFile -Path $af -SkipValidation
    $a.Shares = @([pscustomobject]@{ LocalName = 'Y:'; RemoteName = '\\srv\apps'; Username = 'svc'; Domain = ''; PasswordFile = 'config\secrets\y.txt'; PasswordEncrypted = (Protect-AnswerPassword -Password 'Sh' -Key $k1) })
    $a.BitLocker | Add-Member -NotePropertyName PinEncrypted -NotePropertyValue (Protect-AnswerPassword -Password '123456' -Key $k1) -Force
    $a | Add-Member -NotePropertyName AdminPasswordEncrypted -NotePropertyValue (Protect-AnswerPassword -Password 'Adm' -Key $k1) -Force
    $out = Join-Path $root 'AnswerFiles/Copy.xml'
    Export-AnswerFile -Answer $a -Path $out
    $c = Read-AnswerFile -Path $out -SkipValidation
    $vals = foreach ($v in $c.JoinPasswordEncrypted, $c.AdminPasswordEncrypted, $c.Shares[0].PasswordEncrypted, $c.BitLocker.PinEncrypted) { Unprotect-AnswerPassword -Value $v -Key $k1 }
    Assert-Equal ($vals -join '|') 'N3w pw|Adm|Sh|123456' 'export: every encrypted password survives export and read'
    $plain = Join-Path $root 'AnswerFiles/Plain.xml'
    $c.JoinPasswordEncrypted = ''; $c.AdminPasswordEncrypted = ''; $c.Shares[0].PasswordEncrypted = ''; $c.BitLocker.PinEncrypted = ''
    Export-AnswerFile -Answer $c -Path $plain
    Assert-Equal ([IO.File]::ReadAllText($plain) -match 'encrypted') $false 'export: no empty encrypted elements'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# Wiring: the build puts the passwords into the answer files before the stick is planned, and the key into boot.wim;
# the deploy decrypts them when it reads the answer file.
Assert-Equal ($build.IndexOf('Sync-AnswerFilePasswords') -lt $build.IndexOf('$content = Get-MediaContent')) $true 'build: passwords into the answer files before the stick content is planned'
Assert-Equal ($build -match 'deployDir\\config\\answer-key\.txt') $true 'build: answer file key into boot.wim without a WinPE password'
Assert-Equal ($build.IndexOf('$answerKey = Get-AnswerKey') -lt $build.IndexOf('Get-ContentSecrets -ContentRoot $secretRoot')) $true 'build: key known before the vault (which then holds it)'
$readAt = $deploy.IndexOf('function Read-DeployAnswer(')
Assert-Equal ($deploy.IndexOf('Add-AnswerPasswords -Root $Root -Answer $a', $readAt) -gt $readAt) $true 'deploy: answer file passwords decrypted when it is read'
Assert-Equal ([regex]::Matches($deploy, 'Get-DeploySecret -Root \$\w+ -RelativePath \S+ -Label').Count) 0 'deploy: every Get-DeploySecret is given the answer'

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All secret vault checks passed' -ForegroundColor Green
