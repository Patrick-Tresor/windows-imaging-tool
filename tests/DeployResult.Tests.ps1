# Tests for the end-of-deploy result (Get-DeployResultSummary in src/DeployStatus.psm1): the Dashboard's Result column
# and details, and C:\Windows\Temp\DeployResult.txt on the PC.
# Run: powershell -File tests/DeployResult.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $repo 'src/DeployStatus.psm1') -Force

$now = [datetime]'2026-11-20 12:00'
$deploy = [pscustomobject]@{
    computerName = 'PC-0042'; maker = 'Dell Inc.'; model = 'Latitude 5521'; answerFile = 'W11-Staff'; image = 'Images\Win11.wim'
    driverPack = 'Dell\Latitude 5521'; driversAdded = 87; toolVersion = '853ca2f (2026-11-20 17:12)'
    started = ([datetime]'2026-11-20 10:00').ToString('o'); finished = ([datetime]'2026-11-20 10:47').ToString('o'); state = 'Succeeded'
}
$checks = @(
    [pscustomobject]@{ name = 'Computer name'; result = 'Passed'; detail = 'PC-0042' }
    [pscustomobject]@{ name = 'Domain join'; result = 'Passed'; detail = 'Joined to corp.local' }
    [pscustomobject]@{ name = 'Device drivers'; result = 'Passed'; detail = 'No device errors' }
    [pscustomobject]@{ name = 'App: Zoom'; result = 'Passed'; detail = 'Installed' }
    [pscustomobject]@{ name = 'App: Firefox'; result = 'Passed'; detail = 'Installed' }
    [pscustomobject]@{ name = 'Task: Wallpaper'; result = 'Passed'; detail = 'exit 0' }
    [pscustomobject]@{ name = 'BitLocker'; result = 'Passed'; detail = 'Encrypting, 12 % done (Tpm)' }
)

# Everything passed: Ready, one line per part.
$s = Get-DeployResultSummary -Deploy $deploy -Checks $checks -Now $now
Assert-Equal $s.Result 'Ready' 'all checks passed: Ready'
Assert-Equal $s.Verdict 'Ready' 'verdict says Ready'
$items = ($s.Lines | ForEach-Object Item) -join ','
Assert-Equal $items 'Windows,Drivers,Applications,Tasks,Computer name,Domain join,BitLocker,Total time,Tool version' 'one line per part, in order'
$line = { param($item) @($s.Lines | Where-Object Item -eq $item)[0] }
Assert-Equal (& $line 'Drivers').Detail 'Dell\Latitude 5521, 87 driver(s) added' 'drivers: pack and count'
Assert-Equal (& $line 'Applications').Detail '2 of 2 installed' 'applications: count'
Assert-Equal (& $line 'Total time').Detail '47m 00s' 'total time from WinPE start to the end of first boot'
Assert-Equal ($s.Text -like 'PC-0042 (Dell Inc. Latitude 5521) - Ready*') $true 'text starts with the PC and the verdict'
Assert-Equal ($s.Text -match '(?m)^  OK\s+Domain join\s+Joined to corp\.local\r?$') $true 'text has a line per part'

# A failed application: Not ready, and which one.
$bad = @($checks | Where-Object name -ne 'App: Zoom') + [pscustomobject]@{ name = 'App: Zoom'; result = 'Failed'; detail = 'Failed: exit 1603' }
$s = Get-DeployResultSummary -Deploy $deploy -Checks $bad -Now $now
Assert-Equal $s.Result 'NotReady' 'a failed application: not ready'
Assert-Equal $s.Verdict 'Not ready: Zoom failed' 'verdict names the failed application'
Assert-Equal (@($s.Lines | Where-Object Item -eq 'Applications')[0].Detail) '1 of 2 installed: Zoom (Failed: exit 1603)' 'applications line names the app and why'

# No driver pack for the model and BitLocker off in Report mode: Ready with warnings.
$noPack = $deploy.PSObject.Copy(); $noPack.driverPack = 'inbox only'; $noPack.driversAdded = $null
$warn = @($checks | Where-Object { $_.name -notin 'BitLocker', 'Device drivers' }) + [pscustomobject]@{ name = 'BitLocker'; result = 'Warning'; detail = 'Off (FullyDecrypted)' }
$s = Get-DeployResultSummary -Deploy $noPack -Checks $warn -Now $now
Assert-Equal $s.Result 'Warning' 'no driver pack and BitLocker off: warning'
Assert-Equal $s.Verdict 'Ready, with warnings: Drivers, BitLocker' 'verdict lists the warnings'
Assert-Equal ((@($s.Lines | Where-Object Item -eq 'Drivers')[0].Detail) -like "No driver pack for Dell Inc. Latitude 5521*") $true 'drivers line says the model has no pack'

# Device errors after a driver pack: the Drivers line says so.
$dev = @($checks | Where-Object name -ne 'Device drivers') + [pscustomobject]@{ name = 'Device drivers'; result = 'Failed'; detail = '1 device(s) with errors: Wi-Fi (code 28)' }
$s = Get-DeployResultSummary -Deploy $deploy -Checks $dev -Now $now
Assert-Equal (@($s.Lines | Where-Object Item -eq 'Drivers')[0].Result) 'Failed' 'device errors fail the drivers line'
Assert-Equal ((@($s.Lines | Where-Object Item -eq 'Drivers')[0].Detail) -like '*87 driver(s) added; 1 device(s) with errors: Wi-Fi (code 28)') $true 'drivers line has the device error'

# Still deploying, and a failed deploy.
$running = $deploy.PSObject.Copy(); $running.state = 'Running'; $running.finished = $null
$s = Get-DeployResultSummary -Deploy $running -Checks @() -Now $now
Assert-Equal $s.Result 'Running' 'running: no verdict yet'
Assert-Equal (@($s.Lines | Where-Object Item -eq 'Total time')[0].Detail) '2h 00m so far' 'running: time so far'
$failed = $deploy.PSObject.Copy(); $failed.state = 'Failed'; $failed | Add-Member -NotePropertyName message -NotePropertyValue 'No internal disk found'
$s = Get-DeployResultSummary -Deploy $failed -Checks @() -Now $now
Assert-Equal $s.Verdict 'Deployment failed: No internal disk found' 'failed: the error'

# The dashboard row carries the result.
$folder = Join-Path ([IO.Path]::GetTempPath()) ('DeployResult-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null
try {
    $record = [ordered]@{ id = 'X1'; computerName = 'PC-0042'; maker = 'Dell Inc.'; model = 'Latitude 5521'; serial = 'ABC'; answerFile = 'W11-Staff'
        image = 'Images\Win11.wim'; driverPack = 'Dell\Latitude 5521'; driversAdded = 87; toolVersion = '853ca2f'; state = 'Succeeded'; percent = 100
        started = $deploy.started; updated = $deploy.finished; finished = $deploy.finished; checks = $checks; checkResult = 'Passed'; checkSummary = 'Passed 7/7' }
    $record | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $folder 'X1.json') -Encoding utf8
    $row = @(Get-DeploymentStatus -Folder $folder -Now $now)[0]
    Assert-Equal $row.Result 'Ready' 'dashboard row: Result column'
    Assert-Equal $row.ResultState 'Ready' 'dashboard row: Result state for the colour'
    Assert-Equal ($row.ResultText -match 'Applications\s+2 of 2 installed') $true 'dashboard row: details text'
    Assert-Equal $row.ToolVersion '853ca2f' 'dashboard row: tool version'
} finally { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }

# WinPE records what first boot needs for the result, and first boot writes DeployResult.txt.
$deployScript = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($deployScript -match "NotePropertyName deploy") $true 'firstboot.json gets the deploy part'
$firstBoot = Get-Content -Raw (Join-Path $repo 'src/FirstBoot.ps1')
Assert-Equal ($firstBoot -match 'DeployResult\.txt') $true 'first boot writes DeployResult.txt'

Complete-Tests
