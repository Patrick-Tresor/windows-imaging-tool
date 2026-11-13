# Plain-PowerShell tests for sysprep at deploy time (src/SysprepAtDeploy.psm1): the one-time startup command WinPE
# writes into the new Windows, Fast Startup detection on a captured disk, and what a PC reports when sysprep fails.
# Run: powershell -File tests\SysprepAtDeploy.Tests.ps1; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/SysprepAtDeploy.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# The startup command: SYSTEM\Setup SetupType 2 + CmdLine, and device encryption held off for that boot.
$cmd = Get-SysprepHookCommand
Assert-Equal $cmd 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ImagingTool\Sysprep\Invoke-SysprepAtDeploy.ps1" -Stage Hook' 'hook command runs the script from the deployed C: drive'
$regArgs = @(Get-SysprepHookRegArgs -HiveKey 'HKLM\T' -Command $cmd -ControlSet 'ControlSet001' -PreventDeviceEncryption)
Assert-Equal $regArgs.Count 3 'three registry writes with device encryption held off'
Assert-Equal ($regArgs[0] -join ' ') 'add HKLM\T\Setup /v SetupType /t REG_DWORD /d 2 /f' 'SetupType 2 runs CmdLine before the logon screen'
Assert-Equal $regArgs[1][1] 'HKLM\T\Setup' 'CmdLine goes to the Setup key'
Assert-Equal $regArgs[1][7] $cmd 'CmdLine is the hook command, as one argument'
Assert-Equal ($regArgs[2] -join ' ') 'add HKLM\T\ControlSet001\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f' 'device encryption held off in the current control set'
$regArgs = @(Get-SysprepHookRegArgs -HiveKey 'HKLM\T' -Command $cmd -ControlSet 'ControlSet001')
Assert-Equal $regArgs.Count 2 'a value the reference already had is left alone'

Assert-Equal (Get-ControlSetName -Lines @('', 'HKEY_LOCAL_MACHINE\T\Select', '    Current    REG_DWORD    0x2', '')) 'ControlSet002' 'control set from Select\Current'
Assert-Equal (Get-ControlSetName -Lines @()) 'ControlSet001' 'control set defaults to 001 when unreadable'
Assert-Equal (Test-RegQueryHasValue -Name 'PreventDeviceEncryption' -Lines @('HKEY_LOCAL_MACHINE\T\X', '    PreventDeviceEncryption    REG_DWORD    0x0')) $true 'a listed value is found'
Assert-Equal (Test-RegQueryHasValue -Name 'PreventDeviceEncryption' -Lines @()) $false 'a missing key has no value'

Assert-Equal ((Get-SysprepArguments -UnattendPath 'C:\ProgramData\ImagingTool\Sysprep\unattend.xml') -join ' ') '/generalize /oobe /reboot /quiet /unattend:C:\ProgramData\ImagingTool\Sysprep\unattend.xml' 'sysprep generalizes, goes to OOBE with the answer file, restarts'

$cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$wu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
Assert-Equal ((Get-PendingRebootMarkers -ExistingKeys @($cbs, $wu)) -join ',') 'servicing,windowsupdate' 'both restart markers are named'
Assert-Equal (@(Get-PendingRebootMarkers -ExistingKeys @()).Count) 0 'no key, no marker'
Assert-Equal (Test-RebootPendingFor -Markers @('servicing') -Attempt 1) $true 'pending servicing restarts before sysprep'
Assert-Equal (Test-RebootPendingFor -Markers @('servicing', 'windowsupdate') -Attempt 2) $true 'a second restart is allowed'
Assert-Equal (Test-RebootPendingFor -Markers @('servicing') -Attempt 3) $false 'restarts stop after two, sysprep is tried'
Assert-Equal (Test-RebootPendingFor -Markers @('windowsupdate') -Attempt 1) $false 'the Windows Update flag alone does not restart'
Assert-Equal (Test-RebootPendingFor -Markers @() -Attempt 1) $false 'no restart when none is pending'

# The Run stage handles the pending restart itself; the checks before sysprep must not stop on it again.
$run = Get-Content -Raw (Join-Path $repo 'src/Invoke-SysprepAtDeploy.ps1')
Assert-Equal ($run -match '-File \$prepare -CheckOnly -RemoveUserApps -SkipRebootCheck') $true 'sysprep at deploy runs the checks with -SkipRebootCheck'
$prep = Get-Content -Raw (Join-Path $repo 'src/Prepare-Reference.ps1')
Assert-Equal ($prep -match 'if \(\$SkipRebootCheck\) \{ \$warnings\.Add') $true 'Prepare-Reference -SkipRebootCheck only warns about a pending restart'

$ok = Get-SysprepOutcome -ImageState 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -ExitCode 0
Assert-Equal $ok.Ok $true 'generalized Windows is a success'
$bad = Get-SysprepOutcome -ImageState 'IMAGE_STATE_COMPLETE' -ExitCode 1 -ErrorLines @(
    '2026-11-10 10:00:00, Error                 SYSPRP Package Microsoft.Foo_1.0 was installed for a user, but not provisioned for all users.',
    '2026-11-10 10:00:01, Error                 [0x0f0082] SYSPRP ActionPlatform::LaunchModule: Failure occurred while executing SysprepGeneralizeValidate')
Assert-Equal $bad.Ok $false 'not generalized is a failure'
Assert-Equal ($bad.Reason -like 'sysprep exited with code 1 and Windows is still IMAGE_STATE_COMPLETE. Last error: *SysprepGeneralizeValidate') $true 'the reason has the exit code and the last SYSPRP line'

$notice = Get-SysprepFailureNotice -Reason ("x" * 400)
Assert-Equal $notice.Caption 'Deployment not finished: sysprep failed' 'failure notice caption'
Assert-Equal ($notice.Text.Length -lt 600) $true 'a long reason is shortened on the logon screen'
Assert-Equal ($notice.Text -like '*C:\Windows\Temp\SysprepAtDeploy.log*') $true 'the notice points at the log'

# Fast Startup leaves 'hibr' at the start of hiberfil.sys; a full shutdown or a resume does not.
$dir = Join-Path ([IO.Path]::GetTempPath()) ("imaging-sysprep-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    Assert-Equal (Test-HibernatedWindows -Root $dir) $false 'no hiberfil.sys: not hibernated'
    $hib = [IO.Path]::Combine($dir, 'hiberfil.sys')
    [IO.File]::WriteAllBytes($hib, [byte[]](0x68, 0x69, 0x62, 0x72, 0, 0, 0, 0))
    Assert-Equal (Test-HibernatedWindows -Root $dir) $true 'hibr signature: hibernated'
    [IO.File]::WriteAllBytes($hib, [byte[]](0x48, 0x49, 0x42, 0x52, 0, 0))
    Assert-Equal (Test-HibernatedWindows -Root $dir) $true 'HIBR signature: hibernated'
    [IO.File]::WriteAllBytes($hib, [byte[]](0, 0, 0, 0, 0, 0))
    Assert-Equal (Test-HibernatedWindows -Root $dir) $false 'an empty header: shut down fully'
    [IO.File]::WriteAllBytes($hib, [byte[]](0x77, 0x61, 0x6B, 0x65))
    Assert-Equal (Test-HibernatedWindows -Root $dir) $false 'wake signature: resumed, not hibernated'

    # WinPE tells a not-sysprepped image apart after applying it (Get-OfflineImageState on W:\).
    $stateDir = [IO.Path]::Combine($dir, 'Windows', 'Setup', 'State')
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [IO.File]::WriteAllText([IO.Path]::Combine($stateDir, 'State.ini'), "[State]`r`nImageState=IMAGE_STATE_COMPLETE`r`n")
    Assert-Equal (Get-OfflineImageState -Root $dir).Generalized $false 'an applied image that was not sysprepped is detected'
    [IO.File]::WriteAllText([IO.Path]::Combine($stateDir, 'State.ini'), "[State]`r`nImageState=IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`r`n")
    Assert-Equal (Get-OfflineImageState -Root $dir).Generalized $true 'a sysprepped image takes the usual route'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# Deploy-Image sets the hook only for a not-sysprepped image, after the unattend and before the boot files.
$deploy = [IO.File]::ReadAllText((Join-Path $repo 'src/Deploy-Image.ps1'))
$detect = $deploy.IndexOf('$sysprepOnPC = -not $imageState.Generalized')
$hook = $deploy.IndexOf('Set-SysprepAtDeploy -UnattendXml $unattendXml')
$boot = $deploy.IndexOf("Invoke-Native -FilePath 'W:\Windows\System32\bcdboot.exe'")
Assert-Equal ($detect -gt 0 -and $hook -gt $detect -and $boot -gt $hook) $true 'deploy: detect, then hook, then boot files'
# The scripts the PC runs are copied with it.
foreach ($f in 'Invoke-SysprepAtDeploy.ps1', 'SysprepAtDeploy.psm1', 'Prepare-Reference.ps1') {
    Assert-Equal ($deploy.Contains("(Join-Path `$PSScriptRoot '$f')")) $true "deploy copies $f to the PC"
}
# The hook removes everything of its own before sysprep, so nothing reaches the generalized Windows.
$script = [IO.File]::ReadAllText((Join-Path $repo 'src/Invoke-SysprepAtDeploy.ps1'))
$sysprepAt = $script.IndexOf('$proc = Start-Process -FilePath $sysprep')
foreach ($cleanup in '& schtasks.exe /Delete /TN $taskName /F', "-Name PreventDeviceEncryption") {
    $at = $script.LastIndexOf($cleanup, $sysprepAt)
    Assert-Equal ($at -gt 0 -and $at -lt $sysprepAt) $true "the run stage cleans up before sysprep: $cleanup"
}

# Nothing on screen while sysprep runs; the logon screen only speaks up when it failed.
Assert-Equal ($script.Contains('Get-SysprepBusyNotice') -or $script.Contains('Preparing this PC')) $false 'no notice on the logon screen while sysprep runs'
$hookAt = $script.IndexOf("if (`$Stage -eq 'Hook')")
Assert-Equal ($script.IndexOf('Set-Notice', $hookAt) -lt 0) $true 'the hook stage sets no logon notice'

# Seamless: the hook waits for the Run stage (no logon screen meanwhile) and keeps the startup command until the end.
Assert-Equal (Test-SysprepHookDone -State 'running') $false 'hook keeps waiting while the checks run'
Assert-Equal (Test-SysprepHookDone -State 'sysprep') $false 'hook keeps waiting while sysprep runs'
foreach ($st in 'done', 'failed', 'restart') { Assert-Equal (Test-SysprepHookDone -State $st) $true "hook stops waiting: $st" }
$hookPart = $script.Substring($hookAt)
Assert-Equal ($hookPart.Contains('Clear-StartupHook') -or $hookPart.Contains("-Name SetupType")) $false 'the hook does not turn the startup command off before sysprep'
Assert-Equal ($hookPart.Contains('while ($clock.Elapsed.TotalMinutes -lt (Get-SysprepWaitMinutes -State $state))')) $true 'the hook waits for the task'
# A slow sysprep is not called failed: the limit grows once sysprep itself runs.
Assert-Equal (Get-SysprepWaitMinutes -State 'running') 45 'the checks before sysprep get 45 minutes'
Assert-Equal (Get-SysprepWaitMinutes -State '') 45 'a task that has not started gets 45 minutes'
Assert-Equal (Get-SysprepWaitMinutes -State 'sysprep') 180 'sysprep itself gets 3 hours'
# First boot means sysprep finished: it clears our failure notice (and only ours) if the hook gave up too early.
$firstBoot = [IO.File]::ReadAllText((Join-Path $repo 'src/FirstBoot.ps1'))
Assert-Equal ($firstBoot.Contains("-eq '$((Get-SysprepFailureNotice -Reason 'x').Caption)'")) $true 'first boot clears the sysprep failure notice by its exact caption'
$failAt = $script.IndexOf('function Stop-WithFailure')
Assert-Equal ($script.IndexOf('Clear-StartupHook', $failAt) -lt $script.IndexOf('function Invoke-RunStage')) $true 'a failure turns the startup command off'
# The deploy screen says nothing about sysprep: only the log file does.
$setPart = $deploy.Substring($deploy.IndexOf('function Set-SysprepAtDeploy'), $deploy.IndexOf('function Invoke-Phase(') - $deploy.IndexOf('function Set-SysprepAtDeploy'))
Assert-Equal ($setPart.Contains('Write-DeployLog ''Sysprep') -or $setPart.Contains("Invoke-Native -FilePath 'reg.exe'")) $false 'setting up sysprep prints nothing on the deploy screen'
Assert-Equal ($deploy.Contains("Set-DeployStatus -Step 'Setting up sysprep")) $false 'no sysprep step in the deploy progress'

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All sysprep at deploy tests passed.' -ForegroundColor Green
