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

    # One staging folder for one DISM run: each picked driver once, with its files, nothing else DISM would add.
    $extra = Join-Path $root 'packs/Extra'
    New-TextFile (Join-Path $extra 'a.inf') 'a'
    New-TextFile (Join-Path $extra 'a.sys') 'a-sys'
    New-TextFile (Join-Path $extra 'sub/b.inf') 'b'
    New-TextFile (Join-Path $extra 'x86/c.inf') 'c32'
    $plan3 = @(Get-WinPEDriverPlan -Sources ($sources + [pscustomobject]@{ Name = 'Extra'; Path = $extra }))
    $stage = Join-Path $root 'stage'
    $staged = @(New-WinPEDriverStaging -Plan $plan3 -Destination $stage)
    Assert-Equal (($staged | ForEach-Object { '{0}:{1}' -f $_.SourceIndex, $_.Name }) -join ',') '0:e1d.inf,0:iaStorVD.inf,1:hpsas.inf,2:a.inf,2:b.inf' 'staging: every picked driver once, by source'
    $infsStaged = @(Get-ChildItem -LiteralPath $stage -Recurse -Filter *.inf -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) -replace '\\', '/' } | Sort-Object)
    Assert-Equal ($infsStaged -join ',') '1/winpe/x64/network/e1d.inf,1/winpe/x64/storage/iaStorVD.inf,2/storage/hpsas.inf,3/a.inf,3/sub/b.inf' 'staging: no duplicate or x86 .inf for DISM to add'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $stage '1/winpe/x64/storage/iaStorVD.sys'))) 'rst-sys' 'staging: a driver keeps its .sys next to the .inf'
    Assert-Equal ([IO.File]::Exists((Join-Path $stage '1/winpe/x86/storage/iaStorVD.sys'))) $false 'staging: Dell x86 folder left out'
    Assert-Equal ([IO.File]::Exists((Join-Path $stage '3/a.sys'))) $true 'staging: files next to a root .inf come along'
    # Driver files out of a vendor cab are often read-only: the next staging still empties the folder.
    $ro = Join-Path $stage '1/winpe/x64/storage/iaStorVD.sys'
    [IO.File]::SetAttributes($ro, [IO.FileAttributes]::ReadOnly)
    $again = @(New-WinPEDriverStaging -Plan $plan3 -Destination $stage)
    Assert-Equal $again.Count 5 'staging: a second run starts from an empty folder'
    Assert-Equal (@(New-WinPEDriverStaging -Plan @() -Destination $stage).Count) 0 'staging: no drivers, nothing staged'

    # The report from the drivers the image lists afterwards, whatever language DISM printed in.
    $report = @(Get-WinPEDriverResults -Plan $plan3 -Staged $staged -InstalledNames @('iastorvd.inf', 'E1D.INF', 'a.inf', 'b.inf'))
    Assert-Equal (($report | ForEach-Object { '{0}={1}/{2}' -f $_.name, $_.added, (@($_.failed) -join '+') }) -join ',') 'Dell=2/,HP=0/hpsas.inf,Extra=2/' 'report: added and failed per source'
    Assert-Equal (@($report[0].vmd) -join ',') 'iaStorVD.inf' 'report: Intel RST/VMD driver found'
    Assert-Equal (@($report[1].vmd).Count) 0 'report: no VMD driver in HP here'
    $twice = @(Get-WinPEDriverResults -Plan $plan3 -Staged @($staged + [pscustomobject]@{ SourceIndex = 1; Name = 'e1d.inf'; Staged = 'x' }) -InstalledNames @('e1d.inf'))
    Assert-Equal "$($twice[0].added)|$($twice[1].added)|$(@($twice[1].failed) -join ',')" '1|0|hpsas.inf,e1d.inf' 'report: one installed copy counts once'
    $byExit = @(Get-WinPEDriverResults -Plan $plan3 -Staged $staged -ExitCode 0)
    Assert-Equal (($byExit | ForEach-Object { $_.added }) -join ',') '2,1,2' 'report: without the image list, exit code 0 means all added'
    $byFail = @(Get-WinPEDriverResults -Plan $plan3 -Staged $staged -ExitCode 2)
    Assert-Equal (($byFail | ForEach-Object { @($_.failed).Count }) -join ',') '2,1,2' 'report: without the image list, a failed run marks them failed'
    Assert-Equal (@(Get-WinPEDriverResults -Plan $plan3 -Staged @()).Count) 3 'report: one entry per source even with no drivers'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# The build uses the cache and copies the packs with the plan.
$build = Get-Content -Raw (Join-Path $repo 'src/New-DeploymentMedia.ps1')
Assert-Equal ($build -match 'Find-WinPEBuildCache -Key \$peKey') $true 'build: looks for a cached WinPE'
Assert-Equal ($build -match '(?s)Save-WinPEBuildCache.*Deploy''') $true 'build: caches boot.wim before the Deploy folder goes in'
Assert-Equal ($build -match 'Get-WinPEPackCopyPlan -PackPath \$pack\.Path') $true 'build: vendor packs go to the stick with the plan'
Assert-Equal ($build -match 'Copy-Item -Path \(Join-Path \$pack\.Path') $false 'build: no whole-pack Copy-Item to the stick'
Assert-Equal ($build -match 'New-WinPEDriverStaging') $true 'build: WinPE drivers staged for one DISM run'
Assert-Equal ($build -match '\$peCacheThis = -not \$NoWinPECache -and -not \(\$infTotal -and \$infAdded -eq 0\)') $true 'build: a DISM run that added nothing is not cached'
Assert-Equal ($build -match '/Add-Driver /Driver:') $true 'build: one DISM /Add-Driver over the staging folder'
Assert-Equal ($build -match 'Add-WindowsDriver') $false 'build: no Add-WindowsDriver call per driver (about 10 s each)'
Assert-Equal ($build -match 'Add-DefenderScanExclusions -Paths @\(\$WorkDir\)') $true 'build: Defender skips the WinPE work folder while DISM runs'

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All WinPE build cache checks passed' -ForegroundColor Green
