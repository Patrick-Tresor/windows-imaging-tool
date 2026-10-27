# Plain-PowerShell tests for the setuperr.log check in Prepare-Reference.ps1: only a sysprep failure from the
# latest run since the last boot is reported, never a log a Windows upgrade left. Run: pwsh -File tests/SysprepLog.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repo 'src/Prepare-Reference.ps1'

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# The script needs admin rights and runs sysprep, so load only its log function.
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SysprepErrors' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))

$dir = Join-Path ([IO.Path]::GetTempPath()) ("sysprep-log-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
$errLog = Join-Path $dir 'setuperr.log'
$actLog = Join-Path $dir 'setupact.log'
function Set-Logs([string[]]$Err, [string[]]$Act) {
    Remove-Item -LiteralPath $errLog, $actLog -Force -ErrorAction SilentlyContinue
    if ($Err) { Set-Content -LiteralPath $errLog -Value $Err }
    if ($Act) { Set-Content -LiteralPath $actLog -Value $Act }
}
$boot = [datetime]'2026-10-27 08:00:00'

try {
    Set-Logs
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir -Since $boot).Count) 0 'no setuperr.log, nothing to report'

    # What a Windows upgrade leaves: no sysprep lines at all, and from before the last boot.
    $upgrade = @(
        '2026-06-04 14:02:11, Error                 MOUPG  CSetupManager::Execute(229): Result = 0x800705B4',
        '2026-06-04 14:02:11, Error                 CONX   Windows::Compat::Appraiser::AppraiserLog::Log: Failed to open key',
        '2026-06-04 14:05:37, Error      [0x0f0082] BFSVC  Failed to set element application device. Status = [0xc0000001]'
    )
    Set-Logs -Err $upgrade
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir -Since $boot).Count) 0 'upgrade log before the last boot is ignored'
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir).Count) 0 'upgrade log is ignored even with no time limit'
    (Get-Item -LiteralPath $errLog).LastWriteTime = $boot.AddHours(1)
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir -Since $boot).Count) 0 'upgrade log written after the last boot is still ignored'

    # A real sysprep failure after the last boot.
    $sysprep = @(
        '2026-10-27 09:15:02, Error                 SYSPRP Package Contoso.App_1.0.0.0_x64__abc was installed for a user, but not provisioned for all users.',
        '2026-10-27 09:15:02, Error                 SYSPRP Failed to remove apps for the current user: 0x80073cf2.',
        '2026-10-27 09:15:03, Error      [0x0f0082] SYSPRP ActionPlatform::LaunchModule: Failure occurred while executing SysprepGeneralizeValidate',
        '2026-10-27 09:15:03, Error                 MOUPG  unrelated line in the same file'
    )
    Set-Logs -Err ($upgrade + $sysprep)
    (Get-Item -LiteralPath $errLog).LastWriteTime = $boot.AddHours(2)
    $found = @(Get-SysprepErrors -LogDir $dir -Since $boot)
    Assert-Equal $found.Count 3 'sysprep errors after the last boot are reported, upgrade lines are not'
    Assert-Equal ($found[0] -match '0x80073cf2|Contoso') $true 'first reported line is the sysprep one'

    # The same failure, but the machine has rebooted since.
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir -Since $boot.AddHours(3)).Count) 0 'log older than the last boot is ignored'
    (Get-Item -LiteralPath $errLog).LastWriteTime = $boot.AddHours(4)
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir -Since $boot.AddHours(3)).Count) 0 'sysprep lines dated before the last boot are ignored'

    # A later sysprep run that went fine: the earlier run's errors no longer count.
    $runs = @(
        '2026-10-27 09:14:50, Info                  SYSPRP ===            Beginning of a new sysprep run            ===',
        '2026-10-27 10:30:00, Info                  SYSPRP ===            Beginning of a new sysprep run            ==='
    )
    Set-Logs -Err ($upgrade + $sysprep) -Act $runs
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir -Since $boot).Count) 0 'errors from an earlier sysprep run are ignored'

    # The latest run failed too.
    $latest = '2026-10-27 10:30:05, Error                 SYSPRP Sysprep_Clean_Validate_Opk: There are one or more Windows updates that require a reboot.'
    Set-Logs -Err ($upgrade + $sysprep + $latest) -Act $runs
    $found = @(Get-SysprepErrors -LogDir $dir -Since $boot)
    Assert-Equal $found.Count 1 'only the latest sysprep run is reported'
    Assert-Equal ($found[0] -match 'require a reboot') $true 'reported line comes from the latest run'

    # A failure line that names sysprep without the SYSPRP tag still counts.
    Set-Logs -Err @('2026-10-27 09:20:00, Error                 Sysprep.exe failed with 0x80070005')
    Assert-Equal (@(Get-SysprepErrors -LogDir $dir -Since $boot).Count) 1 'a sysprep failure without the SYSPRP tag is reported'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# Windows PowerShell 5.1 reads a file without a BOM as ANSI, so the script must stay plain ASCII.
$bytes = [IO.File]::ReadAllBytes($script)
Assert-Equal (@($bytes | Where-Object { $_ -gt 127 }).Count) 0 'Prepare-Reference.ps1 is ASCII'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
