# Runs every *.Tests.ps1 in this folder, each in its own PowerShell process, and reports which failed.
# Windows: run tests\Run-All.ps1.
# Other systems: set TESTS_SHELL=pwsh to use PowerShell 7 instead of powershell.exe.
$ErrorActionPreference = 'Continue'
$shell = if ($env:TESTS_SHELL) { $env:TESTS_SHELL } else { 'powershell.exe' }
$failed = @()
$details = @()
foreach ($t in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name) {
    Write-Host ''
    Write-Host "=== $($t.Name)" -ForegroundColor Cyan
    $lines = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $t.FullName 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    foreach ($l in $lines) { Write-Host $l -ForegroundColor $(if ($l -like 'PASS *') { 'Green' } elseif ($l -like 'FAIL *') { 'Red' } else { 'Gray' }) }
    if ($code -ne 0) {
        $failed += $t.Name
        # Repeated at the end, so a failure is found without scrolling through every test's output.
        $details += "--- $($t.Name)"
        $details += @($lines | Where-Object { $_ -notlike 'PASS *' } | Select-Object -Last 80)
    }
}
Write-Host ''
if ($failed) {
    foreach ($l in $details) { Write-Host $l -ForegroundColor Red }
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All test files passed.' -ForegroundColor Green
