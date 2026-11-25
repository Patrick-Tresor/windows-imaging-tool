# Console pages fit their window: in a restored (not maximized) window every grid column stays on screen, at least as
# wide as its header's longest word, and long cell text wraps instead of being cut off; in a maximized window the
# columns keep the widths the XAML gives them. GridFit.psm1 does it for every window New-ConsoleWindow loads.
# Run: powershell -File tests/ConsoleFit.Tests.ps1 (the WPF part needs Windows).

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$console = Join-Path $repo 'src/Console'

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$loader = Get-Content -Raw -LiteralPath (Join-Path $console 'XamlWindow.psm1')
Assert-Equal ($loader -match 'Enable-GridFit \$window') $true 'New-ConsoleWindow fits the grids of every window'
$styles = Get-Content -Raw -LiteralPath (Join-Path $console 'Styles.xaml')
Assert-Equal ($styles -match 'Property="RowHeight"') $false 'grid rows have no fixed height, so wrapped text shows'
Assert-Equal ($styles -match 'Property="MinRowHeight" Value="32"') $true 'one-line rows stay 32 px'
[xml]$main = Get-Content -Raw -LiteralPath (Join-Path $console 'MainWindow.xaml')
foreach ($node in $main.SelectNodes('//*[local-name()="TabItem"]/*[local-name()="ScrollViewer"]/*[local-name()="DockPanel"]')) {
    $min = [int]$node.GetAttribute('MinHeight')
    Assert-Equal ($min -le 480) $true "a filling page asks for no more height than a restored window has ($min <= 480)"
}

# The width sharing itself.
Import-Module (Join-Path $console 'GridFit.psm1') -Force
$inf = [double]::PositiveInfinity
$w = Get-FitColumnWidths -Base 120, 100, 100 -Min 60, 50, 50 -Max 120, $inf, $inf -Available 1000
Assert-Equal ($w -join ',') '120,440,440' 'wide: a pixel column stays at its XAML width, * columns share the rest'
$w = Get-FitColumnWidths -Base 120, 100, 100 -Min 60, 50, 50 -Max 120, $inf, $inf -Available 256
Assert-Equal (($w | Measure-Object -Sum).Sum -le 256) $true "narrow: the columns fit ($($w -join ','))"
Assert-Equal ($w[0] -gt $w[1]) $true 'narrow: the 120 px column shrinks in proportion with the * columns'
$w = Get-FitColumnWidths -Base 120, 100, 100 -Min 60, 50, 50 -Max 120, $inf, $inf -Available 100
Assert-Equal ($w -join ',') '60,50,50' 'too narrow: every column at its minimum'
$w = Get-FitColumnWidths -Base 90, 60 -Min 50, 50 -Max 90, 60 -Available 1000
Assert-Equal ($w -join ',') '90,60' 'only pixel columns: none grows past its XAML width'

$sta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'SKIP layout checks: WPF needs Windows' -ForegroundColor Yellow
} elseif (-not $sta) {
    Write-Host 'SKIP layout checks: WPF needs an STA thread' -ForegroundColor Yellow
} else {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $console 'XamlWindow.psm1') -Force

    function Find-Visual($Root, [type]$Type) {
        for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root); $i++) {
            $child = [Windows.Media.VisualTreeHelper]::GetChild($Root, $i)
            if ($child -is $Type) { return $child }
            $found = Find-Visual $child $Type
            if ($found) { return $found }
        }
    }

    $ui = New-ConsoleWindow 'MainWindow.xaml'
    $win = $ui.Window
    $win.WindowStartupLocation = 'Manual'
    $win.Left = -4000; $win.Top = -4000; $win.ShowInTaskbar = $false; $win.ShowActivated = $false
    $win.Width = 1100; $win.Height = 720
    $ui.Controls['GridAd'].ItemsSource = @([pscustomobject]@{
        Name = 'GWHZLG3'; IpAddress = '10.10.64.51'; OUPath = 'corp.local/Workstations/Montreal/Finance'
        OperatingSystem = 'Windows 11 Enterprise'; LastLogonText = '2026-11-23'; Online = 'Yes (SMB)'; OnlineDetail = ''
        Agent = '4 min ago'; AgentDetail = ''; Reimage = 'Waiting for the PC to restart into WinPE'; Description = 'Finance laptop, 3rd floor'
    })
    $ui.Controls['GridDash'].ItemsSource = @([pscustomobject]@{
        ComputerName = 'GWHZLG3'; Model = 'Latitude 5521'; Serial = 'GWHZLG3'; IpAddress = '10.10.64.51'; LastSeenText = '1 min ago'
        AnswerFile = 'Windows 11 Finance'; State = 'Running'; Percent = 40; Step = 'Applying the image'; Result = ''; ResultText = ''
        ResultState = ''; Started = [datetime]'2026-11-25 10:00'; Duration = '12 min'; LastSeen = '10:12'
    })
    $win.Show()
    try {
        foreach ($size in @(@{ W = 1100; H = 720; Name = 'restored' }, @{ W = 1920; H = 1040; Name = 'maximized' })) {
            $win.Width = $size.W; $win.Height = $size.H
            foreach ($tab in 'Computers', 'Dashboard', 'Images', 'Driver Library', 'Answer Files', 'Apps and Tasks') {
                $item = @($ui.Controls['Tabs'].Items | Where-Object { $_.Header -eq $tab })[0]
                $ui.Controls['Tabs'].SelectedItem = $item
                $win.UpdateLayout()
                $grids = New-Object Collections.ArrayList
                $stack = New-Object Collections.Stack; $stack.Push($item.Content)
                while ($stack.Count) {
                    $v = $stack.Pop()
                    if ($v -is [Windows.Controls.DataGrid]) { [void]$grids.Add($v); continue }
                    if ($v -is [Windows.Media.Visual]) {
                        for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($v); $i++) { $stack.Push([Windows.Media.VisualTreeHelper]::GetChild($v, $i)) }
                    }
                }
                foreach ($grid in $grids) {
                    if (-not $grid.IsVisible) { continue }
                    $scroll = Find-Visual $grid ([Windows.Controls.ScrollViewer])
                    Assert-Equal ([int]$scroll.ScrollableWidth) 0 "$($size.Name) ${tab}: $($grid.Name) columns fit without scrolling sideways"
                    foreach ($col in $grid.Columns) {
                        Assert-Equal ($col.ActualWidth -ge $col.MinWidth - 0.5) $true "$($size.Name) ${tab}: $($grid.Name) '$($col.Header)' at least its header's width ($([int]$col.ActualWidth) >= $([int]$col.MinWidth))"
                    }
                }
                if ($tab -eq 'Computers' -and $size.Name -eq 'restored') {
                    $page = $item.Content
                    Assert-Equal ([int]$page.ScrollableHeight) 0 "restored Computers page needs no scrolling ($([int]$page.ScrollableHeight) px over)"
                    $cell = Find-Visual $ui.Controls['GridAd'] ([Windows.Controls.DataGridRow])
                    Assert-Equal ($cell.ActualHeight -gt 32) $true 'restored: a long cell wraps onto a taller row instead of being cut off'
                }
            }
        }
        # Maximized, a column with a pixel width in the XAML is back at that width; the * columns take the rest.
        $item = @($ui.Controls['Tabs'].Items | Where-Object { $_.Header -eq 'Computers' })[0]
        $ui.Controls['Tabs'].SelectedItem = $item; $win.UpdateLayout()
        $name = @($ui.Controls['GridAd'].Columns | Where-Object { $_.Header -eq 'Name' })[0]
        Assert-Equal ([int]$name.ActualWidth) 120 'maximized: the Name column is its XAML width'
    } finally {
        $win.Close()
    }
}

Complete-Tests 'All window fit tests passed.'
