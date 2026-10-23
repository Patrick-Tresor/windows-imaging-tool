# Plain-PowerShell tests for the naming list: CSV reading and writing, lookup, validation and the console's
# merge and save. Run: pwsh -File tests/NamingList.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/NamingList.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("naming-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # The shipped list is a header only.
    Assert-Equal @(Read-NamingList -Path (Join-Path $repo 'config/naming-list.csv')).Count 0 'shipped naming list is empty'
    Assert-Equal @(Read-NamingList -Path (Join-Path $tmp 'missing.csv')).Count 0 'a missing list is empty'

    # Comma CSV, UTF-8 with BOM, quoted OU with commas, blank line.
    $csv = Join-Path $tmp 'list.csv'
    $text = "Serial,ComputerName,OU,AnswerFile,Notes`r`nTEST0001,PC-TEST-01,`"OU=Québec,OU=Laptops,DC=corp,DC=example`",W11-Test,`r`n`r`n test0002 ,pc-test-02,,,Spare`r`n"
    [IO.File]::WriteAllText($csv, $text, [Text.UTF8Encoding]::new($true))
    $list = @(Read-NamingList -Path $csv)
    Assert-Equal $list.Count 2 'rows are read and blank lines skipped'
    Assert-Equal $list[0].OU 'OU=Québec,OU=Laptops,DC=corp,DC=example' 'quoted OU keeps its commas and accents'
    Assert-Equal (Find-NamingEntry -Entries $list -Serial 'TEST0002').ComputerName 'pc-test-02' 'lookup trims and ignores case'
    Assert-Equal ($null -eq (Find-NamingEntry -Entries $list -Serial 'NOPE')) $true 'an unlisted serial finds nothing'
    Assert-Equal ($null -eq (Find-NamingEntry -Entries $list -Serial '')) $true 'an empty serial finds nothing'

    # Semicolon CSV saved by French Excel (ANSI), with other header spellings.
    $semi = Join-Path $tmp 'semi.csv'
    [IO.File]::WriteAllBytes($semi, [Text.Encoding]::GetEncoding(28591).GetBytes("Serial Number;Name;Organizational Unit;Profile;Description`r`nTEST0003;PC-TEST-03;OU=Montréal,DC=corp,DC=example;W11-Test;Réception`r`n"))
    $s = @(Read-NamingList -Path $semi)[0]
    Assert-Equal "$($s.Serial)|$($s.ComputerName)|$($s.OU)|$($s.AnswerFile)|$($s.Notes)" 'TEST0003|PC-TEST-03|OU=Montréal,DC=corp,DC=example|W11-Test|Réception' 'semicolon ANSI file with aliased headers'

    # Saving keeps the file's delimiter and round-trips.
    Save-NamingList -Path $semi -Entries @($s, [pscustomobject]@{ Serial = 'TEST0004'; ComputerName = 'PC-TEST-04' })
    Assert-Equal ((Get-Content $semi -First 1) -replace '^\xEF\xBB\xBF|^﻿', '') '"Serial";"ComputerName";"OU";"AnswerFile";"Notes"' 'save keeps semicolons'
    Assert-Equal (@(Read-NamingList -Path $semi) | ForEach-Object Serial) 'TEST0003 TEST0004' 'saved list reads back'

    $noSerial = Join-Path $tmp 'noserial.csv'
    Set-Content $noSerial "Name,OU`r`nPC1,"
    $msg = try { Read-NamingList -Path $noSerial | Out-Null; '' } catch { $_.Exception.Message }
    Assert-Equal ($msg -like '*no Serial column*') $true 'a file without a Serial column is rejected'

    # Validation.
    Assert-Equal @(Test-ComputerName 'PC-TEST-01').Count 0 'a valid name has no problems'
    Assert-Equal @(Test-ComputerName 'THIS-NAME-IS-TOO-LONG').Count 1 'names over 15 characters are rejected'
    Assert-Equal @(Test-ComputerName 'PC_01').Count 1 'underscores are rejected'
    Assert-Equal @(Test-ComputerName '12345').Count 1 'all-digit names are rejected'
    $bad = @(
        [pscustomobject]@{ Serial = 'A1'; ComputerName = 'PC-1'; OU = 'Laptops'; AnswerFile = 'Nope'; Notes = '' }
        [pscustomobject]@{ Serial = 'a1'; ComputerName = 'pc-1'; OU = ''; AnswerFile = '..\x'; Notes = '' }
        [pscustomobject]@{ Serial = ''; ComputerName = 'PC-3'; OU = 'OU=Laptops,DC=corp,DC=example'; AnswerFile = 'W11-Test'; Notes = '' }
    )
    $problems = @(Test-NamingList -Entries $bad -AnswerFileNames 'W11-Test')
    Assert-Equal ($problems -join "`n") (@(
        "Row 1 (A1): OU 'Laptops' must be a distinguished name such as OU=Laptops,DC=corp,DC=example."
        "Row 1 (A1): Answer file 'Nope' does not exist."
        'Row 1 (A1): serial is listed more than once.'
        'Row 1 (A1): computer name PC-1 is used more than once.'
        "Row 2 (a1): Answer file '..\x' may only contain letters, digits, dot, dash and underscore."
        'Row 2 (a1): serial is listed more than once.'
        'Row 2 (a1): computer name pc-1 is used more than once.'
        'Row 3: Serial is empty.'
    ) -join "`n") 'list validation reports every problem by row'
    Assert-Equal @(Test-NamingEntry -Entry $bad[0]).Count 1 'without answer file names only the format is checked'

    # Console: seeded list, save validation, rows with last deploy, merge.
    $root = Join-Path $tmp 'root'
    Initialize-ContentRoot -Path $root
    Assert-Equal (Test-Path (Get-NamingListPath -ContentRoot $root)) $true 'content root gets a naming list'
    $rows = @([pscustomobject]@{ Serial = ' TEST0001 '; ComputerName = 'pc-test-01'; OU = ''; AnswerFile = 'Default'; Notes = '' },
              [pscustomobject]@{ Serial = ''; ComputerName = ''; OU = ''; AnswerFile = ''; Notes = '' })
    Assert-Equal (Save-NamingListFromConsole -ContentRoot $root -Rows $rows) 1 'console save drops blank rows'
    $saved = @(Read-NamingList -Path (Get-NamingListPath -ContentRoot $root))[0]
    Assert-Equal "$($saved.Serial)|$($saved.ComputerName)" 'TEST0001|PC-TEST-01' 'console save trims and upper-cases names'
    $msg = try { Save-NamingListFromConsole -ContentRoot $root -Rows @([pscustomobject]@{ Serial = 'X'; AnswerFile = 'Missing' }) | Out-Null; '' } catch { $_.Exception.Message }
    Assert-Equal ($msg -like "*not saved*Answer file 'Missing' does not exist*") $true 'console save refuses an unknown answer file'

    Set-Content (Join-Path $root 'Logs/TEST0001_20261020-0900_FAILED.log') 'x'
    Set-Content (Join-Path $root 'Logs/TEST0001_20261021-0900_OK.log') 'x'
    (Get-Item (Join-Path $root 'Logs/TEST0001_20261020-0900_FAILED.log')).LastWriteTime = [datetime]'2026-10-20 09:00'
    (Get-Item (Join-Path $root 'Logs/TEST0001_20261021-0900_OK.log')).LastWriteTime = [datetime]'2026-10-21 09:00'
    $grid = @(Get-NamingListRows -ContentRoot $root)
    Assert-Equal "$($grid[0].Status)|$($grid[0].LastDeploy)" 'OK|2026-10-21 09:00 OK' 'grid rows show status and the latest deploy'

    $merge = Merge-NamingList -Existing @($saved) -Incoming @(
        [pscustomobject]@{ Serial = 'test0001'; ComputerName = ''; OU = 'OU=Laptops,DC=corp,DC=example'; AnswerFile = ''; Notes = 'moved' }
        [pscustomobject]@{ Serial = 'TEST0005'; ComputerName = 'PC-TEST-05'; OU = ''; AnswerFile = ''; Notes = '' }
    )
    Assert-Equal "$($merge.Added)|$($merge.Updated)|$($merge.Rows.Count)" '1|1|2' 'merge adds new serials and updates listed ones'
    Assert-Equal "$($merge.Rows[0].ComputerName)|$($merge.Rows[0].OU)|$($merge.Rows[0].Notes)" 'PC-TEST-01|OU=Laptops,DC=corp,DC=example|moved' 'merge keeps columns the import leaves empty'
    Assert-Equal $saved.OU '' 'merge does not change the existing rows in place'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
