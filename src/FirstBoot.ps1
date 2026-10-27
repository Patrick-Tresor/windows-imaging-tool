<#
.SYNOPSIS
    Runs once on the deployed PC, as SYSTEM, from SetupComplete.cmd before anyone logs on.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\Deploy with firstboot.json and the answer file's applications.
    Installs the applications in order, applies options, runs FIRSTBOOT tasks, then removes C:\Deploy.
    When firstboot.json has a status folder, reports progress to the console's dashboard from 90 to 100 %.
    That folder is a UNC path written as the computer account (SYSTEM), so the share must let Domain Computers
    write to it; if it cannot be reached the deployment still finishes and the dashboard shows it as Stalled.
#>
$ErrorActionPreference = 'Continue'
$log = "$env:WINDIR\Temp\FirstBoot.log"
function Write-Log([string]$Message) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) }

$deployDir = $PSScriptRoot
$plan = Get-Content -Raw (Join-Path $deployDir 'firstboot.json') | ConvertFrom-Json
Write-Log "First boot for answer file $($plan.answerFile)"

$reporting = $false
if ($plan.PSObject.Properties['status'] -and $plan.status.folder) {
    Import-Module (Join-Path $deployDir 'DeployStatus.psm1') -Force
    # The network can take a moment after setup; retry for about a minute before giving up on reporting.
    for ($i = 0; $i -lt 6 -and -not $reporting; $i++) {
        $reporting = Resume-DeployStatus -Folder $plan.status.folder -Id $plan.status.id -LogPath @("$env:WINDIR\Temp\Deploy.log", $log) 3>$null
        if (-not $reporting) { Start-Sleep -Seconds 10 }
    }
    Write-Log $(if ($reporting) { "Reporting status to $($plan.status.folder)" } else { "Status folder $($plan.status.folder) unreachable; not reporting" })
}
function Set-Progress([string]$Step, [int]$Percent, [string]$Warning) {
    if ($reporting) { Set-DeployStatus -Step $Step -Percent $Percent -Phase 'FirstBoot' -Warning $Warning -Fields @{ computerName = $env:COMPUTERNAME } }
}
Set-Progress 'First boot: starting' 91
$total = @($plan.applications).Count
$n = 0

foreach ($app in $plan.applications) {
    $dir = Join-Path $deployDir "Apps\$($app.name)"
    $n++
    Write-Log "Installing $($app.name): $($app.command)"
    Set-Progress "Installing $($app.name) ($n of $total)" (91 + [int](7 * ($n - 1) / [Math]::Max(1, $total)))
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $($app.command)" -WorkingDirectory $dir -Wait -PassThru -WindowStyle Hidden
    if ($app.successCodes -contains $p.ExitCode) { Write-Log "  $($app.name) OK (exit $($p.ExitCode))" }
    else {
        Write-Log "  $($app.name) FAILED (exit $($p.ExitCode))"
        Set-Progress "Installed $($app.name)" (91 + [int](7 * $n / [Math]::Max(1, $total))) "$($app.name) failed (exit $($p.ExitCode))"
    }
}

if ($plan.disableSystemRestore) {
    Disable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-Log 'System Restore disabled'
}
if ($plan.enableAdministrator) {
    & net.exe user Administrator /active:yes | Out-Null
    Write-Log 'Built-in Administrator enabled'
}

if (@($plan.tasks).Count) { Set-Progress 'Running first boot tasks' 98 }
foreach ($cmd in $plan.tasks) {
    Write-Log "FIRSTBOOT task: $cmd"
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $cmd" -Wait -PassThru -WindowStyle Hidden
    Write-Log "  exit $($p.ExitCode)"
}

# Setup already blanked the passwords in the cached unattend.xml; remove it and the installers anyway.
Remove-Item "$env:WINDIR\Panther\unattend.xml" -Force -ErrorAction SilentlyContinue
Write-Log 'First boot finished; removing C:\Deploy'
if ($reporting) { Set-DeployStatus -Step 'Deployment complete' -Percent 100 -State Succeeded -Fields @{ computerName = $env:COMPUTERNAME } }
Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & rd /s /q `"$deployDir`"" -WindowStyle Hidden
