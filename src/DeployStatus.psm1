# Deployment status reporting for the dashboard.
# Deploy-Image.ps1 (WinPE) and FirstBoot.ps1 (the new Windows) write Status\<id>.json and a live copy of the log,
# Status\<id>.log; the console reads them. PowerShell 5.1 compatible, no UI code, so it can be tested without Windows.
# Reporting is best effort: a failed write is a warning and never stops a deployment.

$script:Folder   = $null   # where this deployment's status is written
$script:Record   = $null   # the status record, kept in memory and rewritten on each update
$script:LogPaths = @()     # logs concatenated into Status\<id>.log
$script:Warned   = $false

#region Writing (WinPE and first boot)

function Get-StatusId {
    # The BIOS serial names the files; a redeployed PC replaces its previous status. Placeholder serials
    # (blank, "To Be Filled By O.E.M.", "System Serial Number", "Default string") fall back to the MAC address.
    param([string]$Serial, [string]$MacAddress)
    $s = if ($Serial) { $Serial.Trim() } else { '' }
    if (-not $s -or $s -match '^(to be filled|system serial|default string|none|0+$)') {
        $s = if ($MacAddress) { 'MAC-' + ($MacAddress -replace '[:-]', '') } else { 'PC-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    }
    ($s -replace '[\\/:*?"<>|\s]', '_')
}

function Resolve-StatusTarget {
    # Works out where WinPE writes status and which UNC path, if any, the new Windows can report to at first boot.
    #   ReportPath empty:              <content root>\Status (the share's UNC when the root is the mapped share).
    #   ReportPath under the share:    written through the share's drive letter, no second mapping.
    #   ReportPath elsewhere:          mapped as R: (USB deployments reporting to a server, for example).
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [string]$SharePath,          # deploy-settings share.path
        [string]$ReportPath,         # deploy-settings reporting.path
        [string]$ShareDrive = 'Z:\'  # where Find-ContentRoot maps the share
    )
    $onShare = $SharePath -and $ContentRoot.TrimEnd('\') -eq $ShareDrive.TrimEnd('\')
    if (-not $ReportPath) {
        return [pscustomobject]@{
            Local = $ContentRoot.TrimEnd('\') + '\Status'   # a WinPE path; string-built so tests run off Windows
            Map   = $null
            Unc   = if ($onShare) { $SharePath.TrimEnd('\') + '\Status' } else { $null }
        }
    }
    $report = $ReportPath.TrimEnd('\')
    $share = if ($SharePath) { $SharePath.TrimEnd('\') } else { '' }
    if ($onShare -and ($report -eq $share -or $report.StartsWith("$share\", [StringComparison]::OrdinalIgnoreCase))) {
        return [pscustomobject]@{ Local = $ShareDrive.TrimEnd('\') + '\' + $report.Substring($share.Length).TrimStart('\'); Map = $null; Unc = $report }
    }
    [pscustomobject]@{ Local = 'R:\'; Map = $report; Unc = $report }
}

function Start-DeployStatus {
    # Begins reporting for this PC. Returns the status id.
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)]$Identity,     # Get-HardwareIdentity
        [string]$MacAddress,
        [string]$IpAddress,
        [string[]]$LogPath = @('X:\Windows\Temp\Deploy.log')
    )
    $script:Folder = $Folder
    $script:LogPaths = $LogPath
    $now = (Get-Date).ToString('o')
    $script:Record = [ordered]@{
        id           = Get-StatusId -Serial $Identity.Serial -MacAddress $MacAddress
        computerName = ''
        serial       = $Identity.Serial
        maker        = $Identity.Maker
        model        = $Identity.Model
        macAddress   = $MacAddress
        ipAddress    = $IpAddress
        answerFile   = ''
        image        = ''
        driverPack   = ''
        state        = 'Running'
        phase        = 'WinPE'
        step         = 'Starting'
        percent      = 0
        message      = ''
        started      = $now
        updated      = $now
        finished     = $null
        logFile      = ''
        warnings     = @()
    }
    try { New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null } catch { Write-StatusWarning $_ }
    Save-DeployStatus
    $script:Record.id
}

function Resume-DeployStatus {
    # Picks up the record WinPE wrote, at first boot. Returns $false when the status folder cannot be reached.
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Id, [string[]]$LogPath = @())
    $script:Folder = $Folder
    $script:LogPaths = $LogPath
    try {
        $saved = Get-Content -Raw -Path (Join-Path $Folder "$Id.json") -ErrorAction Stop | ConvertFrom-Json
        $script:Record = [ordered]@{}
        foreach ($p in $saved.PSObject.Properties) { $script:Record[$p.Name] = $p.Value }
        $script:Record.warnings = @($saved.warnings | Where-Object { $_ })
        $true
    } catch { Write-StatusWarning $_; $false }
}

function Set-DeployStatus {
    # Updates the record and rewrites the status and live log. Any field of the record can be set through -Fields.
    param(
        [string]$Step,
        [Nullable[int]]$Percent,
        [ValidateSet('Running', 'Succeeded', 'Warning', 'Failed', 'Cancelled')][string]$State,
        [string]$Phase,
        [string]$Message,
        [string]$Warning,       # appended to the warnings list; the deployment finishes as Warning instead of Succeeded
        [hashtable]$Fields = @{}
    )
    if (-not $script:Record) { return }
    if ($Step)    { $script:Record.step = $Step }
    if ($null -ne $Percent) { $script:Record.percent = [Math]::Max(0, [Math]::Min(100, [int]$Percent)) }
    if ($Phase)   { $script:Record.phase = $Phase }
    if ($PSBoundParameters.ContainsKey('Message')) { $script:Record.message = $Message }
    if ($Warning) { $script:Record.warnings = @($script:Record.warnings) + $Warning }
    foreach ($k in $Fields.Keys) { $script:Record[$k] = $Fields[$k] }
    if ($State) {
        if ($State -eq 'Succeeded' -and @($script:Record.warnings).Count) { $State = 'Warning' }
        $script:Record.state = $State
        if ($State -ne 'Running') { $script:Record.finished = (Get-Date).ToString('o') }
    }
    $script:Record.updated = (Get-Date).ToString('o')
    Save-DeployStatus
}

function Set-DeployCheckResult {
    # Records post-deploy check results (PostDeployChecks.psm1) on the status. Failed or warned checks become one warning,
    # replaced on a re-run, so a deployment that finished as Warning only because of its checks goes back to Succeeded once they pass.
    param([Parameter(Mandatory)][object[]]$Results, [Parameter(Mandatory)]$Summary, [string]$Warning)
    if (-not $script:Record) { return }
    $script:Record.warnings = @(@($script:Record.warnings) | Where-Object { $_ -and "$_" -notlike 'Post-deploy checks:*' })
    if ($Warning) { $script:Record.warnings = @($script:Record.warnings) + $Warning }
    $fields = @{ checks = @($Results); checkResult = $Summary.Result; checkSummary = $Summary.Text; checked = (Get-Date).ToString('o') }
    if ($script:Record.state -in 'Succeeded', 'Warning') {
        foreach ($k in $fields.Keys) { $script:Record[$k] = $fields[$k] }
        $finished = $script:Record.finished
        Set-DeployStatus -State Succeeded      # becomes Warning while any warning remains
        $script:Record.finished = $finished    # a re-run does not change when the deployment finished
        Save-DeployStatus
    } else {
        Set-DeployStatus -Fields $fields
    }
}

function Save-DeployStatus {
    if (-not $script:Folder -or -not $script:Record) { return }
    try {
        # Write then rename, so the console never reads a half-written file.
        $path = Join-Path $script:Folder "$($script:Record.id).json"
        $tmp = "$path.tmp"
        [pscustomobject]$script:Record | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding utf8 -ErrorAction Stop
        Move-Item -Path $tmp -Destination $path -Force -ErrorAction Stop

        $text = foreach ($log in $script:LogPaths) {
            if (Test-Path $log) { [IO.File]::ReadAllText($log) }    # ReadAllText shares the file with the writer
        }
        if ($text) { Set-Content -Path (Join-Path $script:Folder "$($script:Record.id).log") -Value ($text -join "`r`n") -Encoding utf8 -ErrorAction Stop }
    } catch { Write-StatusWarning $_ }
}

function Write-StatusWarning($ErrorRecord) {
    # Once per session, so an unreachable share does not flood the log.
    if ($script:Warned) { return }
    $script:Warned = $true
    Write-Warning "Status reporting to $($script:Folder) failed: $($ErrorRecord.Exception.Message). The deployment continues."
}

function Get-DeployStatusRecord { if ($script:Record) { [pscustomobject]$script:Record } }

function Get-PrimaryNetworkAddress {
    # MAC and IPv4 of the first adapter with an address, for the dashboard. WinPE has WMI, so this works there too.
    try {
        $nic = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop |
            Where-Object { $_.IPAddress } | Select-Object -First 1
        if ($nic) {
            return [pscustomobject]@{ MacAddress = $nic.MACAddress; IpAddress = @($nic.IPAddress | Where-Object { $_ -match '^\d+\.' })[0] }
        }
    } catch { }
    [pscustomobject]@{ MacAddress = $null; IpAddress = $null }
}

#endregion

#region Reading (console)

function Get-StatusFolder {
    # The console reads from deploy-settings reporting.path when set, otherwise <content root>\Status.
    param([Parameter(Mandatory)][string]$ContentRoot, $Settings)
    if ($Settings -and $Settings.PSObject.Properties['reporting'] -and $Settings.reporting.path) { return $Settings.reporting.path }
    Join-Path $ContentRoot 'Status'
}

function Get-DeploymentStatus {
    # One row per PC, newest first. A Running deployment with no update for StaleMinutes shows as Stalled:
    # the PC lost power or the network, hung, or (at first boot) cannot write to the status share.
    param(
        [Parameter(Mandatory)][string]$Folder,
        [int]$StaleMinutes = 45,
        [datetime]$Now = (Get-Date)
    )
    $rows = foreach ($file in Get-ChildItem -Path $Folder -Filter *.json -File -ErrorAction SilentlyContinue) {
        try { $s = Get-Content -Raw -Path $file.FullName -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        $started  = ConvertTo-StatusDate $s.started
        $updated  = ConvertTo-StatusDate $s.updated
        $finished = ConvertTo-StatusDate $s.finished
        $state = $s.state
        if ($state -eq 'Running' -and $updated -and ($Now - $updated).TotalMinutes -ge $StaleMinutes) { $state = 'Stalled' }
        $end = if ($finished) { $finished } elseif ($state -eq 'Running') { $Now } else { $updated }
        $log = [IO.Path]::ChangeExtension($file.FullName, '.log')
        [pscustomobject]@{
            Id           = $s.id
            ComputerName = $s.computerName
            Serial       = $s.serial
            Model        = (@($s.maker, $s.model) | Where-Object { $_ }) -join ' '
            IpAddress    = $s.ipAddress
            MacAddress   = $s.macAddress
            AnswerFile   = $s.answerFile
            Image        = $s.image
            DriverPack   = $s.driverPack
            State        = $state
            Phase        = $s.phase
            Step         = $s.step
            Percent      = [int]$s.percent
            Message      = $s.message
            Warnings     = (@($s.warnings) | Where-Object { $_ }) -join '; '
            CheckResult  = if ($s.PSObject.Properties['checkResult']) { $s.checkResult } else { '' }
            Checks       = if ($s.PSObject.Properties['checkSummary']) { $s.checkSummary } else { '' }
            CheckResults = if ($s.PSObject.Properties['checks']) { @($s.checks | Where-Object { $_ }) } else { @() }
            Checked      = if ($s.PSObject.Properties['checked']) { ConvertTo-StatusDate $s.checked } else { $null }
            Started      = $started
            Updated      = $updated
            Duration     = if ($started -and $end) { Format-Duration ($end - $started) } else { '' }
            LastSeen     = if ($updated) { Format-Duration ($Now - $updated) } else { '' }
            LogPath      = if (Test-Path $log) { $log } else { $null }
            StatusPath   = $file.FullName
        }
    }
    @($rows) | Sort-Object Started -Descending
}

function Get-DeploymentSummary {
    param([object[]]$Rows = @())
    $count = { param($s) @($Rows | Where-Object State -in $s).Count }
    [pscustomobject]@{
        Total     = @($Rows).Count
        Running   = & $count @('Running')
        Succeeded = & $count @('Succeeded')
        Warning   = & $count @('Warning')
        Failed    = & $count @('Failed', 'Stalled')
        Cancelled = & $count @('Cancelled')
    }
}

function Remove-DeploymentStatus {
    # Clears a PC from the dashboard. Its final log in Logs\ is kept.
    param([Parameter(Mandatory)][object[]]$Rows)
    foreach ($r in $Rows) {
        Remove-Item -Path $r.StatusPath -Force -ErrorAction SilentlyContinue
        if ($r.LogPath) { Remove-Item -Path $r.LogPath -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertTo-StatusDate($Value) {
    # ConvertFrom-Json in PowerShell 7 already turns ISO strings into dates; 5.1 leaves them as strings.
    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToLocalTime() }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d.ToLocalTime() }
    $null
}

function Format-Duration([timespan]$Span) {
    if ($Span.TotalSeconds -lt 0) { $Span = [timespan]::Zero }
    if ($Span.TotalHours -ge 24) { return '{0}d {1}h' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours }
    if ($Span.TotalMinutes -ge 60) { return '{0}h {1:00}m' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes }
    '{0}m {1:00}s' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds
}

#endregion

Export-ModuleMember -Function Get-StatusId, Resolve-StatusTarget, Start-DeployStatus, Resume-DeployStatus, Set-DeployStatus, Set-DeployCheckResult,
    Get-DeployStatusRecord, Get-PrimaryNetworkAddress, Get-StatusFolder, Get-DeploymentStatus, Get-DeploymentSummary,
    Remove-DeploymentStatus, Format-Duration
