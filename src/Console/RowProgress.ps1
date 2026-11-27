# Work shown in the row it is about instead of the Progress window (Patrick, 2026-11-27: show the entry, and in front
# of it that it is downloading; then the same on every page that opened the Progress window, except the USB stick
# and network boot builds, which keep their step list there). Dot-sourced by ImagingConsole.ps1 after
# BuildProgress.ps1.
#   Images tab: a capture (a new row on top until the image is there), an update, a rollback: the image's Status.
#   Computers tab: Install agent in each PC's Agent column, Reimage in its Reimage column.
#   Driver library: driver pack downloads (DriverDownloader.ps1, its own rows and wording).
# The job runs and is read as before (Start-ConsoleJob, Show-BuildProgress -NoWindow); a job that worked lets go
# 5 s after it ends and the page reloads; a failed one keeps its message on the row until Clear the message (right-
# click), and Open the log (right-click) has the details.

function Start-RowJob {
    # Follows a Start-ConsoleJob job in rows of -Grid ('images' or 'ad'). -Keys: the image name (file name or base
    # name) or the PC names. -Column: the Computers column to write in ('Agent' or 'Reimage'). -FailedWord starts an
    # image's failure message ('Capture failed'). Returns the job.
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('images', 'ad')][string]$Grid,
        [Parameter(Mandatory)][string[]]$Keys,
        [string]$Column,
        [string]$FailedWord = 'Failed',
        [string]$Noun = 'job',
        [scriptblock]$OnFinished,
        $Owner = $script:window
    )
    $ctx = Show-BuildProgress -Owner $Owner -ProgressFile $Job.ProgressFile -LogPath $Job.LogPath -Process $Job.Process -Title $Title `
        -Noun $Noun -Hidden -RemoveWhenDoneSeconds 5 -NoWindow -OnFinished $OnFinished -OnUpdate { param($j) Update-RowJobs -Grid $j.RowTarget.Grid }
    $ctx.RowTarget = @{ Grid = $Grid; Keys = @($Keys); Column = $Column; FailedWord = $FailedWord }
    $ctx.Dismissed = @{}
    Update-RowJobs -Grid $Grid
    $ctx
}

function Get-JobRowStatus {
    # What one row says, from its steps (Get-BuildStepView rows: Name, State, Percent, Status, Detail, Indeterminate)
    # and the job's view (SummaryState, Summary, Finished). $null once its work is done: the row shows itself again.
    # -UseDetail: the text is the step's detail (PC rows, whose step is named after the PC).
    param([object[]]$Steps, $Job, [string]$FailedWord = 'Failed', [switch]$UseDetail)
    $steps = @($Steps | Where-Object { $_ })
    $failedText = { param($why) $why = "$why".Trim(); if (-not $FailedWord) { $why } elseif ($why) { "${FailedWord}: $why" } else { $FailedWord } }
    $bad = @($steps | Where-Object { "$($_.State)" -eq 'failed' })[0]
    if ($bad) {
        return [pscustomobject]@{ Text = (& $failedText $(if ($bad.Detail) { $bad.Detail } else { $bad.Name })); Percent = 0; Busy = $false; Indeterminate = $false; Failed = $true }
    }
    $jobFailed = $Job -and "$($Job.SummaryState)" -eq 'error'
    $open = @($steps | Where-Object { "$($_.State)" -in 'running', 'pending' })
    if ($jobFailed -and ($open -or -not $steps)) {
        $why = "$($Job.Summary)" -replace '^Failed:\s*', ''
        if ($why -match 'Open log' -or -not $why) { $why = 'it stopped before the end' }
        return [pscustomobject]@{ Text = (& $failedText $why); Percent = 0; Busy = $false; Indeterminate = $false; Failed = $true }
    }
    if ($steps -and -not $open) { return $null }
    if ($Job -and $Job.Finished) { return $null }
    $run = @($steps | Where-Object { "$($_.State)" -eq 'running' })[0]
    if ($run) {
        $label = if ($UseDetail) { $(if ("$($run.Detail)") { "$($run.Detail)" } else { 'Working' }) } else { "$($run.Name)" }
        if ("$($run.Status)" -and -not $run.Indeterminate) {
            return [pscustomobject]@{ Text = "$label $($run.Status)"; Percent = [double]$run.Percent; Busy = $true; Indeterminate = $false; Failed = $false }
        }
        return [pscustomobject]@{ Text = $label; Percent = 0; Busy = $true; Indeterminate = $true; Failed = $false }
    }
    [pscustomobject]@{ Text = $(if ($steps) { 'Waiting' } else { 'Starting' }); Percent = 0; Busy = $true; Indeterminate = $true; Failed = $false }
}

function Get-RowJobKeyMatch {
    # True when a row key is one of the job's keys: images by name without the extension (a capture knows only
    # the name), PCs by name.
    param([string]$Key, [string[]]$Keys, [string]$Grid)
    if ($Grid -eq 'images') { $Key = [IO.Path]::GetFileNameWithoutExtension($Key); $Keys = @($Keys | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) }
    [bool](@($Keys | Where-Object { $_ -eq $Key }).Count)
}

function Get-RowJobState {
    # The latest job of -Grid on the row -Key (optionally only those writing -Column) and its status, or $null.
    param([string]$Grid, [string]$Key, [string]$Column)
    $jobs = @($script:WindowlessJobs | Where-Object { $_.RowTarget -and $_.RowTarget.Grid -eq $Grid -and (-not $Column -or $_.RowTarget.Column -eq $Column) })
    [array]::Reverse($jobs)
    foreach ($job in $jobs) {
        $t = $job.RowTarget
        $k = @($t.Keys | Where-Object { Get-RowJobKeyMatch -Key $Key -Keys @($_) -Grid $Grid })[0]
        if (-not $k -or $job.Dismissed.ContainsKey($k)) { continue }
        if ($Grid -eq 'ad') {
            # The PC's own step; while it waits, a shared step before it (Getting the Office files ready).
            $own = @($job.Rows | Where-Object { $_.Name -eq $k })
            $shared = @($job.Rows | Where-Object { $_.Name -notin $t.Keys -and $_.State -eq 'running' })
            $st = if ($own -and $own[0].State -eq 'pending' -and $shared) { Get-JobRowStatus -Steps $shared -Job $job.View -FailedWord '' }
                  else { Get-JobRowStatus -Steps $own -Job $job.View -FailedWord '' -UseDetail }
        } else {
            $st = Get-JobRowStatus -Steps @($job.Rows) -Job $job.View -FailedWord $t.FailedWord
        }
        if ($st) { return [pscustomobject]@{ Job = $job; Key = $k; Status = $st } }
    }
    $null
}

function Update-RowJobs {
    # Writes the jobs onto the rows of -Grid; redraws only when something changed.
    param([Parameter(Mandatory)][string]$Grid)
    if (-not $script:ui) { return }
    if ($Grid -eq 'images') { Update-ImageRowJobs } else { Update-AdRowJobs }
}

function Set-RowStatusValues {
    # The Status, bar and tip of a row (a PSObject); $true when anything changed.
    param([Parameter(Mandatory)]$Row, $State)
    $st = if ($State) { $State.Status } else { $null }
    $values = [ordered]@{
        Status = $(if ($st) { $st.Text } else { '' }); Percent = $(if ($st) { $st.Percent } else { 0 })
        Busy = $(if ($st) { $st.Busy } else { $false }); Indeterminate = $(if ($st) { $st.Indeterminate } else { $false })
        Failed = $(if ($st) { $st.Failed } else { $false })
        StatusTip = $(if ($st -and $st.Failed) { "$($st.Text)`nRight-click the row: Open the log, Clear the message." } elseif ($st) { $st.Text } else { $null })
    }
    $changed = $false
    foreach ($k in $values.Keys) {
        $p = $Row.PSObject.Properties[$k]
        if (-not $p) { $Row | Add-Member -NotePropertyName $k -NotePropertyValue $values[$k]; $changed = $true }
        elseif ("$($p.Value)" -ne "$($values[$k])") { $p.Value = $values[$k]; $changed = $true }
    }
    $changed
}

function Update-ImageRowJobs {
    # Images tab: each image's Status; a capture's image not in the list yet gets a row on top until it is there.
    $g = $script:ui.GridImages
    $rows = @($g.ItemsSource | Where-Object { $_ })
    $changed = $false
    # Captures (and anything else) whose image has no row yet.
    $extra = @()
    foreach ($job in @($script:WindowlessJobs | Where-Object { $_.RowTarget -and $_.RowTarget.Grid -eq 'images' })) {
        foreach ($k in @($job.RowTarget.Keys)) {
            if (@($rows | Where-Object { Get-RowJobKeyMatch -Key $_.Name -Keys @($k) -Grid 'images' }).Count) { continue }
            if (Get-RowJobState -Grid 'images' -Key $k) { $extra += [pscustomobject]@{ Name = $k; IsJobEntry = $true } }
        }
    }
    $keep = @($rows | Where-Object { -not ($_.PSObject.Properties['IsJobEntry'] -and $_.IsJobEntry) -or (Get-RowJobState -Grid 'images' -Key $_.Name) })
    if ($extra -or $keep.Count -ne $rows.Count) { $rows = @($extra) + @($keep); $g.ItemsSource = $rows; $changed = $true }
    foreach ($r in $rows) { if (Set-RowStatusValues -Row $r -State (Get-RowJobState -Grid 'images' -Key $r.Name)) { $changed = $true } }
    if ($changed) { try { $g.Items.Refresh() } catch { } }
}

function Update-AdRowJobs {
    # Computers tab: Install agent in the Agent column, Reimage in the Reimage column. What the column said before
    # (<Column>Base) comes back when the job lets go, unless the tab refreshed the column meanwhile
    # (<Column>Shown is what was written, so a refreshed value is seen as the new base).
    $g = $script:ui.GridAd
    $changed = $false
    foreach ($r in @($g.ItemsSource | Where-Object { $_ })) {
        foreach ($col in 'Agent', 'Reimage') {
            $base = $r.PSObject.Properties["${col}Base"]
            $shown = $r.PSObject.Properties["${col}Shown"]
            $state = Get-RowJobState -Grid 'ad' -Key "$($r.Name)" -Column $col
            if ($state) {
                $text = $state.Status.Text
                if (-not $shown -or "$($r.$col)" -ne "$($shown.Value)") {
                    $r | Add-Member -NotePropertyName "${col}Base" -NotePropertyValue $r.$col -Force
                }
                $r | Add-Member -NotePropertyName "${col}Shown" -NotePropertyValue $text -Force
                if ("$($r.$col)" -ne $text) { $r | Add-Member -NotePropertyName $col -NotePropertyValue $text -Force; $changed = $true }
            } elseif ($shown) {
                if ("$($r.$col)" -eq "$($shown.Value)") { $r | Add-Member -NotePropertyName $col -NotePropertyValue $(if ($base) { $base.Value } else { '' }) -Force; $changed = $true }
                $r.PSObject.Properties.Remove("${col}Shown")
                if ($base) { $r.PSObject.Properties.Remove("${col}Base") }
            }
        }
    }
    if ($changed) { try { $g.Items.Refresh() } catch { } }
}

function Get-RowJobsOn {
    # The jobs shown on a row (for its right-click menu).
    param([string]$Grid, $Row)
    if (-not $Row) { return @() }
    @(foreach ($col in $(if ($Grid -eq 'ad') { 'Agent', 'Reimage' } else { '' })) { Get-RowJobState -Grid $Grid -Key "$($Row.Name)" -Column $col }) | Where-Object { $_ }
}

function Clear-RowJobMessage {
    # Clear the message: the row's failed jobs let go of it (a running one stays). Returns how many were cleared.
    param([string]$Grid, $Row)
    $n = 0
    foreach ($s in @(Get-RowJobsOn -Grid $Grid -Row $Row)) {
        if ($s.Status.Busy) { continue }
        $s.Job.Dismissed[$s.Key] = $true
        $n++
        if ($s.Job.Dismissed.Count -ge @($s.Job.RowTarget.Keys).Count) { Remove-ProgressJob -Ctx $s.Job }
    }
    Update-RowJobs -Grid $Grid
    $n
}

function Add-RowJobMenu {
    # Right-click on a row of -Grid: Open the log, Clear the message, for the jobs shown on it.
    param([Parameter(Mandatory)]$DataGrid, [Parameter(Mandatory)][string]$Grid)
    $menu = New-Object Windows.Controls.ContextMenu
    $log = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Open the log' }
    $clear = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Clear the message' }
    [void]$menu.Items.Add($log); [void]$menu.Items.Add($clear)
    $menu.Tag = @{ DataGrid = $DataGrid; Grid = $Grid }
    $log.Tag = $menu.Tag; $clear.Tag = $menu.Tag
    $menu.Add_Opened({
        param($sender)
        $t = $sender.Tag
        $on = @(Get-RowJobsOn -Grid $t.Grid -Row $t.DataGrid.SelectedItem)
        $sender.Items[0].IsEnabled = [bool]$on
        $sender.Items[1].IsEnabled = [bool](@($on | Where-Object { -not $_.Status.Busy }).Count)
    })
    $log.Add_Click({ param($sender) Invoke-Safely {
        $t = $sender.Tag
        foreach ($s in @(Get-RowJobsOn -Grid $t.Grid -Row $t.DataGrid.SelectedItem)) { Invoke-ProgressJobButton -Ctx $s.Job -Action 'log' }
    } })
    $clear.Add_Click({ param($sender) Invoke-Safely { $t = $sender.Tag; [void](Clear-RowJobMessage -Grid $t.Grid -Row $t.DataGrid.SelectedItem) } })
    # Right-click selects the row under the mouse first, so the menu is about that row.
    $DataGrid.Add_PreviewMouseRightButtonDown({
        param($sender, $e)
        try {
            $dep = $e.OriginalSource
            while ($dep -and -not ($dep -is [Windows.Controls.DataGridRow])) {
                $dep = if ($dep -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($dep) } else { $dep.Parent }
            }
            if ($dep -and -not $sender.SelectedItems.Contains($dep.Item)) { $sender.SelectedItem = $dep.Item }
        } catch { }
    })
    $DataGrid.ContextMenu = $menu
}
