# Plain-PowerShell tests for Get-OfflineImageState, which the WinPE capture uses to refuse a Windows that was not
# sysprepped and to say why. Run: pwsh -File tests/CaptureState.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("capture-state-test-" + [guid]::NewGuid())
$stateDir = Join-Path $root 'Windows/Setup/State'
$panther = Join-Path $root 'Windows/System32/Sysprep/Panther'
New-Item -ItemType Directory -Path $stateDir, $panther | Out-Null
$ini = Join-Path $stateDir 'State.ini'
try {
    $s = Get-OfflineImageState -Root $root
    Assert-Equal $s.Generalized $true 'no State.ini cannot be checked, so it does not block'
    Assert-Equal ($null -eq $s.ImageState) $true 'no State.ini gives no ImageState'

    # Windows writes State.ini as UTF-16 with a BOM.
    Set-Content -LiteralPath $ini -Value '[State]', 'ImageState=IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -Encoding Unicode
    $s = Get-OfflineImageState -Root $root
    Assert-Equal $s.Generalized $true 'sysprepped Windows is generalized'
    Assert-Equal $s.ImageState 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' 'sysprepped ImageState is read'

    Set-Content -LiteralPath $ini -Value '[State]', 'ImageState = IMAGE_STATE_COMPLETE' -Encoding ASCII
    $s = Get-OfflineImageState -Root $root
    Assert-Equal $s.Generalized $false 'a Windows that is in use is not generalized'
    Assert-Equal $s.ImageState 'IMAGE_STATE_COMPLETE' 'ImageState with spaces around = is read'
    Assert-Equal ($null -eq $s.LastError) $true 'no Panther log, no error'

    Set-Content -LiteralPath (Join-Path $panther 'setuperr.log') -Value @(
        '2026-10-27 12:01:02, Error      SYSPRP Package Microsoft.Copilot_1.0 was installed for a user, but not provisioned for all users.',
        '2026-10-27 12:01:03, Error      SYSPRP Failed to remove apps for the current user: 0x80073cf2.')
    $s = Get-OfflineImageState -Root $root
    Assert-Equal $s.LastError '2026-10-27 12:01:03, Error      SYSPRP Failed to remove apps for the current user: 0x80073cf2.' 'last sysprep error is reported'

    Set-Content -LiteralPath $ini -Value '[State]' -Encoding ASCII
    Assert-Equal (Get-OfflineImageState -Root $root).Generalized $false 'State.ini without ImageState is not generalized'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All capture state tests passed.' -ForegroundColor Green
