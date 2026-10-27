# Helpers for the hands-free capture of a VMware Workstation VM (Capture-VMImage.ps1 -VmxPath) and for the
# console's capture wizard: finding vmrun.exe and the VMs Workstation knows, reading a .vmx for its disks, and
# finding the current disk of each snapshot chain when the .vmx cannot be read.

# The guest variables the host and VMwareCaptureAgent.ps1 (inside the VM) talk through. The host sets the request;
# the agent answers in the state variable. In the guest they are guestinfo.<name>.
$script:CaptureRequestVar = 'imagingtool.capture'
$script:CaptureStateVar = 'imagingtool.state'

function Get-VMwareCaptureVariables {
    [pscustomobject]@{ Request = $script:CaptureRequestVar; State = $script:CaptureStateVar }
}

function Find-Vmrun {
    # vmrun.exe ships with VMware Workstation Pro (Workstation Player's vmrun cannot take snapshots).
    $cmd = Get-Command vmrun.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }) {
        $path = Join-Path $base 'VMware\VMware Workstation\vmrun.exe'
        if (Test-Path -LiteralPath $path) { return $path }
    }
}

function Find-QemuImg {
    # qemu-img reads VMware disks, including the snapshot chain, and writes a VHD Windows can mount.
    $cmd = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }) {
        $path = Join-Path $base 'qemu\qemu-img.exe'
        if (Test-Path -LiteralPath $path) { return $path }
    }
}

function New-VmrunArguments {
    # Arguments for vmrun.exe: vmrun -T ws <command> [<vmx>] [<more>...].
    param([Parameter(Mandatory)][string]$Command, [string]$VmxPath, [string[]]$Arguments = @())
    $list = @('-T', 'ws', $Command)
    if ($VmxPath) { $list += $VmxPath }
    $list + @($Arguments)
}

function ConvertFrom-VmrunList {
    # The .vmx paths in the output of 'vmrun list' (a "Total running VMs: N" line, then one path per line).
    param([AllowEmptyCollection()][string[]]$Lines = @())
    @($Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -notmatch '^Total running VMs' })
}

function Test-VmxInList {
    # True when $VmxPath is one of $RunningPaths. Windows paths compare without case.
    param([Parameter(Mandatory)][string]$VmxPath, [AllowEmptyCollection()][string[]]$RunningPaths = @())
    $want = [IO.Path]::GetFullPath($VmxPath)
    [bool]@($RunningPaths | Where-Object { $_ -and [IO.Path]::GetFullPath($_) -ieq $want }).Count
}

function Read-VmxSettings {
    # The key = "value" lines of a .vmx (or of Workstation's inventory.vmls and preferences.ini), keys lowercased.
    param([Parameter(Mandatory)][string]$Path)
    $settings = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*"(.*)"\s*$') { $settings[$Matches[1].ToLowerInvariant()] = $Matches[2] }
    }
    $settings
}

function Get-VmxDiskPaths {
    # The virtual hard disks a .vmx uses, in controller order, as full paths. A snapshot moves a disk to its newest
    # delta file (Name-000001.vmdk), and the .vmx names that one. Returns $null when the .vmx is encrypted, as it is
    # for a VM with a virtual TPM; Get-VmdkLeafPaths finds the disks then.
    param([Parameter(Mandatory)][string]$VmxPath)
    $settings = Read-VmxSettings -Path $VmxPath
    if ($settings.Contains('encryption.keysafe') -or $settings.Contains('encryption.data')) { return $null }
    $folder = Split-Path -Parent ([IO.Path]::GetFullPath($VmxPath))
    $order = @{ nvme = 0; scsi = 1; sata = 2; ide = 3 }
    $disks = foreach ($key in $settings.Keys) {
        if ($key -notmatch '^((nvme|scsi|sata|ide)(\d+):(\d+))\.filename$') { continue }
        $dev = $Matches[1]; $bus = $order[$Matches[2]]; $controller = [int]$Matches[3]; $unit = [int]$Matches[4]
        $file = $settings[$key]
        if ($file -notmatch '\.vmdk$') { continue }
        if ($settings["$dev.present"] -ieq 'FALSE') { continue }
        if ($settings["$dev.devicetype"] -match 'cdrom') { continue }
        $path = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $folder $file }
        [pscustomobject]@{ Path = $path; Bus = $bus; Controller = $controller; Unit = $unit }
    }
    @($disks | Sort-Object Bus, Controller, Unit | ForEach-Object { $_.Path })
}

function Get-VmdkDescriptor {
    # The descriptor text of a .vmdk, or $null for an extent file (-s001.vmdk, -flat.vmdk) that has none. A
    # "single file" disk keeps its descriptor inside the binary file near the start; a split disk has a small
    # text file. Either way it sits in the first 64 KB.
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 65536
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally { $stream.Dispose() }
    $text = [Text.Encoding]::GetEncoding(28591).GetString($buffer, 0, $read)
    $start = $text.IndexOf('# Disk DescriptorFile')
    if ($start -lt 0) { return $null }
    $end = $text.IndexOf([char]0, $start)
    if ($end -lt 0) { $end = $text.Length }
    $text.Substring($start, $end - $start)
}

function Get-VmdkLeafPaths {
    # The current disk of each snapshot chain in a VM folder: every .vmdk with a descriptor that no other .vmdk
    # names as its parent. Used when the .vmx is encrypted.
    param([Parameter(Mandatory)][string]$Folder)
    $descriptors = @(Get-ChildItem -LiteralPath $Folder -Filter *.vmdk -File | Where-Object { Get-VmdkDescriptor -Path $_.FullName })
    $parents = @(foreach ($d in $descriptors) {
        if ((Get-VmdkDescriptor -Path $d.FullName) -match '(?m)^parentFileNameHint\s*=\s*"([^"]+)"') { Split-Path -Leaf $Matches[1] }
    })
    @($descriptors | Where-Object { $parents -notcontains $_.Name } | Sort-Object Name | ForEach-Object { $_.FullName })
}

function Get-VMwareInventory {
    # The .vmx files VMware Workstation lists in its library (inventory.vmls) and recent VMs (preferences.ini),
    # that still exist. $AppData is %APPDATA%\VMware.
    param([string]$AppData = (Join-Path $env:APPDATA 'VMware'))
    $paths = foreach ($file in 'inventory.vmls', 'preferences.ini') {
        $path = Join-Path $AppData $file
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $settings = Read-VmxSettings -Path $path
        foreach ($key in $settings.Keys) {
            if ($key -match '^(vmlist\d+\.config|pref\.mruvm\d+\.filename)$' -and $settings[$key] -match '\.vmx$') { $settings[$key] }
        }
    }
    $unique = [Collections.Generic.List[string]]::new()
    foreach ($p in $paths) {
        if ((Test-Path -LiteralPath $p) -and -not @($unique | Where-Object { $_ -ieq $p }).Count) { $unique.Add($p) }
    }
    @($unique)
}

Export-ModuleMember -Function Get-VMwareCaptureVariables, Find-Vmrun, Find-QemuImg, New-VmrunArguments, ConvertFrom-VmrunList, Test-VmxInList,
    Read-VmxSettings, Get-VmxDiskPaths, Get-VmdkDescriptor, Get-VmdkLeafPaths, Get-VMwareInventory
