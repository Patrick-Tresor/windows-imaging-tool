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
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
