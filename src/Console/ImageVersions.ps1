# Image versions window: list, keep a copy, roll back, notes and cleanup for one image.
# Dot-sourced by ImagingConsole.ps1, which loads WPF, ConsoleData.psm1 and ImageVersions.psm1.

function Show-ImageVersionsDialog {
    # Returns $true when something changed, so the Images tab refreshes.
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)]$Image
    )
    [xml]$vx = Get-Content -Raw (Join-Path $PSScriptRoot 'ImageVersions.xaml')
    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($vx))
    $win.Owner = $Owner
    $v = @{}
    foreach ($node in $vx.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $v[$name] = $win.FindName($name)
    }
    $v.TxtTitle.Text = "Versions of $($Image.Name)"
    $state = @{ Changed = $false }
    $imagePath = Join-Path (Join-Path $ContentRoot 'Images') $Image.Name

    $say = { param($Text, $Icon = 'Information') [Windows.MessageBox]::Show($win, $Text, 'Image versions', 'OK', $Icon) | Out-Null }
    $ask = { param($Text) [Windows.MessageBox]::Show($win, $Text, 'Image versions', 'YesNo', 'Question') -eq 'Yes' }
    $safely = { param([scriptblock]$Action) try { & $Action } catch { & $say $_.Exception.Message 'Error' } }
    $load = { $v.GridVersions.ItemsSource = @(Get-ImageVersionRows -ContentRoot $ContentRoot -ImageName $Image.Name) }
    $selected = { @($v.GridVersions.SelectedItems) }
    $run = {
        param($Action, $Version, $Note)
        $args2 = Get-ImageVersionArguments -ScriptPath (Join-Path $SrcDir 'Invoke-ImageVersion.ps1') -ContentRoot $ContentRoot `
            -ImageName $Image.Name -Action $Action -Version $Version -Note $Note
        Start-Process powershell.exe -ArgumentList $args2
        $state.Changed = $true
    }

    $v.GridVersions.Add_SelectionChanged({
        $rows = & $selected
        $v.TxtNote.Text = if ($rows.Count -eq 1) { $rows[0].Note } else { '' }
    })

    $v.BtnKeep.Add_Click({ & $safely {
        $note = $v.TxtNote.Text.Trim()
        if (-not (& $ask "Copy $($Image.Name) ($($Image.SizeGB) GB) to Images\Previous as a new version?")) { return }
        & $run 'Keep' $null $note
        & $say 'Copying in a separate window. Click Refresh when it finishes.'
    } })

    $v.BtnRollback.Add_Click({ & $safely {
        $rows = & $selected
        if ($rows.Count -ne 1 -or -not $rows[0].Version) { & $say 'Select one earlier version (not Current).' 'Warning'; return }
        $r = $rows[0]
        $text = "Roll $($Image.Name) back to version $($r.Version)?`n`nThe current image is kept as a new version, then version $($r.Version) is copied back as the current image. " +
                "Every answer file without a version deploys it from then on. PCs being deployed right now should finish first."
        if (-not (& $ask $text)) { return }
        & $run 'Rollback' $r.Version $null
        & $say 'Rolling back in a separate window. Click Refresh when it finishes.'
    } })

    $v.BtnNote.Add_Click({ & $safely {
        $rows = & $selected
        if ($rows.Count -ne 1 -or -not $rows[0].Version) { & $say 'Select one earlier version to add a note to. A note for the current image goes in with Keep a copy.' 'Warning'; return }
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

    $v.BtnPrune.Add_Click({ & $safely {
        $keep = 0
        if (-not [int]::TryParse($v.TxtKeep.Text, [ref]$keep) -or $keep -lt 0) { & $say 'Type how many of the newest versions to keep (0 or more).' 'Warning'; return }
        $old = @(Get-ImageVersionsToDelete -ContentRoot $ContentRoot -ImageName $Image.Name -Keep $keep)
        if (-not $old) { & $say "Nothing to delete: there are $keep or fewer versions, or answer files use the older ones."; return }
        $gb = ($old | Measure-Object SizeGB -Sum).Sum
        if (-not (& $ask ("Delete {0} older version(s) ({1}), freeing {2:N1} GB? Versions answer files use are kept." -f $old.Count, ($old.Version -join ', '), $gb))) { return }
        Remove-ImageVersions -ContentRoot $ContentRoot -ImageName $Image.Name -Version @($old.Version)
        $state.Changed = $true
        & $load
    } })

    $v.BtnRefresh.Add_Click({ & $safely { & $load } })
    $v.BtnClose.Add_Click({ $win.Close() })

    & $safely { & $load }
    [void]$win.ShowDialog()
    $state.Changed
}
