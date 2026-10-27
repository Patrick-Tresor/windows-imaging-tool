# Unknown models window. Dot-sourced by ImagingConsole.ps1 after DriverDownloader.ps1, which provides
# Start-DriverPackDownload; the report itself comes from DriverReport.psm1.

# A real .NET type so the check box column binds two-way.
class UnknownModelRow {
    [bool]$Selected
    [bool]$HasPack
    [string]$Maker
    [string]$Model
    [string]$Ids
    [int]$PCs
    [string]$Computers
    [string]$LastSeen
    [string]$Drivers
    [string]$PackText
    [object]$Source
}

function Show-UnknownModels {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir
    )

    [xml]$uxaml = Get-Content -Raw (Join-Path $PSScriptRoot 'UnknownModels.xaml')
    $dlg = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($uxaml))
    $dlg.Owner = $Owner
    $u = @{}
    foreach ($node in $uxaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $u[$name] = $dlg.FindName($name)
    }
    $state = @{ Rows = @(); Changed = $false }

    function Show-ReportError([string]$Text) {
        [Windows.MessageBox]::Show($dlg, $Text, 'Unknown Models', 'OK', 'Warning') | Out-Null
    }

    $updateSelection = {
        $sel = @($state.Rows | Where-Object Selected)
        $mb = ($sel | ForEach-Object { [double]"0$($_.Source.Pack.SizeMB)" } | Measure-Object -Sum).Sum
        $pcs = ($state.Rows | Measure-Object PCs -Sum).Sum
        $u.TxtSelection.Text = if (-not $state.Rows) { 'Every deployed PC got its driver pack.' }
            else { '{0} models on {1} PCs. {2} packs ticked, {3:N1} GB to download' -f $state.Rows.Count, $pcs, $sel.Count, ($mb / 1KB) }
    }

    $load = {
        param([bool]$Refresh)
        $os = $u.CmbOs.SelectedItem.Content
        $dlg.Cursor = 'Wait'
        $u.TxtSelection.Text = 'Reading the deployment reports and vendor catalogs...'
        $dlg.Dispatcher.Invoke([action]{}, 'Background')   # let the text paint before the catalog downloads block
        try {
            $models = @(Get-UnknownModels -ContentRoot $ContentRoot)
            $state.Rows = @(Add-UnknownModelPacks -Models $models -Os $os -Refresh:$Refresh | ForEach-Object {
                $row = [UnknownModelRow]::new()
                foreach ($p in 'Maker', 'Model', 'Ids', 'PCs', 'Computers', 'LastSeen', 'Drivers', 'PackText') { $row.$p = $_.$p }
                $row.HasPack = [bool]$_.Pack
                $row.Selected = $row.HasPack   # one click: every model with a pack is ticked
                $row.Source = $_
                $row
            })
        } catch {
            $state.Rows = @()
            Show-ReportError "Could not build the report: $($_.Exception.Message)"
        } finally { $dlg.Cursor = $null }
        $u.GridModels.ItemsSource = $state.Rows
        & $updateSelection
    }

    $u.CmbOs.Add_SelectionChanged({ & $load $false })
    $u.BtnRefresh.Add_Click({ & $load $true })
    $u.GridModels.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{ & $updateSelection })

    $u.BtnOpenReports.Add_Click({
        $dir = Get-DriverReportDir $ContentRoot
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Invoke-Item $dir
    })

    $u.BtnInbox.Add_Click({
        try {
            $rows = @($u.GridModels.SelectedItems)
            if (-not $rows) { Show-ReportError 'Highlight the rows (click, Ctrl+click) that need no driver pack.'; return }
            $names = ($rows | ForEach-Object { "$($_.Maker) $($_.Model)" }) -join "`n"
            $ok = [Windows.MessageBox]::Show($dlg, "Deploy these with Windows inbox drivers only, without a warning?`n`n$names", 'Unknown Models', 'YesNo', 'Question')
            if ($ok -ne 'Yes') { return }
            foreach ($r in $rows) { Set-UnknownModelInbox -ContentRoot $ContentRoot -Model $r.Source }
            $state.Changed = $true
            & $load $false
        } catch { Show-ReportError $_.Exception.Message }
    })

    $u.BtnDownload.Add_Click({
        try {
            $packs = @($state.Rows | Where-Object Selected | ForEach-Object { $_.Source.Pack } | Sort-Object Maker, Model -Unique)   # two SKUs of one model share a pack
            if (-not $packs) { Show-ReportError 'No model with a vendor pack is ticked.'; return }
            Start-DriverPackDownload -Packs $packs -ContentRoot $ContentRoot -SrcDir $SrcDir -KeepDownload:$u.ChkKeep.IsChecked
            $state.Changed = $true
            $dlg.Close()
        } catch { Show-ReportError $_.Exception.Message }
    })
    $u.BtnClose.Add_Click({ $dlg.Close() })

    $dlg.Add_ContentRendered({ & $load $false })
    [void]$dlg.ShowDialog()
    $state.Changed
}
