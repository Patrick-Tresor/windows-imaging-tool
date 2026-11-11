# The Driver Library page lists driver pack downloads with their progress, in the main window (Patrick, 2026-11-11:
# no separate window, and the progress must still be there after it was out of sight).
# Run: powershell -STA -File tests/DriverDownloads.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

[xml]$main = Get-Content -Raw (Join-Path $repo 'src/Console/MainWindow.xaml')
$xns = 'http://schemas.microsoft.com/winfx/2006/xaml'
$grpNode = $main.SelectSingleNode("//*[@*[local-name()='Name' and .='GrpDriverDownloads']]")
Assert-Equal ([bool]$grpNode) $true 'the Driver Library page has a Downloads list'
$page = $grpNode
while ($page -and $page.LocalName -ne 'TabItem') { $page = $page.ParentNode }
Assert-Equal $page.GetAttribute('Header') 'Driver Library' 'the Downloads list is on the Driver Library page'
Assert-Equal $grpNode.GetAttribute('Visibility') 'Collapsed' 'the list is hidden until a download starts'

$sta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'SKIP Downloads list: WPF needs Windows' -ForegroundColor Yellow
} elseif (-not $sta) {
    Write-Host 'SKIP Downloads list: WPF needs an STA thread' -ForegroundColor Yellow
} else {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $repo 'src/BuildSteps.psm1') -Force
    Import-Module (Join-Path $repo 'src/Console/WheelScroll.psm1') -Force
    . (Join-Path $repo 'src/Console/BuildProgress.ps1')
    . (Join-Path $repo 'src/Console/DriverDownloader.ps1')

    # The Downloads group from MainWindow.xaml, on its own off-screen window.
    $grp = [Windows.Markup.XamlReader]::Parse($grpNode.OuterXml)
    $win = New-Object Windows.Window -Property @{ Left = -10000; Top = -10000; Width = 900; Height = 500; ShowInTaskbar = $false; Content = $grp }
    $lst = $grp.FindName('LstDriverDownloads')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("dl-panel-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:refreshed = 0
    try {
        $win.Show()
        $pf = Join-Path $dir 'progress.json'
        Start-BuildProgress -Path $pf -Title 'Downloading the Dell Latitude 5531 driver pack' -Steps @(, @('pack1', 'Dell Latitude 5531'))
        Start-BuildStep 'pack1'; Set-BuildStepProgress 'pack1' -Percent 12 -Detail 'Downloading 2773 MB'
        $row = Add-DriverDownloadJob -Panel $grp -List $lst -ProgressFile $pf -LogPath (Join-Path $dir 'x.log') -Title 'Dell Latitude 5531 driver pack' `
            -OnFinished { $script:refreshed++ }
        $win.Dispatcher.Invoke([action]{}, 'Background')
        Assert-Equal $grp.Visibility 'Visible' 'a download shows the list'
        Assert-Equal @($lst.ItemsSource).Count 1 'one row per download'
        Assert-Equal "$($row.Title)|$($row.Finished)" 'Dell Latitude 5531 driver pack|False' 'the row names the pack and is running'
        $step = @($row.Steps)[0]
        Assert-Equal "$($step.Name)|$($step.Percent)|$($step.Detail)" 'Dell Latitude 5531|12|Downloading 2773 MB' 'the pack row shows its bar and detail'
        Assert-Equal $script:DriverDownloadTimer.IsEnabled $true 'progress is read while it runs'

        Invoke-DriverDownloadAction -Row $row -Action 'remove'
        Assert-Equal @($lst.ItemsSource).Count 1 'a running download cannot be removed'

        # A second download goes on top.
        $pf2 = Join-Path $dir 'progress2.json'
        Start-BuildProgress -Path $pf2 -Title 'x' -Steps @(, @('pack1', 'HP EliteBook 840 G9'))
        $row2 = Add-DriverDownloadJob -Panel $grp -List $lst -ProgressFile $pf2 -Title 'HP EliteBook 840 G9 driver pack'
        Assert-Equal @($lst.ItemsSource)[0].Title 'HP EliteBook 840 G9 driver pack' 'the newest download is first'

        Complete-BuildStep 'pack1' -Detail '198 drivers in Drivers\Dell\Latitude 5531'   # BuildSteps writes the last started file: pf2
        Stop-BuildProgress
        Update-DriverDownloads
        Assert-Equal "$($row2.Finished)|$($row2.Outcome)" 'True|ok' 'a finished download is marked done'
        Assert-Equal "$($row.Finished)" 'False' 'the other download keeps running'
        Assert-Equal $script:refreshed 0 'no refresh until the download that asked for one ends'

        Start-BuildProgress -Path $pf -Title 'x' -Steps @(, @('pack1', 'Dell Latitude 5531'))
        Start-BuildStep 'pack1'; Complete-BuildStep 'pack1' -State failed -Detail 'hash check failed'
        Stop-BuildProgress -Message '1 of 1 packs failed.'
        Update-DriverDownloads
        Update-DriverDownloads
        Assert-Equal "$($row.Finished)|$($row.Outcome)|$($row.Summary)" 'True|failed|Failed: 1 of 1 packs failed.' 'a failed download says so'
        Assert-Equal $script:refreshed 1 'the library refreshes once when a download ends'
        Assert-Equal $script:DriverDownloadTimer.IsEnabled $false 'reading stops when nothing runs'

        $win.Dispatcher.Invoke([action]{}, 'Background')
        $buttons = @()
        $walk = { param($n) for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($n); $i++) {
            $c = [Windows.Media.VisualTreeHelper]::GetChild($n, $i); if ($c -is [Windows.Controls.Button]) { $script:buttons += $c }; & $walk $c } }
        $script:buttons = @(); & $walk $lst
        $remove = @($script:buttons | Where-Object { "$($_.Tag)" -eq 'remove' -and $_.DataContext -eq $row })[0]
        Assert-Equal $remove.IsEnabled $true 'Remove is enabled once the download ended'
        $remove.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent, $remove))
        Assert-Equal @($lst.ItemsSource).Count 1 'Remove takes the download off the list'
        Invoke-DriverDownloadAction -Row $row2 -Action 'remove'
        Assert-Equal $grp.Visibility 'Collapsed' 'the list hides when it is empty'
    } finally {
        if ($script:DriverDownloadTimer) { $script:DriverDownloadTimer.Stop() }
        $win.Close()
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All driver download list checks passed.' -ForegroundColor Green
