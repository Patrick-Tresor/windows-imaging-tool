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

Assert-Equal (Test-RebootPendingFor -Pending $true -Attempt 1) $true 'a pending restart comes before sysprep'
Assert-Equal (Test-RebootPendingFor -Pending $true -Attempt 3) $false 'restarts stop after three attempts'
Assert-Equal (Test-RebootPendingFor -Pending $false -Attempt 1) $false 'no restart when none is pending'

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
foreach ($cleanup in '& schtasks.exe /Delete /TN $taskName /F', 'Restore-Notice', "-Name PreventDeviceEncryption") {
    $at = $script.LastIndexOf($cleanup, $sysprepAt)
    Assert-Equal ($at -gt 0 -and $at -lt $sysprepAt) $true "the run stage cleans up before sysprep: $cleanup"
}

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All sysprep at deploy tests passed.' -ForegroundColor Green
