# Driver pack builder: reads the Dell, HP and Lenovo driver pack catalogs, downloads the packs for chosen
# models, extracts them into Drivers\<Maker>\<Model> and registers them in driver-catalog.json.
# The catalog parsers have no Windows dependencies, so they are tested off Windows with sample XML.

Import-Module (Join-Path $PSScriptRoot 'ConsoleData.psm1')
$ErrorActionPreference = 'Stop'   # a failed download or extraction must stop that pack, not carry on

$script:VendorCatalogs = @{
    Dell   = @{ Url = 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'; Xml = 'DriverPackCatalog.xml' }
    HP     = @{ Url = 'https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab'; Xml = 'HPClientDriverPackCatalog.xml' }
    Lenovo = @{ Url = 'https://download.lenovo.com/cdrt/td/catalogv2.xml'; Xml = 'catalogv2.xml' }
}

function Join-ContentPath {
    # Same as the private helper in ConsoleData.psm1: catalog paths use backslashes, normalized so tests run off Windows.
    param([string]$Root, [string]$Child)
    Join-Path $Root ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
}

# The signer a downloaded .exe must carry before it is run to extract itself.
$script:Signers = @{ Dell = 'Dell'; HP = 'HP Inc'; Lenovo = 'Lenovo' }

function Get-DriverPackCacheDir {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
    Join-ContentPath $base 'ImagingConsole\VendorCatalogs'
}

function Get-OsKey {
    # Normalizes each vendor's OS naming to 'Windows 10' or 'Windows 11'.
    param([string]$Text)
    # Dell osCode "Windows11", HP "Windows 11 64-bit, 23H2", Lenovo "win11".
    if ($Text -match '(?i)win(dows)?\s*(1[01])\b') { "Windows $($Matches[2])" }
}

function New-PackRow {
    param($Maker, $Model, $Os, $Release, $Version, $Released, $Url, $Size, $Hash, $HashType, $Skus, $MachineTypes, $Id)
    [pscustomobject]@{
        Maker        = $Maker
        Model        = $Model
        Os           = $Os
        Release      = "$Release"
        Version      = "$Version"
        Released     = $Released
        Url          = $Url
        SizeMB       = if ($Size) { [Math]::Round([double]$Size / 1MB) } else { $null }
        Hash         = if ($Hash) { "$Hash".Trim().ToUpperInvariant() } else { $null }
        HashType     = if ($Hash) { $HashType } else { $null }
        Skus         = @($Skus | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToUpperInvariant() } | Select-Object -Unique)
        MachineTypes = @($MachineTypes | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToUpperInvariant() } | Select-Object -Unique)
        Id           = $Id
        FileName     = [IO.Path]::GetFileName(([uri]$Url).AbsolutePath)
    }
}

function ConvertTo-Date([string]$Text) {
    # yyyy-MM-dd text: sorts correctly and survives the JSON job file in PowerShell 5.1, unlike a DateTime.
    if ($Text -match '^\d{4}-\d{2}-\d{2}') { $Matches[0] }
}

#region Catalog parsers

function ConvertFrom-DellDriverPackCatalog {
    # DriverPackCatalog.xml: one DriverPackage per pack, listing the systems (brand + model + systemID) it covers.
    param([Parameter(Mandatory)][string]$Path)
    [xml]$x = Get-Content -Raw -Path $Path
    $base = $x.DocumentElement.GetAttribute('baseLocation')
    if (-not $base) { $base = 'downloads.dell.com' }
    foreach ($p in $x.SelectNodes("//*[local-name()='DriverPackage']")) {
        if ($p.GetAttribute('type') -ne 'win') { continue }   # 'winpe' packs are for the boot image, not the OS
        $os = $p.SelectNodes("*[local-name()='SupportedOperatingSystems']/*[local-name()='OperatingSystem']") |
            Where-Object { $_.GetAttribute('osArch') -eq 'x64' } |
            ForEach-Object { Get-OsKey $_.GetAttribute('osCode') } | Where-Object { $_ } | Select-Object -Unique
        if (-not $os) { continue }
        $sha = $p.SelectSingleNode("*[local-name()='Cryptography']/*[local-name()='Hash'][@algorithm='SHA256']")
        $hash, $hashType = if ($sha) { $sha.InnerText, 'SHA256' } else { $p.GetAttribute('hashMD5'), 'MD5' }
        $url = 'https://' + $base.TrimEnd('/') + '/' + $p.GetAttribute('path').TrimStart('/')

        # One row per model: a pack often covers several models (e.g. Latitude 5440 and 5540), each with its own SKUs.
        $models = [ordered]@{}
        foreach ($b in $p.SelectNodes("*[local-name()='SupportedSystems']/*[local-name()='Brand']")) {
            $brand = $b.SelectSingleNode("*[local-name()='Display']").InnerText.Trim()
            foreach ($m in $b.SelectNodes("*[local-name()='Model']")) {
                $display = $m.SelectSingleNode("*[local-name()='Display']")
                $name = "$brand $(if ($display) { $display.InnerText.Trim() } else { $m.GetAttribute('name') })".Trim()
                if (-not $models.Contains($name)) { $models[$name] = [Collections.Generic.List[string]]::new() }
                $models[$name].Add($m.GetAttribute('systemID'))
            }
        }
        foreach ($name in $models.Keys) {
            foreach ($o in $os) {
                New-PackRow -Maker Dell -Model $name -Os $o -Release '' -Version $p.GetAttribute('vendorVersion') `
                    -Released (ConvertTo-Date $p.GetAttribute('dateTime')) -Url $url -Size $p.GetAttribute('size') `
                    -Hash $hash -HashType $hashType -Skus $models[$name] -Id $p.GetAttribute('releaseID')
            }
        }
    }
}

function ConvertFrom-DellWinPEDriverPacks {
    # The WinPE driver packs in Dell's DriverPackCatalog.xml (type 'winpe'): storage (Intel RST/VMD), network and
    # other drivers WinPE itself needs. Intel's drivers in them match on the controller, so they work on any maker's PC.
    # Newest WinPE version first (WinPE 11 before 10), then newest release.
    param([Parameter(Mandatory)][string]$Path)
    [xml]$x = Get-Content -Raw -Path $Path
    $base = $x.DocumentElement.GetAttribute('baseLocation')
    if (-not $base) { $base = 'downloads.dell.com' }
    $rows = foreach ($p in $x.SelectNodes("//*[local-name()='DriverPackage']")) {
        if ($p.GetAttribute('type') -ne 'winpe') { continue }
        $file = $p.GetAttribute('path')
        $pe = if ($file -match '(?i)WinPE(\d+(\.\d+)?)') { [double]$Matches[1] } else { 0 }
        $sha = $p.SelectSingleNode("*[local-name()='Cryptography']/*[local-name()='Hash'][@algorithm='SHA256']")
        $hash, $hashType = if ($sha) { $sha.InnerText, 'SHA256' } else { $p.GetAttribute('hashMD5'), 'MD5' }
        $row = New-PackRow -Maker Dell -Model 'WinPE' -Os "WinPE $pe" -Release '' -Version $p.GetAttribute('vendorVersion') `
            -Released (ConvertTo-Date $p.GetAttribute('dateTime')) -Url ('https://' + $base.TrimEnd('/') + '/' + $file.TrimStart('/')) `
            -Size $p.GetAttribute('size') -Hash $hash -HashType $hashType -Id $p.GetAttribute('releaseID')
        $row | Add-Member -NotePropertyName WinPEVersion -NotePropertyValue $pe -PassThru
    }
    @($rows | Sort-Object @{ Expression = 'WinPEVersion'; Descending = $true }, @{ Expression = 'Released'; Descending = $true })
}

# Used when the catalog lists no WinPE pack or can't be read: Dell's WinPE 11 pack A11 (2026-10-14, 34 MB), with
# Intel RST (VMD) 17.11 to 21.0 and Intel VROC storage drivers. It has no hash here, so its Dell signature is checked.
$script:DellWinPEFallback = @{ Url = 'https://downloads.dell.com/FOLDER15124725M/1/WinPE11.0-Drivers-A11-KHF4P.cab'; Version = 'A11'; WinPEVersion = 11 }

# Intel RST/VMD storage drivers: without one of these, WinPE sees no SSD on a PC with VMD on.
$script:VmdDriverNames = 'iaStorVD.inf', 'iaStorAC.inf', 'iaStorAVC.inf', 'iaVROC.inf', 'iaStorE.inf'

function Test-VmdDriverPresent {
    # True when a folder of drivers includes an Intel RST/VMD storage driver.
    param([Parameter(Mandatory)][string]$Folder)
    [bool](Get-ChildItem -Path $Folder -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $script:VmdDriverNames } | Select-Object -First 1)
}

function Save-WinPEDriverPack {
    <#
    .SYNOPSIS
        Downloads and extracts Dell's newest WinPE driver pack into the cache (once per version). Returns Path,
        Source and Version, and HasVmd (an Intel RST/VMD driver is in it). New-DeploymentMedia.ps1 adds it to
        every build, so WinPE sees SSDs behind Intel RST/VMD (the default on many 11th gen and later laptops).
        Falls back to a known pack when the catalog lists none or can't be read.
    #>
    param([string]$CacheDir = (Get-DriverPackCacheDir), [string]$CatalogPath, [switch]$Refresh)
    $pack = $null; $why = $null
    try {
        if (-not $CatalogPath) { $CatalogPath = Update-VendorCatalog -Maker Dell -CacheDir $CacheDir -Force:$Refresh }
        $pack = ConvertFrom-DellWinPEDriverPacks -Path $CatalogPath | Select-Object -First 1
        if (-not $pack) { $why = 'the Dell catalog lists no WinPE pack' }
    } catch { $why = "the Dell catalog could not be read ($($_.Exception.Message))" }
    $fallback = -not $pack
    if ($fallback) {
        $f = $script:DellWinPEFallback
        $pack = [pscustomobject]@{ Url = $f.Url; Version = $f.Version; WinPEVersion = $f.WinPEVersion; Hash = $null; HashType = $null
            FileName = [IO.Path]::GetFileName(([uri]$f.Url).AbsolutePath); SizeMB = 34 }
        Write-Host "Using the built-in Dell WinPE pack link: $why."
    }
    $dest = Join-Path $CacheDir "WinPE\Dell-WinPE$($pack.WinPEVersion)-$($pack.Version)"
    $source = "Dell WinPE $($pack.WinPEVersion) driver pack $($pack.Version)"
    if (-not (Test-Path (Join-Path $dest 'pack.json'))) {
        $file = Join-Path $CacheDir "WinPE\$($pack.FileName)"
        Write-Host "Downloading the $source ($($pack.SizeMB) MB)..."
        Save-WebFile -Url $pack.Url -Destination $file -DisplayName 'Dell WinPE driver pack'
        if ($pack.Hash) {
            $actual = (Get-FileHash $file -Algorithm $pack.HashType).Hash
            if ($actual -ne $pack.Hash) { Remove-Item $file -Force; throw "$($pack.FileName) failed its $($pack.HashType) check. Deleted it; build again." }
        } else {
            try { Test-VendorSignature -File $file -Maker Dell } catch { Remove-Item $file -Force; throw }
        }
        $staging = "$dest.new"
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
        Expand-VendorDriverPack -File $file -Maker Dell -Destination $staging
        if (-not (Get-ChildItem -Path $staging -Filter *.inf -Recurse -File | Select-Object -First 1)) {
            Remove-Item $staging -Recurse -Force
            throw "No .inf files in $($pack.FileName)."
        }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Move-Item $staging $dest
        Remove-Item $file -Force
        [ordered]@{ version = $pack.Version; winpe = $pack.WinPEVersion; url = $pack.Url; downloaded = (Get-Date).ToString('yyyy-MM-dd HH:mm') } |
            ConvertTo-Json | Set-Content -Path (Join-Path $dest 'pack.json') -Encoding utf8
    }
    [pscustomobject]@{ Path = $dest; Source = $source; Version = $pack.Version; HasVmd = Test-VmdDriverPresent -Folder $dest; Fallback = $fallback }
}

function ConvertFrom-HpDriverPackCatalog {
    # HPClientDriverPackCatalog.xml: ProductOSDriverPack rows (platform + OS -> SoftPaq id) and a SoftPaqList with the files.
    param([Parameter(Mandatory)][string]$Path)
    [xml]$x = Get-Content -Raw -Path $Path
    $softpaqs = @{}
    foreach ($sp in $x.SelectNodes("//*[local-name()='SoftPaqList']/*[local-name()='SoftPaq']")) { $softpaqs[$sp.Id] = $sp }
    foreach ($r in $x.SelectNodes("//*[local-name()='ProductOSDriverPackList']/*[local-name()='ProductOSDriverPack']")) {
        $os = Get-OsKey $r.OSName
        $sp = $softpaqs[$r.SoftPaqId]
        if (-not $os -or -not $sp -or $r.OSName -notmatch '64') { continue }
        $hash, $hashType = if ($sp.SHA256) { $sp.SHA256, 'SHA256' } else { $sp.MD5, 'MD5' }
        New-PackRow -Maker HP -Model $r.SystemName.Trim() -Os $os -Release ([regex]::Match($r.OSName, '\d{2}H\d').Value) `
            -Version $sp.Version -Released (ConvertTo-Date $sp.DateReleased) -Url ($sp.Url -replace '^(ftp|http)://', 'https://') `
            -Size $sp.Size -Hash $hash -HashType $hashType -Skus ($r.SystemId -split '[,;\s]+') -Id $sp.Id
    }
}

function ConvertFrom-LenovoDriverPackCatalog {
    # catalogv2.xml: one Model per product with its machine types and an SCCM driver pack per OS and release.
    param([Parameter(Mandatory)][string]$Path)
    [xml]$x = Get-Content -Raw -Path $Path
    foreach ($m in $x.SelectNodes("//*[local-name()='Model']")) {
        $name = ($m.GetAttribute('name') -replace '\s*\(Type[^)]*\)\s*$', '').Trim()
        $types = @($m.SelectNodes("*[local-name()='Types']/*[local-name()='Type']") | ForEach-Object { $_.InnerText })
        foreach ($s in $m.SelectNodes("*[local-name()='SCCM']")) {
            $os = Get-OsKey $s.GetAttribute('os')
            $url = $s.InnerText.Trim()
            if (-not $os -or $url -notmatch '^https?://') { continue }
            $crc = $s.GetAttribute('crc')
            New-PackRow -Maker Lenovo -Model $name -Os $os -Release $s.GetAttribute('version') -Version $s.GetAttribute('version') `
                -Released (ConvertTo-Date $s.GetAttribute('date')) -Url ($url -replace '^http://', 'https://') `
                -Hash $(if ($crc -match '^[0-9a-fA-F]{64}$') { $crc }) -HashType SHA256 -MachineTypes $types -Id $types[0]
        }
    }
}

function Select-LatestDriverPacks {
    # Keeps the newest pack per maker, model and OS: highest release (23H2 > 22H2), then newest date.
    param([Parameter(ValueFromPipeline)]$Pack)
    begin { $all = [Collections.Generic.List[object]]::new() }
    process { if ($Pack) { $all.Add($Pack) } }
    end {
        $all | Group-Object Maker, Model, Os | ForEach-Object {
            $_.Group | Sort-Object @{ e = 'Release'; Descending = $true }, @{ e = 'Released'; Descending = $true } | Select-Object -First 1
        } | Sort-Object Model
    }
}

#endregion

#region Vendor catalogs

function Expand-CabFile {
    param([string]$Cab, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & expand.exe $Cab -F:* $Destination | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "expand.exe failed on $Cab" }
}

function Save-WebFile {
    # BITS survives large files and flaky links; Invoke-WebRequest is the fallback where BITS is unavailable.
    param([string]$Url, [string]$Destination, [string]$DisplayName)
    # Downloads to .part and renames, so an interrupted download is never mistaken for a finished one.
    New-Item -ItemType Directory -Path (Split-Path $Destination) -Force | Out-Null
    $part = "$Destination.part"
    Remove-Item $part -Force -ErrorAction SilentlyContinue
    $done = $false
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            Start-BitsTransfer -Source $Url -Destination $part -DisplayName $DisplayName
            $done = $true
        } catch { Write-Warning "BITS download failed ($($_.Exception.Message)), retrying with Invoke-WebRequest." }
    }
    if (-not $done) {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest many times slower in PowerShell 5.1
        try { Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing } finally { $ProgressPreference = $old }
    }
    Move-Item $part $Destination -Force
}

function Get-DownloadKind {
    # What a downloaded file really is, from its first bytes: Cab, Gzip, Zip, Xml, Html or Unknown.
    param([Parameter(Mandatory)][string]$Path)
    $bytes = New-Object byte[] 512
    $fs = [IO.File]::OpenRead($Path)
    try { $n = $fs.Read($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    if ($n -ge 4 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'MSCF') { return 'Cab' }
    if ($n -ge 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) { return 'Gzip' }
    if ($n -ge 2 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B) { return 'Zip' }
    $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $n).TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
    if ($text -match '^(?i)<(!doctype html|html)') { return 'Html' }
    if ($text.StartsWith('<')) { return 'Xml' }
    'Unknown'
}

function Expand-GzipFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)
    $in = [IO.File]::OpenRead($Path)
    try {
        $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
        $out = [IO.File]::Create($Destination)
        try { $gz.CopyTo($out) } finally { $out.Dispose(); $gz.Dispose() }
    } finally { $in.Dispose() }
}

function Update-VendorCatalog {
    # Downloads a vendor catalog into the cache when it is missing or older than MaxAgeHours. Returns the XML path.
    param(
        [Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Maker,
        [string]$CacheDir = (Get-DriverPackCacheDir),
        [int]$MaxAgeHours = 24,
        [switch]$Force
    )
    $info = $script:VendorCatalogs[$Maker]
    $dir = Join-Path $CacheDir $Maker
    $xml = Join-Path $dir $info.Xml
    if (-not $Force -and (Test-Path $xml) -and (Get-Item $xml).LastWriteTime -gt (Get-Date).AddHours(-$MaxAgeHours)) { return $xml }

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $download = Join-Path $dir ([IO.Path]::GetFileName($info.Url))
    Save-WebFile -Url $info.Url -Destination $download -DisplayName "$Maker driver pack catalog"
    # Check what really came down: expand.exe "succeeds" on a file that is not a cab and leaves no XML behind.
    # Dell's CDN or a proxy can send the XML itself, a gzip, or an HTML page instead of the cab.
    $kind = Get-DownloadKind -Path $download
    switch ($kind) {
        'Cab'  { Expand-CabFile -Cab $download -Destination $dir }
        'Gzip' { Expand-GzipFile -Path $download -Destination $xml }
        'Xml'  { if ($download -ne $xml) { Copy-Item $download $xml -Force } }
        default {
            $size = (Get-Item $download).Length
            Remove-Item $download -Force
            throw ("The $Maker catalog download from $($info.Url) is not a catalog ($kind, $size bytes). " +
                $(if ($kind -eq 'Html') { 'A proxy or firewall probably answered instead of the vendor; allow that address.' } else { 'Try again later.' }))
        }
    }
    if ($download -ne $xml) { Remove-Item $download -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $xml)) {
        # Use the catalog XML the cab holds, whatever its exact name.
        $found = Get-ChildItem -Path $dir -Filter *.xml -File | Where-Object Name -ne $info.Xml | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { Move-Item $found.FullName $xml -Force }
    }
    if (-not (Test-Path $xml)) {
        $have = @(Get-ChildItem -Path $dir -File | ForEach-Object Name) -join ', '
        throw "The $Maker catalog ($kind) did not contain $($info.Xml). The folder $dir has: $(if ($have) { $have } else { 'nothing' })."
    }
    (Get-Item $xml).LastWriteTime = Get-Date
    $xml
}

function Get-VendorDriverPacks {
    # The newest x64 driver pack for every model a vendor publishes, for one OS.
    param(
        [Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Maker,
        [ValidateSet('Windows 10', 'Windows 11')][string]$Os = 'Windows 11',
        [string]$CatalogPath,
        [string]$CacheDir = (Get-DriverPackCacheDir),
        [switch]$Refresh
    )
    if (-not $CatalogPath) { $CatalogPath = Update-VendorCatalog -Maker $Maker -CacheDir $CacheDir -Force:$Refresh }
    $packs = switch ($Maker) {
        'Dell'   { ConvertFrom-DellDriverPackCatalog -Path $CatalogPath }
        'HP'     { ConvertFrom-HpDriverPackCatalog -Path $CatalogPath }
        'Lenovo' { ConvertFrom-LenovoDriverPackCatalog -Path $CatalogPath }
    }
    $packs | Where-Object Os -eq $Os | Select-LatestDriverPacks
}

#endregion

#region Library

function Get-DriverPackFolder {
    # Catalog-relative folder for a pack: Drivers\<Maker>\<Model>, the same layout as a manual import.
    param([Parameter(Mandatory)]$Pack)
    "$($Pack.Maker)\$($Pack.Model -replace '[\\/:*?"<>|]', '_')"
}

function Get-InstalledDriverPack {
    # The pack.json written by Install-VendorDriverPack, or $null when the folder was not downloaded by it.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Pack)
    $file = Join-ContentPath $ContentRoot "Drivers\$(Get-DriverPackFolder $Pack)\pack.json"
    if (Test-Path $file) { Get-Content -Raw $file | ConvertFrom-Json }
}

function Add-DriverPackLibraryStatus {
    # Adds an Installed column to catalog rows: the version in the library, and whether the catalog has a newer one.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(ValueFromPipeline)]$Pack)
    process {
        $have = Get-InstalledDriverPack -ContentRoot $ContentRoot -Pack $Pack
        $status = if (-not $have) { '' }
                  elseif ($have.url -eq $Pack.Url) { "Yes ($($have.os) $($have.version))" }
                  else { "Update available (have $($have.os) $($have.version))" }
        $Pack | Add-Member -NotePropertyName Installed -NotePropertyValue $status -Force -PassThru
    }
}

function Register-DriverPack {
    # Points the pack's SKUs (Dell, HP), machine types (Lenovo) and model name at its folder in driver-catalog.json.
    # Existing entries for the same maker and key are replaced, so a re-download or an update does not leave duplicates.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Pack, [Parameter(Mandatory)][string]$Path)
    $new = @(
        foreach ($s in $Pack.Skus) { [pscustomobject]@{ Maker = $Pack.Maker; Sku = $s; Path = $Path } }
        foreach ($t in $Pack.MachineTypes) { [pscustomobject]@{ Maker = $Pack.Maker; MachineType = $t; Path = $Path } }
        [pscustomobject]@{ Maker = $Pack.Maker; Model = $Pack.Model; Path = $Path }
    )
    $keep = Get-DriverCatalogRows -ContentRoot $ContentRoot | Where-Object {
        $r = $_
        -not ($r.Maker -eq $Pack.Maker -and (
            ($r.Sku -and $r.Sku -in $Pack.Skus) -or
            ($r.MachineType -and $r.MachineType -in $Pack.MachineTypes) -or
            ($r.Model -and $r.Model -eq $Pack.Model -and -not $r.Sku -and -not $r.MachineType)))
    }
    # New entries go first: the deploy takes the first match, and these are the most exact.
    Save-DriverCatalog -ContentRoot $ContentRoot -Rows @($new + @($keep))
    $new.Count
}

function Test-VendorSignature {
    # Only run a vendor .exe that carries a valid Authenticode signature from that vendor.
    param([string]$File, [string]$Maker)
    $sig = Get-AuthenticodeSignature -FilePath $File
    if ($sig.Status -ne 'Valid') { throw "$([IO.Path]::GetFileName($File)) is not validly signed ($($sig.Status)). Not running it." }
    if ($sig.SignerCertificate.Subject -notmatch [regex]::Escape($script:Signers[$Maker])) {
        throw "$([IO.Path]::GetFileName($File)) is signed by '$($sig.SignerCertificate.Subject)', not $Maker. Not running it."
    }
}

function Expand-VendorDriverPack {
    # Extracts a downloaded pack into Destination with each vendor's own switches.
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Maker, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
    if ($ext -eq '.cab') { Expand-CabFile -Cab $File -Destination $Destination; return }
    if ($ext -eq '.zip') { Expand-Archive -Path $File -DestinationPath $Destination -Force; return }
    if ($ext -ne '.exe') { throw "Don't know how to extract $ext files." }

    Test-VendorSignature -File $File -Maker $Maker
    $switches = @(switch ($Maker) {
        'Dell'   { '/s', "/e=`"$Destination`"" }
        'HP'     { '/s', '/e', '/f', "`"$Destination`"" }
        'Lenovo' { '/VERYSILENT', '/SUPPRESSMSGBOXES', "/DIR=`"$Destination`"", '/EXTRACT=YES' }
    })
    $proc = Start-Process -FilePath $File -ArgumentList $switches -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0) { throw "$([IO.Path]::GetFileName($File)) exited with code $($proc.ExitCode) while extracting." }
}

function Install-VendorDriverPack {
    # Downloads, checks, extracts and registers one pack. The old folder is only replaced once the new one extracted.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)]$Pack,
        [string]$DownloadDir = (Join-Path ([IO.Path]::GetTempPath()) 'ImagingConsole-Downloads'),
        [switch]$KeepDownload
    )
    $relative = Get-DriverPackFolder $Pack
    $dest = Join-ContentPath $ContentRoot "Drivers\$relative"
    $file = Join-Path $DownloadDir $Pack.FileName

    if (-not (Test-Path $file) -or ($Pack.Hash -and (Get-FileHash $file -Algorithm $Pack.HashType).Hash -ne $Pack.Hash)) {
        Write-Host "Downloading $($Pack.FileName) ($($Pack.SizeMB) MB)..."
        Save-WebFile -Url $Pack.Url -Destination $file -DisplayName "$($Pack.Maker) $($Pack.Model)"
    }
    if ($Pack.Hash) {
        $actual = (Get-FileHash $file -Algorithm $Pack.HashType).Hash
        if ($actual -ne $Pack.Hash) {
            Remove-Item $file -Force
            throw "$($Pack.FileName) failed its $($Pack.HashType) check (expected $($Pack.Hash), got $actual). Deleted it; try again."
        }
    } else {
        Write-Warning "The $($Pack.Maker) catalog has no hash for $($Pack.FileName); only the signature is checked."
    }

    Write-Host "Extracting to Drivers\$relative..."
    $staging = "$dest.new"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    Expand-VendorDriverPack -File $file -Maker $Pack.Maker -Destination $staging
    $infs = @(Get-ChildItem -Path $staging -Filter *.inf -Recurse -File).Count
    if ($infs -eq 0) {
        Remove-Item $staging -Recurse -Force
        throw "No .inf files were found after extracting $($Pack.FileName)."
    }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item $staging $dest

    [ordered]@{
        maker = $Pack.Maker; model = $Pack.Model; os = $Pack.Os; release = $Pack.Release; version = $Pack.Version
        released = $Pack.Released; url = $Pack.Url
        downloaded = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    } | ConvertTo-Json | Set-Content -Path (Join-Path $dest 'pack.json') -Encoding utf8

    $entries = Register-DriverPack -ContentRoot $ContentRoot -Pack $Pack -Path $relative
    if (-not $KeepDownload) { Remove-Item $file -Force }
    [pscustomobject]@{ Path = $relative; InfCount = $infs; Entries = $entries }
}

#endregion

Export-ModuleMember -Function Get-DriverPackCacheDir, ConvertFrom-DellDriverPackCatalog, ConvertFrom-DellWinPEDriverPacks, Save-WinPEDriverPack, Test-VmdDriverPresent, ConvertFrom-HpDriverPackCatalog,
    ConvertFrom-LenovoDriverPackCatalog, Select-LatestDriverPacks, Get-DownloadKind, Update-VendorCatalog, Get-VendorDriverPacks,
    Get-DriverPackFolder, Get-InstalledDriverPack, Add-DriverPackLibraryStatus, Register-DriverPack,
    Expand-VendorDriverPack, Install-VendorDriverPack
