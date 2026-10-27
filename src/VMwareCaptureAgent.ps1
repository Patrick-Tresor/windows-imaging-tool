<#
.SYNOPSIS
    Runs inside a VMware reference VM so the admin PC can capture it hands-free: install it once, and the capture
    starts sysprep in the VM by itself.
.DESCRIPTION
    Install it once in the reference VM, from an elevated PowerShell window:
        powershell -ExecutionPolicy Bypass -File \\server\Deploy\Tools\VMwareCaptureAgent.ps1 -Install
    It copies itself and Prepare-Reference.ps1 (from the same folder) to C:\ProgramData\ImagingTool\CaptureAgent and
    adds a scheduled task that runs at startup as SYSTEM.

    At each startup the task waits up to 30 minutes for the admin PC to ask for a capture, which
    Capture-VMImage.ps1 -VmxPath does by setting the VMware guest variable guestinfo.imagingtool.capture. Nothing
    else starts it: a normal boot of the VM does nothing. When asked, it answers in guestinfo.imagingtool.state,
    removes its task and folder (so they are not in the image), and runs Prepare-Reference.ps1 -RemoveUserApps,
    which runs sysprep and shuts the VM down. If the checks or sysprep fail it shuts the VM down anyway, and its
    log (C:\Windows\Temp\ImagingTool\capture-agent.log) tells the admin PC why. The admin PC rolls the VM back
    to its snapshot from before the capture, so the agent is installed again afterwards.

    Needs VMware Tools in the VM. Untested on Windows.
.EXAMPLE
    .\VMwareCaptureAgent.ps1 -Install
.EXAMPLE
    .\VMwareCaptureAgent.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Install')][switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Run')][int]$WaitMinutes = 30
)

$ErrorActionPreference = 'Stop'
$taskName = 'ImagingTool VMware capture agent'
$agentDir = Join-Path $env:ProgramData 'ImagingTool\CaptureAgent'
$workDir = Join-Path $env:WINDIR 'Temp\ImagingTool'     # removed from the image by the admin PC before the capture
$toolsd = Join-Path $env:ProgramFiles 'VMware\VMware Tools\vmtoolsd.exe'
$requestVar = 'guestinfo.imagingtool.capture'           # Get-VMwareCaptureVariables in VMwareVM.psm1
$stateVar = 'guestinfo.imagingtool.state'

function Remove-Agent {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $agentDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-GuestVariable([string]$Name) {
    # vmtoolsd prints the value, or fails when the variable is not set.
    $out = & $toolsd --cmd "info-get $Name" 2>$null
    if ($LASTEXITCODE -eq 0) { "$out".Trim() }
}

function Set-GuestVariable([string]$Name, [string]$Value) {
    & $toolsd --cmd "info-set $Name $Value" 2>$null | Out-Null
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell window.' }

if ($Uninstall) {
    Remove-Agent
    Write-Host 'Removed the capture agent.'
    return
}

if ($Install) {
    if (-not (Test-Path -LiteralPath $toolsd)) { throw "VMware Tools is not installed in this VM ($toolsd is missing). Install it from VMware Workstation (VM > Install VMware Tools), then run this again." }
    $prepare = Join-Path $PSScriptRoot 'Prepare-Reference.ps1'
    if (-not (Test-Path -LiteralPath $prepare)) { throw "Prepare-Reference.ps1 must be in the same folder as this script ($PSScriptRoot)." }
    New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath, $prepare -Destination $agentDir -Force
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $agentDir 'VMwareCaptureAgent.ps1')`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host 'Capture agent installed. Shut the VM down; the capture wizard on the admin PC does the rest.' -ForegroundColor Green
    Write-Host 'A normal boot of this VM does nothing; sysprep runs only when the admin PC starts a capture.'
    return
}

# Run at startup: wait for the admin PC to ask.
if (-not (Test-Path -LiteralPath $toolsd)) { return }
$deadline = (Get-Date).AddMinutes($WaitMinutes)
while ((Get-GuestVariable $requestVar) -ne 'sysprep') {
    if ((Get-Date) -gt $deadline) { return }
    Start-Sleep -Seconds 10
}

Set-GuestVariable $stateVar 'started'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$log = Join-Path $workDir 'capture-agent.log'
$prepare = Join-Path $workDir 'Prepare-Reference.ps1'
Copy-Item -LiteralPath (Join-Path $agentDir 'Prepare-Reference.ps1') -Destination $prepare -Force
"$(Get-Date -Format s) Capture requested by the admin PC. Running Prepare-Reference.ps1 -RemoveUserApps." | Set-Content -LiteralPath $log -Encoding ASCII

# The task and its folder must not end up in the image. The VM goes back to its snapshot afterwards, which brings
# them back for the next capture.
Remove-Agent

$failed = $false
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prepare -RemoveUserApps 2>&1 |
        ForEach-Object { "$_" } | Add-Content -LiteralPath $log -Encoding ASCII
    if ($LASTEXITCODE -ne 0) { $failed = $true; "$(Get-Date -Format s) Prepare-Reference.ps1 stopped (exit code $LASTEXITCODE)." | Add-Content -LiteralPath $log -Encoding ASCII }
    # sysprep shuts Windows down when it succeeds. Wait for it, in case it was started without waiting.
    Get-Process sysprep -ErrorAction SilentlyContinue | Wait-Process -Timeout 3600 -ErrorAction SilentlyContinue
}
catch {
    $failed = $true
    "$(Get-Date -Format s) $($_.Exception.Message)" | Add-Content -LiteralPath $log -Encoding ASCII
}

# sysprep has ended. When it generalized Windows, its own shutdown is under way; otherwise it failed. Either way
# shut down, so the admin PC stops waiting (and, after a failure, shows this log).
$imageState = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState -ErrorAction SilentlyContinue).ImageState
if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
    "$(Get-Date -Format s) sysprep finished." | Add-Content -LiteralPath $log -Encoding ASCII
    Start-Sleep -Seconds 120
}
else {
    if (-not $failed) { "$(Get-Date -Format s) sysprep ended without generalizing Windows (ImageState $imageState). See C:\Windows\System32\Sysprep\Panther\setuperr.log." | Add-Content -LiteralPath $log -Encoding ASCII }
    Set-GuestVariable $stateVar 'failed'
}
Stop-Computer -Force
