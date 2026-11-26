<#
.SYNOPSIS
    Installs again, silently, the applications that failed at first boot.
.DESCRIPTION
    First boot (FirstBoot.ps1) puts this in C:\ProgramData\ImagingTool\RetryApps (administrators and SYSTEM only) with
    retry.json and the failed apps' packs, and makes the logon task ImagingTool\RetryApps. The task runs this as
    SYSTEM, hidden, 2 minutes after someone logs on: no window, nothing to click, whoever logs on can work (a standard
    user needs no admin rights). Each app is installed the way first boot does (Invoke-AppReinstall).
    The results go on the Dashboard (the PC's status on the share, when it reports there) and in
    C:\Windows\Temp\DeployResult.txt (Update-LocalDeployResult: the whole result is made again, so a BitLocker check
    the agent passed since stays passed). Once every app is installed, or after maxAttempts logons, the task and
    this folder are removed. The agent's Retry failed apps takes the apps it installs out of retry.json, and the two
    never install at the same time (Enter-AppInstallLock). Log: C:\Windows\Temp\RetryApps.log.
#>
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$log = "$env:WINDIR\Temp\RetryApps.log"
Import-Module ([IO.Path]::Combine($dir, 'ScriptLog.psm1')) -Force
function Write-Log([string]$Message) { Write-ScriptLog -Path $log -Message $Message }
$taskName = 'ImagingTool\RetryApps'

function Remove-RetryApps {
    # The task, then this folder (a moment after this script ends).
    & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    Write-Log "Logon task $taskName removed: exit $LASTEXITCODE"
    Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & rd /s /q `"$dir`"" -WindowStyle Hidden
}

$lock = $null
try {
    Import-Module ([IO.Path]::Combine($dir, 'AppPack.psm1')) -Force
    Import-Module ([IO.Path]::Combine($dir, 'DeployStatus.psm1')) -Force
    # One install at a time: another logon's retry, or the agent installing apps the console sent.
    $lock = Enter-AppInstallLock -Minutes 30
    if (-not $lock) { Write-Log 'Another application install is still running after 30 minutes: trying at the next logon'; exit 0 }
    $planPath = [IO.Path]::Combine($dir, 'retry.json')
    # The agent may have installed them all while this waited, and removed this folder's plan.
    if (-not [IO.File]::Exists($planPath)) { Write-Log 'Nothing to install again any more'; exit 0 }
    $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
    $plan.attempts = [int]$plan.attempts + 1
    [IO.File]::WriteAllText($planPath, (ConvertTo-Json -InputObject $plan -Depth 8), (New-Object Text.UTF8Encoding $true))
    $names = @($plan.apps | ForEach-Object { "$($_.name)" })
    Write-Log "Logon retry $($plan.attempts) of $($plan.maxAttempts): installing $($names -join ', ') again"

    $defs = @{}
    foreach ($a in @($plan.apps)) { $defs["$($a.name)"] = $a }
    $results = @(Invoke-AppReinstall -AppRoot ([IO.Path]::Combine($dir, 'Apps')) -Names $names -Definitions $defs -Log { param($m) Write-Log $m })

    # The end-of-deploy result on this PC (the agent's check-in reads its first line). A PC deployed before
    # deploy-result.json existed starts it from what first boot gave this retry.
    try {
        $data = Get-LocalDeployResultPath
        if (-not [IO.File]::Exists($data) -and $plan.deploy) { Save-LocalDeployResult -Deploy $plan.deploy -Checks @($plan.checks) -Path $data }
        $verdict = Update-LocalDeployResult -Results @(ConvertTo-AppChecks -Results $results -By 'the logon retry') -DataPath $data
        if ($verdict) { Write-Log "DeployResult.txt now: $verdict" }
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
    Exit-AppInstallLock $lock
}
