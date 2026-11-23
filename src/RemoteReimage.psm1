# Reimaging running PCs from the console (Computers tab): a job on the deployment share, and WinPE started from the
# PC's own disk. Used by Start-RemoteReimage.ps1 on the console PC and, in WinPE, by Deploy-Image.ps1 (to take a job).
#
# How a reimage goes:
#   1. The console reads the PC over PowerShell remoting (WinRM), or when that is off over its admin share and a
#      one-time SYSTEM service: its name, BIOS serial, UUID and firmware.
#   2. It writes Reimage\<serial>.json on the share: answer file, computer name and OU to keep, expiry.
#   3. It copies the network boot image (Boot\boot.wim on the content root) to C:\_ImagingBoot on the PC, adds a
#      one-time RAM disk boot entry for it (as WDS does over the network, but from the PC's disk, so no PXE),
#      suspends BitLocker for that one restart, and restarts the PC.
#   4. WinPE maps the share from its deploy-settings.json, finds the job for its serial, moves it to
#      Reimage\Started (so it can't run twice) and deploys with that answer file without asking.
#
# The share layout:
#   Reimage\<serial>.json                     a pending job
#   Reimage\Started\<serial>_<time>.json      jobs WinPE took
# PowerShell 5.1 compatible. The job and boot entry functions work off Windows, for the tests.

Import-Module (Join-Path $PSScriptRoot 'JsonFile.psm1')
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1')   # Join-ContentPath

#region Serial numbers

# Serials some makers leave in the BIOS of boards they did not fill in: many PCs share them, so a job keyed by one
# could be taken by the wrong PC.
$script:GenericSerials = @('', '0', '00000000', '0123456789', '1234567890', 'NONE', 'N/A', 'NA', 'DEFAULT STRING', 'DEFAULT',
    'TO BE FILLED BY O.E.M.', 'TO BE FILLED BY OEM', 'SYSTEM SERIAL NUMBER', 'SERIAL NUMBER', 'INVALID', 'NOT APPLICABLE',
    'NOT SPECIFIED', 'CHASSIS SERIAL NUMBER', 'XXXXXXXX')

function Test-UsableSerial {
    param([AllowEmptyString()][AllowNull()][string]$Serial)
    $s = "$Serial".Trim().ToUpperInvariant()
    -not ($s -in $script:GenericSerials -or $s -match '^(.)\1+$')
}

function ConvertTo-SerialKey {
    # A file name for a serial: upper case, anything but letters, digits and dashes becomes _ (VMware serials have
    # spaces and commas). Refuses serials many PCs share.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Serial)
    if (-not (Test-UsableSerial $Serial)) { throw "BIOS serial '$Serial' is not unique to one PC, so it can't be reimaged remotely. Reimage it from the USB stick." }
    ($Serial.Trim().ToUpperInvariant() -replace '[^A-Z0-9-]', '_')
}

#endregion

#region Reimage jobs

function Get-JobFolder { param([string]$ContentRoot) Join-ContentPath $ContentRoot 'Reimage' }

function ConvertFrom-JobTime([string]$Value) {
    [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function New-ReimageJob {
    # Queues a reimage for one PC. WinPE takes it by BIOS serial (and checks the UUID), uses its answer file without
    # asking, and moves it to Started, so a later boot of WinPE does not reimage the PC again. Jobs expire.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Serial,
        [string]$Uuid,
        [Parameter(Mandatory)][string]$AnswerFile,
        [string]$ComputerName,          # the name to keep; empty = the answer file's naming
        [string]$OU,                    # the OU to join it to; empty = the answer file's OU
        [int]$ExpiresHours = 4,
        [datetime]$Now = (Get-Date)
    )
    if (-not (Test-Path -LiteralPath (Join-ContentPath $ContentRoot "AnswerFiles\$AnswerFile.xml"))) { throw "No answer file named $AnswerFile on $ContentRoot." }
    $key = ConvertTo-SerialKey $Serial
    $dir = Get-JobFolder $ContentRoot
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $job = [pscustomobject][ordered]@{
        serial       = $Serial.Trim()
        uuid         = "$Uuid".Trim()
        answerFile   = $AnswerFile
        computerName = "$ComputerName".Trim().ToUpperInvariant()
        ou           = "$OU".Trim()
        requestedBy  = "$env:USERDOMAIN\$env:USERNAME".Trim('\')
        requestedAt  = $Now.ToString('o')
        expiresAt    = $Now.AddHours($ExpiresHours).ToString('o')
    }
    Save-JsonFile -Path (Join-ContentPath $dir "$key.json") -InputObject $job
    $job
}

function Test-JobExpired {
    param([Parameter(Mandatory)]$Job, [datetime]$Now = (Get-Date))
    (ConvertFrom-JobTime $Job.expiresAt) -lt $Now
}

function Get-ReimageJob {
    # The pending job for a PC, or $null.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Serial)
    $path = Join-ContentPath (Get-JobFolder $ContentRoot) "$(ConvertTo-SerialKey $Serial).json"
    if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
}

function Remove-ReimageJob {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Serial)
    Remove-Item -LiteralPath (Join-ContentPath (Get-JobFolder $ContentRoot) "$(ConvertTo-SerialKey $Serial).json") -ErrorAction SilentlyContinue
}

function Receive-ReimageJob {
    <#
    .SYNOPSIS
        In WinPE: takes the job for this PC's serial, if one is waiting and has not expired. A job that names a UUID is
        only taken by the PC with that UUID. Returns the job, or $null. OnNote gets a line for the log when a job is
        there but not taken.
    #>
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Serial,
        [string]$Uuid,
        [datetime]$Now = (Get-Date),
        [scriptblock]$OnNote = { },
        # WinPE's clock can be hours off (a stick built before WinPE got the console's time zone reads the PC's local
        # clock as Pacific time), so expiry allows this much. The console removes a job that was not taken in time.
        [int]$ClockSkewHours = 14
    )
    if (-not (Test-UsableSerial $Serial)) { return $null }
    $key = ConvertTo-SerialKey $Serial
    $dir = Get-JobFolder $ContentRoot
    $path = Join-ContentPath $dir "$key.json"
    # .NET, not Test-Path: WinPE maps the share as Z: through net use, which PowerShell may have no drive for.
    if (-not [IO.File]::Exists($path)) { return $null }
    $job = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if (Test-JobExpired -Job $job -Now $Now.AddHours(-$ClockSkewHours)) { & $OnNote "A reimage job for this PC expired at $($job.expiresAt); not used."; return $null }
    if ($job.uuid -and $Uuid -and $job.uuid.Trim() -ne $Uuid.Trim()) {
        & $OnNote "A reimage job for serial $Serial is for another PC (UUID $($job.uuid), this PC has $Uuid); not used."
        return $null
    }
    $job | Add-Member -NotePropertyName startedAt -NotePropertyValue $Now.ToString('o') -Force
    $started = Join-ContentPath $dir 'Started'
    [void][IO.Directory]::CreateDirectory($started)
    Save-JsonFile -Path (Join-ContentPath $started ("{0}_{1:yyyyMMdd-HHmmss}.json" -f $key, $Now)) -InputObject $job
    [IO.File]::Delete($path)
    $job
}

function Get-StartedJob {
    <#
    .SYNOPSIS
        The job WinPE took for a PC, or $null. -RequestedAt (the requestedAt of the job the console queued) finds that
        very job whatever WinPE's clock says; -Since takes the most recent one WinPE started after a given time.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Serial, [datetime]$Since = [datetime]::MinValue, [string]$RequestedAt)
    $key = ConvertTo-SerialKey $Serial
    $files = @(Get-ChildItem -LiteralPath (Join-ContentPath (Get-JobFolder $ContentRoot) 'Started') -Filter "${key}_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
    foreach ($f in $files) {
        try { $job = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if ($RequestedAt) {
            # ConvertFrom-Json may turn the text into a date: compare as round-trip text either way.
            $r = if ($job.requestedAt -is [datetime]) { $job.requestedAt.ToString('o') } else { "$($job.requestedAt)" }
            if ($r -eq $RequestedAt -or ((ConvertFrom-JobTime $r) -eq (ConvertFrom-JobTime $RequestedAt))) { return $job }
            continue
        }
        if ((ConvertFrom-JobTime $job.startedAt) -ge $Since) { return $job }
        return $null
    }
    $null
}

function Get-ReimageStates {
    # What the Computers tab shows in its Reimage column, by computer name: a waiting job, or one WinPE took in
    # the last day.
    param([Parameter(Mandatory)][string]$ContentRoot, [datetime]$Now = (Get-Date))
    $states = @{}
    $dir = Get-JobFolder $ContentRoot
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-ContentPath $dir 'Started') -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try { $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if (-not $j.computerName -or -not $j.startedAt) { continue }
        $at = (ConvertFrom-JobTime $j.startedAt).ToLocalTime()
        if ($at -lt $Now.AddDays(-1)) { continue }
        $states[$j.computerName] = "Started $($at.ToString('HH:mm'))"
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if (-not $j.computerName) { continue }
        $states[$j.computerName] = if (Test-JobExpired -Job $j -Now $Now) { 'Expired' } else { "Waiting: $($j.answerFile)" }
    }
    $states
}

function Find-ReimageJobByName {
    # The pending job for a computer name (to cancel it from the console), or $null.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ComputerName)
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-JobFolder $ContentRoot) -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if ($j.computerName -eq $ComputerName.ToUpperInvariant()) { return $j }
    }
    $null
}

#endregion

#region Reaching the PCs

function Get-RemoteOnlineState {
    <#
    .SYNOPSIS
        For each host, whether the console can reimage it now and how, and if not why: checked in parallel, 200 at
        a time. Ping is often blocked by Windows Firewall, so a PC that is on is told apart by its other ports.
    .OUTPUTS
        Hashtable: name as given -> { Online, Method, State, Address (the name that resolved), Ip, Detail }
        Method: 'WinRM' (PowerShell remoting answers), 'Smb' (remoting is off but the admin share answers: the
        console copies its files there and runs them with a one-time service), or '' when neither answers.
        State: 'Yes', 'Yes (SMB)', 'No access' (on, but neither WinRM nor file sharing answers), 'Not found' (the
        name does not resolve from this PC) or 'No answer' (off, asleep, or a firewall drops everything).
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ComputerName, [int]$TimeoutMs = 3000, [int]$Port = 5985,
        [int]$SmbPort = 445, [int[]]$OtherPorts = @(135, 3389))
    $result = @{}
    $names = @($ComputerName | Where-Object { $_ } | Select-Object -Unique)
    $allPorts = @(@($Port, $SmbPort) + $OtherPorts | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    for ($i = 0; $i -lt $names.Count; $i += 200) {
        $batch = @($names[$i..([Math]::Min($i + 199, $names.Count - 1))])

        # 1. Names to addresses. A full name that does not resolve (this PC uses another DNS server) is tried short.
        $lookups = foreach ($c in $batch) {
            $alt = if ($c -match '^[^.]+\.' -and $c -notmatch '^\d+(\.\d+){3}$') { ($c -split '\.')[0] } else { '' }
            [pscustomobject]@{ Name = $c; Alt = $alt; Task = $(try { [Net.Dns]::GetHostAddressesAsync($c) } catch { $null })
                AltTask = $(if ($alt) { try { [Net.Dns]::GetHostAddressesAsync($alt) } catch { $null } }) }
        }
        $tasks = @($lookups | ForEach-Object { $_.Task; $_.AltTask } | Where-Object { $_ })
        if ($tasks) { try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, $TimeoutMs) } catch { } }
        $resolved = foreach ($l in $lookups) {
            $ip = $null; $used = $l.Name
            foreach ($pair in @(@($l.Task, $l.Name), @($l.AltTask, $l.Alt))) {
                $t = $pair[0]
                if ($ip -or -not $t -or $t.Status -ne 'RanToCompletion') { continue }
                # IPv4 first: a .NET Framework TcpClient connects over the address's own family.
                $a = @($t.Result | Sort-Object { if ($_.AddressFamily -eq 'InterNetwork') { 0 } else { 1 } } | Where-Object { -not [Net.IPAddress]::IsLoopback($_) -or $pair[1] -match '(?i)^localhost$|^127\.' })
                if ($a) { $ip = $a[0]; $used = $pair[1] }
            }
            [pscustomobject]@{ Name = $l.Name; Ip = $ip; Used = $used }
        }

        # 2. WinRM, file sharing, and the ports any Windows PC that is on answers on.
        $probes = foreach ($r in @($resolved | Where-Object Ip)) {
            foreach ($p in $allPorts) {
                $tcp = [Net.Sockets.TcpClient]::new($r.Ip.AddressFamily)
                [pscustomobject]@{ Name = $r.Name; Port = $p; Client = $tcp; Task = $(try { $tcp.ConnectAsync($r.Ip, $p) } catch { $null }) }
            }
        }
        $tasks = @($probes | Where-Object Task | ForEach-Object Task)
        if ($tasks) { try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, $TimeoutMs) } catch { } }
        $open = @{}
        foreach ($p in @($probes)) {
            if ($p.Task -and $p.Task.Status -eq 'RanToCompletion' -and $p.Client.Connected) { $open["$($p.Name)|$($p.Port)"] = $true }
            try { $p.Client.Close() } catch { }
        }

        foreach ($r in $resolved) {
            $winrm = [bool]$open["$($r.Name)|$Port"]
            $smb = [bool]$open["$($r.Name)|$SmbPort"]
            $other = @($OtherPorts | Where-Object { $open["$($r.Name)|$_"] })
            $method = if ($winrm) { 'WinRM' } elseif ($smb) { 'Smb' } else { '' }
            $state = if (-not $r.Ip) { 'Not found' } elseif ($winrm) { 'Yes' } elseif ($smb) { 'Yes (SMB)' } elseif ($other) { 'No access' } else { 'No answer' }
            $detail = switch ($state) {
                'Not found' { "$($r.Name) does not resolve from this PC: it is not in the DNS this PC uses (this PC on another network, or the PC's DNS record is old)" }
                'Yes'       { "answers on PowerShell remoting (WinRM, port $Port) at $($r.Ip)" }
                'Yes (SMB)' { "is on at $($r.Ip): PowerShell remoting is off, so the reimage goes through its admin share (C$, port $SmbPort) and a one-time service" }
                'No access' { "is on at $($r.Ip) (port $($other -join ', ') answers) but neither PowerShell remoting (port $Port) nor file sharing (port $SmbPort) answers: turn one on, or allow it in its firewall" }
                default     { "resolves to $($r.Ip) but answers on none of ports $($allPorts -join ', '): it is off or asleep, the address is old, or a firewall drops everything" }
            }
            $result[$r.Name] = [pscustomobject]@{ Online = [bool]$method; Method = $method; Smb = $smb; State = $state; Address = $r.Used; Ip = "$($r.Ip)"; Detail = $detail }
        }
    }
    $result
}

function Get-OnlineSummaryText {
    # One line for the console's status bar: how many can be reimaged now, and what to do about the first ones that can't.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)   # { Name, State }
    $rows = @($Rows)
    $on = @($rows | Where-Object { "$($_.State)" -like 'Yes*' }).Count
    $text = "$on of $($rows.Count) can be reimaged now."
    $names = { param($list) "$($list[0].Name)$(if ($list.Count -gt 1) { " and $($list.Count - 1) more" })" }
    $blocked = @($rows | Where-Object State -eq 'No access')
    $lost = @($rows | Where-Object State -eq 'Not found')
    if ($blocked) { $text += " $(& $names $blocked): on, but its firewall blocks both PowerShell remoting and file sharing. Allow one of them (README)." }
    elseif ($lost) { $text += " $(& $names $lost): name not found in this PC's DNS. Use a domain controller as this PC's DNS server." }
    elseif ($rows.Count -gt $on) { $text += ' No answer: off, asleep, or a firewall drops everything. Point at Online for details.' }
    $text
}

#endregion

#region Running commands on a PC: PowerShell remoting, or the admin share and a one-time service

# Without WinRM: the console connects to \\PC\IPC$ and \\PC\ADMIN$ (as the account given), writes a script and its
# arguments to \\PC\ADMIN$\Temp\ImagingTool-<id>, creates a one-time SYSTEM service that starts it (sc.exe over
# the service manager's named pipe, port 445 only, as Windows admin tools do), reads the result file it writes,
# and deletes the service and the folder.

$script:WNetSource = @'
using System;
using System.Runtime.InteropServices;
public static class ImagingToolWNet {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class NetResource { public int Scope; public int Type; public int DisplayType; public int Usage;
        public string LocalName; public string RemoteName; public string Comment; public string Provider; }
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetAddConnection2(NetResource res, string password, string user, int flags);
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetCancelConnection2(string name, int flags, bool force);
}
'@

function Connect-AdminShare {
    # Signs in to \\PC\<share> as the account, without the password on a command line. 1219 = this PC already has
    # a connection to it as another account: that one is used.
    param([Parameter(Mandatory)][string]$Unc, [pscredential]$Credential)
    if (-not $Credential) { return $false }
    if (-not ('ImagingToolWNet' -as [type])) { Add-Type -TypeDefinition $script:WNetSource }
    $res = New-Object ImagingToolWNet+NetResource
    $res.Type = 0; $res.RemoteName = $Unc
    $code = [ImagingToolWNet]::WNetAddConnection2($res, $Credential.GetNetworkCredential().Password, $Credential.UserName, 0)
    if ($code -eq 1219) { return $false }
    if ($code -ne 0) { throw "Could not connect to ${Unc} as $($Credential.UserName): $((New-Object ComponentModel.Win32Exception $code).Message) (error $code)" }
    $true
}

function Disconnect-AdminShare {
    param([string]$Unc)
    if ('ImagingToolWNet' -as [type]) { try { [void][ImagingToolWNet]::WNetCancelConnection2($Unc, 0, $true) } catch { } }
}

function ConvertTo-AdminSharePath {
    # C:\_ImagingBoot\boot.wim on PC01 -> \\PC01\C$\_ImagingBoot\boot.wim
    param([Parameter(Mandatory)][string]$ComputerName, [Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^([A-Za-z]):\\(.*)$') { throw "Not a local path: $Path" }
    "\\$ComputerName\$($Matches[1].ToUpperInvariant())`$\$($Matches[2])"
}

function Get-RemoteRunnerScript {
    # The script the one-time service runs (as SYSTEM): the command, with its arguments from args.xml, writes its
    # output to out.xml or its error to error.txt, then done.txt. Folder: where the files are, on the PC.
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [Parameter(Mandatory)][string]$Folder)
    $code = $ScriptBlock.ToString()
    @"
`$ErrorActionPreference = 'Stop'
`$dir = '$($Folder -replace "'", "''")'
try {
    # The list comes back as one ArrayList: @() of the variable makes it the argument list, nested lists kept.
    `$raw = Import-Clixml -LiteralPath (Join-Path `$dir 'args.xml')
    `$a = @(`$raw)
    `$out = @(& {
$code
    } @a)
    Export-Clixml -LiteralPath (Join-Path `$dir 'out.xml') -InputObject `$out -Depth 4
} catch {
    Set-Content -LiteralPath (Join-Path `$dir 'error.txt') -Value "`$(`$_.Exception.Message)" -Encoding UTF8
} finally {
    Set-Content -LiteralPath (Join-Path `$dir 'done.txt') -Value 'done'
}
"@
}

function Get-RemoteServiceArgs {
    # sc.exe argument lists that create, start and delete the one-time service. cmd's start lets PowerShell run on
    # after the service manager gives up on it (it is not a real service: error 1053 is expected).
    param([Parameter(Mandatory)][string]$ComputerName, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Script)
    $ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    [pscustomobject]@{
        Create = @("\\$ComputerName", 'create', $Name, 'binPath=', "C:\Windows\System32\cmd.exe /c start /b $ps -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $Script", 'type=', 'own', 'start=', 'demand', 'obj=', 'LocalSystem')
        Start  = @("\\$ComputerName", 'start', $Name)
        Delete = @("\\$ComputerName", 'delete', $Name)
    }
}

function Open-RemoteChannel {
    # A way to run commands and copy files on a PC: Method 'WinRM' (a PowerShell session) or 'Smb'.
    param([Parameter(Mandatory)][string]$ComputerName, [pscredential]$Credential, [ValidateSet('WinRM', 'Smb')][string]$Method = 'WinRM')
    $ch = [pscustomobject]@{ ComputerName = $ComputerName; Method = $Method; Credential = $Credential; Session = $null; Connected = @() }
    if ($Method -eq 'WinRM') {
        $credArgs = @{}
        if ($Credential) { $credArgs.Credential = $Credential }
        try {
            $ch.Session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop @credArgs
        } catch {
            # A console PC outside the domain can't use Negotiate without TrustedHosts, but it can ask the domain for
            # a Kerberos ticket with the account given (the PC's full DNS name, the domain's DNS reachable).
            if (-not $Credential -or -not (Test-WinRMSignInError $_.Exception.Message)) { throw }
            $first = $_
            try { $ch.Session = New-PSSession -ComputerName $ComputerName -Authentication Kerberos -ErrorAction Stop @credArgs }
            catch { throw $first }
        }
    } else {
        foreach ($share in 'IPC$', 'ADMIN$', 'C$') {
            $unc = "\\$ComputerName\$share"
            if (Connect-AdminShare -Unc $unc -Credential $Credential) { $ch.Connected += $unc }
        }
        if (-not [IO.Directory]::Exists("\\$ComputerName\ADMIN`$\Temp")) {
            Close-RemoteChannel $ch
            throw "Access is denied to \\$ComputerName\ADMIN`$: the account is not an administrator there, or file sharing is off"
        }
    }
    $ch
}

function Close-RemoteChannel {
    param($Channel)
    if (-not $Channel) { return }
    if ($Channel.Session) { Remove-PSSession $Channel.Session -ErrorAction SilentlyContinue }
    foreach ($unc in @($Channel.Connected)) { Disconnect-AdminShare $unc }
    $Channel.Connected = @()
}

function Invoke-RemoteChannel {
    # Runs the script block on the PC with these arguments and returns its output. Over Smb it runs as SYSTEM.
    param([Parameter(Mandatory)]$Channel, [Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$TimeoutSeconds = 180)
    if ($Channel.Method -eq 'WinRM') {
        return Invoke-Command -Session $Channel.Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
    $pc = $Channel.ComputerName
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $local = "C:\Windows\Temp\ImagingTool-$id"
    $unc = "\\$pc\ADMIN`$\Temp\ImagingTool-$id"
    $name = "ImagingToolRun$id"
    [void][IO.Directory]::CreateDirectory($unc)
    try {
        Export-Clixml -LiteralPath "$unc\args.xml" -InputObject $ArgumentList -Depth 4
        [IO.File]::WriteAllText("$unc\run.ps1", (Get-RemoteRunnerScript -ScriptBlock $ScriptBlock -Folder $local), [Text.Encoding]::UTF8)
        $sc = Get-RemoteServiceArgs -ComputerName $pc -Name $name -Script "$local\run.ps1"
        $o = & sc.exe @($sc.Create) 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not create a service on ${pc}: $(($o | Out-String).Trim())" }
        try {
            & sc.exe @($sc.Start) 2>&1 | Out-Null    # 1053 is expected: PowerShell is not a real service
            $until = (Get-Date).AddSeconds($TimeoutSeconds)
            while (-not [IO.File]::Exists("$unc\done.txt")) {
                if ((Get-Date) -gt $until) { throw "$pc did not run the command within $TimeoutSeconds s (its antivirus may block services that start PowerShell)" }
                Start-Sleep -Milliseconds 500
            }
        } finally { & sc.exe @($sc.Delete) 2>&1 | Out-Null }
        if ([IO.File]::Exists("$unc\error.txt")) { throw ([IO.File]::ReadAllText("$unc\error.txt").Trim()) }
        if ([IO.File]::Exists("$unc\out.xml")) {
            # One ArrayList: written out, its items go down the pipeline one by one, as Invoke-Command's would.
            $result = Import-Clixml -LiteralPath "$unc\out.xml"
            $result
        }
    } finally {
        try { [IO.Directory]::Delete($unc, $true) } catch { }
    }
}

function Copy-ToRemoteChannel {
    # Copies a file from this PC to a path on the PC (C:\...).
    param([Parameter(Mandatory)]$Channel, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)
    if ($Channel.Method -eq 'WinRM') {
        Copy-Item -LiteralPath $Path -Destination $Destination -ToSession $Channel.Session -Force
    } else {
        [IO.File]::Copy($Path, (ConvertTo-AdminSharePath -ComputerName $Channel.ComputerName -Path $Destination), $true)
    }
}

$script:RemoteInfoScript = {
    # Runs on the target PC.
    $bl = $null
    try { $bl = (Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop).ProtectionStatus.ToString() } catch { }
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        # Services may not get firmware_type: PEFirmwareType 2 = UEFI.
        Firmware     = $(if ($env:firmware_type) { $env:firmware_type } elseif ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -ErrorAction SilentlyContinue).PEFirmwareType -eq 2) { 'UEFI' } else { 'Legacy' })
        Serial       = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
        Uuid         = "$((Get-CimInstance Win32_ComputerSystemProduct).UUID)".Trim()
        Model        = "$((Get-CimInstance Win32_ComputerSystem).Model)".Trim()
        FreeC        = [int64](Get-PSDrive C).Free
        BitLocker    = $bl
    }
}

function Get-RemoteComputerInfo {
    # Reads a running PC (WinRM, or the admin share and a one-time service). Needs admin rights on it.
    param([Parameter(Mandatory)][string]$ComputerName, [pscredential]$Credential, [ValidateSet('WinRM', 'Smb')][string]$Method = 'WinRM')
    $ch = Open-RemoteChannel -ComputerName $ComputerName -Credential $Credential -Method $Method
    try { @(Invoke-RemoteChannel -Channel $ch -ScriptBlock $script:RemoteInfoScript -TimeoutSeconds 120)[0] } finally { Close-RemoteChannel $ch }
}

function Test-RemoteTarget {
    # Problems that stop a reimage, from Get-RemoteComputerInfo, before anything is changed on the PC.
    # ExpectedName: the computer name in Active Directory. A stale DNS record can point at another PC.
    param([Parameter(Mandatory)]$Info, [string]$ExpectedName)
    if ($ExpectedName -and "$($Info.ComputerName)" -and $Info.ComputerName -ne $ExpectedName) {
        "its address answers as $($Info.ComputerName), not $ExpectedName (an old DNS record?)"
    }
    if ($Info.Firmware -ne 'UEFI') { 'it starts Windows in legacy BIOS mode; deploys need UEFI' }
    if (-not (Test-UsableSerial $Info.Serial)) { "its BIOS serial '$($Info.Serial)' is not unique to one PC" }
    if ($Info.FreeC -and $Info.FreeC -lt 2GB) { "only $([int]($Info.FreeC / 1MB)) MB free on C: (WinPE needs about 1 GB)" }
}

#endregion

#region WinPE from the PC's own disk

function Get-BcdGuid {
    # The {GUID} in bcdedit /create's output ("The entry {...} was successfully created."), in any language.
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}') { return $Matches[0] }
    $null
}

function Get-LocalBootCommands {
    <#
    .SYNOPSIS
        The bcdedit commands that start WinPE once from a boot.wim on the PC's own disk, as a RAM disk (UEFI).
        RamdiskId and LoaderId are the GUIDs bcdedit /create gave. Each item is one argument list.
    #>
    param(
        [Parameter(Mandatory)][string]$RamdiskId,
        [Parameter(Mandatory)][string]$LoaderId,
        [string]$Drive = 'C:',
        [string]$Folder = '\_ImagingBoot'
    )
    $wim = "ramdisk=[$Drive]$Folder\boot.wim,$RamdiskId"
    @(
        , @('/set', $RamdiskId, 'ramdisksdidevice', "partition=$Drive")
        , @('/set', $RamdiskId, 'ramdisksdipath', "$Folder\boot.sdi")
        , @('/set', $LoaderId, 'device', $wim)
        , @('/set', $LoaderId, 'osdevice', $wim)
        , @('/set', $LoaderId, 'path', '\windows\system32\boot\winload.efi')
        , @('/set', $LoaderId, 'systemroot', '\windows')
        , @('/set', $LoaderId, 'winpe', 'yes')
        , @('/set', $LoaderId, 'detecthal', 'yes')
        # One time only: the next restart after this one uses the normal boot order again.
        , @('/bootsequence', $LoaderId)
    )
}

function Get-LocalBootFolderAclArgs {
    # icacls arguments that leave C:\_ImagingBoot readable by Administrators and SYSTEM only: boot.wim holds the
    # answer file key (the network boot image has no WinPE password), so a user of the PC must not copy it.
    param([string]$Folder = 'C:\_ImagingBoot')
    @($Folder, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
}

function Get-LocalBootCleanupCommand {
    # What the PC runs at its next Windows start (SYSTEM startup task): WinPE did not reimage it, so WinPE and its
    # boot entry go, and the task removes itself. A reimaged PC never runs it: its disk is erased.
    param([string]$BootEntry, [string]$Folder = 'C:\_ImagingBoot', [string]$TaskName = 'ImagingTool\RemoveImagingBoot')
    # No quotes: schtasks /TR keeps a quoted path badly in Windows PowerShell, and these paths have no spaces.
    $cmd = "rd /s /q $Folder"
    if ($BootEntry) { $cmd += " & bcdedit /delete $BootEntry /f" }
    "cmd.exe /c $cmd & schtasks /Delete /TN $TaskName /F"
}

#region Restart notice

# The tasks that restart the PC into WinPE and tell the people signed in to it. Windows' own shutdown /t notice
# ("You're about to be signed out") has only Close, so the console shows its own window with Reboot now.
$script:NoticeFolder = 'C:\_ImagingBoot\Notice'
$script:NoticeScriptPath = 'C:\_ImagingBoot\Notice\ReimageNotice.ps1'
$script:RestartTaskName = 'ImagingTool\ReimageRestart'
$script:NoticeTaskName = 'ImagingTool\ReimageNotice'
# SYSTEM and Administrators full control, signed-in users read and run: Reboot now runs it with schtasks /Run.
$script:RestartTaskSddl = 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)'

function Get-ReimageNoticeFolderAclArgs {
    # The notice script sits under C:\_ImagingBoot (removed with it) in a subfolder the users signed in can read.
    @($script:NoticeFolder, '/grant', '*S-1-5-32-545:(OI)(CI)RX')
}

function Get-ReimageRestartCommand {
    # What the SYSTEM restart task runs: closes the notice windows' task, then restarts at once (apps closed).
    "/c schtasks /Delete /TN $script:NoticeTaskName /F & shutdown.exe /r /t 0 /f /d p:4:1"
}

function Get-ReimageRestartTaskXml {
    <#
    .SYNOPSIS
        Task Scheduler XML for the SYSTEM task that restarts the PC into WinPE. {START} and {END} are filled on the PC
        with its own clock (local time): it runs once at {START}, and deletes itself after {END} if Windows comes back.
    #>
    $actionArgs = [Security.SecurityElement]::Escape((Get-ReimageRestartCommand))
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Restarts this PC into WinPE to reinstall Windows (imaging console).</Description></RegistrationInfo>
  <Triggers>
    <TimeTrigger><StartBoundary>{START}</StartBoundary><EndBoundary>{END}</EndBoundary><Enabled>true</Enabled></TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <StartWhenAvailable>true</StartWhenAvailable>
    <DeleteExpiredTaskAfter>PT0S</DeleteExpiredTaskAfter>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>cmd.exe</Command><Arguments>$actionArgs</Arguments></Exec>
  </Actions>
</Task>
"@
}

function Get-ReimageNoticeTaskXml {
    # Task Scheduler XML for the notice window: no trigger, started at once in the session of every user signed in
    # (group BUILTIN\Users, their own rights).
    $cmd = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $script:NoticeScriptPath"
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Tells the user this PC restarts to reinstall Windows (imaging console).</Description></RegistrationInfo>
  <Principals>
    <Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>powershell.exe</Command><Arguments>$cmd</Arguments></Exec>
  </Actions>
</Task>
"@
}

function Get-ReimageNoticeScript {
    <#
    .SYNOPSIS
        The window the users signed in to the PC see: the message, a countdown, Reboot now and Close. {DEADLINE} is
        filled on the PC (UTC ticks of the restart). Reboot now runs the SYSTEM restart task, or restarts directly
        when it can't (users may restart a workstation). Close only hides the window: the PC still restarts on time.
    #>
    param([Parameter(Mandatory)][string]$Message)
    $msg = $Message -replace "'", "''"
    @"
`$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
`$deadline = [datetime]::new([int64]'{DEADLINE}', [DateTimeKind]::Utc)
`$font = New-Object Drawing.Font('Segoe UI', 10)
`$form = New-Object Windows.Forms.Form
`$form.Text = 'Windows is being reinstalled'
`$form.FormBorderStyle = 'FixedDialog'; `$form.MaximizeBox = `$false; `$form.MinimizeBox = `$false
`$form.StartPosition = 'CenterScreen'; `$form.TopMost = `$true; `$form.ShowInTaskbar = `$true
`$form.AutoSize = `$true; `$form.AutoSizeMode = 'GrowAndShrink'; `$form.Font = `$font
`$form.BackColor = [Drawing.Color]::White; `$form.Padding = New-Object Windows.Forms.Padding(8)
`$layout = New-Object Windows.Forms.TableLayoutPanel
`$layout.AutoSize = `$true; `$layout.ColumnCount = 1; `$layout.Dock = 'Fill'
`$title = New-Object Windows.Forms.Label
`$title.Text = 'This PC is about to restart'; `$title.AutoSize = `$true
`$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 13); `$title.Margin = New-Object Windows.Forms.Padding(8, 8, 8, 4)
`$text = New-Object Windows.Forms.Label
`$text.Text = '$msg'; `$text.AutoSize = `$true; `$text.MaximumSize = New-Object Drawing.Size(420, 0)
`$text.Margin = New-Object Windows.Forms.Padding(8, 4, 8, 4)
`$count = New-Object Windows.Forms.Label
`$count.AutoSize = `$true; `$count.Margin = New-Object Windows.Forms.Padding(8, 4, 8, 12); `$count.ForeColor = [Drawing.Color]::DimGray
`$buttons = New-Object Windows.Forms.FlowLayoutPanel
`$buttons.AutoSize = `$true; `$buttons.FlowDirection = 'RightToLeft'; `$buttons.Dock = 'Fill'
`$close = New-Object Windows.Forms.Button
`$close.Text = 'Close'; `$close.AutoSize = `$true; `$close.MinimumSize = New-Object Drawing.Size(100, 32)
`$reboot = New-Object Windows.Forms.Button
`$reboot.Text = 'Reboot now'; `$reboot.AutoSize = `$true; `$reboot.MinimumSize = New-Object Drawing.Size(120, 32)
`$buttons.Controls.AddRange(@(`$close, `$reboot))
`$layout.Controls.AddRange(@(`$title, `$text, `$count, `$buttons))
`$form.Controls.Add(`$layout)
`$form.AcceptButton = `$reboot; `$form.CancelButton = `$close
`$showLeft = {
    `$left = `$deadline - [datetime]::UtcNow
    if (`$left.TotalSeconds -le 0) { `$count.Text = 'Restarting now...'; return }
    `$count.Text = 'Save your work. It restarts by itself in {0}:{1:00}.' -f [int][math]::Floor(`$left.TotalMinutes), `$left.Seconds
}
& `$showLeft
`$timer = New-Object Windows.Forms.Timer
`$timer.Interval = 1000
`$timer.Add_Tick(`$showLeft)
`$timer.Start()
`$close.Add_Click({ `$form.Close() })
`$reboot.Add_Click({
    `$reboot.Enabled = `$false; `$close.Enabled = `$false
    `$timer.Stop(); `$count.Text = 'Restarting now...'; `$form.Refresh()
    & schtasks.exe /Run /TN '$script:RestartTaskName' 2>&1 | Out-Null
    # Users may restart a workstation themselves when the task can't be run.
    if (`$LASTEXITCODE -ne 0) {
        & shutdown.exe /r /t 0 /f /d p:4:1 2>&1 | Out-Null
    }
    if (`$LASTEXITCODE -ne 0) {
        `$close.Enabled = `$true; `$timer.Start()
        `$text.Text = 'This PC could not restart now. It restarts by itself when the time is up.'
    }
})
[void]`$form.ShowDialog()
`$timer.Stop()
"@
}

#endregion

function Remove-LocalDiskBoot {
    # Takes WinPE off a PC that is back in Windows without being reimaged: the folder, the boot entry and the task.
    param([Parameter(Mandatory)][string]$ComputerName, [string]$BootEntry, [pscredential]$Credential, [ValidateSet('WinRM', 'Smb')][string]$Method = 'WinRM')
    $ch = Open-RemoteChannel -ComputerName $ComputerName -Credential $Credential -Method $Method
    try {
        Invoke-RemoteChannel -Channel $ch -ArgumentList "$BootEntry" -ScriptBlock {
            param($Entry)
            if ($Entry) { & bcdedit.exe /delete $Entry /f 2>&1 | Out-Null }
            foreach ($t in 'RemoveImagingBoot', 'ReimageRestart', 'ReimageNotice') { & schtasks.exe /Delete /TN "ImagingTool\$t" /F 2>&1 | Out-Null }
            Remove-Item 'C:\_ImagingBoot' -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path 'C:\_ImagingBoot') { throw 'C:\_ImagingBoot could not be removed.' }
        } | Out-Null
    } finally { Close-RemoteChannel $ch }
}

function Invoke-LocalDiskBoot {
    <#
    .SYNOPSIS
        Copies boot.wim to C:\_ImagingBoot on a running PC (PowerShell remoting, or the admin share), adds a one-time
        RAM disk boot entry for it, suspends BitLocker for one restart (the boot manager must read C:), and restarts
        it. On a failure before the restart, the boot entries are removed again and the PC is left as it was.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$BootWim,
        [pscredential]$Credential,
        [ValidateSet('WinRM', 'Smb')][string]$Method = 'WinRM',
        [int]$DelaySeconds = 60,
        [string]$Message = 'IT is reinstalling Windows on this PC. Save your work: it restarts shortly.',
        [scriptblock]$OnStage = { }
    )
    if (-not (Test-Path -LiteralPath $BootWim)) { throw "No network boot image at $BootWim." }
    $ch = Open-RemoteChannel -ComputerName $ComputerName -Credential $Credential -Method $Method
    $created = @()
    try {
        & $OnStage 'copy'
        Invoke-RemoteChannel -Channel $ch -ArgumentList (, (Get-LocalBootFolderAclArgs)) -ScriptBlock {
            param($AclArgs)
            New-Item -ItemType Directory -Path 'C:\_ImagingBoot' -Force | Out-Null
            # Admins and SYSTEM only, before boot.wim (with the answer file key) is copied in.
            # [string[]]: over the admin share a list arrives as an ArrayList.
            $o = & icacls.exe ([string[]]$AclArgs) 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Could not limit C:\_ImagingBoot to administrators: $o" }
        } | Out-Null
        Copy-ToRemoteChannel -Channel $ch -Path $BootWim -Destination 'C:\_ImagingBoot\boot.wim'
        & $OnStage 'bootentry'
        $out = @(Invoke-RemoteChannel -Channel $ch -ScriptBlock {
            $sdi = 'C:\Windows\Boot\DVD\EFI\boot.sdi'
            if (-not (Test-Path $sdi)) { throw "$sdi is missing on this PC." }
            Copy-Item $sdi 'C:\_ImagingBoot\boot.sdi' -Force
            $ram = (& bcdedit.exe /create /d 'Imaging RAM disk' /device) -join ' '
            $ldr = (& bcdedit.exe /create /d 'Reinstall Windows (WinPE)' /application osloader) -join ' '
            @($ram, $ldr)
        })
        $ramId = Get-BcdGuid $out[0]; $loaderId = Get-BcdGuid $out[1]
        $created = @($ramId, $loaderId | Where-Object { $_ })
        if (-not $ramId -or -not $loaderId) { throw "bcdedit could not create the boot entries: $($out -join ' | ')" }
        $steps = Get-LocalBootCommands -RamdiskId $ramId -LoaderId $loaderId
        $cleanup = Get-LocalBootCleanupCommand -BootEntry $loaderId
        & $OnStage 'restart'
        $notice = [pscustomobject]@{
            Folder = $script:NoticeFolder; FolderAcl = @(Get-ReimageNoticeFolderAclArgs); ScriptPath = $script:NoticeScriptPath
            Script = Get-ReimageNoticeScript -Message $Message; NoticeXml = Get-ReimageNoticeTaskXml
            RestartXml = Get-ReimageRestartTaskXml; RestartSddl = $script:RestartTaskSddl
        }
        Invoke-RemoteChannel -Channel $ch -ArgumentList $steps, $DelaySeconds, $Message, $cleanup, $notice -ScriptBlock {
            param($Steps, $Delay, $Message, $Cleanup, $Notice)
            foreach ($a in $Steps) {
                $o = & bcdedit.exe ([string[]]$a) 2>&1
                if ($LASTEXITCODE -ne 0) { throw "bcdedit $($a -join ' ') failed: $o" }
            }
            # If WinPE does not reimage the PC and Windows starts again, this removes WinPE and its boot entry.
            $o = & schtasks.exe /Create /TN 'ImagingTool\RemoveImagingBoot' /TR $Cleanup /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Could not create the cleanup task: $o" }
            # With BitLocker on, the changed boot would ask for the recovery key. One restart without it; the deploy
            # erases the disk anyway.
            $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
            if ($bl -and $bl.ProtectionStatus -eq 'On') { Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 | Out-Null }
            # The restart: a SYSTEM task at the time, and a window with Reboot now and Close for each user signed in
            # (Windows' own shutdown /t notice has only Close). Old way if the task can't be made.
            $at = (Get-Date).AddSeconds($Delay)
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $scheduled = $false
            try {
                $svc = New-Object -ComObject Schedule.Service
                $svc.Connect()
                try { $folder = $svc.GetFolder('\ImagingTool') } catch { $folder = $svc.GetFolder('\').CreateFolder('ImagingTool') }
                $xml = $Notice.RestartXml.Replace('{START}', $at.ToString("yyyy-MM-dd'T'HH:mm:ss", $inv)).Replace('{END}', $at.AddHours(1).ToString("yyyy-MM-dd'T'HH:mm:ss", $inv))
                # 6 = create or update, 5 = service account (SYSTEM).
                [void]$folder.RegisterTask('ReimageRestart', $xml, 6, $null, $null, 5, $Notice.RestartSddl)
                $scheduled = $true
                try {
                    New-Item -ItemType Directory -Path $Notice.Folder -Force | Out-Null
                    & icacls.exe ([string[]]$Notice.FolderAcl) 2>&1 | Out-Null
                    $text = $Notice.Script.Replace('{DEADLINE}', "$($at.ToUniversalTime().Ticks)")
                    [IO.File]::WriteAllText($Notice.ScriptPath, $text, (New-Object Text.UTF8Encoding $true))
                    # 4 = group: runs in the session of each user signed in.
                    $task = $folder.RegisterTask('ReimageNotice', $Notice.NoticeXml, 6, $null, $null, 4, $null)
                    [void]$task.Run($null)
                } catch { }    # no window: the PC still restarts on time
            } catch { }
            if (-not $scheduled) {
                # /d p:4:1 = planned, application installation. A delay over 0 also closes the apps that are open.
                & shutdown.exe /r /t $Delay /c $Message /d p:4:1
                if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed (exit $LASTEXITCODE)." }
            }
        } | Out-Null
        $created = @()
        [pscustomobject]@{ ComputerName = $ComputerName; BootEntry = $loaderId; Method = $Method }
    } catch {
        $err = $_
        try {
            Invoke-RemoteChannel -Channel $ch -ArgumentList (, $created) -ScriptBlock {
                param($Ids)
                foreach ($id in $Ids) { & bcdedit.exe /delete $id /f 2>&1 | Out-Null }
                foreach ($t in 'RemoveImagingBoot', 'ReimageRestart', 'ReimageNotice') { & schtasks.exe /Delete /TN "ImagingTool\$t" /F 2>&1 | Out-Null }
                Remove-Item 'C:\_ImagingBoot' -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
        } catch { }
        throw $err
    } finally { Close-RemoteChannel $ch }
}

#endregion

#region Console checks

function Get-NetworkBootImage {
    # The network boot image the Computers tab starts on PCs: <content root>\Boot\boot.wim, and what its build wrote
    # next to it (boot.json: when, and which share it maps).
    param([Parameter(Mandatory)][string]$ContentRoot)
    $wim = Join-ContentPath $ContentRoot 'Boot\boot.wim'
    $info = $null
    try { $info = Get-Content -Raw -LiteralPath (Join-ContentPath $ContentRoot 'Boot\boot.json') -ErrorAction Stop | ConvertFrom-Json } catch { }
    $exists = Test-Path -LiteralPath $wim
    [pscustomobject]@{
        Path   = $wim
        Exists = $exists
        Built  = if ($info -and $info.built) { "$($info.built)" } elseif ($exists) { (Get-Item -LiteralPath $wim).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        Share  = if ($info) { "$($info.share)" } else { '' }
    }
}

function Get-RemoteReimageProblems {
    # What stops a reimage from the Computers tab, before any PC is touched. Settings: the content root's
    # deploy-settings.json. Boot: Get-NetworkBootImage.
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Boot)
    $share = "$($Settings.share.path)".Trim()
    if (-not $share) { 'No deployment share: set Network share on the Deploy Settings tab (the PCs load the image from there), then build the network boot image.' }
    if (-not $Boot.Exists) { 'No network boot image yet: click Build network boot image.' }
    elseif ($share -and $Boot.Share -and $Boot.Share -ne $share) { "The network boot image maps $($Boot.Share), but the share is now $share`: click Build network boot image." }
}

#endregion

function Test-WinRMSignInError {
    # WinRM answered but would not sign in from this PC: it is outside the domain (no TrustedHosts, no Kerberos).
    param([AllowEmptyString()][string]$Message)
    $Message -match '(?i)TrustedHosts|cannot be authenticated|workgroup|0x8009030e|0x80090311|0x80090322|Kerberos'
}

function Get-RemotingProblemText {
    <#
    .SYNOPSIS
        One short line for the progress window from a PowerShell remoting error, saying what to do. The whole error
        goes to the log. WinRM's messages are long and the same in every language only by their error names.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [string]$Account,
        # A PC outside the domain, signed in to with its own local account.
        [switch]$Local)
    $who = if ($Account) { $Account } else { 'this account' }
    if ($Local -and $Message -match '(?i)Access is denied|Acc.s refus|0x80070005|AccessDenied') {
        return "$who can't get admin rights on it over the network: use its built-in Administrator, or allow remote admin for local accounts there (see the log)"
    }
    if ($Message -match '(?i)TrustedHosts|cannot be authenticated|workgroup|0x8009030e|0x80090311') {
        return "This console PC can't sign in to it over WinRM (the console PC is not in the domain?): run the console on a domain PC, or add the PCs to WinRM TrustedHosts on this one (see the log)"
    }
    if ($Message -match '(?i)Access is denied|Acc.s refus|0x80070005|AccessDenied') {
        return "$who is not an administrator on it: untick Use the Deploy Settings account and use an admin account, or add $who to its Administrators"
    }
    if ($Message -match '(?i)user name or password is incorrect|logon failure|0x8007052e') {
        return "Wrong password for $who"
    }
    if ($Message -match '(?i)WinRM cannot complete|cannot connect|ERROR_WINRM|0x80338012|network path') {
        return 'WinRM does not answer on it: turn on PowerShell remoting there (Enable-PSRemoting -Force, or the Group Policy in the log)'
    }
    $line = @("$Message" -split "`r?`n" | Where-Object { $_.Trim() })
    if ($line) { $line[0].Trim() } else { 'PowerShell remoting failed' }
}

function Read-ReimageTargets {
    <#
    .SYNOPSIS
        The PCs the console's Computers tab hands to Start-RemoteReimage.ps1: a JSON list of { name, address, ou }.
    .DESCRIPTION
        Windows PowerShell 5.1's ConvertFrom-Json returns a JSON list as ONE object (the whole array), so
        @(... | ConvertFrom-Json) gave a list holding a list. $t.address on that inner array then found the array's own
        Address() method instead of the property, and the first reimage tried to reach a PC named
        "System.Object&, mscorlib ... Address(int )". Piping through ForEach-Object unrolls the array in 5.1 and 7.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    @($text | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object {
        $name = "$($_.name)".Trim()
        if (-not $name) { return }
        $address = if ($_.PSObject.Properties['address'] -and "$($_.address)".Trim()) { "$($_.address)".Trim() } else { $name }
        $ou = if ($_.PSObject.Properties['ou']) { "$($_.ou)".Trim() } else { '' }
        # local: not in Active Directory (found by IP); credentialFile: its own local admin account (Export-Clixml).
        $local = [bool]($_.PSObject.Properties['local'] -and $_.local)
        $credFile = if ($_.PSObject.Properties['credentialFile']) { "$($_.credentialFile)".Trim() } else { '' }
        [pscustomobject]@{ name = $name.ToUpperInvariant(); address = $address; ou = $(if ($local) { '' } else { $ou }); local = $local; credentialFile = $credFile }
    })
}

Export-ModuleMember -Function Get-ReimageNoticeScript, Get-ReimageNoticeTaskXml, Get-ReimageRestartTaskXml, Get-ReimageRestartCommand, Get-ReimageNoticeFolderAclArgs, Get-RemotingProblemText, Test-WinRMSignInError, Read-ReimageTargets, Test-UsableSerial, ConvertTo-SerialKey, New-ReimageJob, Test-JobExpired, Get-ReimageJob, Remove-ReimageJob,
    Receive-ReimageJob, Get-StartedJob, Get-ReimageStates, Find-ReimageJobByName, Get-RemoteOnlineState, Get-OnlineSummaryText, ConvertTo-AdminSharePath, Get-RemoteRunnerScript, Get-RemoteServiceArgs, Open-RemoteChannel, Close-RemoteChannel, Invoke-RemoteChannel, Copy-ToRemoteChannel, Get-RemoteComputerInfo,
    Test-RemoteTarget, Get-BcdGuid, Get-LocalBootCommands, Get-LocalBootFolderAclArgs, Get-LocalBootCleanupCommand, Remove-LocalDiskBoot, Invoke-LocalDiskBoot, Get-NetworkBootImage, Get-RemoteReimageProblems
