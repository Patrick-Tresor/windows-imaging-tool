# Tests for finding the latest cumulative update in the Microsoft Update Catalog (src/UpdateCatalog.psm1), with
# saved copies of the catalog's pages: no network.
# Run: powershell -File tests/UpdateCatalog.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $repo 'src/UpdateCatalog.psm1') -Force

Assert-Equal (Get-WindowsReleaseName -Build '10.0.26100.4349') 'Windows 11 Version 24H2' 'build 26100 is 24H2'
Assert-Equal (Get-WindowsReleaseName -Build '10.0.26300.10075') 'Windows 11 Version 26H2' 'build 26300 is 26H2'
Assert-Equal (Get-WindowsReleaseName -Build '19045') 'Windows 10 Version 22H2' 'build 19045 is Windows 10 22H2'
Assert-Equal (Get-WindowsReleaseName -Build '10.0.99999.1') $null 'an unknown build has no name'

# Rows as the catalog's search page writes them.
function New-Row($Id, $Title, $Date, $N) {
    "<tr id=""${Id}_R$N""><td><a id=""${Id}_link"" href=""javascript:void(0);"" onclick=""goToDetails(&quot;$Id&quot;);"" class=""contentTextItemSpacerNoBreakLink"">`r`n    $Title`r`n</a></td>" +
    "<td class=""resultsbottomBorder resultspadding"" id=""${Id}_C4_R$N"">$Date</td></tr>"
}
$ids = 1..7 | ForEach-Object { [guid]::NewGuid().ToString() }
$html = '<table>' + (@(
    New-Row $ids[0] '2026-09 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5065426)' '9/9/2026' 1
    New-Row $ids[1] '2026-10 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5066835)' '10/14/2026' 2
    New-Row $ids[2] '2026-10 Cumulative Update Preview for Windows 11 Version 24H2 for x64-based Systems (KB5067036)' '10/28/2026' 3
    New-Row $ids[3] '2026-10 Cumulative Update for Windows 11 Version 24H2 for arm64-based Systems (KB5066835)' '10/14/2026' 4
    New-Row $ids[4] '2026-10 Dynamic Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5066835)' '10/14/2026' 5
    New-Row $ids[5] '2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11 Version 24H2 for x64 (KB5066131)' '10/14/2026' 6
    New-Row $ids[6] '2026-10 Cumulative Update for Windows 11 Version 23H2 for x64-based Systems (KB5066793)' '10/14/2026' 7
) -join "`r`n") + '</table>'

$rows = @(ConvertFrom-CatalogSearch -Html $html)
Assert-Equal $rows.Count 7 'every search result row is read'
Assert-Equal "$($rows[1].Kb)|$($rows[1].Date.ToString('yyyy-MM-dd'))" 'KB5066835|2026-10-14' 'KB and date read from a row'
$best = Select-LatestCumulativeUpdate -Rows $rows -Release 'Windows 11 Version 24H2'
Assert-Equal $best.Id $ids[1] 'newest regular x64 update picked: not preview, arm64, dynamic, .NET or another version'
Assert-Equal (Select-LatestCumulativeUpdate -Rows $rows -Release 'Windows 10 Version 22H2') $null 'nothing for a release not in the results'
Assert-Equal @(ConvertFrom-CatalogSearch -Html '<html>no results</html>').Count 0 'a page with no results gives no rows'

$dialog = @"
var downloadInformation = new Array();
downloadInformation[0] = new Object();
downloadInformation[0].files = new Array();
downloadInformation[0].files[0] = new Object();
downloadInformation[0].files[0].url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/aaa/public/windows11.0-kb5066835-x64_abc.msu';
downloadInformation[0].files[1] = new Object();
downloadInformation[0].files[1].url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/bbb/public/windows11.0-kb5043080-x64_def.msu';
"@
$urls = @(ConvertFrom-CatalogDownloadDialog -Html $dialog)
Assert-Equal $urls.Count 2 'both .msu links read from the download dialog'
Assert-Equal ((Get-UpdateFileOrder -Names @('windows11.0-kb5066835-x64_abc.msu', 'windows11.0-kb5043080-x64_def.msu')) -join ',') 'windows11.0-kb5043080-x64_def.msu,windows11.0-kb5066835-x64_abc.msu' 'checkpoint update (lower KB) applied first'

# The whole search with a fake catalog.
$requests = [Collections.Generic.List[string]]::new()
$fake = { param($Url, $Body) $requests.Add("$Url|$Body"); if ($Url -like '*Search.aspx*') { $html } else { $dialog } }.GetNewClosure()
$found = Find-LatestCumulativeUpdate -Build '10.0.26100.1' -Request $fake
Assert-Equal "$($found.Kb)|$($found.Urls.Count)" 'KB5066835|2' 'finds the update and its files'
Assert-Equal ($requests[1] -like "*DownloadDialog.aspx|updateIDs=*$($ids[1])*") $true 'asks the download dialog for that update'
# 26H2 (26300) shares 25H2's update: when no row says 26H2, the 25H2 row is used.
$html25 = $html -replace 'Version 24H2', 'Version 25H2' -replace 'version 24H2', 'version 25H2'
$searches = [Collections.Generic.List[string]]::new()
$fake26 = { param($Url, $Body) if ($Url -like '*Search.aspx*') { $searches.Add($Url); if ($Url -like '*26H2*') { $html } else { $html25 } } else { $dialog } }.GetNewClosure()
$found26 = Find-LatestCumulativeUpdate -Build '10.0.26300.10075' -Request $fake26
Assert-Equal "$($found26.Kb)|$($searches.Count)|$($found26.Title -like '*25H2*')" 'KB5066835|2|True' '26H2 falls back to the 25H2 update'
Assert-Throws { Find-LatestCumulativeUpdate -Build '10.0.99999.1' -Request $fake } '*not one the tool knows*' 'unknown build: short message'
Assert-Throws { Find-LatestCumulativeUpdate -Build '10.0.26100.1' -Request { throw 'offline' } } '*Could not reach the Microsoft Update Catalog*' 'catalog unreachable: short message'
Assert-Throws { Find-LatestCumulativeUpdate -Build '10.0.26100.1' -Request { param($Url, $Body) if ($Url -like '*Search*') { $html } else { 'nothing' } }.GetNewClosure() } '*no download link*' 'no link: short message'

# Download into Updates: in apply order, a file already there is not downloaded again.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('UpdateCatalog-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Set-Content -LiteralPath (Join-Path $tmp 'windows11.0-kb5043080-x64_def.msu') -Value 'old'
    $got = [Collections.Generic.List[string]]::new()
    $saved = Save-LatestCumulativeUpdate -Build '10.0.26100.1' -Folder $tmp -Find { param($Build) [pscustomobject]@{ Kb = 'KB5066835'; Urls = $urls } }.GetNewClosure() `
        -Download { param($Url, $Path) $got.Add([IO.Path]::GetFileName($Path)); Set-Content -LiteralPath $Path -Value 'new' }.GetNewClosure()
    Assert-Equal (($saved.Files | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ',') 'windows11.0-kb5043080-x64_def.msu,windows11.0-kb5066835-x64_abc.msu' 'files returned in apply order'
    Assert-Equal ($got -join ',') 'windows11.0-kb5066835-x64_abc.msu' 'only the missing file is downloaded'
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# The script and the window use it.
$script = Get-Content -Raw (Join-Path $repo 'src/Update-OfflineImage.ps1')
Assert-Equal ($script -match 'Save-LatestCumulativeUpdate') $true 'Update-OfflineImage -LatestUpdate downloads the update'
$window = Get-Content -Raw (Join-Path $repo 'src/Console/UpdateImage.ps1')
Assert-Equal ($window -match '\$latest = \$true') $true 'Update image always looks for the latest cumulative update'

Complete-Tests
