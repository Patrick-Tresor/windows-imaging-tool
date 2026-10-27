# Plain-PowerShell tests for dashboard status reporting. Run: pwsh -File tests/DeployStatus.Tests.ps1
# Works on Windows and Linux; exits non-zero if any check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployStatus.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("status-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    # Status ids
    Assert-Equal (Get-StatusId -Serial ' 5CG1234XYZ ') '5CG1234XYZ' 'serial names the status file'
    Assert-Equal (Get-StatusId -Serial 'To Be Filled By O.E.M.' -MacAddress '00:15:5D:01:02:03') 'MAC-00155D010203' 'placeholder serial falls back to the MAC'
    Assert-Equal (Get-StatusId -Serial '0000' -MacAddress '00-15-5D-01-02-03') 'MAC-00155D010203' 'all-zero serial falls back to the MAC'
    Assert-Equal (Get-StatusId -Serial 'AB/12 34') 'AB_12_34' 'unsafe file name characters are replaced'

    # Where status goes
    $t = Resolve-StatusTarget -ContentRoot 'E:\' -SharePath '\\srv\Deploy'
    Assert-Equal "$($t.Map)|$($t.Unc)" '|' 'USB without a status share: no mapping, no first-boot reporting'
    $t = Resolve-StatusTarget -ContentRoot 'Z:\' -SharePath '\\srv\Deploy\'
    Assert-Equal "$($t.Map)|$($t.Unc)" '|\\srv\Deploy\Status' 'network root: first boot reports to the share Status folder'
    $t = Resolve-StatusTarget -ContentRoot 'Z:\' -SharePath '\\srv\Deploy' -ReportPath '\\SRV\deploy\Reports\Status'
    Assert-Equal "$($t.Local)|$($t.Map)|$($t.Unc)" 'Z:\Reports\Status||\\SRV\deploy\Reports\Status' 'status path under the share reuses the share drive'
    $t = Resolve-StatusTarget -ContentRoot 'E:\' -SharePath '\\srv\Deploy' -ReportPath '\\srv\Status'
    Assert-Equal "$($t.Local)|$($t.Map)|$($t.Unc)" 'R:\|\\srv\Status|\\srv\Status' 'USB with a status share maps it as R:'

    # WinPE lifecycle
    $folder = Join-Path $root 'Status'
    $winpeLog = Join-Path $root 'Deploy.log'
    Set-Content $winpeLog 'line from WinPE'
    $hw = [pscustomobject]@{ Maker = 'HP'; Model = 'EliteBook 840 G9'; Serial = '5CG1'; MachineType = $null; Sku = '8AB8' }
    $id = Start-DeployStatus -Folder $folder -Identity $hw -MacAddress '00:11:22:33:44:55' -IpAddress '10.0.0.5' -LogPath $winpeLog
    Assert-Equal $id '5CG1' 'start returns the status id'
    Assert-Equal (Test-Path (Join-Path $folder '5CG1.json')) $true 'start writes the status file'
    Set-DeployStatus -Step 'Applying the image (50 %)' -Percent 40 -Fields @{ computerName = 'LAB-5CG1'; answerFile = 'Default' }
    $rows = @(Get-DeploymentStatus -Folder $folder)
    Assert-Equal $rows.Count 1 'one row per PC'
    Assert-Equal "$($rows[0].State)|$($rows[0].Percent)|$($rows[0].ComputerName)|$($rows[0].Model)" 'Running|40|LAB-5CG1|HP EliteBook 840 G9' 'row shows the latest step'
    Assert-Equal (Get-Content -Raw $rows[0].LogPath).Trim() 'line from WinPE' 'live log is copied next to the status'
    Assert-Equal (@(Get-ChildItem $folder -Filter *.tmp).Count) 0 'no temporary files are left behind'

    Set-DeployStatus -Percent 250
    Assert-Equal (Get-DeployStatusRecord).percent 100 'percent is clamped'
    Set-DeployStatus -Step 'Waiting for first boot in Windows' -Percent 90 -Phase 'FirstBoot'

    # First boot picks up the record and finishes it
    $fbLog = Join-Path $root 'FirstBoot.log'
    Set-Content $fbLog 'line from first boot'
    Import-Module (Join-Path $repo 'src/DeployStatus.psm1') -Force    # fresh module state, like a new process
    Assert-Equal (Resume-DeployStatus -Folder $folder -Id '5CG1' -LogPath @($winpeLog, $fbLog)) $true 'first boot resumes the WinPE record'
    Assert-Equal (Resume-DeployStatus -Folder (Join-Path $root 'nowhere') -Id '5CG1' 3>$null) $false 'an unreachable folder returns false'
    $null = Resume-DeployStatus -Folder $folder -Id '5CG1' -LogPath @($winpeLog, $fbLog)
    Set-DeployStatus -Step 'Installed Zoom' -Percent 95 -Warning 'Zoom failed (exit 1603)'
    Set-DeployStatus -Step 'Deployment complete' -Percent 100 -State Succeeded
    $row = @(Get-DeploymentStatus -Folder $folder)[0]
    Assert-Equal "$($row.State)|$($row.Warnings)|$($row.ComputerName)" 'Warning|Zoom failed (exit 1603)|LAB-5CG1' 'a warning turns success into Warning and keeps earlier fields'
    Assert-Equal ((Get-Content -Raw $row.LogPath) -match 'line from WinPE[\s\S]*line from first boot') $true 'live log joins WinPE and first boot logs'

    # Stalled and failed PCs, summary, clearing
    $old = (Get-Date).AddHours(-2).ToString('o')
    @{ id = 'STALE1'; serial = 'STALE1'; state = 'Running'; percent = 30; started = $old; updated = $old } | ConvertTo-Json |
        Set-Content (Join-Path $folder 'STALE1.json')
    @{ id = 'BAD1'; serial = 'BAD1'; state = 'Failed'; message = 'Image not found'; started = $old; updated = $old; finished = $old } | ConvertTo-Json |
        Set-Content (Join-Path $folder 'BAD1.json')
    Set-Content (Join-Path $folder 'broken.json') '{ not json'
    $rows = @(Get-DeploymentStatus -Folder $folder -StaleMinutes 45)
    Assert-Equal (($rows | Where-Object Id -eq 'STALE1').State) 'Stalled' 'a Running PC with no update for StaleMinutes is Stalled'
    Assert-Equal $rows.Count 3 'unreadable status files are skipped'
    $sum = Get-DeploymentSummary -Rows $rows
    Assert-Equal "$($sum.Total)|$($sum.Running)|$($sum.Warning)|$($sum.Failed)" '3|0|1|2' 'summary counts failed and stalled together'
    Remove-DeploymentStatus -Rows @($rows | Where-Object Id -eq '5CG1')
    Assert-Equal "$(Test-Path (Join-Path $folder '5CG1.json'))|$(Test-Path (Join-Path $folder '5CG1.log'))" 'False|False' 'remove deletes the status and live log'

    Assert-Equal (Format-Duration ([timespan]::FromMinutes(75))) '1h 15m' 'durations over an hour'
    Assert-Equal (Format-Duration ([timespan]::FromSeconds(95))) '1m 35s' 'durations under an hour'

    $s = [pscustomobject]@{ reporting = [pscustomobject]@{ path = '\\srv\Status' } }
    Assert-Equal (Get-StatusFolder -ContentRoot $root -Settings $s) '\\srv\Status' 'console reads the status share when set'
    Assert-Equal (Get-StatusFolder -ContentRoot $root -Settings ([pscustomobject]@{ share = @{} })) (Join-Path $root 'Status') 'console defaults to the content root Status folder'
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
