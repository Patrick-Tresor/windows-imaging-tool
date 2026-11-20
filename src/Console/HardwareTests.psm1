# The console's Hardware Tests tab: the checklist in docs\HARDWARE-TESTS.md, with a result per test.
#
# The list comes from the doc's tables at run time, so a test added to the doc shows up in the console. Results are
# kept in <content root>\config\hardware-tests.json: Passed, Failed or Skipped, the date, a note, the log that goes
# with it and the tool version it was tested with (a pass on an older version is shown as such).
# No UI code here, so it can be tested without Windows.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'JsonFile.psm1')

$script:Results = 'Passed', 'Failed', 'Skipped'

function ConvertFrom-MarkdownCell {
    # Plain text from a table cell: no **bold**, `code` marks or escaped pipes.
    param([string]$Text)
    ($Text -replace '\*\*', '' -replace '`', '' -replace '\\\|', '|').Trim()
}

function Get-HardwareTestList {
    <#
    .SYNOPSIS
        Every test in the doc's tables: { Id, Section, Test, PassWhen }, in the doc's order.
    .DESCRIPTION
        A section is a "## " heading; a test is a table row whose first cell is its number (1.1, 2.3b...).
    #>
    param([Parameter(Mandatory)][string]$DocPath)
    if (-not [IO.File]::Exists($DocPath)) { throw "The hardware test list is missing: $DocPath" }
    $section = ''
    foreach ($line in [IO.File]::ReadAllLines($DocPath)) {
        if ($line -match '^##\s+(.+)$') { $section = ($Matches[1] -replace '^\d+\.\s*', '').Trim(); continue }
        if ($line -notmatch '^\|') { continue }
        # Split on pipes that are not escaped.
        $cells = @([regex]::Split($line.Trim().Trim('|'), '(?<!\\)\|') | ForEach-Object { ConvertFrom-MarkdownCell $_ })
        if ($cells.Count -lt 3 -or $cells[0] -notmatch '^\d+\.\d+[a-z]?$') { continue }
        [pscustomobject]@{ Id = $cells[0]; Section = $section; Test = $cells[1]; PassWhen = $cells[2] }
    }
}

function Get-HardwareTestResultPath {
    param([Parameter(Mandatory)][string]$ContentRoot)
    [IO.Path]::Combine($ContentRoot, 'config', 'hardware-tests.json')
}

function Get-HardwareTestResults {
    # The saved results by test number, as a hashtable of { result, date, note, log, version }.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $map = @{}
    $path = Get-HardwareTestResultPath -ContentRoot $ContentRoot
    if (-not [IO.File]::Exists($path)) { return $map }
    try { $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw "Could not read ${path}: $($_.Exception.Message)" }
    foreach ($p in @($json.PSObject.Properties)) { $map[$p.Name] = $p.Value }
    $map
}

function Set-HardwareTestResult {
    <#
    .SYNOPSIS
        Saves one test's result. -Result '' clears it (not tested). The date is today unless -Date is given.
    #>
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyString()][string]$Result,
        [string]$Note,
        [string]$Log,
        [string]$Version,
        [datetime]$Date = (Get-Date)
    )
    if ($Result -and $Result -notin $script:Results) { throw "Result must be Passed, Failed or Skipped, not '$Result'." }
    $map = Get-HardwareTestResults -ContentRoot $ContentRoot
    $old = $map[$Id]
    if (-not $Result -and -not $Note -and -not $Log) { $map.Remove($Id) }
    else {
        $map[$Id] = [ordered]@{
            result  = $Result
            date    = if ($Result) { $Date.ToString('yyyy-MM-dd') } elseif ($old) { "$($old.date)" } else { '' }
            note    = if ($PSBoundParameters.ContainsKey('Note')) { $Note } elseif ($old) { "$($old.note)" } else { '' }
            log     = if ($PSBoundParameters.ContainsKey('Log')) { $Log } elseif ($old) { "$($old.log)" } else { '' }
            version = if ($Result) { $Version } elseif ($old) { "$($old.version)" } else { '' }
        }
    }
    $path = Get-HardwareTestResultPath -ContentRoot $ContentRoot
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $ordered = [ordered]@{}
    foreach ($k in @($map.Keys | Sort-Object { [regex]::Replace("$_", '\d+', { param($m) $m.Value.PadLeft(4, '0') }) })) { $ordered[$k] = $map[$k] }
    Save-JsonFile -Path $path -InputObject $ordered -Depth 3
}

function Get-HardwareTestRows {
    <#
    .SYNOPSIS
        The tab's rows: each test with its result, date, note, log and version. Status says "Passed (older version)"
        when it passed with a version other than -CurrentVersion, so a retest after a fix is easy to spot.
    #>
    param([Parameter(Mandatory)][string]$DocPath, [string]$ContentRoot, [string]$CurrentVersion)
    $results = if ($ContentRoot) { Get-HardwareTestResults -ContentRoot $ContentRoot } else { @{} }
    foreach ($t in Get-HardwareTestList -DocPath $DocPath) {
        $r = $results[$t.Id]
        $result = if ($r) { "$($r.result)" } else { '' }
        $version = if ($r) { "$($r.version)" } else { '' }
        $older = $result -eq 'Passed' -and $CurrentVersion -and $version -and ($version -split ' ')[0] -ne ($CurrentVersion -split ' ')[0]
        [pscustomobject]@{
            Id       = $t.Id
            Section  = $t.Section
            Test     = $t.Test
            PassWhen = $t.PassWhen
            Result   = $result
            Status   = if (-not $result) { 'Not tested' } elseif ($older) { 'Passed (older version)' } else { $result }
            Date     = if ($r) { "$($r.date)" } else { '' }
            Note     = if ($r) { "$($r.note)" } else { '' }
            Log      = if ($r) { "$($r.log)" } else { '' }
            Version  = $version
        }
    }
}

function Get-HardwareTestSummary {
    # "12 of 45 passed, 2 failed, 1 skipped, 30 not tested".
    param([object[]]$Rows = @())
    $Rows = @($Rows | Where-Object { $_ })
    $count = { param($r) @($Rows | Where-Object Result -eq $r).Count }
    $passed = & $count 'Passed'; $failed = & $count 'Failed'; $skipped = & $count 'Skipped'
    $none = @($Rows | Where-Object { -not $_.Result }).Count
    $parts = @("$passed of $($Rows.Count) passed")
    if ($failed) { $parts += "$failed failed" }
    if ($skipped) { $parts += "$skipped skipped" }
    if ($none) { $parts += "$none not tested" }
    $older = @($Rows | Where-Object Status -eq 'Passed (older version)').Count
    if ($older) { $parts += "$older passed on an older version" }
    [pscustomobject]@{ Passed = $passed; Failed = $failed; Skipped = $skipped; NotTested = $none; Total = $Rows.Count; Text = $parts -join ', ' }
}

function Find-LatestDeployLog {
    # The newest log in <content root>\Logs (a deploy's Deploy.log copy, or a Copy logs folder), relative to the
    # content root, for "Attach the latest log". $null when there is none.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $dir = [IO.Path]::Combine($ContentRoot, 'Logs')
    if (-not [IO.Directory]::Exists($dir)) { return $null }
    $newest = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)[0]
    if (-not $newest) { return $null }
    'Logs\' + $newest.Name
}

Export-ModuleMember -Function Get-HardwareTestList, Get-HardwareTestResults, Set-HardwareTestResult, Get-HardwareTestRows,
    Get-HardwareTestSummary, Find-LatestDeployLog
