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

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

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

    # The share password is in the boot image's settings, encrypted with the answer file key; WinPE decrypts it
    # (Get-ShareCredential -Decrypt). A plain password file is never read, even when it is there.
    Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force
    $key = New-AnswerKey
    $peDir = Join-Path $root 'pe/Deploy/config'
    New-Item -ItemType Directory -Path $peDir -Force | Out-Null
    $baked = Get-Content -Raw $settings | ConvertFrom-Json
    $baked.share | Add-Member -NotePropertyName encryptedPassword -NotePropertyValue (Protect-AnswerPassword -Password 'SharePw' -Key $key) -Force
    $baked | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $peDir 'deploy-settings.json')
    Assert-Equal ((Get-Content -Raw (Join-Path $peDir 'deploy-settings.json')) -like '*SharePw*') $false 'boot image settings hold no plain share password'
    $cred = Get-ShareCredential -SettingsPath (Join-Path $peDir 'deploy-settings.json') -Decrypt { param($v) Unprotect-AnswerPassword -Value $v -Key $key }
    Assert-Equal "$($cred.User)|$($cred.Password)" 'CORP\svc|SharePw' 'WinPE decrypts the share password from the boot image settings'
    $cred = Get-ShareCredential -SettingsPath (Join-Path $peDir 'deploy-settings.json')
    Assert-Equal ($null -eq $cred.Password) $true 'without the key nothing is decrypted (net use then asks)'
    $cred = Get-ShareCredential -SettingsPath $settings
    Assert-Equal ($null -eq $cred.Password) $true 'a plain share password file is not read'

    # The stick: config is copied, config\secrets never is.
    $c = Get-MediaContent -ContentRoot $root
    Assert-Equal ($c.Exclude -join ';') 'config\secrets;config\share.txt' 'secrets and the share password file left out by default'
    Assert-Equal (($c.Notes -join ' ') -like '*Password files (config\secrets) are not copied*') $true 'and the build says so'
    $plan = Get-MediaCopyPlan -ContentRoot $root -Folders $c.Folders -Files $c.Files -Exclude $c.Exclude
    Assert-Equal (@($plan.Items | Where-Object { $_.Relative -like 'config\secrets*' }).Count) 0 'no password file in the copy'
    Assert-Equal (@($plan.Directories | Where-Object { $_ -like 'config\secrets*' }).Count) 0 'not even the empty folder'
    Assert-Equal (@($plan.Items | Where-Object Relative -eq 'config\deploy-settings.json').Count) 1 'the rest of config is copied'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# Wiring: the deploy asks for the WinPE password before anything else and takes every password through
# Get-DeploySecret; startnet.cmd gives no command prompt after a refused WinPE password.
$deploy = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
$unlockAt = [regex]::Match($deploy, '(?m)^Unlock-DeployMedia\s*$').Index
Assert-Equal ($unlockAt -gt 0 -and $unlockAt -lt $deploy.IndexOf('Find-ContentRoot -SettingsPath')) $true 'WinPE password asked before the content is looked for'
Assert-Equal ($deploy -match 'Read-SecretFile') $false 'no password read straight from the media in the deploy'
$common = Get-Content -Raw (Join-Path $repo 'src/DeployCommon.psm1')
Assert-Equal ($common -match "share\.PSObject\.Properties\['passwordFile'\]") $false 'WinPE never reads a share password file'
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
    BitLocker = [pscustomobject]@{ Enabled = $true; Protector = 'Tpm' }
}
$needed = @(Get-AnswerSecrets -Answer $full)
Assert-Equal (($needed | ForEach-Object Key) -join ',') 'config\secrets\admin.txt,config\secrets\join.txt,config\secrets\share.txt' 'answer secrets: every password once, the shared join file only once (BitLocker has none)'
Assert-Equal $needed[1].Label 'Join account password (CORP\svc-join)' 'answer secrets: the join account is named'
Assert-Equal "$($needed[2].Share)|$($needed[0].Share)" 'Y:|' 'answer secrets: share passwords say which drive'
$bare = [pscustomobject]@{
    EnableAdministrator = $false; AdminPasswordFile = 'config\secrets\admin.txt'; Membership = 'Workgroup'; JoinPasswordFile = 'config\secrets\join.txt'
    Shares = @(); BitLocker = [pscustomobject]@{ Enabled = $true; Protector = 'Tpm' }
}
Assert-Equal @(Get-AnswerSecrets -Answer $bare).Count 0 'answer secrets: nothing for settings that are off'

# Wiring: the wizard gets the missing passwords up front (its Passwords page is the only place to type one), and
# every password the deploy reads is one Get-AnswerSecrets knows about.
Assert-Equal ($deploy -match '-MissingSecrets \$missingSecrets -SaveSecrets \$saveSecrets') $true 'wizard is given the missing passwords'
Assert-Equal ($deploy.Contains('Show-SecretsPrompt') -or $deploy.Contains('Request-DeploySecrets')) $false 'no second password window'
Assert-Equal ($deploy.Contains('-and -not $unstarted -and -not $needsPasswords) -or $job')) $true 'an unattended answer file that needs passwords opens the wizard'
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
Assert-Equal (($enc -split ':')[1]) (Get-AnswerKeyId $key) 'answer password: names the key it was made with'
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

    # The answer file's encrypted password is what the deploy wizard gets.
    $af = Join-Path $root 'AnswerFiles/Default.xml'
    $a = Read-AnswerFile -Path $af -SkipValidation
    $a.Membership = 'Domain'; $a.JoinUser = 'CORP\svc-join'; $a.Domain = 'corp.example.com'
    $a | Add-Member -NotePropertyName JoinPasswordEncrypted -NotePropertyValue (Protect-AnswerPassword -Password 'N3w pw' -Key $k1) -Force
    Assert-Equal @(Get-AnswerSecrets -Answer $a)[0].Encrypted $a.JoinPasswordEncrypted 'answer secrets: carry the encrypted password'
    Export-AnswerFile -Answer $a -Path $af

    # Export-AnswerFile (the editor's save) keeps the encrypted values; the stick needs no password file.
    $a = Read-AnswerFile -Path $af -SkipValidation
    $a.Shares = @([pscustomobject]@{ LocalName = 'Y:'; RemoteName = '\\srv\apps'; Username = 'svc'; Domain = ''; PasswordFile = 'config\secrets\y.txt'; PasswordEncrypted = (Protect-AnswerPassword -Password 'Sh' -Key $k1) })
    $a | Add-Member -NotePropertyName AdminPasswordEncrypted -NotePropertyValue (Protect-AnswerPassword -Password 'Adm' -Key $k1) -Force
    $out = Join-Path $root 'AnswerFiles/Copy.xml'
    Export-AnswerFile -Answer $a -Path $out
    $c = Read-AnswerFile -Path $out -SkipValidation
    $vals = foreach ($v in $c.JoinPasswordEncrypted, $c.AdminPasswordEncrypted, $c.Shares[0].PasswordEncrypted) { Unprotect-AnswerPassword -Value $v -Key $k1 }
    Assert-Equal ($vals -join '|') 'N3w pw|Adm|Sh' 'export: every encrypted password survives export and read'
    $plain = Join-Path $root 'AnswerFiles/Plain.xml'
    $c.JoinPasswordEncrypted = ''; $c.AdminPasswordEncrypted = ''; $c.Shares[0].PasswordEncrypted = ''
    Export-AnswerFile -Answer $c -Path $plain
    Assert-Equal ([IO.File]::ReadAllText($plain) -match 'encrypted') $false 'export: no empty encrypted elements'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# Wiring: the build puts the key into boot.wim (or into the vault); the deploy decrypts the passwords when it reads
# the answer file. Nothing reads plain password files.
Assert-Equal ($build -match 'Sync-AnswerFilePasswords|Get-ContentSecrets') $false 'build: no plain password files read'
Assert-Equal ($build -match 'deployDir\\config\\answer-key\.txt') $true 'build: answer file key into boot.wim without a WinPE password'
Assert-Equal ($build.IndexOf('$answerKey = Get-AnswerKey') -lt $build.IndexOf('New-SecretVault -Password $winPEPassword')) $true 'build: key known before the vault (which then holds it)'
$readAt = $deploy.IndexOf('function Read-DeployAnswer(')
Assert-Equal ($deploy.IndexOf('Add-AnswerPasswords -Root $Root -Answer $a', $readAt) -gt $readAt) $true 'deploy: answer file passwords decrypted when it is read'
Assert-Equal ([regex]::Matches($deploy, 'Get-DeploySecret -Root \$\w+ -RelativePath \S+ -Label').Count) 0 'deploy: every Get-DeploySecret is given the answer'

Complete-Tests 'All secret vault checks passed'
