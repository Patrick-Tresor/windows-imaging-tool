# Plain-PowerShell tests for first boot on the deployed PC (src/FirstBootState.psm1, src/FirstBoot.ps1): a restart in
# the middle picks up after the last finished step, and the files deploy stages in C:\Temp are for admins only.
# Run: powershell -File tests\FirstBootState.Tests.ps1; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/FirstBootState.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

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
foreach ($f in 'FirstBoot.ps1', 'FirstBootState.psm1', 'AppPack.psm1', 'firstboot.json', 'firstboot-progress.json', 'firstboot.lock') {
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

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All first boot state tests passed.' -ForegroundColor Green
