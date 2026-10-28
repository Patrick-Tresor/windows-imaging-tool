# Tests for the WinPE progress window: the local progress file Deploy-Image.ps1 writes (DeployStatus.psm1), what the
# window shows for each state (DeployProgress.psm1), and on Windows the WinForms window itself, shown off-screen.
# Run: powershell -File tests/DeployProgress.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployStatus.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployProgress.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("progress-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # Local progress file: written without any dashboard share, -LocalOnly never touches the dashboard record.
    $path = Join-Path $work 'DeployProgress.json'
    $hw = [pscustomobject]@{ Maker = 'Dell Inc.'; Model = 'Latitude 7440'; Serial = 'ABC123' }
    Start-LocalProgress -Path $path -Identity $hw
    $r = Read-ProgressFile -Path $path
    Assert-Equal "$($r.state)|$($r.step)|$($r.percent)|$($r.model)" 'Running|Starting|0|Latitude 7440' 'local progress starts Running at 0'
    Assert-Equal (Get-DeployStatusRecord) '' 'no dashboard record without Start-DeployStatus'

    Set-DeployStatus -Step 'Applying the image (40 %)' -Percent 34 -Fields @{ answerFile = 'W11-Office'; image = 'Win11.wim' }
    $r = Read-ProgressFile -Path $path
    Assert-Equal "$($r.step)|$($r.percent)|$($r.answerFile)|$($r.image)" 'Applying the image (40 %)|34|W11-Office|Win11.wim' 'Set-DeployStatus updates the local file'

    $dash = Join-Path $work 'Status'
    $id = Start-DeployStatus -Folder $dash -Identity $hw -LogPath @()
    Set-DeployStatus -LocalOnly -Fields @{ countdown = 7 }
    Assert-Equal (Read-ProgressFile -Path $path).countdown 7 '-LocalOnly updates the local file'
    $saved = Get-Content -Raw (Join-Path $dash "$id.json") | ConvertFrom-Json
    Assert-Equal ($saved.PSObject.Properties['countdown'] -eq $null) $true '-LocalOnly leaves the dashboard record alone'

    Set-DeployStatus -Warning 'No driver pack for Dell Inc. Latitude 7440'
    Set-DeployStatus -State Succeeded
    Assert-Equal (Read-ProgressFile -Path $path).state 'Warning' 'a warning makes the local result Warning too'

    # The window's Change settings button asks the countdown to stop, once.
    Assert-Equal (Receive-ProgressCancel) $false 'no cancel request at first'
    Set-Content -Path (Get-ProgressCancelPath $path) -Value 'change'
    Assert-Equal (Receive-ProgressCancel) $true 'cancel request is seen'
    Assert-Equal (Receive-ProgressCancel) $false 'cancel request is used up'

    # Log tail.
    $log = Join-Path $work 'Deploy.log'
    Set-Content -Path $log -Value ((1..30 | ForEach-Object { "line $_" }) + '')
    $tail = @(Get-LogTail -Path $log -Lines 3)
    Assert-Equal ($tail -join ',') 'line 28,line 29,line 30' 'log tail keeps the last lines'
    Assert-Equal @(Get-LogTail -Path (Join-Path $work 'missing.log')).Count 0 'missing log gives no lines'
    Assert-Equal (Read-ProgressFile -Path (Join-Path $work 'missing.json')) '' 'missing progress file reads as nothing'
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

# Views.
function New-Record([hashtable]$Values) {
    $r = [ordered]@{
        computerName = 'LAB-01'; serial = 'ABC123'; maker = 'Dell Inc.'; model = 'Latitude 7440'; answerFile = 'W11-Office'
        image = 'Win11.wim'; driverPack = 'Dell\Latitude 7440'; state = 'Running'; step = 'Applying the image (50 %)'; percent = 40
        message = ''; countdown = 0; whenDone = ''; started = '2026-10-28T10:00:00Z'; finished = $null; warnings = @()
    }
    foreach ($k in $Values.Keys) { $r[$k] = $Values[$k] }
    [pscustomobject]$r
}
$now = [datetime]'2026-10-28T10:05:30Z'

$v = Get-ProgressView -Record $null
Assert-Equal "$($v.Title)|$($v.Percent)|$($v.Finished)|$($v.ShowPower)" 'Getting ready|0|False|False' 'no record yet: getting ready'

$v = Get-ProgressView -Record (New-Record @{}) -Now $now
Assert-Equal "$($v.Title)|$($v.Detail)|$($v.Percent)|$($v.SidebarStep)|$($v.Busy)" 'Installing Windows|Applying the image (50 %)|40|4|True' 'running deploy shows the step and percent'
Assert-Equal $v.PercentText '40 %    Elapsed 5m 30s' 'running deploy shows elapsed time'
Assert-Equal $v.Hardware 'Dell Inc. Latitude 7440   Serial ABC123' 'hardware line'
Assert-Equal ($v.Facts -join '|') 'Computer name:  LAB-01|Answer file:    W11-Office|Image:          Win11.wim|Drivers:        Dell\Latitude 7440' 'facts list what is deployed'

$v = Get-ProgressView -Record (New-Record @{ countdown = 9; step = 'Counting down'; percent = 5 })
Assert-Equal "$($v.Title)|$($v.ShowChange)|$($v.SidebarStep)|$($v.Busy)" 'Starting in 9 s|True|0|False' 'countdown offers Change settings'

$v = Get-ProgressView -Record (New-Record @{ step = 'Waiting for the operator'; percent = 5 })
Assert-Equal "$($v.Title)|$($v.ShowChange)|$($v.Busy)" 'Waiting for your choices|False|False' 'wizard open: waiting for choices'

$v = Get-ProgressView -Record (New-Record @{ state = 'Succeeded'; percent = 90; whenDone = 'stay'; finished = '2026-10-28T10:20:00Z' })
Assert-Equal "$($v.Title)|$($v.Color)|$($v.Percent)|$($v.ShowPower)|$($v.SidebarStep)" 'Windows is installed|Good|100|True|5' 'success staying in WinPE offers Restart'
Assert-Equal $v.PercentText '100 %    Took 20m 00s' 'finished deploy shows how long it took'

$v = Get-ProgressView -Record (New-Record @{ state = 'Succeeded'; whenDone = 'restart' })
Assert-Equal "$($v.ShowPower)|$($v.Detail)" 'False|Restarting into Windows. Setup and the applications finish there.' 'success restarting on its own hides the buttons'

$v = Get-ProgressView -Record (New-Record @{ state = 'Warning'; whenDone = 'stay'; warnings = @('No driver pack') })
Assert-Equal "$($v.Color)|$($v.Message)" 'Warning|Finished with warnings: No driver pack' 'warnings are listed'

$v = Get-ProgressView -Record (New-Record @{ state = 'Failed'; step = 'Injecting drivers'; message = 'dism.exe exited with code 2' })
Assert-Equal "$($v.Title)|$($v.Detail)|$($v.Message)|$($v.Color)|$($v.ShowPower)" 'Deployment failed|Failed while: Injecting drivers|dism.exe exited with code 2|Bad|True' 'failure names the step and the error'

$v = Get-ProgressView -Record (New-Record @{}) -DeployRunning $false
Assert-Equal "$($v.State)|$($v.Title)|$($v.Finished)" 'Stopped|Deployment stopped|True' 'a deploy script that died is reported'

$v = Get-ProgressView -Record (New-Record @{ state = 'Cancelled' })
Assert-Equal "$($v.Title)|$($v.ShowPower)" 'Deployment cancelled|True' 'cancelled'

# The window itself (WinForms, Windows only), shown off-screen.
if ($env:OS -eq 'Windows_NT') {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $ui = New-DeployProgressForm
    $ui.Form.StartPosition = 'Manual'
    $ui.Form.Location = New-Object Drawing.Point(-3000, -3000)
    $ui.Form.ShowInTaskbar = $false
    $ui.Form.Show()
    try {
        Update-DeployProgressForm -Ui $ui -View (Get-ProgressView -Record (New-Record @{ countdown = 5 })) -LogLines 'a', 'b'
        Assert-Equal "$($ui.Title.Text)|$($ui.Change.Visible)|$($ui.Restart.Visible)|$($ui.Log.Text)" "Starting in 5 s|True|False|a`r`nb" 'window: countdown'
        Update-DeployProgressForm -Ui $ui -View (Get-ProgressView -Record (New-Record @{}))
        Assert-Equal "$($ui.Bar.Value)|$($ui.Change.Visible)|$($ui.Sidebar[4].Font.Bold)|$($ui.Sidebar[0].Font.Bold)" '40|False|True|False' 'window: installing'
        Update-DeployProgressForm -Ui $ui -View (Get-ProgressView -Record (New-Record @{ state = 'Failed'; message = 'boom' }))
        Assert-Equal "$($ui.Title.Text)|$($ui.Message.Text)|$($ui.Restart.Visible)|$($ui.Shutdown.Visible)|$($ui.Sidebar[5].Font.Bold)" 'Deployment failed|boom|True|True|True' 'window: failed'
        # Every control fits inside the window, right of the sidebar.
        foreach ($c in $ui.Form.Controls | Where-Object { $_ -isnot [Windows.Forms.Panel] }) {
            $fits = $c.Left -ge 200 -and $c.Right -le $ui.Form.ClientSize.Width -and $c.Bottom -le $ui.Form.ClientSize.Height
            Assert-Equal $fits $true "window: $($c.GetType().Name) '$($c.Text)' fits"
        }
    }
    finally { $ui.Form.Close(); $ui.Form.Dispose() }
} else { Write-Host 'SKIP WinForms window (not Windows)' }

# The deploy script starts the window with the script that exists, and the media carries it (src\*.ps1).
$deploy = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($deploy -match "Join-Path \`$PSScriptRoot 'DeployProgressWindow.ps1'") $true 'Deploy-Image starts DeployProgressWindow.ps1'
Assert-Equal (Test-Path (Join-Path $repo 'src/DeployProgressWindow.ps1')) $true 'DeployProgressWindow.ps1 exists'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
