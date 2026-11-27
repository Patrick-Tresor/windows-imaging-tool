# Plain-PowerShell tests for work shown in its page's rows instead of the Progress window (src/Console/RowProgress.ps1):
# captures, image updates and rollbacks on the Images tab, Install agent and Reimage on the Computers tab.
# Run: pwsh -File tests/RowProgress.Tests.ps1. No WPF: the grids are stand-ins.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $repo 'src/Console/RowProgress.ps1')
function Remove-ProgressJob { param($Ctx) $script:removedJob = $Ctx }

$step = { param($name, $state, $pct, $status, $detail, [bool]$busy) [pscustomobject]@{ Name = $name; State = $state; Percent = $pct; Status = $status; Detail = $detail; Indeterminate = $busy } }
$running = [pscustomobject]@{ SummaryState = 'muted'; Finished = $false; Summary = '' }
$failedJob = [pscustomobject]@{ SummaryState = 'error'; Finished = $true; Summary = 'The capture stopped before the end. Click Open log to see why.' }

# The text a row shows.
$st = Get-JobRowStatus -Steps @((& $step 'Copying the VM''s disk' 'done' 100 'Complete' '' $false), (& $step 'Capturing the image' 'running' 35 '35%, about 20 min left' '' $false)) -Job $running -FailedWord 'Capture failed'
Assert-Equal "$($st.Text)|$($st.Percent)|$($st.Busy)|$($st.Indeterminate)" 'Capturing the image 35%, about 20 min left|35|True|False' 'status: the running step with percent and time left'
$st = Get-JobRowStatus -Steps @((& $step 'Adding the updates' 'running' -1 '' 'KB5043080' $true)) -Job $running
Assert-Equal "$($st.Text)|$($st.Indeterminate)" 'Adding the updates|True' 'status: a step without percent, busy bar'
$st = Get-JobRowStatus -Steps @() -Job $running
Assert-Equal "$($st.Text)|$($st.Busy)" 'Starting|True' 'status: before the first read'
Assert-Equal (Get-JobRowStatus -Steps @((& $step 'a' 'done' 100 'Complete' '' $false), (& $step 'b' 'skipped' 100 'Not needed' '' $false)) -Job $running) $null 'status: every step done, the row shows itself again'
$st = Get-JobRowStatus -Steps @((& $step 'Capturing the image' 'failed' 0 'Failed' 'DISM error 112: not enough space' $false)) -Job $failedJob -FailedWord 'Capture failed'
Assert-Equal "$($st.Text)|$($st.Failed)|$($st.Busy)" 'Capture failed: DISM error 112: not enough space|True|False' 'status: a failed step with its one-line reason'
$st = Get-JobRowStatus -Steps @((& $step 'Capturing the image' 'running' 35 '35%' '' $false)) -Job $failedJob -FailedWord 'Capture failed'
Assert-Equal $st.Text 'Capture failed: it stopped before the end' 'status: the worker died, no "Open log" button wording'
$st = Get-JobRowStatus -Steps @((& $step 'PC-01' 'running' -1 '' 'Copying WinPE to the PC' $true)) -Job $running -FailedWord '' -UseDetail
Assert-Equal $st.Text 'Copying WinPE to the PC' 'status: a PC row says what is done to it'
$st = Get-JobRowStatus -Steps @((& $step 'PC-01' 'failed' 0 'Failed' 'Not reached: no answer to ping' $false)) -Job $running -FailedWord '' -UseDetail
Assert-Equal "$($st.Text)|$($st.Failed)" 'Not reached: no answer to ping|True' 'status: a PC failure is its own message'

Assert-Equal (Get-RowJobKeyMatch -Key 'Win11.24H2.wim' -Keys @('Win11.24H2.esd') -Grid 'images') $true 'key: images match without the extension'
Assert-Equal (Get-RowJobKeyMatch -Key 'Win11.wim' -Keys @('Win10.wim') -Grid 'images') $false 'key: another image'

# Images tab: a capture shows on top at once, an update on its image's row; done, they let go.
$script:WindowlessJobs = New-Object Collections.ArrayList
$img = [pscustomobject]@{ Name = 'Win11.wim'; SizeGB = 5 }
$script:ui = @{ GridImages = [pscustomobject]@{ ItemsSource = @($img); Items = $null }; GridAd = [pscustomobject]@{ ItemsSource = @(); Items = $null } }
$capRows = New-Object Collections.ArrayList
$cap = @{ RowTarget = @{ Grid = 'images'; Keys = @('Lab.wim'); FailedWord = 'Capture failed' }; Rows = $capRows; View = $running; Dismissed = @{} }
[void]$script:WindowlessJobs.Add($cap)
Update-RowJobs -Grid 'images'
$list = @($script:ui.GridImages.ItemsSource)
Assert-Equal "$($list.Count)|$($list[0].Name)|$($list[0].Status)|$($list[0].IsJobEntry)" '2|Lab.wim|Starting|True' 'images: a capture shows on top at once'
[void]$capRows.Add((& $step 'Capturing the image' 'running' 35 '35%, about 20 min left' '' $false))
Update-RowJobs -Grid 'images'
$list = @($script:ui.GridImages.ItemsSource)
Assert-Equal "$($list.Count)|$($list[0].Status)|$($list[0].Percent)" '2|Capturing the image 35%, about 20 min left|35' 'images: the capture row moves on, no second row'
$capRows[0] = (& $step 'Capturing the image' 'done' 100 'Complete' '' $false)
$cap.View = [pscustomobject]@{ SummaryState = 'success'; Finished = $true; Summary = 'Done' }
Update-RowJobs -Grid 'images'
Assert-Equal "$(@($script:ui.GridImages.ItemsSource).Count)|$(@($script:ui.GridImages.ItemsSource)[0].Name)" '1|Win11.wim' 'images: the capture row goes when it worked (the reload shows the image)'

$updRows = New-Object Collections.ArrayList
[void]$updRows.Add((& $step 'Adding the updates' 'failed' 0 'Failed' 'DISM error 0x800f081f' $false))
$upd = @{ RowTarget = @{ Grid = 'images'; Keys = @('Win11.wim'); FailedWord = 'Update failed' }; Rows = $updRows; View = $failedJob; Dismissed = @{} }
[void]$script:WindowlessJobs.Add($upd)
Update-RowJobs -Grid 'images'
Assert-Equal "$($img.Status)|$($img.Failed)" 'Update failed: DISM error 0x800f081f|True' 'images: a failed update stays on the image'
Assert-Equal (Clear-RowJobMessage -Grid 'images' -Row $img) 1 'images: Clear the message'
Assert-Equal "$($img.Status)|$($img.Failed)|$($script:removedJob -eq $upd)" '|False|True' 'images: the image shows itself again, the job is let go'

# Computers tab: Install agent in the Agent column, then its old text back; a PC that failed keeps the reason.
$pc1 = [pscustomobject]@{ Name = 'PC-01'; Agent = 'No agent'; Reimage = '' }
$pc2 = [pscustomobject]@{ Name = 'PC-02'; Agent = 'No agent'; Reimage = '' }
$script:ui.GridAd.ItemsSource = @($pc1, $pc2)
$agRows = New-Object Collections.ArrayList
[void]$agRows.Add((& $step 'PC-01' 'running' -1 '' 'Waiting for its first check-in' $true))
[void]$agRows.Add((& $step 'PC-02' 'failed' 0 'Failed' 'Not reached: no answer to ping' $false))
$ag = @{ RowTarget = @{ Grid = 'ad'; Keys = @('PC-01', 'PC-02'); Column = 'Agent' }; Rows = $agRows; View = $running; Dismissed = @{} }
[void]$script:WindowlessJobs.Add($ag)
Update-RowJobs -Grid 'ad'
Assert-Equal "$($pc1.Agent)|$($pc2.Agent)|$($pc1.Reimage)" 'Waiting for its first check-in|Not reached: no answer to ping|' 'computers: each PC''s Agent column shows its part'
$pc1.Agent = 'No agent'   # the tab refreshed the column meanwhile (every 30 s)
Update-RowJobs -Grid 'ad'
Assert-Equal $pc1.Agent 'Waiting for its first check-in' 'computers: a refresh does not hide the install'
$agRows[0] = (& $step 'PC-01' 'done' 100 'Complete' 'Checked in' $false)
$pc1.Agent = 'Agent 1.4 (just now)'   # the refresh after it checked in
Update-RowJobs -Grid 'ad'
Assert-Equal $pc1.Agent 'Agent 1.4 (just now)' 'computers: done, the fresh Agent value stays'
$pc3 = [pscustomobject]@{ Name = 'PC-03'; Agent = 'Agent 1.4'; Reimage = 'Done 2026-11-20' }
$script:ui.GridAd.ItemsSource = @($pc1, $pc2, $pc3)
$reRows = New-Object Collections.ArrayList
[void]$reRows.Add((& $step 'Getting the Office files ready' 'running' 40 '40%' '' $false))
[void]$reRows.Add((& $step 'PC-03' 'pending' 0 '' '' $false))
$re = @{ RowTarget = @{ Grid = 'ad'; Keys = @('PC-03'); Column = 'Reimage' }; Rows = $reRows; View = $running; Dismissed = @{} }
[void]$script:WindowlessJobs.Add($re)
Update-RowJobs -Grid 'ad'
Assert-Equal "$($pc3.Reimage)|$($pc3.Agent)" 'Getting the Office files ready 40%|Agent 1.4' 'computers: Reimage column, the shared Office step while the PC waits'
$reRows[0] = (& $step 'Getting the Office files ready' 'done' 100 'Complete' '' $false)
$reRows[1] = (& $step 'PC-03' 'done' 100 'Complete' 'Job given to its agent' $false)
Update-RowJobs -Grid 'ad'
Assert-Equal $pc3.Reimage 'Done 2026-11-20' 'computers: done, the column has its own text back'
Assert-Equal (Clear-RowJobMessage -Grid 'ad' -Row $pc2) 1 'computers: Clear the message on the failed PC'
Assert-Equal $pc2.Agent 'No agent' 'computers: its Agent column is back'

# The pages use it, and only the two builds still open the Progress window (Patrick, 2026-11-27).
$console = Get-Content -Raw (Join-Path $repo 'src/Console/ImagingConsole.ps1')
Assert-Equal ($console -match "Start-RowJob -Job \`$job [^\n]*-Grid 'ad' -Column 'Reimage'") $true 'reimage: in the Reimage column'
Assert-Equal ($console -match "Start-RowJob -Job \`$job [^\n]*-Grid 'ad' -Column 'Agent'") $true 'install agent: in the Agent column'
Assert-Equal (@([regex]::Matches($console, 'Show-BuildProgress ')).Count) 2 'console: only the USB stick and network boot builds use the Progress window'
foreach ($f in 'CaptureWizard.ps1', 'UpdateImage.ps1', 'ImageVersions.ps1') {
    $text = Get-Content -Raw (Join-Path $repo "src/Console/$f")
    Assert-Equal ($text -match "Start-RowJob [^\n]*-Grid 'images'" -and $text -notmatch 'Show-BuildProgress ') $true "${f}: in the image's row on the Images tab"
}
Assert-Equal ($console -match "Add-RowJobMenu -DataGrid \`$ui\.GridImages" -and $console -match "Add-RowJobMenu -DataGrid \`$ui\.GridAd") $true 'right-click menus on both grids'

Complete-Tests 'All row progress tests passed'
