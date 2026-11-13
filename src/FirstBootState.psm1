# Where FirstBoot.ps1 is on the deployed PC, kept in C:\Temp\firstboot-progress.json. When the PC restarts in the
# middle of first boot (an installer or a task that restarts it), the startup task ImagingTool\FirstBoot starts
# FirstBoot.ps1 again and it picks up after the last finished step instead of stopping for good.
# Also the icacls arguments that keep the staged first boot files to Administrators and SYSTEM.
# PowerShell 5.1 compatible; nothing Windows-only runs at import.

$script:MaxRuns = 5   # the first run and 4 restarts; an installer that restarts the PC every time gives up there

function New-FirstBootProgress {
    [pscustomobject]@{ runs = 0; started = @(); done = @(); appResults = @(); taskResults = @() }
}

function Read-FirstBootProgress {
    # The saved progress, or a new one when there is none (or it cannot be read).
    param([Parameter(Mandatory)][string]$Path)
    try {
        if ([IO.File]::Exists($Path)) {
            $text = [IO.File]::ReadAllText($Path)
            if ("$text".Trim()) {
                $p = $text | ConvertFrom-Json
                $get = { param($n) if ($p.PSObject.Properties[$n]) { @($p.$n | Where-Object { $null -ne $_ }) } else { @() } }
                return [pscustomobject]@{
                    runs        = if ($p.PSObject.Properties['runs']) { [int]$p.runs } else { 0 }
                    started     = @(& $get 'started')
                    done        = @(& $get 'done')
                    appResults  = @(& $get 'appResults')
                    taskResults = @(& $get 'taskResults')
                }
            }
        }
    } catch { }
    New-FirstBootProgress
}

function Save-FirstBootProgress {
    # Writes over the file in place, so it keeps the Administrators-and-SYSTEM rights WinPE gave it.
    param([Parameter(Mandatory)]$Progress, [Parameter(Mandatory)][string]$Path)
    $o = [ordered]@{
        runs        = [int]$Progress.runs
        started     = @($Progress.started)
        done        = @($Progress.done)
        appResults  = @($Progress.appResults)
        taskResults = @($Progress.taskResults)
    }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $o -Depth 6))
}

function Get-FirstBootStepState {
    # Done (finished in this or an earlier run), Interrupted (started in an earlier run that the PC's restart cut
    # short; only one run goes at a time) or New.
    param([Parameter(Mandatory)]$Progress, [Parameter(Mandatory)][string]$Step)
    if (@($Progress.done) -contains $Step) { return 'Done' }
    if (@($Progress.started) -contains $Step) { return 'Interrupted' }
    'New'
}

function Start-FirstBootStep {
    param([Parameter(Mandatory)]$Progress, [Parameter(Mandatory)][string]$Step)
    if (@($Progress.started) -notcontains $Step) { $Progress.started = @($Progress.started) + $Step }
}

function Complete-FirstBootStep {
    param([Parameter(Mandatory)]$Progress, [Parameter(Mandatory)][string]$Step)
    Start-FirstBootStep -Progress $Progress -Step $Step
    if (@($Progress.done) -notcontains $Step) { $Progress.done = @($Progress.done) + $Step }
}

function Test-FirstBootRunsLeft {
    # False once first boot has started more than -MaxRuns times: something restarts the PC every time.
    param([Parameter(Mandatory)]$Progress, [int]$MaxRuns = $script:MaxRuns)
    [int]$Progress.runs -le $MaxRuns
}

function Get-InterruptedAppResult {
    # The result of an application whose install the PC's restart cut short. It is not run again (an installer that
    # restarts the PC would do it again every time); its detection rule says whether it got installed.
    param([Parameter(Mandatory)]$Detection)
    if ($Detection.HasRules -and $Detection.Detected) {
        return [pscustomobject]@{ Status = 'Installed'; ExitCode = $null; RebootNeeded = $false; Message = 'the PC restarted during the install; found installed afterwards' }
    }
    $why = if ($Detection.HasRules) { 'and it is not detected' } else { 'and it has no detection rule to check it' }
    [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; RebootNeeded = $false; Message = "the PC restarted during the install $why" }
}

function Get-InterruptedTaskResult {
    # The result of a FIRSTBOOT task the PC's restart cut short. It is not run again.
    [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; Message = 'the PC restarted while the task ran; it was not run again' }
}

function Get-FirstBootLock {
    # An open handle no other process can open while this run lasts, or $null when another run holds it. Windows
    # closes it when the process ends, also with a restart, so it never stays stuck.
    param([Parameter(Mandatory)][string]$Path)
    try { [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { $null }
}

function Get-AdminOnlyAclArgs {
    # icacls arguments that leave only Administrators and SYSTEM on Path, with nothing inherited. A folder made at
    # the root of C: lets every signed-in user change it, and C:\Temp holds the BitLocker PIN and installers that
    # run as SYSTEM. A -Folder passes the rights on to what goes in it later. SIDs, so a French Windows
    # (Administrateurs) works the same and WinPE can set them on the offline Windows drive.
    param([Parameter(Mandatory)][string]$Path, [switch]$Folder)
    $r = if ($Folder) { '(OI)(CI)F' } else { 'F' }
    @($Path, '/inheritance:r', '/grant:r', "*S-1-5-32-544:$r", "*S-1-5-18:$r")
}

Export-ModuleMember -Function New-FirstBootProgress, Read-FirstBootProgress, Save-FirstBootProgress, Get-FirstBootStepState,
    Start-FirstBootStep, Complete-FirstBootStep, Test-FirstBootRunsLeft, Get-InterruptedAppResult, Get-InterruptedTaskResult,
    Get-FirstBootLock, Get-AdminOnlyAclArgs
