# Which version of the tool built a stick, a boot image or a deploy, so an old stick is easy to spot.
#
# The version is the commit and its date. src\version.txt holds a git placeholder that GitHub fills in when main is
# downloaded as a zip (export-subst in .gitattributes), so a downloaded copy knows its commit without git. A git
# clone has git itself. The media build writes the version into boot.wim (Deploy\config\tool-version.json) and onto
# the stick's DEPLOY partition (tool-version.json), where the console reads it to say a stick is out of date.
# Used by the console, the media build and WinPE: plain .NET file calls only (no Join-Path on WinPE volumes).

function ConvertTo-ToolVersion {
    # Turns "<commit> <ISO date>" (version.txt or git log) into the version object, or $null for anything else.
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text.Trim()
    if ($t -notmatch '^([0-9a-f]{6,40})\s+(\S+)$') { return $null }
    $commit = $Matches[1]; $dateText = $Matches[2]
    $date = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($dateText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { return $null }
    New-ToolVersion -Commit $commit -Date $date.UtcDateTime
}

function New-ToolVersion {
    param([Parameter(Mandatory)][string]$Commit, $Date)
    $d = $null
    if ($Date -is [datetime]) { $d = $Date.ToUniversalTime() }
    elseif ($Date) {
        $o = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse("$Date", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$o)) { $d = $o.UtcDateTime }
    }
    $short = if ($Commit.Length -gt 7 -and $Commit -match '^[0-9a-f]+$') { $Commit.Substring(0, 7) } else { $Commit }
    [pscustomobject]@{
        Commit = $short
        Date   = $d
        Text   = if ($d) { '{0} ({1})' -f $short, $d.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { $short }
    }
}

function Get-ToolVersion {
    <#
    .SYNOPSIS
        This copy of the tool's version: { Commit, Date (UTC), Text }.
    .DESCRIPTION
        In order: Deploy\config\tool-version.json (inside WinPE, written by the build), src\version.txt filled in by
        GitHub's zip download, git (a clone), else "dev" with the newest script's date.
    #>
    param([string]$SourceRoot = $PSScriptRoot)
    $baked = [IO.Path]::Combine($SourceRoot, 'config', 'tool-version.json')
    if ([IO.File]::Exists($baked)) {
        try { $v = Read-ToolVersionFile -Path $baked; if ($v) { return $v } } catch { }
    }
    $txt = [IO.Path]::Combine($SourceRoot, 'version.txt')
    if ([IO.File]::Exists($txt)) {
        $v = ConvertTo-ToolVersion ([IO.File]::ReadAllText($txt))
        if ($v) { return $v }
    }
    try {
        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $out = & $git.Source -C $SourceRoot log -1 '--format=%h %cI' 2>$null
        if ($LASTEXITCODE -eq 0) {
            $v = ConvertTo-ToolVersion "$out"
            if ($v) {
                # Changed files not committed yet: say so, the commit alone would not describe this copy.
                $dirty = & $git.Source -C $SourceRoot status --porcelain -- . 2>$null
                if ($dirty) { $v.Commit += '+'; $v.Text = $v.Text -replace '^(\S+)', '$1+' }
                return $v
            }
        }
    } catch { }
    $newest = $null
    try {
        $newest = [IO.Directory]::GetFiles($SourceRoot, '*.ps*1') | ForEach-Object { [IO.File]::GetLastWriteTimeUtc($_) } |
            Sort-Object -Descending | Select-Object -First 1
    } catch { }
    New-ToolVersion -Commit 'dev' -Date $newest
}

function ConvertTo-ToolVersionRecord {
    # What goes into tool-version.json: the version, and when and for what this media was built.
    param([Parameter(Mandatory)]$Version, [string]$Target, [datetime]$Built = (Get-Date))
    [ordered]@{
        commit = $Version.Commit
        date   = if ($Version.Date) { $Version.Date.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        built  = $Built.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        target = $Target
    }
}

function Read-ToolVersionFile {
    # tool-version.json as a version object with Built, or $null when the file is missing or unreadable.
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return $null }
    if (-not $j -or -not $j.commit) { return $null }
    $v = New-ToolVersion -Commit "$($j.commit)" -Date $j.date
    $v | Add-Member -NotePropertyName Built -NotePropertyValue "$($j.built)"
    $v
}

function Get-StickToolVersion {
    # The version a stick was built with, from its DEPLOY partition. $null for a stick built before versions existed.
    param([Parameter(Mandatory)][string]$StickRoot)
    Read-ToolVersionFile -Path ([IO.Path]::Combine($StickRoot, 'tool-version.json'))
}

function Compare-ToolVersion {
    <#
    .SYNOPSIS
        Same, Older, Newer or Unknown: how the stick's version compares with this console's.
    .DESCRIPTION
        A stick with no version file was built before versions existed, so it is Older. Different commits are
        ordered by their dates; without dates (dev copies) the answer is Unknown.
    #>
    param($Console, $Stick)
    if (-not $Console) { return 'Unknown' }
    if (-not $Stick) { return 'Older' }
    if ($Stick.Commit.TrimEnd('+') -eq $Console.Commit.TrimEnd('+') -and $Stick.Commit -eq $Console.Commit) { return 'Same' }
    if ($Stick.Commit.TrimEnd('+') -eq $Console.Commit.TrimEnd('+')) { return 'Unknown' }
    if (-not $Stick.Date -or -not $Console.Date) { return 'Unknown' }
    if ($Stick.Date -lt $Console.Date) { return 'Older' }
    if ($Stick.Date -gt $Console.Date) { return 'Newer' }
    'Unknown'
}

function Get-StaleStickMessage {
    # One line for the console's banner, or $null when every plugged-in stick is up to date.
    param([Parameter(Mandatory)]$Console, [string[]]$StickRoots)
    $lines = foreach ($root in @($StickRoots | Where-Object { $_ })) {
        $s = Get-StickToolVersion -StickRoot $root
        if ((Compare-ToolVersion -Console $Console -Stick $s) -ne 'Older') { continue }
        $drive = $root.TrimEnd('\')
        if ($s) { "The USB stick in $drive was built with version $($s.Text)$(if ($s.Built) { " on $($s.Built)" }); this console is $($Console.Text)." }
        else { "The USB stick in $drive was built before this console stamped versions; this console is $($Console.Text)." }
    }
    if (-not $lines) { return $null }
    (@($lines) -join ' ') + ' Update it so it has the latest fixes: Media tab, tick "Update a stick", Build media.'
}

function Get-StaleBootImageMessage {
    # One line for the console's banner when the network boot image (<content root>\Boot) was built with an older
    # version of the tool than this console, or $null when it is up to date or there is none.
    param([Parameter(Mandatory)]$Console, [Parameter(Mandatory)][string]$ContentRoot)
    $boot = [IO.Path]::Combine($ContentRoot, 'Boot')
    if (-not [IO.File]::Exists([IO.Path]::Combine($boot, 'boot.wim'))) { return $null }
    $b = Read-ToolVersionFile -Path ([IO.Path]::Combine($boot, 'tool-version.json'))
    if ((Compare-ToolVersion -Console $Console -Stick $b) -ne 'Older') { return $null }
    if ($b) { "The network boot image was built with version $($b.Text)$(if ($b.Built) { " on $($b.Built)" }); this console is $($Console.Text). Rebuild it so reimaged PCs get the latest fixes." }
    else { "The network boot image was built before this console stamped versions; this console is $($Console.Text). Rebuild it so reimaged PCs get the latest fixes." }
}

Export-ModuleMember -Function ConvertTo-ToolVersion, New-ToolVersion, Get-ToolVersion, ConvertTo-ToolVersionRecord, Read-ToolVersionFile,
    Get-StickToolVersion, Compare-ToolVersion, Get-StaleStickMessage, Get-StaleBootImageMessage
