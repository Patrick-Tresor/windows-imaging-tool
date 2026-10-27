# Plain-PowerShell tests for the console data layer and driver matching. Run: pwsh -File tests/ConsoleData.Tests.ps1
# Works on Windows and Linux; exits non-zero on the first failing group.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
$common = Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force -PassThru

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-test-" + [guid]::NewGuid())
& $common { param($p) $script:LogPath = $p } (Join-Path $root 'test.log')
try {
    Initialize-ContentRoot -Path $root
    Assert-Equal (Test-ContentRoot $root) $true 'content root is created and recognized'

    # Seed a driver folder and import a second pack from a folder.
    $src = Join-Path $root 'src-pack'
    New-Item -ItemType Directory -Path (Join-Path $src 'net') -Force | Out-Null
    Set-Content (Join-Path $src 'net/e1d.inf') '[Version]'
    $result = Import-DriverPack -ContentRoot $root -Source $src -Maker 'HP' -Model 'ProBook 450 G10' -Sku '8B41'
    Assert-Equal $result.InfCount 1 'import copies the .inf files'
    Assert-Equal $result.Path 'HP\ProBook 450 G10' 'import returns the catalog-relative path'

    $rows = @(Get-DriverCatalogRows -ContentRoot $root)
    $hp = $rows | Where-Object Sku -eq '8B41'
    Assert-Equal $hp.Status '1 drivers' 'catalog row shows the driver count'
    Assert-Equal (($rows | Where-Object Model -eq 'Latitude 5440').Status) 'Missing folder' 'catalog row flags a missing folder'

    # Saving drops empty fields and keeps fallbacks.
    Save-DriverCatalog -ContentRoot $root -Rows ($rows | Where-Object Maker -ne 'Dell')
    $catalog = Get-DriverCatalog -ContentRoot $root
    Assert-Equal (@($catalog.entries | Where-Object maker -eq 'Dell').Count) 0 'removed rows are dropped on save'
    Assert-Equal ($catalog.fallbacks.HP) 'HP\_Generic WinPE-Storage-Net' 'fallbacks survive a save'
    Assert-Equal ($null -eq ($catalog.entries | Where-Object sku -eq '8B41').PSObject.Properties['modelPattern']) $true 'empty match fields are not written'

    $threw = $false
    try { Save-DriverCatalog -ContentRoot $root -Rows @([pscustomobject]@{ Maker = 'Acer'; Path = 'Acer\X' }) } catch { $threw = $true }
    Assert-Equal $threw $true 'an entry with nothing to match on is rejected'

    # The imported pack is what the deploy script would pick for that PC.
    $hw = [pscustomobject]@{ Maker = 'HP'; Model = 'HP ProBook 450 15.6 inch G10'; MachineType = $null; Sku = '8B41' }
    $pack = Resolve-DriverPack -Identity $hw -CatalogPath (Join-Path $root 'config/driver-catalog.json') -DriverRoot (Join-Path $root 'Drivers') 6>$null
    Assert-Equal ([IO.Path]::GetFileName($pack)) 'ProBook 450 G10' 'deploy matches the imported pack by SKU'

    # Disk layout follows the firmware: GPT + EFI for UEFI, MBR + active System for legacy BIOS.
    $gpt = New-DiskpartScript -DiskNumber 1 -Firmware UEFI
    $mbr = New-DiskpartScript -DiskNumber 1 -Firmware BIOS
    Assert-Equal (($gpt -match 'convert gpt') -and ($gpt -match 'create partition efi') -and ($gpt -notmatch 'active')) $true 'UEFI layout is GPT with an EFI partition'
    Assert-Equal (($mbr -match 'convert mbr') -and ($mbr -match '(?m)^active') -and ($mbr -match 'set id=27') -and ($mbr -notmatch 'efi|msr|gpt')) $true 'BIOS layout is MBR with an active system partition'
    foreach ($script in $gpt, $mbr) {
        Assert-Equal (($script -match 'select disk 1') -and ($script -match 'assign letter=S') -and ($script -match 'assign letter=W')) $true 'both layouts select the disk and use S: and W:'
    }

    # Images: split parts count as one image.
    Set-Content (Join-Path $root 'Images/Win11.wim') 'x'
    Set-Content (Join-Path $root 'Images/Big.swm') 'x'
    Set-Content (Join-Path $root 'Images/Big2.swm') 'x'
    $images = @(Get-ImageList -ContentRoot $root)
    Assert-Equal ($images.Name -join ',') 'Big.swm,Win11.wim' 'image list hides extra .swm parts'
    Assert-Equal (($images | Where-Object Name -eq 'Big.swm').Parts) 2 'split image counts its parts'

    # Logs: name parsing.
    Set-Content (Join-Path $root 'Logs/ABC123_20261022-1530_OK.log') 'done'
    $log = Get-DeploymentLogs -ContentRoot $root | Select-Object -First 1
    Assert-Equal "$($log.Serial)|$($log.Status)|$($log.When.ToString('yyyy-MM-dd HH:mm'))" 'ABC123|OK|2026-10-22 15:30' 'log name is parsed'

    # Settings round-trip.
    $s = Get-DeploySettings -ContentRoot $root
    $s.defaultAnswerFile = 'Lab'
    Save-DeploySettings -ContentRoot $root -Settings $s
    Assert-Equal (Get-DeploySettings -ContentRoot $root).defaultAnswerFile 'Lab' 'settings round-trip'
    $s.defaultAnswerFile = 'Default'
    Save-DeploySettings -ContentRoot $root -Settings $s

    # WDS settings: defaults for older settings files, round-trip, and the share settings are kept.
    $s.PSObject.Properties.Remove('wds')
    Save-DeploySettings -ContentRoot $root -Settings $s
    $w = Get-WdsSettings -ContentRoot $root
    Assert-Equal "$($w.server)|$($w.imageName)|$($w.setup)" '|Imaging Tool (x64)|False' 'WDS settings default when the section is missing'
    Save-WdsSettings -ContentRoot $root -Wds ([pscustomobject]@{ server = ' wds01 '; imageName = ''; setup = $true; remoteInstallPath = 'E:\RemoteInstall'; dhcpOnServer = $true; noPrompt = $false })
    $w = Get-WdsSettings -ContentRoot $root
    Assert-Equal "$($w.server)|$($w.imageName)|$($w.setup)|$($w.remoteInstallPath)|$($w.dhcpOnServer)|$($w.noPrompt)" 'wds01|Imaging Tool (x64)|True|E:\RemoteInstall|True|False' 'WDS settings round-trip'
    Assert-Equal (Get-DeploySettings -ContentRoot $root).share.path $s.share.path 'saving WDS settings keeps the share'

    # Multicast settings: defaults, validation, round-trip, and the other sections are kept.
    $m = Get-MulticastSettings -ContentRoot $root
    Assert-Equal "$($m.enabled)|$($m.namespace)|$($m.type)|$($m.speedPolicy)|$($m.fallback)" 'False|ImagingTool|AutoCast|None|True' 'multicast settings default to off'
    $bad = [pscustomobject]@{ enabled = $true; namespace = 'Room 12'; type = 'ScheduledCast'; clients = ''; startTime = '03/11/2026 8h30'; speedPolicy = 'AutoDisconnect'; thresholdKbps = '0' }
    Assert-Equal (@(Get-MulticastIssues -Multicast $bad).Count) 2 'bad start time and threshold are reported'
    $bad.startTime = ''
    Assert-Equal ((@(Get-MulticastIssues -Multicast $bad)) -match 'needs a number of PCs').Count 1 'a scheduled session needs a trigger'
    $threw = $false; try { Save-MulticastSettings -ContentRoot $root -Multicast $bad } catch { $threw = $true }
    Assert-Equal $threw $true 'invalid multicast settings are not saved'
    Save-MulticastSettings -ContentRoot $root -Multicast ([pscustomobject]@{ enabled = $true; server = ' wds01 '; namespace = 'Room 12'; contentPath = 'D:\Deploy'
        type = 'ScheduledCast'; clients = '24'; startTime = '2026-11-03 08:30'; speedPolicy = 'Multistream'; thresholdKbps = ''; fallback = $false })
    $m = Get-MulticastSettings -ContentRoot $root
    Assert-Equal "$($m.enabled)|$($m.server)|$($m.namespace)|$($m.type)|$($m.clients)|$($m.startTime)|$($m.speedPolicy)|$($m.thresholdKbps)|$($m.fallback)" 'True|wds01|Room 12|ScheduledCast|24|2026-11-03 08:30|Multistream|1024|False' 'multicast settings round-trip'
    Assert-Equal (Get-WdsSettings -ContentRoot $root).server 'wds01' 'saving multicast settings keeps the WDS settings'

    # Multicast room monitor: summary line and rows, slowest PC first.
    $mon = [pscustomobject]@{ Server = 'WDS01'; Namespace = 'Room 12'; Exists = $true; Sessions = 1; Clients = @(
        [pscustomobject]@{ Id = 7; Name = 'MININT-A'; IpAddress = '10.0.12.21'; MacAddress = '00-15-5D-01-02-03'; File = 'Images\W11.wim'; Percent = 80; JoinedSeconds = 300; RateBytes = 40MB }
        [pscustomobject]@{ Id = 9; Name = 'MININT-B'; IpAddress = '10.0.12.22'; MacAddress = ''; File = 'Images\W11.wim'; Percent = 20; JoinedSeconds = 3900; RateBytes = 512KB }
        [pscustomobject]@{ Id = 4; Name = 'MININT-C'; IpAddress = '10.0.12.23'; MacAddress = ''; File = 'Images\W11.wim'; Percent = 100; JoinedSeconds = 60; RateBytes = 40MB }) }
    $view = ConvertTo-MulticastView -Monitor $mon
    Assert-Equal $view.Summary '3 PCs receiving, average 67 %, 1 done. Slowest: MININT-B at 20 %.' 'multicast monitor summary'
    Assert-Equal "$($view.Rows[0].Id)|$($view.Rows[0].Address)|$($view.Rows[0].File)|$($view.Rows[0].Joined)|$($view.Rows[0].Speed)" '9|10.0.12.22|W11.wim|1 h 05 min|512 KB/s' 'multicast monitor row, slowest first'
    Assert-Equal "$($view.Rows[1].Address)|$($view.Rows[1].Joined)|$($view.Rows[1].Speed)" '10.0.12.21  00-15-5D-01-02-03|5 min|40.0 MB/s' 'multicast monitor row details'
    $mon.Sessions = 0; $mon.Clients = @()
    Assert-Equal ((ConvertTo-MulticastView -Monitor $mon).Summary -like '*has not started sending yet*') $true 'waiting session summary'
    $mon.Exists = $false
    Assert-Equal (@((ConvertTo-MulticastView -Monitor $mon).Rows).Count) 0 'missing session has no rows'

    # Multicast plan in WinPE: which server, namespace and file, and when to stay unicast.
    $ds = [pscustomobject]@{ share = [pscustomobject]@{ path = '\\files01\Deploy' }; wds = [pscustomobject]@{ server = '' }
        multicast = [pscustomobject]@{ enabled = $true; server = ''; namespace = ''; fallback = $null } }
    $plan = Get-MulticastPlan -Settings $ds -ContentRoot 'Z:\' -ImagePath 'Z:\Images\W11-23H2.wim'
    Assert-Equal "$($plan.Server)|$($plan.Namespace)|$($plan.SourceFile)|$($plan.Fallback)" 'files01|ImagingTool|Images\W11-23H2.wim|True' 'multicast plan defaults to the share server'
    $ds.wds.server = 'wds01'; $ds.multicast.namespace = 'Room 12'; $ds.multicast.fallback = $false
    $plan = Get-MulticastPlan -Settings $ds -ContentRoot 'Z:' -ImagePath 'z:\Images\Sub\W10.wim'
    Assert-Equal "$($plan.Server)|$($plan.Namespace)|$($plan.SourceFile)|$($plan.Fallback)" 'wds01|Room 12|Images\Sub\W10.wim|False' 'multicast plan prefers the WDS server'
    Assert-Equal ($null -eq (Get-MulticastPlan -Settings $ds -ContentRoot 'D:\' -ImagePath 'D:\Images\W11.wim' -IsNetworkRoot $false)) $true 'USB content stays unicast'
    Assert-Equal ($null -eq (Get-MulticastPlan -Settings $ds -ContentRoot 'Z:\' -ImagePath 'Y:\Other\W11.wim')) $true 'images outside the content root stay unicast'
    Assert-Equal ($null -eq (Get-MulticastPlan -Settings $ds -ContentRoot 'Z:\' -ImagePath 'Z:\Images\W11.swm')) $true 'split images stay unicast'
    $ds.multicast.enabled = $false
    Assert-Equal ($null -eq (Get-MulticastPlan -Settings $ds -ContentRoot 'Z:\' -ImagePath 'Z:\Images\W11.wim')) $true 'multicast off stays unicast'

    # Answer files.
    $rows = @(Get-AnswerFileRows -ContentRoot $root)
    Assert-Equal "$($rows.Name)|$($rows.IsDefault)" 'Default|Yes' 'content root is seeded with the default answer file'
    Assert-Equal ($rows[0].Issues -join '') 'Image Images\Win11-Enterprise.wim is not in the content root.' 'missing image is reported'
    $new = New-AnswerFileFromSample -ContentRoot $root -Name 'Lab'
    Assert-Equal (Test-Path $new) $true 'new answer file is created from the sample'
    $threw = $false
    try { New-AnswerFileFromSample -ContentRoot $root -Name 'Lab' | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'answer file names cannot be reused'

    $imp = Import-SmartDeployAnswerFile -ContentRoot $root -Path (Join-Path $PSScriptRoot 'fixtures/smartdeploy-sample.xml')
    Assert-Equal $imp.Name 'smartdeploy-sample' 'SmartDeploy file is imported under its own name'
    Assert-Equal ($imp.Notes.Count -gt 3) $true 'import returns the manual steps'
    $impRow = Get-AnswerFileRows -ContentRoot $root | Where-Object Name -eq 'smartdeploy-sample'
    Assert-Equal (@($impRow.Issues | Where-Object { $_ -like 'Password file*' }).Count) 3 'missing join and share password files are reported'
    Assert-Equal (@($impRow.Issues | Where-Object { $_ -like 'Application*' }).Count) 2 'missing application folders are reported'
    Assert-Equal ((Get-ImageUsage -ContentRoot $root)['Win11-Enterprise.wim'] -join ',') 'Default,Lab' 'image usage lists the answer files using it'

    # Capture wizard data.
    Assert-Equal (Test-Path (Join-Path $root 'Tools/Prepare-Reference.ps1')) $true 'content root gets the prepare script'
    Assert-Equal (Test-ImageName 'Win11_24H2-v1.0') $true 'valid image name accepted'
    Assert-Equal (Test-ImageName 'Win 11') $false 'image name with a space rejected'
    $cfgPath = New-CaptureConfig -ContentRoot $root -Name 'Win11_Ref' -Description 'Base' -SplitForFat32 -Unattended
    $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
    Assert-Equal "$($cfg.name)|$($cfg.splitSizeMB)|$($cfg.noPrompt)|$($cfg.shutdownWhenDone)|$($cfg.compression)" 'Win11_Ref|3800|True|True|max' 'capture config is written'
    $threw = $false
    try { New-CaptureConfig -ContentRoot $root -Name 'Win11' | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'capture refuses a name that already exists'

    $s = Get-DeploySettings -ContentRoot $root
    Assert-Equal (@(Get-CaptureReadiness -ContentRoot $root -Destination Network).Count) 0 'share from defaults is accepted'
    $s.share.path = ''
    Save-DeploySettings -ContentRoot $root -Settings $s
    Assert-Equal (@(Get-CaptureReadiness -ContentRoot $root -Destination Network).Count) 1 'network capture without a share is flagged'
    Assert-Equal (@(Get-CaptureReadiness -ContentRoot $root -Destination Usb).Count) 0 'USB capture does not need a share'
    $s.share.path = 'server\Deploy'
    Save-DeploySettings -ContentRoot $root -Settings $s
    Assert-Equal (@(Get-CaptureReadiness -ContentRoot $root -Destination Network).Count) 1 'non-UNC share is flagged'

    Set-Content (Join-Path $root 'Logs/CAPTURE-Win11_Ref_20261022-1700_FAILED.log') 'x'
    $cap = Get-DeploymentLogs -ContentRoot $root | Where-Object Serial -like 'CAPTURE-*'
    Assert-Equal "$($cap.Serial)|$($cap.Status)" 'CAPTURE-Win11_Ref|FAILED' 'capture log with underscore in the name is parsed'

    # Answer file editor data.
    $inst = Join-Path $root 'zoom-src.msi'
    Set-Content $inst 'msi'
    New-Application -ContentRoot $root -Name 'Zoom' -Source $inst -Command 'msiexec /i zoom-src.msi /qn' | Out-Null
    $appList = @(Get-ApplicationList -ContentRoot $root)
    Assert-Equal "$($appList.Name)|$($appList.Status)|$(Test-Path (Join-Path $root 'Applications/Zoom/zoom-src.msi'))" 'Zoom|Ready|True' 'new application copies the installer and writes app.json'

    $ed = Get-NewAnswer -Name 'Office'
    $ed.Membership = 'Domain'; $ed.Domain = 'corp.example.com'; $ed.JoinUser = 'svc-join'
    $ed.Applications = @('Zoom')
    $ed.Shares = @([pscustomobject]@{ LocalName = 'Y:'; RemoteName = '\\srv\apps'; Username = 'svc'; Domain = 'CORP'; PasswordFile = $null })
    $saved = Save-AnswerFromEditor -ContentRoot $root -Answer $ed -JoinPassword 'J0in!' -SharePasswords @{ 'Y:' = 'Sh4re' } -IsNew
    $back = Read-AnswerFile -Path $saved
    Assert-Equal "$($back.Membership)|$($back.JoinPasswordFile)|$($back.Shares[0].PasswordFile)|$($back.Applications)" 'Domain|config\secrets\Office-join.txt|config\secrets\Office-share-y.txt|Zoom' 'editor save writes the answer file with password file paths'
    Assert-Equal "$(Get-Content -Raw (Join-Path $root 'config/secrets/Office-join.txt'))|$(Get-Content -Raw (Join-Path $root 'config/secrets/Office-share-y.txt'))" 'J0in!|Sh4re' 'typed passwords go to their own files'
    Assert-Equal ((Get-Content -Raw $saved) -match 'J0in!|Sh4re') $false 'passwords are not in the answer file'
    $threw = $false
    try { Save-AnswerFromEditor -ContentRoot $root -Answer $ed -IsNew | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'a new answer file cannot overwrite an existing one'
    $ed.Name = 'Broken'; $ed.Domain = ''
    $msg = try { Save-AnswerFromEditor -ContentRoot $root -Answer $ed -IsNew | Out-Null; '' } catch { $_.Exception.Message }
    Assert-Equal ($msg -like '*needs network/domain*') $true 'editor save reports validation problems'
    $threw = $false
    try { Save-SecretFile -ContentRoot $root -RelativePath '..\outside.txt' -Value 'x' } catch { $threw = $true }
    Assert-Equal $threw $true 'password files must stay inside the content root'

    # Offline image updates.
    Assert-Equal (Test-Path (Join-Path $root 'Updates')) $true 'content root gets an Updates folder'
    $upd = Join-Path $root 'Updates'
    foreach ($n in 'windows11.0-kb5045934-x64-ndp481_abc.msu', 'windows11.0-kb5044284-x64_def.msu', 'windows11.0-kb5043080-x64_aaa.msu', 'custom-fix.cab', 'readme.txt') {
        Set-Content (Join-Path $upd $n) 'x'
    }
    $pk = @(Get-UpdatePackageRows -Path @($upd))
    Assert-Equal ($pk.KB -join ',') 'KB5043080,KB5044284,KB5045934,' 'updates are ordered Windows, .NET, other, oldest KB first'
    Assert-Equal ($pk.Kind -join ',') 'Windows,Windows,.NET,Other' 'update kind is guessed from the catalog file name'
    Assert-Equal (@(Get-UpdatePackageRows -Path @($upd, $pk[0].FullName)).Count) 4 'a file listed twice is added once'

    $wimPath = Join-Path $root 'Images/Win11.wim'
    Assert-Equal (@(Get-ImageServicingHistory -ImagePath $wimPath).Count) 0 'a captured image has no update history'
    $res = @(
        [pscustomobject]@{ index = 1; package = $pk[1].Name; result = 'Installed' }
        [pscustomobject]@{ index = 1; package = $pk[2].Name; result = 'Not applicable' }
    )
    Add-ImageServicingRecord -ImagePath $wimPath -Results $res -Builds '10.0.26100.2033' -Cleanup -Date ([datetime]'2026-10-23 10:00')
    Add-ImageServicingRecord -ImagePath $wimPath -Results @($res[0]) -Builds '10.0.26100.2314' -Date ([datetime]'2026-11-12 09:30')
    $hist = @(Get-ImageServicingHistory -ImagePath $wimPath)
    Assert-Equal "$($hist.Count)|$($hist[0].cleanup)|$($hist[1].builds)" '2|True|10.0.26100.2314' 'update history is appended'
    $imgRow = Get-ImageList -ContentRoot $root | Where-Object Name -eq 'Win11.wim'
    Assert-Equal $imgRow.Updated '2026-11-12 09:30 (KB5044284)' 'image list shows the last update and its installed KBs'
    Assert-Equal (@(Get-ImageList -ContentRoot $root).Name -contains 'Win11.updates.json') $false 'history file is not listed as an image'

    $ua = Get-ImageUpdateArguments -ScriptPath 'C:\Imaging Tool\src\Update-OfflineImage.ps1' -ImagePath "\\srv\Deploy\Images\O'Brien.wim" `
        -Packages @('D:\Up dates\a.msu', 'D:\b.msu') -Cleanup -NoBackup
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ua[-1]))
    Assert-Equal $decoded "& 'C:\Imaging Tool\src\Update-OfflineImage.ps1' -ImagePath '\\srv\Deploy\Images\O''Brien.wim' -PackagePath 'D:\Up dates\a.msu','D:\b.msu' -Cleanup -NoBackup -NoPrompt" 'update command quotes paths and lists packages in order'
    $parsed = [System.Management.Automation.Language.Parser]::ParseInput($decoded, [ref]$null, [ref]$null)
    $cmdAst = $parsed.EndBlock.Statements[0].PipelineElements[0]
    Assert-Equal ($cmdAst.CommandElements[4].Elements.Count) 2 'update command passes the packages as one array'
    $threw = $false
    try { Get-ImageUpdateArguments -ScriptPath 'x.ps1' -ImagePath 'y.wim' -Packages @('a.msu') -ResetBase | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'reset base without cleanup is rejected'

    Set-Content (Join-Path $root 'Logs/SERVICE-Win11_20261023-1000_OK.log') 'x'
    Assert-Equal ((Get-DeploymentLogs -ContentRoot $root | Where-Object Serial -like 'SERVICE-*').Status) 'OK' 'update log is parsed'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
