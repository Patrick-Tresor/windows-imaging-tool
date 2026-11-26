# Plain-PowerShell tests for first boot on the deployed PC (src/FirstBootState.psm1, src/FirstBoot.ps1): a restart in
# the middle picks up after the last finished step, and the files deploy stages in C:\Temp are for admins only.
# Run: powershell -File tests\FirstBootState.Tests.ps1; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/FirstBootState.psm1') -Force

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fbstate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    # Progress: new, saved, read back after a "restart".
    $path = Join-Path $tmp 'firstboot-progress.json'
    $p = Read-FirstBootProgress -Path $path
    Assert-Equal "$($p.runs)|$(@($p.done).Count)|$(@($p.started).Count)" '0|0|0' 'no progress file gives a new progress'
    Set-Content -Path $path -Value '{}' -Encoding ascii
    $p = Read-FirstBootProgress -Path $path
    Assert-Equal "$($p.runs)|$(@($p.done).Count)" '0|0' "the '{}' deploy writes reads as a new progress"
    Set-Content -Path $path -Value 'not json' -Encoding ascii
    Assert-Equal (Read-FirstBootProgress -Path $path).runs 0 'an unreadable file gives a new progress'

    Set-Content -Path $path -Value '{}' -Encoding ascii
    $p = Read-FirstBootProgress -Path $path
    $p.runs = 1
    Assert-Equal (Get-FirstBootStepState -Progress $p -Step 'app:1') 'New' 'a step not started yet is New'
    Start-FirstBootStep -Progress $p -Step 'app:1'
    $p.appResults = @([pscustomobject]@{ name = 'Zoom'; status = 'Installed'; ok = $true; exitCode = 0; rebootNeeded = $false; message = 'exit 0' })
    Complete-FirstBootStep -Progress $p -Step 'app:1'
    Start-FirstBootStep -Progress $p -Step 'app:2'
    Save-FirstBootProgress -Progress $p -Path $path

    $again = Read-FirstBootProgress -Path $path
    Assert-Equal $again.runs 1 'the number of starts is kept'
    Assert-Equal (Get-FirstBootStepState -Progress $again -Step 'app:1') 'Done' 'a finished step stays Done after a restart'
    Assert-Equal (Get-FirstBootStepState -Progress $again -Step 'app:2') 'Interrupted' 'a step a restart cut short is Interrupted'
    Assert-Equal (Get-FirstBootStepState -Progress $again -Step 'app:3') 'New' 'steps after it are New'
    Assert-Equal "$(@($again.appResults).Count)|$(@($again.appResults)[0].name)|$(@($again.appResults)[0].ok)" '1|Zoom|True' 'results of earlier starts are kept for the checks'
    Complete-FirstBootStep -Progress $again -Step 'app:2'
    Complete-FirstBootStep -Progress $again -Step 'app:2'
    Assert-Equal "$(@($again.done).Count)|$(@($again.started).Count)" '2|2' 'a step is listed once'

    # Starts: the first and 4 restarts, then it gives up.
    $again.runs = 5
    Assert-Equal (Test-FirstBootRunsLeft -Progress $again) $true 'a fifth start still runs'
    $again.runs = 6
    Assert-Equal (Test-FirstBootRunsLeft -Progress $again) $false 'a sixth start gives up (something restarts the PC every time)'

    # Interrupted steps are not run again; an app's detection rule says whether it got installed.
    $r = Get-InterruptedAppResult -Detection ([pscustomobject]@{ HasRules = $true; Detected = $true })
    Assert-Equal $r.Status 'Installed' 'an app found installed after the restart counts as installed'
    $r = Get-InterruptedAppResult -Detection ([pscustomobject]@{ HasRules = $true; Detected = $false })
    Assert-Equal "$($r.Status)|$($r.Message -like '*not detected*')" 'Failed|True' 'an app not found after the restart failed'
    $r = Get-InterruptedAppResult -Detection ([pscustomobject]@{ HasRules = $false; Detected = $false })
    Assert-Equal "$($r.Status)|$($r.Message -like '*no detection rule*')" 'Failed|True' 'an app with no rule cannot be confirmed'
    Assert-Equal (Get-InterruptedTaskResult).Status 'Failed' 'a task the restart cut short is reported'

    # One run at a time.
    $lockPath = Join-Path $tmp 'firstboot.lock'
    $first = Get-FirstBootLock -Path $lockPath
    $second = Get-FirstBootLock -Path $lockPath
    Assert-Equal "$($null -ne $first)|$($null -eq $second)" 'True|True' 'a second run cannot take the lock while the first holds it'
    $first.Dispose()
    $third = Get-FirstBootLock -Path $lockPath
    Assert-Equal ($null -ne $third) $true 'the lock is free again once the run ends'
    $third.Dispose()
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# Admins-only rights for what deploy stages in C:\Temp.
Assert-Equal ((Get-AdminOnlyAclArgs -Path 'W:\Temp\Apps' -Folder) -join ' ') 'W:\Temp\Apps /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F' 'a staged folder passes admins-only rights to what goes in it'
Assert-Equal ((Get-AdminOnlyAclArgs -Path 'W:\Temp\firstboot.json') -join ' ') 'W:\Temp\firstboot.json /inheritance:r /grant:r *S-1-5-32-544:F *S-1-5-18:F' 'a staged file is for admins and SYSTEM only'

$deploy = [IO.File]::ReadAllText((Join-Path $repo 'src/Deploy-Image.ps1'))
$lockApps = $deploy.IndexOf("Protect-StagedItem -Path `$f -Folder")
Assert-Equal ($lockApps -gt 0 -and $lockApps -lt $deploy.IndexOf("Copy-Item -Path (Join-Path `$appRoot `$app.name)")) $true 'Apps and Tasks are locked before anything is copied in'
$lockEnd = $deploy.IndexOf('Protect-StagedItem -Path "W:\Temp\$f"')
$lockList = $deploy.Substring($deploy.LastIndexOf('foreach ($f in', $lockEnd), $lockEnd - $deploy.LastIndexOf('foreach ($f in', $lockEnd))
foreach ($f in 'FirstBoot.ps1', 'FirstBootState.psm1', 'AppPack.psm1', 'LibraryPack.psm1', 'firstboot.json', 'firstboot-progress.json', 'firstboot.lock') {
    Assert-Equal ($lockEnd -gt 0 -and $lockList.Contains("'$f'")) $true "deploy locks $f"
}
Assert-Equal ($deploy.Contains("Protect-StagedItem -Path 'W:\Temp\deployed.json'")) $true 'deploy locks deployed.json'
Assert-Equal ($deploy.Contains("(Join-Path `$PSScriptRoot 'FirstBootState.psm1') 'W:\Temp\'")) $true 'deploy stages FirstBootState.psm1 next to FirstBoot.ps1'

# FirstBoot.ps1: the startup task stays until first boot has finished, and the PIN file goes at the end.
$fb = [IO.File]::ReadAllText((Join-Path $repo 'src/FirstBoot.ps1'))
$firstDelete = $fb.IndexOf('schtasks.exe /Delete /TN $taskName')
Assert-Equal ($firstDelete -gt $fb.IndexOf("Get-FirstBootStepState -Progress `$progress -Step 'finished'")) $true 'the task is only deleted once first boot finished (or had finished)'
Assert-Equal ($fb.IndexOf('schtasks.exe /Delete /TN $taskName', $firstDelete + 1) -gt $fb.IndexOf('Enable-DeployBitLocker $plan.bitlocker')) $true 'the task stays while apps, tasks and BitLocker run'
Assert-Equal ($fb.Contains('firstboot.started')) $false 'no one-shot claim file any more'
foreach ($s in "'app:", "'task:", "'options'", "'bitlocker'", "'finished'") {
    Assert-Equal ($fb.Contains($s) -or $fb.Contains("`"$($s.Trim("'"))")) $true "first boot records the $s step"
}
# The cleanup command (defined at the top of FirstBoot.ps1, run on its own here).
$fnStart = $fb.IndexOf('function Get-FirstBootCleanupCommand')
$fnEnd = $fb.IndexOf("`nImport-Module", $fnStart)
. ([scriptblock]::Create($fb.Substring($fnStart, $fnEnd - $fnStart)))
$clean = Get-FirstBootCleanupCommand 'C:\Temp'
Assert-Equal ($clean.Contains('del /f /q "C:\Temp\firstboot.json"')) $true 'cleanup removes firstboot.json (the PIN)'
Assert-Equal "$($clean.Contains('"C:\Temp\FirstBoot.ps1"'))|$($clean.Contains('firstboot-progress.json'))" 'True|False' 'cleanup removes the script and keeps the finished record'
$keep = Get-FirstBootCleanupCommand 'C:\Temp' -KeepScript
Assert-Equal "$($keep.Contains('"C:\Temp\FirstBoot.ps1"'))|$($keep.Contains('firstboot.json'))" 'False|True' 'when the task could not be deleted, its script stays (admins only) but the PIN goes'

# unattend.xml on the deployed PC: Clear-UnattendPasswords.ps1 blanks every password once OOBE is over.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('unattend-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $ua = Join-Path $tmp 'unattend.xml'
    [IO.File]::WriteAllText($ua, @'
<unattend><settings pass="specialize"><component name="Microsoft-Windows-UnattendedJoin"><Identification><Credentials>
<Domain>CORP</Domain><Password>J0in-Secret</Password><Username>svc-join</Username></Credentials></Identification></component></settings>
<settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"><UserAccounts><AdministratorPassword>
<Value>Adm1n-Secret</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
<AutoLogon><Password><Value>Auto-Secret</Value><PlainText>true</PlainText></Password><Username>Administrator</Username></AutoLogon>
<ComputerName>PC-01</ComputerName></component></settings></unattend>
'@)
    $logFile = Join-Path $tmp 'FirstBoot.log'
    $clear = Join-Path $repo 'src/Clear-UnattendPasswords.ps1'
    & $clear -Path $ua, (Join-Path $tmp 'missing.xml') -LogPath $logFile -NoWait -KeepTask
    $after = [IO.File]::ReadAllText($ua)
    Assert-Equal ($after -match 'Secret') $false 'unattend: every password is removed'
    Assert-Equal (([xml]$after).unattend.settings[1].component.ComputerName) 'PC-01' 'unattend: still valid XML, other settings kept'
    Assert-Equal ((Get-Content -Raw $logFile) -match 'removed 3 from') $true 'unattend: the log says how many'
    & $clear -Path $ua -LogPath $logFile -NoWait -KeepTask
    Assert-Equal ((Get-Content -Raw $logFile) -match 'none left in') $true 'unattend: a second run finds nothing to remove'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
$fb = Get-Content -Raw (Join-Path $repo 'src/FirstBoot.ps1')
Assert-Equal ($fb -match '/SC ONLOGON /RU SYSTEM') $true 'unattend: first boot creates the SYSTEM logon task'
$dp = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($dp -match "Protect-StagedItem -Path 'W:\\ProgramData\\ImagingTool\\Clear-UnattendPasswords\.ps1'") $true 'unattend: the script is staged for admins only'

# The scripts that run on their own write their log through ScriptLog.psm1, staged next to each of them.
foreach ($f in 'FirstBoot.ps1', 'Clear-UnattendPasswords.ps1', 'Invoke-SysprepAtDeploy.ps1', 'Add-ScanExclusions.ps1') {
    $text = Get-Content -Raw (Join-Path $repo "src/$f")
    Assert-Equal ($text -match "ScriptLog\.psm1" -and $text -match 'Write-ScriptLog') $true "$f logs through ScriptLog.psm1"
}
foreach ($staged in "(Join-Path `$PSScriptRoot 'SysprepAtDeploy.psm1'), (Join-Path `$PSScriptRoot 'ScriptLog.psm1')",
                    "(Join-Path `$PSScriptRoot 'Clear-UnattendPasswords.ps1'), (Join-Path `$PSScriptRoot 'ScriptLog.psm1')",
                    "(Join-Path `$PSScriptRoot 'ScriptLog.psm1'), (Join-Path `$PSScriptRoot 'FirstBootState.psm1') 'W:\Temp\'") {
    Assert-Equal ($dp.Contains($staged)) $true "deploy stages ScriptLog.psm1: $staged"
}
$logFile = Join-Path ([IO.Path]::GetTempPath()) ("scriptlog-" + [guid]::NewGuid() + "/x/test.log")
Import-Module (Join-Path $repo 'src/ScriptLog.psm1') -Force
Write-ScriptLog -Path $logFile -Message 'hello' -Prefix '[INFO] '
Write-ScriptLog -Path '' -Message 'nowhere'
Assert-Equal ((Get-Content $logFile) -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\] hello$') $true 'a log line: time, prefix, message; the folder is made'
Remove-Item (Split-Path (Split-Path $logFile)) -Recurse -Force

# Failed applications: installed again silently at the next logon (Retry-FailedApps.ps1, SYSTEM logon task).
$apps = @([pscustomobject]@{ name = 'Google Chrome'; command = 'chrome.cmd' }, [pscustomobject]@{ name = 'Zoom'; command = 'zoom.cmd' })
$results = @([pscustomobject]@{ name = 'Google Chrome'; ok = $false; status = 'Failed'; message = 'exit 1603' }, [pscustomobject]@{ name = 'Zoom'; ok = $true; status = 'Installed' })
$rp = New-AppRetryPlan -Applications $apps -AppResults $results -Deploy ([pscustomobject]@{ computerName = 'PC1' }) -Checks @() -Status ([pscustomobject]@{ folder = '\\srv\s\Status'; id = 'ABC' })
Assert-Equal "$(@($rp.apps).Count)|$($rp.apps[0].name)|$($rp.apps[0].command)|$($rp.attempts)|$($rp.maxAttempts)" '1|Google Chrome|chrome.cmd|0|3' 'only the failed app is retried, with its app.json, up to 3 logons'
Assert-Equal ($null -eq (New-AppRetryPlan -Applications $apps -AppResults @($results[1]))) $true 'nothing failed: no retry'
$fb = Get-Content -Raw (Join-Path $repo 'src/FirstBoot.ps1')
Assert-Equal ($fb -match "/TN 'ImagingTool\\RetryApps' /SC ONLOGON /DELAY 0002:00 /RU SYSTEM") $true 'first boot makes the SYSTEM logon task, 2 minutes after logon'
Assert-Equal ($fb -match '-WindowStyle Hidden -File `"\$retryDir\\Retry-FailedApps\.ps1`"') $true 'it runs hidden'
Assert-Equal ($fb.IndexOf('New-AppRetryPlan') -lt $fb.IndexOf('Get-FirstBootCleanupCommand $deployDir')) $true 'the failed packs move before C:\Temp is cleared'
Assert-Equal ($fb -match '(?s)\$retryDir = .{0,300}Get-AdminOnlyAclArgs -Path \$retryDir -Folder') $true 'the retry folder is for admins only before anything goes in'
Assert-Equal ($clean.Contains('"C:\Temp\Retry-FailedApps.ps1"')) $true 'cleanup removes the staged retry script'
$dp = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($dp -match "'Test-Deployment\.ps1', 'Retry-FailedApps\.ps1'") $true 'deploy stages the retry script for admins only'
$rs = Get-Content -Raw (Join-Path $repo 'src/Retry-FailedApps.ps1')
foreach ($m in 'ScriptLog.psm1', 'AppPack.psm1', 'DeployStatus.psm1') { Assert-Equal ($rs -match [regex]::Escape("'$m'")) $true "the retry imports $m" }
Assert-Equal ($rs -match '(?s)Invoke-AppRetryPlan.*Publish-AppRetryResults') $true 'the logon retry runs the one retry and reports to DeployResult.txt and the Dashboard'
Assert-Equal ($fb -match '(?s)ImagingAgent\.ps1"\) \{.{0,300}the agent installs them again.{0,200}\} else \{.{0,90}ImagingTool\\RetryApps') $true 'with the agent there is no logon task: the agent retries'
$agentText = Get-Content -Raw (Join-Path $repo 'src/ImagingAgent.ps1')
Assert-Equal ($agentText -match "Invoke-AppRetryPlan -By 'the agent' -WaitMinutes 0 -MinMinutes 60") $true 'the agent retries hourly and never waits on another install'
Assert-Equal ($fb -match '(?s)DeployResult\.txt.{0,400}Save-LocalDeployResult -Deploy \$deployInfo -Checks \$checkResults') $true 'first boot keeps what DeployResult.txt is made from'
Assert-Equal ($rs -match '-RemoveFolder \{ Start-Process -FilePath cmd\.exe') $true 'it removes its own folder a moment after it ends'
$bytes = [IO.File]::ReadAllBytes((Join-Path $repo 'src/Retry-FailedApps.ps1'))
Assert-Equal (@($bytes | Where-Object { $_ -gt 127 }).Count) 0 'Retry-FailedApps.ps1 is ASCII'

# The retry itself, on this PC: a folder like first boot makes, one app that installs now. Only on CI (it writes
# C:\Windows\Temp\DeployResult.txt and RetryApps.log, as on a deployed PC).
if ($env:CI -or $env:IMAGING_E2E) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('retry-' + [guid]::NewGuid().ToString('N'))
  try {
    $kit = Join-Path $tmp 'RetryApps'
    New-Item -ItemType Directory -Path (Join-Path $kit 'Apps\Retry-App') -Force | Out-Null
    foreach ($f in 'Retry-FailedApps.ps1', 'AppPack.psm1', 'LibraryPack.psm1', 'ScriptLog.psm1', 'DeployStatus.psm1') { Copy-Item (Join-Path $repo "src/$f") $kit }
    $marker = Join-Path $tmp 'retry-installed.txt'
    $status = Join-Path $tmp 'Status'
    New-Item -ItemType Directory -Path $status -Force | Out-Null
    @{ id = 'RETRY1'; serial = 'RETRY1'; state = 'Warning'; warnings = @('Retry-App failed (Failed)')
       checks = @(@{ name = 'App: Retry-App'; result = 'Failed'; detail = 'Failed: exit 1' }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $status 'RETRY1.json')
    $plan = New-AppRetryPlan -Applications @([pscustomobject]@{ name = 'Retry-App'; command = "echo installed> `"$marker`"" }) `
        -AppResults @([pscustomobject]@{ name = 'Retry-App'; ok = $false; status = 'Failed'; message = 'exit 1' }) `
        -Deploy ([pscustomobject]@{ computerName = 'RETRY-PC'; state = 'Succeeded'; driverPack = 'Dell\x' }) `
        -Checks @([pscustomobject]@{ name = 'App: Retry-App'; result = 'Failed'; detail = 'Failed: exit 1' }) -Status ([pscustomobject]@{ folder = $status; id = 'RETRY1' })
    $plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $kit 'retry.json') -Encoding utf8
    # A PC deployed before deploy-result.json: the retry starts it from its plan.
    $dataFile = Join-Path $env:ProgramData 'ImagingTool\deploy-result.json'
    Remove-Item -LiteralPath $dataFile -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'Retry-FailedApps.ps1')
    Assert-Equal (Test-Path $dataFile) $true 'the retry keeps what DeployResult.txt is made from'
    Remove-Item -LiteralPath $dataFile -Force -ErrorAction SilentlyContinue
    $retryLog = Get-Content -Raw "$env:WINDIR\Temp\RetryApps.log"
    Assert-Equal (Test-Path $marker) $true "the retry installs the failed app (log: $retryLog)"
    Assert-Equal ($retryLog -match 'Every application is installed now') $true 'the log says it is done'
    $row = Get-Content -Raw (Join-Path $status 'RETRY1.json') | ConvertFrom-Json
    Assert-Equal "$($row.state)|$(@($row.checks)[0].result)|$(@($row.warnings).Count)" 'Succeeded|Passed|0' 'the Dashboard row is Succeeded, the app passes'
    Assert-Equal ((Get-Content -Raw (Join-Path $status 'RETRY1.log')) -match 'Logon Retry: Retry-App installed') $true 'its live log says so'
    Assert-Equal ((Get-Content -Raw "$env:WINDIR\Temp\DeployResult.txt") -match '^RETRY-PC - Ready') $true 'DeployResult.txt says Ready now'
    Start-Sleep -Seconds 8
    Assert-Equal (Test-Path $kit) $false 'the retry folder is removed once every app is in'
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
} else { Write-Host 'SKIP running the logon retry: it writes to C:\Windows\Temp (set IMAGING_E2E=1).' -ForegroundColor Yellow }

Complete-Tests 'All first boot state tests passed.'
