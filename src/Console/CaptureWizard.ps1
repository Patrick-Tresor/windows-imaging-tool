# Capture wizard window. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg,
# Get-UsbDiskChoices and the ConsoleData module.

function Show-CaptureWizard {
    param(
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir
    )

    [xml]$wxaml = Get-Content -Raw (Join-Path $PSScriptRoot 'CaptureWizard.xaml')
    $wiz = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($wxaml))
    $wiz.Owner = $Owner
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

    # Page 1: the command to run on the reference machine, from the share when there is one.
    Update-ContentTools -ContentRoot $ContentRoot
    $toolsPath = if ($settings.share.path) { Join-Path $settings.share.path 'Tools\Prepare-Reference.ps1' } else { Join-Path $ContentRoot 'Tools\Prepare-Reference.ps1' }
    $w.TxtPrepCmd.Text = "powershell -ExecutionPolicy Bypass -File `"$toolsPath`""
    $w.BtnCopyCmd.Add_Click({ [Windows.Clipboard]::SetText($w.TxtPrepCmd.Text) })

    # Page 2 defaults.
    $w.TxtName.Text = 'Win11-{0:yyyyMMdd}' -f (Get-Date)

    # Page 3: reference machine choices.
    $loadVMs = {
        $vms = @(Get-ReferenceVMs)
        $w.CmbVM.ItemsSource = $vms
        if ($vms) {
            $w.CmbVM.SelectedItem = $vms | Where-Object Usable | Select-Object -First 1
            $w.RbVmDisk.IsEnabled = $true
            $w.RbVM.IsEnabled = $true
        } else {
            $w.RbVmDisk.IsEnabled = $false
            $w.RbVM.IsEnabled = $false
            $w.RbVmDisk.Content = 'A Hyper-V VM on this PC, captured with the VM off (Hyper-V is not available here)'
            $w.RbVM.Content = 'A Hyper-V VM on this PC, booted from a capture ISO (Hyper-V is not available here)'
        }
    }
    $loadUsb = {
        $disks = @(Get-UsbDiskChoices)
        $w.CmbUsb.ItemsSource = $disks
        if ($disks) { $w.CmbUsb.SelectedIndex = 0 }
    }
    & $loadVMs; & $loadUsb
    if ($w.RbVmDisk.IsEnabled) { $w.RbVmDisk.IsChecked = $true } else { $w.RbIso.IsChecked = $true }
    $w.BtnVMRefresh.Add_Click($loadVMs)
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
            Mode        = if ($w.RbVmDisk.IsChecked) { 'VmDisk' } elseif ($w.RbVM.IsChecked) { 'VM' } elseif ($w.RbIso.IsChecked) { 'Iso' } else { 'Usb' }
            VM          = $w.CmbVM.SelectedItem
            IsoFolder   = $w.TxtIsoFolder.Text.Trim()
            Usb         = $w.CmbUsb.SelectedItem
        }
    }

    # Returns an error message for the current page, or nothing when the user may move on.
    $validate = {
        $c = & $getChoice
        switch ($state.Page) {
            0 { if (-not $w.ChkPrepared.IsChecked) { 'Run the prepare command on the reference machine first, then tick the box.' } }
            1 {
                if (-not (Test-ImageName $c.Name)) { 'The name may only contain letters, digits, dot, dash and underscore.' }
                elseif (-not $c.NewVersion -and @(Get-ImageList -ContentRoot $ContentRoot | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $c.Name }).Count) {
                    "An image named $($c.Name) already exists. Pick another name, or tick the box to capture it as a new version."
                }
            }
            2 {
                if ($c.Mode -in @('VM', 'VmDisk') -and -not $c.VM) { 'Choose a VM.' }
                elseif ($c.Mode -in @('VM', 'VmDisk') -and -not $c.VM.Usable) { "$($c.VM.Name) is a generation 1 VM. Only generation 2 (UEFI) VMs can be captured." }
                elseif ($c.Mode -in @('VM', 'VmDisk') -and $c.VM.State -ne 'Off') { "$($c.VM.Name) is $($c.VM.State). Shut it down, then click Refresh." }
                elseif ($c.Mode -eq 'VM' -and -not $c.Unattended) { 'The Hyper-V option needs "Start without asking and shut down when done" on the previous page.' }
                elseif ($c.Mode -eq 'Iso' -and -not (Test-Path $c.IsoFolder)) { 'Choose a folder for the ISO.' }
                elseif ($c.Mode -eq 'Usb' -and -not $c.Usb) { 'No USB stick found. Plug one in and click Refresh.' }
            }
        }
    }

    $showSummary = {
        $c = & $getChoice
        $target = switch ($c.Mode) {
            'VmDisk' { "Hyper-V VM $($c.VM.Name): run Prepare-Reference.ps1 if needed, then capture its disk with the VM off" }
            'VM'  { "Hyper-V VM $($c.VM.Name): build capture ISO, boot the VM from it, eject when done" }
            'Iso' { "Capture ISO in $($c.IsoFolder)\Capture-WinPE.iso" }
            'Usb' { "USB stick $($c.Usb.Label) (will be ERASED)" }
        }
        $saveTo = switch ($c.Mode) {
            'Usb'    { 'The USB stick''s DEPLOY partition' }
            'VmDisk' { "$ContentRoot\Images" }
            default  { "$($settings.share.path)\Images" }
        }
        $w.TxtSummary.Text = @(
            "Image name:    $($c.Name).$(if ($c.Split) { 'swm (split)' } else { 'wim' })"
            "Description:   $(if ($c.Description) { $c.Description } else { '(none)' })"
            "Compression:   $($c.Compression)"
            "Unattended:    $(if ($c.Unattended) { 'yes, shuts down when done' } else { 'no, asks for YES on the machine' })"
            $(if ($c.NewVersion -and @(Get-ImageList -ContentRoot $ContentRoot | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $c.Name }).Count) {
                "Existing image: replaced after the capture succeeds; the old one is kept in Images\Previous" })
            ''
            "Media:         $target"
            "Saved to:      $saveTo"
        ) -join "`r`n"
        $issues = @(Get-CaptureReadiness -ContentRoot $ContentRoot -Destination $(if ($c.Mode -eq 'Usb') { 'Usb' } else { 'Network' }))
        # Capture media is built with the ADK on this PC, so check it before Build and start.
        $issues += @((Get-AdkStatus).Problems)
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
        $w.BtnNext.Content = if ($state.Page -eq $state.Last) { 'Build and start' } else { 'Next' }
        if ($state.Page -eq $state.Last) { & $showSummary }
    }

    $finish = {
        $c = & $getChoice
        if ($c.Mode -eq 'Usb' -and
            [Windows.MessageBox]::Show($wiz, "Everything on $($c.Usb.Label) will be erased. Continue?", 'Capture Wizard', 'YesNo', 'Warning') -ne 'Yes') { return $false }

        if ($c.Mode -eq 'VmDisk') {
            # Reads the VM's disk on this PC; no capture media is built and the VM is not started.
            Start-Process powershell.exe -ArgumentList (Get-VMCaptureArguments -ScriptPath (Join-Path $SrcDir 'Capture-VMImage.ps1') `
                -ContentRoot $ContentRoot -VMName $c.VM.Name -Name $c.Name -Description $c.Description -Compression $c.Compression `
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
            'VM'  {
                # Hyper-V cannot mount an ISO from a network share without delegation, so keep it local.
                $isoDir = Join-Path $env:ProgramData 'ImagingConsole'
                New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
                $buildArgs += @('-Target', 'Iso', '-OutputPath', (ConvertTo-Arg $isoDir), '-BootVM', (ConvertTo-Arg $c.VM.Name))
            }
            'Iso' { $buildArgs += @('-Target', 'Iso', '-OutputPath', (ConvertTo-Arg $c.IsoFolder)) }
            'Usb' { $buildArgs += @('-Target', 'Usb', '-UsbDiskNumber', $c.Usb.Number, '-Force') }
        }
        Start-Process powershell.exe -ArgumentList $buildArgs
        $true
    }

    $w.BtnBack.Add_Click({ if ($state.Page -gt 0) { $state.Page--; & $showPage } })
    $w.BtnNext.Add_Click({
        try {
            $problem = & $validate
            if ($problem) { Show-WizardError $problem; return }
            if ($state.Page -lt $state.Last) { $state.Page++; & $showPage; return }
            if (& $finish) { $wiz.DialogResult = $true; $wiz.Close() }
        } catch { Show-WizardError $_.Exception.Message }
    })
    $w.BtnCancel.Add_Click({ $wiz.Close() })

    & $showPage
    [bool]$wiz.ShowDialog()
}
