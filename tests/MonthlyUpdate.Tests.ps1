# Plain-PowerShell tests for the monthly image update (ImageUpdateSchedule.psm1) and the Autopilot CSV merge.
# Run: pwsh -File tests/MonthlyUpdate.Tests.ps1. Works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/ImageUpdateSchedule.psm1') -Force
Import-Module (Join-Path $repo 'src/Autopilot.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

Assert-Equal (Get-PatchTuesday -Year 2026 -Month 11).ToString('yyyy-MM-dd') '2026-11-10' 'Patch Tuesday, November 2026'
Assert-Equal (Get-PatchTuesday -Year 2026 -Month 12).ToString('yyyy-MM-dd') '2026-12-08' 'Patch Tuesday, December 2026'
Assert-Equal (Get-PatchTuesday -Year 2026 -Month 9).ToString('yyyy-MM-dd') '2026-09-08' 'month starting on a Tuesday'
Assert-Equal (Test-ImageUpdateDue -Now ([datetime]'2026-11-10T03:00')) $false 'not on Patch Tuesday itself'
Assert-Equal (Test-ImageUpdateDue -Now ([datetime]'2026-11-11T03:00')) $true 'the day after'
Assert-Equal (Test-ImageUpdateDue -Now ([datetime]'2026-11-14T03:00') -DaysAfter 1) $true 'PC was off: catches up later in the month'
Assert-Equal (Test-ImageUpdateDue -Now ([datetime]'2026-11-20T03:00') -LastRun '2026-11') $false 'once a month'
Assert-Equal (Test-ImageUpdateDue -Now ([datetime]'2026-12-09T03:00') -LastRun '2026-11') $true 'next month again'

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-monthly-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'Images'), (Join-Path $root 'Updates'), (Join-Path $root 'config') -Force | Out-Null
    $img = Join-Path $root 'Images/Win11.wim'
    Set-Content $img 'wim'
    Set-Content (Join-Path $root 'Updates/windows11.0-kb5044284-x64.msu') 'cu'
    Set-Content (Join-Path $root 'Updates/windows11.0-kb5043080-x64.msu') 'old'
    $history = @([pscustomobject]@{ packages = @([pscustomobject]@{ index = 1; package = 'windows11.0-kb5043080-x64.msu'; result = 'Installed' }) })
    $p = @(Get-PendingImageUpdates -ContentRoot $root -ImagePath $img -History $history)
    Assert-Equal ($p.Name -join ',') 'windows11.0-kb5044284-x64.msu' 'only files the image has not had'
    New-Item -ItemType Directory -Path (Join-Path $root 'Updates/Win11') -Force | Out-Null
    Set-Content (Join-Path $root 'Updates/Win11/windows11.0-kb5046617-x64.msu') 'own'
    Assert-Equal ((Get-PendingImageUpdates -ContentRoot $root -ImagePath $img -History @()).Name -join ',') 'windows11.0-kb5046617-x64.msu' 'an image''s own folder wins'

    $s = Get-ImageUpdateSchedule -ContentRoot $root
    Assert-Equal "$($s.enabled)|$(@($s.images).Count)|$($s.daysAfterPatchTuesday)" 'False|0|1' 'defaults: off'
    $s.enabled = $true; $s.images = @('Images\Win11.wim'); $s.lastRun = '2026-11'
    Save-ImageUpdateSchedule -ContentRoot $root -Schedule $s
    $s = Get-ImageUpdateSchedule -ContentRoot $root
    Assert-Equal "$($s.enabled)|$($s.images -join ',')|$($s.lastRun)" 'True|Images\Win11.wim|2026-11' 'saved and read back'
    Assert-Equal ((Get-Content -Raw (Join-Path $root 'config/image-update-schedule.json')) -match '"images":\s*\[') $true 'one image is still a JSON list'

    # Autopilot: one row per serial, newest wins, Intune's columns without quotes.
    $ap = Join-Path $root 'Autopilot'
    New-Item -ItemType Directory -Path $ap -Force | Out-Null
    Set-Content (Join-Path $ap 'Autopilot-S1.csv') "Device Serial Number,Windows Product ID,Hardware Hash`nS1,,OLDHASH"
    (Get-Item (Join-Path $ap 'Autopilot-S1.csv')).LastWriteTimeUtc = [datetime]'2026-01-01'
    Set-Content (Join-Path $ap 'Autopilot-S1b.csv') "Device Serial Number,Windows Product ID,Hardware Hash`nS1,,NEWHASH"
    Set-Content (Join-Path $ap 'Autopilot-S2.csv') "Device Serial Number,Windows Product ID,Hardware Hash,Group Tag`nS2,,HASH2,Staff"
    $out = Join-Path $root 'all.csv'
    Assert-Equal (Merge-AutopilotCsv -Folder $ap -OutFile $out) 2 'two PCs'
    Assert-Equal ((Get-Content $out) -join '|') 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag|S1,,NEWHASH,|S2,,HASH2,Staff' 'merged file'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All monthly update and Autopilot checks passed' -ForegroundColor Green
