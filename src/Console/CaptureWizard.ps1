# Capture wizard window. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg,
# Get-UsbDiskChoices and the ConsoleData and VMwareVM modules.

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

    $state = @{ Page = 0; Last = 3 }
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
            Mode        = if ($w.RbDiskFile.IsChecked) { 'DiskFile' } elseif ($w.RbIso.IsChecked) { 'Iso' } else { 'Usb' }
            DiskFile    = $w.TxtDiskFile.Text.Trim().Trim('"')
            IsoFolder   = $w.TxtIsoFolder.Text.Trim()
            Usb         = $w.CmbUsb.SelectedItem
        }
    }

    # The disk file capture reads the VM's disk with DISM on this PC and saves to the content root: no share, no ADK, no media.
    $onThisPC = @('DiskFile')

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
                if (-not $w.ChkPrepared.IsChecked) { 'Run the prepare command on the reference machine first, then tick the box.' }
                elseif ($c.Mode -eq 'DiskFile' -and (Test-VMwareFolderInUse -Folder (Split-Path -Parent $c.DiskFile))) { 'VMware still has this VM open. Wait until sysprep has shut it down, then click Next.' }
            }
            2 {
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
                "Disk file $current, copied and captured on this PC" +
                $(if ($current -ne $c.DiskFile) { "`r`n               (the newest snapshot of $(Split-Path -Leaf $c.DiskFile))" })
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
            'Clicking Start opens a window that copies the VM''s disk on this PC and captures it. This takes a while and needs free space on this PC for a copy of the whole disk (VHD and VHDX files are read in place). The new image appears on the Images tab when it finishes.'
        } else {
            'Clicking Build and start opens a window that builds the capture media (a few minutes). Boot the reference machine from it to capture. The new image appears on the Images tab when it finishes.'
        }
        $w.TxtIssues.Text = if ($issues) { "Fix before you start:`n" + ($issues -join "`n") } else { '' }
        $w.BtnNext.IsEnabled = -not $issues
    }

    $showPage = {
        for ($i = 0; $i -le $state.Last; $i++) {
            $w["Page$i"].Visibility = if ($i -eq $state.Page) { 'Visible' } else { 'Collapsed' }
            $w["Step$i"].Foreground = if ($i -eq $state.Page) { 'White' } elseif ($i -lt $state.Page) { '#9CA3AF' } else { '#6B7280' }
            $w["Step$i"].FontWeight = if ($i -eq $state.Page) { 'SemiBold' } else { 'Normal' }
        }
        $w.BtnBack.IsEnabled = $state.Page -gt 0
        $w.BtnNext.IsEnabled = $true
        $w.BtnNext.Content = if ($state.Page -ne $state.Last) { 'Next' } elseif ((& $getChoice).Mode -in $onThisPC) { 'Start' } else { 'Build and start' }
        if ($state.Page -eq $state.Last) { & $showSummary }
    }

    $finish = {
        $c = & $getChoice
        if ($c.Mode -eq 'Usb' -and
            [Windows.MessageBox]::Show($wiz, "Everything on $($c.Usb.Label) will be erased. Continue?", 'Capture Wizard', 'YesNo', 'Warning') -ne 'Yes') { return $false }

        if ($c.Mode -eq 'DiskFile') {
            Start-Process powershell.exe -ArgumentList (Get-VMCaptureArguments -ScriptPath (Join-Path $SrcDir 'Capture-VMImage.ps1') `
                -ContentRoot $ContentRoot -DiskPath $c.DiskFile -Name $c.Name -Description $c.Description -Compression $c.Compression `
                -Split:$c.Split -NewVersion:$c.NewVersion)
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

    $w.BtnBack.Add_Click({
        if ($state.Page -gt 0) { $state.Page-- }
        & $showPage
    })
    $w.BtnNext.Add_Click({
        try {
            $problem = & $validate
            if ($problem) { Show-WizardError $problem; return }
            if ($state.Page -lt $state.Last) {
                $state.Page++
                & $showPage; return
            }
            if (& $finish) { $wiz.DialogResult = $true; $wiz.Close() }
        } catch { Show-WizardError $_.Exception.Message }
    })
    $w.BtnCancel.Add_Click({ $wiz.Close() })

    & $showPage
    [bool]$wiz.ShowDialog()
}
