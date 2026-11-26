<#
.SYNOPSIS
    Installs again, silently, the applications that failed at first boot, on a PC without the agent.
.DESCRIPTION
    First boot (FirstBoot.ps1) puts the failed apps' packs and retry.json in C:\ProgramData\ImagingTool\RetryApps
    (administrators and SYSTEM only). On a PC with the agent, the agent installs them again at its check-ins (an hour
    after first boot, then hourly). A PC without it (deployed without a network share) gets the logon task
    ImagingTool\RetryApps, which runs this as SYSTEM, hidden, 2 minutes after someone logs on: no window, nothing to
    click. Both run the same Invoke-AppRetryPlan (AppPack.psm1) and report with Publish-AppRetryResults
    (DeployStatus.psm1: DeployResult.txt and the Dashboard). Once every app is installed, or after maxAttempts
    tries, the task and this folder are removed. Log: C:\Windows\Temp\RetryApps.log.
#>
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$log = "$env:WINDIR\Temp\RetryApps.log"
Import-Module ([IO.Path]::Combine($dir, 'ScriptLog.psm1')) -Force
function Write-Log([string]$Message) { Write-ScriptLog -Path $log -Message $Message }

try {
    Import-Module ([IO.Path]::Combine($dir, 'DeployStatus.psm1')) -Force
    Import-Module ([IO.Path]::Combine($dir, 'AppPack.psm1')) -Force
    $r = Invoke-AppRetryPlan -Dir $dir -By 'the logon retry' -WaitMinutes 30 -Log { param($m) Write-Log $m } `
        -OnResults { param($Plan, $Results) Publish-AppRetryResults -Plan $Plan -Results $Results -By 'the logon retry' -Log { param($m) Write-Log $m } } `
        -RemoveFolder { Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & rd /s /q `"$dir`"" -WindowStyle Hidden }
    if (-not $r.Ran) { Write-Log "Nothing done: $($r.Message)" }
} catch {
    Write-Log "Logon retry failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
}
