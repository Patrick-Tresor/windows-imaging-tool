# Shared by every *.Tests.ps1: dot-source it at the top (. (Join-Path $PSScriptRoot 'TestHelpers.ps1')), call the
# Assert-* functions, and end with Complete-Tests, which sets the exit code Run-All.ps1 reads.

$failures = 0

function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

function Assert-Throws {
    # Assert-Throws { ... } '*part of the message*' 'name', or Assert-Throws { ... } 'name' for any error.
    param([scriptblock]$Block, [string]$Like, $Name)
    if (-not $PSBoundParameters.ContainsKey('Name')) { $Name = $Like; $Like = '*' }
    try { & $Block | Out-Null; Write-Host "FAIL $Name (no error)" -ForegroundColor Red; $script:failures++ }
    catch {
        if ($_.Exception.Message -like $Like) { Write-Host "PASS $Name" -ForegroundColor Green }
        else { Write-Host "FAIL $Name`n  error: $($_.Exception.Message)" -ForegroundColor Red; $script:failures++ }
    }
}

function Complete-Tests([string]$Message = 'All tests passed.') {
    if ($script:failures) { Write-Host "$($script:failures) check(s) failed" -ForegroundColor Red; exit 1 }
    Write-Host $Message -ForegroundColor Green
    exit 0
}
