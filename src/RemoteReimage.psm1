# Remote reimaging: Wake-on-LAN, a one-time network boot on running PCs, and reimage jobs on the content root.
# Used by the console, Start-RemoteReimage.ps1 and, in WinPE, Deploy-Image.ps1 (to pick up a job).
#
# Content root layout:
#   Computers\<MAC>.json         one known PC: name, mac, address, group, relay, model, serial, last deploy
#   Reimage\<MAC>.json           a pending job: answer file, name to keep, expiry
#   Reimage\Started\<MAC>_<time>.json   jobs that WinPE picked up
# <MAC> is the 12 hex digits without separators, e.g. 00155D0A1B2C.

function Join-RootPath {
    # Paths use backslashes (they are read in WinPE); normalize so the module also runs in tests off Windows.
    param([string]$Root, [string]$Child)
    Join-Path $Root ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
}

#region MAC addresses and Wake-on-LAN

function ConvertTo-MacKey {
    # Accepts 00:15:5D:0A:1B:2C, 00-15-5d-0a-1b-2c, 0015.5d0a.1b2c or 00155D0A1B2C; returns 00155D0A1B2C.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Mac)
    $hex = ($Mac.Trim() -replace '[:\-\.\s]', '').ToUpperInvariant()
    if ($hex -notmatch '^[0-9A-F]{12}$') { throw "'$Mac' is not a MAC address (12 hex digits, e.g. 00-15-5D-0A-1B-2C)." }
    $hex
}

function Format-MacAddress {
    # 00155D0A1B2C -> 00-15-5D-0A-1B-2C, the form Windows shows and WDS accepts.
    param([Parameter(Mandatory)][string]$Mac)
    (ConvertTo-MacKey $Mac) -replace '(..)(?!$)', '$1-'
}

function New-MagicPacket {
    # Six 0xFF bytes, then the MAC sixteen times: 102 bytes.
    param([Parameter(Mandatory)][string]$Mac)
    $key = ConvertTo-MacKey $Mac
    $macBytes = [byte[]](0..5 | ForEach-Object { [Convert]::ToByte($key.Substring($_ * 2, 2), 16) })
    $packet = [byte[]]::new(102)
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
    for ($r = 0; $r -lt 16; $r++) { [Array]::Copy($macBytes, 0, $packet, 6 + $r * 6, 6) }
    , $packet
}

function Get-BroadcastAddress {
    # Directed broadcast for a subnet: 10.1.20.37/24 -> 10.1.20.255. Routers forward it only if configured to.
    param([Parameter(Mandatory)][string]$IPAddress, [Parameter(Mandatory)][ValidateRange(0, 32)][int]$PrefixLength)
    $bytes = ([Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
    if ($bytes.Count -ne 4) { throw "Only IPv4 addresses have a broadcast address ($IPAddress)." }
    [Array]::Reverse($bytes)
    $ip = [BitConverter]::ToUInt32($bytes, 0)
    $hostMask = if ($PrefixLength -eq 0) { [uint32]::MaxValue } else { [uint32]([math]::Pow(2, 32 - $PrefixLength) - 1) }
    $out = [BitConverter]::GetBytes([uint32]($ip -bor $hostMask))
    [Array]::Reverse($out)
    ([Net.IPAddress]::new($out)).ToString()
}

function Get-WakeTargets {
    # Where to send a PC's magic packet: the local broadcast, plus its subnet's directed broadcast when its IP is known.
    param([Parameter(Mandatory)]$Computer)
    $targets = [Collections.Generic.List[string]]::new()
    $targets.Add('255.255.255.255')
    if ($Computer.ip -and $Computer.prefixLength) {
        try { $targets.Add((Get-BroadcastAddress -IPAddress $Computer.ip -PrefixLength $Computer.prefixLength)) } catch { }
    }
    @($targets | Select-Object -Unique)
}

function Send-MagicPacket {
    # Sends the packet from this PC to each broadcast address, three times each (UDP can drop).
    param([Parameter(Mandatory)][string]$Mac, [string[]]$Broadcast = @('255.255.255.255'), [int]$Port = 9)
    $packet = New-MagicPacket $Mac
    $udp = [Net.Sockets.UdpClient]::new()
    try {
        $udp.EnableBroadcast = $true
        foreach ($b in $Broadcast) {
            $ep = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($b), $Port)
            for ($i = 0; $i -lt 3; $i++) { [void]$udp.Send($packet, $packet.Length, $ep) }
        }
    } finally { $udp.Close() }
}

function Send-WakeOnLan {
    # Wakes one PC. With a relay (a PC that is on in the same subnet), the relay also sends it locally,
    # which works when routers drop directed broadcasts.
    param([Parameter(Mandatory)]$Computer, [int]$Port = 9)
    Send-MagicPacket -Mac $Computer.mac -Broadcast (Get-WakeTargets $Computer) -Port $Port
    if ($Computer.relay) {
        $packet = New-MagicPacket $Computer.mac
        Invoke-Command -ComputerName $Computer.relay -ErrorAction Stop -ArgumentList $packet, $Port -ScriptBlock {
            param([byte[]]$Packet, [int]$Port)
            $udp = [Net.Sockets.UdpClient]::new()
            try {
                $udp.EnableBroadcast = $true
                $ep = [Net.IPEndPoint]::new([Net.IPAddress]::Broadcast, $Port)
                for ($i = 0; $i -lt 3; $i++) { [void]$udp.Send($Packet, $Packet.Length, $ep) }
            } finally { $udp.Close() }
        }
    }
}

#endregion

#region One-time network boot

function Select-PxeBootEntry {
    # Picks the firmware network boot entry from `bcdedit /enum firmware` output. Returns its {GUID} or $null.
    # bcdedit's labels are localized (identifier / identificateur), so this reads only the GUID and the
    # firmware's own description: blocks are split on the dashed lines, and IPv4 entries win over IPv6.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BcdText)
    $blocks = $BcdText -split '(?m)^-{5,}\s*$'
    $candidates = foreach ($b in $blocks) {
        $guid = [regex]::Match($b, '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}')
        if (-not $guid.Success) { continue }
        # Only the first line holds the entry's own identifier; the boot manager block lists others in displayorder.
        $firstLine = ($b.Trim() -split "`r?`n")[0]
        if ($firstLine -notmatch [regex]::Escape($guid.Value)) { continue }
        # \u00e9 (e acute) is escaped to keep this file ASCII: Windows PowerShell 5.1 reads a file without a BOM as ANSI.
        if ($b -notmatch '(?i)\b(PXE|IPv4|IPv6|Network|NIC|LAN|Ethernet|R[\u00e9e]seau)\b') { continue }
        $rank = if ($b -match '(?i)IPv6') { 2 } else { 1 }
        [pscustomobject]@{ Id = $guid.Value; Rank = $rank }
    }
    $best = @($candidates | Sort-Object Rank | Select-Object -First 1)
    if ($best) { $best[0].Id } else { $null }
}

$script:RemoteInfoScript = {
    # Runs on the target PC: firmware type, firmware boot entries and the wired adapters.
    $adapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' | Where-Object MACAddress | ForEach-Object {
        $i = [array]::IndexOf(@($_.IPAddress), (@($_.IPAddress) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1))
        [pscustomobject]@{
            Mac    = $_.MACAddress
            IP     = if ($i -ge 0) { @($_.IPAddress)[$i] } else { $null }
            Mask   = if ($i -ge 0) { @($_.IPSubnet)[$i] } else { $null }
            Name   = $_.Description
        }
    })
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Firmware     = $env:firmware_type
        BcdText      = if ($env:firmware_type -eq 'UEFI') { (& bcdedit.exe /enum firmware) -join "`n" } else { '' }
        Adapters     = $adapters
        Model        = (Get-CimInstance Win32_ComputerSystem).Model
        Serial       = (Get-CimInstance Win32_BIOS).SerialNumber
    }
}

function Get-PrefixLength {
    # 255.255.255.0 -> 24
    param([Parameter(Mandatory)][string]$Mask)
    $bits = (([Net.IPAddress]::Parse($Mask)).GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2) }) -join ''
    ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Get-RemoteComputerInfo {
    # Reads a running PC over PowerShell remoting (WinRM). Needs admin rights on it.
    param([Parameter(Mandatory)][string]$ComputerName)
    Invoke-Command -ComputerName $ComputerName -ScriptBlock $script:RemoteInfoScript -ErrorAction Stop
}

function Invoke-PxeRestart {
    # Sets the firmware's next boot (one time only) to the network entry, then restarts the PC.
    # Later boots use the normal order again, so the PC cannot loop back into the deploy.
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [int]$DelaySeconds = 30,
        [string]$Message = 'This PC is being reimaged by IT. Save your work: it restarts shortly.'
    )
    $info = Get-RemoteComputerInfo -ComputerName $ComputerName
    if ($info.Firmware -ne 'UEFI') {
        throw "$ComputerName boots in legacy BIOS mode; set network boot first in its BIOS boot order instead."
    }
    $entry = Select-PxeBootEntry -BcdText $info.BcdText
    if (-not $entry) {
        throw "$ComputerName has no network boot entry. Enable the UEFI network stack (PXE) in its BIOS settings."
    }
    Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ArgumentList $entry, $DelaySeconds, $Message -ScriptBlock {
        param($Entry, $Delay, $Message)
        & bcdedit.exe /set '{fwbootmgr}' bootsequence $Entry | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bcdedit could not set the next boot to $Entry (exit $LASTEXITCODE)." }
        # /d p:4:1 = planned, application installation. A delay over 0 also forces apps to close.
        & shutdown.exe /r /t $Delay /c $Message /d p:4:1
        if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed (exit $LASTEXITCODE)." }
    }
    [pscustomobject]@{ ComputerName = $ComputerName; BootEntry = $entry; Info = $info }
}

function Test-WinRMReachable {
    # Which of these hosts answer on the WinRM port, checked in parallel. Ping is often blocked by Windows Firewall.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ComputerName, [int]$TimeoutMs = 1500, [int]$Port = 5985)
    $checks = foreach ($c in $ComputerName) {
        $tcp = [Net.Sockets.TcpClient]::new()
        [pscustomobject]@{ Name = $c; Client = $tcp; Task = $(try { $tcp.ConnectAsync($c, $Port) } catch { $null }) }
    }
    $tasks = @($checks | Where-Object Task | ForEach-Object Task)
    if ($tasks) { try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, $TimeoutMs) } catch { } }
    $result = @{}
    foreach ($c in $checks) {
        $result[$c.Name] = [bool]($c.Task -and $c.Task.Status -eq 'RanToCompletion' -and $c.Client.Connected)
        $c.Client.Close()
    }
    $result
}

#endregion

#region Known computers

function Get-ComputerFolder { param([string]$ContentRoot) Join-RootPath $ContentRoot 'Computers' }

function Get-KnownComputers {
    param([Parameter(Mandatory)][string]$ContentRoot)
    Get-ChildItem -Path (Get-ComputerFolder $ContentRoot) -Filter *.json -File -ErrorAction SilentlyContinue |
        ForEach-Object { try { Get-Content -Raw $_.FullName | ConvertFrom-Json } catch { } } |
        Sort-Object group, name
}

function Get-KnownComputer {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Mac)
    $path = Join-Path (Get-ComputerFolder $ContentRoot) "$(ConvertTo-MacKey $Mac).json"
    if (Test-Path $path) { Get-Content -Raw $path | ConvertFrom-Json }
}

function Save-KnownComputer {
    # Adds or updates one PC. Only the fields given are changed, so the console, a CSV import
    # and the deploy can each fill in what they know.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Mac,
        [hashtable]$Fields = @{}
    )
    $key = ConvertTo-MacKey $Mac
    $dir = Get-ComputerFolder $ContentRoot
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir "$key.json"
    $pc = [ordered]@{ name = ''; mac = (Format-MacAddress $key); address = ''; group = ''; relay = ''; ip = ''; prefixLength = 0;
                      maker = ''; model = ''; serial = ''; lastDeployed = ''; lastResult = ''; lastAnswerFile = '' }
    if (Test-Path $path) {
        $old = Get-Content -Raw $path | ConvertFrom-Json
        foreach ($p in $old.PSObject.Properties) { $pc[$p.Name] = $p.Value }
    }
    foreach ($k in $Fields.Keys) { if ($null -ne $Fields[$k]) { $pc[$k] = $Fields[$k] } }
    if ($pc.name) { $pc.name = "$($pc.name)".Trim().ToUpperInvariant() }
    [pscustomobject]$pc | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
    [pscustomobject]$pc
}

function Remove-KnownComputer {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Mac)
    $key = ConvertTo-MacKey $Mac
    Remove-Item (Join-Path (Get-ComputerFolder $ContentRoot) "$key.json") -ErrorAction SilentlyContinue
    Remove-Item (Join-RootPath $ContentRoot "Reimage\$key.json") -ErrorAction SilentlyContinue
}

function Import-KnownComputerCsv {
    # CSV with a header row: Name and MAC are required; Address, Group and Relay are optional.
    # Commas or semicolons (French Excel) both work. Returns how many rows were added and the rows it skipped.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Path)
    $first = Get-Content -Path $Path -TotalCount 1
    $delim = if ($first -and ($first.Split(';').Count -gt $first.Split(',').Count)) { ';' } else { ',' }
    $added = 0
    $skipped = [Collections.Generic.List[string]]::new()
    $line = 1
    foreach ($row in Import-Csv -Path $Path -Delimiter $delim) {
        $line++
        $get = { param($n) $p = $row.PSObject.Properties | Where-Object { $_.Name.Trim() -eq $n } | Select-Object -First 1; if ($p) { "$($p.Value)".Trim() } else { '' } }
        $name = & $get 'Name'; $mac = & $get 'MAC'
        if (-not $name -or -not $mac) { $skipped.Add("line ${line}: Name and MAC are required"); continue }
        try { [void](ConvertTo-MacKey $mac) } catch { $skipped.Add("line ${line}: $($_.Exception.Message)"); continue }
        $fields = @{ name = $name }
        foreach ($col in 'Address', 'Group', 'Relay') { $v = & $get $col; if ($v) { $fields[$col.ToLowerInvariant()] = $v } }
        [void](Save-KnownComputer -ContentRoot $ContentRoot -Mac $mac -Fields $fields)
        $added++
    }
    [pscustomobject]@{ Added = $added; Skipped = @($skipped) }
}

function Update-KnownComputerFromInfo {
    # Records what Get-RemoteComputerInfo found: the wired adapter's MAC and IP, model and serial.
    # Returns the saved PC, keyed by the adapter whose IP matches how we reached it (or the first one).
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Info, $Existing)
    $adapters = @($Info.Adapters | Where-Object Mac)
    if (-not $adapters) { throw "$($Info.ComputerName) reported no network adapter with an IP address." }
    $pick = $null
    if ($Existing -and $Existing.mac) { $pick = $adapters | Where-Object { (ConvertTo-MacKey $_.Mac) -eq (ConvertTo-MacKey $Existing.mac) } | Select-Object -First 1 }
    if (-not $pick) { $pick = $adapters | Where-Object { $_.Name -notmatch '(?i)wi-?fi|wireless|802\.11|virtual|vpn|bluetooth' } | Select-Object -First 1 }
    if (-not $pick) { $pick = $adapters[0] }
    $fields = @{ name = $(if ($Existing -and $Existing.name) { $Existing.name } else { $Info.ComputerName }); model = "$($Info.Model)".Trim(); serial = "$($Info.Serial)".Trim() }
    if ($pick.IP) { $fields.ip = $pick.IP }
    if ($pick.Mask) { $fields.prefixLength = Get-PrefixLength $pick.Mask }
    Save-KnownComputer -ContentRoot $ContentRoot -Mac $pick.Mac -Fields $fields
}

#endregion

#region Reimage jobs

function Get-JobFolder { param([string]$ContentRoot) Join-RootPath $ContentRoot 'Reimage' }

function New-ReimageJob {
    # Queues a reimage for one PC. WinPE picks it up by MAC, uses its answer file without asking, and
    # removes it, so a later network boot does not reimage the PC again. Jobs expire after some hours.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Mac,
        [Parameter(Mandatory)][string]$AnswerFile,
        [string]$ComputerName,          # keep this name instead of the answer file's naming
        [int]$ExpiresHours = 12,
        [datetime]$Now = (Get-Date)
    )
    if (-not (Test-Path (Join-RootPath $ContentRoot "AnswerFiles\$AnswerFile.xml"))) { throw "No answer file named $AnswerFile." }
    $key = ConvertTo-MacKey $Mac
    $dir = Get-JobFolder $ContentRoot
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $job = [pscustomobject][ordered]@{
        mac          = Format-MacAddress $key
        answerFile   = $AnswerFile
        computerName = $ComputerName
        requestedBy  = "$env:USERDOMAIN\$env:USERNAME".Trim('\')
        requestedAt  = $Now.ToString('o')
        expiresAt    = $Now.AddHours($ExpiresHours).ToString('o')
    }
    $job | ConvertTo-Json | Set-Content -Path (Join-Path $dir "$key.json") -Encoding utf8
    $job
}

function Test-JobExpired {
    param([Parameter(Mandatory)]$Job, [datetime]$Now = (Get-Date))
    [datetime]::Parse($Job.expiresAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) -lt $Now
}

function Get-ReimageJob {
    # The pending job for a PC, or $null.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Mac)
    $path = Join-Path (Get-JobFolder $ContentRoot) "$(ConvertTo-MacKey $Mac).json"
    if (Test-Path $path) { Get-Content -Raw $path | ConvertFrom-Json }
}

function Remove-ReimageJob {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Mac)
    Remove-Item (Join-Path (Get-JobFolder $ContentRoot) "$(ConvertTo-MacKey $Mac).json") -ErrorAction SilentlyContinue
}

function Receive-ReimageJob {
    # In WinPE: takes the job for any of this PC's MACs, if one is waiting and not expired.
    # Moving it to Reimage\Started is what tells Start-RemoteReimage.ps1 the deploy began.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Mac, [datetime]$Now = (Get-Date))
    $dir = Get-JobFolder $ContentRoot
    foreach ($m in $Mac) {
        $key = try { ConvertTo-MacKey $m } catch { continue }
        $path = Join-Path $dir "$key.json"
        if (-not (Test-Path $path)) { continue }
        $job = Get-Content -Raw $path | ConvertFrom-Json
        if (Test-JobExpired -Job $job -Now $Now) { continue }
        $job | Add-Member -NotePropertyName startedAt -NotePropertyValue $Now.ToString('o') -Force
        $started = Join-RootPath $dir 'Started'
        New-Item -ItemType Directory -Path $started -Force | Out-Null
        $job | ConvertTo-Json | Set-Content -Path (Join-Path $started ("{0}_{1:yyyyMMdd-HHmmss}.json" -f $key, $Now)) -Encoding utf8
        Remove-Item $path -Force
        return $job
    }
    $null
}

function Get-StartedJob {
    # The most recent picked-up job for a PC since a given time, or $null.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Mac, [datetime]$Since = [datetime]::MinValue)
    $key = ConvertTo-MacKey $Mac
    $f = Get-ChildItem -Path (Join-RootPath (Get-JobFolder $ContentRoot) 'Started') -Filter "${key}_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $f) { return $null }
    $job = Get-Content -Raw $f.FullName | ConvertFrom-Json
    $at = [datetime]::Parse($job.startedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if ($at -ge $Since) { $job }
}

function Get-KnownComputerRows {
    # Grid rows for the console: each PC with its reimage state.
    param([Parameter(Mandatory)][string]$ContentRoot, [datetime]$Now = (Get-Date))
    foreach ($pc in Get-KnownComputers -ContentRoot $ContentRoot) {
        $job = Get-ReimageJob -ContentRoot $ContentRoot -Mac $pc.mac
        $state = if ($job -and (Test-JobExpired -Job $job -Now $Now)) { 'Expired' }
                 elseif ($job) { "Waiting: $($job.answerFile)" }
                 else {
                     $s = Get-StartedJob -ContentRoot $ContentRoot -Mac $pc.mac -Since $Now.AddDays(-1)
                     if ($s) { "Started $(([datetime]::Parse($s.startedAt)).ToString('HH:mm'))" } else { '' }
                 }
        [pscustomobject]@{
            Name         = $pc.name
            Mac          = $pc.mac
            Address      = if ($pc.address) { $pc.address } else { $pc.name }
            Group        = $pc.group
            Relay        = $pc.relay
            Model        = $pc.model
            LastDeployed = $pc.lastDeployed
            LastResult   = $pc.lastResult
            Job          = $state
            Computer     = $pc
        }
    }
}

#endregion

#region WDS known devices

function Get-WdsServerName {
    # remote.wdsServer wins, then wds.server (the WDS publishing settings); empty means this PC.
    param([Parameter(Mandatory)]$Settings)
    if ($Settings.remote -and $Settings.remote.wdsServer) { return $Settings.remote.wdsServer }
    if ($Settings.wds -and $Settings.wds.server) { return $Settings.wds.server }
    ''
}

$script:WdsPrestageScript = {
    # Runs on the WDS server. Add: prestage the PC with no F12 prompt. Remove: delete that prestaged device.
    param([string]$Action, [string]$Mac, [string]$Name)
    Import-Module WDS -ErrorAction Stop
    $existing = @(Get-WdsClient -DeviceID $Mac -ErrorAction SilentlyContinue)
    foreach ($c in $existing) { Remove-WdsClient -DeviceID $c.DeviceID -ErrorAction SilentlyContinue }
    if ($Action -eq 'Add') {
        New-WdsClient -DeviceID $Mac -DeviceName $Name -PxePromptPolicy NoPrompt -JoinDomain $false -ErrorAction Stop | Out-Null
    }
}

function Set-WdsNoPrompt {
    # Prestages a PC in WDS so it network boots without anyone pressing F12, or removes that again.
    # Other PCs keep the server's prompt policy.
    param([string]$Server, [Parameter(Mandatory)][string]$Mac, [string]$Name = '', [switch]$Remove)
    $argList = @($(if ($Remove) { 'Remove' } else { 'Add' }), (Format-MacAddress $Mac), $(if ($Name) { $Name } else { ConvertTo-MacKey $Mac }))
    if ($Server -and $Server -ne $env:COMPUTERNAME -and $Server -ne 'localhost') {
        Invoke-Command -ComputerName $Server -ScriptBlock $script:WdsPrestageScript -ArgumentList $argList -ErrorAction Stop
    } else {
        & $script:WdsPrestageScript @argList
    }
}

#endregion

#region In WinPE

function Get-LocalMacAddresses {
    # MACs of this PC's adapters that have an IP. In WinPE that is normally the wired NIC it booted from.
    @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' | Where-Object MACAddress | ForEach-Object {
        [pscustomobject]@{ Mac = $_.MACAddress; IP = @($_.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0]
                           Mask = @($_.IPSubnet | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0] }
    })
}

function Save-DeployedComputer {
    # Called by Deploy-Image.ps1 at the end, so every deployed PC can be woken and reimaged later.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)]$Identity,
        [string]$ComputerName,
        [string]$AnswerFile,
        [string]$Result
    )
    $fields = @{ maker = $Identity.Maker; model = $Identity.Model; serial = $Identity.Serial
                 lastDeployed = (Get-Date).ToString('yyyy-MM-dd HH:mm'); lastResult = $Result; lastAnswerFile = $AnswerFile }
    if ($ComputerName) { $fields.name = $ComputerName }
    if ($Adapter.IP) { $fields.ip = $Adapter.IP }
    if ($Adapter.Mask) { $fields.prefixLength = Get-PrefixLength $Adapter.Mask }
    Save-KnownComputer -ContentRoot $ContentRoot -Mac $Adapter.Mac -Fields $fields
}

#endregion

Export-ModuleMember -Function ConvertTo-MacKey, Format-MacAddress, New-MagicPacket, Get-BroadcastAddress, Get-WakeTargets,
    Send-MagicPacket, Send-WakeOnLan, Select-PxeBootEntry, Get-PrefixLength, Get-RemoteComputerInfo, Invoke-PxeRestart,
    Test-WinRMReachable, Get-KnownComputers, Get-KnownComputer, Save-KnownComputer, Remove-KnownComputer,
    Import-KnownComputerCsv, Update-KnownComputerFromInfo, New-ReimageJob, Test-JobExpired, Get-ReimageJob,
    Remove-ReimageJob, Receive-ReimageJob, Get-StartedJob, Get-KnownComputerRows, Get-WdsServerName, Set-WdsNoPrompt,
    Get-LocalMacAddresses, Save-DeployedComputer
