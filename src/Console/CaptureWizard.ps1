# Capture wizard window. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg,
# Show-BuildProgress and the ConsoleData, VMwareVM and CaptureCheck modules.

function Show-CaptureWizard {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir
    )

    $form = New-ConsoleWindow 'CaptureWizard.xaml' -Owner $Owner
    $wiz = $form.Window
    $w = $form.Controls

    # Check: the Check the disk page's run (checklist, result file, background process) for the disk in CheckedDisk.
    $state = @{ Page = 0; Last = 4; Checklist = $null; CheckedDisk = $null; CheckProc = $null; ResultPath = $null
        Result = $null; CheckPassed = $false; CheckLog = $null; HandedOver = $false }
    $checkPage = 2
    $settings = Get-DeploySettings -ContentRoot $ContentRoot

    # Page 2: the sysprep command to run on the reference machine, from the share when there is one.
    Update-ContentTools -ContentRoot $ContentRoot
    $toolsDir = if ($settings.share.path) { Join-Path $settings.share.path 'Tools' } else { Join-Path $ContentRoot 'Tools' }
    $w.TxtPrepCmd.Text = "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $toolsDir 'Prepare-Reference.ps1')`""
    # Sysprep: always with -RemoveUserApps (Store apps installed for a user only break sysprep; the Store stays).
    $copyCommand = {
        param($box)
        # Another program (clipboard history, remote desktop) can hold the clipboard for a moment, so retry
        # and never let a failed copy close the wizard.
        try {
            [Windows.Forms.Clipboard]::SetDataObject($box.Text, $true, 10, 100)
        } catch {
            $box.Focus() | Out-Null
            $box.SelectAll()
            Show-WindowMessage $wiz 'Capture Wizard' "Could not copy: another program is using the clipboard. The command is selected; press Ctrl+C to copy it."
        }
    }
    $w.BtnCopyCmd.Add_Click({ & $copyCommand $w.TxtPrepCmd })
    # Sysprep on each PC instead (VM disk file only): the VM is only shut down, fully (not Fast Startup's hibernation).
    $prepCommand = $w.TxtPrepCmd.Text; $prepIntro = $w.TxtPrepIntro.Text
    $prepDone = "$($w.ChkPrepared.Content)"
    $updatePrepPage = {
        $atDeploy = (& $getChoice).SysprepAtDeploy
        $w.TxtPrepTitle.Text = if ($atDeploy) { 'Shut the reference VM down' } else { 'Run sysprep on the reference machine' }
        $w.TxtPrepIntro.Text = if ($atDeploy) {
            'Run this in the VM as administrator: it frees space so the image is smaller (10-30 minutes), then shuts the VM down fully (the Start menu''s Shut down only hibernates Windows when Fast Startup is on). Each PC deployed from this image then runs the same checks and sysprep at its first start, and restarts into Windows setup. A sysprep failure there leaves that PC unfinished, with the reason on its logon screen.'
        } else { $prepIntro }
        $w.TxtPrepCmd.Text = if ($atDeploy) { "$prepCommand -CleanupOnly -ShutDown" } else { "$prepCommand -RemoveUserApps" }
        $w.ChkPrepared.Content = if ($atDeploy) { 'The VM is shut down' } else { $prepDone }
    }
    $w.ChkSysprepAtDeploy.Add_Click({ try { & $updatePrepPage } catch { Show-WindowMessage $wiz 'Capture Wizard' $_.Exception.Message } })

    # Page 3 defaults.
    $w.TxtName.Text = 'Win11-{0:yyyyMMdd}' -f (Get-Date)

    # Save to (VM disk file only): the content root's Images folder by default, or any folder on this PC or a server.
    $defaultSaveTo = [IO.Path]::Combine($ContentRoot.TrimEnd('\'), 'Images')
    $isDefaultSaveTo = { param($p) "$p".Trim().Trim('"').TrimEnd('\') -ieq $defaultSaveTo }
    $updateSaveToHint = {
        $w.TxtSaveToHint.Text = if (& $isDefaultSaveTo $w.TxtSaveTo.Text) {
            'The Images folder of the content root, so the image shows on the Images tab.'
        } else {
            'Another folder: the image shows on the Images tab only when the console has that folder''s content root open.'
        }
    }
    $w.TxtSaveTo.Text = $defaultSaveTo
    $w.TxtSaveTo.Add_TextChanged({ try { & $updateSaveToHint } catch { } })
    $w.BtnSaveToDefault.Add_Click({ $w.TxtSaveTo.Text = $defaultSaveTo })
    $w.BtnSaveTo.Add_Click({
        $dlg = [Windows.Forms.FolderBrowserDialog]::new()
        $dlg.Description = 'Where to save the image: a folder on this PC, or Network > your server > its share.'
        $current = $w.TxtSaveTo.Text.Trim().Trim('"')
        if ($current -and [IO.Directory]::Exists($current)) { $dlg.SelectedPath = $current }
        if ($dlg.ShowDialog() -eq 'OK') { $w.TxtSaveTo.Text = $dlg.SelectedPath }
    })
    & $updateSaveToHint

    # Page 1: reference machine choices.
    # The disk file choice starts at the current disk of the first VMware Workstation VM, when there is one.
    $prefillDiskFile = {
        $vmx = @(try { Get-VMwareInventory } catch { })
        if ($vmx -and -not $w.TxtDiskFile.Text) {
            try {
                $disk = @(Get-VmxDiskPaths -VmxPath $vmx[0])[0]
                if (-not $disk) { $disk = @(Get-VmdkLeafPaths -Folder (Split-Path -Parent $vmx[0]))[0] }
                if ($disk) { $w.TxtDiskFile.Text = $disk }
            } catch { }
        }
    }
    $w.TxtDiskFileStatus.Text = 'qemu-img.exe is missing, so only VHD and VHDX files can be read: install QEMU for Windows and add its folder to PATH.'
    $w.TxtDiskFileStatus.Visibility = if (Find-QemuImg) { 'Collapsed' } else { 'Visible' }
    $w.BtnDiskFileBrowse.Add_Click({
        $dlg = [Windows.Forms.OpenFileDialog]::new()
        $dlg.Filter = 'VM disk files (*.vmdk;*.vhdx;*.vhd;*.vdi;*.qcow2)|*.vmdk;*.vhdx;*.vhd;*.vdi;*.qcow2|All files (*.*)|*.*'
        if ($w.TxtDiskFile.Text -and (Test-Path -LiteralPath (Split-Path -Parent $w.TxtDiskFile.Text))) { $dlg.InitialDirectory = Split-Path -Parent $w.TxtDiskFile.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $w.TxtDiskFile.Text = $dlg.FileName }
    })
    & $prefillDiskFile

    $getChoice = {
        [pscustomobject]@{
            Name        = $w.TxtName.Text.Trim()
            Description = $w.TxtDescription.Text.Trim()
            Compression = $w.CmbCompression.SelectedItem.Tag
            SysprepAtDeploy = [bool]$w.ChkSysprepAtDeploy.IsChecked
            DiskFile    = $w.TxtDiskFile.Text.Trim().Trim('"')
            SaveTo      = $w.TxtSaveTo.Text.Trim().Trim('"').TrimEnd('\')
        }
    }

    # The capture reads the VM's disk with DISM on this PC and saves to the content root: no share, no ADK, no media.

    # Page 3: check the disk. The quick checks run here; reading Windows on the disk (and copying a VMDK to a VHD
    # first, which takes minutes) runs in a hidden elevated PowerShell, Capture-VMImage.ps1 -CheckOnly, that writes
    # a result file this timer reads. The copy it makes is handed to the capture, or deleted when the wizard closes.
    $checkTimer = New-Object Windows.Threading.DispatcherTimer
    $checkTimer.Interval = [TimeSpan]::FromMilliseconds(500)

    $stopCheck = {
        # Stops a running check and deletes its copy of the disk (unless the capture took it over).
        $checkTimer.Stop()
        $proc = $state.CheckProc
        $converted = $(if ($state.Result) { "$($state.Result.convertedPath)" } else { '' })
        if ($proc -and -not $proc.HasExited) {
            $latest = Read-CaptureCheckResult -Path $state.ResultPath
            if ($latest -and "$($latest.step)" -eq 'convert') {
                # Only the copy is running: stop it and its qemu-img, then delete the half-written file.
                & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
                try { $proc.WaitForExit(5000) | Out-Null } catch { }
                Remove-ConvertedDisk "$($latest.convertedPath)"
            } else {
                # It may have the disk mounted: let it finish, and tell it to delete its copy.
                try { [IO.File]::WriteAllText("$($state.ResultPath).cancel", 'cancel') } catch { }
            }
        } elseif ($converted -and -not $state.HandedOver) {
            Remove-ConvertedDisk $converted
        }
        $state.CheckProc = $null; $state.Result = $null; $state.CheckPassed = $false; $state.Checklist = $null; $state.CheckedDisk = $null
    }

    $refreshCheck = {
        if (-not $state.Checklist) { return }
        $result = Read-CaptureCheckResult -Path $state.ResultPath
        $proc = $state.CheckProc
        if ($state.Checklist.Passed -and $proc -and $proc.HasExited -and (-not $result -or "$($result.state)" -eq 'running')) {
            $result = [pscustomobject]@{ state = 'failed'; error = 'The check stopped before it finished. Open the log to see why.'; convertedPath = '' }
        }
        $state.Result = $result
        $view = Get-CaptureCheckView -Checklist $state.Checklist -Result $result -SysprepAtDeploy:((& $getChoice).SysprepAtDeploy)
        $w.LstChecks.ItemsSource = @($view.Rows)
        $w.BarCheck.Visibility = if ($view.Busy) { 'Visible' } else { 'Collapsed' }
        $w.BarCheck.IsIndeterminate = $view.Percent -lt 0
        if ($view.Percent -ge 0) { $w.BarCheck.Value = $view.Percent }
        $w.BtnCheckLog.IsEnabled = [bool]($state.CheckLog -and (Test-Path -LiteralPath $state.CheckLog))
        $state.CheckPassed = $view.Passed
        if (-not $view.Busy) { $checkTimer.Stop() }
        if ($state.Page -eq $checkPage) { $w.BtnNext.IsEnabled = $view.Passed }
    }

    $startCheck = {
        & $stopCheck
        $c = & $getChoice
        $state.CheckedDisk = $c.DiskFile
        $state.Checklist = Get-CaptureDiskChecklist -DiskPath $c.DiskFile -QemuImg (Find-QemuImg) -VBoxManage (Find-VBoxManage)
        if ($state.Checklist.Passed) {
            $id = [guid]::NewGuid().ToString('N')
            $state.ResultPath = Join-Path $env:TEMP "capture-check-$id.json"
            $logDir = [IO.Path]::Combine($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }), 'ImagingConsole', 'Logs')
            $state.CheckLog = [IO.Path]::Combine($logDir, ('capture-check-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
            $checkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg (Join-Path $SrcDir 'Capture-VMImage.ps1')),
                '-CheckOnly', '-DiskPath', (ConvertTo-Arg $c.DiskFile), '-ResultPath', (ConvertTo-Arg $state.ResultPath),
                '-LogPath', (ConvertTo-Arg $state.CheckLog))
            $state.CheckProc = Start-Process powershell.exe -ArgumentList $checkArgs -WindowStyle Hidden -PassThru
            $null = $state.CheckProc.Handle   # PowerShell 5.1 only keeps HasExited/ExitCode if the handle was read
            $checkTimer.Start()
        }
        & $refreshCheck
    }

    $enterCheck = {
        # Runs the check again unless it already passed for this disk and its copy is still current.
        $c = & $getChoice
        $current = $state.CheckPassed -and $state.CheckedDisk -eq $c.DiskFile
        if ($current -and $state.Result -and "$($state.Result.convertedPath)") {
            $current = Test-ConvertedDiskReusable -ConvertedPath "$($state.Result.convertedPath)" -SourcePath "$($state.Result.readPath)"
        }
        if (-not $current -and -not ($state.CheckProc -and -not $state.CheckProc.HasExited -and $state.CheckedDisk -eq $c.DiskFile)) { & $startCheck }
        else { & $refreshCheck }
    }

    $checkTimer.Add_Tick({ try { & $refreshCheck } catch { $checkTimer.Stop() } })
    $w.BtnCheckAgain.Add_Click({ try { & $startCheck } catch { Show-WindowMessage $wiz 'Capture Wizard' $_.Exception.Message } })
    $w.BtnCheckLog.Add_Click({
        if ($state.CheckLog -and (Test-Path -LiteralPath $state.CheckLog)) { Start-Process notepad.exe -ArgumentList (ConvertTo-Arg $state.CheckLog) }
    })
    $wiz.Add_Closed({ try { & $stopCheck } catch { } })

    # Returns an error message for the current page, or nothing when the user may move on.
    $validate = {
        $c = & $getChoice
        switch ($state.Page) {
            0 {
                if (-not ($c.DiskFile -and (Test-Path -LiteralPath $c.DiskFile -PathType Leaf))) { 'Choose the VM''s disk file.' }
                elseif ([IO.Path]::GetExtension($c.DiskFile) -notin '.vhd', '.vhdx' -and -not (Find-QemuImg)) { 'Reading this disk file needs qemu-img.exe: install QEMU for Windows and add its folder to PATH.' }
            }
            1 {
                if (-not $w.ChkPrepared.IsChecked) { $(if ($c.SysprepAtDeploy) { 'Shut the VM down first, then tick the box.' } else { 'Run the prepare command on the reference machine first, then tick the box.' }) }
                elseif ((Test-VMwareFolderInUse -Folder (Split-Path -Parent $c.DiskFile))) { $(if ($c.SysprepAtDeploy) { 'VMware still has this VM open. Shut it down, then click Next.' } else { 'VMware still has this VM open. Wait until sysprep has shut it down, then click Next.' }) }
            }
            2 {
                if (-not $state.CheckPassed) { 'The disk check has not passed yet. Fix the lines with a cross, then click Check again.' }
            }
            3 {
                if (-not (Test-ImageName $c.Name)) { 'The name may only contain letters, digits, dot, dash and underscore.' }
                elseif ($saveProblem = Get-CaptureSaveFolderProblem -Path $c.SaveTo) { $saveProblem }
            }
        }
    }

    $showSummary = {
        $c = & $getChoice
        $current = try { Resolve-VmdkCurrentDisk -Path $c.DiskFile } catch { $c.DiskFile }
        $target = "Disk file $current, captured on this PC" +
            $(if ($current -ne $c.DiskFile) { "`r`n               (the newest snapshot of $(Split-Path -Leaf $c.DiskFile))" }) +
            $(if ($state.Result -and "$($state.Result.state)" -eq 'done') {
                "`r`nWindows:       $($state.Result.windowsName), $(Format-ByteSize ([double]$state.Result.usedBytes)) used, $(if ($state.Result.generalized -eq $true) { 'generalized' } else { 'not sysprepped' })" }) +
            $(if ($c.SysprepAtDeploy -and -not ($state.Result -and $state.Result.generalized -eq $true)) { "`r`nSysprep:       on each PC at its first start (5-10 minutes and one restart more)" })
        $w.TxtSummary.Text = @(
            "Image name:    $($c.Name).$(if ($c.Compression -eq 'recovery') { 'esd' } else { 'wim' })"
            "Description:   $(if ($c.Description) { $c.Description } else { '(none)' })"
            "Compression:   $($c.Compression)"
            $(if (@(Get-ExistingImageFiles -ImagesDir $c.SaveTo -Name $c.Name).Count) {
                "Existing image: replaced after the capture succeeds; the old one is kept in Previous next to it" })
            ''
            "Media:         $target"
            "Saved to:      $($c.SaveTo)"
        ) -join "`r`n"
    }

    $showPage = {
        & $updatePrepPage
        for ($i = 0; $i -le $state.Last; $i++) {
            $w["Page$i"].Visibility = if ($i -eq $state.Page) { 'Visible' } else { 'Collapsed' }
            $w["Step$i"].SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($i -eq $state.Page) { 'SurfaceBrush' } elseif ($i -lt $state.Page) { 'FaintBrush' } else { 'MutedBrush' }))
            $w["Step$i"].FontWeight = if ($i -eq $state.Page) { 'SemiBold' } else { 'Normal' }
        }
        $w.BtnBack.IsEnabled = $state.Page -gt 0
        $w.BtnNext.IsEnabled = $true
        $w.BtnNext.Content = if ($state.Page -ne $state.Last) { 'Next' } else { 'Start' }
        if ($state.Page -eq $checkPage) { & $enterCheck }
        if ($state.Page -eq $state.Last) { & $showSummary }
    }

    $finish = {
        $c = & $getChoice
        # Its own process, followed in the Progress window (steps, bars, time left), like a media build.
        $reuse = if ($state.Result -and $state.CheckedDisk -eq $c.DiskFile) { "$($state.Result.convertedPath)" } else { '' }
        $job = Start-ConsoleJob -Name "capture-$($c.Name)" -ArgumentList {
            param($progressFile, $logPath)
            Get-VMCaptureArguments -ScriptPath (Join-Path $SrcDir 'Capture-VMImage.ps1') `
                -ContentRoot $ContentRoot -DiskPath $c.DiskFile -Name $c.Name -Description $c.Description -Compression $c.Compression `
                -SysprepAtDeploy:$c.SysprepAtDeploy -ImagesDir $(if (& $isDefaultSaveTo $c.SaveTo) { '' } else { $c.SaveTo }) -ReuseConvertedDisk $reuse -ProgressFile $progressFile -LogPath $logPath
        }
        $state.HandedOver = $true
        Show-BuildProgress -Owner $Owner -ProgressFile $job.ProgressFile -LogPath $job.LogPath -Process $job.Process -Title "Capturing $($c.Name)"
        $true
    }

    $w.BtnBack.Add_Click({
        try {
            if ($state.Page -gt 0) { $state.Page-- }
            & $showPage
        } catch { Show-WindowMessage $wiz 'Capture Wizard' $_.Exception.Message }
    })
    $w.BtnNext.Add_Click({
        try {
            $problem = & $validate
            if ($problem) { Show-WindowMessage $wiz 'Capture Wizard' $problem; return }
            if ($state.Page -lt $state.Last) {
                $state.Page++
                & $showPage; return
            }
            if (& $finish) { $wiz.DialogResult = $true; $wiz.Close() }
        } catch { Show-WindowMessage $wiz 'Capture Wizard' $_.Exception.Message }
    })
    $w.BtnCancel.Add_Click({ $wiz.Close() })

    & $showPage
    [bool]$wiz.ShowDialog()
}
