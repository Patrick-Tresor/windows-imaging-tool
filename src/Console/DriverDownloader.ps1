# Driver pack download window. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg and imports
# DriverPacks.psm1. The downloads run in their own window through Get-DriverPacks.ps1 so the console stays usable.

# A real .NET type so the check box column binds two-way.
class DriverPackRow {
    [bool]$Selected
    [string]$Model
    [string]$Ids
    [string]$Release
    [string]$Version
    [string]$Released
    [string]$SizeMB
    [string]$Installed
    [object]$Pack
}

function Start-DriverPackDownload {
    # Hands the packs to Get-DriverPacks.ps1 in its own window through a job file. Also used by the Unknown Models window.
    param(
        [Parameter(Mandatory)][object[]]$Packs,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir,
        [switch]$KeepDownload
    )
    $job = Join-Path ([IO.Path]::GetTempPath()) ('driverpacks-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    ConvertTo-Json -InputObject $Packs -Depth 4 | Set-Content -Path $job -Encoding utf8
    $runArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-Arg (Join-Path $SrcDir 'Get-DriverPacks.ps1')),
        '-ContentRoot', (ConvertTo-Arg $ContentRoot), '-JobFile', (ConvertTo-Arg $job))
    if ($KeepDownload) { $runArgs += '-KeepDownload' }
    Start-Process powershell.exe -ArgumentList $runArgs
}

function Show-DriverDownloader {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir
    )

    [xml]$dxaml = Get-Content -Raw (Join-Path $PSScriptRoot 'DriverDownloader.xaml')
    $dlg = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($dxaml))
    $dlg.Owner = $Owner
    $d = @{}
    foreach ($node in $dxaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $d[$name] = $dlg.FindName($name)
    }
    $state = @{ Rows = @(); Started = $false }

    function Show-DownloaderError([string]$Text) {
        [Windows.MessageBox]::Show($dlg, $Text, 'Download Driver Packs', 'OK', 'Warning') | Out-Null
    }

    $updateSelection = {
        $sel = @($state.Rows | Where-Object Selected)
        $mb = ($sel | ForEach-Object { [double]"0$($_.SizeMB)" } | Measure-Object -Sum).Sum
        $d.TxtSelection.Text = '{0} of {1} models selected, {2:N1} GB to download' -f $sel.Count, $state.Rows.Count, ($mb / 1KB)
    }

    $applyFilter = {
        $q = $d.TxtSearch.Text.Trim()
        $d.GridPacks.ItemsSource = @(if ($q) { $state.Rows | Where-Object { $_.Model -like "*$q*" -or $_.Ids -like "*$q*" } } else { $state.Rows })
        & $updateSelection
    }

    $load = {
        param([bool]$Refresh)
        $maker = $d.CmbVendor.SelectedItem.Content
        $os = $d.CmbOs.SelectedItem.Content
        $dlg.Cursor = 'Wait'
        $d.TxtSelection.Text = "Reading the $maker catalog..."
        $dlg.Dispatcher.Invoke([action]{}, 'Background')   # let the text paint before the download blocks
        try {
            $state.Rows = @(Get-VendorDriverPacks -Maker $maker -Os $os -Refresh:$Refresh | Add-DriverPackLibraryStatus -ContentRoot $ContentRoot | ForEach-Object {
                $row = [DriverPackRow]::new()
                $row.Model = $_.Model; $row.Release = $_.Release; $row.Version = $_.Version; $row.Released = $_.Released
                $row.SizeMB = $_.SizeMB; $row.Installed = $_.Installed; $row.Pack = $_
                $row.Ids = (@($_.Skus) + @($_.MachineTypes)) -join ' '
                $row
            })
        } catch {
            $state.Rows = @()
            Show-DownloaderError "Could not read the $maker catalog: $($_.Exception.Message)"
        } finally { $dlg.Cursor = $null }
        & $applyFilter
    }

    $d.CmbVendor.Add_SelectionChanged({ & $load $false })
    $d.CmbOs.Add_SelectionChanged({ & $load $false })
    $d.BtnReload.Add_Click({ & $load $true })
    $d.TxtSearch.Add_TextChanged({ & $applyFilter })
    # Check box clicks change Selected on the row; refresh the count when they do.
    $d.GridPacks.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{ & $updateSelection })

    $d.BtnSelectUpdates.Add_Click({
        foreach ($r in $state.Rows) { if ($r.Installed -like 'Update*') { $r.Selected = $true } }
        $d.GridPacks.Items.Refresh(); & $updateSelection
    })
    $d.BtnClearSelection.Add_Click({
        foreach ($r in $state.Rows) { $r.Selected = $false }
        $d.GridPacks.Items.Refresh(); & $updateSelection
    })

    $d.BtnDownload.Add_Click({
        try {
            $packs = @($state.Rows | Where-Object Selected | ForEach-Object Pack)
            if (-not $packs) { Show-DownloaderError 'Tick at least one model.'; return }
            Start-DriverPackDownload -Packs $packs -ContentRoot $ContentRoot -SrcDir $SrcDir -KeepDownload:$d.ChkKeep.IsChecked
            $state.Started = $true
            $dlg.Close()
        } catch { Show-DownloaderError $_.Exception.Message }
    })
    $d.BtnClose.Add_Click({ $dlg.Close() })

    $dlg.Add_ContentRendered({ & $load $false })
    [void]$dlg.ShowDialog()
    $state.Started
}
