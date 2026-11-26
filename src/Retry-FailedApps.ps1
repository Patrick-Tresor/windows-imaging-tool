<#
.SYNOPSIS
    Installs again, silently, the applications that failed at first boot.
.DESCRIPTION
    First boot (FirstBoot.ps1) puts this in C:\ProgramData\ImagingTool\RetryApps (administrators and SYSTEM only) with
    retry.json and the failed apps' packs, and makes the logon task ImagingTool\RetryApps. The task runs this as
    SYSTEM, hidden, 2 minutes after someone logs on: no window, nothing to click, whoever logs on can work (a standard
    user needs no admin rights). Each app is installed the way first boot does (Invoke-AppInstall).
    The results go on the Dashboard (the PC's status on the share, when it reports there) and in
    C:\Windows\Temp\DeployResult.txt. Once every app is installed, or after maxAttempts logons, the task and this
    folder are removed. Log: C:\Windows\Temp\RetryApps.log.
#>
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$log = "$env:WINDIR\Temp\RetryApps.log"
Import-Module ([IO.Path]::Combine($dir, 'ScriptLog.psm1')) -Force
function Write-Log([string]$Message) { Write-ScriptLog -Path $log -Message $Message }
$taskName = 'ImagingTool\RetryApps'

# One run at a time (two logons close together).
$mutex = New-Object Threading.Mutex($false, 'Global\ImagingToolRetryApps')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

function Remove-RetryApps {
    # The task, then this folder (a moment after this script ends).
    & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    Write-Log "Logon task $taskName removed: exit $LASTEXITCODE"
    Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & rd /s /q `"$dir`"" -WindowStyle Hidden
}

try {
    Import-Module ([IO.Path]::Combine($dir, 'AppPack.psm1')) -Force
    Import-Module ([IO.Path]::Combine($dir, 'DeployStatus.psm1')) -Force
    $planPath = [IO.Path]::Combine($dir, 'retry.json')
    $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
    $plan.attempts = [int]$plan.attempts + 1
    [IO.File]::WriteAllText($planPath, (ConvertTo-Json -InputObject $plan -Depth 8), (New-Object Text.UTF8Encoding $true))
    $names = @($plan.apps | ForEach-Object { "$($_.name)" })
    Write-Log "Logon retry $($plan.attempts) of $($plan.maxAttempts): installing $($names -join ', ') again"

    $results = @()
    foreach ($plain in @($plan.apps)) {
        $app = ConvertTo-AppDefinition -Name $plain.name -Json $plain
        $r = try { Invoke-AppInstall -Definition $app -AppFolder ([IO.Path]::Combine($dir, "Apps\$($app.name)")) -LogPath "$env:WINDIR\Temp\App-$($app.name).log" -Log { param($m) Write-Log $m } }
             catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; RebootNeeded = $false; Message = $_.Exception.Message } }
        $ok = $r.Status -in 'Installed', 'AlreadyInstalled'
        Write-Log "  $($app.name) $(if ($ok) { 'OK' } else { 'FAILED' }) ($($r.Status)): $($r.Message)"
        $results += [pscustomobject]@{ name = $app.name; ok = $ok; status = "$($r.Status)"; message = "$($r.Message)" }
    }

    # The end-of-deploy result on this PC (the agent's check-in reads its first line).
    $plan.checks = @(Set-AppCheckResults -Checks @($plan.checks) -Results $results -By 'the logon retry')
    try {
        $summary = Get-DeployResultSummary -Deploy $plan.deploy -Checks @($plan.checks)
        Set-Content -Path "$env:WINDIR\Temp\DeployResult.txt" -Value $summary.Text -Encoding utf8
        Write-Log "Deployment result now: $($summary.Verdict)"
    } catch { Write-Log "Could not update DeployResult.txt: $($_.Exception.Message)" }

    # The Dashboard (as the computer account, like first boot). A share that can't be reached is tried at the next logon.
    if ($plan.status -and $plan.status.folder) {
        try {
            $row = Update-DeployAppResults -StatusFolder $plan.status.folder -Id "$($plan.status.id)" -Results $results -By 'the logon retry'
            Write-Log $(if ($row) { "Dashboard updated in $($plan.status.folder)" } else { "No status for this PC in $($plan.status.folder) any more; Dashboard not updated" })
        } catch { Write-Log "Could not update the Dashboard: $($_.Exception.Message)" }
    }

    $left = @($plan.apps | Where-Object { $n = "$($_.name)"; @($results | Where-Object { $_.name -eq $n -and -not $_.ok }).Count })
    $plan.apps = @($left)
    [IO.File]::WriteAllText($planPath, (ConvertTo-Json -InputObject $plan -Depth 8), (New-Object Text.UTF8Encoding $true))
    if (-not $left) { Write-Log 'Every application is installed now'; Remove-RetryApps }
    elseif ($plan.attempts -ge [int]$plan.maxAttempts) { Write-Log "Giving up after $($plan.attempts) logons: $(($left | ForEach-Object name) -join ', ') still not installed"; Remove-RetryApps }
    else { Write-Log "Trying $(($left | ForEach-Object name) -join ', ') again at the next logon" }
} catch {
    Write-Log "Logon retry failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
} finally {
    if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
}
