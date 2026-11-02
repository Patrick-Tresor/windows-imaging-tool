# Shared helpers for capture and deploy. Runs in WinPE (PowerShell 5.1, WinPE-PowerShell component).

$script:LogPath = 'X:\Windows\Temp\Deploy.log'

function Format-ConsoleText {
    <#
    .SYNOPSIS
        Splits a console line into lines that fit the window, at spaces where possible. Continuation lines are
        indented, so a long error reads as one block instead of running off the right edge.
    #>
    param([AllowEmptyString()][string]$Text, [int]$Width = 100, [int]$Indent = 9)
    if ($Width -lt 20) { $Width = 20 }
    $lines = New-Object System.Collections.Generic.List[string]
    $pad = ' ' * $Indent
    $rest = $Text
    $first = $true
    while ($true) {
        $room = if ($first) { $Width } else { $Width - $Indent }
        if ($rest.Length -le $room) { $lines.Add($(if ($first) { $rest } else { $pad + $rest })); break }
        $cut = $rest.LastIndexOf(' ', $room)
        if ($cut -lt [int]($room / 2)) { $cut = $room }   # no good space: break inside the word
        $part = $rest.Substring(0, $cut).TrimEnd()
        $lines.Add($(if ($first) { $part } else { $pad + $part }))
        $rest = $rest.Substring($cut).TrimStart()
        $first = $false
        if (-not $rest) { break }
    }
    $lines.ToArray()
}

function Get-ConsoleWidth {
    try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -gt 0) { return $w - 1 } } catch { }
    100
}

function Set-DeployConsole {
    # Makes the WinPE console wide enough for the log (up to 140 columns, as the screen allows), with the buffer
    # as wide as the window so nothing is cut off at the right edge, and a long history to scroll back in.
    param([int]$Columns = 140, [int]$Rows = 40, [string]$Title = 'Deploy Windows')
    try {
        $raw = $Host.UI.RawUI
        $raw.WindowTitle = $Title
        $max = $raw.MaxPhysicalWindowSize
        $w = [Math]::Min($Columns, $max.Width); $h = [Math]::Min($Rows, $max.Height)
        if ($w -lt 20 -or $h -lt 10) { return }
        $buffer = New-Object Management.Automation.Host.Size($w, [Math]::Max(3000, $raw.BufferSize.Height))
        $window = New-Object Management.Automation.Host.Size($w, $h)
        # The buffer can never be narrower than the window: shrink the window first, grow the buffer first.
        if ($w -lt $raw.WindowSize.Width) { $raw.WindowSize = $window; $raw.BufferSize = $buffer }
        else { $raw.BufferSize = $buffer; $raw.WindowSize = $window }
    } catch { }   # a host without a resizable console (ISE, CI): keep what it has
}

function Write-DeployLog {
    # The log keeps the full line with date and level; the console gets the time and the message, wrapped to fit.
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $now = Get-Date
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f $now, $Level, $Message
    Add-Content -Path $script:LogPath -Value $line
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    $prefix = @{ INFO = ''; WARN = 'Warning: '; ERROR = 'ERROR: ' }[$Level]
    foreach ($l in (Format-ConsoleText -Text ('{0:HH:mm:ss} {1}{2}' -f $now, $prefix, $Message) -Width (Get-ConsoleWidth))) {
        Write-Host $l -ForegroundColor $color
    }
}

function Invoke-Native {
    # Runs an external tool, logs it, and throws on a non-zero exit code.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    Write-DeployLog "> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { Add-Content -Path $script:LogPath -Value "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "$FilePath exited with code $LASTEXITCODE" }
}

function Get-NativeProgress {
    <#
    .SYNOPSIS
        How far a DISM run is, from what it has printed so far. $null before it printed any progress.
    .DESCRIPTION
        /Add-Driver prints "Installing 12 of 76 - ...": Percent counts the drivers done, Done/Total give the count.
        Everything else (/Apply-Image, /Capture-Image) draws a bar "[=====  45.0%  ]": Percent is its last value.
    #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $null }
    $drivers = [regex]::Matches($Text, 'Installing (\d+) of (\d+)')
    if ($drivers.Count) {
        $m = $drivers[$drivers.Count - 1]
        $n = [int]$m.Groups[1].Value; $total = [int]$m.Groups[2].Value
        if ($total -gt 0) {
            return [pscustomobject]@{ Percent = [int][Math]::Floor(100 * ($n - 1) / $total); Done = $n - 1; Total = $total }
        }
    }
    $found = [regex]::Matches($Text, '(\d{1,3})(?:[.,]\d+)?\s?%')
    if (-not $found.Count) { return $null }
    $pct = [Math]::Min(100, [int]$found[$found.Count - 1].Groups[1].Value)
    [pscustomobject]@{ Percent = $pct; Done = $null; Total = $null }
}

function Get-NativeLogLines {
    # The lines of a tool's output worth keeping in the log: no progress bar redraws ("[==== 45.0% ]", one per
    # percent when DISM writes to a file), no blank lines.
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return @() }
    @($Text -split "[`r`n]+" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*\[[=\s]*\d{1,3}(?:[.,]\d+)?\s?%[=\s]*\]\s*$' })
}

function Read-SharedText([string]$Path) {
    # Reads a file another process still writes to. File.ReadAllText asks for FileShare.Read, which fails while
    # cmd has the file open for writing, so the progress was never seen.
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { '' }
}

function Invoke-NativeWithProgress {
    # Like Invoke-Native for long DISM runs: reads the tool's output every few seconds and calls OnProgress with
    # the last percentage it printed (or $null) and the Get-NativeProgress result, so the progress window and the
    # dashboard follow along. Only the result lines go to the log, not every progress bar redraw.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][scriptblock]$OnProgress,
        [int]$IntervalSeconds = 2
    )
    Write-DeployLog "> $FilePath $($ArgumentList -join ' ')"
    $out = Join-Path $env:TEMP ("native-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $quoted = @($FilePath) + $ArgumentList | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    # cmd's redirection keeps the output off the console; Read-SharedText reads it while the tool writes.
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$($quoted -join ' ') > `"$out`" 2>&1`"" -NoNewWindow -PassThru
    $null = $p.Handle   # PowerShell 5.1 only keeps ExitCode if the handle was read before exit
    while (-not $p.WaitForExit($IntervalSeconds * 1000)) {
        $info = Get-NativeProgress -Text (Read-SharedText $out)
        try { & $OnProgress $(if ($info) { $info.Percent } else { $null }) $info } catch { }
    }
    if (Test-Path $out) {
        Get-NativeLogLines -Text (Read-SharedText $out) | ForEach-Object { Add-Content -Path $script:LogPath -Value "  $_" }
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }
    if ($p.ExitCode -ne 0) { throw "$FilePath exited with code $($p.ExitCode)" }
}

function Get-HardwareIdentity {
    # Returns the values the driver catalog can match on.
    $cs   = Get-CimInstance Win32_ComputerSystem
    $csp  = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $sku  = $null
    try { $sku = (Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation -ErrorAction Stop).SystemSKU } catch { }

    $maker = switch -Wildcard ($cs.Manufacturer.Trim()) {
        'Dell*'            { 'Dell' }
        'HP' { 'HP' }
        'Hewlett*'         { 'HP' }
        'LENOVO'           { 'Lenovo' }
        default            { $cs.Manufacturer.Trim() }
    }

    $model = $cs.Model.Trim()
    $machineType = $null
    if ($maker -eq 'Lenovo') {
        # Lenovo puts the machine type (e.g. 21HDS0AB00) in Model and the friendly name in Version.
        $machineType = $model.Substring(0, [Math]::Min(4, $model.Length))
        $model = $csp.Version.Trim()
    }
    if ($maker -eq 'HP' -and $sku) {
        # HP's SystemSKU is the order number; the 4-char baseboard product is what driver catalogs use.
        $sku = (Get-CimInstance Win32_BaseBoard).Product.Trim()
    }

    [pscustomobject]@{
        Maker       = $maker
        Model       = $model
        MachineType = $machineType
        Sku         = if ($sku) { $sku.Trim() } else { $null }
        Serial      = $bios.SerialNumber.Trim()
        IsUefi      = Test-UefiBoot
    }
}

function Get-WinPEDriverInfs {
    # The .inf files to load in WinPE from a folder: the x64 ones when the folder has per-architecture
    # subfolders (Dell's WinPE packs have x64 and x86), otherwise all of them.
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path $Folder)) { return @() }
    $base = (Resolve-Path $Folder).ProviderPath.TrimEnd('\', '/')
    $infs = @(Get-ChildItem -Path $base -Filter *.inf -Recurse -File | Sort-Object FullName)
    # Folder names below the given folder only, so a folder that is itself called x86 still gives its drivers.
    $below = { param($f) ($f.FullName.Substring($base.Length) -replace '\\', '/').ToLowerInvariant() }
    $x64 = @($infs | Where-Object { (& $below $_) -match '/(x64|amd64)/' })
    if ($x64) { $x64 } else { @($infs | Where-Object { (& $below $_) -notmatch '/(x86|arm64)/' }) }
}

function Import-WinPEDrivers {
    # Loads drivers into the running WinPE with drvload, then rescans storage. True when at least one loaded.
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path $Folder)) { Write-DeployLog "No WinPE drivers to load: $Folder does not exist"; return $false }
    $infs = @(Get-WinPEDriverInfs -Folder $Folder)
    if (-not $infs) { Write-DeployLog "No WinPE drivers to load in $Folder"; return $false }
    $failed = 0
    foreach ($inf in $infs) {
        & drvload.exe $inf.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    Write-DeployLog "Loaded $($infs.Count - $failed) of $($infs.Count) WinPE driver(s) from $Folder" -Level $(if ($failed -eq $infs.Count) { 'WARN' } else { 'INFO' })
    if ($failed -eq $infs.Count) { return $false }
    try { Update-HostStorageCache -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 3   # a newly loaded storage controller takes a moment to list its disks
    $true
}

function Format-WinPEDriverReport {
    # One log line from config\winpe-drivers.json (written by New-DeploymentMedia.ps1); $null Report means an older build.
    param($Report)
    if (-not $Report) { return 'This boot image has no WinPE driver report: it was built before WinPE drivers were added. Rebuild the media.' }
    $parts = @(foreach ($s in @($Report.sources)) { "$($s.name): $($s.added) added$(if (@($s.failed).Count) { ", $(@($s.failed).Count) failed" })" })
    $text = if ($parts) { "WinPE drivers in this boot image (built $($Report.built)): $($parts -join '; ')." } else { "No extra WinPE drivers in this boot image (built $($Report.built))." }
    if ($Report.problem) { $text += " $($Report.problem)" }
    $text + $(if ($Report.vmd) { ' Intel RST/VMD storage driver: yes.' } else { ' Intel RST/VMD storage driver: NO, so an SSD behind VMD stays hidden.' })
}

function Write-WinPEDriverReport {
    param([Parameter(Mandatory)][string]$Path)
    $r = if (Test-Path $Path) { try { Get-Content -Raw $Path | ConvertFrom-Json } catch { $null } } else { $null }
    Write-DeployLog (Format-WinPEDriverReport $r) -Level $(if ($r -and $r.vmd) { 'INFO' } else { 'WARN' })
}

function Get-DevicesWithoutDriver {
    # Devices WinPE found but has no driver for (code 28), storage controllers first: "Name (PCI\VEN_8086&DEV_9A0B)".
    $devs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 28 })
    $devs | Sort-Object @{ Expression = { if ("$($_.DeviceID)" -match 'VEN_8086&DEV_(9A0B|467F|A77F|7D0B|AD0B)') { 0 } else { 1 } } } |
        ForEach-Object { '{0} ({1})' -f $(if ($_.Name) { $_.Name } else { 'unknown device' }), ("$($_.DeviceID)" -replace '&SUBSYS.*$', '') }
}

function Get-AddDriverArgs {
    <#
    .SYNOPSIS
        DISM arguments that inject a driver folder into an offline Windows. Unsigned drivers are refused unless
        -ForceUnsigned: DISM's /ForceUnsigned is a bare switch, and "/ForceUnsigned:No" fails with error 87.
        PowerShell quotes an argument with a space ("/Driver:E:\Drivers\Dell\Latitude 5521") as a whole, which DISM
        reads; a trailing backslash is removed so it can't escape that closing quote.
    #>
    param([Parameter(Mandatory)][string]$ImageRoot, [Parameter(Mandatory)][string]$DriverPath, [switch]$ForceUnsigned)
    $path = $DriverPath.TrimEnd('\', '/')
    if ($path -match '^[A-Za-z]:$') { $path += '\' }   # a bare drive root keeps its backslash
    $dismArgs = @("/Image:$ImageRoot", '/Add-Driver', "/Driver:$path", '/Recurse')
    if ($ForceUnsigned) { $dismArgs += '/ForceUnsigned' }
    $dismArgs
}

function Format-DriverProgressLine {
    # "[ 5/76] storage\iaStorVD.inf  (0:42)": the driver being added to boot.wim, its folder below Root, elapsed time.
    param([int]$Index, [int]$Total, [Parameter(Mandatory)][string]$Path, [string]$Root, [TimeSpan]$Elapsed = [TimeSpan]::Zero)
    $name = Split-Path $Path -Leaf
    $folder = Split-Path (Split-Path $Path -Parent) -Leaf
    $shown = if ($folder -and $Root -and (Split-Path $Path -Parent).TrimEnd('\', '/') -ne $Root.TrimEnd('\', '/')) { "$folder\$name" } else { $name }
    $width = "$Total".Length
    ('[{0}/{1}] {2}  ({3:m\:ss})' -f "$Index".PadLeft($width), $Total, $shown, $Elapsed)
}

function Test-UefiBoot {
    # WinPE records the firmware type here: 1 = BIOS, 2 = UEFI.
    (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType -eq 2
}

function Select-WindowsBootEntry {
    <#
    .SYNOPSIS
        Picks the firmware entry that starts the Windows just deployed, from `bcdedit /enum firmware` output.
    .DESCRIPTION
        bcdboot /f UEFI writes a Windows Boot Manager entry (\EFI\Microsoft\Boot\bootmgfw.efi). bcdedit's labels are
        localized, so this reads only identifiers, paths and devices: blocks are split on the dashed lines, and an
        entry on the system partition just written (partition=S:) wins over another Windows Boot Manager, such as
        one left by an older Windows on a second disk. Returns {bootmgr}, a {GUID} or $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BcdText,
        [string]$SystemDrive = 'S:'
    )
    $idPattern = '\{(bootmgr|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}'
    $candidates = foreach ($b in ($BcdText -split '(?m)^-{5,}\s*$')) {
        $lines = @($b.Trim() -split "`r?`n" | Where-Object { $_.Trim() })
        if (-not $lines) { continue }
        # The block's own identifier is on its first line; {fwbootmgr} lists other entries in displayorder.
        $id = [regex]::Match($lines[0], $idPattern)
        if (-not $id.Success) { continue }
        if ($b -notmatch '(?im)\\EFI\\Microsoft\\Boot\\bootmgfw\.efi\s*$') { continue }
        $onSystem = $b -match ('(?im)partition=' + [regex]::Escape($SystemDrive.TrimEnd('\')) + '\s*$')
        [pscustomobject]@{ Id = $id.Value; Rank = $(if ($onSystem) { 1 } elseif ($id.Value -eq '{bootmgr}') { 2 } else { 3 }) }
    }
    $best = @($candidates | Sort-Object Rank | Select-Object -First 1)
    if ($best) { $best[0].Id } else { $null }
}

function Get-WindowsBootNextArgs {
    # The two bcdedit calls that make the firmware start Windows: first in the boot order, and the next boot
    # (BootNext), which the firmware honours even when a USB stick or the network stays above it in its own order.
    param([Parameter(Mandatory)][string]$Entry)
    @(@('/set', '{fwbootmgr}', 'displayorder', $Entry, '/addfirst'), @('/set', '{fwbootmgr}', 'bootsequence', $Entry))
}

function Set-WindowsBootNext {
    <#
    .SYNOPSIS
        After bcdboot on a UEFI PC: makes the next restart start the deployed Windows instead of the USB stick
        or the network again. Never throws; returns Ok, Entry and Message for the log.
    #>
    param([string]$SystemDrive = 'S:', [string]$BcdEdit = 'bcdedit.exe')
    # bcdedit's error text on stderr must not become a terminating error before its exit code is read.
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $BcdEdit /enum firmware 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Entry = $null; Message = "bcdedit /enum firmware failed (exit $LASTEXITCODE): $($text.Trim())" } }
        $entry = Select-WindowsBootEntry -BcdText $text -SystemDrive $SystemDrive
        if (-not $entry) { return [pscustomobject]@{ Ok = $false; Entry = $null; Message = 'No Windows Boot Manager entry in the firmware boot list.' } }
        foreach ($a in (Get-WindowsBootNextArgs -Entry $entry)) {
            $out = (& $BcdEdit @a 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Entry = $entry; Message = "bcdedit $($a -join ' ') failed (exit $LASTEXITCODE): $($out.Trim())" } }
        }
        [pscustomobject]@{ Ok = $true; Entry = $entry; Message = "Next boot and first in the boot order: Windows Boot Manager $entry" }
    } catch {
        [pscustomobject]@{ Ok = $false; Entry = $null; Message = $_.Exception.Message }
    }
}

function New-DeployedMarker {
    # Written to <Windows drive>\Deploy\deployed.json after a deployment; FirstBoot.ps1 deletes it once Windows runs.
    # While it is there, WinPE knows this disk holds a Windows that has not started yet.
    param([Parameter(Mandatory)]$Identity, [string]$AnswerFile, [string]$ComputerName)
    [pscustomobject]@{
        serial       = "$($Identity.Serial)"
        answerFile   = $AnswerFile
        computerName = $ComputerName
        deployed     = (Get-Date).ToString('o')
    }
}

function Find-UnstartedDeployment {
    <#
    .SYNOPSIS
        Looks on this PC's volumes for a Windows this tool deployed that has never started (\Deploy\deployed.json
        with this PC's serial). Found means the PC restarted into WinPE again, usually from a USB stick left in,
        so an Unattended countdown must not wipe it a second time. Returns the marker or $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Serial,
        [string[]]$Roots = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.RootDirectory.FullName }),
        [string[]]$ExcludeRoots = @()
    )
    $skip = @($ExcludeRoots + 'X:\' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, [Math]::Min(2, $_.Length)).ToUpperInvariant() })
    foreach ($r in $Roots) {
        if ($r.Length -ge 2 -and $r.Substring(0, 2).ToUpperInvariant() -in $skip) { continue }
        $path = Join-Path $r 'Deploy\deployed.json'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try { $m = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { continue }
        if ("$($m.serial)" -eq $Serial) {
            $m | Add-Member -NotePropertyName path -NotePropertyValue $path -Force
            return $m
        }
    }
    $null
}

function New-DiskpartScript {
    # Wipes the disk and creates Microsoft's recommended layout for the firmware WinPE booted with.
    # Both layouts leave the boot files' partition at S: and Windows at W:.
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][ValidateSet('UEFI', 'BIOS')][string]$Firmware
    )
    if ($Firmware -eq 'UEFI') {
        # GPT: EFI, MSR, Windows, Recovery.
        @"
select disk $DiskNumber
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=1024
format quick fs=ntfs label="Windows"
assign letter=W
create partition primary
format quick fs=ntfs label="Recovery"
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
exit
"@
    } else {
        # MBR: active System, Windows, Recovery (type 27, hidden from Explorer).
        @"
select disk $DiskNumber
clean
convert mbr
create partition primary size=100
format quick fs=ntfs label="System"
assign letter=S
active
create partition primary
shrink minimum=1024
format quick fs=ntfs label="Windows"
assign letter=W
create partition primary
format quick fs=ntfs label="Recovery"
set id=27
exit
"@
    }
}

function Find-DriverCatalogMatch {
    # The most specific catalog entry for a PC, without logging, so the console can re-check reported PCs.
    # Status: Matched, InboxOnly (an entry with no path), Fallback (maker fallback), None.
    param(
        [Parameter(Mandatory)]$Identity,
        [string]$CatalogPath,
        $Catalog   # the parsed catalog, instead of CatalogPath, when checking many PCs
    )
    $catalog = if ($Catalog) { $Catalog } else { Get-Content -Raw -Path $CatalogPath | ConvertFrom-Json }
    $mine = @($catalog.entries | Where-Object { $_.maker -eq $Identity.Maker })

    $by = 'sku'
    $match = $mine | Where-Object { $_.sku -and $_.sku -eq $Identity.Sku } | Select-Object -First 1
    if (-not $match) { $by = 'machineType';  $match = $mine | Where-Object { $_.machineType -and $_.machineType -eq $Identity.MachineType } | Select-Object -First 1 }
    if (-not $match) { $by = 'model';        $match = $mine | Where-Object { $_.model -and $_.model -eq $Identity.Model } | Select-Object -First 1 }
    if (-not $match) { $by = 'modelPattern'; $match = $mine | Where-Object { $_.modelPattern -and $Identity.Model -like $_.modelPattern } | Select-Object -First 1 }

    if ($match) {
        $status = if ($match.path) { 'Matched' } else { 'InboxOnly' }
        return [pscustomobject]@{ Status = $status; MatchedBy = $by; Path = $match.path }
    }
    if ($catalog.fallbacks -and $catalog.fallbacks.PSObject.Properties[$Identity.Maker]) {
        return [pscustomobject]@{ Status = 'Fallback'; MatchedBy = 'fallback'; Path = $catalog.fallbacks.($Identity.Maker) }
    }
    [pscustomobject]@{ Status = 'None'; MatchedBy = $null; Path = $null }
}

function Resolve-DriverPack {
    # Picks the most specific catalog entry for this PC. Returns a full path, or $null for inbox drivers only.
    # -Detailed returns the Find-DriverCatalogMatch result with FullPath added (MissingFolder when it is not there).
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$DriverRoot,
        [switch]$Detailed
    )
    $m = Find-DriverCatalogMatch -Identity $Identity -CatalogPath $CatalogPath
    switch ($m.Status) {
        'Matched'   { Write-DeployLog "Driver catalog match: $($m.Path)" }
        'InboxOnly' { Write-DeployLog "Catalog says Windows inbox drivers only for '$($Identity.Model)'" }
        'Fallback'  { Write-DeployLog "No exact driver pack for '$($Identity.Model)'; using maker fallback $($m.Path)" -Level WARN }
        'None'      { Write-DeployLog "No driver pack for $($Identity.Maker) '$($Identity.Model)'; Windows inbox drivers only" -Level WARN }
    }

    $full = $null
    if ($m.Path) {
        $full = Join-Path $DriverRoot ($m.Path -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $full)) {
            Write-DeployLog "Driver folder missing: $full" -Level WARN
            $full = $null
            if ($m.Status -eq 'Matched') { $m.Status = 'MissingFolder' }
        }
    }
    if (-not $Detailed) { return $full }
    $m | Add-Member -NotePropertyName FullPath -NotePropertyValue $full -PassThru
}

function Write-DriverReport {
    # Records which drivers this PC got in <content root>\Reports\Drivers\<serial>.json, one file per PC, newest
    # deployment wins. The console's Unknown Models report lists the PCs that got no exact pack.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Match,
        [string]$ComputerName,
        [string]$AnswerFile,
        [string]$Result
    )
    $dir = Join-Path (Join-Path $ContentRoot 'Reports') 'Drivers'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $serial = "$($Identity.Serial)" -replace '[\\/:*?"<>|\s]', '_'
    if (-not $serial.Trim('_')) { $serial = "$($Identity.Maker)-$($Identity.Model)" -replace '[\\/:*?"<>|\s]', '_' }
    [ordered]@{
        serial       = $Identity.Serial
        computerName = $ComputerName
        maker        = $Identity.Maker
        model        = $Identity.Model
        sku          = $Identity.Sku
        machineType  = $Identity.MachineType
        driverStatus = $Match.Status
        matchedBy    = $Match.MatchedBy
        driverPath   = $Match.Path
        answerFile   = $AnswerFile
        result       = $Result
        date         = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    } | ConvertTo-Json | Set-Content -Path (Join-Path $dir "$serial.json") -Encoding utf8
}

function Find-ContentRoot {
    # USB first: any volume labelled DEPLOY that holds an Images folder. Otherwise map the share from settings.
    param([string]$SettingsPath)
    foreach ($vol in Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -eq 'DEPLOY' }) {
        $root = "$($vol.DriveLetter):\"
        if (Test-Path (Join-Path $root 'Images')) { Write-DeployLog "Using USB content at $root"; return $root }
    }

    if (-not $SettingsPath -or -not (Test-Path $SettingsPath)) { throw 'No DEPLOY volume found and no settings file to locate a network share.' }
    $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    if (-not $settings.share.path) { throw 'No DEPLOY volume found and no share configured.' }

    Write-DeployLog "Waiting for network to reach $($settings.share.path)"
    Invoke-Native -FilePath 'wpeutil.exe' -ArgumentList @('WaitForNetwork')

    $cred = Get-ShareCredential -SettingsPath $SettingsPath
    Mount-NetworkShare -LocalName 'Z:' -RemoteName $settings.share.path -User $cred.User -Password $cred.Password
    Write-DeployLog "Using network content at Z:\"
    'Z:\'
}

function Mount-NetworkShare {
    # Maps a share with net use. With a user but no password, net use prompts for it on the console.
    param(
        [Parameter(Mandatory)][string]$LocalName,
        [Parameter(Mandatory)][string]$RemoteName,
        [string]$User,
        [string]$Password
    )
    $netArgs = @('use', $LocalName, $RemoteName)
    if ($User) { $netArgs += @("/user:$User", $(if ($Password) { $Password } else { '*' })) }
    # Log the command without the password.
    Write-DeployLog "Mapping $LocalName to $RemoteName$(if ($User) { " as $User" })"
    if ($User -and -not $Password) { & net.exe @netArgs }   # leave the console attached so the prompt shows
    else { & net.exe @netArgs 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "Could not map $RemoteName (net use exit code $LASTEXITCODE)." }
}

# Join account checks already made while WinPE runs (Test-JoinAccount), by domain, account and password hash.
$script:JoinChecks = @{}

function Get-NetUseErrorCode {
    # The Windows error number in net use's output: "System error 1326 has occurred." In another language, the first number.
    param([object[]]$Output = @())
    $text = (@($Output) | ForEach-Object { "$_" }) -join "`n"
    if ($text -match 'System error (\d+)') { return [int]$Matches[1] }
    if ($text -match '\b(\d{1,5})\b') { return [int]$Matches[1] }
    -1
}

function Get-JoinCheckResult {
    # What signing in with the join account returned (Test-JoinAccount). Refused only when the domain answered and
    # turned the account down; anything else (no network, DNS, NTLM blocked from WinPE) is NotChecked.
    param([int]$Code)
    $refused = @{
        1326 = 'wrong user name or password'
        1327 = 'the account may not sign in (account restriction)'
        1330 = 'its password has expired'
        1331 = 'the account is disabled'
        1793 = 'the account has expired'
        1907 = 'its password must be changed first'
        1909 = 'the account is locked out'
    }
    if ($Code -eq 0) { return [pscustomobject]@{ Result = 'Passed'; Code = 0; Reason = 'signed in' } }
    if ($refused.ContainsKey($Code)) { return [pscustomobject]@{ Result = 'Refused'; Code = $Code; Reason = $refused[$Code] } }
    $reason = if ($Code -in 53, 64, 67, 121, 1231, 1232, 1311, 1355) { 'could not reach the domain from WinPE (network or DNS)' }
              elseif ($Code -eq 1219) { 'WinPE is already connected to that server as another account' }
              elseif ($Code -eq 1937) { 'the domain does not accept NTLM sign-ins from WinPE' }
              elseif ($Code -lt 0) { 'net use gave no error number' }
              else { "net use error $Code" }
    [pscustomobject]@{ Result = 'NotChecked'; Code = $Code; Reason = $reason }
}

function Test-JoinAccount {
    <#
    .SYNOPSIS
        Signs in to the domain with the join account (net use \\<domain>\IPC$), so a wrong password shows in WinPE
        before the disk is wiped, not after the restart, when Windows tries it for 15 minutes and the PC stays out of
        the domain.
    .DESCRIPTION
        One sign-in per account and password while WinPE runs: Passed and Refused are kept, so pressing Next again
        costs no more failed logons (a domain may lock the account). NotChecked is tried again after a minute, in case
        the network came up late. Cached says the answer is a kept one. Never throws.
    #>
    param([Parameter(Mandatory)][string]$Domain, [Parameter(Mandatory)][string]$Account, [string]$Password, [string]$NetExe = 'net.exe')
    # Without a password net use would ask for one on the console and the deploy would hang.
    if (-not $Password) { return [pscustomobject]@{ Result = 'NotChecked'; Code = -1; Reason = 'the password file is empty'; Cached = $false } }
    # net use's error text on stderr must not become a terminating error before its exit code is read.
    $ErrorActionPreference = 'Continue'
    $sha = [Security.Cryptography.SHA256]::Create()
    $key = "$Domain|$Account|" + [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Password")))
    $kept = $script:JoinChecks[$key]
    if ($kept -and ($kept.Result -ne 'NotChecked' -or ((Get-Date) - $kept.Time).TotalSeconds -lt 60)) {
        return [pscustomobject]@{ Result = $kept.Result; Code = $kept.Code; Reason = $kept.Reason; Cached = $true }
    }
    $target = '\\' + $Domain + '\IPC$'
    $code = try {
        $out = @(& $NetExe use $target $Password "/user:$Account" /persistent:no 2>&1)
        if ($LASTEXITCODE -eq 0) { & $NetExe use $target /delete /y 2>&1 | Out-Null; 0 } else { Get-NetUseErrorCode -Output $out }
    } catch { Get-NetUseErrorCode -Output @($_.Exception.Message) }
    $r = Get-JoinCheckResult -Code $code
    $script:JoinChecks[$key] = [pscustomobject]@{ Result = $r.Result; Code = $r.Code; Reason = $r.Reason; Time = Get-Date }
    [pscustomobject]@{ Result = $r.Result; Code = $r.Code; Reason = $r.Reason; Cached = $false }
}

function Get-ShareCredential {
    # The share account from deploy-settings.json. The password file sits next to config\ on the media (X:\Deploy).
    param([Parameter(Mandatory)][string]$SettingsPath)
    $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    $password = $null
    if ($settings.share.user -and $settings.share.passwordFile) {
        $pwFile = Join-Path (Split-Path $SettingsPath -Parent | Split-Path -Parent) $settings.share.passwordFile
        if (Test-Path $pwFile) { $password = (Get-Content -Raw $pwFile).Trim() }
    }
    [pscustomobject]@{ User = $settings.share.user; Password = $password }
}

function Get-MulticastPlan {
    # Decides whether this deploy downloads the image by WDS multicast, and what to ask the server for.
    # Returns $null for a unicast deploy (multicast off, USB content, image outside the content root, split image),
    # otherwise the server, namespace and the image path relative to the content root (the namespace's folder).
    param(
        $Settings,                                  # deploy-settings.json object
        [Parameter(Mandatory)][string]$ContentRoot, # Z:\ for the share, D:\ for USB
        [Parameter(Mandatory)][string]$ImagePath,
        [bool]$IsNetworkRoot = $true
    )
    $mc = $Settings.multicast
    if (-not $mc -or -not $mc.enabled -or -not $IsNetworkRoot) { return $null }
    if ($ImagePath -like '*.swm') { return $null }
    $root = $ContentRoot.TrimEnd('\', '/') + '\'
    $image = $ImagePath -replace '/', '\'
    if (-not $image.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    # The transport server is the WDS server; failing that, the server that hosts the share.
    $server = "$($mc.server)".Trim()
    if (-not $server) { $server = "$($Settings.wds.server)".Trim() }
    if (-not $server -and "$($Settings.share.path)" -match '^\\\\([^\\]+)\\') { $server = $Matches[1] }
    if (-not $server) { return $null }
    [pscustomobject]@{
        Server     = $server
        Namespace  = $(if ("$($mc.namespace)".Trim()) { "$($mc.namespace)".Trim() } else { 'ImagingTool' })
        SourceFile = $image.Substring($root.Length)
        Fallback   = $(if ($null -eq $mc.fallback) { $true } else { [bool]$mc.fallback })
    }
}

function Receive-MulticastImage {
    # Downloads one file from a WDS multicast namespace with wdsmcast.exe (the WDS transport client in WinPE).
    # With a scheduled session it waits here until enough PCs have joined or the start time comes.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Destination,
        [string]$User,
        [string]$Password
    )
    $exe = @("$env:SystemRoot\System32\wdsmcast.exe", (Join-Path $PSScriptRoot 'Tools\wdsmcast.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw 'wdsmcast.exe is not in this WinPE image.' }
    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    $mcArgs = @('/Transfer-File', "/Server:$($Plan.Server)", "/Namespace:$($Plan.Namespace)",
        "/SourceFile:$($Plan.SourceFile)", "/DestinationFile:$Destination")
    if ($User) {
        $mcArgs += "/Username:$User"   # DOMAIN\user
        if ($Password) { $mcArgs += "/Password:$Password" }
    }
    # Log the command without the password; leave the console attached so the progress shows.
    Write-DeployLog "Multicast: $($Plan.SourceFile) from $($Plan.Server) namespace $($Plan.Namespace) to $Destination"
    & $exe @mcArgs
    if ($LASTEXITCODE -ne 0) { throw "wdsmcast exited with code $LASTEXITCODE" }
    if (-not (Test-Path $Destination)) { throw "wdsmcast finished but $Destination is missing" }
    $Destination
}

function Get-DiskConversionCommand {
    # The command that converts a VM disk file to a VHD Windows can mount, or $null when it is a VHD or VHDX already.
    # qemu-img converts qcow2, raw, vmdk and vdi. VirtualBox's VBoxManage converts vmdk and vdi.
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$QemuImg,
        [string]$VBoxManage
    )
    $ext = [IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
    if ($ext -in '.vhd', '.vhdx') { return $null }
    if ($QemuImg) { return @{ FilePath = $QemuImg; ArgumentList = @('convert', '-p', '-O', 'vpc', $SourcePath, $DestinationPath) } }
    if ($VBoxManage -and $ext -in '.vmdk', '.vdi') {
        return @{ FilePath = $VBoxManage; ArgumentList = @('clonemedium', 'disk', $SourcePath, $DestinationPath, '--format', 'VHD') }
    }
    throw "Cannot convert $(Split-Path $SourcePath -Leaf) to VHD. Install qemu-img (for qcow2, raw, vmdk and vdi) or VirtualBox (for vmdk and vdi)."
}

function Get-OfflineImageState {
    # What sysprep left in an offline Windows at $Root: ImageState from Windows\Setup\State\State.ini ($null when the
    # file is missing), whether that means generalized, and the last SYSPRP error line in the sysprep Panther log.
    # IMAGE_STATE_COMPLETE means sysprep never ran or failed; IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE means it finished.
    param([Parameter(Mandatory)][string]$Root)
    $state = $null
    $ini = Join-Path $Root 'Windows\Setup\State\State.ini'
    if (Test-Path -LiteralPath $ini) {
        $m = Select-String -LiteralPath $ini -Pattern '^\s*ImageState\s*=\s*(\S+)' | Select-Object -First 1
        $state = if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
    }
    $lastError = $null
    $errLog = Join-Path $Root 'Windows\System32\Sysprep\Panther\setuperr.log'
    if (Test-Path -LiteralPath $errLog) {
        $lastError = Select-String -LiteralPath $errLog -Pattern '\bSYSPRP\b' | Select-Object -Last 1 | ForEach-Object { $_.Line.Trim() }
    }
    [pscustomobject]@{
        Root        = $Root
        ImageState  = $state
        Generalized = ($null -eq $state) -or ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE')
        LastError   = $lastError
    }
}

Export-ModuleMember -Function Format-DriverProgressLine, Format-ConsoleText, Set-DeployConsole, Get-NativeProgress, Get-NativeLogLines, Get-AddDriverArgs, Get-WinPEDriverInfs, Import-WinPEDrivers, Format-WinPEDriverReport, Write-WinPEDriverReport, Get-DevicesWithoutDriver, Write-DeployLog, Invoke-Native, Invoke-NativeWithProgress, Get-HardwareIdentity, Test-UefiBoot, New-DiskpartScript, Find-DriverCatalogMatch, Resolve-DriverPack, Write-DriverReport,
    Find-ContentRoot, Mount-NetworkShare, Get-NetUseErrorCode, Get-JoinCheckResult, Test-JoinAccount, Get-ShareCredential, Get-MulticastPlan, Receive-MulticastImage, Get-DiskConversionCommand, Get-OfflineImageState,
    Select-WindowsBootEntry, Get-WindowsBootNextArgs, Set-WindowsBootNext, New-DeployedMarker, Find-UnstartedDeployment
