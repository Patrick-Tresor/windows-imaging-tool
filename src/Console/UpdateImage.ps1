# Update image dialog: picks .msu/.cab packages for an image and runs Update-OfflineImage.ps1.
# Dot-sourced by ImagingConsole.ps1, which provides the ConsoleData module.

function Show-UpdateImageDialog {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)]$Image      # a row from Get-ImageList
    )

    $form = New-ConsoleWindow 'UpdateImage.xaml' -Owner $Owner
    $dlg = $form.Window
    $d = $form.Controls

    $d.TxtTitle.Text = "Update $($Image.Name)"
    $last = @(Get-ImageServicingHistory -ImagePath $Image.FullName) | Select-Object -Last 1
    $d.TxtCurrent.Text = @(
        "Editions:      $(if ($Image.Indexes) { $Image.Indexes } else { '(not read)' })"
        "Last updated:  $(if ($last) { "$($last.date), build $($last.builds -join ', ')" } else { 'never (as captured)' })"
    ) -join "`r`n"

    $updatesDir = Join-Path $ContentRoot 'Updates'
    New-Item -ItemType Directory -Path $updatesDir -Force | Out-Null
    $packages = [Collections.ObjectModel.ObservableCollection[object]]::new()
    $add = {
        param([string[]]$Paths)
        $known = @($packages | ForEach-Object FullName)
        foreach ($row in Get-UpdatePackageRows -Path $Paths) { if ($known -notcontains $row.FullName) { $packages.Add($row) } }
    }
    & $add @($updatesDir)
    $d.GridPackages.ItemsSource = $packages

    $d.BtnAddFiles.Add_Click({
        $open = [Microsoft.Win32.OpenFileDialog]::new()
        $open.Filter = 'Update packages (*.msu;*.cab)|*.msu;*.cab'
        $open.Multiselect = $true
        if ($open.ShowDialog($dlg)) { & $add $open.FileNames }
    })
    $d.BtnAddFolder.Add_Click({
        $fb = [Windows.Forms.FolderBrowserDialog]::new()
        $fb.Description = 'Folder with .msu or .cab update packages'
        if ($fb.ShowDialog() -eq 'OK') { & $add @($fb.SelectedPath) }
    })
    $d.BtnRemove.Add_Click({ if ($d.GridPackages.SelectedItem) { [void]$packages.Remove($d.GridPackages.SelectedItem) } })
    $move = {
        param([int]$Offset)
        $i = $d.GridPackages.SelectedIndex
        $j = $i + $Offset
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $packages.Count) { return }
        $packages.Move($i, $j)
        $d.GridPackages.SelectedIndex = $j
    }
    $d.BtnUp.Add_Click({ & $move -1 })
    $d.BtnDown.Add_Click({ & $move 1 })
    $d.BtnOpenUpdates.Add_Click({ Invoke-Item $updatesDir })

    $d.ChkResetBase.IsEnabled = $d.ChkCleanup.IsChecked
    $d.ChkCleanup.Add_Click({
        $d.ChkResetBase.IsEnabled = $d.ChkCleanup.IsChecked
        if (-not $d.ChkCleanup.IsChecked) { $d.ChkResetBase.IsChecked = $false }
    })

    $d.BtnStart.Add_Click({
        try {
            if (-not $packages.Count) { Show-WindowMessage $dlg 'Update Image' 'Add at least one update package (.msu or .cab).'; return }
            # Checked now, so a mistake shows here; the job builds the same command with its progress file and log.
            $getArgs = {
                param($ProgressFile, $LogPath)
                Get-ImageUpdateArguments -ScriptPath (Join-Path $SrcDir 'Update-OfflineImage.ps1') -ImagePath $Image.FullName `
                    -Packages @($packages | ForEach-Object FullName) -Cleanup:([bool]$d.ChkCleanup.IsChecked) `
                    -ResetBase:([bool]$d.ChkResetBase.IsChecked) -NoBackup:(-not $d.ChkBackup.IsChecked) -ProgressFile $ProgressFile -LogPath $LogPath
            }
            [void](& $getArgs '' '')
            $text = "Apply $($packages.Count) update(s) to $($Image.Name)?`n`n" + (($packages | ForEach-Object { "- $($_.Name)" }) -join "`n") +
                "`n`nDo not deploy this image until the Progress window says it is done."
            if ([Windows.MessageBox]::Show($dlg, $text, 'Update Image', 'YesNo', 'Question') -ne 'Yes') { return }
            # Hidden, in its own process: servicing takes 20 minutes or more per edition and must not freeze the
            # console. Its steps are a card in the Progress window.
            $job = Start-ConsoleJob -Name 'image-update' -ArgumentList $getArgs -Hidden
            Show-BuildProgress -Owner $Owner -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Noun 'update' -Hidden `
                -Title "Updating $($Image.Name)" -OnFinished { try { Update-Images } catch { } }
            $dlg.DialogResult = $true
            $dlg.Close()
        } catch { Show-WindowMessage $dlg 'Update Image' $_.Exception.Message }
    })
    $d.BtnCancel.Add_Click({ $dlg.Close() })

    [bool]$dlg.ShowDialog()
}
