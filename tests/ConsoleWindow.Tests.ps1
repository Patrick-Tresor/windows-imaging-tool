# The admin console opens without a black console window behind it: ImagingConsole.cmd hands off with start and
# closes, PowerShell runs hidden, and the elevated relaunch stays hidden too. A startup error then shows in a
# message box and a log instead of vanishing with the hidden window.
# Run: pwsh -File tests/ConsoleWindow.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$launcher = @(Get-Content -LiteralPath (Join-Path $repo 'ImagingConsole.cmd') | Where-Object { $_ -match '(?i)powershell' -and $_ -notmatch '(?i)^\s*rem\b' })
Assert-Equal $launcher.Count 1 'ImagingConsole.cmd starts PowerShell once'
Assert-Equal ($launcher[0] -match '(?i)^\s*start ""\s') $true 'ImagingConsole.cmd uses start, so its own cmd window closes at once'
Assert-Equal ($launcher[0] -match '(?i)-WindowStyle Hidden') $true 'PowerShell starts with its window hidden'
Assert-Equal ($launcher[0] -match '(?i)-HideConsole\s*$') $true 'the console is told to hide its console window'

$text = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Console/ImagingConsole.ps1')
$relaunch = [regex]::Match($text, "(?s)Start-Process powershell\.exe -Verb RunAs.*?return").Value
Assert-Equal ($relaunch -match "-WindowStyle Hidden -ArgumentList") $true 'the elevated relaunch opens no visible window'
Assert-Equal ($relaunch -match "'-HideConsole'") $true 'the elevated relaunch hides its console window too'
Assert-Equal ($text -match 'ShowWindow\(\$h, 0\)') $true 'the console hides its own console window (SW_HIDE)'
Assert-Equal ($text -match "(?s)trap \{.*?console-error\.log.*?MessageBox\]::Show") $true 'a startup error is logged and shown in a message box'
$trapAt = $text.IndexOf('trap {'); $windowAt = $text.IndexOf("MainWindow.xaml")
Assert-Equal ($trapAt -gt 0 -and $trapAt -lt $windowAt) $true 'the error trap is set before the main window loads'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
