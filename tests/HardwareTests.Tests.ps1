# Tests for the console's Hardware Tests tab (src/Console/HardwareTests.psm1): reading docs/HARDWARE-TESTS.md and
# saving a result per test.
# Run: powershell -File tests/HardwareTests.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $repo 'src/Console/HardwareTests.psm1') -Force

$doc = Join-Path $repo 'docs/HARDWARE-TESTS.md'
$tests = @(Get-HardwareTestList -DocPath $doc)
Assert-Equal ($tests.Count -ge 40) $true 'the real checklist has its tests'
Assert-Equal $tests[0].Id '1.1' 'first test is 1.1'
Assert-Equal $tests[0].Section 'USB stick (offline)' 'section from the ## heading, without its number'
Assert-Equal (@($tests | Where-Object Id -eq '1.11b').Count) 1 'numbers with a letter are tests too'
Assert-Equal (@($tests | Group-Object Id | Where-Object Count -gt 1).Count) 0 'every test number is used once'
$t19 = @($tests | Where-Object Id -eq '1.9')[0]
Assert-Equal ($t19.PassWhen -notmatch '`|\*\*') $true 'markdown marks are removed from the text'
foreach ($id in '1.14', '3.4', '4.5') { Assert-Equal (@($tests | Where-Object Id -eq $id).Count) 1 "new test $id is in the list" }

$root = Join-Path ([IO.Path]::GetTempPath()) ('HwTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'config'), (Join-Path $root 'Logs') -Force | Out-Null
try {
    # A small doc with an escaped pipe in a cell.
    $mini = Join-Path $root 'mini.md'
    Set-Content -LiteralPath $mini -Value @(
        '# Title', '', '## 1. USB stick', '', '| # | Test | Pass when |', '|---|------|-----------|',
        '| 1.1 | Build **a** stick | `A` \| B |', '| 1.2 | Boot it | WinPE starts |', '', '## 2. Network', '', '| # | Test | Pass when |', '|---|---|---|', '| 2.1 | Share | Mapped |')
    $rows = @(Get-HardwareTestRows -DocPath $mini -ContentRoot $root -CurrentVersion 'bbbbbbb (2026-11-20 10:00)')
    Assert-Equal (($rows | ForEach-Object Id) -join ',') '1.1,1.2,2.1' 'tests from every table, header rows skipped'
    Assert-Equal $rows[0].Test 'Build a stick' 'bold removed'
    Assert-Equal $rows[0].PassWhen 'A | B' 'escaped pipe kept inside the cell'
    Assert-Equal $rows[2].Section 'Network' 'second section'
    Assert-Equal (Get-HardwareTestSummary -Rows $rows).Text '0 of 3 passed, 3 not tested' 'nothing tested yet'

    # Results are saved per test, with the version they were tested with.
    Set-HardwareTestResult -ContentRoot $root -Id '1.1' -Result Passed -Note 'Dell 5521' -Version 'aaaaaaa (2026-11-10 10:00)' -Date ([datetime]'2026-11-10')
    Set-HardwareTestResult -ContentRoot $root -Id '1.2' -Result Failed -Note 'No disk' -Log 'Logs\ABC_20261120-1000_FAILED.log' -Version 'bbbbbbb (2026-11-20 10:00)'
    $rows = @(Get-HardwareTestRows -DocPath $mini -ContentRoot $root -CurrentVersion 'bbbbbbb (2026-11-20 10:00)')
    Assert-Equal $rows[0].Status 'Passed (older version)' 'a pass on an older version says so'
    Assert-Equal $rows[0].Date '2026-11-10' 'date saved'
    Assert-Equal $rows[0].Note 'Dell 5521' 'note saved'
    Assert-Equal $rows[1].Status 'Failed' 'failed test'
    Assert-Equal $rows[1].Log 'Logs\ABC_20261120-1000_FAILED.log' 'log saved'
    Assert-Equal (Get-HardwareTestSummary -Rows $rows).Text '1 of 3 passed, 1 failed, 1 not tested, 1 passed on an older version' 'summary counts'

    # Changing only the note keeps the result; "Not tested" with no note removes the entry.
    Set-HardwareTestResult -ContentRoot $root -Id '1.2' -Result Failed -Note 'No disk, VMD on' -Version 'bbbbbbb (2026-11-20 10:00)'
    Assert-Equal (Get-HardwareTestResults -ContentRoot $root)['1.2'].log 'Logs\ABC_20261120-1000_FAILED.log' 'the log stays when only the note changes'
    Set-HardwareTestResult -ContentRoot $root -Id '1.1' -Result ''
    Assert-Equal (Get-HardwareTestResults -ContentRoot $root).ContainsKey('1.1') $false 'not tested and no note: entry removed'
    Assert-Throws { Set-HardwareTestResult -ContentRoot $root -Id '1.1' -Result 'Maybe' } '*Passed, Failed or Skipped*' 'unknown result refused'

    # A test that is no longer in the doc keeps its saved result but is not listed.
    Set-HardwareTestResult -ContentRoot $root -Id '9.9' -Result Passed
    Assert-Equal @(Get-HardwareTestRows -DocPath $mini -ContentRoot $root).Count 3 'a result for a removed test is not listed'

    # The latest log for "Attach the latest log".
    Assert-Equal (Find-LatestDeployLog -ContentRoot $root) $null 'no log yet'
    Set-Content (Join-Path $root 'Logs/A_20261119-0900_OK.log') 'a'
    (Get-Item (Join-Path $root 'Logs/A_20261119-0900_OK.log')).LastWriteTime = [datetime]'2026-11-19 09:00'
    Set-Content (Join-Path $root 'Logs/B_20261120-0900_OK.log') 'b'
    Assert-Equal (Find-LatestDeployLog -ContentRoot $root) 'Logs\B_20261120-0900_OK.log' 'newest log in Logs'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Complete-Tests
