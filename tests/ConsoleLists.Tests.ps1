# Lists the console hands to WPF (ItemsSource) must stay arrays when they hold one item or none.
# PowerShell unrolls an if/switch statement's output, so $x = if (...) { @(one) } leaves a lone object, and WPF
# then fails with "Cannot convert ... PSCustomObject to type System.Collections.IEnumerable".
# Run: pwsh -File tests/ConsoleLists.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
$common = Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force -PassThru

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Stands in for a WPF list control: the property has the same type as ItemsSource, so PowerShell converts the same way.
Add-Type -TypeDefinition @'
public class ItemsSourceHolder { public System.Collections.IEnumerable ItemsSource { get; set; } }
'@
function Test-ItemsSource($Value) {
    try { [ItemsSourceHolder]::new().ItemsSource = $Value; $true } catch { $false }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-test-" + [guid]::NewGuid())
& $common { param($p) $script:LogPath = $p } (Join-Path $root 'test.log')
try {
    Initialize-ContentRoot -Path $root

    # A new content root has one answer file (Default), the case that broke the console at startup.
    $old = if (Test-ContentRoot $root) { @(Get-AnswerFileRows -ContentRoot $root) } else { @() }
    Assert-Equal (Test-ItemsSource $old) $false 'the old pattern unrolls one answer file (the test reproduces the bug)'
    $rows = @(if (Test-ContentRoot $root) { Get-AnswerFileRows -ContentRoot $root })
    Assert-Equal $rows.Count 1 'one answer file gives one row'
    Assert-Equal (Test-ItemsSource $rows) $true 'one answer file can be shown in the answer file list'
    Assert-Equal (Test-ItemsSource @($rows.Name)) $true 'one answer file can be shown in the default answer file picker'

    $none = Join-Path $root 'missing'
    $empty = @(if (Test-ContentRoot $none) { Get-AnswerFileRows -ContentRoot $none })
    Assert-Equal $empty.Count 0 'no content root gives an empty list'
    Assert-Equal (Test-ItemsSource $empty) $true 'an empty list can be shown'

    $apps = @(if (Test-ContentRoot $root) { Get-ApplicationList -ContentRoot $root })
    Assert-Equal (Test-ItemsSource $apps) $true 'the application list can be shown with no apps'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# Guard: no console script assigns an if/switch whose branch is a bare @(...); that @() is undone by the statement.
$bad = @()
foreach ($f in Get-ChildItem (Join-Path $repo 'src/Console') -Include *.ps1, *.psm1 -Recurse) {
    $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    $assigns = $ast.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assigns) {
        $right = $a.Right
        if ($right -isnot [Management.Automation.Language.IfStatementAst] -and $right -isnot [Management.Automation.Language.SwitchStatementAst]) { continue }
        $blocks = if ($right -is [Management.Automation.Language.IfStatementAst]) { @($right.Clauses | ForEach-Object { $_.Item2 }) + @($right.ElseClause) } else { @($right.Clauses | ForEach-Object { $_.Item2 }) + @($right.Default) }
        foreach ($b in $blocks | Where-Object { $_ }) {
            $stmts = @($b.Statements)
            if ($stmts.Count -ne 1 -or $stmts[0] -isnot [Management.Automation.Language.PipelineAst]) { continue }
            $elems = @($stmts[0].PipelineElements)
            if ($elems.Count -eq 1 -and $elems[0] -is [Management.Automation.Language.CommandExpressionAst] -and
                $elems[0].Expression -is [Management.Automation.Language.ArrayExpressionAst]) {
                $bad += "$($f.Name):$($a.Extent.StartLineNumber): $($a.Extent.Text.Split("`n")[0].Trim())"
                break
            }
        }
    }
}
foreach ($line in $bad) { Write-Host "  $line" }
Assert-Equal $bad.Count 0 'console scripts wrap @() around if/switch statements, not inside their branches'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
