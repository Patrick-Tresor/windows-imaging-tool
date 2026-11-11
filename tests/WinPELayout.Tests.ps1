# Tests that the WinPE windows (deploy wizard, progress window) fit their text: WinPE's fonts are taller than
# Segoe UI on a desktop, and fixed heights cut off the bottom of lines, the name hint and "Command prompt".
# Every window is laid out with fonts 40 % bigger than designed, then each label, check box and button must be
# tall and wide enough for its text, inside the window and not overlapping its neighbours.
# Run: powershell -File tests/WinPELayout.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployWizard.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployProgress.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# The log box shows short entries: time and message, no tool output or command lines.
Assert-Equal (Format-LogTailLine '2026-11-02 12:01:05 [INFO] Partitioning disk 0') '12:01:05 Partitioning disk 0' 'log entry: time and message'
Assert-Equal (Format-LogTailLine '2026-11-02 12:01:09 [WARN] No driver pack') '12:01:09 Warning: No driver pack' 'log entry: warning'
Assert-Equal (Format-LogTailLine '2026-11-02 12:01:05 [INFO] > dism.exe /Apply-Image /ImageFile:E:\Images\Win11.wim') '' 'log entry: commands are left out'
Assert-Equal (Format-LogTailLine '  DiskPart successfully assigned the drive letter or mount point.') '' 'log entry: tool output is left out'
Assert-Equal (Format-LogTailLine '') '' 'log entry: blank line is left out'

if ($env:OS -ne 'Windows_NT') { Write-Host 'SKIP WinForms layout (not Windows)'; if ($failures) { exit 1 }; exit 0 }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Test-Fits($Control, [string]$Where) {
    $text = "$($Control.Text)"
    if (-not $text -or -not $Control.Visible -or $Control -is [Windows.Forms.TextBoxBase]) { return }
    $font = $Control.Font
    if ($Control -is [Windows.Forms.Button]) {
        $need = [Windows.Forms.TextRenderer]::MeasureText($text, $font)
        Assert-Equal ($Control.Width -ge $need.Width -and $Control.Height -ge $need.Height) $true "$Where button '$text' fits its text"
        return
    }
    if ($Control -is [Windows.Forms.Label] -and $Control.AutoEllipsis) { $need = [Windows.Forms.TextRenderer]::MeasureText('Ag', $font).Height }
    else {
        $room = $Control.Width - $(if ($Control -is [Windows.Forms.CheckBox]) { 24 } else { 2 })
        $need = Get-TextHeight -Text $text -Font $font -Width $room
    }
    Assert-Equal ($Control.Height -ge $need) $true "$Where '$text' is tall enough ($($Control.Height) >= $need)"
}

function Test-NoOverlap([object[]]$Controls, [string]$Where) {
    $shown = @($Controls | Where-Object { $_.Height -gt 0 } | Sort-Object Top)
    for ($i = 1; $i -lt $shown.Count; $i++) {
        $a = $shown[$i - 1]; $b = $shown[$i]
        $overlap = $a.Bounds.IntersectsWith($b.Bounds)
        Assert-Equal $overlap $false "$Where '$($a.Text)' and '$($b.Text)' do not overlap"
    }
}

# Progress window with big fonts and long texts.
$ui = New-DeployProgressForm -FontScale 1.4
$ui.Form.StartPosition = 'Manual'; $ui.Form.Location = New-Object Drawing.Point(-3000, -3000); $ui.Form.ShowInTaskbar = $false
$ui.Form.Show()
try {
    $record = [pscustomobject]@{
        state = 'Running'; step = 'Applying the image: 6 %'; percent = 14; maker = 'Dell Inc.'; model = 'Latitude 5521'; serial = 'GWHZLG3'
        computerName = 'GWHZLG3'; answerFile = 'Win11-Staff'; image = 'Images\Win11-Staff.wim'; driverPack = 'Dell\Latitude 5521'
        started = (Get-Date).AddMinutes(-2).ToString('o'); warnings = @('No BIOS settings for this model')
    }
    Update-DeployProgressForm -Ui $ui -View (Get-ProgressView -Record $record) -LogLines '12:00:01 Partitioning disk 0', ('12:00:05 ' + ('a long line ' * 20))
    foreach ($c in $ui.Form.Controls | Where-Object { $_ -isnot [Windows.Forms.Panel] }) {
        Test-Fits $c 'progress:'
        Assert-Equal ($c.Left -ge 200 -and $c.Right -le $ui.Form.ClientSize.Width -and $c.Bottom -le $ui.Form.ClientSize.Height) $true "progress: '$($c.Text)' is inside the window"
    }
    Test-NoOverlap @($ui.Title, $ui.Hardware, $ui.Facts, $ui.Detail, $ui.Bar, $ui.Percent, $ui.Message, $ui.Log, $ui.ViewLog) 'progress:'
    Assert-Equal ($ui.Cmd.Left -gt $ui.ViewLog.Right) $true 'progress: Command prompt is right of View log'
    Assert-Equal $ui.Log.WordWrap $true 'progress: log lines wrap instead of scrolling sideways'
    Assert-Equal $ui.Percent.Text.StartsWith('Overall 14 %') $true 'progress: overall percent is labelled'
}
finally { $ui.Form.Close(); $ui.Form.Dispose() }

# Wizard layout with big fonts: the same controls Show-DeployWizard builds, laid out by Update-DeployWizardLayout.
$big = New-Object Drawing.Font('Segoe UI', 14)
$form = New-Object Windows.Forms.Form -Property @{ ClientSize = New-Object Drawing.Size(920, 540); Font = $big; StartPosition = 'Manual'; Location = New-Object Drawing.Point(-3000, -3000); ShowInTaskbar = $false }
$lbl = { param($t) New-Object Windows.Forms.Label -Property @{ Location = New-Object Drawing.Point(224, 0); Size = New-Object Drawing.Size(672, 22); Text = $t } }
$w = @{
    Form = $form; IsDomain = $true
    Title = (& $lbl 'Name this computer'); HwLabel = (& $lbl 'Dell Inc. Latitude 5521   Serial GWHZLG3   SKU 0A67')
    Error = (& $lbl 'This PC has no internal disk that Windows can be installed on.')
    Back = New-Object Windows.Forms.Button -Property @{ Text = '< Back' }
    Next = New-Object Windows.Forms.Button -Property @{ Text = 'Next >' }
    Cancel = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel' }
    ListLabel = (& $lbl 'Answer file'); List = New-Object Windows.Forms.ListBox; About = (& $lbl '')
    NameLabel = (& $lbl 'Computer name'); NameBox = New-Object Windows.Forms.TextBox
    NameHint = (& $lbl 'Suggested from the hardware. You can change it.'); JoinLabel = (& $lbl 'Joins the domain Borealc.on.ca')
    OuLabel = (& $lbl 'Organizational unit (empty for the default Computers container)'); OuBox = New-Object Windows.Forms.TextBox
    DiskLabel = (& $lbl 'Disk to erase and install Windows on'); DiskBox = New-Object Windows.Forms.ComboBox
    AppsLabel = (& $lbl 'Applications installed at first boot (ticked ones, top to bottom)'); Apps = New-Object Windows.Forms.CheckedListBox
    Summary = New-Object Windows.Forms.TextBox -Property @{ Multiline = $true }
    Confirm = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Erase disk 0 and everything on it, then deploy' }
    SecretIntro = (& $lbl 'These passwords are not on this USB stick. Type them once here: they are kept in memory for this deployment only, and nothing else is asked once Windows starts installing.')
    SecretRows = @()
}
$w.Title.Font = New-Object Drawing.Font('Segoe UI', 20)
$w.Pages = foreach ($i in 0..4) { New-Object Windows.Forms.Panel }
$form.Controls.AddRange(@($w.Title, $w.HwLabel, $w.Error, $w.Back, $w.Next, $w.Cancel) + $w.Pages)
$w.Pages[0].Controls.AddRange(@($w.ListLabel, $w.List, $w.About))
$w.Pages[1].Controls.Add($w.SecretIntro)
$w.Pages[2].Controls.AddRange(@($w.NameLabel, $w.NameBox, $w.NameHint, $w.JoinLabel, $w.OuLabel, $w.OuBox, $w.DiskLabel, $w.DiskBox))
$w.Pages[3].Controls.AddRange(@($w.AppsLabel, $w.Apps))
$w.Pages[4].Controls.AddRange(@($w.Summary, $w.Confirm))
Set-SecretRows -Wiz $w -Secrets @(
    [pscustomobject]@{ Key = 'config\secrets\admin.txt'; Label = 'Local Administrator password' },
    [pscustomobject]@{ Key = 'config\secrets\join.txt'; Label = 'Join account password (CORP\svc-join)' })
$form.Show()
try {
    Update-DeployWizardLayout -Wiz $w
    foreach ($c in $w.Title, $w.HwLabel, $w.Error, $w.Back, $w.Next, $w.Cancel, $w.NameLabel, $w.NameHint, $w.JoinLabel, $w.OuLabel, $w.DiskLabel, $w.AppsLabel, $w.Confirm, $w.ListLabel) {
        Test-Fits $c 'wizard:'
    }
    Test-NoOverlap @($w.Title, $w.HwLabel) 'wizard header:'
    Test-NoOverlap @($w.NameLabel, $w.NameBox, $w.NameHint, $w.JoinLabel, $w.OuLabel, $w.OuBox, $w.DiskLabel, $w.DiskBox) 'wizard name page:'
    Test-NoOverlap @($w.Summary, $w.Confirm) 'wizard confirm page:'
    Assert-Equal ($w.DiskBox.Bottom -le $w.Pages[2].Height) $true 'wizard: the disk box is inside the page'
    Assert-Equal ($w.Pages[2].Top -ge $w.HwLabel.Bottom) $true 'wizard: pages start under the header'
    Assert-Equal ($w.Pages[2].Bottom -le $w.Error.Top -and $w.Error.Bottom -le $w.Next.Top) $true 'wizard: page, error and buttons stack'
    Assert-Equal ($w.Cancel.Right -le $form.ClientSize.Width -and $w.Back.Left -ge 224) $true 'wizard: buttons are inside the window'
    # Passwords page: the note, then a label and a box per password, all on the page and none overlapping.
    Assert-Equal @($w.SecretRows).Count 2 'wizard passwords: one row per password'
    Assert-Equal (@($w.SecretRows | Where-Object { $_.Box.UseSystemPasswordChar }).Count) 2 'wizard passwords: the boxes hide what is typed'
    $secretControls = @($w.SecretIntro) + @($w.SecretRows | ForEach-Object { $_.Label; $_.Box })
    Test-NoOverlap $secretControls 'wizard passwords page:'
    foreach ($r in $w.SecretRows) { Test-Fits $r.Label 'wizard passwords:' }
    Assert-Equal ($w.SecretRows[-1].Box.Bottom -le $w.Pages[1].Height) $true 'wizard passwords: the last box is inside the page'
    # Another answer file replaces the rows instead of adding to them.
    Set-SecretRows -Wiz $w -Secrets @([pscustomobject]@{ Key = 'config\secrets\pin.txt'; Label = 'BitLocker PIN' })
    Assert-Equal "$(@($w.SecretRows).Count)|$($w.Pages[1].Controls.Count)" '1|3' 'wizard passwords: rows replaced for the next answer file'
    Set-SecretRows -Wiz $w -Secrets @()
    Assert-Equal "$(@($w.SecretRows).Count)|$($w.Pages[1].Controls.Count)" '0|1' 'wizard passwords: none missing leaves only the note'
    Update-DeployWizardLayout -Wiz $w

    # Install anyway (Windows 11 check) sits between the page and the error line, only while it is shown.
    $w.Win11Anyway = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Install Windows 11 anyway on this PC (it does not meet the requirements)'; Visible = $false }
    $form.Controls.Add($w.Win11Anyway)
    $pageBottom = $w.Pages[0].Bottom
    $w.Win11Anyway.Visible = $true
    Update-DeployWizardLayout -Wiz $w
    Test-Fits $w.Win11Anyway 'wizard:'
    Assert-Equal ($w.Pages[0].Bottom -le $w.Win11Anyway.Top -and $w.Win11Anyway.Bottom -le $w.Error.Top) $true 'wizard: page, Install anyway and error stack'
    Assert-Equal ($w.Pages[0].Bottom -lt $pageBottom) $true 'wizard: the page makes room for Install anyway'
    $w.Win11Anyway.Visible = $false
    Update-DeployWizardLayout -Wiz $w
    Assert-Equal $w.Pages[0].Bottom $pageBottom 'wizard: hidden Install anyway takes no room'

    $domainDiskTop = $w.DiskLabel.Top; $ouTop = $w.OuLabel.Top
    $w.IsDomain = $false; $w.OuLabel.Visible = $false; $w.OuBox.Visible = $false
    Update-DeployWizardLayout -Wiz $w
    Assert-Equal ($w.DiskLabel.Top -eq $ouTop -and $w.DiskLabel.Top -lt $domainDiskTop) $true 'wizard: a workgroup moves the disk up into the OU rows'
}
finally { $form.Close(); $form.Dispose() }

# Show-DeployWizard lays the wizard out on each page.
$src = Get-Content -Raw (Join-Path $repo 'src/DeployWizard.psm1')
Assert-Equal ($src -match '\$w\.Layout = \{ Update-DeployWizardLayout') $true 'Show-DeployWizard uses Update-DeployWizardLayout'

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All WinPE layout tests passed.' -ForegroundColor Green
