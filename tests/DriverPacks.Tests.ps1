# Plain-PowerShell tests for the driver pack builder: vendor catalog parsing and library registration.
# Run: pwsh -File tests/DriverPacks.Tests.ps1. Uses the sample catalogs in tests/fixtures/driverpacks, no network.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/Console/DriverPacks.psm1') -Force
$common = Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force -PassThru
$fixtures = Join-Path $PSScriptRoot 'fixtures/driverpacks'

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Dell: one row per model and OS, WinPE packs skipped, SHA256 preferred over MD5.
$dell = @(ConvertFrom-DellDriverPackCatalog -Path (Join-Path $fixtures 'DriverPackCatalog.xml'))
Assert-Equal $dell.Count 3 'dell: WinPE packs are skipped'
$d = $dell | Where-Object { $_.Model -eq 'Latitude 5440' -and $_.Os -eq 'Windows 11' }
Assert-Equal ($d.Skus -join ',') '0B0B,0C1D' 'dell: model gets all of its system IDs'
Assert-Equal $d.Url 'https://downloads.dell.com/FOLDER1/1/Latitude-5440-5540-Win11-A07.exe' 'dell: url is built from baseLocation'
Assert-Equal "$($d.HashType) $($d.Hash.Substring(0, 4))" 'SHA256 AAAA' 'dell: SHA256 is used when present'
Assert-Equal "$($d.Version) $($d.SizeMB)" 'A07 1536' 'dell: version and size'
Assert-Equal (($dell | Where-Object Os -eq 'Windows 10').HashType) 'MD5' 'dell: falls back to MD5'
Assert-Equal (($dell | Where-Object Model -eq 'Latitude 5540').Skus -join ',') '0B0C' 'dell: second model in the same pack'

# Dell WinPE packs (Intel RST/VMD storage, network) for boot.wim: WinPE 11 before 10, whatever the dates.
$pe = @(ConvertFrom-DellWinPEDriverPacks -Path (Join-Path $fixtures 'DriverPackCatalog.xml'))
Assert-Equal ($pe | ForEach-Object { "$($_.WinPEVersion) $($_.Version)" }) '11 A02 10 A33' 'dell winpe: only winpe packs, newest WinPE first'
Assert-Equal "$($pe[0].Url)|$($pe[0].HashType)|$($pe[0].FileName)" 'https://downloads.dell.com/FOLDER3/1/WinPE11.0-Drivers-A02.CAB|MD5|WinPE11.0-Drivers-A02.CAB' 'dell winpe: url, hash and file name'
# What a catalog download really is: expand.exe "succeeds" on a non-cab and leaves no XML (Patrick's build).
$kindDir = Join-Path ([IO.Path]::GetTempPath()) ("kind-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $kindDir | Out-Null
try {
    $samples = [ordered]@{
        Cab  = [byte[]](0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0)
        Gzip = [byte[]](0x1F, 0x8B, 8, 0)
        Zip  = [byte[]](0x50, 0x4B, 3, 4)
        Xml  = [Text.Encoding]::UTF8.GetBytes("$([char]0xFEFF)<?xml version=`"1.0`"?><DriverPackManifest/>")
        Html = [Text.Encoding]::ASCII.GetBytes("`r`n<!DOCTYPE html><html><body>Access denied</body></html>")
        Unknown = [byte[]](1, 2, 3)
        Utf16 = [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes('<?xml version="1.0" encoding="utf-16"?><DriverPackManifest/>')
    }
    foreach ($k in $samples.Keys) {
        $f = Join-Path $kindDir "$k.bin"
        [IO.File]::WriteAllBytes($f, $samples[$k])
        Assert-Equal (Get-DownloadKind -Path $f) $(if ($k -eq 'Utf16') { 'Xml' } else { $k }) "download kind: $k"
    }
} finally { Remove-Item $kindDir -Recurse -Force -ErrorAction SilentlyContinue }

# HP WinPE pack: the highest SoftPaq linked on HP's page, over https.
$hpHtml = '<tr><td>3.30</td><td><a href="http://ftp.ext.hp.com/pub/softpaq/sp172001-172500/sp172442.exe">sp172442</a></td></tr>' +
    '<tr><td>3.40</td><td><a href="https://ftp.ext.hp.com/pub/softpaq/sp173001-173500/sp173204.exe">sp173204</a></td></tr>' +
    '<a href="https://ftp.ext.hp.com/pub/softpaq/sp173001-173500/sp173204.html">notes</a>'
$hpPe = ConvertFrom-HpWinPEPage -Html $hpHtml
Assert-Equal "$($hpPe.Version)|$($hpPe.Url)|$($hpPe.FileName)" 'sp173204|https://ftp.ext.hp.com/pub/softpaq/sp173001-173500/sp173204.exe|sp173204.exe' 'hp winpe: newest softpaq'
Assert-Equal "$($null -eq (ConvertFrom-HpWinPEPage -Html '<html>maintenance</html>'))" 'True' 'hp winpe: page without softpaqs gives none'

$vmdDir = Join-Path ([IO.Path]::GetTempPath()) ("vmd-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $vmdDir 'x64/network') -Force | Out-Null
    Set-Content (Join-Path $vmdDir 'x64/network/e1d.inf') 'inf'
    Assert-Equal (Test-VmdDriverPresent -Folder $vmdDir) $false 'vmd: a pack without iaStorVD has no VMD driver'
    New-Item -ItemType Directory -Path (Join-Path $vmdDir 'x64/storage/RST') -Force | Out-Null
    Set-Content (Join-Path $vmdDir 'x64/storage/RST/iaStorVD.inf') 'inf'
    Assert-Equal (Test-VmdDriverPresent -Folder $vmdDir) $true 'vmd: iaStorVD.inf is the VMD driver'
} finally { Remove-Item $vmdDir -Recurse -Force -ErrorAction SilentlyContinue }

# HP: SoftPaq joined by id, SystemId list split, ftp/http rewritten to https, rows with a missing SoftPaq skipped.
$hp = @(ConvertFrom-HpDriverPackCatalog -Path (Join-Path $fixtures 'HPClientDriverPackCatalog.xml'))
Assert-Equal $hp.Count 2 'hp: rows without a SoftPaq are skipped'
$h = $hp | Where-Object Release -eq '24H2'
Assert-Equal ($h.Skus -join ',') '8A86,8A87' 'hp: system IDs are split'
Assert-Equal $h.Url 'https://ftp.hp.com/pub/softpaq/sp150001-150500/sp150001.exe' 'hp: url uses https'
Assert-Equal "$($h.Model)|$($h.Os)|$($h.Version)|$($h.FileName)" 'HP EliteBook 840 14 inch G9 Notebook PC|Windows 11|1.00 A 4|sp150001.exe' 'hp: fields'
$latest = @($hp | Select-LatestDriverPacks)
Assert-Equal "$($latest.Count) $($latest.Release)" '1 24H2' 'hp: newest release wins'

# Lenovo: friendly name without "(Type ...)", machine types, one row per OS release, crc used as SHA256.
$len = @(ConvertFrom-LenovoDriverPackCatalog -Path (Join-Path $fixtures 'catalogv2.xml'))
Assert-Equal $len.Count 4 'lenovo: one row per SCCM pack'
$latest = @($len | Where-Object Os -eq 'Windows 11' | Select-LatestDriverPacks)
Assert-Equal ($latest.Model -join ',') 'ThinkCentre M70q Gen 4,ThinkPad T14 Gen 4' 'lenovo: names drop the type list and are sorted'
$t = $latest | Where-Object Model -eq 'ThinkPad T14 Gen 4'
Assert-Equal "$($t.Release) $($t.HashType) $($t.MachineTypes -join ',')" '24H2 SHA256 21HD,21HE' 'lenovo: newest release, hash and types'
Assert-Equal (($latest | Where-Object Model -like 'ThinkCentre*').Hash) '' 'lenovo: no crc means no hash'

$packs = @(Get-VendorDriverPacks -Maker Dell -Os 'Windows 11' -CatalogPath (Join-Path $fixtures 'DriverPackCatalog.xml'))
Assert-Equal ($packs.Model -join ',') 'Latitude 5440,Latitude 5540' 'get-vendordriverpacks filters by OS'

# Registration in a content root.
$root = Join-Path ([IO.Path]::GetTempPath()) ("driverpacks-test-" + [guid]::NewGuid())
& $common { param($p) $script:LogPath = $p } (Join-Path $root 'test.log')
try {
    Initialize-ContentRoot -Path $root
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/driver-catalog-sample.json') (Join-Path $root 'config/driver-catalog.json') -Force   # the old example rows
    $relative = Get-DriverPackFolder $d
    Assert-Equal $relative 'Dell\Latitude 5440' 'pack folder is Maker\Model'
    $count = Register-DriverPack -ContentRoot $root -Pack $d -Path $relative
    Assert-Equal $count 3 'one entry per SKU plus the model name'
    $entries = @((Get-DriverCatalog -ContentRoot $root).entries | Where-Object maker -eq 'Dell')
    Assert-Equal (@($entries | Where-Object sku -eq '0B0B').Count) 1 'the existing SKU entry is replaced, not duplicated'
    Assert-Equal (@($entries | Where-Object { $_.model -eq 'Latitude 5440' }).Count) 1 'the existing model entry is replaced'
    Assert-Equal (@($entries | Where-Object modelPattern).Count) 1 'unrelated entries are kept'
    Register-DriverPack -ContentRoot $root -Pack $d -Path $relative | Out-Null
    Assert-Equal (@((Get-DriverCatalog -ContentRoot $root).entries | Where-Object maker -eq 'Dell').Count) 4 'registering twice adds nothing'

    # The deploy picks the downloaded pack for a PC with the new SKU.
    New-Item -ItemType Directory -Path (Join-Path $root 'Drivers/Dell/Latitude 5440') -Force | Out-Null
    Set-Content (Join-Path $root 'Drivers/Dell/Latitude 5440/a.inf') '[Version]'
    $hw = [pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5440'; MachineType = $null; Sku = '0C1D' }
    $pack = Resolve-DriverPack -Identity $hw -CatalogPath (Join-Path $root 'config/driver-catalog.json') -DriverRoot (Join-Path $root 'Drivers') 6>$null
    Assert-Equal ([IO.Path]::GetFileName($pack)) 'Latitude 5440' 'deploy matches the downloaded pack by SKU'

    # Library status from pack.json.
    Assert-Equal ((@($d) | Add-DriverPackLibraryStatus -ContentRoot $root).Installed) '' 'not downloaded yet'
    @{ url = $d.Url; os = 'Windows 11'; version = 'A07' } | ConvertTo-Json | Set-Content (Join-Path $root 'Drivers/Dell/Latitude 5440/pack.json')
    Assert-Equal ((@($d) | Add-DriverPackLibraryStatus -ContentRoot $root).Installed) 'Yes (Windows 11 A07)' 'downloaded pack is shown as installed'
    @{ url = 'https://downloads.dell.com/old.cab'; os = 'Windows 11'; version = 'A05' } | ConvertTo-Json | Set-Content (Join-Path $root 'Drivers/Dell/Latitude 5440/pack.json')
    Assert-Equal ((@($d) | Add-DriverPackLibraryStatus -ContentRoot $root).Installed) 'Update available (have Windows 11 A05)' 'older pack shows an update'

    # A .zip pack (no vendor .exe) goes through the whole install without the network: the url is a local file.
    $zipSrc = Join-Path $root 'zipsrc'
    New-Item -ItemType Directory -Path (Join-Path $zipSrc 'net') -Force | Out-Null
    Set-Content (Join-Path $zipSrc 'net/e1d.inf') '[Version]'
    $zip = Join-Path $root 'downloads/pack.zip'
    New-Item -ItemType Directory -Path (Split-Path $zip) -Force | Out-Null
    Compress-Archive -Path (Join-Path $zipSrc '*') -DestinationPath $zip
    $zipPack = [pscustomobject]@{
        Maker = 'Lenovo'; Model = 'ThinkPad X1 Carbon Gen 12'; Os = 'Windows 11'; Release = '24H2'; Version = '24H2'; Released = '2026-04-02'
        Url = 'https://example.invalid/pack.zip'; SizeMB = 1; Hash = (Get-FileHash $zip -Algorithm SHA256).Hash; HashType = 'SHA256'
        Skus = @(); MachineTypes = @('21KC'); Id = '21KC'; FileName = 'pack.zip'
    }
    $r = Install-VendorDriverPack -ContentRoot $root -Pack $zipPack -DownloadDir (Split-Path $zip) -KeepDownload 6>$null
    Assert-Equal "$($r.Path)|$($r.InfCount)|$($r.Entries)" 'Lenovo\ThinkPad X1 Carbon Gen 12|1|2' 'install extracts and registers a pack'
    Assert-Equal ((Get-InstalledDriverPack -ContentRoot $root -Pack $zipPack).version) '24H2' 'install writes pack.json'
    Assert-Equal (Test-Path (Join-Path $root 'Drivers/Lenovo/ThinkPad X1 Carbon Gen 12.new')) $false 'staging folder is gone'

    $zipPack.Hash = 'DEADBEEF'
    $threw = $false
    try { Install-VendorDriverPack -ContentRoot $root -Pack $zipPack -DownloadDir (Join-Path $root 'nowhere') 6>$null 3>$null } catch { $threw = $true }
    Assert-Equal $threw $true 'a failed download stops the install'
    Assert-Equal (Test-Path (Join-Path $root 'Drivers/Lenovo/ThinkPad X1 Carbon Gen 12/net/e1d.inf')) $true 'a failed update keeps the old drivers'

    # Vendor .exe extraction. HP's sp173204.exe (WinPE pack) exited 1168 for /s /e /f: the drivers that came out
    # count, then HP's CMSL form (-e -f <folder> -s) is tried, and only no drivers at all fails.
    $ex = Join-Path $root 'extract'
    $calls = [Collections.ArrayList]@()
    $writeInf = { param($Exe, $Arguments) [void]$calls.Add($Arguments -join ' '); New-Item -ItemType Directory -Path $ex -Force | Out-Null; Set-Content (Join-Path $ex 'x.inf') '[Version]'; 1168 }
    Invoke-VendorExtract -File 'C:\x\sp173204.exe' -Maker HP -Destination $ex -Runner $writeInf 6>$null
    Assert-Equal $calls.Count 1 'HP: an error exit with drivers extracted is accepted'
    Remove-Item $ex -Recurse -Force
    $calls.Clear()
    $secondWorks = { param($Exe, $Arguments) [void]$calls.Add($Arguments -join ' '); if ($Arguments[0] -eq '-e') { New-Item -ItemType Directory -Path $ex -Force | Out-Null; Set-Content (Join-Path $ex 'x.inf') '[Version]'; 0 } else { 1168 } }
    Invoke-VendorExtract -File 'C:\x\sp173204.exe' -Maker HP -Destination $ex -Runner $secondWorks 6>$null
    Assert-Equal ($calls -join '|') "/s /e /f `"$ex`"|-e -f `"$ex`" -s" 'HP: 1168 with nothing extracted retries with -e -f <folder> -s'
    Remove-Item $ex -Recurse -Force
    $msg = $null
    try { Invoke-VendorExtract -File 'C:\x\sp173204.exe' -Maker HP -Destination $ex -Runner { 1168 } 6>$null } catch { $msg = $_.Exception.Message }
    Assert-Equal $msg 'sp173204.exe exited with code 1168, then 1168 while extracting.' 'HP: no drivers after both tries fails with both codes'
    $msg = $null
    try { Invoke-VendorExtract -File 'C:\x\dell.exe' -Maker Dell -Destination $ex -Runner { 2 } 6>$null } catch { $msg = $_.Exception.Message }
    Assert-Equal $msg 'dell.exe exited with code 2 while extracting.' 'Dell: one try, its exit code reported'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# Find a model online: what the admin types against all three catalogs.
$cats = @{ Dell = (Join-Path $fixtures 'DriverPackCatalog.xml'); HP = (Join-Path $fixtures 'HPClientDriverPackCatalog.xml'); Lenovo = (Join-Path $fixtures 'catalogv2.xml') }
$every = @(foreach ($m in 'Dell', 'HP', 'Lenovo') { Get-VendorDriverPacks -Maker $m -Os 'Windows 11' -CatalogPath $cats[$m] })
function Get-Found([string]$q) { (@(Find-VendorDriverPack -Query $q -Packs $every) | ForEach-Object { "$($_.Maker) $($_.Model)" }) -join ',' }
Assert-Equal (Get-Found 'Latitude 5440') 'Dell Latitude 5440' 'find: model name'
Assert-Equal (Get-Found 'dell 5540') 'Dell Latitude 5540' 'find: maker and number, any case'
Assert-Equal (Get-Found '544') '' 'find: a number must match a whole word'
Assert-Equal (Get-Found 'lat') 'Dell Latitude 5440,Dell Latitude 5540' 'find: a word matches the start of a word'
Assert-Equal (Get-Found 'elitebook 840 g9') 'HP HP EliteBook 840 14 inch G9 Notebook PC' 'find: HP model in any order of words found'
Assert-Equal (Get-Found 't14 gen 4') 'Lenovo ThinkPad T14 Gen 4' 'find: Lenovo model'
Assert-Equal (Get-Found '21he') 'Lenovo ThinkPad T14 Gen 4' 'find: Lenovo machine type'
Assert-Equal (Get-Found '0C1D') 'Dell Latitude 5440' 'find: Dell SKU'
Assert-Equal (Get-Found 'Latitude 9999') '' 'find: every word must match'
Assert-Equal (Get-Found '   ') '' 'find: blank finds nothing'
$r = Find-VendorDriverPackOnline -Query 'lenovo t14' -CatalogPaths $cats
Assert-Equal "$(@($r.Packs).Count) $($r.Packs[0].Model) $(@($r.Errors).Count)" '1 ThinkPad T14 Gen 4 0' 'find online: maker word reads only that catalog'
$r = Find-VendorDriverPackOnline -Query 'thinkpad' -CatalogPaths @{ Dell = (Join-Path $fixtures 'missing.xml'); HP = $cats.HP; Lenovo = $cats.Lenovo }
Assert-Equal "$(@($r.Packs).Count) $(@($r.Errors).Count) $(@($r.Errors)[0] -like 'Could not read the Dell catalog*')" '1 1 True' 'find online: one broken catalog does not stop the others'
$d5440 = $every | Where-Object Model -eq 'Latitude 5440'
Assert-Equal (Format-VendorDriverPack $d5440) 'Dell Latitude 5440 - Windows 11 A07, 2026-06-10, 1536 MB' 'format: maker, model, version, date, size'
$hp9 = $every | Where-Object Maker -eq 'HP'
Assert-Equal ((Format-VendorDriverPack $hp9) -like 'HP EliteBook 840 14 inch G9 Notebook PC - Windows 11 24H2 1.00 A 4*') $true 'format: HP model is not prefixed twice'
$lt = ($every | Where-Object Model -eq 'ThinkPad T14 Gen 4').PSObject.Copy()
$lt | Add-Member -NotePropertyName Installed -NotePropertyValue 'Yes (Windows 11 24H2)' -Force
Assert-Equal ((Format-VendorDriverPack $lt) -like '*- already in the library') $true 'format: library status'

# A catalog cab whose XML has another name or extension, is UTF-16, or sits in a cab inside the cab (the Dell
# catalog on Patrick's console PC, 2026-11-10, came out with no DriverPackCatalog.xml). makecab.exe is Windows only.
$makecab = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\makecab.exe' }
if ($makecab -and (Test-Path $makecab)) {
    $cabDir = Join-Path ([IO.Path]::GetTempPath()) ("cab-" + [guid]::NewGuid())
    $srcDir = Join-Path $cabDir 'src'
    $dlDir = Join-Path $cabDir 'dl'   # only the download in it, as in the vendor cache folder
    New-Item -ItemType Directory -Path $srcDir, $dlDir | Out-Null
    try {
        function New-TestCab([string]$Source, [string]$Cab) { & $makecab $Source $Cab | Out-Null; if ($LASTEXITCODE) { throw "makecab exited $LASTEXITCODE" } }
        $src = Join-Path $srcDir 'catalog.bin'
        [IO.File]::WriteAllBytes($src, [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes('<?xml version="1.0" encoding="utf-16"?><DriverPackManifest version="9"/>'))
        $dl = Join-Path $dlDir 'DriverPackCatalog.cab'
        New-TestCab $src $dl
        $out = Join-Path $dlDir 'DriverPackCatalog.xml'
        Resolve-CatalogDownload -Download $dl -Xml $out -Maker Dell
        Assert-Equal "$(([xml](Get-Content -Raw $out)).DocumentElement.version) $(Test-Path $dl)" '9 False' 'catalog cab: UTF-16 XML under another name is found, cab removed'

        Remove-Item $out -Force
        $inner = Join-Path $srcDir 'inner.cab'
        New-TestCab $src $inner
        New-TestCab $inner $dl
        Resolve-CatalogDownload -Download $dl -Xml $out -Maker Dell
        Assert-Equal (Test-Path $out) $true 'catalog cab: XML in a cab inside the cab is found'

        Remove-Item $out -Force
        $junk = Join-Path $srcDir 'readme.bin'
        [IO.File]::WriteAllBytes($junk, [byte[]](1, 2, 3, 4))
        New-TestCab $junk $dl
        $msg = $null
        try { Resolve-CatalogDownload -Download $dl -Xml $out -Maker Dell } catch { $msg = $_.Exception.Message }
        # makecab stores a single file under the cab's own name, so only the kind and size are checked.
        Assert-Equal ("$msg" -replace 'it held \S+ \(', 'it held <file> (') "The Dell catalog (Cab) gave no catalog XML; it held <file> (Unknown, 4 bytes). The download was kept as $dl." 'catalog cab: no XML lists what it held'
        Assert-Equal (Test-Path $dl) $true 'catalog cab: no XML keeps the download'
    } finally { Remove-Item $cabDir -Recurse -Force -ErrorAction SilentlyContinue }
} else { Write-Host 'SKIP catalog cab tests: no makecab.exe' }

# Seamless downloads (Patrick, 2026-11-11): the console runs Get-DriverPacks.ps1 hidden and shows its progress.
Assert-Equal (Get-BitsPercent -Transferred 512 -Total 1024) 50 'bits: percent from bytes'
Assert-Equal (Get-BitsPercent -Transferred 0 -Total ([uint64]::MaxValue)) -1 'bits: unknown size is -1'
Assert-Equal (Get-BitsPercent -Transferred 5 -Total 0) -1 'bits: no size yet is -1'
Assert-Equal (Format-DriverPackName ([pscustomobject]@{ Maker = 'Lenovo'; Model = 'ThinkPad T570' })) 'Lenovo ThinkPad T570' 'name: maker and model'
Assert-Equal (Format-DriverPackName ([pscustomobject]@{ Maker = 'HP'; Model = 'HP EliteBook 840 G9' })) 'HP EliteBook 840 G9' 'name: HP not twice'
$dl = Get-Content -Raw (Join-Path $repo 'src/Console/DriverDownloader.ps1')
$start = $dl.Substring($dl.IndexOf('function Start-DriverPackDownload'))
$start = $start.Substring(0, $start.IndexOf("`nfunction ", 10))
Assert-Equal ($start -match "-WindowStyle Hidden -PassThru") $true 'download: the worker runs hidden'
Assert-Equal ($start -notmatch "-NoExit") $true 'download: no window left open'
Assert-Equal ($start -match 'Show-BuildProgress .*-Noun .download. -Hidden') $true 'download: progress shown in the console'
$gdp = Get-Content -Raw (Join-Path $repo 'src/Get-DriverPacks.ps1')
Assert-Equal ($gdp -match 'Install-VendorDriverPack .*-OnStage \$onStage') $true 'download: each pack reports its stage'

$bs = Import-Module (Join-Path $repo 'src/BuildSteps.psm1') -Force -PassThru
$pf = Join-Path ([IO.Path]::GetTempPath()) ("dlprogress-" + [guid]::NewGuid() + '.json')
try {
    Start-BuildProgress -Path $pf -Title 'Downloading 2 driver packs' -Steps @(@('pack1', 'Dell Latitude 5531'), @('pack2', 'Lenovo ThinkPad T570'))
    Start-BuildStep 'pack1'; Set-BuildStepProgress 'pack1' -Percent 40 -Detail 'Downloading 1650 MB'
    Complete-BuildStep 'pack1' -State failed -Detail 'hash check failed'
    Start-BuildStep 'pack2'; Complete-BuildStep 'pack2' -Detail '105 drivers in Drivers\Lenovo\ThinkPad T570'
    Stop-BuildProgress -Message '1 of 2 packs failed, see the rows below.'
    $v = Get-BuildStepView -Data (Read-BuildProgress -Path $pf)
    Assert-Equal (($v.Rows | ForEach-Object { "$($_.Status)|$($_.Percent)" }) -join ',') 'Failed|40,Complete|100' 'progress: a failed pack keeps its bar, the next one completes'
    Assert-Equal "$($v.Failed) $($v.Summary)" 'True Failed: 1 of 2 packs failed, see the rows below.' 'progress: the summary says how many failed'
} finally { Remove-Item $pf -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
