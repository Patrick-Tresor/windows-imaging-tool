# Naming list: config\naming-list.csv maps a PC's BIOS serial number to its computer name, OU and answer file.
# Deploy-Image.ps1 looks the PC up at deploy time; the console edits the list. PowerShell 5.1 compatible.
#
#   Serial,ComputerName,OU,AnswerFile,Notes
#   5CG1234XYZ,MTL-ACC-014,"OU=Accounting,OU=Workstations,DC=corp,DC=example",W11-Office-FR,Front desk
#
# Every column but Serial may be empty: an empty column falls back to the answer file's own setting.

$script:Columns = 'Serial', 'ComputerName', 'OU', 'AnswerFile', 'Notes'

# Header spellings accepted on read (spaces, dashes and underscores ignored), so inventory exports load as they are.
$script:HeaderAliases = @{
    serial = 'Serial'; serialnumber = 'Serial'; servicetag = 'Serial'
    computername = 'ComputerName'; name = 'ComputerName'; hostname = 'ComputerName'; computer = 'ComputerName'
    ou = 'OU'; organizationalunit = 'OU'; machineobjectou = 'OU'
    answerfile = 'AnswerFile'; answer = 'AnswerFile'; profile = 'AnswerFile'
    notes = 'Notes'; note = 'Notes'; description = 'Notes'; comment = 'Notes'
}

function Read-TextFile {
    # BOM first, then strict UTF-8, then the ANSI code page: Excel's plain "CSV" saves ANSI, and OU names often have accents.
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } catch { }
    $ansi = try { [Text.Encoding]::GetEncoding(1252) } catch { [Text.Encoding]::GetEncoding(28591) }
    $ansi.GetString($bytes)
}

function Get-CsvDelimiter([string]$Text) {
    # Excel in French, German and other locales saves with semicolons.
    $header = ($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($header -and $header.Contains(';') -and -not $header.Contains(',')) { ';' } else { ',' }
}

function Read-NamingList {
    <#
    .SYNOPSIS
        Reads a naming list CSV into rows with the standard columns. A missing or empty file is an empty list.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $text = Read-TextFile -Path $Path
    if (-not $text.Trim()) { return @() }
    $raw = @($text | ConvertFrom-Csv -Delimiter (Get-CsvDelimiter $text))
    if (-not $raw) { return @() }

    $map = @{}
    foreach ($h in $raw[0].PSObject.Properties.Name) {
        $key = ($h -replace '[\s_-]', '').ToLowerInvariant()
        if ($script:HeaderAliases.ContainsKey($key) -and -not $map.ContainsValue($script:HeaderAliases[$key])) { $map[$h] = $script:HeaderAliases[$key] }
    }
    if (-not $map.ContainsValue('Serial')) { throw "$Path has no Serial column. The first line must be a header such as: $($script:Columns -join ',')" }

    foreach ($r in $raw) {
        $row = [ordered]@{}
        foreach ($c in $script:Columns) { $row[$c] = '' }
        foreach ($h in $map.Keys) { $row[$map[$h]] = "$($r.$h)".Trim() }
        if (-not ($row.Values -join '')) { continue }   # blank line
        [pscustomobject]$row
    }
}

function Save-NamingList {
    # Writes UTF-8 with a BOM so Excel shows accents. Keeps the delimiter the file already uses.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [string]$Delimiter
    )
    if (-not $Delimiter) { $Delimiter = if (Test-Path $Path) { Get-CsvDelimiter (Read-TextFile -Path $Path) } else { ',' } }
    $rows = @($Entries | Where-Object { $_.Serial } | ForEach-Object {
        $e = $_; $row = [ordered]@{}
        foreach ($c in $script:Columns) { $row[$c] = "$($e.$c)".Trim() }
        [pscustomobject]$row
    })
    $lines = if ($rows) { $rows | ConvertTo-Csv -NoTypeInformation -Delimiter $Delimiter }
             else { ($script:Columns | ForEach-Object { "`"$_`"" }) -join $Delimiter }
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($true))
}

function Find-NamingEntry {
    # The row for this serial (trimmed, case-insensitive), or $null.
    param([AllowEmptyCollection()][object[]]$Entries = @(), [string]$Serial)
    if (-not "$Serial".Trim()) { return $null }
    $Entries | Where-Object { $_.Serial -and $_.Serial.Trim() -eq $Serial.Trim() } | Select-Object -First 1
}

function Test-ComputerName {
    # Problems with a computer name: NetBIOS limits (15 characters, letters, digits and dashes, not all digits).
    param([string]$Name)
    if (-not $Name) { return }
    if ($Name.Length -gt 15) { "Computer name '$Name' is longer than 15 characters." }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { "Computer name '$Name' may only contain letters, digits and dashes." }
    elseif ($Name -match '^\d+$') { "Computer name '$Name' cannot be only digits." }
    if ($Name.StartsWith('-') -or $Name.EndsWith('-')) { "Computer name '$Name' cannot start or end with a dash." }
}

function Test-NamingEntry {
    # Problems with one row. AnswerFileNames, when given, are the answer files that exist on the content root.
    param([Parameter(Mandatory)]$Entry, [string[]]$AnswerFileNames)
    if (-not $Entry.Serial) { 'Serial is empty.' }
    elseif ($Entry.Serial -match '[,;"]') { "Serial '$($Entry.Serial)' contains a comma, semicolon or quote." }
    Test-ComputerName $Entry.ComputerName
    if ($Entry.OU -and $Entry.OU -notmatch '^(OU|CN)=[^,]+(,(OU|CN|DC)=[^,]+)*$') {
        "OU '$($Entry.OU)' must be a distinguished name such as OU=Laptops,DC=corp,DC=example."
    }
    if ($Entry.AnswerFile -and $Entry.AnswerFile -notmatch '^[A-Za-z0-9._-]+$') { "Answer file '$($Entry.AnswerFile)' may only contain letters, digits, dot, dash and underscore." }
    elseif ($Entry.AnswerFile -and $PSBoundParameters.ContainsKey('AnswerFileNames') -and $Entry.AnswerFile -notin $AnswerFileNames) {
        "Answer file '$($Entry.AnswerFile)' does not exist."
    }
}

function Test-NamingList {
    # Problems with the whole list, each prefixed with its row number and serial. Includes duplicate serials and names.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries, [string[]]$AnswerFileNames)
    $extra = @{}
    if ($PSBoundParameters.ContainsKey('AnswerFileNames')) { $extra.AnswerFileNames = $AnswerFileNames }
    $serials = $Entries | Where-Object Serial | Group-Object { $_.Serial.ToUpperInvariant() } | Where-Object Count -gt 1
    $names = $Entries | Where-Object ComputerName | Group-Object { $_.ComputerName.ToUpperInvariant() } | Where-Object Count -gt 1
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $e = $Entries[$i]
        $label = "Row $($i + 1)$(if ($e.Serial) { " ($($e.Serial))" })"
        foreach ($p in Test-NamingEntry -Entry $e @extra) { "${label}: $p" }
        if ($e.Serial -and $serials.Name -contains $e.Serial.ToUpperInvariant()) { "${label}: serial is listed more than once." }
        if ($e.ComputerName -and $names.Name -contains $e.ComputerName.ToUpperInvariant()) { "${label}: computer name $($e.ComputerName) is used more than once." }
    }
}

Export-ModuleMember -Function Read-NamingList, Save-NamingList, Find-NamingEntry, Test-ComputerName, Test-NamingEntry, Test-NamingList
