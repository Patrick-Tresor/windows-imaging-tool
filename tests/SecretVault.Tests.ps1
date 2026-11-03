# Plain-PowerShell tests for keeping passwords off the USB stick: the WinPE password vault (SecretVault.psm1),
# leaving config\secrets out of the stick's copy, and the WinPE password prompt wiring in the build and deploy.
# Run: pwsh -File tests/SecretVault.Tests.ps1. Works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/MediaContent.psm1') -Force
Import-Module (Join-Path $repo 'src/MediaCopy.psm1') -Force
Import-Module (Join-Path $repo 'src/SecretVault.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Paths agree between the build (Windows paths) and WinPE whatever the case or slashes.
Assert-Equal (ConvertTo-SecretKey 'config/secrets/Staff-Join.txt') 'config\secrets\staff-join.txt' 'key: slashes and case'
Assert-Equal (ConvertTo-SecretKey '.\config\secrets\a.txt') 'config\secrets\a.txt' 'key: leading .\ dropped'
Assert-Equal (Test-SecretPath 'config\secrets\x.txt') $true 'config\secrets is secret'
Assert-Equal (Test-SecretPath 'config\deploy-settings.json') $false 'settings are not secret'

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

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All secret vault checks passed' -ForegroundColor Green
