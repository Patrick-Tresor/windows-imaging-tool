# Runs every *.Tests.ps1 in this folder, each in its own PowerShell process, and reports which failed.
# Windows: run tests\Run-All.ps1 (or the launcher, tests\launcher\RunTests.c, built as a.exe at the repo root).
# Other systems: set TESTS_SHELL=pwsh to use PowerShell 7 instead of powershell.exe.
$ErrorActionPreference = 'Continue'
$shell = if ($env:TESTS_SHELL) { $env:TESTS_SHELL } else { 'powershell.exe' }
$failed = @()
foreach ($t in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name) {
    Write-Host ''
    Write-Host "=== $($t.Name)" -ForegroundColor Cyan
    & $shell -NoProfile -ExecutionPolicy Bypass -File $t.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $t.Name }
}
Write-Host ''
if ($failed) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All test files passed.' -ForegroundColor Green
