# Deployment status reporting for the dashboard.
# Deploy-Image.ps1 (WinPE) and FirstBoot.ps1 (the new Windows) write Status\<id>.json and a live copy of the log,
# Status\<id>.log; the console reads them. PowerShell 5.1 compatible, no UI code, so it can be tested without Windows.
# Reporting is best effort: a failed write is a warning and never stops a deployment.

$script:Folder   = $null   # where this deployment's status is written
$script:Record   = $null   # the status record, kept in memory and rewritten on each update
$script:LogPaths = @()     # logs concatenated into Status\<id>.log
$script:Warned   = $false
$script:LocalPath = $null  # this PC's own copy for the progress window in WinPE (DeployProgress.psm1), kept even without a dashboard
$script:Local     = $null

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

function Get-RealSharePath([string]$Path) {
    # The share from deploy-settings.json, or '' for none or the shipped example (\\deploy-server\Deploy), which
    # points at no real server: a content root nobody has set up yet keeps its status in <content root>\Status.
    $p = "$Path".Trim().TrimEnd('\')
    if ($p -match '^\\\\(deploy-server|server|yourserver)\\') { return '' }
    $p
}

function Resolve-StatusTarget {
    # Works out where WinPE writes status and which UNC path, if any, the new Windows can report to at first boot.
    # With a share in the settings every deploy reports to <share>\Status, USB deploys too (mapped as R:; when the
    # share can't be reached, Deploy-Image keeps the status on the stick). Without a share: <content root>\Status.
    #   ReportPath (old setups' reporting.path) under the share: written through the share's drive letter.
    #   ReportPath elsewhere:          mapped as R:.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [string]$SharePath,          # deploy-settings share.path
        [string]$ReportPath,         # deploy-settings reporting.path
        [string]$ShareDrive = 'Z:\'  # where Find-ContentRoot maps the share
    )
    $onShare = $SharePath -and $ContentRoot.TrimEnd('\') -eq $ShareDrive.TrimEnd('\')
    $realShare = Get-RealSharePath $SharePath
    if (-not $ReportPath -and $realShare -and -not $onShare) { $ReportPath = $realShare + '\Status' }
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

function New-StatusRecord {
    # The fields the dashboard record and the local progress file share, so they are typed once. -First goes in
    # front (the id), -Extra after the shared ones.
    param($Identity, $First = [ordered]@{}, $Extra = [ordered]@{})
    $now = (Get-Date).ToString('o')
    $r = [ordered]@{}
    foreach ($k in $First.Keys) { $r[$k] = $First[$k] }
    $r.computerName = ''
    $r.serial       = "$($Identity.Serial)"
    $r.maker        = "$($Identity.Maker)"
    $r.model        = "$($Identity.Model)"
    $r.sku          = "$($Identity.Sku)"
    $r.machineType  = "$($Identity.MachineType)"
    $r.answerFile   = ''
    $r.image        = ''
    $r.driverPack   = ''
    $r.driverStatus = ''
    $r.state        = 'Running'
    $r.phase        = 'WinPE'
    $r.step         = 'Starting'
    $r.percent      = 0
    $r.message      = ''
    foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
    $r.started      = $now
    $r.updated      = $now
    $r.finished     = $null
    $r.warnings     = @()
    $r
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
    $script:Record = New-StatusRecord -Identity $Identity -First ([ordered]@{ id = Get-StatusId -Serial $Identity.Serial -MacAddress $MacAddress }) `
        -Extra ([ordered]@{ macAddress = $MacAddress; ipAddress = $IpAddress; logFile = '' })
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
    # The local progress file (Start-LocalProgress) gets every update too; -LocalOnly updates only that one, for
    # changes the dashboard does not need, such as each second of a countdown.
    param(
        [string]$Step,
        [Nullable[int]]$Percent,
        [ValidateSet('Running', 'Succeeded', 'Warning', 'Failed', 'Cancelled')][string]$State,
        [string]$Phase,
        [string]$Message,
        [string]$Warning,       # appended to the warnings list; the deployment finishes as Warning instead of Succeeded
        [hashtable]$Fields = @{},
        [switch]$LocalOnly
    )
    $update = @{}
    foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'LocalOnly') { $update[$k] = $PSBoundParameters[$k] } }
    if ($script:Local) {
        Update-StatusRecord -Record $script:Local @update
        Save-LocalProgress
    }
    if ($LocalOnly -or -not $script:Record) { return }
    Update-StatusRecord -Record $script:Record @update
    Save-DeployStatus
}

function Update-StatusRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [string]$Step,
        [Nullable[int]]$Percent,
        [string]$State,
        [string]$Phase,
        [string]$Message,
        [string]$Warning,
        [hashtable]$Fields = @{}
    )
    if ($Step)    { $Record.step = $Step }
    if ($null -ne $Percent) { $Record.percent = [Math]::Max(0, [Math]::Min(100, [int]$Percent)) }
    if ($Phase)   { $Record.phase = $Phase }
    if ($PSBoundParameters.ContainsKey('Message')) { $Record.message = $Message }
    if ($Warning) { $Record.warnings = @($Record.warnings) + $Warning }
    foreach ($k in $Fields.Keys) { $Record[$k] = $Fields[$k] }
    if ($State) {
        if ($State -eq 'Succeeded' -and @($Record.warnings).Count) { $State = 'Warning' }
        $Record.state = $State
        if ($State -ne 'Running') { $Record.finished = (Get-Date).ToString('o') }
    }
    $Record.updated = (Get-Date).ToString('o')
}

function Start-LocalProgress {
    # Starts the progress file that the window on this PC's screen reads (DeployProgressWindow.ps1). Unlike the
    # dashboard record it needs no share, so it is written for every deployment.
    param(
        [Parameter(Mandatory)][string]$Path,
        $Identity
    )
    $script:LocalPath = $Path
    $script:Local = New-StatusRecord -Identity $Identity `
        -Extra ([ordered]@{ countdown = 0; whenDone = ''; removeMedia = 0; removableMedia = $false })
    Remove-Item -Path (Get-ProgressCancelPath $Path) -Force -ErrorAction SilentlyContinue
    Save-LocalProgress
}

function Save-LocalProgress {
    if (-not $script:LocalPath -or -not $script:Local) { return }
    try {
        $tmp = "$($script:LocalPath).tmp"
        [pscustomobject]$script:Local | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding utf8 -ErrorAction Stop
        Move-Item -Path $tmp -Destination $script:LocalPath -Force -ErrorAction Stop
    } catch { }   # the window just shows the previous step
}

function Get-ProgressCancelPath([string]$Path) { "$Path.cancel" }

function Receive-ProgressCancel {
    # True once when the progress window asked to stop the countdown (its "Change settings" button writes the file).
    param([string]$Path = $script:LocalPath)
    if (-not $Path) { return $false }
    $flag = Get-ProgressCancelPath $Path
    if (-not (Test-Path -LiteralPath $flag)) { return $false }
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    $true
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
    # The console reads from <share>\Status when deploy-settings has a share (every deploy reports there),
    # an old setup's reporting.path when set, otherwise <content root>\Status.
    param([Parameter(Mandatory)][string]$ContentRoot, $Settings)
    if ($Settings -and $Settings.PSObject.Properties['reporting'] -and $Settings.reporting -and $Settings.reporting.path) { return $Settings.reporting.path }
    $share = if ($Settings -and $Settings.PSObject.Properties['share'] -and $Settings.share) { Get-RealSharePath $Settings.share.path } else { '' }
    if ($share) { return $share + '\Status' }
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
        $result = $null
        try {
            $deploy = [pscustomobject]@{ computerName = $s.computerName; maker = $s.maker; model = $s.model; answerFile = $s.answerFile; image = $s.image
                driverPack = $s.driverPack; driversAdded = $(if ($s.PSObject.Properties['driversAdded']) { $s.driversAdded }); toolVersion = $(if ($s.PSObject.Properties['toolVersion']) { $s.toolVersion })
                started = $s.started; finished = $s.finished; state = $state; message = $s.message }
            $result = Get-DeployResultSummary -Deploy $deploy -Checks $(if ($s.PSObject.Properties['checks']) { @($s.checks) } else { @() }) -Now $Now
        } catch { $result = $null }
        # State and Result say the same thing: a finished deployment whose checks found a problem shows it in State too
        # (Not ready when something failed, Warning when only warnings), so the row colour and the counts match Result.
        if ($result -and $state -in 'Succeeded', 'Warning') {
            if ($result.Result -eq 'NotReady') { $state = 'Not ready' }
            elseif ($result.Result -eq 'Warning') { $state = 'Warning' }
        }
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
            LogPath      = if (Test-Path $log) { $log } else { $null }
            LogFile      = if ($s.PSObject.Properties['logFile']) { "$($s.logFile)" } else { '' }
            StatusPath   = $file.FullName
            ToolVersion  = if ($s.PSObject.Properties['toolVersion']) { $s.toolVersion } else { '' }
            Result       = if ($result) { $result.Verdict } else { '' }
            ResultState  = if ($result) { $result.Result } else { '' }
            ResultText   = if ($result) { $result.Text } else { '' }
            ResultLines  = if ($result) { @($result.Lines) } else { @() }
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
        Failed    = & $count @('Failed', 'Stalled', 'Not ready')
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

function Get-ExpiredDeployments {
    # Finished PCs (Succeeded, Warning, Cancelled; not Failed or Not ready) not heard from for -Days: the console moves them off the Dashboard
    # by itself (there is no Clear finished button). Their final log stays under History.
    param([AllowEmptyCollection()][object[]]$Rows, [int]$Days = 7, [datetime]$Now = (Get-Date))
    @($Rows | Where-Object { $_.State -in 'Succeeded', 'Warning', 'Cancelled' -and $_.Updated -and $_.Updated -lt $Now.AddDays(-$Days) })
}

function Import-StickDeployStatus {
    <#
    .SYNOPSIS
        Moves the status of PCs deployed from a USB stick into the dashboard folder. Without a network folder to report
        to, WinPE writes Status\<id>.json on the stick's DEPLOY partition; the console calls this when the stick is
        plugged in, so those deployments show too. A record already in the dashboard folder is replaced only when the
        stick's copy is newer. The stick's copies are removed once moved, so a PC cleared from the dashboard does not
        come back. Final logs in the stick's Logs folder are copied to the content root's Logs (kept on the stick).
        Returns how many deployments were imported.
    #>
    param(
        [Parameter(Mandatory)][string]$StickRoot,   # the DEPLOY partition, for example E:\
        [Parameter(Mandatory)][string]$Folder,      # the dashboard folder (Get-StatusFolder)
        [string]$LogFolder                          # <content root>\Logs
    )
    $src = [IO.Path]::Combine($StickRoot, 'Status')
    $count = 0
    $same = { param($a, $b) [IO.Path]::GetFullPath($a).TrimEnd('\', '/') -eq [IO.Path]::GetFullPath($b).TrimEnd('\', '/') }
    if ([IO.Directory]::Exists($src) -and -not (& $same $src $Folder)) {
        foreach ($file in [IO.Directory]::GetFiles($src, '*.json')) {
            try { $s = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { continue }   # a half-written or foreign file
            if (-not $s.id) { continue }
            [void][IO.Directory]::CreateDirectory($Folder)
            $name = [IO.Path]::GetFileName($file)
            $target = [IO.Path]::Combine($Folder, $name)
            $newer = $true
            if ([IO.File]::Exists($target)) {
                try {
                    $old = [IO.File]::ReadAllText($target) | ConvertFrom-Json
                    $a = ConvertTo-StatusDate $s.updated; $b = ConvertTo-StatusDate $old.updated
                    $newer = -not $b -or ($a -and $a -gt $b)
                } catch { }
            }
            $log = [IO.Path]::ChangeExtension($file, '.log')
            if ($newer) {
                [IO.File]::Copy($file, $target, $true)
                if ([IO.File]::Exists($log)) { [IO.File]::Copy($log, [IO.Path]::ChangeExtension($target, '.log'), $true) }
                $count++
            }
            [IO.File]::Delete($file)
            if ([IO.File]::Exists($log)) { [IO.File]::Delete($log) }
        }
    }
    $logs = [IO.Path]::Combine($StickRoot, 'Logs')
    if ($LogFolder -and [IO.Directory]::Exists($logs) -and -not (& $same $logs $LogFolder)) {
        foreach ($file in [IO.Directory]::GetFiles($logs, '*.log')) {
            $target = [IO.Path]::Combine($LogFolder, [IO.Path]::GetFileName($file))
            if ([IO.File]::Exists($target)) { continue }
            [void][IO.Directory]::CreateDirectory($LogFolder)
            [IO.File]::Copy($file, $target)
        }
    }
    $count
}

function Get-DeployResultSummary {
    <#
    .SYNOPSIS
        One clear result for a deployment: is the PC ready, and drivers, applications, tasks, domain join, BitLocker
        and total time in one line each. Used by the console's Dashboard and by FirstBoot.ps1 (DeployResult.txt).
    .DESCRIPTION
        -Deploy holds what WinPE recorded (status record or firstboot.json's deploy part): computerName, maker, model,
        answerFile, image, driverPack, driversAdded, toolVersion, started, and when known finished, state, message.
        -Checks are the post-deploy check results ({ name, result, detail }). Returns { Verdict, Result, Lines, Text }:
        Result is Ready, Warning, NotReady, Failed or Running; each line is { Item, Result (OK, Warning, Failed, Info), Detail }.
    #>
    param([Parameter(Mandatory)]$Deploy, [object[]]$Checks = @(), [datetime]$Now = (Get-Date))
    $get = { param($n) if ($Deploy -and $Deploy.PSObject.Properties[$n]) { $Deploy.$n } else { $null } }
    $Checks = @($Checks | Where-Object { $_ })
    $lines = [Collections.Generic.List[object]]::new()
    $add = { param($item, $result, $detail) $lines.Add([pscustomobject]@{ Item = $item; Result = $result; Detail = "$detail" }) }
    # Applications and tasks that did not pass, by line and result, so the verdict can name them (Not ready: Chrome failed).
    $named = @{}
    $fromCheck = { param($r) switch ("$r") { 'Passed' { 'OK' } 'Failed' { 'Failed' } 'Warning' { 'Warning' } default { 'Info' } } }

    $pc = (@((& $get 'maker'), (& $get 'model')) | Where-Object { $_ }) -join ' '
    & $add 'Windows' 'OK' ((@("$(& $get 'image')", $(if (& $get 'answerFile') { "answer file $(& $get 'answerFile')" })) | Where-Object { $_ }) -join ', ')

    # Drivers: the pack WinPE added, and the Device drivers check (errors in Device Manager) when it ran.
    $pack = "$(& $get 'driverPack')"
    $added = & $get 'driversAdded'
    $devCheck = @($Checks | Where-Object name -eq 'Device drivers') | Select-Object -First 1
    $driverText = if (-not $pack -or $pack -eq 'inbox only') { "No driver pack for $(if ($pc) { $pc } else { 'this model' }): Windows' own drivers" }
                  elseif ($null -ne $added -and "$added" -ne '') { "$pack, $added driver(s) added" } else { $pack }
    $driverResult = if ($devCheck) { & $fromCheck $devCheck.result } elseif (-not $pack -or $pack -eq 'inbox only') { 'Warning' } else { 'OK' }
    if ($devCheck -and $devCheck.result -ne 'Passed') { $driverText += "; $($devCheck.detail)" }
    elseif ($driverResult -eq 'OK' -and (-not $pack -or $pack -eq 'inbox only')) { $driverResult = 'Warning' }
    & $add 'Drivers' $driverResult $driverText

    foreach ($kind in @(@('Applications', 'App: ', 'installed'), @('Tasks', 'Task: ', 'succeeded'))) {
        $list = @($Checks | Where-Object { "$($_.name)".StartsWith($kind[1]) })
        if (-not $list) { continue }
        $bad = @($list | Where-Object result -ne 'Passed')
        $text = '{0} of {1} {2}' -f ($list.Count - $bad.Count), $list.Count, $kind[2]
        if ($bad) { $text += ': ' + (($bad | ForEach-Object { "$("$($_.name)".Substring($kind[1].Length)) ($($_.detail))" }) -join '; ') }
        foreach ($b in $bad) {
            $key = "$($kind[0])|$(if ($b.result -eq 'Failed') { 'Failed' } else { 'Warning' })"
            if (-not $named[$key]) { $named[$key] = [Collections.Generic.List[string]]::new() }
            $named[$key].Add("$($b.name)".Substring($kind[1].Length))
        }
        & $add $kind[0] $(if (@($bad | Where-Object result -eq 'Failed')) { 'Failed' } elseif ($bad) { 'Warning' } else { 'OK' }) $text
    }
    foreach ($name in 'Computer name', 'Domain join', 'Workgroup', 'BitLocker') {
        $c = @($Checks | Where-Object name -eq $name) | Select-Object -First 1
        if ($c) { & $add $name (& $fromCheck $c.result) $c.detail }
    }

    $started = ConvertTo-StatusDate (& $get 'started')
    $finished = ConvertTo-StatusDate (& $get 'finished')
    $state = "$(& $get 'state')"
    if ($started) {
        $end = if ($finished) { $finished } else { $Now }
        & $add 'Total time' 'Info' ((Format-Duration ($end - $started)) + $(if (-not $finished -and $state -in 'Running', '') { ' so far' } else { '' }))
    }
    if (& $get 'toolVersion') { & $add 'Tool version' 'Info' (& $get 'toolVersion') }

    $result = if ($state -eq 'Failed') { 'Failed' } elseif ($state -in 'Running', 'Stalled') { 'Running' }
              elseif (@($lines | Where-Object Result -eq 'Failed')) { 'NotReady' } elseif (@($lines | Where-Object Result -eq 'Warning')) { 'Warning' } else { 'Ready' }
    # The parts with this result: an application or task line gives the names of those that did not pass.
    $parts = { param($r) @($lines | Where-Object Result -eq $r | ForEach-Object {
        $n = $named["$($_.Item)|$r"]
        if ($n) { $n } else { $_.Item }
    }) -join ', ' }
    $verdict = switch ($result) {
        'Failed'   { "Deployment failed: $(& $get 'message')".TrimEnd(': ') }
        'Running'  { if ($state -eq 'Stalled') { 'Not finished: the PC stopped reporting' } else { 'Still deploying' } }
        'NotReady' { 'Not ready: ' + (& $parts 'Failed') + ' failed' }
        'Warning'  { 'Ready, with warnings: ' + (& $parts 'Warning') }
        default    { 'Ready' }
    }
    $head = (@((& $get 'computerName'), $(if ($pc) { "($pc)" })) | Where-Object { $_ }) -join ' '
    $textLines = @($(if ($head) { "$head - $verdict" } else { $verdict })) +
        @($lines | ForEach-Object { '  {0,-8} {1,-13} {2}' -f $(switch ($_.Result) { 'OK' { 'OK' } 'Failed' { 'FAILED' } 'Warning' { 'WARNING' } default { '' } }), $_.Item, $_.Detail })
    [pscustomobject]@{ Verdict = $verdict; Result = $result; Lines = $lines.ToArray(); Text = ($textLines -join [Environment]::NewLine) }
}

function Set-AppCheckResults {
    <#
    .SYNOPSIS
        A check list with each app's new result in place of its old one ('App: <name>', Passed or Failed), for an app
        installed again after first boot (the logon retry, or the agent's Retry failed apps). Returns the new list.
    #>
    param([AllowEmptyCollection()][object[]]$Checks = @(), [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results, [string]$By = 'a retry', [datetime]$Now = (Get-Date))
    $list = [Collections.Generic.List[object]]::new()
    foreach ($c in @($Checks)) { if ($c) { $list.Add($c) } }
    foreach ($x in $Results) {
        $name = "App: $($x.name)"
        $result = if ($x.ok) { 'Passed' } else { 'Failed' }
        $detail = if ($x.ok) { "Installed by $By $($Now.ToString('yyyy-MM-dd HH:mm'))$(if ($x.message) { ": $($x.message)" })" } else { "$($x.status): $($x.message)" }
        $old = @($list | Where-Object name -eq $name) | Select-Object -First 1
        $new = [pscustomobject]@{ name = $name; result = $result; detail = $detail }
        if ($old) { $list[$list.IndexOf($old)] = $new } else { $list.Add($new) }
    }
    ,$list.ToArray()
}

function Update-DeployAppResults {
    <#
    .SYNOPSIS
        PC: puts each app's new result (installed again after first boot) into this PC's deployment status
        (<status folder>\<id>.json, the Dashboard's row) and a line in its live log. A check that passes now drops that
        app's warning; with nothing failed or warned any more, the deployment goes back to Succeeded.
        -Results: { name, ok, status, message } per app. Returns the record, or $null when there is none.
    #>
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
          [string]$By = 'a retry', [datetime]$Now = (Get-Date))
    $file = ($Id.Trim() -replace '[\\/:*?"<>|\s]', '_')
    $path = [IO.Path]::Combine($StatusFolder, "$file.json")
    if (-not [IO.File]::Exists($path)) { return $null }
    $r = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $checks = Set-AppCheckResults -Checks @(if ($r.PSObject.Properties['checks']) { @($r.checks) }) -Results $Results -By $By -Now $Now
    $warnings = @(if ($r.PSObject.Properties['warnings']) { @($r.warnings) | Where-Object { $_ } })
    foreach ($x in @($Results | Where-Object { $_.ok })) { $warnings = @($warnings | Where-Object { "$_" -notlike "$($x.name) failed*" }) }
    if (-not @($checks | Where-Object { $_.result -in 'Failed', 'Warning' })) { $warnings = @($warnings | Where-Object { "$_" -notlike 'Post-deploy checks:*' }) }
    $who = (Get-Culture).TextInfo.ToTitleCase(($By -replace '^(the|a) ', ''))
    $logLines = @($Results | ForEach-Object {
        '{0:yyyy-MM-dd HH:mm:ss} [INFO] {1}: {2} {3} ({4}){5}' -f $Now, $who, $_.name, $(if ($_.ok) { 'installed' } else { 'FAILED' }), $_.status, $(if ($_.message) { ": $($_.message)" })
    })
    $set = { param($n, $v) $r | Add-Member -NotePropertyName $n -NotePropertyValue $v -Force }
    & $set 'checks' @($checks)
    & $set 'warnings' @($warnings)
    & $set 'updated' $Now.ToString('o')
    if ("$($r.state)" -in 'Succeeded', 'Warning') { & $set 'state' $(if ($warnings) { 'Warning' } else { 'Succeeded' }) }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $r -Depth 8), (New-Object Text.UTF8Encoding $false))
    [IO.File]::Copy($tmp, $path, $true); [IO.File]::Delete($tmp)
    if ($logLines) { try { [IO.File]::AppendAllText([IO.Path]::ChangeExtension($path, '.log'), (($logLines -join "`r`n") + "`r`n")) } catch { } }
    $r
}

function Update-DeployCheckResults {
    <#
    .SYNOPSIS
        PC: puts checks run again after first boot (the agent's BitLocker check, once a FIRSTLOGON task turned it on)
        into this PC's deployment status (<status folder>\<id>.json, the Dashboard's row) and a line in its live log.
        Each result replaces the check of the same name. -CheckWarning gets the whole new list and returns the
        'Post-deploy checks: ...' warning (or nothing); without it that warning only goes once nothing fails or warns.
        Returns the record, or $null when there is none.
    #>
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
          [scriptblock]$CheckWarning, [string]$By = 'the agent', [datetime]$Now = (Get-Date))
    $file = ($Id.Trim() -replace '[\\/:*?"<>|\s]', '_')
    $path = [IO.Path]::Combine($StatusFolder, "$file.json")
    if (-not [IO.File]::Exists($path)) { return $null }
    $r = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $list = [Collections.Generic.List[object]]::new()
    foreach ($c in @(if ($r.PSObject.Properties['checks']) { @($r.checks) })) { if ($c) { $list.Add($c) } }
    foreach ($x in $Results) {
        $old = @($list | Where-Object name -eq $x.name) | Select-Object -First 1
        $new = [pscustomobject]@{ name = "$($x.name)"; result = "$($x.result)"; detail = "$($x.detail)" }
        if ($old) { $list[$list.IndexOf($old)] = $new } else { $list.Add($new) }
    }
    $checks = $list.ToArray()
    $warnings = @(if ($r.PSObject.Properties['warnings']) { @($r.warnings) | Where-Object { $_ } })
    if ($CheckWarning) {
        $w = & $CheckWarning $checks
        $warnings = @(@($warnings | Where-Object { "$_" -notlike 'Post-deploy checks:*' }) + @($w | Where-Object { $_ }))
    } elseif (-not @($checks | Where-Object { $_.result -in 'Failed', 'Warning' })) {
        $warnings = @($warnings | Where-Object { "$_" -notlike 'Post-deploy checks:*' })
    }
    $who = (Get-Culture).TextInfo.ToTitleCase(($By -replace '^(the|a) ', ''))
    $logLines = @($Results | ForEach-Object { '{0:yyyy-MM-dd HH:mm:ss} [INFO] {1}: {2} check {3}: {4}' -f $Now, $who, $_.name, $_.result, $_.detail })
    $set = { param($n, $v) $r | Add-Member -NotePropertyName $n -NotePropertyValue $v -Force }
    & $set 'checks' @($checks)
    & $set 'warnings' @($warnings)
    & $set 'updated' $Now.ToString('o')
    & $set 'checked' $Now.ToString('o')
    if ("$($r.state)" -in 'Succeeded', 'Warning') { & $set 'state' $(if ($warnings) { 'Warning' } else { 'Succeeded' }) }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $r -Depth 8), (New-Object Text.UTF8Encoding $false))
    [IO.File]::Copy($tmp, $path, $true); [IO.File]::Delete($tmp)
    if ($logLines) { try { [IO.File]::AppendAllText([IO.Path]::ChangeExtension($path, '.log'), (($logLines -join "`r`n") + "`r`n")) } catch { } }
    $r
}

function Update-DeployResultText {
    <#
    .SYNOPSIS
        DeployResult.txt (Get-DeployResultSummary's Text) with one line's result and detail changed, and its first
        line's verdict to match: an item that passes now leaves 'Ready, with warnings: ...', and with no warning
        left it says Ready. A 'Not ready' or failed deployment keeps its verdict. -Result: OK, Warning or Failed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Result, [string]$Detail)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($l in ($Text -split '\r?\n')) { $lines.Add($l) }
    while ($lines.Count -and -not $lines[$lines.Count - 1].Trim()) { $lines.RemoveAt($lines.Count - 1) }
    if (-not $lines.Count) { return $Text }
    $mark = switch ($Result) { 'OK' { 'OK' } 'Failed' { 'FAILED' } 'Warning' { 'WARNING' } default { '' } }
    $new = '  {0,-8} {1,-13} {2}' -f $mark, $Item, $Detail
    $at = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^  \S*\s+$([regex]::Escape($Item))(\s|`$)") { $at = $i; break } }
    if ($at -ge 0) { $lines[$at] = $new } else { $lines.Add($new) }
    # The verdict: "<PC> - Ready, with warnings: A, B" (or without the PC part).
    if ($lines[0] -match '^(?<head>.*? - )?Ready, with warnings: (?<list>.*)$') {
        $head = $Matches['head']
        $left = @($Matches['list'] -split ',\s*' | Where-Object { $_ -and ($_ -ne $Item -or $Result -eq 'Warning') })
        if ($Result -eq 'Warning' -and $left -notcontains $Item) { $left += $Item }
        $lines[0] = "$head$(if ($Result -eq 'Failed') { "Not ready: $Item failed" } elseif ($left) { 'Ready, with warnings: ' + ($left -join ', ') } else { 'Ready' })"
    } elseif ($lines[0] -match '^(?<head>.*? - )?Ready$' -and $Result -ne 'OK') {
        $lines[0] = "$($Matches['head'])$(if ($Result -eq 'Failed') { "Not ready: $Item failed" } else { "Ready, with warnings: $Item" })"
    }
    $lines.ToArray() -join [Environment]::NewLine
}

function Get-DeployChecklist {
    <#
    .SYNOPSIS
        The Dashboard's details for one PC: one line per part of the result (Windows, Drivers, Domain join, BitLocker,
        time...), with one line per application and per task instead of their totals, so a failed one shows by name
        with its reason. Each line: { Item, Result (OK, Warning, Failed, Info), Detail }.
    #>
    param([Parameter(Mandatory)]$Row)
    $checks = @(if ($Row.PSObject.Properties['CheckResults']) { @($Row.CheckResults) | Where-Object { $_ } })
    $lines = @(if ($Row.PSObject.Properties['ResultLines']) { @($Row.ResultLines) | Where-Object { $_ } })
    $mark = { param($r) switch ("$r") { 'Passed' { 'OK' } 'Failed' { 'Failed' } 'Warning' { 'Warning' } default { 'Info' } } }
    foreach ($l in $lines) {
        $prefix = switch ($l.Item) { 'Applications' { 'App: ' } 'Tasks' { 'Task: ' } default { '' } }
        $each = if ($prefix) { @($checks | Where-Object { "$($_.name)".StartsWith($prefix) }) } else { @() }
        if ($each) {
            # Failed ones first, then warnings, then the rest in their order.
            $order = { param($c) switch ("$($c.result)") { 'Failed' { 0 } 'Warning' { 1 } default { 2 } } }
            foreach ($c in @($each | Sort-Object { & $order $_ })) {
                [pscustomobject]@{ Item = "$($c.name)".Substring($prefix.Length); Result = (& $mark $c.result); Detail = "$($c.detail)" }
            }
        } else {
            [pscustomobject]@{ Item = $l.Item; Result = $l.Result; Detail = "$($l.Detail)" }
        }
    }
}

function Get-FailedApps {
    # The applications whose post-deploy check did not pass: what Retry failed apps installs again.
    param([Parameter(Mandatory)]$Row)
    @(if ($Row.PSObject.Properties['CheckResults']) {
        @($Row.CheckResults) | Where-Object { $_ -and "$($_.name)".StartsWith('App: ') -and $_.result -ne 'Passed' } | ForEach-Object { "$($_.name)".Substring(5) }
    })
}

function Get-DeployNotices {
    <#
    .SYNOPSIS
        What changed since the last Dashboard read that is worth a notification: a PC that finished (Succeeded,
        Warning, Not ready), failed or stalled. -Previous: Id -> State from the last read ($null on the first read:
        no notice for what was already there). Returns { Id, Title, Text, Bad }.
    #>
    param([object[]]$Rows = @(), [hashtable]$Previous)
    if ($null -eq $Previous) { return }
    foreach ($r in $Rows) {
        $was = $Previous["$($r.Id)"]
        if ($was -eq $r.State -or $r.State -in 'Running', 'Cancelled') { continue }
        if ($null -ne $was -and $was -ne 'Running') { continue }
        $name = if ($r.ComputerName) { $r.ComputerName } else { $r.Serial }
        $title = switch ($r.State) {
            'Succeeded' { "$name is ready" }
            'Warning'   { "$name finished with warnings" }
            'Not ready' { "$name is not ready" }
            'Failed'    { "$name failed to deploy" }
            'Stalled'   { "$name stopped reporting" }
            default     { "${name}: $($r.State)" }
        }
        $text = if ($r.Result) { "$($r.Result)" } elseif ($r.Step) { "$($r.Step)" } else { "$($r.Model)" }
        [pscustomobject]@{ Id = "$($r.Id)"; Title = $title; Text = $text; Bad = ($r.State -in 'Failed', 'Stalled', 'Not ready') }
    }
}

function Get-DeployStickRoots {
    # DEPLOY partitions of sticks this tool built that are plugged into this PC. DriveInfo, not Get-Volume: the
    # dashboard calls this every 10 seconds.
    @([IO.DriveInfo]::GetDrives() | Where-Object {
        try { $_.IsReady -and $_.VolumeLabel -eq 'DEPLOY' -and [IO.Directory]::Exists([IO.Path]::Combine($_.RootDirectory.FullName, 'Images')) } catch { $false }
    } | ForEach-Object { $_.RootDirectory.FullName })
}

function ConvertTo-StatusDate($Value) {
    # ConvertFrom-Json in PowerShell 7 already turns ISO strings into dates; 5.1 leaves them as strings.
    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToLocalTime() }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d.ToLocalTime() }
    $null
}

function Format-Duration($Span) {
    # The one duration formatter (dashboard, WinPE progress window, media build and USB copy): a timespan or a
    # number of seconds. 42 -> '42s', 192 -> '3m 12s', 3900 -> '1h 05m', 2 days -> '2d 0h'.
    if ($Span -isnot [timespan]) { $Span = [timespan]::FromSeconds([Math]::Round([double]$Span)) }
    if ($Span.TotalSeconds -lt 0) { $Span = [timespan]::Zero }
    if ($Span.TotalHours -ge 24) { return '{0}d {1}h' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours }
    if ($Span.TotalMinutes -ge 60) { return '{0}h {1:00}m' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes }
    if ($Span.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds }
    '{0}s' -f [int][Math]::Floor($Span.TotalSeconds)
}

#endregion

Export-ModuleMember -Function Get-StatusId, Resolve-StatusTarget, Start-DeployStatus, Resume-DeployStatus, Set-DeployStatus, Set-DeployCheckResult,
    Start-LocalProgress, Get-ProgressCancelPath, Receive-ProgressCancel,
    Get-DeployStatusRecord, Get-PrimaryNetworkAddress, Get-StatusFolder, Get-DeploymentStatus, Get-DeploymentSummary,
    Get-DeployChecklist, Get-FailedApps, Get-DeployNotices, Set-AppCheckResults, Update-DeployAppResults, Update-DeployCheckResults, Update-DeployResultText,
    Remove-DeploymentStatus, Get-ExpiredDeployments, Import-StickDeployStatus, Get-DeployStickRoots, Format-Duration, Get-DeployResultSummary
