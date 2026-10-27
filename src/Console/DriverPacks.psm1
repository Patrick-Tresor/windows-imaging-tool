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
    if ($download -like '*.cab') {
        Expand-CabFile -Cab $download -Destination $dir
        Remove-Item $download -Force
    }
    if (-not (Test-Path $xml)) { throw "The $Maker catalog did not contain $($info.Xml)." }
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
    $switches = switch ($Maker) {
        'Dell'   { @('/s', "/e=`"$Destination`"") }
        'HP'     { @('/s', '/e', '/f', "`"$Destination`"") }
        'Lenovo' { @('/VERYSILENT', '/SUPPRESSMSGBOXES', "/DIR=`"$Destination`"", '/EXTRACT=YES') }
    }
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

Export-ModuleMember -Function Get-DriverPackCacheDir, ConvertFrom-DellDriverPackCatalog, ConvertFrom-HpDriverPackCatalog,
    ConvertFrom-LenovoDriverPackCatalog, Select-LatestDriverPacks, Update-VendorCatalog, Get-VendorDriverPacks,
    Get-DriverPackFolder, Get-InstalledDriverPack, Add-DriverPackLibraryStatus, Register-DriverPack,
    Expand-VendorDriverPack, Install-VendorDriverPack
