# Helpers for capturing a VMware Workstation disk file (Capture-VMImage.ps1 -DiskPath) and for the console's
# capture wizard: the VMs Workstation knows, reading a .vmx for its disks, and finding the current disk of each
# snapshot chain when the .vmx cannot be read.

function Find-QemuImg {
    # qemu-img reads VMware disks, including the snapshot chain, and writes a VHD Windows can mount.
    $cmd = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }) {
        $path = Join-Path $base 'qemu\qemu-img.exe'
        if (Test-Path -LiteralPath $path) { return $path }
    }
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

function Test-VmxEncrypted {
    # True when the .vmx is encrypted (every VM with a virtual TPM), so its settings cannot be read.
    param([Parameter(Mandatory)][string]$VmxPath)
    $settings = Read-VmxSettings -Path $VmxPath
    $settings.Contains('encryption.keysafe') -or $settings.Contains('encryption.data')
}

function Get-VmxDiskPaths {
    # The virtual hard disks a .vmx uses, in controller order, as full paths. A snapshot moves a disk to its newest
    # delta file (Name-000001.vmdk), and the .vmx names that one. Returns $null when the .vmx is encrypted, as it is
    # for a VM with a virtual TPM; Get-VmdkLeafPaths finds the disks then.
    param([Parameter(Mandatory)][string]$VmxPath)
    if (Test-VmxEncrypted -VmxPath $VmxPath) { return $null }
    $settings = Read-VmxSettings -Path $VmxPath
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

function Get-VmdkDescriptorPaths {
    # Every .vmdk in a VM folder that is a disk (has a descriptor), not an extent file.
    param([Parameter(Mandatory)][string]$Folder)
    @(Get-ChildItem -LiteralPath $Folder -Filter *.vmdk -File | Where-Object { Get-VmdkDescriptor -Path $_.FullName } | ForEach-Object { $_.FullName })
}

function Get-VmdkLeafPaths {
    # The current disk of each snapshot chain in a VM folder: every .vmdk with a descriptor that no other .vmdk
    # names as its parent, most recently written first. A delta left behind by an interrupted snapshot operation
    # is a leaf too, so the newest one is the likeliest to be the disk the VM just used. Used when the .vmx is
    # encrypted and no snapshot taken by this run tells which disk is current.
    param([Parameter(Mandatory)][string]$Folder)
    $descriptors = @(Get-VmdkDescriptorPaths -Folder $Folder | ForEach-Object { Get-Item -LiteralPath $_ })
    $parents = @(foreach ($d in $descriptors) {
        if ((Get-VmdkDescriptor -Path $d.FullName) -match '(?m)^parentFileNameHint\s*=\s*"([^"]+)"') { Split-Path -Leaf $Matches[1] }
    })
    @($descriptors | Where-Object { $parents -notcontains $_.Name } | Sort-Object LastWriteTimeUtc, Name -Descending | ForEach-Object { $_.FullName })
}

function Resolve-VmdkCurrentDisk {
    # The disk to read for a .vmdk someone picked: the file itself, or, when snapshots were taken on top of it, the
    # newest delta whose snapshot chain goes back to it (the base disk alone holds the VM as it was at the first
    # snapshot). Other disk formats are returned unchanged.
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::GetExtension($Path) -ine '.vmdk') { return $Path }
    $folder = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $parentOf = @{}
    foreach ($d in Get-VmdkDescriptorPaths -Folder $folder) {
        $parentOf[(Split-Path -Leaf $d).ToLowerInvariant()] =
            if ((Get-VmdkDescriptor -Path $d) -match '(?m)^parentFileNameHint\s*=\s*"([^"]+)"') { (Split-Path -Leaf $Matches[1]).ToLowerInvariant() }
    }
    $picked = (Split-Path -Leaf $Path).ToLowerInvariant()
    foreach ($leaf in Get-VmdkLeafPaths -Folder $folder) {
        # Newest first, so the first chain that reaches the picked disk wins.
        $name = (Split-Path -Leaf $leaf).ToLowerInvariant()
        for ($i = 0; $name -and $i -lt 64; $i++) {
            if ($name -eq $picked) { return $leaf }
            $name = $parentOf[$name]
        }
    }
    $Path
}

function Test-VMwareFolderInUse {
    # True when VMware has the VM in this folder open: it keeps <file>.lck folders next to the .vmx and disks while
    # the VM runs. Reading a disk then would give a half-written copy.
    param([Parameter(Mandatory)][string]$Folder)
    [bool]@(Get-ChildItem -LiteralPath $Folder -Filter *.lck -Directory -ErrorAction SilentlyContinue).Count
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

Export-ModuleMember -Function Find-QemuImg, Test-VmxEncrypted, Read-VmxSettings, Get-VmxDiskPaths, Get-VmdkDescriptor, Get-VmdkDescriptorPaths,
    Get-VmdkLeafPaths, Resolve-VmdkCurrentDisk, Test-VMwareFolderInUse, Get-VMwareInventory
