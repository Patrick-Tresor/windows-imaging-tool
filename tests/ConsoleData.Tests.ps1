# Plain-PowerShell tests for the console data layer and driver matching. Run: pwsh -File tests/ConsoleData.Tests.ps1
# Works on Windows and Linux; exits non-zero on the first failing group.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/SecretVault.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
$common = Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force -PassThru

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-test-" + [guid]::NewGuid())
Set-DeployLogPath -Path (Join-Path $root 'test.log')
try {
    Initialize-ContentRoot -Path $root
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/driver-catalog-sample.json') (Join-Path $root 'config/driver-catalog.json') -Force   # the old example rows
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

    # The import reads the maker from the model or the pack's name.
    Assert-Equal (Get-DriverPackMaker -Model 'Latitude 5521') 'Dell' 'maker: Dell product line'
    Assert-Equal (Get-DriverPackMaker -Model 'EliteBook 840 G8') 'HP' 'maker: HP product line'
    Assert-Equal (Get-DriverPackMaker -Model 'ThinkPad T14 Gen 4') 'Lenovo' 'maker: Lenovo product line'
    Assert-Equal (Get-DriverPackMaker -Model 'HP 250 G9') 'HP' 'maker: maker word in the model'
    Assert-Equal (Get-DriverPackMaker -Model '5521' -Source 'C:\Packs\Latitude-5521-WIN11-A05-XXXX.CAB') 'Dell' 'maker: from the file name'
    Assert-Equal (Get-DriverPackMaker -Model 'Model 1' -Source 'C:\Packs\sp173204.exe') 'HP' 'maker: HP SoftPaq file'
    Assert-Equal (Get-DriverPackMaker -Model 'Model 1' -Source 'C:\Packs\tp_t14_gen4_w11_202310.exe') 'Lenovo' 'maker: Lenovo pack file'
    Assert-Equal (Get-DriverPackMaker -Model 'Model 1' -Source 'C:\Packs\drivers') '' 'maker: unknown stays empty'

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

    # Disk layout: GPT with an EFI partition (UEFI only).
    $gpt = New-DiskpartScript -DiskNumber 1
    Assert-Equal (($gpt -match 'convert gpt') -and ($gpt -match 'create partition efi') -and ($gpt -notmatch 'active')) $true 'UEFI layout is GPT with an EFI partition'
    Assert-Equal (($gpt -match 'select disk 1') -and ($gpt -match 'assign letter=S') -and ($gpt -match 'assign letter=W')) $true 'the layout selects the disk and uses S: and W:'

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

    # Settings round-trip. There is no default answer file: an older setup's entry is dropped on save.
    $s = Get-DeploySettings -ContentRoot $root
    $s.share.path = '\\server\Deploy'
    $s | Add-Member -NotePropertyName defaultAnswerFile -NotePropertyValue 'Lab' -Force
    Save-DeploySettings -ContentRoot $root -Settings $s
    $back = Get-DeploySettings -ContentRoot $root
    Assert-Equal "$($back.share.path)|$([bool]$back.PSObject.Properties['defaultAnswerFile'])" '\\server\Deploy|False' 'settings round-trip, old defaultAnswerFile dropped'


    # Answer files.
    $rows = @(Get-AnswerFileRows -ContentRoot $root)
    Assert-Equal "$($rows.Name)" 'Default' 'content root is seeded with the Default answer file'
    Assert-Equal ($rows[0].Issues -join '') 'Image Images\Win11-Enterprise.wim is not in the content root.' 'missing image is reported'
    Copy-Item (Get-AnswerFilePath -ContentRoot $root -Name 'Default') (Get-AnswerFilePath -ContentRoot $root -Name 'Lab')

    Assert-Equal ((Get-ImageUsage -ContentRoot $root)['Win11-Enterprise.wim'] -join ',') 'Default,Lab' 'image usage lists the answer files using it'

    # Capture wizard data.
    Assert-Equal (Test-Path (Join-Path $root 'Tools/Prepare-Reference.ps1')) $true 'content root gets the prepare script'
    Assert-Equal (Test-ImageName 'Win11_24H2-v1.0') $true 'valid image name accepted'
    Assert-Equal (Test-ImageName 'Win 11') $false 'image name with a space rejected'

    Set-Content (Join-Path $root 'Logs/CAPTURE-Win11_Ref_20261022-1700_FAILED.log') 'x'
    $cap = Get-DeploymentLogs -ContentRoot $root | Where-Object Serial -like 'CAPTURE-*'
    Assert-Equal "$($cap.Serial)|$($cap.Status)" 'CAPTURE-Win11_Ref|FAILED' 'capture log with underscore in the name is parsed'

    # Answer file editor data.
    $inst = Join-Path $root 'zoom-src.msi'
    Set-Content $inst 'msi'
    New-Application -ContentRoot $root -Name 'Zoom' -Source $inst -Command 'msiexec /i zoom-src.msi /qn' | Out-Null
    $appList = @(Get-ApplicationList -ContentRoot $root)
    Assert-Equal "$($appList.Name)|$($appList.Status)|$(Test-Path (Join-Path $root 'Applications/Zoom/zoom-src.msi'))" 'Zoom|Ready (no detection)|True' 'new application copies the installer and writes app.json'

    $ed = Get-NewAnswer -Name 'Office'
    $ed.Membership = 'Domain'; $ed.Domain = 'corp.example.com'; $ed.JoinUser = 'svc-join'
    $ed.Applications = @('Zoom')
    $ed.Shares = @([pscustomobject]@{ LocalName = 'Y:'; RemoteName = '\\srv\apps'; Username = 'svc'; Domain = 'CORP'; PasswordFile = $null })
    $saved = Save-AnswerFromEditor -ContentRoot $root -Answer $ed -JoinPassword 'J0in!' -SharePasswords @{ 'Y:' = 'Sh4re' } -IsNew
    $back = Read-AnswerFile -Path $saved
    Assert-Equal "$($back.Membership)|$($back.JoinPasswordFile)|$($back.Shares[0].PasswordFile)|$($back.Applications)" 'Domain|config\secrets\Office-join.txt|config\secrets\Office-share-y.txt|Zoom' 'editor save writes the answer file with password file paths'
    $key = Get-AnswerKey -ContentRoot $root
    Assert-Equal "$(Unprotect-AnswerPassword -Value $back.JoinPasswordEncrypted -Key $key)|$(Unprotect-AnswerPassword -Value $back.Shares[0].PasswordEncrypted -Key $key)" 'J0in!|Sh4re' 'typed passwords are saved encrypted in the answer file'
    Assert-Equal "$(Test-Path (Join-Path $root 'config/secrets/Office-join.txt'))|$(Test-Path (Join-Path $root 'config/secrets/Office-share-y.txt'))" 'False|False' 'and not in password files'
    Assert-Equal ((Get-Content -Raw $saved) -match 'J0in!|Sh4re') $false 'the answer file holds no password in plain text'
    Assert-Equal (@(Get-AnswerFileIssues -ContentRoot $root -Answer $back | Where-Object { $_ -like '*password*' }).Count) 0 'encrypted passwords count as saved'
    $kept = Save-AnswerFromEditor -ContentRoot $root -Answer $back
    Assert-Equal "$((Read-AnswerFile -Path $kept).JoinPasswordEncrypted)" "$($back.JoinPasswordEncrypted)" 'saving again without typing keeps the encrypted password'
    Assert-Equal (Test-SavedPassword -ContentRoot $root -RelativePath $back.JoinPasswordFile -Encrypted $back.JoinPasswordEncrypted) $true 'the editor shows the password as saved'
    $threw = $false
    try { Save-AnswerFromEditor -ContentRoot $root -Answer $ed -IsNew | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'a new answer file cannot overwrite an existing one'
    $ed.Name = 'Broken'; $ed.Domain = ''
    $msg = try { Save-AnswerFromEditor -ContentRoot $root -Answer $ed -IsNew | Out-Null; '' } catch { $_.Exception.Message }
    Assert-Equal ($msg -like '*needs network/domain*') $true 'editor save reports validation problems'
    $ed.Name = 'NoUser'; $ed.Domain = 'corp.example.com'; $ed.JoinUser = ''; $ed.JoinPasswordFile = $null
    $msg = try { Save-AnswerFromEditor -ContentRoot $root -Answer $ed -JoinPassword 'J0in!' -IsNew | Out-Null; '' } catch { $_.Exception.Message }
    Assert-Equal ($msg -like '*join account user name*' -and $msg -notlike '*passwordFile*') $true 'a missing join user is reported on its own; the password file is named by the save'
    $ed.JoinUser = 'svc-join'; $ed.JoinPasswordFile = 'config\secrets\Office-join.txt'

    # Domain join fields the editor points at before saving.
    $j = Get-NewAnswer -Name 'Join'
    Assert-Equal (Get-DomainJoinProblem -Answer $j) $null 'a workgroup answer needs no join account'
    $j.Membership = 'Domain'; $j.Domain = ''; $j.JoinUser = ''
    Assert-Equal (Get-DomainJoinProblem -Answer $j).Control 'TxtDomain' 'missing domain points at the Domain box'
    $j.Domain = 'corp.example.com'
    Assert-Equal (Get-DomainJoinProblem -Answer $j -PasswordTyped $true).Control 'TxtJoinUser' 'missing join user points at the user name box'
    $j.JoinUser = 'svc-join'
    Assert-Equal (Get-DomainJoinProblem -Answer $j).Control 'PwdJoin' 'no typed or saved password points at the password box'
    Assert-Equal (Get-DomainJoinProblem -Answer $j -PasswordSaved $true) $null 'a saved password is enough'
    Assert-Equal (Get-DomainJoinProblem -Answer $j -PasswordTyped $true) $null 'a typed password is enough'
    $s = Split-JoinAccount -User ' CORP\svc-join ' -Domain ''
    Assert-Equal "$($s.User)|$($s.Domain)" 'svc-join|CORP' 'DOMAIN\user fills in the account domain'
    $s = Split-JoinAccount -User 'svc-join@corp.example.com' -Domain ''
    Assert-Equal "$($s.User)|$($s.Domain)" 'svc-join@corp.example.com|' 'a UPN is kept as typed'
    $s = Split-JoinAccount -User 'CORP\svc' -Domain 'svc'
    Assert-Equal "$($s.User)|$($s.Domain)" 'svc|CORP' 'DOMAIN\user wins over a different account domain (kept both, Windows signed in as svc\CORP\svc)'
    $s = Split-JoinAccount -User 'svc-join@corp.example.com' -Domain 'CORP'
    Assert-Equal "$($s.User)|$($s.Domain)" 'svc-join@corp.example.com|' 'a UPN needs no account domain'
    $j.JoinUser = 'CORP\svc\x'
    Assert-Equal (Get-DomainJoinProblem -Answer $j -PasswordSaved $true).Control 'TxtJoinUser' 'a user name with two backslashes points at the user name box'
    $j.JoinUser = 'svc-join'; $j.JoinDomain = 'svc\CORP'
    Assert-Equal (Get-DomainJoinProblem -Answer $j -PasswordSaved $true).Control 'TxtJoinDomain' 'an account domain with a backslash points at the account domain box'
    $j.JoinDomain = 'CORP'
    $ed.Name = 'Secure'; $ed.Domain = 'corp.example.com'
    $ed.BitLocker.Enabled = $true; $ed.BitLocker.Protector = 'TpmPin'; $ed.BitLocker.PinFile = $null
    $msg = try { Save-AnswerFromEditor -ContentRoot $root -Answer $ed -BitLockerPin '12ab' -IsNew | Out-Null; '' } catch { $_.Exception.Message }
    Assert-Equal $msg 'The BitLocker startup PIN must be 6 to 20 digits.' 'editor save rejects a PIN that is not digits'
    $saved = Save-AnswerFromEditor -ContentRoot $root -Answer $ed -BitLockerPin '246810' -IsNew
    $back = Read-AnswerFile -Path $saved
    Assert-Equal "$($back.BitLocker.PinFile)" 'config\secrets\Secure-bitlocker-pin.txt' 'editor save names the PIN file'
    Assert-Equal (Unprotect-AnswerPassword -Value $back.BitLocker.PinEncrypted -Key (Get-AnswerKey -ContentRoot $root)) '246810' 'the PIN is saved encrypted in the answer file'
    Assert-Equal ((Get-Content -Raw $saved) -match '246810') $false 'the PIN is not in the answer file in plain text'

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
    Set-Content (Join-Path $upd 'ssu-19041.3570-x64.cab') 'x'
    Assert-Equal ((@(Get-UpdatePackageRows -Path @($upd))[0]).Kind) 'SSU' 'a standalone servicing stack update goes first'
    Remove-Item (Join-Path $upd 'ssu-19041.3570-x64.cab')

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
        -Packages @('D:\Up dates\a.msu', 'D:\b.msu') -Cleanup
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ua[-1]))
    Assert-Equal $decoded "& 'C:\Imaging Tool\src\Update-OfflineImage.ps1' -ImagePath '\\srv\Deploy\Images\O''Brien.wim' -PackagePath 'D:\Up dates\a.msu','D:\b.msu' -Cleanup -NoPrompt" 'update command quotes paths and lists packages in order'
    $parsed = [System.Management.Automation.Language.Parser]::ParseInput($decoded, [ref]$null, [ref]$null)
    $cmdAst = $parsed.EndBlock.Statements[0].PipelineElements[0]
    Assert-Equal ($cmdAst.CommandElements[4].Elements.Count) 2 'update command passes the packages as one array'
    $ua = Get-ImageUpdateArguments -ScriptPath 'x.ps1' -ImagePath 'y.wim' -Packages @() -LatestUpdate
    Assert-Equal ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ua[-1]))) "& 'x.ps1' -ImagePath 'y.wim' -LatestUpdate -NoPrompt" 'latest update alone: no package list'
    Assert-Throws { Get-ImageUpdateArguments -ScriptPath 'x.ps1' -ImagePath 'y.wim' -Packages @() } '*latest cumulative update*' 'nothing to apply is rejected'
    $threw = $false
    try { Get-ImageUpdateArguments -ScriptPath 'x.ps1' -ImagePath 'y.wim' -Packages @('a.msu') -ResetBase | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'reset base without cleanup is rejected'

    $vc = Get-VMCaptureArguments -ScriptPath 'C:\Imaging Tool\src\Capture-VMImage.ps1' -ContentRoot 'D:\Deploy Share' -DiskPath "D:\VMs\Win11's Ref\Ref.vmdk" `
        -Name 'Win11-24H2' -Description 'Lab build'
    $vcDecoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($vc[-1]))
    Assert-Equal $vcDecoded "& 'C:\Imaging Tool\src\Capture-VMImage.ps1' -DiskPath 'D:\VMs\Win11''s Ref\Ref.vmdk' -Name 'Win11-24H2' -ContentRoot 'D:\Deploy Share' -Compression max -Description 'Lab build' -NoPrompt" 'VM capture command quotes the disk path and adds the options'
    $threw = $false
    try { Get-VMCaptureArguments -ScriptPath 'x.ps1' -ContentRoot 'y' -DiskPath 'v.vmdk' -Name 'bad name' | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true 'VM capture rejects an image name with spaces'
    $vcp = Get-VMCaptureArguments -ScriptPath 'x.ps1' -ContentRoot 'D:\Share' -DiskPath 'D:\VMs\a.vmdk' -Name 'W11' `
        -ReuseConvertedDisk 'C:\Temp\capture-check-1.vhd' -ProgressFile 'C:\Temp\p.json' -LogPath 'C:\Logs\c.log'
    Assert-Equal ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($vcp[-1]))) "& 'x.ps1' -DiskPath 'D:\VMs\a.vmdk' -Name 'W11' -ContentRoot 'D:\Share' -Compression max -ReuseConvertedDisk 'C:\Temp\capture-check-1.vhd' -ProgressFile 'C:\Temp\p.json' -LogPath 'C:\Logs\c.log' -NoPrompt" 'VM capture command passes the checked copy, progress file and log'

    $vcs = Get-VMCaptureArguments -ScriptPath 'x.ps1' -ContentRoot 'D:\Share' -DiskPath 'D:\VMs\a.vmdk' -Name 'W11' -SysprepAtDeploy
    Assert-Equal ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($vcs[-1]))) "& 'x.ps1' -DiskPath 'D:\VMs\a.vmdk' -Name 'W11' -ContentRoot 'D:\Share' -Compression max -SysprepAtDeploy -NoPrompt" 'VM capture command passes sysprep on each PC'
    $vci = Get-VMCaptureArguments -ScriptPath 'x.ps1' -ContentRoot 'D:\Share' -DiskPath 'D:\VMs\a.vmdk' -Name 'W11' -ImagesDir '\\SERVER\Deploy\Images'
    Assert-Equal ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($vci[-1]))) "& 'x.ps1' -DiskPath 'D:\VMs\a.vmdk' -Name 'W11' -ContentRoot 'D:\Share' -Compression max -ImagesDir '\\SERVER\Deploy\Images' -NoPrompt" 'VM capture command passes the chosen Save to folder'
    Assert-Equal ([bool](Get-CaptureSaveFolderProblem -Path '')) $true 'Save to: an empty folder is refused'
    Assert-Equal ([bool](Get-CaptureSaveFolderProblem -Path 'Images')) $true 'Save to: a relative folder is refused'
    Assert-Equal ([bool](Get-CaptureSaveFolderProblem -Path '\\SERVER')) $true 'Save to: a server name without a share is refused'
    $saveRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'savetest-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($saveRoot)
    if ($saveRoot -match '^[A-Za-z]:\\') {
        Assert-Equal (Get-CaptureSaveFolderProblem -Path $saveRoot) $null 'Save to: an existing folder is accepted'
        Assert-Equal (Get-CaptureSaveFolderProblem -Path ([IO.Path]::Combine($saveRoot, 'Images'))) $null 'Save to: a new folder in an existing one is accepted'
        Assert-Equal ([bool](Get-CaptureSaveFolderProblem -Path ([IO.Path]::Combine($saveRoot, 'a', 'b')))) $true 'Save to: a folder whose parent is missing is refused'
    }
    [IO.Directory]::Delete($saveRoot, $true)

    $vhdxConv = Get-DiskConversionCommand -SourcePath 'D:\VMs\a.vhdx' -DestinationPath 'T\b.vhd' -QemuImg 'C:\qemu\qemu-img.exe'
    Assert-Equal $vhdxConv $null 'a VHDX needs no conversion'
    $qcowConv = Get-DiskConversionCommand -SourcePath 'D:\VMs\a.qcow2' -DestinationPath 'T\b.vhd' -QemuImg 'C:\qemu\qemu-img.exe' -VBoxManage 'C:\VBox\VBoxManage.exe'
    Assert-Equal ($qcowConv.ArgumentList -join ' ') 'convert -p -O vpc D:\VMs\a.qcow2 T\b.vhd' 'qcow2 converts with qemu-img when it is installed'
    $vmdkConv = Get-DiskConversionCommand -SourcePath 'D:\VMs\a.vmdk' -DestinationPath 'T\b.vhd' -VBoxManage 'C:\VBox\VBoxManage.exe'
    Assert-Equal ($vmdkConv.ArgumentList -join ' ') 'clonemedium disk D:\VMs\a.vmdk T\b.vhd --format VHD' 'VMDK converts with VirtualBox when qemu-img is missing'
    $threwConv = $false
    try { Get-DiskConversionCommand -SourcePath 'D:\VMs\a.qcow2' -DestinationPath 'T\b.vhd' -VBoxManage 'C:\VBox\VBoxManage.exe' | Out-Null } catch { $threwConv = $true }
    Assert-Equal $threwConv $true 'qcow2 without qemu-img is rejected'

    Set-Content (Join-Path $root 'Logs/SERVICE-Win11_20261023-1000_OK.log') 'x'
    Assert-Equal ((Get-DeploymentLogs -ContentRoot $root | Where-Object Serial -like 'SERVICE-*').Status) 'OK' 'update log is parsed'

    # Deleting an answer file (Answer Files tab, Delete): asks first, then the file is gone.
    Set-Content (Join-Path $root 'AnswerFiles/ToDelete.xml') '<x/>'
    $chk = Get-AnswerFileDeleteCheck -ContentRoot $root -Name 'ToDelete'
    Assert-Equal ($chk.Text -like '*Delete the answer file ToDelete*') $true 'delete check: the question names it'
    [void](Remove-AnswerFile -ContentRoot $root -Name 'ToDelete')
    Assert-Equal (Test-Path (Join-Path $root 'AnswerFiles/ToDelete.xml')) $false 'delete: the file is gone'
    Assert-Throws { Get-AnswerFileDeleteCheck -ContentRoot $root -Name 'ToDelete' } '*no answer file named ToDelete*' 'delete: a missing answer file is refused'

    # Dashboard History: deployments no longer on the Dashboard, never captures or image updates.
    $tab = @(Get-DeploymentHistoryRows -ContentRoot $root -DashboardLogFiles @('abc123_20261022-1530_OK.log'))
    Assert-Equal $tab.Count 0 'History hides a deployment that is still on the Dashboard, and has no capture or update logs'
    $tab = @(Get-DeploymentHistoryRows -ContentRoot $root)
    Assert-Equal "$($tab.Serial)|$($tab.State)|$($tab.IsHistory)" 'ABC123|Succeeded|True' 'History lists a deployment cleared from the Dashboard as a Dashboard row'

    # Images tab, Open log: the newest capture or update log of that image only.
    Set-Content (Join-Path $root 'Logs/CAPTURE-VM-Win11_20261024-0900_OK.log') 'x'
    Set-Content (Join-Path $root 'Logs/CAPTURE-VM-Win11_Ref_20261025-0900_OK.log') 'x'
    Assert-Equal ([IO.Path]::GetFileName((Get-ImageLogPath -ContentRoot $root -ImageName 'Win11'))) 'CAPTURE-VM-Win11_20261024-0900_OK.log' 'image log: newest of its capture and update logs'
    Assert-Equal ($null -eq (Get-ImageLogPath -ContentRoot $root -ImageName 'Other')) $true 'image log: none for an image never captured here'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# The example driver rows (Patrick, 2026-11-11: "remove all the demo driver"): a new content root has none, and
# an old one loses them unless a pack was put in their folder.
$root = Join-Path ([IO.Path]::GetTempPath()) ("sample-drivers-" + [guid]::NewGuid())
try {
    Initialize-ContentRoot -Path $root
    Assert-Equal ((Get-DriverCatalog -ContentRoot $root).entries.model -join ',') 'Virtual Machine' 'new content root: no example driver rows'
    Assert-Equal (Remove-SampleDriverEntries -ContentRoot $root) 0 'new content root: nothing to remove'
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/driver-catalog-sample.json') (Join-Path $root 'config/driver-catalog.json') -Force
    $cat = Get-DriverCatalog -ContentRoot $root
    $cat.entries = @($cat.entries) + @([pscustomobject]@{ maker = 'Dell'; model = 'Latitude 5521'; path = 'Dell\Latitude 5521' })
    $cat | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'config/driver-catalog.json')
    New-Item -ItemType Directory -Path (Join-Path $root 'Drivers/HP/EliteBook 840 G9') -Force | Out-Null
    Set-Content (Join-Path $root 'Drivers/HP/EliteBook 840 G9/a.inf') '[Version]'
    Assert-Equal (Remove-SampleDriverEntries -ContentRoot $root) 5 'old content root: the empty example rows are removed'
    $left = @((Get-DriverCatalog -ContentRoot $root).entries | ForEach-Object { "$($_.maker) $($_.model)$($_.sku)" })
    Assert-Equal ($left -join ',') 'HP 8A86,HP HP EliteBook 840 14 inch G9 Notebook PC,Microsoft Corporation Virtual Machine,Dell Latitude 5521' 'old content root: rows with drivers and own rows stay'
    Assert-Equal ((Get-DriverCatalog -ContentRoot $root).fallbacks.Dell) 'Dell\_Generic WinPE-Storage-Net' 'old content root: fallbacks stay'
} finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

# Faster builds: the folders the console adds to Defender's exclusions itself; the Media tab lists them only on failure.
$folders = @(Get-ScanExclusionFolders -ContentRoot 'D:\Deploy' -WorkDir 'C:\WinPE_Build')
Assert-Equal $folders[0] 'C:\WinPE_Build' 'scan tip: the WinPE work folder first'
Assert-Equal ($folders[1] -like '*ImagingConsole*WinPEBuilds') $true 'scan tip: the WinPE build cache'
Assert-Equal ($folders[2] -like '*ImagingConsole*CaptureMount') $true 'scan tip: the VM capture''s mount folder'
Assert-Equal ($folders[3] -like 'D:\Deploy*Images') $true 'scan tip: the content root''s Images folder'
Assert-Equal @(Get-ScanExclusionFolders -ContentRoot '\\server\Deploy').Count 3 'scan tip: a network share is not listed (its server scans it)'
Assert-Equal (@($folders | Where-Object { $_ -match '^[A-Za-z]:\\?$' -or $_ -match '\.exe$' }).Count) 0 'scan tip: never a drive root or a program'
$cfg = [pscustomobject]@{ contentRoot = 'D:\Deploy' }
Assert-Equal @(Get-ScanExclusionTodo -ContentRoot 'D:\Deploy' -Config $cfg).Count 4 'scan exclusions: all four to add at first start'
$cfg = Add-ScanExclusionsDone -Config $cfg -Folders $folders[0], $folders[1], $folders[2]
Assert-Equal (@(Get-ScanExclusionTodo -ContentRoot 'D:\Deploy' -Config $cfg) -join ',') $folders[3] 'scan exclusions: only the folders not added yet (a new content root adds its Images)'
$cfg = Add-ScanExclusionsDone -Config $cfg -Folders ($folders[3] + '\')
Assert-Equal @(Get-ScanExclusionTodo -ContentRoot 'D:\Deploy' -Config $cfg).Count 0 'scan exclusions: nothing left once all were added (trailing backslash ignored)'
Assert-Equal @($cfg.scanExclusionsDone).Count 4 'scan exclusions: remembered once each'
Assert-Equal $(Get-ScanExclusionTip -ContentRoot 'D:\Deploy' -Config $cfg) $null 'scan tip: hidden once every folder was added'
$tip = Get-ScanExclusionTip -ContentRoot 'D:\Deploy' -Config ([pscustomobject]@{ contentRoot = 'D:\Deploy' }) -Reason 'Windows refused the change (Tamper Protection or a policy)'
Assert-Equal ($tip.Text -like '*could not add*(Windows refused the change (Tamper Protection or a policy))*Windows Security*C:\WinPE_Build*') $true 'scan tip: says why in one line, where to add them, and lists them'
Assert-Equal @(Get-ScanExclusionTodo -ContentRoot 'D:\Deploy' -Config ([pscustomobject]@{ scanTipDone = $true })).Count 4 'scan exclusions: the old Done flag does not stop the automatic add'
$cfg = [pscustomobject]@{ scanExclusionsDone = $folders; scanTipDismissed = $folders }
Assert-Equal (@(Get-ScanExclusionTodo -ContentRoot 'E:\Moved' -Config $cfg) -join ',') ([IO.Path]::Combine('E:\Moved', 'Images')) 'scan exclusions: a moved content root gets its new Images folder added'
Assert-Equal ((Get-ScanExclusionTip -ContentRoot 'E:\Moved' -Config $cfg -Reason 'x').Folders -join ',') ([IO.Path]::Combine('E:\Moved', 'Images')) 'scan tip: Done hid the old folders only, a refused new location shows again'
Assert-Equal $(Get-ScanExclusionTip -ContentRoot 'D:\Deploy' -Config ([pscustomobject]@{ scanTipDismissed = $folders })) $null 'scan tip: hidden for the folders the admin clicked Done on'
Assert-Equal (Read-ScanExclusionResult -Path ([IO.Path]::Combine([IO.Path]::GetTempPath(), 'no-such-scan-result.json'))).Ok $false 'scan exclusions: no result file = the script did not run'
$resPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "scan-result-$([guid]::NewGuid().ToString('N')).json")
try {
    [IO.File]::WriteAllText($resPath, '{"Ok":true,"NoDefender":false,"Added":["C:\\WinPE_Build"],"Message":"Added 1 folder(s)."}')
    $r = Read-ScanExclusionResult -Path $resPath
    Assert-Equal ($r.Ok -and @($r.Added).Count -eq 1) $true 'scan exclusions: reads the script''s result'
} finally { Remove-Item $resPath -Force -ErrorAction SilentlyContinue }

Complete-Tests 'All tests passed'
