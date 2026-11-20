# Plain-PowerShell tests for driver packs as one file each on the stick (src/DriverPackFile.psm1) and the deploy
# finding <folder>.wim (Resolve-DriverPack). The DISM round trip runs only on Windows as administrator (CI does).
# Run: powershell -File tests\DriverPackFile.Tests.ps1; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/MediaCopy.psm1') -Force
Import-Module (Join-Path $repo 'src/DriverPackFile.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

function Join-T([string]$Root, [string]$Rel) { [IO.Path]::Combine($Root, ($Rel -replace '\\', [IO.Path]::DirectorySeparatorChar)) }
function New-T([string]$Root, [string]$Rel, [string]$Text) {
    $p = Join-T $Root $Rel
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p))
    [IO.File]::WriteAllText($p, $Text)
}

$base = Join-Path ([IO.Path]::GetTempPath()) ("drvpack-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$src = Join-Path $base 'content'
$cache = Join-Path $base 'cache'
try {
    [void][IO.Directory]::CreateDirectory($base)
    Set-DeployLogPath -Path (Join-Path $base 'test.log')
    New-T $src 'config\driver-catalog.json' (@'
{ "entries": [
    { "maker": "Dell", "model": "Latitude 5521", "path": "Dell\\Latitude 5521" },
    { "maker": "Dell", "model": "Latitude 7400", "path": "Dell\\Latitude 7400" },
    { "maker": "HP", "model": "Outer", "path": "HP\\Elite" },
    { "maker": "HP", "model": "Inner", "path": "HP\\Elite\\G9" },
    { "maker": "Microsoft Corporation", "model": "Virtual Machine", "path": null } ],
  "fallbacks": { "Dell": "Dell\\_Generic", "Lenovo": "Lenovo\\_Generic" } }
'@)
    New-T $src 'Drivers\Dell\Latitude 5521\net\e1d.inf' '[Version] net'
    New-T $src 'Drivers\Dell\Latitude 5521\net\e1d.sys' 'sys bytes'
    New-T $src 'Drivers\Dell\Latitude 5521\storage\iaStorVD.inf' '[Version] storage'
    New-T $src 'Drivers\Dell\_Generic\x.inf' '[Version] generic'
    New-T $src 'Drivers\HP\Elite\a.inf' '[Version] a'
    New-T $src 'Drivers\HP\Elite\G9\b.inf' '[Version] b'
    New-T $src 'Drivers\_WinPE\Dell-WinPE11\rst.inf' '[Version] pe'
    New-T $src 'Drivers\Loose\c.inf' '[Version] not in the catalog'
    $catalog = Join-T $src 'config\driver-catalog.json'

    $plan = Get-MediaCopyPlan -ContentRoot $src -Folders 'config', 'Drivers'
    $folders = @(Get-DriverPackFolders -Plan $plan -CatalogPath $catalog -DriverRoots 'Drivers')
    Assert-Equal "$($folders.Count)|$($folders -contains 'Drivers\Dell\_Generic')|$($folders -contains 'Drivers\Dell\Latitude 5521')" '2|True|True' 'folders: catalog packs with files only (no _WinPE, no nested HP, no missing 7400)'

    $calls = New-Object System.Collections.ArrayList
    $fake = { param($folder, $dest, $name) [void]$calls.Add($name); [IO.File]::WriteAllText($dest, "packed $name") }
    $packed = ConvertTo-PackedDriverPlan -Plan $plan -ContentRoot $src -Folders $folders -CacheRoot $cache -Packer $fake
    $rels = @($packed.Items | ForEach-Object Relative)
    Assert-Equal (@($rels | Where-Object { $_ -like 'Drivers\Dell\Latitude 5521\*' }).Count) 0 'plan: the pack''s files are gone'
    Assert-Equal ($rels -contains 'Drivers\Dell\Latitude 5521.wim') $true 'plan: one .wim for the pack'
    Assert-Equal ($rels -contains 'Drivers\Dell\_Generic.wim') $true 'plan: the maker fallback is packed too'
    Assert-Equal ($rels -contains 'Drivers\_WinPE\Dell-WinPE11\rst.inf') $true 'plan: WinPE drivers stay plain files'
    Assert-Equal ($rels -contains 'Drivers\HP\Elite\G9\b.inf') $true 'plan: nested catalog folders stay plain files'
    Assert-Equal ($rels -contains 'Drivers\Loose\c.inf') $true 'plan: folders outside the catalog are untouched'
    Assert-Equal (@($packed.Directories | Where-Object { $_ -like 'Drivers\Dell\Latitude 5521*' }).Count) 0 'plan: no empty pack folder made on the stick'
    Assert-Equal $packed.FileCount $rels.Count 'plan: file count'
    $sum = [int64]0; foreach ($i in $packed.Items) { $sum += $i.Length }
    Assert-Equal $packed.TotalBytes $sum 'plan: total bytes'
    Assert-Equal "$($calls.Count)|$($calls -contains '_Generic')|$($calls -contains 'Latitude 5521')" '2|True|True' 'pack: each folder packed once, named after its folder'
    $row = @($packed.Packed | Where-Object { $_.Folder -eq 'Drivers\Dell\Latitude 5521' })[0]
    Assert-Equal "$($row.Files)|$($row.Reused)" '3|False' 'pack: report counts the files'

    # The next build reuses the cached files; a changed driver packs that folder again.
    $calls.Clear()
    $again = ConvertTo-PackedDriverPlan -Plan $plan -ContentRoot $src -Folders $folders -CacheRoot $cache -Packer $fake
    Assert-Equal $calls.Count 0 'cache: nothing packed again when nothing changed'
    Assert-Equal (@($again.Packed | Where-Object Reused).Count) 2 'cache: both reported as reused'
    $w1 = @($packed.Items | Where-Object Relative -eq 'Drivers\Dell\Latitude 5521.wim')[0].Source
    $w2 = @($again.Items | Where-Object Relative -eq 'Drivers\Dell\Latitude 5521.wim')[0].Source
    Assert-Equal $w2 $w1 'cache: same file reused'
    New-T $src 'Drivers\Dell\Latitude 5521\net\e1d.inf' '[Version] net, newer version'
    $plan2 = Get-MediaCopyPlan -ContentRoot $src -Folders 'config', 'Drivers'
    $third = ConvertTo-PackedDriverPlan -Plan $plan2 -ContentRoot $src -Folders $folders -CacheRoot $cache -Packer $fake
    Assert-Equal ($calls -join ';') 'Latitude 5521' 'cache: a changed pack is packed again, the other reused'
    $w3 = @($third.Items | Where-Object Relative -eq 'Drivers\Dell\Latitude 5521.wim')[0].Source
    Assert-Equal ($w3 -ne $w1) $true 'cache: the changed pack gets a new file'

    # A pack that can't be packed goes as plain files, with the reason.
    $bad = ConvertTo-PackedDriverPlan -Plan $plan -ContentRoot $src -Folders $folders -CacheRoot (Join-Path $base 'cache2') -Packer { param($f, $d, $n) if ($n -eq '_Generic') { throw 'disk full' } else { [IO.File]::WriteAllText($d, 'ok') } }
    Assert-Equal (@($bad.Failed | ForEach-Object { "$($_.Folder): $($_.Reason)" }) -join ';') 'Drivers\Dell\_Generic: disk full' 'failure: reported'
    Assert-Equal (@($bad.Items | ForEach-Object Relative) -contains 'Drivers\Dell\_Generic\x.inf') $true 'failure: that pack stays plain files'
    Assert-Equal (Test-Path (Join-Path (Join-Path $base 'cache2') '*.partial')) $false 'failure: no half-made file left in the cache'

    # Deploy: a stick with <folder>.wim (and no folder) gives that file as the driver pack.
    $stick = Join-Path $base 'stick'
    New-T $stick 'config\driver-catalog.json' ([IO.File]::ReadAllText($catalog))
    New-T $stick 'Drivers\Dell\Latitude 5521.wim' 'wim'
    $hw = [pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5521'; MachineType = $null; Sku = $null }
    $found = Resolve-DriverPack -Identity $hw -CatalogPath (Join-T $stick 'config\driver-catalog.json') -DriverRoot (Join-T $stick 'Drivers') 6>$null
    Assert-Equal ([IO.Path]::GetFileName($found)) 'Latitude 5521.wim' 'deploy: the packed file is used'
    New-T $src 'Drivers\Dell\Latitude 7400\a.inf' '[Version]'
    $folder = Resolve-DriverPack -Identity ([pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 7400'; MachineType = $null; Sku = $null }) -CatalogPath $catalog -DriverRoot (Join-T $src 'Drivers') 6>$null
    Assert-Equal ([IO.Path]::GetFileName($folder)) 'Latitude 7400' 'deploy: a plain folder (network share) still works'

    # Updating a stick that has the old plain pack folder: those files are deleted, the .wim copied.
    if (Test-NativeCopy) {
        $old = Join-Path $base 'oldstick'
        [void](Copy-MediaContent -Plan $plan -Destination $old -Quiet)
        $u = Get-MediaUpdatePlan -Plan $packed -Destination $old
        Assert-Equal (@($u.Stale | Where-Object { $_.Relative -like 'Drivers\Dell\Latitude 5521\*' }).Count) 3 'update: the old plain pack files are deleted'
        Remove-StaleMediaFiles -UpdatePlan $u -Destination $old
        [void](Copy-MediaContent -Plan $u.Copy -Destination $old -Quiet)
        Assert-Equal (Test-Path (Join-T $old 'Drivers\Dell\Latitude 5521')) $false 'update: the empty old pack folder is gone'
        Assert-Equal (Test-Path (Join-T $old 'Drivers\Dell\Latitude 5521.wim')) $true 'update: the .wim is on the stick'
        Assert-Equal (Test-Path (Join-T $old 'Drivers\_WinPE\Dell-WinPE11\rst.inf')) $true 'update: WinPE drivers kept'
    }

    # Real DISM: pack a folder and unpack it again, as the build and the deploy do.
    $isAdmin = $false
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if ($isAdmin) {
        $wim = Join-Path $base 'real.wim'
        New-DriverPackWim -Folder (Join-T $src 'Drivers\Dell\Latitude 5521') -Destination $wim -Name 'Latitude 5521'
        Assert-Equal (Test-Path $wim) $true 'dism: pack made'
        $out = Join-Path $base 'unpacked'
        [void][IO.Directory]::CreateDirectory($out)
        & dism.exe /English /Apply-Image "/ImageFile:$wim" /Index:1 "/ApplyDir:$out" | Out-Null
        Assert-Equal $LASTEXITCODE 0 'dism: pack unpacks'
        Assert-Equal ([IO.File]::ReadAllText((Join-T $out 'net\e1d.inf'))) '[Version] net, newer version' 'dism: files come back as they were'
        Assert-Equal (Test-Path (Join-T $out 'storage\iaStorVD.inf')) $true 'dism: subfolders kept'
    } else { Write-Host 'SKIP dism round trip (needs Windows as administrator)' }
}
finally { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }

Complete-Tests 'All driver pack file checks passed'
