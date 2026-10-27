# Mouse wheel scrolling in the console windows: every window routes the wheel through WheelScroll.psm1, every page
# that can outgrow its window can scroll, and a grid inside a scrolling page hands the wheel back to the page once
# it reaches its end.
# Run: powershell -File tests/ConsoleScrolling.Tests.ps1 (the WPF part needs Windows).

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$console = Join-Path $repo 'src/Console'

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Every window the console loads turns on wheel routing.
foreach ($f in Get-ChildItem -LiteralPath $console -Filter '*.ps1') {
    $text = Get-Content -Raw -LiteralPath $f.FullName
    foreach ($m in [regex]::Matches($text, '(\$\w+) = \[Windows\.Markup\.XamlReader\]::Load')) {
        $var = [regex]::Escape($m.Groups[1].Value)
        Assert-Equal ($text -match "Enable-WheelScrolling $var\b") $true "$($f.Name): $($m.Groups[1].Value) gets wheel scrolling"
    }
}

# Pages and sections that the editors and the capture wizard switch between are ScrollViewers, or DockPanels that
# give a grid or list the rest of the room. A bare StackPanel page is cut off at the bottom of the window.
foreach ($f in Get-ChildItem -LiteralPath $console -Filter '*.xaml') {
    [xml]$x = Get-Content -Raw -LiteralPath $f.FullName
    foreach ($node in $x.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($name -notmatch '^(Sec|Page)\d+$') { continue }
        Assert-Equal ($node.LocalName -in 'ScrollViewer', 'DockPanel') $true "$($f.Name): $name can scroll or fill"
    }
}

$sta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'SKIP wheel routing checks: WPF needs Windows' -ForegroundColor Yellow
} elseif (-not $sta) {
    Write-Host 'SKIP wheel routing checks: WPF needs an STA thread' -ForegroundColor Yellow
} else {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $console 'WheelScroll.psm1') -Force

    function Find-Visual($Root, [type]$Type) {
        for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root); $i++) {
            $child = [Windows.Media.VisualTreeHelper]::GetChild($Root, $i)
            if ($child -is $Type) { return $child }
            $found = Find-Visual $child $Type
            if ($found) { return $found }
        }
    }

    # A scrolling page that holds a short grid with more rows than fit, like the Multicast tab.
    [xml]$px = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" VerticalScrollBarVisibility="Auto">
  <StackPanel>
    <Border Height="150"/>
    <DataGrid x:Name="Grid" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Height="120" RowHeight="20" AutoGenerateColumns="False">
      <DataGrid.Columns><DataGridTextColumn Header="PC" Binding="{Binding}"/></DataGrid.Columns>
    </DataGrid>
    <Border Height="600"/>
  </StackPanel>
</ScrollViewer>
'@
    $page = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($px))
    $grid = $page.FindName('Grid')
    $grid.ItemsSource = @(1..60 | ForEach-Object { "PC$_" })
    $win = New-Object Windows.Window -Property @{
        Width = 400; Height = 300; Left = -2000; Top = -2000; ShowInTaskbar = $false; ShowActivated = $false
        WindowStyle = 'None'; Content = $page
    }
    Enable-WheelScrolling $win
    $win.Show()
    try {
        $win.UpdateLayout()
        $gridScroll = Find-Visual $grid ([Windows.Controls.ScrollViewer])
        # The rows panel stays in the grid while rows scroll in and out of view.
        $row = Find-Visual $grid ([Windows.Controls.Primitives.DataGridRowsPresenter])
        Assert-Equal ($gridScroll.ScrollableHeight -gt 0) $true 'the grid has rows to scroll'
        Assert-Equal ($page.ScrollableHeight -gt 0) $true 'the page has room to scroll'

        Assert-Equal ([object]::ReferenceEquals((Get-WheelScrollTarget $row -120), $gridScroll)) $true 'wheel down over the grid scrolls the grid first'
        Assert-Equal ($null -eq (Get-WheelScrollTarget $row 120)) $true 'wheel up with the grid and the page at the top scrolls nothing'

        Invoke-WheelScroll $gridScroll -120
        $win.UpdateLayout()
        Assert-Equal ($gridScroll.VerticalOffset -gt 0) $true 'one wheel turn moves the grid'

        $gridScroll.ScrollToEnd(); $win.UpdateLayout()
        Assert-Equal ([object]::ReferenceEquals((Get-WheelScrollTarget $row -120), $page)) $true 'wheel down over a grid at its end scrolls the page'
        Assert-Equal ([object]::ReferenceEquals((Get-WheelScrollTarget $row 120), $gridScroll)) $true 'wheel up over a grid at its end scrolls the grid'

        Invoke-WheelScroll $page -120
        $win.UpdateLayout()
        Assert-Equal ($page.VerticalOffset -gt 0) $true 'one wheel turn moves the page'

        $gridScroll.ScrollToHome(); $page.ScrollToEnd(); $win.UpdateLayout()
        Assert-Equal ([object]::ReferenceEquals((Get-WheelScrollTarget $row 120), $page)) $true 'wheel up over a grid at its top scrolls the page'

        # The real event: a wheel turn over a grid row, raised through the window.
        $gridScroll.ScrollToHome(); $page.ScrollToHome(); $win.UpdateLayout()
        $cell = Find-Visual $grid ([Windows.Controls.DataGridRow])
        $wheel = [Windows.Input.MouseWheelEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, -120)
        $wheel.RoutedEvent = [Windows.UIElement]::PreviewMouseWheelEvent
        $cell.RaiseEvent($wheel)
        $win.UpdateLayout()
        Assert-Equal $wheel.Handled $true 'the window handles a wheel turn over the grid'
        Assert-Equal ($gridScroll.VerticalOffset -gt 0) $true 'that wheel turn scrolls the grid'

        # The main window loads, and its tabs that hold a grid under a tall form scroll as a whole.
        [xml]$mx = Get-Content -Raw -LiteralPath (Join-Path $console 'MainWindow.xaml')
        $main = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($mx))
        foreach ($tab in 'Driver Library', 'Remote Reimage', 'Dashboard') {
            $item = @($main.FindName('Tabs').Items | Where-Object { $_.Header -eq $tab })[0]
            Assert-Equal ($item.Content -is [Windows.Controls.ScrollViewer]) $true "the $tab tab scrolls when the window is small"
        }
    } finally {
        $win.Close()
    }
}

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All scrolling tests passed.' -ForegroundColor Green
