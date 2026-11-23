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
            LogFile      = if ($s.PSObject.Properties['logFile']) { "$($s.logFile)" } else { '' }
            StatusPath   = $file.FullName
            ToolVersion  = if ($s.PSObject.Properties['toolVersion']) { $s.toolVersion } else { '' }
            Result       = if ($result) { $result.Verdict } else { '' }
            ResultState  = if ($result) { $result.Result } else { '' }
            ResultText   = if ($result) { $result.Text } else { '' }
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

function Get-ExpiredDeployments {
    # Finished PCs (Succeeded, Warning, Cancelled) not heard from for -Days: the console moves them off the Dashboard
    # by itself, so nobody has to click Clear finished. Their final log stays under Show: History.
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
    $verdict = switch ($result) {
        'Failed'   { "Deployment failed: $(& $get 'message')".TrimEnd(': ') }
        'Running'  { if ($state -eq 'Stalled') { 'Not finished: the PC stopped reporting' } else { 'Still deploying' } }
        'NotReady' { 'Not ready: ' + ((@($lines | Where-Object Result -eq 'Failed' | ForEach-Object Item)) -join ', ') + ' failed' }
        'Warning'  { 'Ready, with warnings: ' + ((@($lines | Where-Object Result -eq 'Warning' | ForEach-Object Item)) -join ', ') }
        default    { 'Ready' }
    }
    $head = (@((& $get 'computerName'), $(if ($pc) { "($pc)" })) | Where-Object { $_ }) -join ' '
    $textLines = @($(if ($head) { "$head - $verdict" } else { $verdict })) +
        @($lines | ForEach-Object { '  {0,-8} {1,-13} {2}' -f $(switch ($_.Result) { 'OK' { 'OK' } 'Failed' { 'FAILED' } 'Warning' { 'WARNING' } default { '' } }), $_.Item, $_.Detail })
    [pscustomobject]@{ Verdict = $verdict; Result = $result; Lines = $lines.ToArray(); Text = ($textLines -join [Environment]::NewLine) }
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
    Remove-DeploymentStatus, Get-ExpiredDeployments, Import-StickDeployStatus, Get-DeployStickRoots, Format-Duration, Get-DeployResultSummary
