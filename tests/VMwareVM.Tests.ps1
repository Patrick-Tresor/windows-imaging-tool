# Plain-PowerShell tests for the VMware hands-free capture helpers: vmrun arguments and output, reading a .vmx for
# its disks, finding the current disk of a snapshot chain, and Workstation's VM list. vmrun, the VM and qemu-img
# are not needed. Run: pwsh -File tests/VMwareVM.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/VMwareVM.psm1') -Force
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("vmware-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    # vmrun
    Assert-Equal ((New-VmrunArguments -Command snapshot -VmxPath 'D:\VMs\Staff\Staff.vmx' -Arguments 'Before capture') -join '|') `
        '-T|ws|snapshot|D:\VMs\Staff\Staff.vmx|Before capture' 'vmrun arguments keep a name with spaces as one argument'
    Assert-Equal ((New-VmrunArguments -Command list) -join '|') '-T|ws|list' 'vmrun list takes no VM'
    Assert-Equal ((New-VmrunArguments -Command start -VmxPath 'D:\VMs\Staff\Staff.vmx' -Arguments 'nogui' -Password 'p w') -join '|') `
        '-T|ws|-vp|p w|start|D:\VMs\Staff\Staff.vmx|nogui' 'the encryption password goes before the command'
    Assert-Equal (Test-VmrunWrongPassword @('Error: Cannot open VM: C:\Users\Pat\Documents\Test\Clone of Staff.vmx, Incorrect password')) $true 'a wrong encryption password is recognized'
    Assert-Equal (Test-VmrunWrongPassword @('Error: The virtual machine is not powered on')) $false 'other vmrun errors are not password errors'

    $vmx = Join-Path $root 'Staff.vmx'
    $listed = ConvertFrom-VmrunList @('Total running VMs: 2', $vmx.ToUpperInvariant(), 'E:\Other\Other.vmx', '')
    Assert-Equal $listed.Count 2 'vmrun list output gives one path per running VM'
    Assert-Equal (Test-VmxInList -VmxPath $vmx -RunningPaths $listed) $true 'a running VM is found whatever the case of its path'
    Assert-Equal (Test-VmxInList -VmxPath $vmx -RunningPaths (ConvertFrom-VmrunList @('Total running VMs: 0'))) $false 'no running VMs'
    Assert-Equal (Test-VmxInList -VmxPath $vmx -RunningPaths $null) $false 'empty vmrun output'

    # .vmx disks: a snapshot points the .vmx at the newest delta file.
    Set-Content -LiteralPath $vmx -Encoding ASCII -Value @(
        '.encoding = "UTF-8"',
        'displayName = "Staff"',
        'sata0:1.present = "TRUE"',
        'sata0:1.deviceType = "cdrom-image"',
        'sata0:1.fileName = "C:\ISO\Win11.iso"',
        'scsi0:0.present = "FALSE"',
        'scsi0:0.fileName = "Old.vmdk"',
        'sata0:0.present = "TRUE"',
        'sata0:0.fileName = "D:\Data\Data.vmdk"',
        'nvme0:0.present = "TRUE"',
        'nvme0:0.fileName = "Staff-000001.vmdk"')
    $disks = @(Get-VmxDiskPaths -VmxPath $vmx)
    Assert-Equal $disks.Count 2 'removed disks and CD drives are skipped'
    Assert-Equal $disks[0] (Join-Path $root 'Staff-000001.vmdk') 'the NVMe boot disk comes first, relative to the .vmx folder'
    Assert-Equal $disks[1] 'D:\Data\Data.vmdk' 'an absolute disk path is kept'

    $encrypted = Join-Path $root 'Encrypted.vmx'
    Set-Content -LiteralPath $encrypted -Encoding ASCII -Value @('.encoding = "UTF-8"', 'encryption.keySafe = "vmware:key/list/(pair/(phrase/abc))"', 'encryption.data = "AAAA"')
    Assert-Equal ($null -eq (Get-VmxDiskPaths -VmxPath $encrypted)) $true 'an encrypted .vmx cannot be read for its disks'
    Assert-Equal (Test-VmxEncrypted -VmxPath $encrypted) $true 'an encrypted .vmx is recognized'
    Assert-Equal (Test-VmxEncrypted -VmxPath $vmx) $false 'a plain .vmx is not encrypted'

    # Snapshot chains: Staff.vmdk (split disk: text descriptor + extent) <- Staff-000001.vmdk (single file, descriptor
    # inside) <- Staff-000002.vmdk (text descriptor naming its parent by full path).
    $chain = Join-Path $root 'chain'
    New-Item -ItemType Directory -Path $chain | Out-Null
    Set-Content -LiteralPath (Join-Path $chain 'Staff.vmdk') -Encoding ASCII -Value @(
        '# Disk DescriptorFile', 'version=1', 'CID=11111111', 'parentCID=ffffffff', 'createType="twoGbMaxExtentSparse"',
        'RW 8323072 SPARSE "Staff-s001.vmdk"')
    [IO.File]::WriteAllBytes((Join-Path $chain 'Staff-s001.vmdk'), [byte[]](@(0x4B, 0x44, 0x4D, 0x56) + @(0) * 2048))
    $header = [byte[]](@(0x4B, 0x44, 0x4D, 0x56) + @(0) * 508)
    $embedded = [Text.Encoding]::ASCII.GetBytes("# Disk DescriptorFile`nversion=1`nCID=22222222`nparentCID=11111111`ncreateType=`"monolithicSparse`"`nparentFileNameHint=`"Staff.vmdk`"`n")
    [IO.File]::WriteAllBytes((Join-Path $chain 'Staff-000001.vmdk'), [byte[]]($header + $embedded + @(0) * 4096))
    Set-Content -LiteralPath (Join-Path $chain 'Staff-000002.vmdk') -Encoding ASCII -Value @(
        '# Disk DescriptorFile', 'version=1', 'CID=33333333', 'parentCID=22222222', 'createType="twoGbMaxExtentSparse"',
        'parentFileNameHint="D:\VMs\Staff\Staff-000001.vmdk"', 'RW 8323072 SPARSE "Staff-000002-s001.vmdk"')

    $desc = Get-VmdkDescriptor -Path (Join-Path $chain 'Staff-000001.vmdk')
    Assert-Equal ($desc -match 'parentFileNameHint="Staff.vmdk"') $true 'a descriptor inside a single-file disk is read'
    Assert-Equal ($desc.Contains([string][char]0)) $false 'the descriptor stops at the padding after it'
    Assert-Equal ($null -eq (Get-VmdkDescriptor -Path (Join-Path $chain 'Staff-s001.vmdk'))) $true 'an extent file has no descriptor'
    $leaves = @(Get-VmdkLeafPaths -Folder $chain)
    Assert-Equal $leaves.Count 1 'one disk with two snapshots has one current disk'
    Assert-Equal (Split-Path -Leaf $leaves[0]) 'Staff-000002.vmdk' 'the newest delta is the current disk'
    Assert-Equal @(Get-VmdkDescriptorPaths -Folder $chain).Count 3 'every disk with a descriptor is listed, extent files are not'

    # A delta left behind by an interrupted snapshot operation is a leaf too; the disk written last comes first.
    $orphan = Join-Path $chain 'Staff-000003.vmdk'
    Set-Content -LiteralPath $orphan -Encoding ASCII -Value @('# Disk DescriptorFile', 'version=1', 'parentCID=11111111', 'parentFileNameHint="Staff.vmdk"')
    (Get-Item -LiteralPath $orphan).LastWriteTime = (Get-Date).AddDays(-1)
    (Get-Item -LiteralPath (Join-Path $chain 'Staff-000002.vmdk')).LastWriteTime = Get-Date
    $leaves = @(Get-VmdkLeafPaths -Folder $chain)
    Assert-Equal $leaves.Count 2 'a leftover delta is also a leaf'
    Assert-Equal (Split-Path -Leaf $leaves[0]) 'Staff-000002.vmdk' 'the disk written last comes first, not the first by name'

    # Picking a disk file: a disk with snapshots on top is read through its newest snapshot.
    $current = { param($n) Split-Path -Leaf (Resolve-VmdkCurrentDisk -Path (Join-Path $chain $n)) }
    Assert-Equal (& $current 'Staff.vmdk') 'Staff-000002.vmdk' 'the base disk resolves to the newest delta on top of it'
    Assert-Equal (& $current 'Staff-000001.vmdk') 'Staff-000002.vmdk' 'a middle delta resolves to the newest delta on top of it'
    Assert-Equal (& $current 'Staff-000002.vmdk') 'Staff-000002.vmdk' 'the current disk stays itself'
    Assert-Equal (& $current 'Staff-000003.vmdk') 'Staff-000003.vmdk' 'a leaf of another chain stays itself'
    Assert-Equal (Resolve-VmdkCurrentDisk -Path 'D:\VMs\a.vhdx') 'D:\VMs\a.vhdx' 'other formats are not resolved'

    Assert-Equal (Test-VMwareFolderInUse -Folder $chain) $false 'a folder without lock folders is not in use'
    New-Item -ItemType Directory -Path (Join-Path $chain 'Staff.vmx.lck') | Out-Null
    Assert-Equal (Test-VMwareFolderInUse -Folder $chain) $true 'a VMware lock folder means the VM is open'

    # Workstation's library and recent VMs.
    $appData = Join-Path $root 'AppData'
    New-Item -ItemType Directory -Path $appData | Out-Null
    $other = Join-Path $root 'Other.vmx'
    Set-Content -LiteralPath $other -Value 'displayName = "Other"'
    Set-Content -LiteralPath (Join-Path $appData 'inventory.vmls') -Encoding ASCII -Value @(
        '.encoding = "UTF-8"', "vmlist1.config = `"$vmx`"", 'vmlist1.DisplayName = "Staff"', 'vmlist2.config = "Z:\Gone\Gone.vmx"', 'vmlist3.config = "folder1"')
    Set-Content -LiteralPath (Join-Path $appData 'preferences.ini') -Encoding ASCII -Value @(
        "pref.mruVM0.filename = `"$($vmx.ToUpperInvariant())`"", "pref.mruVM1.filename = `"$other`"")
    $inventory = @(Get-VMwareInventory -AppData $appData)
    Assert-Equal $inventory.Count 2 'the library and recent VMs are listed once each, without missing files'
    Assert-Equal $inventory[0] $vmx 'the library comes first'
    Assert-Equal $inventory[1] $other 'a recent VM outside the library is listed'
    Assert-Equal @(Get-VMwareInventory -AppData (Join-Path $root 'none')).Count 0 'no Workstation settings, no VMs'

    # The agent in the VM and the host must use the same guest variables.
    $agent = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/VMwareCaptureAgent.ps1')
    $vars = Get-VMwareCaptureVariables
    Assert-Equal ($agent.Contains("'guestinfo.$($vars.Request)'")) $true 'the agent reads the request variable the host sets'
    Assert-Equal ($agent.Contains("'guestinfo.$($vars.State)'")) $true 'the agent answers in the variable the host reads'
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'src/VMwareCaptureAgent.ps1'), [ref]$null, [ref]$errors)
    Assert-Equal @($errors).Count 0 'the agent script parses'

    # The console's command line for a VMware capture.
    $vc = Get-VMCaptureArguments -ScriptPath 'C:\Imaging Tool\src\Capture-VMImage.ps1' -ContentRoot 'D:\Deploy' -VmxPath "D:\VMs\O'Brien\Staff.vmx" -Name 'Win11-Staff'
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($vc[-1]))
    Assert-Equal $decoded "& 'C:\Imaging Tool\src\Capture-VMImage.ps1' -VmxPath 'D:\VMs\O''Brien\Staff.vmx' -Name 'Win11-Staff' -ContentRoot 'D:\Deploy' -Compression max -NoPrompt" 'VMware capture command passes the .vmx path'
    $dc = Get-VMCaptureArguments -ScriptPath 'C:\Imaging Tool\src\Capture-VMImage.ps1' -ContentRoot 'D:\Deploy' -DiskPath 'C:\VMs\Staff\Staff-000002.vmdk' -Name 'Win11-Staff' -Split
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($dc[-1]))
    Assert-Equal $decoded "& 'C:\Imaging Tool\src\Capture-VMImage.ps1' -DiskPath 'C:\VMs\Staff\Staff-000002.vmdk' -Name 'Win11-Staff' -ContentRoot 'D:\Deploy' -Compression max -SplitSizeMB 3800 -NoPrompt" 'disk file capture command passes the disk path'

    # The agent goes to the content root's Tools folder with Prepare-Reference.ps1, which it needs next to it.
    $content = Join-Path $root 'content'
    Update-ContentTools -ContentRoot $content
    Assert-Equal (Test-Path (Join-Path $content 'Tools/VMwareCaptureAgent.ps1')) $true 'the agent is copied to Tools'
    Assert-Equal (Test-Path (Join-Path $content 'Tools/Prepare-Reference.ps1')) $true 'Prepare-Reference.ps1 is next to it'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All VMware capture tests passed.' -ForegroundColor Green
