# Finds and downloads the latest Windows cumulative update for an image from the Microsoft Update Catalog
# (www.catalog.update.microsoft.com), for Update-OfflineImage.ps1 -LatestUpdate.
#
# The catalog has no API: this reads its search page and its download dialog, the way a browser does. When Microsoft
# changes those pages the search fails with a clear message, and the operator downloads the .msu by hand into the
# content root's Updates folder (the Update image window lists it).

$script:CatalogUrl = 'https://www.catalog.update.microsoft.com'

function Get-WindowsReleaseName {
    # The name the catalog uses in update titles for a Windows build (10.0.26100.x or 26100), or $null when unknown.
    param([Parameter(Mandatory)][string]$Build)
    $n = if ($Build -match '^\d+\.\d+\.(\d+)') { [int]$Matches[1] } elseif ($Build -match '^(\d+)$') { [int]$Matches[1] } else { 0 }
    switch ($n) {
        26300 { 'Windows 11 Version 26H2' }
        26200 { 'Windows 11 Version 25H2' }
        26100 { 'Windows 11 Version 24H2' }
        22631 { 'Windows 11 Version 23H2' }
        22621 { 'Windows 11 Version 22H2' }
        19045 { 'Windows 10 Version 22H2' }
        19044 { 'Windows 10 Version 21H2' }
        17763 { 'Windows 10 Version 1809' }
        default { $null }
    }
}

function Get-CatalogReleaseNames {
    # The release names to search the catalog for, best first. 24H2, 25H2 and 26H2 share one cumulative update (same KB,
    # same .msu): when the catalog has no row titled for the newer release yet, the older release's row is that update.
    param([Parameter(Mandatory)][string]$Release)
    switch ($Release) {
        'Windows 11 Version 26H2' { @($Release, 'Windows 11 Version 25H2') }
        default { @($Release) }
    }
}

function ConvertFrom-CatalogSearch {
    # The result rows of a catalog search page: Id (the update's GUID), Title, Kb and Date (last updated).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)
    $rows = [regex]::Matches($Html, '<a[^>]*\bid="([0-9a-fA-F-]{36})_link"[^>]*>\s*([^<]+?)\s*</a>')
    foreach ($m in $rows) {
        $id = $m.Groups[1].Value
        $title = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value) -replace '\s+', ' '
        $date = $null
        $d = [regex]::Match($Html, 'id="' + [regex]::Escape($id) + '_C4_R\d+"[^>]*>\s*([^<]+?)\s*<')
        if ($d.Success) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($d.Groups[1].Value, 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$parsed)) { $date = $parsed }
        }
        [pscustomobject]@{
            Id    = $id
            Title = $title
            Kb    = if ($title -match '\b(KB\d{6,8})\b') { $Matches[1] } else { '' }
            Date  = $date
        }
    }
}

function Select-LatestCumulativeUpdate {
    # The newest regular x64 cumulative update for that release: not a preview, not a Dynamic (setup) update,
    # not .NET, not Server or Arm64. Newest = the "yyyy-MM" in the title, then the catalog date.
    param([AllowEmptyCollection()][object[]]$Rows, [Parameter(Mandatory)][string]$Release)
    # The catalog writes both "Windows 11 Version 24H2" and "Windows 11, version 24H2".
    $parts = $Release -split ' Version '
    $name = [regex]::Escape($parts[0]) + ',? [Vv]ersion ' + [regex]::Escape($parts[1])
    $pattern = "^(\d{4}-\d{2} )?Cumulative Update for $name for x64-based Systems \(KB\d+\)"
    @($Rows | Where-Object { $_.Title -match $pattern -and $_.Title -notmatch 'Preview|Dynamic|\.NET|Server|arm64' }) |
        Sort-Object @{ Expression = { if ($_.Title -match '^(\d{4}-\d{2})') { $Matches[1] } else { '' } }; Descending = $true },
                    @{ Expression = { if ($_.Date) { $_.Date } else { [datetime]::MinValue } }; Descending = $true } |
        Select-Object -First 1
}

function ConvertFrom-CatalogDownloadDialog {
    # The file addresses in the catalog's download dialog. A Windows 11 24H2 and later update can have two .msu files
    # (the checkpoint update and the latest one); both are needed, in the same folder.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)
    @([regex]::Matches($Html, "files\[\d+\]\.url\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -match '\.(msu|cab)$' } | Select-Object -Unique)
}

function Get-UpdateFileOrder {
    # Files in the order DISM applies them: lowest KB first, so a checkpoint update goes before the latest one.
    param([AllowEmptyCollection()][string[]]$Names)
    @($Names | Sort-Object { if ($_ -match 'kb(\d+)') { [int64]$Matches[1] } else { [int64]::MaxValue } }, { $_ })
}

function Invoke-CatalogRequest {
    # GET (no -Body) or form POST to the catalog; returns the page text.
    param([Parameter(Mandatory)][string]$Url, [string]$Body)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        if ($PSBoundParameters.ContainsKey('Body')) {
            (Invoke-WebRequest -Uri $Url -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 120).Content
        } else {
            (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 120).Content
        }
    } finally { $ProgressPreference = $old }
}

function Find-LatestCumulativeUpdate {
    <#
    .SYNOPSIS
        The newest cumulative update for a Windows build: Title, Kb, Release and Urls (one or more .msu files).
    .DESCRIPTION
        Throws a short message when the build is not one the tool knows, the catalog cannot be reached or the
        update is not found; the caller then tells the operator to download it by hand. -Request is for tests.
    #>
    param(
        [Parameter(Mandatory)][string]$Build,
        [scriptblock]$Request = { param($Url, $Body) if ($null -ne $Body) { Invoke-CatalogRequest -Url $Url -Body $Body } else { Invoke-CatalogRequest -Url $Url } }
    )
    $release = Get-WindowsReleaseName -Build $Build
    if (-not $release) { throw "Windows build $Build is not one the tool knows." }
    $best = $null
    foreach ($name in @(Get-CatalogReleaseNames -Release $release)) {
        $query = [Uri]::EscapeDataString("Cumulative Update for $name for x64-based Systems")
        try { $html = & $Request "$script:CatalogUrl/Search.aspx?q=$query" $null }
        catch { throw "Could not reach the Microsoft Update Catalog: $($_.Exception.Message)" }
        $best = Select-LatestCumulativeUpdate -Rows @(ConvertFrom-CatalogSearch -Html "$html") -Release $name
        if ($best) { break }
    }
    if (-not $best) { throw "No cumulative update for $release found in the Microsoft Update Catalog." }

    $ids = '[{"size":0,"languages":"","uidInfo":"' + $best.Id + '","updateID":"' + $best.Id + '"}]'
    try { $dialog = & $Request "$script:CatalogUrl/DownloadDialog.aspx" ('updateIDs=' + [Uri]::EscapeDataString($ids)) }
    catch { throw "Could not read the download links of $($best.Kb): $($_.Exception.Message)" }
    $urls = @(ConvertFrom-CatalogDownloadDialog -Html "$dialog")
    if (-not $urls) { throw "The Microsoft Update Catalog gave no download link for $($best.Kb)." }
    [pscustomobject]@{ Title = $best.Title; Kb = $best.Kb; Release = $release; Urls = $urls }
}

function Save-CatalogFile {
    # BITS for big files, Invoke-WebRequest where BITS is not available. Downloads to .part and renames, so an
    # interrupted download is never taken for a finished one.
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Destination)
    $part = "$Destination.part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    $done = $false
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try { Start-BitsTransfer -Source $Url -Destination $part -DisplayName ([IO.Path]::GetFileName($Destination)); $done = $true } catch { }
    }
    if (-not $done) {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing } finally { $ProgressPreference = $old }
    }
    Move-Item -LiteralPath $part -Destination $Destination -Force
}

function Save-LatestCumulativeUpdate {
    <#
    .SYNOPSIS
        Downloads the newest cumulative update for a build into a folder (the content root's Updates folder) and
        returns the update with Files: the full paths, in the order to apply them.
    .DESCRIPTION
        A file already in the folder is not downloaded again. -Find and -Download are for tests.
    #>
    param(
        [Parameter(Mandatory)][string]$Build,
        [Parameter(Mandatory)][string]$Folder,
        [scriptblock]$Find = { param($Build) Find-LatestCumulativeUpdate -Build $Build },
        [scriptblock]$Download = { param($Url, $Path) Save-CatalogFile -Url $Url -Destination $Path },
        [scriptblock]$OnFile = { param($Name, $Number, $Count) }
    )
    $update = & $Find $Build
    [void][IO.Directory]::CreateDirectory($Folder)
    $names = Get-UpdateFileOrder -Names @($update.Urls | ForEach-Object { [IO.Path]::GetFileName(([Uri]$_).AbsolutePath) })
    $files = @()
    $i = 0
    foreach ($name in $names) {
        $i++
        $path = [IO.Path]::Combine($Folder, $name)
        if (-not [IO.File]::Exists($path)) {
            & $OnFile $name $i $names.Count
            $url = @($update.Urls | Where-Object { [IO.Path]::GetFileName(([Uri]$_).AbsolutePath) -eq $name })[0]
            & $Download $url $path
        }
        $files += $path
    }
    $update | Add-Member -NotePropertyName Files -NotePropertyValue $files -PassThru
}

Export-ModuleMember -Function Get-WindowsReleaseName, ConvertFrom-CatalogSearch, Select-LatestCumulativeUpdate, ConvertFrom-CatalogDownloadDialog,
    Get-UpdateFileOrder, Find-LatestCumulativeUpdate, Save-LatestCumulativeUpdate
