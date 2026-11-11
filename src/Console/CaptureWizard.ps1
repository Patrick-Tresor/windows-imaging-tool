# Capture wizard window. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg, Get-UsbDiskChoices,
# Show-BuildProgress and the ConsoleData, VMwareVM and CaptureCheck modules.

function Show-CaptureWizard {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir
    )

    [xml]$wxaml = Get-Content -Raw (Join-Path $PSScriptRoot 'CaptureWizard.xaml')
    $wiz = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($wxaml))
    $wiz.Owner = $Owner
    Enable-WheelScrolling $wiz
    $w = @{}
    foreach ($node in $wxaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $w[$name] = $wiz.FindName($name)
    }

    # Check: the Check the disk page's run (checklist, result file, background process) for the disk in CheckedDisk.
    $state = @{ Page = 0; Last = 4; Checklist = $null; CheckedDisk = $null; CheckProc = $null; ResultPath = $null
        Result = $null; CheckPassed = $false; CheckLog = $null; HandedOver = $false }
    $checkPage = 2
    $settings = Get-DeploySettings -ContentRoot $ContentRoot

    function Show-WizardError([string]$Text) {
        [Windows.MessageBox]::Show($wiz, $Text, 'Capture Wizard', 'OK', 'Warning') | Out-Null
    }

    # Page 2: the sysprep command to run on the reference machine, from the share when there is one.
    Update-ContentTools -ContentRoot $ContentRoot
    $toolsDir = if ($settings.share.path) { Join-Path $settings.share.path 'Tools' } else { Join-Path $ContentRoot 'Tools' }
    $w.TxtPrepCmd.Text = "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $toolsDir 'Prepare-Reference.ps1')`""
    $copyCommand = {
        param($box)
        # Another program (clipboard history, remote desktop) can hold the clipboard for a moment, so retry
        # and never let a failed copy close the wizard.
        try {
            [Windows.Forms.Clipboard]::SetDataObject($box.Text, $true, 10, 100)
        } catch {
            $box.Focus() | Out-Null
            $box.SelectAll()
            Show-WizardError "Could not copy: another program is using the clipboard. The command is selected; press Ctrl+C to copy it."
        }
    }
    $w.BtnCopyCmd.Add_Click({ & $copyCommand $w.TxtPrepCmd })
    # Sysprep on each PC instead (VM disk file only): the VM is only shut down, fully (not Fast Startup's hibernation).
    $prepCommand = $w.TxtPrepCmd.Text; $prepIntro = $w.TxtPrepIntro.Text; $prepHint = $w.TxtPrepHint.Text
    $prepDone = "$($w.ChkPrepared.Content)"
    $updatePrepPage = {
        $atDeploy = (& $getChoice).SysprepAtDeploy
        $w.TxtPrepTitle.Text = if ($atDeploy) { 'Shut the reference VM down' } else { 'Run sysprep on the reference machine' }
        $w.TxtPrepIntro.Text = if ($atDeploy) {
            'Run this in the VM to shut it down fully (the Start menu''s Shut down only hibernates Windows when Fast Startup is on). Each PC deployed from this image then runs the same checks and sysprep at its first start, and restarts into Windows setup. A sysprep failure there leaves that PC unfinished, with the reason on its logon screen.'
        } else { $prepIntro }
        $w.TxtPrepCmd.Text = if ($atDeploy) { 'shutdown /s /t 0' } else { $prepCommand }
        $w.TxtPrepHint.Visibility = if ($atDeploy) { 'Collapsed' } else { 'Visible' }
        $w.ChkPrepared.Content = if ($atDeploy) { 'The VM is shut down' } else { $prepDone }
    }
    $w.ChkSysprepAtDeploy.Add_Click({ try { & $updatePrepPage } catch { Show-WizardError $_.Exception.Message } })

    # Page 3 defaults.
    $w.TxtName.Text = 'Win11-{0:yyyyMMdd}' -f (Get-Date)

    # Page 1: reference machine choices.
    $loadUsb = {
        $disks = @(Get-UsbDiskChoices)
        $w.CmbUsb.ItemsSource = $disks
        if ($disks) { $w.CmbUsb.SelectedIndex = 0 }
    }
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
    & $loadUsb; & $prefillDiskFile
    $w.RbDiskFile.IsChecked = $true
    $w.BtnUsbRefresh.Add_Click($loadUsb)
    $w.TxtIsoFolder.Text = [Environment]::GetFolderPath('Desktop')
    $w.BtnIsoFolder.Add_Click({
        $dlg = [Windows.Forms.FolderBrowserDialog]::new()
        if ($dlg.ShowDialog() -eq 'OK') { $w.TxtIsoFolder.Text = $dlg.SelectedPath }
    })

    $getChoice = {
        [pscustomobject]@{
            Name        = $w.TxtName.Text.Trim()
            Description = $w.TxtDescription.Text.Trim()
            Compression = $w.CmbCompression.SelectedItem.Tag
            Split       = [bool]$w.ChkSplit.IsChecked
            Unattended  = [bool]$w.ChkUnattended.IsChecked
            NewVersion  = [bool]$w.ChkNewVersion.IsChecked
            SysprepAtDeploy = [bool]$w.ChkSysprepAtDeploy.IsChecked -and $w.RbDiskFile.IsChecked
            Mode        = if ($w.RbDiskFile.IsChecked) { 'DiskFile' } elseif ($w.RbIso.IsChecked) { 'Iso' } else { 'Usb' }
            DiskFile    = $w.TxtDiskFile.Text.Trim().Trim('"')
            IsoFolder   = $w.TxtIsoFolder.Text.Trim()
            Usb         = $w.CmbUsb.SelectedItem
        }
    }

    # The disk file capture reads the VM's disk with DISM on this PC and saves to the content root: no share, no ADK, no media.
    $onThisPC = @('DiskFile')

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
    $w.BtnCheckAgain.Add_Click({ try { & $startCheck } catch { Show-WizardError $_.Exception.Message } })
    $w.BtnCheckLog.Add_Click({
        if ($state.CheckLog -and (Test-Path -LiteralPath $state.CheckLog)) { Start-Process notepad.exe -ArgumentList (ConvertTo-Arg $state.CheckLog) }
    })
    $wiz.Add_Closed({ try { & $stopCheck } catch { } })

    # Returns an error message for the current page, or nothing when the user may move on.
    $validate = {
        $c = & $getChoice
        switch ($state.Page) {
            0 {
                if ($c.Mode -eq 'DiskFile' -and -not ($c.DiskFile -and (Test-Path -LiteralPath $c.DiskFile -PathType Leaf))) { 'Choose the VM''s disk file.' }
                elseif ($c.Mode -eq 'DiskFile' -and [IO.Path]::GetExtension($c.DiskFile) -notin '.vhd', '.vhdx' -and -not (Find-QemuImg)) { 'Reading this disk file needs qemu-img.exe: install QEMU for Windows and add its folder to PATH.' }
                elseif ($c.Mode -eq 'Iso' -and -not (Test-Path $c.IsoFolder)) { 'Choose a folder for the ISO.' }
                elseif ($c.Mode -eq 'Usb' -and -not $c.Usb) { 'No USB stick found. Plug one in and click Refresh.' }
            }
            1 {
                if (-not $w.ChkPrepared.IsChecked) { $(if ($c.SysprepAtDeploy) { 'Shut the VM down first, then tick the box.' } else { 'Run the prepare command on the reference machine first, then tick the box.' }) }
                elseif ($c.Mode -eq 'DiskFile' -and (Test-VMwareFolderInUse -Folder (Split-Path -Parent $c.DiskFile))) { $(if ($c.SysprepAtDeploy) { 'VMware still has this VM open. Shut it down, then click Next.' } else { 'VMware still has this VM open. Wait until sysprep has shut it down, then click Next.' }) }
            }
            2 {
                if (-not $state.CheckPassed) { 'The disk check has not passed yet. Fix the lines with a cross, then click Check again.' }
            }
            3 {
                if (-not (Test-ImageName $c.Name)) { 'The name may only contain letters, digits, dot, dash and underscore.' }
                elseif (-not $c.NewVersion -and @(Get-ImageList -ContentRoot $ContentRoot | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $c.Name }).Count) {
                    "An image named $($c.Name) already exists. Pick another name, or tick the box to capture it as a new version."
                }
            }
        }
    }

    $showSummary = {
        $c = & $getChoice
        $target = switch ($c.Mode) {
            'DiskFile' {
                $current = try { Resolve-VmdkCurrentDisk -Path $c.DiskFile } catch { $c.DiskFile }
                "Disk file $current, captured on this PC" +
                $(if ($current -ne $c.DiskFile) { "`r`n               (the newest snapshot of $(Split-Path -Leaf $c.DiskFile))" }) +
                $(if ($state.Result -and "$($state.Result.state)" -eq 'done') {
                    "`r`nWindows:       $($state.Result.windowsName), $(Format-DiskSize ([double]$state.Result.usedBytes)) used, $(if ($state.Result.generalized -eq $true) { 'generalized' } else { 'not sysprepped' })" }) +
                $(if ($c.SysprepAtDeploy -and -not ($state.Result -and $state.Result.generalized -eq $true)) { "`r`nSysprep:       on each PC at its first start (5-10 minutes and one restart more)" })
            }
            'Iso' { "Capture ISO in $($c.IsoFolder)\Capture-WinPE.iso" }
            'Usb' { "USB stick $($c.Usb.Label) (will be ERASED)" }
        }
        $saveTo = switch ($c.Mode) {
            'Usb'    { 'The USB stick''s DEPLOY partition' }
            { $_ -in $onThisPC } { "$ContentRoot\Images" }
            default  { "$($settings.share.path)\Images" }
        }
        $w.TxtSummary.Text = @(
            "Image name:    $($c.Name).$(if ($c.Split) { 'swm (split)' } else { 'wim' })"
            "Description:   $(if ($c.Description) { $c.Description } else { '(none)' })"
            "Compression:   $($c.Compression)"
            $(if ($c.Mode -notin $onThisPC) { "Unattended:    $(if ($c.Unattended) { 'yes, shuts down when done' } else { 'no, asks for YES on the machine' })" })
            $(if ($c.NewVersion -and @(Get-ImageList -ContentRoot $ContentRoot | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $c.Name }).Count) {
                "Existing image: replaced after the capture succeeds; the old one is kept in Images\Previous" })
            ''
            "Media:         $target"
            "Saved to:      $saveTo"
        ) -join "`r`n"
        $issues = @()
        if ($c.Mode -notin $onThisPC) {
            $issues += @(Get-CaptureReadiness -ContentRoot $ContentRoot -Destination $(if ($c.Mode -eq 'Usb') { 'Usb' } else { 'Network' }))
            # Capture media is built with the ADK on this PC, so check it before Build and start.
            $issues += @((Get-AdkStatus).Problems)
        }
        $w.TxtSummaryIntro.Text = if ($c.Mode -eq 'DiskFile') {
            'Clicking Start opens a progress window with each step and the time left. The copy of the disk made by the check is reused, so the capture starts right away. The new image appears on the Images tab when it finishes.'
        } else {
            'Clicking Build and start opens a window that builds the capture media (a few minutes). Boot the reference machine from it to capture. The new image appears on the Images tab when it finishes.'
        }
        $w.TxtIssues.Text = if ($issues) { "Fix before you start:`n" + ($issues -join "`n") } else { '' }
        $w.BtnNext.IsEnabled = -not $issues
    }

    $showPage = {
        $isDisk = (& $getChoice).Mode -eq 'DiskFile'
        # Sysprep on each PC needs the disk check, so only for a VM's disk file.
        $w.ChkSysprepAtDeploy.Visibility = if ($isDisk) { 'Visible' } else { 'Collapsed' }
        & $updatePrepPage
        $w.Step2.Text = if ($isDisk) { '3. Check the disk' } else { '3. Check the disk (VM disk only)' }
        for ($i = 0; $i -le $state.Last; $i++) {
            $w["Page$i"].Visibility = if ($i -eq $state.Page) { 'Visible' } else { 'Collapsed' }
            $w["Step$i"].Foreground = if ($i -eq $state.Page) { 'White' } elseif ($i -lt $state.Page) { '#9CA3AF' } else { '#6B7280' }
            $w["Step$i"].FontWeight = if ($i -eq $state.Page) { 'SemiBold' } else { 'Normal' }
        }
        $w.BtnBack.IsEnabled = $state.Page -gt 0
        $w.BtnNext.IsEnabled = $true
        $w.BtnNext.Content = if ($state.Page -ne $state.Last) { 'Next' } elseif ((& $getChoice).Mode -in $onThisPC) { 'Start' } else { 'Build and start' }
        if ($state.Page -eq $checkPage) { & $enterCheck }
        if ($state.Page -eq $state.Last) { & $showSummary }
    }

    $finish = {
        $c = & $getChoice
        if ($c.Mode -eq 'Usb' -and
            [Windows.MessageBox]::Show($wiz, "Everything on $($c.Usb.Label) will be erased. Continue?", 'Capture Wizard', 'YesNo', 'Warning') -ne 'Yes') { return $false }

        if ($c.Mode -eq 'DiskFile') {
            # Its own minimized window, followed in the progress window (steps, bars, time left), like a media build.
            $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
            $progressFile = Join-Path $env:TEMP "capture-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
            $logDir = [IO.Path]::Combine($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }), 'ImagingConsole', 'Logs')
            $logPath = [IO.Path]::Combine($logDir, "capture-$($c.Name)-$stamp.log")
            $reuse = if ($state.Result -and $state.CheckedDisk -eq $c.DiskFile) { "$($state.Result.convertedPath)" } else { '' }
            $proc = Start-Process powershell.exe -WindowStyle Minimized -PassThru -ArgumentList (Get-VMCaptureArguments -ScriptPath (Join-Path $SrcDir 'Capture-VMImage.ps1') `
                -ContentRoot $ContentRoot -DiskPath $c.DiskFile -Name $c.Name -Description $c.Description -Compression $c.Compression `
                -Split:$c.Split -NewVersion:$c.NewVersion -SysprepAtDeploy:$c.SysprepAtDeploy -ReuseConvertedDisk $reuse -ProgressFile $progressFile -LogPath $logPath)
            $state.HandedOver = $true
            Show-BuildProgress -Owner $Owner -ProgressFile $progressFile -LogPath $logPath -Process $proc -Title "Capturing $($c.Name)"
            return $true
        }
        $cfg = New-CaptureConfig -ContentRoot $ContentRoot -Name $c.Name -Description $c.Description `
            -Compression $c.Compression -SplitForFat32:$c.Split -Unattended:$c.Unattended -NewVersion:$c.NewVersion
        $buildArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', (ConvertTo-Arg (Join-Path $SrcDir 'New-DeploymentMedia.ps1')),
            '-SettingsPath', (ConvertTo-Arg (Join-Path $ContentRoot 'config\deploy-settings.json')),
            '-CaptureConfig', (ConvertTo-Arg $cfg))
        switch ($c.Mode) {
            'Iso' { $buildArgs += @('-Target', 'Iso', '-OutputPath', (ConvertTo-Arg $c.IsoFolder)) }
            'Usb' { $buildArgs += @('-Target', 'Usb', '-UsbDiskNumber', $c.Usb.Number, '-Force') }
        }
        Start-Process powershell.exe -ArgumentList $buildArgs
        $true
    }

    # The disk check page is only for a VM's disk file; the ISO and USB captures check the disk in WinPE.
    $skipCheck = { $state.Page -eq $checkPage -and (& $getChoice).Mode -ne 'DiskFile' }
    $w.BtnBack.Add_Click({
        try {
            if ($state.Page -gt 0) { $state.Page-- }
            if (& $skipCheck) { $state.Page-- }
            & $showPage
        } catch { Show-WizardError $_.Exception.Message }
    })
    $w.BtnNext.Add_Click({
        try {
            $problem = & $validate
            if ($problem) { Show-WizardError $problem; return }
            if ($state.Page -lt $state.Last) {
                $state.Page++
                if (& $skipCheck) { $state.Page++ }
                & $showPage; return
            }
            if (& $finish) { $wiz.DialogResult = $true; $wiz.Close() }
        } catch { Show-WizardError $_.Exception.Message }
    })
    $w.BtnCancel.Add_Click({ $wiz.Close() })

    & $showPage
    [bool]$wiz.ShowDialog()
}
