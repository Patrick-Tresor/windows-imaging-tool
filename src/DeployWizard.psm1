# Graphical deploy wizard shown in WinPE before a deployment: answer file, computer name, OU, target disk,
# applications, then a summary to confirm. WinForms, because WinPE-NetFX has no WPF.
# Deploy-Image.ps1 passes in the hardware and two script blocks that read an answer file and prepare its
# plan (map shares, find the image, driver pack and applications), so all deploy logic stays there.

function Test-ComputerNameValue {
    # Returns why a computer name can't be used, or nothing when it is valid.
    param([string]$Name)
    if (-not $Name) { return 'Type a computer name.' }
    if ($Name.Length -gt 15) { return 'A computer name can have at most 15 characters.' }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { return 'Use only letters, digits and dashes.' }
    if ($Name -match '^[0-9]+$') { return 'A computer name cannot be only digits.' }
    if ($Name.StartsWith('-') -or $Name.EndsWith('-')) { return 'A computer name cannot start or end with a dash.' }
}

function Format-DiskChoice {
    # One line per disk in the wizard's disk list.
    param([Parameter(Mandatory)]$Disk)
    '{0}: {1} ({2:N0} GB, {3})' -f $Disk.Number, "$($Disk.FriendlyName)".Trim(), ($Disk.Size / 1GB), $Disk.BusType
}

function Get-TargetDisks {
    # Disks Windows can go on: not the USB stick WinPE booted from, not empty card readers.
    @(Get-Disk | Where-Object { $_.BusType -ne 'USB' -and $_.Size -gt 0 } | Sort-Object Number)
}

function Get-AppChoices {
    # The answer file's applications first, in its order and ticked, then the rest of the library unticked.
    param([string[]]$Selected = @(), [string[]]$Available = @())
    foreach ($name in $Selected) { [pscustomobject]@{ Name = $name; Checked = $true } }
    foreach ($name in $Available | Sort-Object) {
        if ($name -notin $Selected) { [pscustomobject]@{ Name = $name; Checked = $false } }
    }
}

function Get-DeploySummary {
    # The lines shown before the disk is wiped, in the wizard and on the console.
    param(
        [Parameter(Mandatory)]$Answer,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)]$Disk,
        [string[]]$Applications = @()
    )
    $join = if ($Answer.Membership -eq 'Domain') {
        "domain $($Answer.Domain)$(if ($Answer.OrganizationalUnit) { " ($($Answer.OrganizationalUnit))" })"
    } else { "workgroup $($Answer.Workgroup)" }
    "Answer file:  $($Answer.Name)"
    "Image:        $($Plan.ImagePath) (index $($Answer.ImageIndex))"
    "Drivers:      $(if ($Plan.DriverPack) { $Plan.DriverPack } else { 'inbox only' })"
    "Applications: $(if ($Applications) { $Applications -join ', ' } else { 'none' })"
    "Name:         $ComputerName"
    "Joins:        $join"
    # Deploy-Image adds its own lines (Windows 11 check, firmware, BIOS, BitLocker, user data) to the plan.
    if ($Plan.PSObject.Properties['Details']) { @($Plan.Details) }
    "ERASE disk:   $(Format-DiskChoice $Disk)"
}

function Show-DeployWizard {
    <#
    .SYNOPSIS
        Shows the wizard and returns the operator's choices, or $null when they cancel.
    .OUTPUTS
        Answer (with DiskNumber, OrganizationalUnit and Applications set to the choices), Plan, ComputerName.
    #>
    param(
        [Parameter(Mandatory)]$Hardware,
        [Parameter(Mandatory)][string[]]$AnswerFiles,
        [string]$Default,
        [string]$ComputerName,                              # from the command line; replaces the suggested name
        [Parameter(Mandatory)][scriptblock]$ReadAnswer,     # { param($Name) } -> answer object, throws when invalid
        [Parameter(Mandatory)][scriptblock]$PreparePlan,    # { param($Answer) } -> ImagePath, DriverPack, AvailableApps, DefaultName
        [object[]]$Disks = (Get-TargetDisks)
    )
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    # Event handlers run outside this function's scope, so everything they share lives here.
    $script:wiz = @{
        Page = 0; Answer = $null; Plan = $null; Disks = $Disks; Result = $null
        ReadAnswer = $ReadAnswer; PreparePlan = $PreparePlan; ComputerName = $ComputerName
    }
    $w = $script:wiz
    $font = New-Object Drawing.Font('Segoe UI', 10)

    $form = New-Object Windows.Forms.Form -Property @{
        Text = 'Deploy Windows'; ClientSize = New-Object Drawing.Size(720, 500); Font = $font
        StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        TopMost = $true; BackColor = [Drawing.Color]::White
    }
    $title = New-Object Windows.Forms.Label -Property @{
        Location = (New-Object Drawing.Point(24, 16)); Size = (New-Object Drawing.Size(672, 32)); Font = New-Object Drawing.Font('Segoe UI', 15)
    }
    $hwText = "$($Hardware.Maker) $($Hardware.Model)   Serial $($Hardware.Serial)$(if ($Hardware.Sku) { "   SKU $($Hardware.Sku)" })"
    $hwLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(24, 50)); Size = (New-Object Drawing.Size(672, 22)); Text = $hwText; ForeColor = [Drawing.Color]::DimGray }
    $err = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(24, 410)); Size = (New-Object Drawing.Size(672, 40)); ForeColor = [Drawing.Color]::Firebrick }
    $back   = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(384, 456)); Size = (New-Object Drawing.Size(100, 32)); Text = '< Back' }
    $next   = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(490, 456)); Size = (New-Object Drawing.Size(100, 32)); Text = 'Next >' }
    $cancel = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(596, 456)); Size = (New-Object Drawing.Size(100, 32)); Text = 'Cancel'; DialogResult = 'Cancel' }
    $form.CancelButton = $cancel
    $form.Controls.AddRange(@($title, $hwLabel, $err, $back, $next, $cancel))

    $pages = foreach ($i in 0..3) {
        $p = New-Object Windows.Forms.Panel -Property @{ Location = (New-Object Drawing.Point(24, 84)); Size = (New-Object Drawing.Size(672, 320)); Visible = $false }
        $form.Controls.Add($p); $p
    }

    # Page 0: answer file.
    $pages[0].Controls.Add((New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Answer file' }))
    $w.List = New-Object Windows.Forms.ListBox -Property @{ Location = (New-Object Drawing.Point(0, 24)); Size = (New-Object Drawing.Size(300, 290)); IntegralHeight = $false }
    $w.List.Items.AddRange([object[]]$AnswerFiles)
    $w.About = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(316, 24)); Size = (New-Object Drawing.Size(356, 290)) }
    $pages[0].Controls.AddRange(@($w.List, $w.About))

    # Page 1: computer name, OU, disk.
    $w.NameBox = New-Object Windows.Forms.TextBox -Property @{ Location = (New-Object Drawing.Point(0, 24)); Size = (New-Object Drawing.Size(300, 26)); MaxLength = 15; CharacterCasing = 'Upper' }
    $w.NameHint = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(316, 26)); Size = (New-Object Drawing.Size(356, 40)); ForeColor = [Drawing.Color]::DimGray }
    $w.JoinLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 70)); Size = (New-Object Drawing.Size(672, 22)) }
    $w.OuLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 100)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Organizational unit (empty for the default Computers container)' }
    $w.OuBox = New-Object Windows.Forms.TextBox -Property @{ Location = (New-Object Drawing.Point(0, 124)); Size = (New-Object Drawing.Size(672, 26)) }
    $w.DiskBox = New-Object Windows.Forms.ComboBox -Property @{ Location = (New-Object Drawing.Point(0, 194)); Size = (New-Object Drawing.Size(672, 26)); DropDownStyle = 'DropDownList' }
    foreach ($d in $Disks) { [void]$w.DiskBox.Items.Add((Format-DiskChoice $d)) }
    $pages[1].Controls.AddRange(@(
        (New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(300, 22)); Text = 'Computer name' }),
        $w.NameBox, $w.NameHint, $w.JoinLabel, $w.OuLabel, $w.OuBox,
        (New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 170)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Disk to erase and install Windows on' }),
        $w.DiskBox))

    # Page 2: applications.
    $w.Apps = New-Object Windows.Forms.CheckedListBox -Property @{ Location = (New-Object Drawing.Point(0, 24)); Size = (New-Object Drawing.Size(672, 290)); CheckOnClick = $true; IntegralHeight = $false }
    $pages[2].Controls.AddRange(@(
        (New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Applications installed at first boot (ticked ones, top to bottom)' }),
        $w.Apps))

    # Page 3: summary and confirmation.
    $w.Summary = New-Object Windows.Forms.TextBox -Property @{
        Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(672, 260)); Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'
        Font = New-Object Drawing.Font([Drawing.FontFamily]::GenericMonospace, 10); BackColor = [Drawing.Color]::WhiteSmoke
    }
    $w.Confirm = New-Object Windows.Forms.CheckBox -Property @{ Location = (New-Object Drawing.Point(0, 276)); Size = (New-Object Drawing.Size(672, 26)); ForeColor = [Drawing.Color]::Firebrick }
    $pages[3].Controls.AddRange(@($w.Summary, $w.Confirm))

    $w.Pages = $pages; $w.Title = $title; $w.Error = $err; $w.Back = $back; $w.Next = $next; $w.Form = $form

    $w.Show = {
        $w = $script:wiz
        for ($i = 0; $i -lt $w.Pages.Count; $i++) { $w.Pages[$i].Visible = $i -eq $w.Page }
        $w.Title.Text = @('Choose an answer file', 'Name this computer', 'Choose applications', 'Ready to deploy')[$w.Page]
        $w.Back.Enabled = $w.Page -gt 0
        $w.Next.Text = if ($w.Page -eq 3) { 'Deploy' } else { 'Next >' }
        $w.Next.Enabled = if ($w.Page -eq 3) { $w.Confirm.Checked } else { $true }
        $w.Error.Text = ''
    }

    $w.List.add_SelectedIndexChanged({
        $w = $script:wiz
        $w.Answer = $null; $w.Plan = $null
        try {
            $a = & $w.ReadAnswer $w.List.SelectedItem
            $w.Answer = $a
            $w.About.ForeColor = [Drawing.Color]::Black
            $w.About.Text = (@(
                "Image: $($a.ImageFile) (index $($a.ImageIndex))",
                "Naming: $($a.NamingMode)$(if ($a.Prefix) { ", prefix $($a.Prefix)" })",
                $(if ($a.Membership -eq 'Domain') { "Joins domain $($a.Domain)" } else { "Workgroup $($a.Workgroup)" }),
                "Applications: $(if ($a.Applications) { $a.Applications.Count } else { 'none' })",
                "Regional: $($a.UILanguage), $($a.TimeZone)",
                "When done: $(if ($a.Shutdown) { 'shut down' } elseif ($a.Reboot) { 'restart' } else { 'stay in WinPE' })"
            ) -join "`n")
        }
        catch {
            $w.About.ForeColor = [Drawing.Color]::Firebrick
            $w.About.Text = $_.Exception.Message
        }
    })

    $w.Confirm.add_CheckedChanged({ $script:wiz.Next.Enabled = $script:wiz.Confirm.Checked })

    $back.add_Click({ $script:wiz.Page--; & $script:wiz.Show })

    $next.add_Click({
        $w = $script:wiz
        $w.Error.Text = ''
        $w.Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        try {
            switch ($w.Page) {
                0 {
                    if (-not $w.Answer) { throw 'Pick an answer file that has no problems.' }
                    # Maps the answer file's shares and checks the image before going further.
                    $w.Plan = & $w.PreparePlan $w.Answer
                    $a = $w.Answer
                    $w.NameBox.Text = if ($w.ComputerName) { $w.ComputerName } else { $w.Plan.DefaultName }
                    $w.NameHint.Text = switch ($a.NamingMode) {
                        'WMI'    { 'Suggested from the hardware. You can change it.' }
                        'Custom' { "Suggested from the scheme $($a.CustomScheme). You can change it." }
                        'Prompt' { 'Type the name for this PC.' }
                    }
                    $isDomain = $a.Membership -eq 'Domain'
                    $w.JoinLabel.Text = if ($isDomain) { "Joins the domain $($a.Domain)" } else { "Joins the workgroup $($a.Workgroup)" }
                    $w.OuLabel.Visible = $isDomain; $w.OuBox.Visible = $isDomain
                    $w.OuBox.Text = "$($a.OrganizationalUnit)"
                    if (-not $w.Disks) { throw 'This PC has no internal disk that Windows can be installed on.' }
                    $w.DiskBox.SelectedIndex = 0
                    for ($i = 0; $i -lt $w.Disks.Count; $i++) { if ($w.Disks[$i].Number -eq $a.DiskNumber) { $w.DiskBox.SelectedIndex = $i } }
                    $w.Apps.Items.Clear()
                    foreach ($c in Get-AppChoices -Selected $a.Applications -Available $w.Plan.AvailableApps) {
                        [void]$w.Apps.Items.Add($c.Name, $c.Checked)
                    }
                }
                1 {
                    $problem = Test-ComputerNameValue $w.NameBox.Text.Trim()
                    if ($problem) { [void]$w.NameBox.Focus(); throw $problem }
                    if ($w.DiskBox.SelectedIndex -lt 0) { throw 'Pick the disk to install Windows on.' }
                }
                2 {
                    $w.Disk = $w.Disks[$w.DiskBox.SelectedIndex]
                    $a = $w.Answer.PSObject.Copy()
                    $a.DiskNumber = $w.Disk.Number
                    $a.OrganizationalUnit = $w.OuBox.Text.Trim()
                    $a.Applications = @($w.Apps.CheckedItems | ForEach-Object { "$_" })
                    $w.Chosen = $a
                    $w.Summary.Lines = [string[]](Get-DeploySummary -Answer $a -Plan $w.Plan -ComputerName $w.NameBox.Text.Trim() -Disk $w.Disk -Applications $a.Applications)
                    $w.Confirm.Checked = $false
                    $w.Confirm.Text = "Erase disk $($w.Disk.Number) and everything on it, then deploy"
                }
                3 {
                    $w.Result = [pscustomobject]@{ Answer = $w.Chosen; Plan = $w.Plan; ComputerName = $w.NameBox.Text.Trim() }
                    $w.Form.DialogResult = 'OK'
                    return
                }
            }
            $w.Page++
            & $w.Show
        }
        catch { $w.Error.Text = $_.Exception.Message }
        finally { $w.Form.Cursor = [Windows.Forms.Cursors]::Default }
    })

    $start = [Array]::IndexOf($AnswerFiles, $Default)
    $w.List.SelectedIndex = if ($start -ge 0) { $start } else { 0 }
    & $w.Show
    $form.Add_Shown({ $script:wiz.Form.Activate() })
    $null = $form.ShowDialog()
    $result = $w.Result
    $form.Dispose()
    $script:wiz = $null
    $result
}

function Test-DeployWizardAvailable {
    # WinForms needs the WinPE-NetFX component. Without it Deploy-Image falls back to console prompts.
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; $true } catch { $false }
}

Export-ModuleMember -Function Test-ComputerNameValue, Format-DiskChoice, Get-TargetDisks, Get-AppChoices, Get-DeploySummary,
    Show-DeployWizard, Test-DeployWizardAvailable
