<#
.SYNOPSIS
    Runs once on the deployed PC, as SYSTEM, from SetupComplete.cmd before anyone logs on.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\Deploy with firstboot.json and the answer file's applications.
    Installs the applications in order, applies options, restores the user data (LoadState), runs FIRSTBOOT
    tasks, then removes C:\Deploy.
#>
$ErrorActionPreference = 'Continue'
$log = "$env:WINDIR\Temp\FirstBoot.log"
function Write-Log([string]$Message) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) }

$deployDir = $PSScriptRoot
$plan = Get-Content -Raw (Join-Path $deployDir 'firstboot.json') | ConvertFrom-Json
Write-Log "First boot for answer file $($plan.answerFile)"

foreach ($app in $plan.applications) {
    $dir = Join-Path $deployDir "Apps\$($app.name)"
    Write-Log "Installing $($app.name): $($app.command)"
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $($app.command)" -WorkingDirectory $dir -Wait -PassThru -WindowStyle Hidden
    if ($app.successCodes -contains $p.ExitCode) { Write-Log "  $($app.name) OK (exit $($p.ExitCode))" }
    else { Write-Log "  $($app.name) FAILED (exit $($p.ExitCode))" }
}

if ($plan.disableSystemRestore) {
    Disable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-Log 'System Restore disabled'
}
if ($plan.enableAdministrator) {
    & net.exe user Administrator /active:yes | Out-Null
    Write-Log 'Built-in Administrator enabled'
}

# User data after the applications, so their settings land on installed applications.
if ($plan.userState) {
    $us = $plan.userState
    Write-Log "Restoring user data from $($us.store)"
    $loadArgs = @($us.arguments)
    & $us.loadState @loadArgs | Out-Null
    $code = $LASTEXITCODE
    if ($code -in 0, 3) {
        Write-Log "  user data restored (exit $code$(if ($code -eq 3) { ', some files skipped: see C:\Windows\Temp\LoadState.log' }))"
        if (-not $us.keepStore) {
            # Deleting a hard-link store only removes its links; the restored files stay in the profiles.
            & cmd.exe /c "rd /s /q `"$($us.store)`"" 2>&1 | Out-Null
            if (Test-Path $us.store) { Write-Log "  couldn't remove all of $($us.store); delete it by hand" }
        }
    } else {
        Write-Log "  user data restore FAILED (exit $code); the store is kept in $($us.store). See C:\Windows\Temp\LoadState.log"
    }
}

foreach ($cmd in $plan.tasks) {
    Write-Log "FIRSTBOOT task: $cmd"
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $cmd" -Wait -PassThru -WindowStyle Hidden
    Write-Log "  exit $($p.ExitCode)"
}

# Setup already blanked the passwords in the cached unattend.xml; remove it and the installers anyway.
Remove-Item "$env:WINDIR\Panther\unattend.xml" -Force -ErrorAction SilentlyContinue
Write-Log 'First boot finished; removing C:\Deploy'
Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & rd /s /q `"$deployDir`"" -WindowStyle Hidden
