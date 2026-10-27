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

    # Page 2 (manual sysprep, not shown for the hands-free captures): the command to run on the reference
    # machine, from the share when there is one. Page 1 shows the VMware capture agent's install command the same way.
    Update-ContentTools -ContentRoot $ContentRoot
    $toolsDir = if ($settings.share.path) { Join-Path $settings.share.path 'Tools' } else { Join-Path $ContentRoot 'Tools' }
    $w.TxtPrepCmd.Text = "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $toolsDir 'Prepare-Reference.ps1')`""
    $w.TxtAgentCmd.Text = "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $toolsDir 'VMwareCaptureAgent.ps1')`" -Install"
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
    $w.BtnCopyAgentCmd.Add_Click({ & $copyCommand $w.TxtAgentCmd })

    # Page 3 defaults.
    $w.TxtName.Text = 'Win11-{0:yyyyMMdd}' -f (Get-Date)

    # Page 1: reference machine choices. The hands-free Hyper-V capture is the default when Hyper-V is here.
    $vmLabels = @{ VmDisk = $w.RbVmDisk.Content; VM = $w.RbVM.Content }
    $loadVMs = {
        $vms = @()
        $why = $null
        if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
            $why = 'Hyper-V or its PowerShell module is not installed on this PC'
        } else {
            try { $vms = @(Get-ReferenceVMs) } catch { $why = "Hyper-V did not answer: $($_.Exception.Message)" }
            if (-not $why -and -not $vms) { $why = 'no VMs found; create one, then click Refresh' }
        }
        $w.CmbVM.ItemsSource = $vms
        $w.TxtVMStatus.Text = if ($why) { "Not available: $why." } else { '' }
        $w.TxtVMStatus.Visibility = if ($why) { 'Visible' } else { 'Collapsed' }
        $w.RbVmDisk.IsEnabled = [bool]$vms
        $w.RbVM.IsEnabled = [bool]$vms
        $w.RbVmDisk.Content = $vmLabels.VmDisk
        $w.RbVM.Content = $vmLabels.VM
        if ($vms) {
            $w.CmbVM.SelectedItem = $vms | Where-Object Usable | Select-Object -First 1
        } elseif ($w.RbVmDisk.IsChecked -or $w.RbVM.IsChecked) {
            $w.RbIso.IsChecked = $true
        }
    }
    $loadUsb = {
        $disks = @(Get-UsbDiskChoices)
        $w.CmbUsb.ItemsSource = $disks
        if ($disks) { $w.CmbUsb.SelectedIndex = 0 }
    }
    # VMware Workstation VMs: the ones in its library, or any .vmx the user browses to.
    $loadVmware = {
        $missing = @(
            if (-not (Find-Vmrun)) { 'VMware Workstation Pro (vmrun.exe) is not installed on this PC' }
            if (-not (Find-QemuImg)) { 'qemu-img.exe is missing: install QEMU for Windows and add its folder to PATH' }
        )
        $w.TxtVmwareStatus.Text = if ($missing) { "Not available: $($missing -join '; ')." } else { '' }
        $w.TxtVmwareStatus.Visibility = if ($missing) { 'Visible' } else { 'Collapsed' }
        $w.RbVmware.IsEnabled = -not $missing
        $vmx = @(try { Get-VMwareInventory } catch { })
        $w.CmbVmx.ItemsSource = $vmx
        if ($vmx -and -not $w.CmbVmx.Text) { $w.CmbVmx.Text = $vmx[0] }
        if ($missing -and $w.RbVmware.IsChecked) { $w.RbIso.IsChecked = $true }
    }
    $w.BtnVmxBrowse.Add_Click({
        $dlg = [Windows.Forms.OpenFileDialog]::new()
        $dlg.Filter = 'VMware VM (*.vmx)|*.vmx'
        if ($dlg.ShowDialog() -eq 'OK') { $w.CmbVmx.Text = $dlg.FileName }
    })

    & $loadVMs; & $loadUsb; & $loadVmware
    if ($w.RbVmDisk.IsEnabled) { $w.RbVmDisk.IsChecked = $true }
    elseif ($w.RbVmware.IsEnabled) { $w.RbVmware.IsChecked = $true }
    else { $w.RbIso.IsChecked = $true }
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
            Mode        = if ($w.RbVmDisk.IsChecked) { 'VmDisk' } elseif ($w.RbVmware.IsChecked) { 'Vmware' } elseif ($w.RbVM.IsChecked) { 'VM' } elseif ($w.RbIso.IsChecked) { 'Iso' } else { 'Usb' }
            VM          = $w.CmbVM.SelectedItem
            Vmx         = $w.CmbVmx.Text.Trim().Trim('"')
            IsoFolder   = $w.TxtIsoFolder.Text.Trim()
            Usb         = $w.CmbUsb.SelectedItem
        }
    }

    # The hands-free Hyper-V and VMware captures run sysprep themselves, so they skip the manual sysprep page.
    $skipsPrep = { $w.RbVmDisk.IsChecked -eq $true -or $w.RbVmware.IsChecked -eq $true }
    $handsFree = @('VmDisk', 'Vmware')

    # Offers to shut down a running VMware VM; vmrun asks Windows in it to shut down (needs VMware Tools).
    $offerVmwareShutdown = {
        param([string]$Vmx)
        $vmrun = Find-Vmrun
        $running = ConvertFrom-VmrunList @(& $vmrun @(New-VmrunArguments -Command list) 2>$null)
        if (-not (Test-VmxInList -VmxPath $Vmx -RunningPaths $running)) { return $true }
        $answer = [Windows.MessageBox]::Show($wiz,
            "$([IO.Path]::GetFileNameWithoutExtension($Vmx)) is running. Shut down Windows in the VM now? Unsaved work in the VM is lost.",
            'Capture Wizard', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return $false }
        $wiz.Cursor = [Windows.Input.Cursors]::Wait
        try { & $vmrun @(New-VmrunArguments -Command stop -VmxPath $Vmx -Arguments 'soft') 2>&1 | Out-Null }
        finally { $wiz.Cursor = $null }
        $running = ConvertFrom-VmrunList @(& $vmrun @(New-VmrunArguments -Command list) 2>$null)
        -not (Test-VmxInList -VmxPath $Vmx -RunningPaths $running)
    }

    # Offers to shut down a running VM for the hands-free capture. True when the VM is off afterwards.
    $offerShutdown = {
        param($vm)
        if ($vm.State -ne 'Running') { return $false }
        $answer = [Windows.MessageBox]::Show($wiz,
            "$($vm.Name) is running. Shut down Windows in the VM now? Unsaved work in the VM is lost.",
            'Capture Wizard', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return $false }
        $wiz.Cursor = [Windows.Input.Cursors]::Wait
        try { Stop-VM -Name $vm.Name -Force -ErrorAction Stop }
        finally { $wiz.Cursor = $null }
        & $loadVMs
        $w.CmbVM.SelectedItem = @($w.CmbVM.ItemsSource | Where-Object Name -eq $vm.Name)[0]
        $w.CmbVM.SelectedItem.State -eq 'Off'
    }

    # Returns an error message for the current page, or nothing when the user may move on.
    $validate = {
        $c = & $getChoice
        switch ($state.Page) {
            0 {
                if ($c.Mode -in @('VM', 'VmDisk') -and -not $c.VM) { 'Choose a VM.' }
                elseif ($c.Mode -in @('VM', 'VmDisk') -and -not $c.VM.Usable) { "$($c.VM.Name) is a generation $($c.VM.Generation) VM. Only generation 1 and 2 VMs can be captured." }
                elseif ($c.Mode -eq 'VmDisk' -and $c.VM.Generation -ne 2) { "$($c.VM.Name) is a generation $($c.VM.Generation) VM. The hands-free capture needs generation 2 (UEFI); boot it from a capture ISO instead." }
                elseif ($c.Mode -eq 'VmDisk' -and $c.VM.State -ne 'Off' -and -not (& $offerShutdown $c.VM)) { "$($c.VM.Name) is $($c.VM.State). Shut it down, then click Refresh." }
                elseif ($c.Mode -eq 'Vmware' -and ($c.Vmx -notmatch '\.vmx$' -or -not (Test-Path -LiteralPath $c.Vmx -PathType Leaf))) { 'Choose the VM''s .vmx file.' }
                elseif ($c.Mode -eq 'Vmware' -and -not (& $offerVmwareShutdown $c.Vmx)) { "$([IO.Path]::GetFileNameWithoutExtension($c.Vmx)) is still running. Shut it down first." }
                elseif ($c.Mode -eq 'Iso' -and -not (Test-Path $c.IsoFolder)) { 'Choose a folder for the ISO.' }
                elseif ($c.Mode -eq 'Usb' -and -not $c.Usb) { 'No USB stick found. Plug one in and click Refresh.' }
            }
            1 {
                if (-not $w.ChkPrepared.IsChecked) { 'Run the prepare command on the reference machine first, then tick the box.' }
                elseif ($c.Mode -eq 'VM' -and @(Get-ReferenceVMs | Where-Object { $_.Name -eq $c.VM.Name -and $_.State -ne 'Off' }).Count) { "$($c.VM.Name) is still running. Let sysprep shut it down first." }
            }
            2 {
                if (-not (Test-ImageName $c.Name)) { 'The name may only contain letters, digits, dot, dash and underscore.' }
                elseif (-not $c.NewVersion -and @(Get-ImageList -ContentRoot $ContentRoot | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $c.Name }).Count) {
                    "An image named $($c.Name) already exists. Pick another name, or tick the box to capture it as a new version."
                }
                elseif ($c.Mode -eq 'VM' -and -not $c.Unattended) { 'Booting a Hyper-V VM from a capture ISO needs "Start without asking and shut down when done".' }
            }
        }
    }

    $showSummary = {
        $c = & $getChoice
        $target = switch ($c.Mode) {
            'VmDisk' { "Hyper-V VM $($c.VM.Name), hands-free: sysprep at boot if needed, capture its disk with the VM off, then roll back to a checkpoint" }
            'Vmware' { "VMware VM $($c.Vmx), hands-free: snapshot, the capture agent runs sysprep, capture its disk with the VM off, then revert to the snapshot" }
            'VM'  { "Hyper-V VM $($c.VM.Name): build capture ISO, boot the VM from it, eject when done" }
            'Iso' { "Capture ISO in $($c.IsoFolder)\Capture-WinPE.iso" }
            'Usb' { "USB stick $($c.Usb.Label) (will be ERASED)" }
        }
        $saveTo = switch ($c.Mode) {
            'Usb'    { 'The USB stick''s DEPLOY partition' }
            { $_ -in $handsFree } { "$ContentRoot\Images" }
            default  { "$($settings.share.path)\Images" }
        }
        $w.TxtSummary.Text = @(
            "Image name:    $($c.Name).$(if ($c.Split) { 'swm (split)' } else { 'wim' })"
            "Description:   $(if ($c.Description) { $c.Description } else { '(none)' })"
            "Compression:   $($c.Compression)"
            $(if ($c.Mode -notin $handsFree) { "Unattended:    $(if ($c.Unattended) { 'yes, shuts down when done' } else { 'no, asks for YES on the machine' })" })
            $(if ($c.NewVersion -and @(Get-ImageList -ContentRoot $ContentRoot | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $c.Name }).Count) {
                "Existing image: replaced after the capture succeeds; the old one is kept in Images\Previous" })
            ''
            "Media:         $target"
            "Saved to:      $saveTo"
        ) -join "`r`n"
        # The hands-free capture runs DISM on this PC and saves to the content root: no share, no ADK, no media.
        $issues = @()
        if ($c.Mode -notin $handsFree) {
            $issues += @(Get-CaptureReadiness -ContentRoot $ContentRoot -Destination $(if ($c.Mode -eq 'Usb') { 'Usb' } else { 'Network' }))
            # Capture media is built with the ADK on this PC, so check it before Build and start.
            $issues += @((Get-AdkStatus).Problems)
        }
        $w.TxtSummaryIntro.Text = if ($c.Mode -eq 'VmDisk') {
            'Clicking Start opens a window that runs the capture on this PC. It starts the VM only if sysprep has not run yet, and takes a while. The new image appears on the Images tab when it finishes.'
        } elseif ($c.Mode -eq 'Vmware') {
            'Clicking Start opens a window that runs the capture on this PC: it starts the VM, waits for sysprep to shut it down, copies the disk and captures it. This takes a while and needs free space on this PC for a copy of the whole VM disk. The new image appears on the Images tab when it finishes.'
        } else {
            'Clicking Build and start opens a window that builds the capture media (a few minutes) and, for a Hyper-V VM, starts the capture. The new image appears on the Images tab when it finishes.'
        }
        $w.TxtIssues.Text = if ($issues) { "Fix before you start:`n" + ($issues -join "`n") } else { '' }
        $w.BtnNext.IsEnabled = -not $issues
    }

    $showPage = {
        $skip = & $skipsPrep
        $w.Step1.Visibility = if ($skip) { 'Collapsed' } else { 'Visible' }
        $w.Step2.Text = '{0}. Image details' -f $(if ($skip) { 2 } else { 3 })
        $w.Step3.Text = '{0}. Summary' -f $(if ($skip) { 3 } else { 4 })
        for ($i = 0; $i -le $state.Last; $i++) {
            $w["Page$i"].Visibility = if ($i -eq $state.Page) { 'Visible' } else { 'Collapsed' }
            $w["Step$i"].Foreground = if ($i -eq $state.Page) { 'White' } elseif ($i -lt $state.Page) { '#9CA3AF' } else { '#6B7280' }
            $w["Step$i"].FontWeight = if ($i -eq $state.Page) { 'SemiBold' } else { 'Normal' }
        }
        $w.BtnBack.IsEnabled = $state.Page -gt 0
        $w.BtnNext.IsEnabled = $true
        $w.BtnNext.Content = if ($state.Page -ne $state.Last) { 'Next' } elseif ($skip) { 'Start' } else { 'Build and start' }
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
        if ($c.Mode -eq 'Vmware') {
            Start-Process powershell.exe -ArgumentList (Get-VMCaptureArguments -ScriptPath (Join-Path $SrcDir 'Capture-VMImage.ps1') `
                -ContentRoot $ContentRoot -VmxPath $c.Vmx -Name $c.Name -Description $c.Description -Compression $c.Compression `
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

    # Renumber the step list when the choice adds or drops the manual sysprep page.
    $w.RbVmDisk.Add_Checked({ & $showPage })
    $w.RbVmDisk.Add_Unchecked({ & $showPage })
    $w.RbVmware.Add_Checked({ & $showPage })
    $w.RbVmware.Add_Unchecked({ & $showPage })
    $w.BtnBack.Add_Click({
        if ($state.Page -gt 0) { $state.Page-- }
        if ($state.Page -eq 1 -and (& $skipsPrep)) { $state.Page = 0 }
        & $showPage
    })
    $w.BtnNext.Add_Click({
        try {
            $problem = & $validate
            if ($problem) { Show-WizardError $problem; return }
            if ($state.Page -lt $state.Last) {
                $state.Page++
                if ($state.Page -eq 1 -and (& $skipsPrep)) { $state.Page = 2 }
                & $showPage; return
            }
            if (& $finish) { $wiz.DialogResult = $true; $wiz.Close() }
        } catch { Show-WizardError $_.Exception.Message }
    })
    $w.BtnCancel.Add_Click({ $wiz.Close() })

    & $showPage
    [bool]$wiz.ShowDialog()
}
