# Plain-PowerShell tests for the WinPE build cache (boot.wim with its components and drivers reused between
# builds) and the vendor WinPE packs' copy to the stick. Run: pwsh -File tests/WinPEBuildCache.Tests.ps1. No network.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force
Import-Module (Join-Path $repo 'src/MediaCopy.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function New-TextFile([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("winpecache-test-" + [guid]::NewGuid())
try {
    # Two vendor packs: Dell's with x64 and x86 folders, HP's flat, both with the same Intel NIC driver.
    $dell = Join-Path $root 'packs/Dell-WinPE11-A11'
    $hp = Join-Path $root 'packs/HP-WinPE-sp1'
    New-TextFile (Join-Path $dell 'winpe/x64/storage/iaStorVD.inf') 'rst'
    New-TextFile (Join-Path $dell 'winpe/x64/storage/iaStorVD.sys') 'rst-sys'
    New-TextFile (Join-Path $dell 'winpe/x64/network/e1d.inf') 'nic'
    New-TextFile (Join-Path $dell 'winpe/x86/storage/iaStorVD.inf') 'rst32'
    New-TextFile (Join-Path $dell 'winpe/x86/storage/iaStorVD.sys') 'rst32-sys'
    New-TextFile (Join-Path $dell 'pack.json') '{}'
    New-TextFile (Join-Path $hp 'nic/e1d.inf') 'nic'
    New-TextFile (Join-Path $hp 'storage/hpsas.inf') 'sas'
    $sources = @([pscustomobject]@{ Name = 'Dell'; Path = $dell }, [pscustomobject]@{ Name = 'HP'; Path = $hp })
    $wim = Join-Path $root 'boot.wim'
    New-TextFile $wim 'base wim'
    $components = 'WinPE-WMI', 'WinPE-PowerShell'

    # The driver plan: x64 only, the same driver in a second pack marked as a duplicate.
    $plan = @(Get-WinPEDriverPlan -Sources $sources)
    Assert-Equal $plan.Count 2 'plan: one entry per source'
    Assert-Equal (($plan[0].Infs | ForEach-Object { $_.File.Name }) -join ',') 'e1d.inf,iaStorVD.inf' 'plan: Dell x64 drivers only'
    Assert-Equal (($plan[0].Infs | Where-Object Duplicate).Count) 0 'plan: nothing in the first pack is a duplicate'
    Assert-Equal (($plan[1].Infs | Where-Object Duplicate | ForEach-Object { $_.File.Name }) -join ',') 'e1d.inf' 'plan: the NIC in both packs goes in once'
    Assert-Equal (@(Get-WinPEDriverPlan -Sources @()).Count) 0 'plan: no sources, no drivers'

    # The key: the same inputs give the same key; any change gives another.
    $key = Get-WinPEBuildKey -BaseWim $wim -Components $components -DriverPlan $plan
    Assert-Equal ($key -match '^[0-9a-f]{16}$') $true 'key: 16 hex characters'
    Assert-Equal (Get-WinPEBuildKey -BaseWim $wim -Components $components -DriverPlan (Get-WinPEDriverPlan -Sources $sources)) $key 'key: same inputs, same key'
    Assert-Equal ((Get-WinPEBuildKey -BaseWim $wim -Components 'WinPE-WMI' -DriverPlan $plan) -ne $key) $true 'key: another component list changes it'
    Assert-Equal ((Get-WinPEBuildKey -BaseWim $wim -Components $components -DriverPlan @($plan[0])) -ne $key) $true 'key: a pack left out changes it'
    New-TextFile (Join-Path $hp 'storage/hpsas.inf') 'sas v2'
    Assert-Equal ((Get-WinPEBuildKey -BaseWim $wim -Components $components -DriverPlan (Get-WinPEDriverPlan -Sources $sources)) -ne $key) $true 'key: a changed .inf changes it'
    New-TextFile (Join-Path $hp 'storage/hpsas.inf') 'sas'
    [IO.File]::SetLastWriteTimeUtc($wim, [DateTime]::UtcNow.AddDays(-3))
    Assert-Equal ((Get-WinPEBuildKey -BaseWim $wim -Components $components -DriverPlan $plan) -ne $key) $true 'key: another ADK boot.wim changes it'
    $key = Get-WinPEBuildKey -BaseWim $wim -Components $components -DriverPlan $plan

    # The cache: nothing at first, then the saved boot.wim and report; only the newest two builds are kept.
    $cache = Join-Path $root 'cache'
    Assert-Equal (Find-WinPEBuildCache -Key $key -CacheDir $cache) $null 'cache: empty at first'
    $report = @([ordered]@{ name = 'Dell'; added = 2; failed = @(); vmd = @('iaStorVD.inf') }, [ordered]@{ name = 'HP'; added = 1; failed = @('hpsas.inf'); vmd = @() })
    $dir = Save-WinPEBuildCache -Key $key -WimPath $wim -Sources $report -CacheDir $cache
    $hit = Find-WinPEBuildCache -Key $key -CacheDir $cache
    Assert-Equal ($null -ne $hit) $true 'cache: found after saving'
    Assert-Equal ([IO.File]::ReadAllText($hit.Wim)) 'base wim' 'cache: boot.wim copied'
    Assert-Equal $hit.Sources.Count 2 'cache: the driver report comes back'
    Assert-Equal (@($hit.Sources | ForEach-Object { $_.vmd } | Where-Object { $_ }) -join ',') 'iaStorVD.inf' 'cache: the VMD driver is in the report'
    Assert-Equal ($hit.Built -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$') $true 'cache: build date kept'
    Assert-Equal (Find-WinPEBuildCache -Key 'other' -CacheDir $cache) $null 'cache: another key is a miss'
    New-Item -ItemType Directory -Path (Join-Path $cache 'halfdone') -Force | Out-Null
    Start-Sleep -Milliseconds 50
    $null = Save-WinPEBuildCache -Key 'second' -WimPath $wim -Sources $report -CacheDir $cache
    Start-Sleep -Milliseconds 50
    $null = Save-WinPEBuildCache -Key 'third' -WimPath $wim -Sources $report -CacheDir $cache
    Assert-Equal ((Get-ChildItem -LiteralPath $cache -Directory | ForEach-Object Name | Sort-Object) -join ',') 'second,third' 'cache: the newest two builds are kept'
    $null = Save-WinPEBuildCache -Key 'third' -WimPath $wim -Sources @() -CacheDir $cache
    Assert-Equal (Find-WinPEBuildCache -Key 'third' -CacheDir $cache).Sources.Count 0 'cache: saving the same key again replaces it'
    New-Item -ItemType Directory -Path (Join-Path $cache 'nojson') -Force | Out-Null
    New-TextFile (Join-Path $cache 'nojson/boot.wim') 'x'
    Assert-Equal (Find-WinPEBuildCache -Key 'nojson' -CacheDir $cache) $null 'cache: a build stopped halfway is not reused'

    # The pack on the stick: x86 left out, under Drivers\_WinPE\<pack>, and an update copies nothing new.
    $copy = Get-WinPEPackCopyPlan -PackPath $dell
    $rels = @($copy.Items | ForEach-Object Relative)
    Assert-Equal $copy.FileCount 4 'stick: x64 files and pack.json only'
    Assert-Equal (@($rels | Where-Object { $_ -match 'x86' }).Count) 0 'stick: no x86 files'
    Assert-Equal ($rels -contains 'Drivers\_WinPE\Dell-WinPE11-A11\winpe\x64\storage\iaStorVD.sys') $true 'stick: path under Drivers\_WinPE'
    Assert-Equal (@($copy.Directories | Where-Object { $_ -match 'x86' }).Count) 0 'stick: no x86 folders'
    Assert-Equal $copy.TotalBytes (($copy.Items | Measure-Object Length -Sum).Sum) 'stick: total is the files'' size'
    $stick = Join-Path $root 'stick'
    New-Item -ItemType Directory -Path $stick -Force | Out-Null
    $first = (Get-MediaUpdatePlan -Plan $copy -Destination $stick).Copy
    Assert-Equal $first.FileCount 4 'stick: a new stick gets every file'
    $null = Copy-MediaContent -Plan $first -Destination $stick -Quiet
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $stick 'Drivers/_WinPE/Dell-WinPE11-A11/winpe/x64/storage/iaStorVD.inf'))) 'rst' 'stick: driver copied'
    Assert-Equal (Get-MediaUpdatePlan -Plan (Get-WinPEPackCopyPlan -PackPath $dell) -Destination $stick).Copy.FileCount 0 'stick: an update copies nothing unchanged'
    $drvload = @(Get-WinPEDriverInfs -Folder (Join-Path $stick 'Drivers/_WinPE') | ForEach-Object Name)
    Assert-Equal ($drvload -join ',') 'e1d.inf,iaStorVD.inf' 'stick: WinPE finds the x64 drivers to load'
    $flat = Get-WinPEPackCopyPlan -PackPath $hp
    Assert-Equal $flat.FileCount 2 'stick: a pack without architecture folders is copied whole'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# The build uses the cache and copies the packs with the plan.
$build = Get-Content -Raw (Join-Path $repo 'src/New-DeploymentMedia.ps1')
Assert-Equal ($build -match 'Find-WinPEBuildCache -Key \$peKey') $true 'build: looks for a cached WinPE'
Assert-Equal ($build -match '(?s)Save-WinPEBuildCache.*Deploy''') $true 'build: caches boot.wim before the Deploy folder goes in'
Assert-Equal ($build -match 'Get-WinPEPackCopyPlan -PackPath \$pack\.Path') $true 'build: vendor packs go to the stick with the plan'
Assert-Equal ($build -match 'Copy-Item -Path \(Join-Path \$pack\.Path') $false 'build: no whole-pack Copy-Item to the stick'

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All WinPE build cache checks passed' -ForegroundColor Green
