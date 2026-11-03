# Graphical deploy wizard shown in WinPE before a deployment: answer file, computer name, OU, target disk,
# applications, then a summary to confirm. WinForms, because WinPE-NetFX has no WPF.
# Deploy-Image.ps1 passes in the hardware and two script blocks that read an answer file and prepare its
# plan (map shares, find the image, driver pack and applications), so all deploy logic stays there.

# Steps listed down the left of the wizard and of the progress window (DeployProgress.psm1).
$script:DeploySteps = 'Answer file', 'Computer name', 'Applications', 'Confirm', 'Install Windows', 'Finish'

function Get-DeploySteps { $script:DeploySteps }

function New-DeploySidebar {
    # The dark band down the left of a window: a heading and the steps. Returns the step labels.
    param([Parameter(Mandatory)]$Form, [string]$Heading = 'Deploy Windows')
    $panel = New-Object Windows.Forms.Panel -Property @{ Dock = 'Left'; Width = 200; BackColor = [Drawing.Color]::FromArgb(31, 58, 95) }
    $panel.Controls.Add((New-Object Windows.Forms.Label -Property @{
        Location = (New-Object Drawing.Point(14, 20)); Size = (New-Object Drawing.Size(180, 34)); Text = $Heading
        Font = New-Object Drawing.Font('Segoe UI', 14); ForeColor = [Drawing.Color]::White
    }))
    Set-FittingFont -Label $panel.Controls[0]
    $labels = for ($i = 0; $i -lt $script:DeploySteps.Count; $i++) {
        $l = New-Object Windows.Forms.Label -Property @{
            Location = (New-Object Drawing.Point(14, (84 + 34 * $i))); Size = (New-Object Drawing.Size(180, 30))
            Text = '{0}   {1}' -f ($i + 1), $script:DeploySteps[$i]
        }
        $panel.Controls.Add($l); $l
    }
    $Form.Controls.Add($panel)
    $labels
}

function Set-FittingFont {
    # Shrinks a label's font until its text fits on one line. WinPE has fewer fonts and some PCs scale the
    # screen, so text measured for Segoe UI at 96 dpi was cut off ("Deploy Win", "Computer nam").
    param([Parameter(Mandatory)]$Label, [single]$MinSize = 7)
    $font = $Label.Font
    $room = $Label.Width - $Label.Padding.Horizontal - 2
    while ($font.Size -gt $MinSize -and [Windows.Forms.TextRenderer]::MeasureText($Label.Text, $font).Width -gt $room) {
        $font = New-Object Drawing.Font($font.FontFamily, ($font.Size - 0.5), $font.Style)
    }
    $Label.Font = $font
}

function Get-TextHeight {
    # Pixels the text needs at this width with word wrap, in this font. WinPE has fewer fonts than Windows and
    # its fallback is taller than Segoe UI, so fixed heights clipped the bottom of every line.
    param([string]$Text, [Parameter(Mandatory)]$Font, [Parameter(Mandatory)][int]$Width, [int]$MinLines = 1)
    $flags = [Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::TextBoxControl
    $line = [Windows.Forms.TextRenderer]::MeasureText('Ag', $Font).Height
    $h = if ($Text) { [Windows.Forms.TextRenderer]::MeasureText($Text, $Font, (New-Object Drawing.Size([Math]::Max(1, $Width), [int]::MaxValue)), $flags).Height } else { 0 }
    [Math]::Max($h, $line * $MinLines)
}

function Set-FittedHeight {
    <#
    .SYNOPSIS
        Makes a label or check box tall enough for its text (wrapped to its width), between MinLines and MaxLines.
        Beyond MaxLines the text ends with "..." (AutoEllipsis): details belong in the log, not in a scroll bar.
    #>
    param([Parameter(Mandatory)]$Control, [int]$MinLines = 1, [int]$MaxLines = 0)
    $room = $Control.Width - $Control.Padding.Horizontal - $(if ($Control -is [Windows.Forms.CheckBox]) { 24 } else { 2 })
    $line = [Windows.Forms.TextRenderer]::MeasureText('Ag', $Control.Font).Height
    $h = Get-TextHeight -Text $Control.Text -Font $Control.Font -Width $room -MinLines $MinLines
    if ($MaxLines -gt 0 -and $h -gt $line * $MaxLines) {
        $h = $line * $MaxLines
        if ($Control -is [Windows.Forms.Label]) { $Control.AutoEllipsis = $true }
    }
    $Control.Height = $h + $Control.Padding.Vertical + 4
}

function Set-FittedButton {
    # Widens and heightens a button until its text fits ("Command pro" was cut off in WinPE). Never shrinks it.
    param([Parameter(Mandatory)]$Button, [int]$MinWidth = 100, [int]$MinHeight = 32)
    $size = [Windows.Forms.TextRenderer]::MeasureText($Button.Text, $Button.Font)
    $Button.Width = [Math]::Max($MinWidth, $size.Width + 24)
    $Button.Height = [Math]::Max($MinHeight, $size.Height + 12)
}

function Set-StackLayout {
    <#
    .SYNOPSIS
        Places controls one under the other from Top, each Gap pixels below the previous one, at their current
        heights (Set-FittedHeight them first). Returns the bottom of the last one. Pass only the controls that
        are shown: hidden ones leave no gap.
    #>
    param([Parameter(Mandatory)][object[]]$Controls, [int]$Top = 0, [int]$Gap = 4, [hashtable]$GapAfter = @{})
    $y = $Top
    foreach ($c in $Controls) {
        $c.Top = $y
        $y = $c.Bottom + $(if ($GapAfter.ContainsKey($c)) { $GapAfter[$c] } else { $Gap })
    }
    $y - $Gap
}

function Set-ButtonRow {
    # Fits each button to its text, then lines them up from the right edge leftwards, bottoms at Bottom.
    param([Parameter(Mandatory)][object[]]$Buttons, [Parameter(Mandatory)][int]$Right, [Parameter(Mandatory)][int]$Bottom, [int]$Gap = 6, [switch]$FromLeft)
    foreach ($b in $Buttons) { Set-FittedButton -Button $b }
    $h = ($Buttons | Measure-Object -Property Height -Maximum).Maximum
    if ($FromLeft) {
        $x = $Right
        foreach ($b in $Buttons) { $b.Height = $h; $b.Top = $Bottom - $h; $b.Left = $x; $x = $b.Right + $Gap }
    } else {
        $x = $Right
        foreach ($b in @($Buttons)[($Buttons.Count - 1)..0]) { $b.Height = $h; $b.Top = $Bottom - $h; $b.Left = $x - $b.Width; $x = $b.Left - $Gap }
    }
    $Bottom - $h
}

function Set-DeploySidebarStep {
    # Steps before Current are done, Current is bold and white, the rest are dimmed.
    param([Parameter(Mandatory)][object[]]$Labels, [Parameter(Mandatory)][int]$Current)
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $Labels[$i].Font = New-Object Drawing.Font('Segoe UI', 10, $(if ($i -eq $Current) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
        $Labels[$i].ForeColor = if ($i -eq $Current) { [Drawing.Color]::White }
                                elseif ($i -lt $Current) { [Drawing.Color]::FromArgb(170, 200, 230) }
                                else { [Drawing.Color]::FromArgb(120, 140, 165) }
        Set-FittingFont -Label $Labels[$i]
    }
}

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

# Buses Windows is never installed on: the USB stick WinPE booted from, card readers, mounted VHDs.
$script:RemovableBus = 'USB', 'SD', 'MMC', 'File Backed Virtual'

function Select-TargetDisks {
    # Disks Windows can go on, from Get-Disk output: internal, not empty, and not the disk holding the content (Exclude).
    param([object[]]$Disks = @(), [int[]]$Exclude = @())
    @($Disks | Where-Object { $_ -and "$($_.BusType)" -notin $script:RemovableBus -and $_.Size -gt 0 -and $_.Number -notin $Exclude } | Sort-Object Number)
}

function Get-TargetDisks {
    param([int[]]$Exclude = @())
    Select-TargetDisks -Disks @(Get-Disk) -Exclude $Exclude
}

function Resolve-TargetDisk {
    <#
    .SYNOPSIS
        The disk Windows goes on. The answer file's disk number when that is an internal disk; otherwise the first
        internal disk (NVMe, then SATA, then the rest). USB sticks often take disk 0 in WinPE, so the answer file's
        default of 0 can point at the stick. Disk is $null when there is no internal disk; Reason says why in plain words.
    #>
    param([object[]]$Disks = @(), [int]$Requested = 0, [int[]]$Exclude = @())
    $targets = @(Select-TargetDisks -Disks $Disks -Exclude $Exclude)
    $hit = $targets | Where-Object Number -eq $Requested | Select-Object -First 1
    if ($hit) { return [pscustomobject]@{ Disk = $hit; Reason = "disk $Requested, as the answer file says" } }

    $asked = $Disks | Where-Object { $_ -and $_.Number -eq $Requested } | Select-Object -First 1
    $why = if (-not $asked) { "there is no disk $Requested" }
           elseif ($asked.Number -in $Exclude) { "disk $Requested holds the deployment content ($(Format-DiskChoice $asked))" }
           elseif ("$($asked.BusType)" -in $script:RemovableBus) { "disk $Requested is a $($asked.BusType) disk ($(Format-DiskChoice $asked))" }
           else { "disk $Requested is empty or unreadable" }

    $rank = @{ NVMe = 0; SATA = 1; ATA = 1; RAID = 2; SAS = 3; SCSI = 4 }
    $pick = $targets | Sort-Object @{ Expression = { $b = "$($_.BusType)"; if ($rank.ContainsKey($b)) { $rank[$b] } else { 9 } } }, Number |
        Select-Object -First 1
    if ($pick) { return [pscustomobject]@{ Disk = $pick; Reason = "the answer file says disk $Requested, but $why; using the internal disk $($pick.Number) instead" } }

    $seen = @($Disks | Where-Object { $_ } | Sort-Object Number | ForEach-Object { Format-DiskChoice $_ })
    [pscustomobject]@{
        Disk   = $null
        # Short enough for the wizard's two lines; Reason, for the log, says what WinPE sees and how to fix it.
        Short  = 'No internal disk found, so nothing was erased. WinPE is missing the storage driver; see the log.'
        Reason = ('This PC has no internal disk that WinPE can see, so Windows has nowhere to go. Nothing was erased. ' +
            "WinPE sees: $(if ($seen) { $seen -join '; ' } else { 'no disks at all' }). " +
            'The SSD is usually hidden by Intel RST/VMD (Dell 11th gen and later ship with it on): set SATA/NVMe Operation to AHCI/NVMe in the BIOS, ' +
            'or check the "WinPE drivers in this boot image" line above: it must say Intel RST/VMD storage driver: yes.')
    }
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
        # The account Windows will sign in as (AnswerFile.psm1), so a wrong one shows before the disk is wiped and in Deploy.log.
        $as = if (Get-Command Resolve-JoinAccount -ErrorAction SilentlyContinue) { (Resolve-JoinAccount -Answer $Answer).Account }
        "domain $($Answer.Domain)$(if ($Answer.OrganizationalUnit) { " ($($Answer.OrganizationalUnit))" })$(if ($as) { " as $as" })"
    } else { "workgroup $($Answer.Workgroup)" }
    "Answer file:  $($Answer.Name)"
    "Image:        $($Plan.ImagePath) (index $($Answer.ImageIndex))"
    "Drivers:      $(if ($Plan.DriverPack) { $Plan.DriverPack } else { 'inbox only' })"
    "Applications: $(if ($Applications) { $Applications -join ', ' } else { 'none' })"
    # Tasks from the Tasks tab by name and when they run; plain commands only counted.
    $taskRows = @($Answer.Tasks | Where-Object { $_ })
    if ($taskRows) {
        $named = @($taskRows | Where-Object { $_.PSObject.Properties['Script'] -and $_.Script } | ForEach-Object { "$($_.Script) ($($_.Phase))" })
        $plain = $taskRows.Count - $named.Count
        if ($plain) { $named += "$plain command$(if ($plain -gt 1) { 's' })" }
        "Tasks:        $($named -join ', ')"
    }
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
        [object[]]$Disks = (Get-TargetDisks),
        [string]$Notice                                     # one line shown on the first page, such as why there was no countdown
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
        Text = 'Deploy Windows'; ClientSize = New-Object Drawing.Size(920, 540); Font = $font
        StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        TopMost = $true; BackColor = [Drawing.Color]::White
    }
    $title = New-Object Windows.Forms.Label -Property @{
        Location = (New-Object Drawing.Point(224, 16)); Size = (New-Object Drawing.Size(672, 32)); Font = New-Object Drawing.Font('Segoe UI', 15)
    }
    $hwText = "$($Hardware.Maker) $($Hardware.Model)   Serial $($Hardware.Serial)$(if ($Hardware.Sku) { "   SKU $($Hardware.Sku)" })"
    $hwLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(224, 50)); Size = (New-Object Drawing.Size(672, 22)); Text = $hwText; ForeColor = [Drawing.Color]::DimGray }
    # One or two short lines; the details of a problem go to the deploy log. AutoEllipsis ends anything longer
    # with "..." instead of cutting a line in half or needing a scroll bar.
    $err = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(224, 410)); Size = (New-Object Drawing.Size(672, 42)); ForeColor = [Drawing.Color]::Firebrick; AutoEllipsis = $true }
    $back   = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(584, 456)); Size = (New-Object Drawing.Size(100, 32)); Text = '< Back' }
    $next   = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(690, 456)); Size = (New-Object Drawing.Size(100, 32)); Text = 'Next >' }
    $cancel = New-Object Windows.Forms.Button -Property @{ Location = (New-Object Drawing.Point(796, 456)); Size = (New-Object Drawing.Size(100, 32)); Text = 'Cancel'; DialogResult = 'Cancel' }
    $form.CancelButton = $cancel
    $form.Controls.AddRange(@($title, $hwLabel, $err, $back, $next, $cancel))
    $w.Sidebar = New-DeploySidebar -Form $form

    $pages = foreach ($i in 0..3) {
        $p = New-Object Windows.Forms.Panel -Property @{ Location = (New-Object Drawing.Point(224, 84)); Size = (New-Object Drawing.Size(672, 320)); Visible = $false }
        $form.Controls.Add($p); $p
    }

    # Page 0: answer file.
    $w.ListLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Answer file' }
    $pages[0].Controls.Add($w.ListLabel)
    $w.List = New-Object Windows.Forms.ListBox -Property @{ Location = (New-Object Drawing.Point(0, 24)); Size = (New-Object Drawing.Size(300, 290)); IntegralHeight = $false }
    $w.List.Items.AddRange([object[]]$AnswerFiles)
    $w.About = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(316, 24)); Size = (New-Object Drawing.Size(356, 290)) }
    $pages[0].Controls.AddRange(@($w.List, $w.About))

    # Page 1: computer name, OU, disk.
    $w.NameBox = New-Object Windows.Forms.TextBox -Property @{ Location = (New-Object Drawing.Point(0, 24)); Size = (New-Object Drawing.Size(300, 26)); MaxLength = 15; CharacterCasing = 'Upper' }
    # The hint goes under the box: beside it, a second line had no room and was cut off.
    $w.NameHint = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 54)); Size = (New-Object Drawing.Size(672, 22)); ForeColor = [Drawing.Color]::DimGray }
    $w.JoinLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 70)); Size = (New-Object Drawing.Size(672, 22)) }
    $w.OuLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 100)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Organizational unit (empty for the default Computers container)' }
    $w.OuBox = New-Object Windows.Forms.TextBox -Property @{ Location = (New-Object Drawing.Point(0, 124)); Size = (New-Object Drawing.Size(672, 26)) }
    $w.DiskBox = New-Object Windows.Forms.ComboBox -Property @{ Location = (New-Object Drawing.Point(0, 194)); Size = (New-Object Drawing.Size(672, 26)); DropDownStyle = 'DropDownList' }
    foreach ($d in $Disks) { [void]$w.DiskBox.Items.Add((Format-DiskChoice $d)) }
    $w.NameLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Computer name' }
    $w.DiskLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 170)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Disk to erase and install Windows on' }
    $pages[1].Controls.AddRange(@($w.NameLabel, $w.NameBox, $w.NameHint, $w.JoinLabel, $w.OuLabel, $w.OuBox, $w.DiskLabel, $w.DiskBox))

    # Page 2: applications.
    $w.Apps = New-Object Windows.Forms.CheckedListBox -Property @{ Location = (New-Object Drawing.Point(0, 24)); Size = (New-Object Drawing.Size(672, 290)); CheckOnClick = $true; IntegralHeight = $false }
    $w.AppsLabel = New-Object Windows.Forms.Label -Property @{ Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(672, 22)); Text = 'Applications installed at first boot (ticked ones, top to bottom)' }
    $pages[2].Controls.AddRange(@($w.AppsLabel, $w.Apps))

    # Page 3: summary and confirmation.
    $w.Summary = New-Object Windows.Forms.TextBox -Property @{
        Location = (New-Object Drawing.Point(0, 0)); Size = (New-Object Drawing.Size(672, 260)); Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'
        Font = New-Object Drawing.Font([Drawing.FontFamily]::GenericMonospace, 10); BackColor = [Drawing.Color]::WhiteSmoke
    }
    $w.Confirm = New-Object Windows.Forms.CheckBox -Property @{ Location = (New-Object Drawing.Point(0, 276)); Size = (New-Object Drawing.Size(672, 26)); ForeColor = [Drawing.Color]::Firebrick }
    $pages[3].Controls.AddRange(@($w.Summary, $w.Confirm))

    $w.Pages = $pages; $w.Title = $title; $w.Error = $err; $w.Back = $back; $w.Next = $next; $w.Cancel = $cancel; $w.Form = $form
    $w.HwLabel = $hwLabel; $w.IsDomain = $true
    $w.Layout = { Update-DeployWizardLayout -Wiz $script:wiz }

    $w.Show = {
        $w = $script:wiz
        for ($i = 0; $i -lt $w.Pages.Count; $i++) { $w.Pages[$i].Visible = $i -eq $w.Page }
        $w.Title.Text = @('Choose an answer file', 'Name this computer', 'Choose applications', 'Ready to deploy')[$w.Page]
        Set-DeploySidebarStep -Labels $w.Sidebar -Current $w.Page
        $w.Back.Enabled = $w.Page -gt 0
        $w.Next.Text = if ($w.Page -eq 3) { 'Deploy' } else { 'Next >' }
        $w.Next.Enabled = if ($w.Page -eq 3) { $w.Confirm.Checked } else { $true }
        $w.Error.Text = ''
        & $w.Layout
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
                "Tasks: $(if (@($a.Tasks).Count) { @($a.Tasks).Count } else { 'none' })",
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
                    $w.OuLabel.Visible = $isDomain; $w.OuBox.Visible = $isDomain; $w.IsDomain = $isDomain
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
        catch { $w.Error.Text = $_.Exception.Message; Set-FittedHeight -Control $w.Error -MinLines 2 -MaxLines 2 }
        finally { $w.Form.Cursor = [Windows.Forms.Cursors]::Default }
    })

    $start = [Array]::IndexOf($AnswerFiles, $Default)
    $w.List.SelectedIndex = if ($start -ge 0) { $start } else { 0 }
    & $w.Show
    if ($Notice) { $w.Error.Text = $Notice; Set-FittedHeight -Control $w.Error -MinLines 2 -MaxLines 2 }
    $form.Add_Shown({ $script:wiz.Form.Activate() })
    $null = $form.ShowDialog()
    $result = $w.Result
    $form.Dispose()
    $script:wiz = $null
    $result
}

function Update-DeployWizardLayout {
    <#
    .SYNOPSIS
        Sizes every label, check box and button of the wizard to its text in the font WinPE really has, and
        stacks them so nothing overlaps or is clipped. Run again whenever texts change (each page).
    #>
    param([Parameter(Mandatory)][hashtable]$Wiz)
    $w = $Wiz
    $client = $w.Form.ClientSize
    $left = $w.Title.Left; $width = $client.Width - $left - 24
    foreach ($c in $w.Title, $w.HwLabel, $w.Error) { $c.Left = $left; $c.Width = $width }
    Set-FittedHeight -Control $w.Title -MaxLines 1
    Set-FittedHeight -Control $w.HwLabel -MaxLines 1
    $headerBottom = Set-StackLayout -Controls @($w.Title, $w.HwLabel) -Top 12 -Gap 2

    $buttonsTop = Set-ButtonRow -Buttons @($w.Back, $w.Next, $w.Cancel) -Right ($client.Width - 24) -Bottom ($client.Height - 12)
    Set-FittedHeight -Control $w.Error -MinLines 2 -MaxLines 2
    $w.Error.Top = $buttonsTop - 6 - $w.Error.Height

    $pageTop = $headerBottom + 10
    $pageHeight = [Math]::Max(120, $w.Error.Top - 6 - $pageTop)
    foreach ($p in $w.Pages) { $p.SetBounds($left, $pageTop, $width, $pageHeight) }

    # Page 0: label, then the list and what the answer file does side by side.
    $w.ListLabel.Width = $width; Set-FittedHeight -Control $w.ListLabel -MaxLines 1
    $top = $w.ListLabel.Bottom + 2
    $w.List.SetBounds(0, $top, [int]($width * 0.45), $pageHeight - $top)
    $w.About.SetBounds($w.List.Right + 16, $top, $width - $w.List.Right - 16, $pageHeight - $top)

    # Page 1: one field under the other; the OU only for a domain join.
    foreach ($c in $w.NameLabel, $w.NameHint, $w.JoinLabel, $w.OuLabel, $w.DiskLabel) { $c.Width = $width; Set-FittedHeight -Control $c -MaxLines 2 }
    $w.OuBox.Width = $width; $w.DiskBox.Width = $width
    $rows = @($w.NameLabel, $w.NameBox, $w.NameHint, $w.JoinLabel)
    if ($w.IsDomain) { $rows += $w.OuLabel, $w.OuBox }
    $rows += $w.DiskLabel, $w.DiskBox
    $gaps = @{}; foreach ($c in $w.NameHint, $w.JoinLabel, $w.OuBox) { $gaps[$c] = 12 }
    [void](Set-StackLayout -Controls $rows -Top 0 -Gap 2 -GapAfter $gaps)

    # Page 2: label, then the list.
    $w.AppsLabel.Width = $width; Set-FittedHeight -Control $w.AppsLabel -MaxLines 2
    $w.Apps.SetBounds(0, $w.AppsLabel.Bottom + 2, $width, $pageHeight - $w.AppsLabel.Bottom - 2)

    # Page 3: summary above the confirmation box.
    $w.Confirm.Width = $width; Set-FittedHeight -Control $w.Confirm -MaxLines 2
    $w.Confirm.Top = $pageHeight - $w.Confirm.Height
    $w.Summary.SetBounds(0, 0, $width, $w.Confirm.Top - 8)
}

function Test-DeployWizardAvailable {
    # WinForms needs the WinPE-NetFX component. Without it Deploy-Image falls back to console prompts.
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; $true } catch { $false }
}

Export-ModuleMember -Function Get-DeploySteps, New-DeploySidebar, Set-FittingFont, Get-TextHeight, Set-FittedHeight, Set-FittedButton, Set-StackLayout, Set-ButtonRow, Update-DeployWizardLayout, Set-DeploySidebarStep, Test-ComputerNameValue, Format-DiskChoice, Select-TargetDisks, Get-TargetDisks, Resolve-TargetDisk, Get-AppChoices, Get-DeploySummary,
    Show-DeployWizard, Test-DeployWizardAvailable
