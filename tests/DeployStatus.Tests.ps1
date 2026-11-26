# Plain-PowerShell tests for dashboard status reporting. Run: pwsh -File tests/DeployStatus.Tests.ps1
# Works on Windows and Linux; exits non-zero if any check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployStatus.psm1') -Force

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ("status-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    # Status ids
    Assert-Equal (Get-StatusId -Serial ' 5CG1234XYZ ') '5CG1234XYZ' 'serial names the status file'
    Assert-Equal (Get-StatusId -Serial 'To Be Filled By O.E.M.' -MacAddress '00:15:5D:01:02:03') 'MAC-00155D010203' 'placeholder serial falls back to the MAC'
    Assert-Equal (Get-StatusId -Serial '0000' -MacAddress '00-15-5D-01-02-03') 'MAC-00155D010203' 'all-zero serial falls back to the MAC'
    Assert-Equal (Get-StatusId -Serial 'AB/12 34') 'AB_12_34' 'unsafe file name characters are replaced'

    # Where status goes
    $t = Resolve-StatusTarget -ContentRoot 'E:\'
    Assert-Equal "$($t.Local)|$($t.Map)|$($t.Unc)" 'E:\Status||' 'USB without a share: status on the stick, no first-boot reporting'
    $t = Resolve-StatusTarget -ContentRoot 'E:\' -SharePath '\\srv\Deploy'
    Assert-Equal "$($t.Local)|$($t.Map)|$($t.Unc)" 'R:\|\\srv\Deploy\Status|\\srv\Deploy\Status' 'USB with a share: reports to the share Status folder'
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
    $now = [datetime]::Now
    $aged = @(
        [pscustomobject]@{ Id = 'OLD-OK'; State = 'Succeeded'; Updated = $now.AddDays(-8) }
        [pscustomobject]@{ Id = 'NEW-OK'; State = 'Succeeded'; Updated = $now.AddDays(-2) }
        [pscustomobject]@{ Id = 'OLD-FAIL'; State = 'Failed'; Updated = $now.AddDays(-30) }
        [pscustomobject]@{ Id = 'OLD-WARN'; State = 'Warning'; Updated = $now.AddDays(-9) }
    )
    Assert-Equal ((Get-ExpiredDeployments -Rows $aged -Now $now).Id -join ',') 'OLD-OK,OLD-WARN' 'finished PCs older than 7 days leave the Dashboard; failed ones stay'
    Remove-DeploymentStatus -Rows @($rows | Where-Object Id -eq '5CG1')
    Assert-Equal "$(Test-Path (Join-Path $folder '5CG1.json'))|$(Test-Path (Join-Path $folder '5CG1.log'))" 'False|False' 'remove deletes the status and live log'

    Assert-Equal (Format-Duration ([timespan]::FromMinutes(75))) '1h 15m' 'durations over an hour'
    Assert-Equal (Format-Duration ([timespan]::FromSeconds(95))) '1m 35s' 'durations under an hour'
    Assert-Equal (Format-Duration 42.4) '42s' 'durations under a minute, also from seconds'

    # State agrees with Result: a finished PC whose checks found a failed application is Not ready, not Warning.
    $agree = Join-Path $root 'StatusAgree'
    New-Item -ItemType Directory -Path $agree -Force | Out-Null
    $t = (Get-Date).AddMinutes(-30).ToString('o')
    @{ id = 'NR1'; serial = 'NR1'; computerName = 'PC-NR1'; state = 'Warning'; percent = 100; started = $t; updated = $t; finished = $t; driverPack = 'Dell\Latitude 5521'
       checks = @(@{ name = 'App: Google Chrome'; result = 'Failed'; detail = 'Failed: exit 1603' }, @{ name = 'App: Zoom'; result = 'Passed'; detail = 'Installed' }) } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $agree 'NR1.json')
    @{ id = 'OK1'; serial = 'OK1'; computerName = 'PC-OK1'; state = 'Succeeded'; percent = 100; started = $t; updated = $t; finished = $t; driverPack = 'Dell\Latitude 5521'
       checks = @(@{ name = 'BitLocker'; result = 'Warning'; detail = 'Off' }) } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $agree 'OK1.json')
    $agreeRows = @(Get-DeploymentStatus -Folder $agree)
    $nr = $agreeRows | Where-Object Id -eq 'NR1'
    Assert-Equal "$($nr.State)|$($nr.Result)" 'Not ready|Not ready: Google Chrome failed' 'a failed app: State is Not ready and Result names the app'
    Assert-Equal (($agreeRows | Where-Object Id -eq 'OK1').State) 'Warning' 'a check warning turns Succeeded into Warning'
    $sum = Get-DeploymentSummary -Rows $agreeRows
    Assert-Equal "$($sum.Warning)|$($sum.Failed)" '1|1' 'Not ready counts with failed and stalled'

    # The details: one line per app, failed ones first, with the reason; Retry failed apps takes the failed ones.
    $list = @(Get-DeployChecklist -Row $nr)
    $apps = @($list | Where-Object { $_.Item -in 'Google Chrome', 'Zoom' })
    Assert-Equal (($apps | ForEach-Object { "$($_.Item)=$($_.Result)" }) -join ',') 'Google Chrome=Failed,Zoom=OK' 'one line per app, the failed one first'
    Assert-Equal ($apps[0].Detail) 'Failed: exit 1603' 'the line gives the reason'
    Assert-Equal (@($list | Where-Object Item -eq 'Applications').Count) 0 'no Applications total line when each app has its own'
    Assert-Equal ((@($list | ForEach-Object Item))[0]) 'Windows' 'the other parts keep their order'
    Assert-Equal ((Get-FailedApps -Row $nr) -join ',') 'Google Chrome' 'the failed apps'
    Assert-Equal (@(Get-FailedApps -Row ($agreeRows | Where-Object Id -eq 'OK1')).Count) 0 'none on a PC whose apps passed'

    # Notices: only for a PC that finished or failed since the last read; nothing on the first read.
    $prev = @{ NR1 = 'Running'; OK1 = 'Warning' }
    Assert-Equal (@(Get-DeployNotices -Rows $agreeRows -Previous $null).Count) 0 'no notice on the first read'
    $n = @(Get-DeployNotices -Rows $agreeRows -Previous $prev)
    Assert-Equal "$($n.Count)|$($n[0].Title)|$($n[0].Bad)" '1|PC-NR1 is not ready|True' 'a PC that just finished as not ready gets a notice'
    Assert-Equal $n[0].Text 'Not ready: Google Chrome failed' 'the notice says what failed'
    Assert-Equal (@(Get-DeployNotices -Rows $agreeRows -Previous @{ NR1 = 'Not ready'; OK1 = 'Warning' }).Count) 0 'no notice when nothing changed'
    Assert-Equal (@(Get-DeployNotices -Rows $agreeRows -Previous @{ OK1 = 'Warning' }).Count) 1 'a PC new on the Dashboard that already finished gets one (USB stick import)'

    # USB deploys with no network folder: the console moves the stick's status into the dashboard
    $stick = Join-Path $root 'stick'
    $dash = Join-Path $root 'dash'
    $logs = Join-Path $root 'Logs'
    New-Item -ItemType Directory -Path (Join-Path $stick 'Status'), (Join-Path $stick 'Logs'), $dash -Force | Out-Null
    $rec = { param($id, $updated) [pscustomobject]@{ id = $id; state = 'Succeeded'; started = $updated; updated = $updated } | ConvertTo-Json }
    Set-Content (Join-Path $stick 'Status\USB1.json') (& $rec 'USB1' '2026-11-16T10:00:00Z')
    Set-Content (Join-Path $stick 'Status\USB1.log') 'stick log'
    Set-Content (Join-Path $stick 'Status\OLD1.json') (& $rec 'OLD1' '2026-11-16T09:00:00Z')
    Set-Content (Join-Path $dash 'OLD1.json') (& $rec 'OLD1' '2026-11-16T11:00:00Z')
    Set-Content (Join-Path $stick 'Status\junk.json') 'not json {'
    Set-Content (Join-Path $stick 'Logs\USB1_20261116-1000_OK.log') 'final log'
    $n = Import-StickDeployStatus -StickRoot $stick -Folder $dash -LogFolder $logs
    Assert-Equal $n 1 'stick import counts the deployments it added'
    Assert-Equal "$(Test-Path (Join-Path $dash 'USB1.json'))|$(Get-Content -Raw (Join-Path $dash 'USB1.log'))".Trim() 'True|stick log' 'stick status and live log move to the dashboard'
    Assert-Equal (Get-Content -Raw (Join-Path $dash 'OLD1.json')).Contains('T11:00:00Z') $true 'an older stick record does not replace a newer one'
    Assert-Equal "$(Test-Path (Join-Path $stick 'Status\USB1.json'))|$(Test-Path (Join-Path $stick 'Status\OLD1.json'))" 'False|False' 'imported records leave the stick, so cleared PCs do not come back'
    Assert-Equal (Test-Path (Join-Path $stick 'Status\junk.json')) $true 'unreadable files stay on the stick'
    Assert-Equal "$(Test-Path (Join-Path $logs 'USB1_20261116-1000_OK.log'))|$(Test-Path (Join-Path $stick 'Logs\USB1_20261116-1000_OK.log'))" 'True|True' 'final logs are copied to Deployment Logs and kept on the stick'
    Assert-Equal (Import-StickDeployStatus -StickRoot $stick -Folder $dash -LogFolder $logs) 0 'a second import adds nothing'
    Assert-Equal (Import-StickDeployStatus -StickRoot $stick -Folder (Join-Path $stick 'Status')) 0 'a dashboard folder on the stick itself is left alone'
    Assert-Equal (Test-Path (Join-Path $stick 'Status\junk.json')) $true 'self import deletes nothing'

    $s = [pscustomobject]@{ reporting = [pscustomobject]@{ path = '\\srv\Status' } }
    Assert-Equal (Get-StatusFolder -ContentRoot $root -Settings $s) '\\srv\Status' 'console reads the status share when set'
    Assert-Equal (Get-StatusFolder -ContentRoot $root -Settings ([pscustomobject]@{ share = @{} })) (Join-Path $root 'Status') 'console defaults to the content root Status folder'
    Assert-Equal (Get-StatusFolder -ContentRoot $root -Settings ([pscustomobject]@{ share = [pscustomobject]@{ path = '\\srv\Deploy\' } })) '\\srv\Deploy\Status' 'console reads the share Status folder when a share is set'

    # The result on the PC after first boot: the logon retry, the agent's Retry failed apps and its BitLocker check
    # each change deploy-result.json, and DeployResult.txt is made again whole, so none undoes another.
    $data = Join-Path $root 'deploy-result.json'
    $txt = Join-Path $root 'DeployResult.txt'
    $dep = [pscustomobject]@{ computerName = 'PC9'; maker = 'Dell Inc.'; model = 'Latitude 5521'; driverPack = 'Dell\5521'; state = 'Succeeded' }
    $first = @([pscustomobject]@{ name = 'App: Chrome'; result = 'Failed'; detail = 'Failed: exit 1603' }, [pscustomobject]@{ name = 'BitLocker'; result = 'Warning'; detail = 'Off (FullyDecrypted)' })
    Save-LocalDeployResult -Deploy $dep -Checks $first -Path $data
    Set-Content $txt (Get-DeployResultSummary -Deploy $dep -Checks $first).Text
    Assert-Equal (Update-LocalDeployResult -Results @([pscustomobject]@{ name = 'BitLocker'; result = 'Passed'; detail = 'On (Tpm)' }) -DataPath $data -ResultPath $txt) 'PC9 (Dell Inc. Latitude 5521) - Not ready: Chrome failed' 'BitLocker on: Chrome still fails'
    $v = Update-LocalDeployResult -Results @(ConvertTo-AppChecks -Results @([pscustomobject]@{ name = 'Chrome'; ok = $true; status = 'Installed'; message = 'exit 0' }) -By 'the logon retry') -DataPath $data -ResultPath $txt
    Assert-Equal $v 'PC9 (Dell Inc. Latitude 5521) - Ready' 'Chrome installed by the retry after BitLocker went on: Ready, BitLocker stays on'
    Assert-Equal ((Get-Content -Raw $txt) -match '(?m)^  OK\s+BitLocker\s+On \(Tpm\)') $true 'DeployResult.txt keeps the BitLocker line the agent passed'
    Assert-Equal (@((Get-Content -Raw $data | ConvertFrom-Json).checks).Count) 2 'deploy-result.json: one check per name'
    Assert-Equal ($null -eq (Update-LocalDeployResult -Results @() -DataPath $data -ResultPath $txt)) $true 'nothing new: nothing written'
    # A PC deployed before deploy-result.json: the line changes in place.
    $old = Join-Path $root 'old-result.txt'
    Set-Content $old ("PC8 - Ready, with warnings: BitLocker`r`n" + ('  {0,-8} {1,-13} {2}' -f 'WARNING', 'BitLocker', 'Off'))
    Assert-Equal (Update-LocalDeployResult -Results @([pscustomobject]@{ name = 'BitLocker'; result = 'Passed'; detail = 'On' }) -DataPath (Join-Path $root 'none.json') -ResultPath $old) 'PC8 - Ready' 'no deploy-result.json: the BitLocker line changes in place'
    Assert-Equal "$(@(Merge-CheckResults -Checks @(@{ name = 'A'; result = 'Failed'; detail = 'x' }) -Results @(@{ name = 'A'; result = 'Passed'; detail = 'y' }, @{ name = 'B'; result = 'Passed'; detail = 'z' }) | ForEach-Object { "$($_.name)=$($_.result)" }) -join ',')" 'A=Passed,B=Passed' 'checks merge by name'
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Complete-Tests 'All tests passed'
