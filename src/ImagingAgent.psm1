# The agent on every imaged PC, and what the console needs to talk to it. PowerShell 5.1 compatible.
#
# On the PC (ImagingAgent.ps1, a SYSTEM scheduled task ImagingTool\Agent that starts with Windows and keeps running):
#   - every few minutes it writes a check-in to <status folder>\Agents\<serial>.json on the deployment share: name,
#     serial, IP, model, image, deploy result, who is signed in, when it last checked in. As SYSTEM the share sees the
#     computer account, which already writes to the Status folder (Domain Computers, Modify) at first boot.
#   - every minute it looks for a job in <status folder>\Agents\Jobs\<serial>\job.json. A job only counts when the
#     console signed it (RSA, SHA-256) with its private key, it names this PC's serial, UUID and agent id, it has not
#     expired, and it never ran here before. Any domain PC can write in the Status folder, so the signature is what
#     makes a job the console's.
#   - a reimage job: it copies the network boot image the console put next to the job (that folder is readable by
#     this PC's computer account only: boot.wim holds the answer file key), checks its SHA-256 against the signed
#     job, and restarts into WinPE from its own disk the way the console does over WinRM (Invoke-LocalDiskBoot
#     -Method Local). WinPE then takes the usual Reimage\<serial>.json job on the share.
#
# On the console: the key pair (private in <content root>\config\secrets\agent-key.xml, never on a stick; public in
# config\agent-public-key.xml and in every boot.wim), reading the check-ins, and writing signed jobs.
#
# The share layout:
#   Status\Agents\<serial>.json               a PC's last check-in
#   Status\Agents\Jobs\<serial>\job.json      a signed job for that PC
#   Status\Agents\Jobs\<serial>\boot.wim      the network boot image for a reimage job (that PC's account only)

Import-Module (Join-Path $PSScriptRoot 'JsonFile.psm1')
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1')   # ConvertTo-SerialKey, Invoke-LocalDiskBoot

$script:AgentDir = 'C:\ProgramData\ImagingTool\Agent'
$script:AgentTaskName = 'ImagingTool\Agent'
# The files the agent runs from (copied into C:\ProgramData\ImagingTool\Agent, administrators and SYSTEM only).
$script:AgentFiles = @('ImagingAgent.ps1', 'ImagingAgent.psm1', 'RemoteReimage.psm1', 'JsonFile.psm1', 'AnswerFile.psm1', 'AppPack.psm1',
    'LibraryPack.psm1', 'ScriptLog.psm1')
$script:KeyFile = 'config\secrets\agent-key.xml'
$script:PublicKeyFile = 'config\agent-public-key.xml'

function Join-AgentPath([string]$Root, [string]$Child) {
    # [IO.Path]::Combine, not Join-Path: a UNC share or a WinPE volume may have no PowerShell drive.
    [IO.Path]::Combine($Root, ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar))
}

function ConvertFrom-AgentTime($Value) {
    # ConvertFrom-Json may already have made a date of it.
    if ($Value -is [datetime]) { return $Value }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d }
    $null
}

#region Where things are

function Get-AgentInstallFolder { $script:AgentDir }
function Get-AgentTaskName { $script:AgentTaskName }
function Get-AgentFileNames { $script:AgentFiles }

function Get-AgentFolder {
    # Where the PCs check in: <status folder>\Agents.
    param([Parameter(Mandatory)][string]$StatusFolder)
    Join-AgentPath $StatusFolder 'Agents'
}

function Get-AgentStatusFolder {
    <#
    .SYNOPSIS
        Deploy: the UNC status folder the agent on a newly deployed PC checks in to, or '' when there is none. The one
        WinPE reported to; else, for a USB deploy that could not reach the share, the share's Status folder from
        deploy-settings.json (reporting.path on older setups), which Windows reaches later as the computer account.
    #>
    param($StatusTarget, $Settings)
    if ($StatusTarget -and $StatusTarget.Unc) { return "$($StatusTarget.Unc)" }
    if ($Settings -and $Settings.PSObject.Properties['reporting'] -and $Settings.reporting -and "$($Settings.reporting.path)" -like '\\*') { return "$($Settings.reporting.path)".TrimEnd('\') }
    $share = if ($Settings -and $Settings.PSObject.Properties['share'] -and $Settings.share) { "$($Settings.share.path)".Trim().TrimEnd('\') } else { '' }
    # The shipped example (\\deploy-server\Deploy) points at no real server.
    if (-not $share -or $share -notlike '\\*' -or $share -match '^\\\\(deploy-server|server|yourserver)\\') { return '' }
    "$share\Status"
}

function Get-AgentJobFolder {
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Serial)
    Join-AgentPath (Get-AgentFolder $StatusFolder) "Jobs\$(ConvertTo-SerialKey $Serial)"
}

#endregion

#region Keys (console)

function New-AgentKeyPair {
    # RSA 3072: the console signs with the private key, every PC checks with the public one. XML, as .NET has it.
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
    try {
        $rsa.PersistKeyInCsp = $false
        [pscustomobject]@{ Private = $rsa.ToXmlString($true); Public = $rsa.ToXmlString($false) }
    } finally { $rsa.Dispose() }
}

function Get-AgentSigningKey {
    <#
    .SYNOPSIS
        The console's private key (XML) from <content root>\config\secrets\agent-key.xml, or $null. -Create makes the
        pair the first time and writes the public key to config\agent-public-key.xml (it goes into every boot.wim
        and on the sticks; config\secrets never does).
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [switch]$Create)
    $path = Join-AgentPath $ContentRoot $script:KeyFile
    $pub = Join-AgentPath $ContentRoot $script:PublicKeyFile
    if ([IO.File]::Exists($path)) {
        $key = [IO.File]::ReadAllText($path).Trim()
        # The public key file was deleted (or never copied): write it again from the private key.
        if (-not [IO.File]::Exists($pub)) { [IO.File]::WriteAllText($pub, (ConvertTo-AgentPublicKey $key), [Text.Encoding]::ASCII) }
        return $key
    }
    if (-not $Create) { return $null }
    $pair = New-AgentKeyPair
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $pair.Private, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($pub, $pair.Public, [Text.Encoding]::ASCII)
    $pair.Private
}

function ConvertTo-AgentPublicKey {
    param([Parameter(Mandatory)][string]$PrivateKey)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($PrivateKey); $rsa.ToXmlString($false) } finally { $rsa.Dispose() }
}

function Get-AgentPublicKey {
    # The public key the PCs check jobs with: <content root>\config\agent-public-key.xml (made with the private key).
    param([Parameter(Mandatory)][string]$ContentRoot, [switch]$Create)
    $key = Get-AgentSigningKey -ContentRoot $ContentRoot -Create:$Create
    if (-not $key) { return $null }
    [IO.File]::ReadAllText((Join-AgentPath $ContentRoot $script:PublicKeyFile)).Trim()
}

function Get-AgentKeyId {
    # A short name for a public key (first 12 hex of its SHA-256), for the logs: which console's key a PC trusts.
    param([Parameter(Mandatory)][string]$PublicKey)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($PublicKey.Trim())) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12) }
    finally { $sha.Dispose() }
}

#endregion

#region Jobs

# The fields a signature covers, in this order. A job is signed as these lines (name=value), so nothing in it can be
# changed or added without breaking the signature.
$script:JobFields = @('version', 'id', 'action', 'serial', 'uuid', 'agentId', 'computerName', 'createdAt', 'expiresAt', 'bootWimSha256', 'delaySeconds', 'message', 'requestedBy')

function Get-AgentJobText {
    param([Parameter(Mandatory)]$Job)
    (@($script:JobFields | ForEach-Object {
        $v = if ($Job.PSObject.Properties[$_]) { $Job.$_ } else { '' }
        if ($v -is [datetime]) { $v = $v.ToUniversalTime().ToString('o') }
        "$_=$("$v" -replace "[`r`n]", ' ')"
    })) -join "`n"
}

function Set-AgentJobSignature {
    # Adds signature (base64 RSA SHA-256 over Get-AgentJobText) to the job.
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$PrivateKey)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($PrivateKey)
        $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes((Get-AgentJobText $Job)), 'SHA256')
    } finally { $rsa.Dispose() }
    $Job | Add-Member -NotePropertyName signature -NotePropertyValue ([Convert]::ToBase64String($sig)) -Force
    $Job
}

function Test-AgentJobSignature {
    param([Parameter(Mandatory)]$Job, [string[]]$PublicKeys)
    if (-not $Job.PSObject.Properties['signature'] -or -not $Job.signature) { return $false }
    try { $sig = [Convert]::FromBase64String("$($Job.signature)") } catch { return $false }
    $data = [Text.Encoding]::UTF8.GetBytes((Get-AgentJobText $Job))
    foreach ($k in @($PublicKeys | Where-Object { $_ })) {
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        try {
            $rsa.PersistKeyInCsp = $false
            $rsa.FromXmlString($k)
            if ($rsa.VerifyData($data, 'SHA256', $sig)) { return $true }
        } catch { } finally { $rsa.Dispose() }
    }
    $false
}

function New-AgentJob {
    <#
    .SYNOPSIS
        Console: a signed job for one PC's agent, from its check-in (serial, UUID, agent id). For a reimage, -BootWim
        is copied next to the job and its SHA-256 goes into the signed job. The job's folder is made fresh and
        limited to administrators, the console's account and that PC's computer account (-SetFolderAccess; tests pass
        a stand-in), because boot.wim holds the answer file key.
    #>
    param(
        [Parameter(Mandatory)][string]$StatusFolder,
        [Parameter(Mandatory)][string]$PrivateKey,
        [Parameter(Mandatory)]$CheckIn,                  # the PC's check-in (Get-AgentCheckIns row or the raw record)
        [ValidateSet('reimage')][string]$Action = 'reimage',
        [string]$BootWim,
        [string]$BootWimSha256,                          # when known already (several PCs, one image)
        [int]$DelaySeconds = 60,
        [string]$Message = 'IT is reinstalling Windows on this PC. Save your work: it restarts shortly.',
        [int]$ExpiresMinutes = 60,
        [datetime]$Now = (Get-Date),
        [scriptblock]$SetFolderAccess = { param($Folder, $Account) Set-AgentJobFolderAccess -Folder $Folder -Account $Account }
    )
    $serial = "$($CheckIn.serial)"
    if (-not $CheckIn.agentId) { throw "The agent on $($CheckIn.computerName) has no id: it can't take jobs." }
    $dir = Get-AgentJobFolder -StatusFolder $StatusFolder -Serial $serial
    # Fresh every time: a folder some other PC made beforehand (anyone can write in Status) is never reused.
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dir))
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    $account = if ($CheckIn.PSObject.Properties['accountSid'] -and $CheckIn.accountSid) { "*$($CheckIn.accountSid)" } else { "$($CheckIn.account)" }
    & $SetFolderAccess $dir $account
    if (@([IO.Directory]::GetFileSystemEntries($dir)).Count) { [IO.Directory]::Delete($dir, $true); throw "Something wrote into $dir while it was made; not used." }
    try {
        $hash = ''
        if ($Action -eq 'reimage') {
            if (-not $BootWim -or -not [IO.File]::Exists($BootWim)) { throw "No network boot image at $BootWim." }
            $hash = if ($BootWimSha256) { $BootWimSha256 } else { (Get-FileHash -LiteralPath $BootWim -Algorithm SHA256).Hash }
            [IO.File]::Copy($BootWim, (Join-AgentPath $dir 'boot.wim'), $true)
        }
        $job = [pscustomobject][ordered]@{
            version       = 1
            id            = [guid]::NewGuid().ToString()
            action        = $Action
            serial        = $serial.Trim()
            uuid          = "$($CheckIn.uuid)".Trim()
            agentId       = "$($CheckIn.agentId)"
            computerName  = "$($CheckIn.computerName)".ToUpperInvariant()
            createdAt     = $Now.ToUniversalTime().ToString('o')
            expiresAt     = $Now.ToUniversalTime().AddMinutes($ExpiresMinutes).ToString('o')
            bootWimSha256 = "$hash".ToUpperInvariant()
            delaySeconds  = $DelaySeconds
            message       = $Message
            requestedBy   = "$env:USERDOMAIN\$env:USERNAME".Trim('\')
        }
        $job = Set-AgentJobSignature -Job $job -PrivateKey $PrivateKey
        Save-JsonFile -Path (Join-AgentPath $dir 'job.json') -InputObject $job
        $job
    } catch {
        try { [IO.Directory]::Delete($dir, $true) } catch { }
        throw
    }
}

function Set-AgentJobFolderAccess {
    # Administrators, SYSTEM and the console's own account full control, the PC's computer account modify (it
    # deletes the job and boot.wim once taken), nothing inherited: the other domain PCs that write in Status get
    # nothing. Account: *SID or DOMAIN\PC$.
    param([Parameter(Mandatory)][string]$Folder, [string]$Account)
    if (-not $Account) { throw 'The PC did not report its computer account: its job folder could not be limited to it.' }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $out = & icacls.exe $Folder /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "*${me}:(OI)(CI)F" "${Account}:(OI)(CI)M" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not limit $Folder to $Account (icacls exit $LASTEXITCODE): $(@($out) -join ' ')" }
}

function Get-AgentJob {
    # The job waiting for this PC, or $null. .NET calls: the share is a UNC path.
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Serial)
    if (-not (Test-UsableSerial $Serial)) { return $null }
    $path = Join-AgentPath (Get-AgentJobFolder -StatusFolder $StatusFolder -Serial $Serial) 'job.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $text = [IO.File]::ReadAllText($path)
    try { $text | ConvertFrom-Json } catch { [pscustomobject]@{ id = ''; unreadable = $_.Exception.Message } }
}

function Remove-AgentJob {
    # Console: the job and its boot image (cancelled, timed out, or done). PC: the job file once taken.
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Serial, [switch]$JobFileOnly)
    $dir = Get-AgentJobFolder -StatusFolder $StatusFolder -Serial $Serial
    try {
        if ($JobFileOnly) { [IO.File]::Delete((Join-AgentPath $dir 'job.json')) }
        elseif ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    } catch { }
}

function Test-AgentJob {
    <#
    .SYNOPSIS
        PC: why a job must not run here, or $null when it may. Identity: this PC's serial, uuid and agentId. DoneIds:
        the jobs that ran here already. ClockSkewMinutes: how far this PC's clock may be from the console's.
    #>
    param(
        [Parameter(Mandatory)]$Job,
        [string[]]$PublicKeys,
        [Parameter(Mandatory)]$Identity,
        [string[]]$DoneIds = @(),
        [datetime]$Now = (Get-Date),
        [int]$ClockSkewMinutes = 10
    )
    if ($Job.PSObject.Properties['unreadable']) { return "the job file can't be read ($($Job.unreadable))" }
    if (-not @($PublicKeys | Where-Object { $_ })) { return 'this PC has no console key, so it takes no jobs' }
    if (-not (Test-AgentJobSignature -Job $Job -PublicKeys $PublicKeys)) { return 'it is not signed by the console' }
    if ("$($Job.version)" -ne '1') { return "job version $($Job.version) is not known to this agent" }
    if ($Job.action -ne 'reimage') { return "action '$($Job.action)' is not known to this agent" }
    if ("$($Job.serial)".Trim().ToUpperInvariant() -ne "$($Identity.serial)".Trim().ToUpperInvariant()) { return "it is for serial $($Job.serial)" }
    if ($Job.uuid -and $Identity.uuid -and "$($Job.uuid)".Trim() -ne "$($Identity.uuid)".Trim()) { return "it is for UUID $($Job.uuid)" }
    # The agent id is new after each deploy, so a job signed for this PC before it was reimaged never runs again.
    if ("$($Job.agentId)" -ne "$($Identity.agentId)") { return 'it was made for an earlier install of this PC' }
    if (@($DoneIds) -contains "$($Job.id)") { return 'it ran here already' }
    $created = ConvertFrom-AgentTime $Job.createdAt
    $expires = ConvertFrom-AgentTime $Job.expiresAt
    if (-not $created -or -not $expires) { return 'its times can''t be read' }
    $utc = $Now.ToUniversalTime()
    if ($expires.ToUniversalTime() -lt $utc.AddMinutes(-$ClockSkewMinutes)) { return "it expired at $($expires.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" }
    if ($created.ToUniversalTime() -gt $utc.AddMinutes($ClockSkewMinutes)) { return 'it was made in the future (is this PC''s clock right?)' }
    if ($Job.action -eq 'reimage' -and "$($Job.bootWimSha256)" -notmatch '^[0-9A-Fa-f]{64}$') { return 'it has no boot image checksum' }
    $null
}

#endregion

#region Check-ins

function New-AgentCheckIn {
    <#
    .SYNOPSIS
        The record a PC writes to Status\Agents\<serial>.json. Identity: serial, uuid, maker, model, firmware.
        Network: ipAddresses, macAddress. Deploy: from agent.json (answer file, image, tool version, deployed).
        Job: the last job's { id, state, message, at }.
    #>
    param(
        [Parameter(Mandatory)]$Identity,
        $Network,
        $Deploy,
        [Parameter(Mandatory)][string]$AgentId,
        [string]$AgentVersion,
        [int]$CheckInMinutes = 5,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$Account,
        [string]$AccountSid,
        [string]$Os,
        [string]$UserSignedIn,
        [Nullable[datetime]]$BootTime,
        [Nullable[int64]]$FreeC,
        [string]$Result,
        $Job,
        [datetime]$Now = (Get-Date)
    )
    $get = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $ips = @(& $get $Network 'ipAddresses' | Where-Object { $_ })
    [pscustomobject][ordered]@{
        computerName   = "$ComputerName".ToUpperInvariant()
        serial         = "$($Identity.serial)".Trim()
        uuid           = "$($Identity.uuid)".Trim()
        maker          = "$(& $get $Identity 'maker')"
        model          = "$(& $get $Identity 'model')"
        firmware       = "$(& $get $Identity 'firmware')"
        account        = $Account
        accountSid     = $AccountSid
        ipAddress      = $(if ($ips) { "$($ips[0])" } else { '' })
        ipAddresses    = @($ips)
        macAddress     = "$(& $get $Network 'macAddress')"
        os             = $Os
        userSignedIn   = $UserSignedIn
        bootTime       = $(if ($BootTime) { $BootTime.Value.ToString('o') } else { '' })
        freeC          = $FreeC
        answerFile     = "$(& $get $Deploy 'answerFile')"
        image          = "$(& $get $Deploy 'image')"
        toolVersion    = "$(& $get $Deploy 'toolVersion')"
        deployedAt     = "$(& $get $Deploy 'deployedAt')"
        result         = $Result
        agentId        = $AgentId
        agentVersion   = $AgentVersion
        checkInMinutes = $CheckInMinutes
        lastSeen       = $Now.ToUniversalTime().ToString('o')
        job            = $Job
    }
}

function Save-AgentCheckIn {
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)]$Record)
    $dir = Get-AgentFolder $StatusFolder
    [void][IO.Directory]::CreateDirectory($dir)
    Save-JsonFile -Path (Join-AgentPath $dir "$(ConvertTo-SerialKey $Record.serial).json") -InputObject $Record -Depth 4
}

function Get-AgentCheckIns {
    <#
    .SYNOPSIS
        Console: every PC's last check-in, with LastSeen (local time), Online (checked in within 3 check-in intervals)
        and LastSeenText. One per computer name: the newest when a PC got a new serial (board swap).
    #>
    param([Parameter(Mandatory)][string]$StatusFolder, [datetime]$Now = (Get-Date))
    $dir = Get-AgentFolder $StatusFolder
    $rows = @(foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try { $r = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
        if (-not $r.serial -or -not $r.lastSeen) { continue }
        $seen = ConvertFrom-AgentTime $r.lastSeen
        if (-not $seen) { continue }
        $seen = $seen.ToLocalTime()
        $every = [Math]::Max(1, [int]$(if ($r.checkInMinutes) { $r.checkInMinutes } else { 5 }))
        $r | Add-Member -NotePropertyName LastSeen -NotePropertyValue $seen -Force
        $r | Add-Member -NotePropertyName Online -NotePropertyValue (($Now - $seen).TotalMinutes -le (3 * $every + 1)) -Force
        $r | Add-Member -NotePropertyName LastSeenText -NotePropertyValue (Format-AgentLastSeen -LastSeen $seen -Now $Now) -Force
        $r
    })
    @($rows | Sort-Object LastSeen -Descending | Group-Object { "$($_.computerName)".ToUpperInvariant() } | ForEach-Object { $_.Group[0] })
}

function Find-AgentCheckIn {
    # A computer's check-in by name (or by serial), or $null.
    param([object[]]$CheckIns, [string]$ComputerName, [string]$Serial)
    if ($Serial) { $s = @($CheckIns | Where-Object { "$($_.serial)".Trim() -eq $Serial.Trim() }); if ($s) { return $s[0] } }
    if ($ComputerName) {
        $n = @($CheckIns | Where-Object { "$($_.computerName)" -eq $ComputerName.ToUpperInvariant() })
        if ($n) { return $n[0] }
    }
    $null
}

function Format-AgentLastSeen {
    # 'Just now', '7 min ago', '3 h ago', 'Yesterday 14:05', '2026-11-20 09:12'.
    param([Parameter(Mandatory)][datetime]$LastSeen, [datetime]$Now = (Get-Date))
    $ago = $Now - $LastSeen
    if ($ago.TotalMinutes -lt 2) { return 'Just now' }
    if ($ago.TotalMinutes -lt 60) { return "$([int][Math]::Floor($ago.TotalMinutes)) min ago" }
    if ($ago.TotalHours -lt 12) { return "$([int][Math]::Floor($ago.TotalHours)) h ago" }
    if ($LastSeen.Date -eq $Now.Date.AddDays(-1)) { return "Yesterday $($LastSeen.ToString('HH:mm'))" }
    if ($LastSeen.Date -eq $Now.Date) { return "Today $($LastSeen.ToString('HH:mm'))" }
    $LastSeen.ToString('yyyy-MM-dd HH:mm')
}

function ConvertTo-AgentTargetInfo {
    # A check-in as Get-RemoteComputerInfo's record, so Test-RemoteTarget checks an agent PC the same way.
    param([Parameter(Mandatory)]$CheckIn)
    [pscustomobject]@{
        ComputerName = "$($CheckIn.computerName)"; Firmware = "$($CheckIn.firmware)"; Serial = "$($CheckIn.serial)"; Uuid = "$($CheckIn.uuid)"
        Model = "$($CheckIn.model)"; FreeC = $(if ($CheckIn.freeC) { [int64]$CheckIn.freeC } else { $null }); BitLocker = ''
    }
}

function Get-AgentRowView {
    <#
    .SYNOPSIS
        Console, Computers tab: what the Online and Agent columns show for a PC, from the network check
        (Get-RemoteOnlineState) and its agent's check-in. A PC whose agent checked in lately is Online 'Agent' even when
        WinRM and file sharing are blocked.
    #>
    param($Check, $Agent, [string]$Name)
    $online = if ($Check -and $Check.Online) { "$($Check.State)" } elseif ($Agent -and $Agent.Online) { 'Agent' } elseif ($Check) { "$($Check.State)" } else { '' }
    $agentText = if (-not $Agent) { '' } elseif ($Agent.Online) { "$($Agent.LastSeenText)" } else { "Off: $($Agent.LastSeenText)" }
    $detail = @()
    if ($Agent) {
        $detail += "Last check-in $($Agent.LastSeen.ToString('yyyy-MM-dd HH:mm')) from $(if ($Agent.ipAddress) { $Agent.ipAddress } else { 'no IPv4 address' })"
        if ($Agent.answerFile -or $Agent.image) { $detail += "Deployed with $((@("$($Agent.answerFile)", "$($Agent.image)") | Where-Object { $_ }) -join ', ')$(if ($Agent.deployedAt) { " on $("$($Agent.deployedAt)".Substring(0, [Math]::Min(10, "$($Agent.deployedAt)".Length)))" })" }
        if ($Agent.result) { $detail += "$($Agent.result)" }
        if ($Agent.userSignedIn) { $detail += "Signed in: $($Agent.userSignedIn)" }
        if ($Agent.job -and $Agent.job.state) { $detail += "Last job: $($Agent.job.action) $($Agent.job.state)$(if ($Agent.job.message) { " ($($Agent.job.message))" })" }
        if ($Agent.agentVersion) { $detail += "Agent from tool version $($Agent.agentVersion)" }
    }
    $onlineDetail = @()
    if ($Check) { $onlineDetail += "$Name $($Check.Detail)" }
    if ($Agent -and $Agent.Online) { $onlineDetail += "Its agent checked in $("$($Agent.LastSeenText)".ToLowerInvariant()): Reimage goes through the agent." }
    [pscustomobject]@{
        Online       = $online
        OnlineDetail = $(if ($onlineDetail) { $onlineDetail -join "`n" } else { $null })
        Agent        = $agentText
        AgentDetail  = $(if ($detail) { $detail -join "`n" } else { 'No agent: it is put on each PC deployed while the network share is set, or with Install agent.' })
    }
}

#endregion

#region The share's rights

function Get-DomainComputersSid {
    # Domain Computers (RID 515) from any account SID of the domain (the console PC's computer account): by SID, so a
    # French domain's "Ordinateurs du domaine" works the same.
    param([Parameter(Mandatory)][string]$DomainAccountSid)
    if ($DomainAccountSid -notmatch '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { throw "Not a domain account SID: $DomainAccountSid" }
    "$($Matches[1])-515"
}

function Resolve-LocalSharePath {
    <#
    .SYNOPSIS
        \\IMAGER\imager\Status -> C:\imager\Status when the share is on this PC (its name, full name, localhost or
        127.0.0.1), else $null. Shares: name -> local path (Get-SmbShare on Windows; tests pass a hashtable).
    #>
    param([Parameter(Mandatory)][string]$Unc, [hashtable]$Shares, [string[]]$ThisPC = @($env:COMPUTERNAME))
    if ($Unc -notmatch '^\\\\([^\\]+)\\([^\\]+)(\\.*)?$') { return $null }
    $hostName = $Matches[1]; $share = $Matches[2]; $rest = "$($Matches[3])".TrimStart('\')
    $names = @($ThisPC | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() }) + 'LOCALHOST', '127.0.0.1'
    if ($names -notcontains ($hostName.Split('.')[0].ToUpperInvariant()) -and $names -notcontains $hostName.ToUpperInvariant()) { return $null }
    $key = @($Shares.Keys | Where-Object { "$_" -eq $share })[0]
    if (-not $key) { return $null }
    $local = "$($Shares[$key])".TrimEnd('\')
    [pscustomobject]@{ Share = $key; Path = $(if ($rest) { "$local\$rest" } else { $local }) }
}

function Grant-StatusFolderAccess {
    <#
    .SYNOPSIS
        Lets the agents (and first boot) write their status: Domain Computers modify rights on the Status folder, and
        Change on its share, when that share is on this PC. Only adds, never takes anything away. Returns
        { Changed, Lines }: what it found or did, for the log. Needs admin rights (the console runs with them).
    #>
    param([Parameter(Mandatory)][string]$StatusFolder)
    $lines = [Collections.Generic.List[string]]::new()
    $changed = $false
    $shares = @{}
    try { foreach ($s in @(Get-SmbShare -ErrorAction Stop)) { $shares[$s.Name] = $s.Path } } catch { }
    $local = Resolve-LocalSharePath -Unc $StatusFolder -Shares $shares -ThisPC @($env:COMPUTERNAME)
    if (-not $local) {
        $lines.Add("$StatusFolder is not a share on this PC: on its server, give Domain Computers modify rights on that folder and Change on the share.")
        return [pscustomobject]@{ Changed = $false; Lines = @($lines) }
    }
    $me = ([Security.Principal.NTAccount]"$env:USERDOMAIN\$env:COMPUTERNAME`$").Translate([Security.Principal.SecurityIdentifier]).Value
    $dc = Get-DomainComputersSid $me
    $dcName = try { ([Security.Principal.SecurityIdentifier]$dc).Translate([Security.Principal.NTAccount]).Value } catch { $dc }
    [void][IO.Directory]::CreateDirectory($local.Path)
    # The folder: an allow rule for Domain Computers with at least Modify, passed on to what is in it.
    $modify = [Security.AccessControl.FileSystemRights]::Modify
    $hasNtfs = @((Get-Acl -LiteralPath $local.Path).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and (($_.FileSystemRights -band $modify) -eq $modify) -and
        $(try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $dc, 'S-1-1-0', 'S-1-5-11' } catch { $false })
    }).Count -gt 0
    if ($hasNtfs) { $lines.Add("$($local.Path): Domain Computers can already write there.") }
    else {
        $o = & icacls.exe $local.Path /grant "*${dc}:(OI)(CI)M" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not give $dcName modify rights on $($local.Path): $(@($o) -join ' ')" }
        $lines.Add("$($local.Path): gave $dcName modify rights."); $changed = $true
    }
    # The share: Change or Full for Domain Computers, Everyone or Authenticated Users.
    $hasShare = @(Get-SmbShareAccess -Name $local.Share -ErrorAction Stop | Where-Object {
        $_.AccessControlType -eq 'Allow' -and "$($_.AccessRight)" -in 'Change', 'Full' -and
        $(try { ([Security.Principal.NTAccount]"$($_.AccountName)").Translate([Security.Principal.SecurityIdentifier]).Value -in $dc, 'S-1-1-0', 'S-1-5-11' } catch { $false })
    }).Count -gt 0
    if ($hasShare) { $lines.Add("Share $($local.Share): Domain Computers can already change files there.") }
    else {
        Grant-SmbShareAccess -Name $local.Share -AccountName $dcName -AccessRight Change -Force -ErrorAction Stop | Out-Null
        $lines.Add("Share $($local.Share): gave $dcName Change."); $changed = $true
    }
    [pscustomobject]@{ Changed = $changed; Lines = @($lines) }
}

function Get-AgentLogProblem {
    <#
    .SYNOPSIS
        One line saying why an agent did not check in, from the end of its log (C:\Windows\Temp\ImagingAgent.log) and its
        task's state. Lines: the log's last lines ($null: no log, it never started). TaskState / TaskResult: from
        Get-ScheduledTask / Get-ScheduledTaskInfo.
    #>
    param([string[]]$Lines, [string]$TaskState, [string]$TaskResult)
    $Lines = @($Lines | Where-Object { "$_".Trim() })
    if (-not $Lines) {
        $t = if ($TaskState) { "task $TaskState$(if ($TaskResult) { ", last result $TaskResult" })" } else { 'no task ImagingTool\Agent' }
        return "The agent never started ($t)"
    }
    $text = { param($l) ($l -replace '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ', '').Trim() }
    $bad = @($Lines | Where-Object { $_ -match 'Could not check in|stops|stopped|Could not read' }) | Select-Object -Last 1
    if ($bad) {
        $t = & $text $bad
        if ($t -match '(?i)Could not check in' -and $t -match '(?i)denied|refus') { return "The PC's computer account may not write to the share: $t" }
        return $t
    }
    "Last agent log line: $(& $text $Lines[-1])"
}

#endregion

#region Installing it

function New-AgentConfig {
    # agent.json next to the agent: where to check in, the console keys it trusts, and what this deploy was.
    param(
        [Parameter(Mandatory)][string]$StatusFolder,
        [string[]]$PublicKeys,
        [int]$CheckInMinutes = 5,
        $Deploy
    )
    [pscustomobject][ordered]@{
        statusFolder   = $StatusFolder
        checkInMinutes = [Math]::Max(1, $CheckInMinutes)
        publicKeys     = @($PublicKeys | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
        deploy         = $Deploy
    }
}

function Get-AgentTaskXml {
    <#
    .SYNOPSIS
        Task Scheduler XML for ImagingTool\Agent: SYSTEM, at startup, and every 15 minutes in case it stopped (a second
        start while it runs is ignored). No time limit: it keeps running and checks in on its own.
    #>
    param([string]$ScriptPath = "$script:AgentDir\ImagingAgent.ps1")
    $cmd = [Security.SecurityElement]::Escape("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`"")
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Imaging tool agent: tells the imaging console this PC is on, and takes the jobs the console signed (reimage).</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>
    <TimeTrigger><StartBoundary>2020-01-01T00:00:00</StartBoundary><Repetition><Interval>PT15M</Interval></Repetition><Enabled>true</Enabled></TimeTrigger>
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
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT5M</Interval><Count>3</Count></RestartOnFailure>
    <Priority>7</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>powershell.exe</Command><Arguments>$cmd</Arguments></Exec>
  </Actions>
</Task>
"@
}

function Install-AgentOnRemotePC {
    <#
    .SYNOPSIS
        Console: puts the agent on a running PC over a remote channel (Open-RemoteChannel: WinRM, or the admin share and
        a one-time service), and starts it. For PCs imaged before the agent existed; newly deployed PCs get it at deploy.
    #>
    param(
        [Parameter(Mandatory)]$Channel,
        [Parameter(Mandatory)][string]$SourceDir,     # the console's src folder
        [Parameter(Mandatory)]$Config                 # New-AgentConfig
    )
    $dir = $script:AgentDir
    $acl = @($dir, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
    Invoke-RemoteChannel -Channel $Channel -ArgumentList $dir, $acl -ScriptBlock {
        param($Dir, $AclArgs)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        # Administrators and SYSTEM only, before the scripts that run as SYSTEM go in.
        $o = & icacls.exe ([string[]]$AclArgs) 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not limit $Dir to administrators: $o" }
    } | Out-Null
    foreach ($f in $script:AgentFiles) { Copy-ToRemoteChannel -Channel $Channel -Path (Join-AgentPath $SourceDir $f) -Destination "$dir\$f" }
    $json = ConvertTo-Json -InputObject $Config -Depth 6
    Invoke-RemoteChannel -Channel $Channel -ArgumentList $dir, $json, (Get-AgentTaskXml) -ScriptBlock {
        param($Dir, $Json, $TaskXml)
        [IO.File]::WriteAllText("$Dir\agent.json", $Json, (New-Object Text.UTF8Encoding $true))
        [IO.File]::WriteAllText("$Dir\agent-task.xml", $TaskXml, [Text.Encoding]::Unicode)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dir\ImagingAgent.ps1" -Register
        if ($LASTEXITCODE -ne 0) { throw "The agent's task could not be made (exit $LASTEXITCODE): see C:\Windows\Temp\ImagingAgent.log on the PC." }
    } | Out-Null
}

#endregion

Export-ModuleMember -Function Get-AgentInstallFolder, Get-AgentTaskName, Get-AgentFileNames, Get-AgentFolder, Get-AgentStatusFolder, Get-AgentJobFolder,
    New-AgentKeyPair, Get-AgentSigningKey, ConvertTo-AgentPublicKey, Get-AgentPublicKey, Get-AgentKeyId,
    Get-AgentJobText, Set-AgentJobSignature, Test-AgentJobSignature, New-AgentJob, Set-AgentJobFolderAccess, Get-AgentJob, Remove-AgentJob, Test-AgentJob,
    New-AgentCheckIn, Save-AgentCheckIn, Get-AgentCheckIns, Find-AgentCheckIn, Format-AgentLastSeen, ConvertTo-AgentTargetInfo, Get-AgentRowView,
    New-AgentConfig, Get-AgentTaskXml, Install-AgentOnRemotePC, Get-DomainComputersSid, Resolve-LocalSharePath, Grant-StatusFolderAccess, Get-AgentLogProblem
