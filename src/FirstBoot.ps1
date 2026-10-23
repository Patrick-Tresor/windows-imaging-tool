<#
.SYNOPSIS
    Runs once on the deployed PC, as SYSTEM, from SetupComplete.cmd before anyone logs on.
.DESCRIPTION
    Deploy-Image.ps1 copies this to C:\Deploy with firstboot.json and the answer file's applications.
    Installs the applications in order, applies options, runs FIRSTBOOT tasks, then removes C:\Deploy.
#>
$ErrorActionPreference = 'Continue'
$log = "$env:WINDIR\Temp\FirstBoot.log"
function Write-Log([string]$Message) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) }

$deployDir = $PSScriptRoot
$plan = Get-Content -Raw (Join-Path $deployDir 'firstboot.json') | ConvertFrom-Json
Write-Log "First boot for answer file $($plan.answerFile)"

# Each app is skipped when its detection rules find it already installed, and checked again after it runs.
Import-Module (Join-Path $deployDir 'AppPack.psm1') -Force
$appResults = @()
foreach ($plain in $plan.applications) {
    $app = ConvertTo-AppDefinition -Name $plain.name -Json $plain
    $dir = Join-Path $deployDir "Apps\$($app.name)"
    Write-Log "Installing $($app.name)"
    $r = try { Invoke-AppInstall -Definition $app -AppFolder $dir -Log { param($m) Write-Log $m } }
         catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; RebootNeeded = $false; Message = $_.Exception.Message } }
    $level = if ($r.Status -in 'Installed', 'AlreadyInstalled') { 'OK' } else { 'FAILED' }
    Write-Log "  $($app.name) $level ($($r.Status)): $($r.Message)"
    $appResults += [pscustomobject]@{ name = $app.name; status = $r.Status; exitCode = $r.ExitCode; rebootNeeded = $r.RebootNeeded; message = $r.Message }
}
# Kept after C:\Deploy is removed, for whoever checks the PC (and the deployment dashboard).
$appResults | ConvertTo-Json -Depth 3 | Set-Content "$env:WINDIR\Temp\FirstBoot-apps.json" -Encoding utf8

if ($plan.disableSystemRestore) {
    Disable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-Log 'System Restore disabled'
}
if ($plan.enableAdministrator) {
    & net.exe user Administrator /active:yes | Out-Null
    Write-Log 'Built-in Administrator enabled'
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
