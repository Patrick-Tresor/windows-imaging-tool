<#
.SYNOPSIS
    Re-runs the post-deploy checks on a deployed PC and updates its row on the console's dashboard.
.DESCRIPTION
    FirstBoot.ps1 runs the checks once, at the end of first boot, and leaves this script with its state in
    C:\ProgramData\ImagingTool. Run it again after fixing something (a missing driver, a failed domain join),
    or after a reboot, when BitLocker has finished encrypting. Run as an administrator; reporting writes to the
    status share as the signed-in user, or as the computer account when run as SYSTEM (a scheduled task, for example).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\ProgramData\ImagingTool\Test-Deployment.ps1
#>
[CmdletBinding()]
param(
    [string]$StatePath = (Join-Path $PSScriptRoot 'checks.json'),
    [switch]$NoReport           # check and print only; the dashboard keeps the previous result
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PostDeployChecks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1') -Force

$state = Get-Content -Raw $StatePath | ConvertFrom-Json
$run = Start-PostDeployCheck -Plan $state.checks -AppResults @($state.appResults) -ReportPath (Join-Path $PSScriptRoot 'last-check.json')

$colors = @{ Passed = 'Green'; Failed = 'Red'; Warning = 'Yellow'; Skipped = 'Gray' }
foreach ($r in $run.Results) {
    Write-Host ('{0,-8} ' -f $r.result) -ForegroundColor $colors[$r.result] -NoNewline
    Write-Host "$($r.name): $($r.detail)"
}
Write-Host ''
Write-Host "Post-deploy checks: $($run.Summary.Text)" -ForegroundColor $colors[$(if ($run.Summary.Result -eq 'None') { 'Skipped' } else { $run.Summary.Result })]

if (-not $NoReport -and $state.status -and $state.status.folder) {
    if (Resume-DeployStatus -Folder $state.status.folder -Id $state.status.id) {
        Set-DeployCheckResult -Results $run.Results -Summary $run.Summary -Warning (ConvertTo-CheckWarning $run.Summary)
        Write-Host "Dashboard updated ($($state.status.folder))"
    } else {
        Write-Warning "Could not reach $($state.status.folder); the dashboard still shows the previous result."
    }
}
if ($run.Summary.Result -eq 'Failed') { exit 1 }
