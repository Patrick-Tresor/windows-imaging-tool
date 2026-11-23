# The admin console opens without a black console window behind it: ImagingConsole.cmd hands off with start and
# closes, PowerShell runs hidden, and the elevated relaunch stays hidden too. A startup error then shows in a
# message box and a log instead of vanishing with the hidden window.
# Run: pwsh -File tests/ConsoleWindow.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

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
Assert-Equal ($text -match "(?s)function Write-ConsoleErrorLog.*?console-error\.log.*?trap \{.*?Write-ConsoleErrorLog.*?MessageBox\]::Show") $true 'a startup error is logged and shown in a message box'
$trapAt = $text.IndexOf('trap {'); $windowAt = $text.IndexOf("MainWindow.xaml")
Assert-Equal ($trapAt -gt 0 -and $trapAt -lt $windowAt) $true 'the error trap is set before the main window loads'

# The crash log keeps the real cause: every inner exception with its stack, and the PowerShell stack.
Assert-Equal ($text -match '(?s)function Write-ConsoleErrorLog.*?InnerException.*?ScriptStackTrace') $true 'the crash log records inner exceptions and the PowerShell stack'
Assert-Equal ($text -match '(?s)trap \{.*?Write-ConsoleErrorLog') $true 'the error trap writes through Write-ConsoleErrorLog'
Assert-Equal ($text -match 'Dispatcher\.Add_UnhandledException') $true 'an error in a queued UI callback is logged and the console stays open'

# Dispatcher.BeginInvoke has no (action, priority) overload: BeginInvoke([action]{...}, 'Background') passes the
# priority to the action as an argument and WPF stops the console with 'Parameter count mismatch' (Computers tab,
# 2026-11-22). The priority goes first.
$bad = @(Get-ChildItem (Join-Path $repo 'src') -Recurse -File -Include *.ps1, *.psm1 | ForEach-Object {
    $file = $_
    [regex]::Matches([IO.File]::ReadAllText($file.FullName), '(?is)BeginInvoke\(\s*\[action\]\s*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}(?:\.GetNewClosure\(\))?\s*,') |
        ForEach-Object { "$($file.Name): $($_.Value.Substring(0, [Math]::Min(60, $_.Value.Length)))" }
})
Assert-Equal ($bad -join '; ') '' 'no BeginInvoke passes a priority (or anything else) after the action'

Complete-Tests 'All tests passed'
