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
    # DISM on a French or German console PC: "Installation de 12 sur 76 - C:\...\x.inf", "12 von 76 - ...".
    if (-not $drivers.Count) { $drivers = [regex]::Matches($Text, '(?m)\b(\d+) \p{L}+ (\d+) - [^\r\n]*\.inf\b') }
    if ($drivers.Count) {
        $m = $drivers[$drivers.Count - 1]
        $n = [int]$m.Groups[1].Value; $total = [int]$m.Groups[2].Value
        if ($total -gt 0) {
            return [pscustomobject]@{ Percent = [int][Math]::Floor(100 * ($n - 1) / $total); Done = $n - 1; Total = $total }
        }
    }
    # qemu-img convert -p prints "    (45.00/100%)": the first number is the percent, not the 100.
    $qemu = [regex]::Matches($Text, '\((\d{1,3})(?:[.,]\d+)?/100%\)')
    if ($qemu.Count) {
        return [pscustomobject]@{ Percent = [Math]::Min(100, [int]$qemu[$qemu.Count - 1].Groups[1].Value); Done = $null; Total = $null }
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
    # Quoted when cmd would split or act on it: spaces, and & | < > ^ ( ) (an image description like "Office&Teams").
    $quoted = @($FilePath) + $ArgumentList | ForEach-Object { if ($_ -match '[\s&|<>^()]') { "`"$_`"" } else { $_ } }
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

# Bump when what goes into a cached WinPE build changes (components, how drivers are added), so old caches are not reused.
$script:WinPEBuildCacheFormat = 1

function Get-WinPEDriverPlan {
    <#
    .SYNOPSIS
        The .inf files each WinPE driver source adds to boot.wim (Get-WinPEDriverInfs), each with a key
        "name|SHA256". The same driver in a second source (Intel NICs and RST are in Dell's and HP's packs) is
        marked Duplicate, so it goes in once. The keys also make the WinPE build cache key.
    #>
    param([object[]]$Sources)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    @(foreach ($src in @($Sources | Where-Object { $_ })) {
        $infs = @(foreach ($inf in @(Get-WinPEDriverInfs -Folder $src.Path)) {
            $key = '{0}|{1}' -f $inf.Name, (Get-FileHash -LiteralPath $inf.FullName -Algorithm SHA256).Hash
            [pscustomobject]@{ File = $inf; Key = $key; Duplicate = -not $seen.Add($key) }
        })
        [pscustomobject]@{ Name = $src.Name; Path = $src.Path; Infs = $infs }
    })
}

function New-WinPEDriverStaging {
    <#
    .SYNOPSIS
        Copies every driver of a Get-WinPEDriverPlan that goes into boot.wim (x64 only, each driver once) into one
        folder, so a single DISM /Add-Driver /Recurse adds them all in one servicing session. One Add-WindowsDriver
        call per driver opens and closes the image's registry each time: about 10 seconds a driver, 45 minutes for
        Dell's and HP's WinPE packs. Each source gets its own numbered subfolder with its folder layout (a driver's
        .sys and .cat files sit next to its .inf or below it). Other .inf files there (duplicates, x86) are left out,
        so DISM only sees the ones the plan picked.
        Returns one row per staged .inf: SourceIndex (0-based, in plan order), Name, Staged path.
    #>
    param([object[]]$Plan, [Parameter(Mandatory)][string]$Destination)
    # Remove-Item -Force: driver files out of a vendor cab are often read-only, which Directory.Delete refuses.
    if ([IO.Directory]::Exists($Destination)) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    [void][IO.Directory]::CreateDirectory($Destination)
    $sep = [IO.Path]::DirectorySeparatorChar
    $rows = New-Object System.Collections.ArrayList
    $plan = @($Plan | Where-Object { $_ })
    for ($n = 0; $n -lt $plan.Count; $n++) {
        $src = $plan[$n]
        $keep = @($src.Infs | Where-Object { -not $_.Duplicate })
        if (-not $keep) { continue }
        $base = (Resolve-Path -LiteralPath $src.Path).ProviderPath.TrimEnd('\', '/')
        $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $keep) { [void]$wanted.Add($k.File.FullName) }
        # Each driver's folder once, and not a folder that is inside one already taken.
        $top = New-Object System.Collections.ArrayList
        foreach ($d in @($keep | ForEach-Object { $_.File.DirectoryName.TrimEnd('\', '/') } | Sort-Object -Unique)) {
            $inside = $false
            foreach ($t in $top) { if ($d -ieq $t -or $d.StartsWith("$t$sep", [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break } }
            if (-not $inside) { [void]$top.Add($d) }
        }
        foreach ($d in $top) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -File -Force)) {
                $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/')
                if ($f.Extension -ieq '.inf' -and -not $wanted.Contains($f.FullName)) { continue }
                $target = [IO.Path]::Combine($Destination, "$($n + 1)", $rel)
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.File]::Copy($f.FullName, $target, $true)
                if ($f.Extension -ieq '.inf') { [void]$rows.Add([pscustomobject]@{ SourceIndex = $n; Name = $f.Name; Staged = $target }) }
            }
        }
    }
    @($rows)
}

function Get-WinPEDriverResults {
    <#
    .SYNOPSIS
        The WinPE driver report (one entry per plan source: name, added, failed, vmd) after one DISM run over the
        New-WinPEDriverStaging folder. InstalledNames are the .inf names of the drivers now in the image
        (Get-WindowsDriver's OriginalFileName), so it works whatever language DISM prints in. Without them
        (Get-WindowsDriver failed), ExitCode 0 counts every staged driver as added.
    #>
    param([object[]]$Plan, [object[]]$Staged, [string[]]$InstalledNames, [int]$ExitCode = 0)
    $left = @{}
    $known = $PSBoundParameters.ContainsKey('InstalledNames') -and $null -ne $InstalledNames
    foreach ($i in @($InstalledNames | Where-Object { $_ })) { $k = "$i".ToLowerInvariant(); $left[$k] = 1 + [int]$left[$k] }
    $plan = @($Plan | Where-Object { $_ })
    @(for ($n = 0; $n -lt $plan.Count; $n++) {
        $added = @(); $failed = @()
        foreach ($r in @($Staged | Where-Object { $_.SourceIndex -eq $n })) {
            $k = $r.Name.ToLowerInvariant()
            $ok = if ($known) { [int]$left[$k] -gt 0 } else { $ExitCode -eq 0 }
            if ($ok) { if ($known) { $left[$k]-- }; $added += $r.Name } else { $failed += $r.Name }
        }
        [ordered]@{ name = $plan[$n].Name; added = $added.Count; failed = @($failed)
            vmd = @($added | Where-Object { $_ -match '^(iaStorVD|iaStorAC|iaStorAVC|iaVROC|iaStorE)\.inf$' } | Select-Object -Unique) }
    })
}

function Get-WinPEBuildKey {
    <#
    .SYNOPSIS
        A key for boot.wim with its optional components and WinPE drivers in: the same key means the same result,
        so a build can reuse it instead of adding them again (minutes of DISM calls). It changes with the ADK's
        WinPE (copype's boot.wim size and date), the component list, and any driver source or .inf file.
    #>
    param([Parameter(Mandatory)][string]$BaseWim, [string[]]$Components, [object[]]$DriverPlan)
    $wim = Get-Item -LiteralPath $BaseWim
    $lines = @("format=$script:WinPEBuildCacheFormat", "wim=$($wim.Length)|$($wim.LastWriteTimeUtc.Ticks)", "components=$(@($Components) -join ',')")
    foreach ($s in @($DriverPlan)) {
        $lines += "source=$($s.Name)|$($s.Path)"
        foreach ($i in @($s.Infs)) { $lines += "inf=$($i.Key)" }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))) } finally { $sha.Dispose() }
    (-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function Get-WinPEBuildCacheDir {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::Combine($HOME, '.cache') }
    [IO.Path]::Combine($base, 'ImagingConsole', 'WinPEBuilds')
}

function Find-WinPEBuildCache {
    # The cached boot.wim for Key and the driver report saved with it; $null when there is none.
    param([Parameter(Mandatory)][string]$Key, [string]$CacheDir = (Get-WinPEBuildCacheDir))
    $dir = [IO.Path]::Combine($CacheDir, $Key)
    $wim = [IO.Path]::Combine($dir, 'boot.wim')
    $json = [IO.Path]::Combine($dir, 'build.json')
    if (-not ([IO.File]::Exists($wim) -and [IO.File]::Exists($json))) { return $null }
    try { $info = [IO.File]::ReadAllText($json) | ConvertFrom-Json } catch { return $null }
    [pscustomobject]@{ Wim = $wim; Built = $info.built; Sources = @($info.sources | Where-Object { $_ }) }
}

function Save-WinPEBuildCache {
    <#
    .SYNOPSIS
        Keeps a copy of boot.wim (components and drivers in, nothing else) and its driver report under Key, and
        deletes all but the newest Keep builds: each one is a few hundred MB.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$WimPath,
        [object[]]$Sources,
        [string]$CacheDir = (Get-WinPEBuildCacheDir),
        [int]$Keep = 2
    )
    $dir = [IO.Path]::Combine($CacheDir, $Key)
    $staging = "$dir.new"
    if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
    [void][IO.Directory]::CreateDirectory($staging)
    [IO.File]::Copy($WimPath, [IO.Path]::Combine($staging, 'boot.wim'))
    $info = [ordered]@{ built = (Get-Date).ToString('yyyy-MM-dd HH:mm'); sources = @($Sources) }
    [IO.File]::WriteAllText([IO.Path]::Combine($staging, 'build.json'), (ConvertTo-Json -InputObject $info -Depth 4))
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    [IO.Directory]::Move($staging, $dir)
    # The JSON marks a finished build; a folder without one (a build stopped halfway) is removed too.
    $old = @(Get-ChildItem -LiteralPath $CacheDir -Directory | Where-Object { $_.FullName -ne (Get-Item -LiteralPath $dir).FullName } |
        Sort-Object @{ Expression = { $j = [IO.Path]::Combine($_.FullName, 'build.json'); if ([IO.File]::Exists($j)) { [IO.File]::GetLastWriteTimeUtc($j) } else { [DateTime]::MinValue } }; Descending = $true })
    $old | Select-Object -Skip ([Math]::Max(0, $Keep - 1)) | ForEach-Object { try { [IO.Directory]::Delete($_.FullName, $true) } catch { } }
    $dir
}

function Get-WinPEPackCopyPlan {
    <#
    .SYNOPSIS
        A Get-MediaCopyPlan-shaped plan that puts a vendor WinPE driver pack on the stick under
        Drivers\_WinPE\<pack folder>, for drvload when boot.wim lacks a driver. The x86 and arm64 folders are left
        out: WinPE is x64 and Get-WinPEDriverInfs never loads them, and they are about half the files.
    #>
    param([Parameter(Mandatory)][string]$PackPath, [string]$Under = 'Drivers\_WinPE')
    $base = (Get-Item -LiteralPath $PackPath).FullName.TrimEnd('\', '/')
    $prefix = "$($Under.Trim('\'))\$(Split-Path $base -Leaf)"
    $items = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    [void]$dirs.Add($prefix)
    $skip = '(^|[\\/])(x86|arm64)([\\/]|$)'
    foreach ($d in Get-ChildItem -LiteralPath $base -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName) {
        $rel = $d.FullName.Substring($base.Length + 1)
        if ($rel -notmatch $skip) { [void]$dirs.Add("$prefix\$($rel -replace '/', '\')") }
    }
    $total = [int64]0
    foreach ($f in Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName) {
        $rel = $f.FullName.Substring($base.Length + 1)
        if ($rel -match $skip) { continue }
        [void]$items.Add([pscustomobject]@{ Relative = "$prefix\$($rel -replace '/', '\')"; Source = $f.FullName; Length = [int64]$f.Length })
        $total += $f.Length
    }
    [pscustomobject]@{ Items = @($items); Directories = @($dirs); TotalBytes = $total; FileCount = $items.Count; Missing = @() }
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
    # Written to <Windows drive>\Temp\deployed.json after a deployment; FirstBoot.ps1 deletes it once Windows runs.
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
        Looks on this PC's volumes for a Windows this tool deployed that has never started (\Temp\deployed.json, or \Deploy\deployed.json from older versions,
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
        # .NET calls, not Join-Path/Test-Path/Get-Content: a volume PowerShell has no drive for (the old Windows
        # partition at C: on a BitLocker or not-yet-ready disk) makes those throw "A drive with the name 'C' does
        # not exist", which stopped the deploy before the wizard opened.
        foreach ($folder in 'Temp', 'Deploy') {
            try {
                $path = [IO.Path]::Combine($r, $folder, 'deployed.json')
                if (-not [IO.File]::Exists($path)) { continue }
                $m = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            } catch { continue }
            if ("$($m.serial)" -eq $Serial) {
                $m | Add-Member -NotePropertyName path -NotePropertyValue $path -Force
                return $m
            }
        }
    }
    $null
}

function New-DiskpartScript {
    # Wipes the disk and creates Microsoft's recommended UEFI layout: GPT with EFI (S:), MSR, Windows (W:), Recovery.
    param([Parameter(Mandatory)][int]$DiskNumber)
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
}

function Test-CatalogIdMatch {
    # Whether a catalog entry's sku or machineType (one value, or several split by commas or semicolons) holds $Value.
    param($List, $Value)
    if (-not "$List".Trim() -or -not "$Value".Trim()) { return $false }
    @("$List" -split '\s*[,;]\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -contains "$Value".Trim()
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
    # sku and machineType may list several values ("0B0B, 0C1D"): a downloaded pack is one entry for all its IDs.
    $match = $mine | Where-Object { Test-CatalogIdMatch $_.sku $Identity.Sku } | Select-Object -First 1
    if (-not $match) { $by = 'machineType';  $match = $mine | Where-Object { Test-CatalogIdMatch $_.machineType $Identity.MachineType } | Select-Object -First 1 }
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
    # Vault: the password files the WinPE password unlocked (SecretVault.psm1), for the share account.
    # Decrypt: turns the share password the build encrypted in the settings into text (Get-ShareCredential).
    param([string]$SettingsPath, [hashtable]$Vault = @{}, [scriptblock]$Decrypt)
    foreach ($vol in Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -eq 'DEPLOY' }) {
        $root = "$($vol.DriveLetter):\"
        # .NET, not Test-Path/Join-Path: a volume PowerShell has no drive for makes those fail in WinPE.
        if ([IO.Directory]::Exists([IO.Path]::Combine($root, 'Images'))) { Write-DeployLog "Using USB content at $root"; return $root }
    }

    if (-not $SettingsPath -or -not (Test-Path $SettingsPath)) { throw 'No DEPLOY volume found and no settings file to locate a network share.' }
    $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    if (-not $settings.share.path) { throw 'No DEPLOY volume found and no share configured.' }

    Write-DeployLog "Waiting for network to reach $($settings.share.path)"
    Invoke-Native -FilePath 'wpeutil.exe' -ArgumentList @('WaitForNetwork')

    $cred = Get-ShareCredential -SettingsPath $SettingsPath -Vault $Vault -Decrypt $Decrypt
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
    # Without the file, the vault the WinPE password unlocked (keys as SecretVault's ConvertTo-SecretKey writes them),
    # then share.encryptedPassword, which the build writes into the boot image's settings and Decrypt turns into text.
    param([Parameter(Mandatory)][string]$SettingsPath, [hashtable]$Vault = @{}, [scriptblock]$Decrypt)
    $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    $password = $null
    if ($settings.share.user -and $settings.share.passwordFile) {
        $pwFile = Join-Path (Split-Path $SettingsPath -Parent | Split-Path -Parent) $settings.share.passwordFile
        $key = ($settings.share.passwordFile -replace '/', '\').Trim().TrimStart('.', '\').ToLowerInvariant()
        if (Test-Path $pwFile) { $password = (Get-Content -Raw $pwFile).Trim() }
        elseif ($Vault -and $Vault.ContainsKey($key)) { $password = $Vault[$key] }
        elseif ($Decrypt -and $settings.share.PSObject.Properties['encryptedPassword'] -and $settings.share.encryptedPassword) {
            try { $password = & $Decrypt "$($settings.share.encryptedPassword)" }
            catch { Write-DeployLog "Share account password in the boot image not usable: $($_.Exception.Message)" -Level WARN }
        }
    }
    [pscustomobject]@{ User = $settings.share.user; Password = $password }
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
    # .NET calls, not Join-Path/Test-Path/Select-String: in WinPE a volume can have no PowerShell drive.
    param([Parameter(Mandatory)][string]$Root)
    $sep = [IO.Path]::DirectorySeparatorChar
    $state = $null
    $ini = [IO.Path]::Combine($Root, ('Windows\Setup\State\State.ini' -replace '\\', $sep))
    if ([IO.File]::Exists($ini)) {
        $m = @([IO.File]::ReadAllLines($ini) | Where-Object { $_ -match '^\s*ImageState\s*=\s*(\S+)' } | Select-Object -First 1)
        $state = if ($m -and $m[0] -match '^\s*ImageState\s*=\s*(\S+)') { $Matches[1] } else { '' }
    }
    $lastError = $null
    $errLog = [IO.Path]::Combine($Root, ('Windows\System32\Sysprep\Panther\setuperr.log' -replace '\\', $sep))
    if ([IO.File]::Exists($errLog)) {
        $lastError = [IO.File]::ReadAllLines($errLog) | Where-Object { $_ -match '\bSYSPRP\b' } | Select-Object -Last 1 | ForEach-Object { $_.Trim() }
    }
    [pscustomobject]@{
        Root        = $Root
        ImageState  = $state
        Generalized = ($null -eq $state) -or ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE')
        LastError   = $lastError
    }
}

Export-ModuleMember -Function Format-DriverProgressLine, Get-WinPEDriverPlan, New-WinPEDriverStaging, Get-WinPEDriverResults, Get-WinPEBuildKey, Get-WinPEBuildCacheDir, Find-WinPEBuildCache, Save-WinPEBuildCache, Get-WinPEPackCopyPlan, Format-ConsoleText, Set-DeployConsole, Get-NativeProgress, Get-NativeLogLines, Read-SharedText, Get-AddDriverArgs, Get-WinPEDriverInfs, Import-WinPEDrivers, Format-WinPEDriverReport, Write-WinPEDriverReport, Get-DevicesWithoutDriver, Write-DeployLog, Invoke-Native, Invoke-NativeWithProgress, Get-HardwareIdentity, Test-UefiBoot, New-DiskpartScript, Find-DriverCatalogMatch, Resolve-DriverPack, Write-DriverReport,
    Find-ContentRoot, Mount-NetworkShare, Get-NetUseErrorCode, Get-JoinCheckResult, Test-JoinAccount, Get-ShareCredential, Get-DiskConversionCommand, Get-OfflineImageState,
    Select-WindowsBootEntry, Get-WindowsBootNextArgs, Set-WindowsBootNext, New-DeployedMarker, Find-UnstartedDeployment
