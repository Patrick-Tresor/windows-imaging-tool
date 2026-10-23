<#
.SYNOPSIS
    Sets up a WDS multicast session so a room of PCs downloads the image together instead of one copy each.
.DESCRIPTION
    Run as admin on the WDS server itself, or on an admin PC that is an administrator of the server
    (it then uses PowerShell remoting). WDS must already be set up (Publish-WdsBootImage.ps1 -Setup does that).

    Creates a multicast namespace over the content root folder on the server, so it serves the same
    Images\*.wim files the deploy uses. No image import into WDS: capture into the content root as usual.
    The content root must be a folder on the WDS server. By default it is found from the share in
    deploy-settings.json (\\server\Deploy -> the folder behind the Deploy share on that server).

    Session types:
      AutoCast       A transmission starts as soon as a PC asks; PCs that join later catch up on the parts they missed.
      ScheduledCast  PCs wait until -Clients PCs have joined or -StartTime comes (whichever is first),
                     or until you start it by hand with -Action Start.

    Actions: Create (default, replaces an existing session of the same name), Status (wdsutil text), Monitor
    (one object per connected PC with its progress, from the WDS transport COM API), Start, Remove, and
    Disconnect -ClientId (that PC stops, then deploys from the share instead when fallback is on).
    Settings not given on the command line come from the "multicast" section of deploy-settings.json.
.EXAMPLE
    .\Set-WdsMulticast.ps1 -Server wds01 -Type ScheduledCast -Clients 25 -SpeedPolicy Multistream
    Waits for 25 PCs, and splits slow PCs into a second, slower stream.
.EXAMPLE
    .\Set-WdsMulticast.ps1 -Server wds01 -Action Status
    Shows the session and the PCs connected to it.
.EXAMPLE
    (.\Set-WdsMulticast.ps1 -Server wds01 -Action Monitor).Clients | Format-Table Name, IpAddress, Percent
#>
[CmdletBinding()]
param(
    [ValidateSet('Create', 'Status', 'Monitor', 'Start', 'Remove', 'Disconnect')][string]$Action = 'Create',
    [string]$Server,                 # empty or localhost: this PC
    [string]$Namespace,              # session name the PCs ask for; default ImagingTool
    [string]$ContentPath,            # content root as a local folder on the server; default: behind the share
    [ValidateSet('AutoCast', 'ScheduledCast')][string]$Type,
    [int]$Clients,                   # ScheduledCast: start when this many PCs have joined (0: no threshold)
    [string]$StartTime,              # ScheduledCast: start at this time, yyyy-MM-dd HH:mm (empty: no time)
    [ValidateSet('None', 'AutoDisconnect', 'Multistream')][string]$SpeedPolicy,
    [int]$ThresholdKbps,             # AutoDisconnect: drop PCs slower than this (they then fall back to the share)
    [long]$ClientId,                 # Disconnect: the PC's Id from Monitor
    [string]$SettingsPath            # deploy-settings.json with "multicast", "wds" and "share" sections for defaults
)

$ErrorActionPreference = 'Stop'

$sharePath = ''
if ($SettingsPath -and (Test-Path $SettingsPath)) {
    $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    $sharePath = "$($settings.share.path)"
    $mc = $settings.multicast
    if (-not $PSBoundParameters.ContainsKey('Server')) { $Server = if ("$($mc.server)") { $mc.server } else { "$($settings.wds.server)" } }
    if ($mc) {
        if (-not $Namespace -and $mc.namespace) { $Namespace = $mc.namespace }
        if (-not $ContentPath -and $mc.contentPath) { $ContentPath = $mc.contentPath }
        if (-not $Type -and $mc.type) { $Type = $mc.type }
        if (-not $PSBoundParameters.ContainsKey('Clients') -and $mc.clients) { $Clients = [int]$mc.clients }
        if (-not $PSBoundParameters.ContainsKey('StartTime') -and $mc.startTime) { $StartTime = $mc.startTime }
        if (-not $SpeedPolicy -and $mc.speedPolicy) { $SpeedPolicy = $mc.speedPolicy }
        if (-not $PSBoundParameters.ContainsKey('ThresholdKbps') -and $mc.thresholdKbps) { $ThresholdKbps = [int]$mc.thresholdKbps }
    }
}
if (-not $Namespace) { $Namespace = 'ImagingTool' }
if (-not $Type) { $Type = 'AutoCast' }
if (-not $SpeedPolicy) { $SpeedPolicy = 'None' }
if ($ThresholdKbps -le 0) { $ThresholdKbps = 1024 }
$isLocal = -not $Server -or $Server -in 'localhost', '.', $env:COMPUTERNAME

$wdsTime = ''
if ($Action -eq 'Create' -and $Type -eq 'ScheduledCast') {
    if ($Clients -le 0 -and -not $StartTime) { throw 'A scheduled session needs a number of PCs, a start time, or both. Otherwise it only starts with -Action Start.' }
    if ($StartTime) {
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($StartTime, 'yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture, 'None', [ref]$t)) {
            throw "Start time '$StartTime' must look like 2026-11-03 08:30."
        }
        $wdsTime = $t.ToString('yyyy/MM/dd:HH:mm', [cultureinfo]::InvariantCulture)
    }
}

# Everything below runs on the WDS server. It is self-contained so Invoke-Command can send it as is.
# wdsutil output is localized, so success comes from exit codes; Status passes its text through as is.
$onServer = {
    param($Action, $Namespace, $ContentPath, $SharePath, $Type, $Clients, $WdsTime, $SpeedPolicy, $ThresholdKbps, $ClientId)
    $ErrorActionPreference = 'Stop'

    function Invoke-WdsUtil {
        $out = & wdsutil.exe @args 2>&1 | Out-String
        [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = $out.Trim() }
    }
    function Assert-WdsUtil {
        $r = Invoke-WdsUtil @args
        if (-not $r.Ok) { throw "wdsutil $($args -join ' ') failed:`n$($r.Text)" }
        Write-Host $r.Text
    }

    if (-not (Get-SmbShare -Name REMINST -ErrorAction SilentlyContinue)) {
        throw "WDS is not set up on $env:COMPUTERNAME. Publish the boot image with 'Set up WDS if needed' first."
    }
    $exists = (Invoke-WdsUtil /Get-Namespace "/Namespace:$Namespace").Ok

    switch ($Action) {
        'Status' {
            if (-not $exists) { return "No multicast session named '$Namespace' on $env:COMPUTERNAME." }
            return (Invoke-WdsUtil /Get-Namespace "/Namespace:$Namespace" /Details:Clients).Text
        }
        'Monitor' {
            # The transport server's COM API gives numbers rather than localized text. One session per image
            # being sent; a waiting scheduled session has no sessions yet.
            $result = [pscustomobject]@{ Server = $env:COMPUTERNAME; Namespace = $Namespace; Exists = $exists; Sessions = 0; Clients = @() }
            if (-not $exists) { return $result }
            $tpt = (New-Object -ComObject WdsTptMgmt.WdsTransportManager).GetWdsTransportServer($env:COMPUTERNAME)
            $ns = $tpt.NamespaceManager.RetrieveNamespace($Namespace)
            $rows = foreach ($content in $ns.RetrieveContents()) {
                foreach ($session in $content.RetrieveSessions()) {
                    $result.Sessions++
                    foreach ($c in $session.RetrieveClients()) {
                        [pscustomobject]@{
                            Id            = [long]$c.Id
                            Name          = "$($c.Name)"
                            IpAddress     = "$($c.IpAddress)"
                            MacAddress    = "$($c.MacAddress)"
                            File          = "$($content.Name)"
                            Percent       = [int]$c.PercentCompletion
                            JoinedSeconds = [long]$c.JoinDuration
                            RateBytes     = [long]$session.TransferRate   # whole session, bytes per second
                            Cpu           = [int]$c.CpuUtilization
                            Network       = [int]$c.NetworkUtilization
                        }
                    }
                }
            }
            $result.Clients = @($rows)
            return $result
        }
        'Disconnect' {
            # Fail, not Fallback: wdsmcast then exits with an error and Deploy-Image copies from the share itself.
            $tpt = (New-Object -ComObject WdsTptMgmt.WdsTransportManager).GetWdsTransportServer($env:COMPUTERNAME)
            $tpt.DisconnectClient([uint32]$ClientId, 1)
            return "Disconnected PC $ClientId from '$Namespace'."
        }
        'Start' {
            if (-not $exists) { throw "No multicast session named '$Namespace' on $env:COMPUTERNAME." }
            Assert-WdsUtil /Start-Namespace "/Namespace:$Namespace"
            return "Started '$Namespace' on $env:COMPUTERNAME."
        }
        'Remove' {
            if ($exists) { Assert-WdsUtil /Remove-Namespace "/Namespace:$Namespace" /Force }
            return "Removed '$Namespace' from $env:COMPUTERNAME."
        }
    }

    # Create: the namespace serves a local folder, so turn \\thisserver\Deploy into the folder behind it.
    if (-not $ContentPath) {
        if ($SharePath -notmatch '^\\\\([^\\]+)\\([^\\]+)(\\.*)?$') { throw 'Set the content folder on the server: there is no network share to find it from.' }
        $shareHost = $Matches[1].Split('.')[0]; $shareName = $Matches[2]; $sub = "$($Matches[3])".TrimStart('\')
        if ($shareHost -ne $env:COMPUTERNAME) {
            throw "The content share is on $shareHost, not on $env:COMPUTERNAME. Multicast serves a folder on the WDS server: set the content folder, or keep the content on the WDS server."
        }
        $share = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
        if (-not $share) { throw "No share named $shareName on $env:COMPUTERNAME." }
        $ContentPath = if ($sub) { Join-Path $share.Path $sub } else { $share.Path }
    }
    if (-not (Test-Path (Join-Path $ContentPath 'Images'))) { throw "$ContentPath has no Images folder: it is not the content root." }

    # Slow PCs: None keeps everyone at the slowest PC's speed; AutoDisconnect drops PCs below the threshold
    # (they fall back to a normal copy from the share); Multistream gives slow PCs their own slower stream.
    $policyArgs = @('/Set-TransportServer', '/MulticastSessionPolicy', "/Policy:$SpeedPolicy")
    if ($SpeedPolicy -eq 'AutoDisconnect') { $policyArgs += "/Threshold:$ThresholdKbps" }
    if ($SpeedPolicy -eq 'Multistream') { $policyArgs += @('/StreamCount:2', '/Fallback:Yes') }
    Assert-WdsUtil @policyArgs

    if ($exists) {
        Write-Host "Replacing multicast session '$Namespace'..."
        Assert-WdsUtil /Remove-Namespace "/Namespace:$Namespace" /Force
    }
    $nsArgs = @('/New-Namespace', "/FriendlyName:Imaging tool ($Namespace)", "/Namespace:$Namespace",
        '/ContentProvider:WDS', "/ConfigString:$ContentPath", "/NamespaceType:$Type")
    if ($Type -eq 'ScheduledCast') {
        if ($WdsTime) { $nsArgs += "/Time:$WdsTime" }
        if ($Clients -gt 0) { $nsArgs += "/Clients:$Clients" }
    }
    Assert-WdsUtil @nsArgs
    if ((Get-Service WDSServer).Status -ne 'Running') { Start-Service WDSServer }

    $when = 'as soon as a PC asks'
    if ($Type -eq 'ScheduledCast') {
        $triggers = @()
        if ($Clients -gt 0) { $triggers += "when $Clients PCs have joined" }
        if ($WdsTime) { $triggers += "at $WdsTime" }
        $when = $triggers -join ' or '
    }
    "Multicast session '$Namespace' on $env:COMPUTERNAME serves $ContentPath. Transfers start $when."
}

if ($Action -eq 'Disconnect' -and -not $PSBoundParameters.ContainsKey('ClientId')) { throw 'Disconnect needs -ClientId (from -Action Monitor).' }
$argList = @($Action, $Namespace, $ContentPath, $sharePath, $Type, $Clients, $wdsTime, $SpeedPolicy, $ThresholdKbps, $ClientId)
if ($isLocal) { & $onServer @argList }
else { Invoke-Command -ComputerName $Server -ScriptBlock $onServer -ArgumentList $argList }
