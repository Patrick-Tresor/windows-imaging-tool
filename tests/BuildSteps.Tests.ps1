# Plain-PowerShell tests for the media build's step-by-step progress (src/BuildSteps.psm1), the steps
# New-DeploymentMedia.ps1 reports, and the console's Build progress window (WPF part on Windows only).
# Run: powershell -File tests\BuildSteps.Tests.ps1; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/BuildSteps.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
$epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
function ConvertTo-Ms([DateTime]$Time) { [int64]($Time.ToUniversalTime() - $epoch).TotalMilliseconds }

Assert-Equal (Format-BuildElapsed 0) '00:00' 'elapsed: zero'
Assert-Equal (Format-BuildElapsed 82.7) '01:22' 'elapsed: minutes and seconds, rounded down'
Assert-Equal (Format-BuildElapsed 3725) '1:02:05' 'elapsed: over an hour'

Assert-Equal (Format-TimeLeft -ElapsedSeconds 10 -Percent 50) '' 'time left: nothing in the first 15 seconds'
Assert-Equal (Format-TimeLeft -ElapsedSeconds 60 -Percent 1) '' 'time left: nothing below 2%'
Assert-Equal (Format-TimeLeft -ElapsedSeconds 30 -Percent 60) 'under 1 min left' 'time left: under a minute'
Assert-Equal (Format-TimeLeft -ElapsedSeconds 120 -Percent 25) 'about 6 min left' 'time left: minutes, rounded up'
Assert-Equal (Format-TimeLeft -ElapsedSeconds 1800 -Percent 25) 'about 1 h 30 min left' 'time left: over an hour'
Assert-Equal (Format-TimeLeft -ElapsedSeconds 600 -Percent 100) '' 'time left: nothing at 100%'
Assert-Equal (Format-TimeLeft -ElapsedSeconds 300 -Percent 4 -FromPercent 1) 'about 2 h 40 min left' 'time left: from the first percent, not from 0'
Assert-Equal (Format-TimeLeft -ElapsedSeconds 300 -Percent 3 -FromPercent 2.5) '' 'time left: nothing until it moved 1% since the first percent'

$dir = Join-Path ([IO.Path]::GetTempPath()) ("imaging-steps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    # Without a progress file every call is a no-op (the build run by hand).
    Start-BuildProgress -Path '' -Title 'x' -Steps @(, @('a', 'A'))
    Start-BuildStep 'a'; Set-BuildStepProgress 'a' -Percent 50; Complete-BuildStep 'a'; Stop-BuildProgress
    Assert-Equal (@(Get-ChildItem -LiteralPath $dir).Count) 0 'no progress file without -ProgressFile'

    $file = Join-Path $dir 'build.json'
    Start-BuildProgress -Path $file -Title 'Creating USB stick (disk 2)' -LogPath 'C:\log.txt' -Steps @(
        , @('stick', 'Partitioning the USB stick')
        , @('copy', 'Copying images and content')
        , @('packs', 'Copying WinPE driver packs')
    )
    $data = Read-BuildProgress -Path $file
    Assert-Equal @($data.steps).Count 3 'every step is listed from the start'
    Assert-Equal (@($data.steps | ForEach-Object state) -join ',') 'pending,pending,pending' 'all steps start pending'
    Assert-Equal $data.title 'Creating USB stick (disk 2)' 'title saved'
    Assert-Equal (@(Get-ChildItem -LiteralPath $dir -Filter '*.tmp').Count) 0 'no temporary file left behind'

    Start-BuildStep 'stick' -Detail 'WINPE and DEPLOY'
    Complete-BuildStep 'stick'
    Start-BuildStep 'copy'
    Set-BuildStepProgress 'copy' -Percent 42.9 -Detail '2 GB of 5 GB'
    Start-Sleep -Milliseconds 350   # progress writes are throttled
    Set-BuildStepProgress 'copy' -Percent 43.2 -Detail '2.1 GB of 5 GB'
    Complete-BuildStep 'nope'       # an id the list does not have is ignored
    $data = Read-BuildProgress -Path $file
    Assert-Equal (@($data.steps | ForEach-Object state) -join ',') 'done,running,pending' 'states as the build goes'
    Assert-Equal $data.steps[1].percent 43 'percent rounded down'
    Assert-Equal $data.steps[1].detail '2.1 GB of 5 GB' 'detail saved'
    Assert-Equal $data.steps[1].rateFromPercent 42 'the first percent above 0 is kept for the time left'
    Assert-Equal ([int64]$data.steps[1].rateFrom -gt 0) $true 'and when it was seen'

    $view = Get-BuildStepView -Data $data
    Assert-Equal $view.Rows[0].Status 'Complete' 'a done step says Complete'
    Assert-Equal $view.Rows[0].Percent 100 'a done step has a full bar'
    Assert-Equal $view.Rows[1].Status '43%' 'a running step shows its percent'
    Assert-Equal $view.Rows[1].Indeterminate $false 'a step with a percent has a real bar'
    Assert-Equal $view.Rows[2].Time '' 'a pending step has no time'
    Assert-Equal $view.Summary 'Copying images and content...' 'the summary names the running step'
    Assert-Equal $view.Finished $false 'not finished yet'
    Assert-Equal $view.Log 'C:\log.txt' 'log path for Open log'

    # Fixed times: step and total elapsed.
    $t0 = [DateTime]::new(2026, 11, 10, 20, 0, 0, [DateTimeKind]::Utc)
    $fixed = [pscustomobject]@{
        title = 't'; started = (ConvertTo-Ms $t0); finished = 0; error = ''; log = ''
        steps = @(
            [pscustomobject]@{ id = 'a'; name = 'A'; state = 'done'; percent = 100; detail = ''; started = (ConvertTo-Ms $t0); ended = (ConvertTo-Ms $t0.AddSeconds(22)) }
            [pscustomobject]@{ id = 'b'; name = 'B'; state = 'running'; percent = -1; detail = ''; started = (ConvertTo-Ms $t0.AddSeconds(22)); ended = 0 }
        )
    }
    $view = Get-BuildStepView -Data $fixed -Now $t0.AddSeconds(88)
    Assert-Equal $view.Rows[0].Time '00:22' 'a done step keeps its own time'
    Assert-Equal $view.Rows[1].Time '01:06' 'a running step counts up'
    Assert-Equal $view.Rows[1].Indeterminate $true 'a step without a percent shows a busy bar'
    Assert-Equal $view.Elapsed '01:28' 'total elapsed'
    $fixed.steps[1].percent = 25
    $view = Get-BuildStepView -Data $fixed -Now $t0.AddSeconds(142)
    Assert-Equal $view.Rows[1].Status '25%, about 6 min left' 'a running step with a percent says how long it still needs'
    # DISM sat at 0% for 30 min while it scanned files, then went from 1% to 4% in 3 min: about 1.5 h left, not 13 h.
    $fixed.steps[1] | Add-Member -NotePropertyName rateFrom -NotePropertyValue (ConvertTo-Ms $t0.AddMinutes(30))
    $fixed.steps[1] | Add-Member -NotePropertyName rateFromPercent -NotePropertyValue 1
    $fixed.steps[1].percent = 4
    $view = Get-BuildStepView -Data $fixed -Now $t0.AddMinutes(33)
    Assert-Equal $view.Rows[1].Status '4%, about 1 h 36 min left' 'time left ignores the wait before the first percent'

    # An error: the running step fails, with only the first line of the message.
    Stop-BuildProgress -Message "Copying Images\W11.wim to the USB stick failed: device not ready.`nAt line 12 char 3"
    $view = Get-BuildStepView -Data (Read-BuildProgress -Path $file)
    Assert-Equal (@($view.Rows | ForEach-Object State) -join ',') 'done,failed,pending' 'the running step is marked failed'
    Assert-Equal $view.Rows[1].Status 'Failed' 'failed step says Failed'
    Assert-Equal $view.Summary 'Failed: Copying Images\W11.wim to the USB stick failed: device not ready.' 'one line error'
    Assert-Equal $view.Failed $true 'failed'
    Assert-Equal $view.Finished $true 'a failed build is finished'

    # Success: steps the build never reached are shown as not needed.
    Start-BuildProgress -Path $file -Title 'ISO' -Steps @(@('a', 'A'), @('b', 'B'), @('c', 'C'))
    Complete-BuildStep 'a' -State reused -Detail 'From the build of 2026-11-09'
    Start-BuildStep 'b'
    Complete-BuildStep 'b'
    Stop-BuildProgress
    $view = Get-BuildStepView -Data (Read-BuildProgress -Path $file)
    Assert-Equal (@($view.Rows | ForEach-Object Status) -join ',') 'Reused,Complete,Not needed' 'reused, done and not needed'
    Assert-Equal $view.Rows[2].Time '' 'a step not needed has no time'
    Assert-Equal ($view.Summary -like 'Done in *') $true 'summary says done'

    Assert-Equal (Read-BuildProgress -Path (Join-Path $dir 'missing.json')) $null 'missing file reads as nothing'
    Set-Content -LiteralPath (Join-Path $dir 'half.json') -Value '{"title": "x", "ste'
    Assert-Equal (Read-BuildProgress -Path (Join-Path $dir 'half.json')) $null 'half a file reads as nothing'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# New-DeploymentMedia.ps1: every step it starts or completes is in its step list, and every listed step is reported.
$buildText = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/New-DeploymentMedia.ps1')
$stepBlock = $buildText.Substring($buildText.IndexOf('$steps = @('), $buildText.IndexOf('Start-BuildProgress -Path') - $buildText.IndexOf('$steps = @('))
$listed = @([regex]::Matches($stepBlock, "@\('(\w+)',\s*[\$']") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$used = @([regex]::Matches($buildText, "(?:Start-BuildStep|Set-BuildStepProgress|Complete-BuildStep)\s+'(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Assert-Equal ($listed.Count -ge 12) $true "the build lists its steps ($($listed -join ', '))"
Assert-Equal (@($used | Where-Object { $_ -notin $listed }) -join ',') '' 'every reported step is in the list'
Assert-Equal (@($listed | Where-Object { $_ -notin $used }) -join ',') '' 'every listed step is reported'
Assert-Equal ($buildText -match 'trap \{\s*Stop-BuildProgress -Message') $true 'an error marks the build failed'
Assert-Equal ($buildText -match '(?m)^Stop-BuildProgress\s*$') $true 'the end marks the build done'

# The console: the build gets a progress file and a log, and the window is loaded the console's way.
$consoleText = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Console/ImagingConsole.ps1')
Assert-Equal ($consoleText -match "'-ProgressFile'") $true 'the console passes -ProgressFile'
Assert-Equal ($consoleText -match 'Show-BuildProgress ') $true 'the console opens the Build progress window'

$sta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'SKIP Build progress window: WPF needs Windows' -ForegroundColor Yellow
} elseif (-not $sta) {
    Write-Host 'SKIP Build progress window: WPF needs an STA thread' -ForegroundColor Yellow
} else {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $repo 'src/Console/WheelScroll.psm1') -Force
    . (Join-Path $repo 'src/Console/BuildProgress.ps1')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("imaging-steps-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir | Out-Null
    $owner = New-Object Windows.Window -Property @{ Left = -10000; Top = -10000; Width = 100; Height = 100; ShowInTaskbar = $false }
    try {
        $file = Join-Path $dir 'build.json'
        Start-BuildProgress -Path $file -Title 'Creating USB stick' -Steps @(@('a', 'Mounting boot.wim'), @('b', 'Copying images and content'))
        Complete-BuildStep 'a'
        Start-BuildStep 'b'
        Set-BuildStepProgress 'b' -Percent 30 -Detail '1 GB of 3 GB'
        Start-Sleep -Milliseconds 350
        Set-BuildStepProgress 'b' -Percent 30 -Detail '1 GB of 3 GB'
        $owner.Show()
        Show-BuildProgress -Owner $owner -ProgressFile $file -Title 'Building USB stick'
        $dlg = @($owner.OwnedWindows)[0]
        $dlg.Left = -10000; $dlg.Top = -10000
        $dlg.Dispatcher.Invoke([action]{}, 'Background')
        $find = { param($n) $dlg.FindName($n) }
        $rows = @((& $find 'LstSteps').ItemsSource)
        Assert-Equal $rows.Count 2 'window: a row per step'
        Assert-Equal $rows[0].Status "$([char]0x2713) Complete" 'window: done step has a tick and Complete'
        Assert-Equal $rows[1].Percent 30 'window: running step bar at its percent'
        Assert-Equal (& $find 'TxtTitle').Text 'Building USB stick' 'window: title'
        Assert-Equal (& $find 'TxtSummary').Text 'Copying images and content...' 'window: summary'

        Complete-BuildStep 'b'
        Stop-BuildProgress
        Update-BuildProgressWindow $dlg.Tag
        Assert-Equal ((& $find 'TxtSummary').Text -like 'Done in *') $true 'window: done'
        Assert-Equal (& $find 'BtnClose').Content 'Done' 'window: Close becomes Done'
        Assert-Equal $dlg.Tag.Timer.IsEnabled $false 'window: stops reading when the build is done'
        $dlg.Close()
    } finally {
        $owner.Close()
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All build step checks passed.' -ForegroundColor Green
