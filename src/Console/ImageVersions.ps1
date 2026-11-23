# Image versions window: list, roll back, notes, delete, and the one keep count for every image.
# Dot-sourced by ImagingConsole.ps1, which loads WPF, ConsoleData.psm1 and ImageVersions.psm1.

function Show-ImageVersionsDialog {
    # Returns $true when something changed, so the Images tab refreshes.
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)]$Image
    )
    $form = New-ConsoleWindow 'ImageVersions.xaml' -Owner $Owner
    $win = $form.Window
    $v = $form.Controls
    $v.TxtTitle.Text = "Versions of $($Image.Name)"
    $state = @{ Changed = $false }
    $imagePath = Join-Path (Join-Path $ContentRoot 'Images') $Image.Name
    $v.TxtLimit.Text = "$(Get-VersionsToKeep -ContentRoot $ContentRoot)"

    $say = { param($Text, $Icon = 'Information') [Windows.MessageBox]::Show($win, $Text, 'Image versions', 'OK', $Icon) | Out-Null }
    $ask = { param($Text) [Windows.MessageBox]::Show($win, $Text, 'Image versions', 'YesNo', 'Question') -eq 'Yes' }
    $safely = { param([scriptblock]$Action) try { & $Action } catch { & $say $_.Exception.Message 'Error' } }
    $load = { $v.GridVersions.ItemsSource = @(Get-ImageVersionRows -ContentRoot $ContentRoot -ImageName $Image.Name) }
    $selected = { @($v.GridVersions.SelectedItems) }
    $run = {
        param($Version)
        $args2 = Get-ImageVersionArguments -ScriptPath (Join-Path $SrcDir 'Invoke-ImageVersion.ps1') -ContentRoot $ContentRoot `
            -ImageName $Image.Name -Version $Version
        # Hidden, with its steps as a card in the Progress window; the Images tab refreshes when it ends. This window
        # closes so the Progress window can be used (a dialog blocks the others while it is open).
        $job = Start-ConsoleJob -Name 'image-version' -ArgumentList $args2 -Hidden
        Show-BuildProgress -Owner $Owner -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Noun 'copy' -Hidden `
            -Title "Rolling $($Image.Name) back to $Version" `
            -OnFinished { try { Update-Images; Update-Answers } catch { } }
        $state.Changed = $true
        $win.Close()
    }

    $v.GridVersions.Add_SelectionChanged({
        $rows = @(& $selected)
        $v.TxtNote.Text = if ($rows.Count -eq 1) { $rows[0].Note } else { '' }
    })

    $v.BtnRollback.Add_Click({ & $safely {
        $rows = @(& $selected)
        if ($rows.Count -ne 1 -or -not $rows[0].Version) { & $say 'Select one earlier version (not Current).' 'Warning'; return }
        $r = $rows[0]
        $text = "Roll $($Image.Name) back to version $($r.Version)?`n`nThe current image is kept as a new version, then version $($r.Version) becomes the current image again. " +
                "Every answer file without a version deploys it from then on. PCs being deployed right now should finish first."
        if (-not (Test-ImageHardLinks -Path (Split-Path $imagePath -Parent))) { $text += "`n`nThis folder can't make hard links, so the rollback copies $($r.SizeGB) GB." }
        if (-not (& $ask $text)) { return }
        & $run $r.Version
    } })

    $v.BtnNote.Add_Click({ & $safely {
        $rows = @(& $selected)
        if ($rows.Count -ne 1 -or -not $rows[0].Version) { & $say 'Select one earlier version to add a note to.' 'Warning'; return }
        Set-ImageVersionNote -ImagePath $imagePath -Version $rows[0].Version -Note $v.TxtNote.Text.Trim()
        & $load
    } })

    $v.BtnDelete.Add_Click({ & $safely {
        $versions = @(& $selected | Where-Object Version | ForEach-Object Version)
        if (-not $versions) { & $say 'Select one or more earlier versions. The current image is deleted from the Images folder itself.' 'Warning'; return }
        if (-not (& $ask "Delete version(s) $($versions -join ', ')? This cannot be undone.")) { return }
        Remove-ImageVersions -ContentRoot $ContentRoot -ImageName $Image.Name -Version $versions
        $state.Changed = $true
        & $load
    } })

    $v.BtnLimitSave.Add_Click({ & $safely {
        $keep = 0
        if (-not [int]::TryParse($v.TxtLimit.Text.Trim(), [ref]$keep) -or $keep -lt 0) { & $say 'Type how many earlier versions to keep (0 keeps them all).' 'Warning'; return }
        Set-VersionsToKeep -ContentRoot $ContentRoot -Keep $keep
        # This image now; the others when a capture, update or rollback next replaces them.
        $old = @(if ($keep -gt 0) { Get-ImageVersionsToDelete -ContentRoot $ContentRoot -ImageName $Image.Name -Keep $keep })
        if ($old) {
            $gb = ($old | Measure-Object SizeGB -Sum).Sum
            if (& $ask ("Every image now keeps its newest {0} earlier versions. Delete the {1} older version(s) of {2} now ({3}), freeing {4:N1} GB? Versions answer files use are kept." -f $keep, $old.Count, $Image.Name, ($old.Version -join ', '), $gb)) {
                Remove-ImageVersions -ContentRoot $ContentRoot -ImageName $Image.Name -Version @($old.Version)
                $state.Changed = $true
                & $load
            }
        } else {
            & $say $(if ($keep -eq 0) { 'Every image now keeps all its earlier versions.' } else { "Every image now keeps its newest $keep earlier versions." })
        }
    } })
    $v.BtnRefresh.Add_Click({ & $safely { & $load } })
    $v.BtnClose.Add_Click({ $win.Close() })

    & $safely { & $load }
    [void]$win.ShowDialog()
    $state.Changed
}
