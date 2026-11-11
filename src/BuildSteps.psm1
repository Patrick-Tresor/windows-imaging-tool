# Step-by-step progress of a media build (New-DeploymentMedia.ps1), for the console's Build progress window.
# The build writes a small JSON file as it goes: every step with its state, percent, short detail and start/end
# times. The console reads it twice a second and draws one row per step: name, elapsed time, bar, Complete.
# Progress is best effort: a failed write never stops the build. PowerShell 5.1 compatible, no Windows-only calls.

$script:Build = $null

function Start-BuildProgress {
    <#
    .SYNOPSIS
        Starts the progress file with every step pending. Steps: @(@('id', 'Name'), ...) in the order they run.
        Without -Path the other functions do nothing, so the build runs the same without the console.
    #>
    param([string]$Path, [string]$Title, [object[]]$Steps, [string]$LogPath)
    if (-not $Path) { $script:Build = $null; return }
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in $Steps) {
        [void]$rows.Add([ordered]@{ id = [string]$s[0]; name = [string]$s[1]; state = 'pending'; percent = -1; detail = ''; started = 0; ended = 0; rateFrom = 0; rateFromPercent = 0 })
    }
    $script:Build = @{
        Path      = $Path
        LastWrite = [Diagnostics.Stopwatch]::StartNew()
        Data      = [ordered]@{ title = $Title; started = (Get-BuildTime); finished = 0; error = ''; log = $LogPath; steps = $rows }
    }
    Save-BuildProgress -Force
}

# Times are Unix milliseconds (UTC): PowerShell 7's ConvertFrom-Json would turn date strings into local DateTimes.
function Get-BuildTime { [int64]([DateTime]::UtcNow - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalMilliseconds }

function Get-BuildStep([string]$Id) {
    if (-not $script:Build) { return $null }
    foreach ($s in $script:Build.Data.steps) { if ($s.id -eq $Id) { return $s } }
    $null
}

function Save-BuildProgress {
    # Writes a temporary file and swaps it in, so the console never reads half a file. At most about three
    # writes a second unless -Force (a step starting or ending).
    param([switch]$Force)
    if (-not $script:Build) { return }
    if (-not $Force -and $script:Build.LastWrite.ElapsedMilliseconds -lt 300) { return }
    $script:Build.LastWrite.Restart()
    $path = $script:Build.Path
    $tmp = "$path.tmp"
    try {
        $json = ConvertTo-Json -InputObject $script:Build.Data -Depth 4
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        for ($try = 0; $try -lt 3; $try++) {
            try {
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
                [IO.File]::Move($tmp, $path)
                break
            } catch { Start-Sleep -Milliseconds 50 }   # the console was reading it
        }
    } catch { Write-Verbose "Build progress not saved: $($_.Exception.Message)" }
}

function Start-BuildStep {
    param([Parameter(Mandatory)][string]$Id, [string]$Detail = '')
    $s = Get-BuildStep $Id
    if (-not $s) { return }
    $s.state = 'running'; $s.percent = -1; $s.detail = $Detail; $s.started = (Get-BuildTime); $s.ended = 0
    $s.rateFrom = 0; $s.rateFromPercent = 0
    Save-BuildProgress -Force
}

function Set-BuildStepProgress {
    # Percent 0-100, or -1 for a bar that only shows the step is busy.
    param([Parameter(Mandatory)][string]$Id, [double]$Percent = -1, [string]$Detail)
    $s = Get-BuildStep $Id
    if (-not $s) { return }
    if ($s.state -ne 'running') { $s.state = 'running'; $s.started = (Get-BuildTime) }
    $s.percent = if ($Percent -lt 0) { -1 } else { [int][Math]::Min(100, [Math]::Floor($Percent)) }
    # The time left is measured from the first percent above 0: DISM first scans every file at 0% (minutes on a
    # big disk), and counting that wait made a 40-minute capture look like 13 hours at 4%.
    if (-not $s.rateFrom -and $s.percent -gt 0) { $s.rateFrom = (Get-BuildTime); $s.rateFromPercent = $s.percent }
    if ($PSBoundParameters.ContainsKey('Detail')) { $s.detail = $Detail }
    Save-BuildProgress
}

function Complete-BuildStep {
    # Done; -State reused (taken from the WinPE build cache), skipped (nothing to do this time) or failed (this step
    # only, the others go on: one driver pack of several).
    param([Parameter(Mandatory)][string]$Id, [string]$Detail, [ValidateSet('done', 'reused', 'skipped', 'failed')][string]$State = 'done')
    $s = Get-BuildStep $Id
    if (-not $s) { return }
    $now = Get-BuildTime
    if (-not $s.started) { $s.started = $now }
    $s.state = $State; $s.ended = $now
    if ($State -ne 'failed') { $s.percent = 100 }
    if ($PSBoundParameters.ContainsKey('Detail')) { $s.detail = $Detail }
    Save-BuildProgress -Force
}

function Stop-BuildProgress {
    # The end of the build: -Message marks the running step failed with a one-line message (details are in the log).
    param([string]$Message)
    if (-not $script:Build) { return }
    $now = Get-BuildTime
    if ($Message) {
        $line = (@("$Message" -split "`r?`n" | Where-Object { $_.Trim() })[0])
        $script:Build.Data.error = if ($line) { $line.Trim() } else { 'The build stopped.' }
        foreach ($s in $script:Build.Data.steps) { if ($s.state -eq 'running') { $s.state = 'failed'; $s.ended = $now } }
    } else {
        # A step the build never reached (an option that turned out not to apply) shows as not needed.
        foreach ($s in $script:Build.Data.steps) {
            if ($s.state -eq 'running') { $s.state = 'done'; $s.percent = 100; $s.ended = $now }
            elseif ($s.state -eq 'pending') { $s.state = 'skipped'; $s.percent = 100; $s.ended = $now; $s.started = $now }
        }
    }
    $script:Build.Data.finished = $now
    Save-BuildProgress -Force
}

function Read-BuildProgress {
    # The progress file, or $null while it is missing or being swapped.
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not [IO.File]::Exists($Path)) { return $null }
        [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch { $null }
}

function ConvertFrom-BuildTime($Value) {
    $ms = [int64]0
    if (-not [int64]::TryParse("$Value", [ref]$ms) -or $ms -le 0) { return $null }
    [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddMilliseconds($ms)
}

function Format-BuildElapsed {
    # 82 -> '01:22', 3725 -> '1:02:05'.
    param([double]$Seconds)
    $t = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    if ($t.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds) }
    '{0:00}:{1:00}' -f $t.Minutes, $t.Seconds
}

function Format-TimeLeft {
    # How long a step still needs, from how long it has run and how far it is: 'about 4 min left'. Nothing until
    # the step has run 15 seconds and passed 2%, when the guess would still jump around. -FromPercent is where the
    # step was when ElapsedSeconds started counting; the guess waits until it has moved 1% since.
    param([double]$ElapsedSeconds, [double]$Percent, [double]$FromPercent = 0)
    if ($ElapsedSeconds -lt 15 -or $Percent -lt 2 -or $Percent -ge 100 -or ($Percent - $FromPercent) -lt 1) { return '' }
    $left = $ElapsedSeconds * (100 - $Percent) / ($Percent - $FromPercent)
    if ($left -lt 60) { return 'under 1 min left' }
    $minutes = [int][Math]::Ceiling($left / 60)
    if ($minutes -lt 60) { return "about $minutes min left" }
    'about {0} h {1:00} min left' -f [int][Math]::Floor($minutes / 60), ($minutes % 60)
}

function Get-BuildStepView {
    <#
    .SYNOPSIS
        What the Build progress window shows, from Read-BuildProgress: one row per step and a summary line.
        Now (UTC) is a parameter so tests get fixed times.
    #>
    param([Parameter(Mandatory)]$Data, [DateTime]$Now = [DateTime]::UtcNow)
    $Now = $Now.ToUniversalTime()
    $rows = @(foreach ($s in @($Data.steps)) {
        $start = ConvertFrom-BuildTime $s.started
        $end = ConvertFrom-BuildTime $s.ended
        $secs = if ($start) { ($(if ($end) { $end } else { $Now }) - $start).TotalSeconds } else { 0 }
        $state = "$($s.state)"
        $status = switch ($state) {
            'done'    { 'Complete' }
            'reused'  { 'Reused' }
            'skipped' { 'Not needed' }
            'failed'  { 'Failed' }
            'running' {
                if ([int]$s.percent -ge 0) {
                    $from = ConvertFrom-BuildTime $s.rateFrom
                    $left = if ($from) {
                        Format-TimeLeft -ElapsedSeconds ($Now - $from).TotalSeconds -Percent ([int]$s.percent) -FromPercent ([int]$s.rateFromPercent)
                    } else { Format-TimeLeft -ElapsedSeconds $secs -Percent ([int]$s.percent) }
                    "$([int]$s.percent)%$(if ($left) { ", $left" })"
                } else { '' }
            }
            default   { '' }
        }
        [pscustomobject]@{
            Id            = "$($s.id)"
            Name          = "$($s.name)"
            State         = $state
            Time          = $(if ($start -and $state -ne 'skipped') { Format-BuildElapsed $secs } else { '' })
            Percent       = $(if ($state -in 'done', 'reused', 'skipped') { 100 } elseif ([int]$s.percent -ge 0) { [int]$s.percent } else { 0 })
            Indeterminate = ($state -eq 'running' -and [int]$s.percent -lt 0)
            Status        = $status
            Detail        = "$($s.detail)"
        }
    })
    $begin = ConvertFrom-BuildTime $Data.started
    $finish = ConvertFrom-BuildTime $Data.finished
    $total = if ($begin) { ($(if ($finish) { $finish } else { $Now }) - $begin).TotalSeconds } else { 0 }
    $running = @($rows | Where-Object State -eq 'running')
    $summary = if ($Data.error) { "Failed: $($Data.error)" }
        elseif ($finish) { "Done in $(Format-BuildElapsed $total)" }
        elseif ($running) { "$($running[0].Name)..." }
        else { 'Starting...' }
    [pscustomobject]@{
        Title    = "$($Data.title)"
        Rows     = $rows
        Summary  = $summary
        Elapsed  = Format-BuildElapsed $total
        Finished = [bool]$finish
        Failed   = [bool]$Data.error
        Log      = "$($Data.log)"
    }
}

Export-ModuleMember -Function Start-BuildProgress, Start-BuildStep, Set-BuildStepProgress, Complete-BuildStep, Stop-BuildProgress,
    Read-BuildProgress, Get-BuildStepView, Format-BuildElapsed, Format-TimeLeft
