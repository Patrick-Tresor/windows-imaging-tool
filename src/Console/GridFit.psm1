# Grids that fit their window. WPF keeps a column with a pixel width at that width, so in a smaller window the grid's
# other columns are squeezed to nothing and the last ones run off the right edge. Enable-GridFit sizes the columns
# itself whenever the grid's room changes: a pixel width in the XAML is the most that column gets, and it shrinks
# with the others when room is short (WPF's own * columns don't grow back after a column has a MaxWidth, so they
# are not used). Each column keeps at least the longest word of its header, header and cell text wrap, and a row
# grows to three lines instead of cutting its text off.

# Each fitted grid's columns and the room they were last sized for; an entry goes when its grid does.
$script:FitPlans = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

# The smallest width a column can have: its header's longest word plus the header's padding.
function Get-GridHeaderMinWidth {
    param([string]$Header, [Windows.Media.FontFamily]$FontFamily = [Windows.Media.FontFamily]::new('Segoe UI'), [double]$FontSize = 13)
    $face = [Windows.Media.Typeface]::new($FontFamily, [Windows.FontStyles]::Normal, [Windows.FontWeights]::SemiBold, [Windows.FontStretches]::Normal)
    $widest = 0.0
    foreach ($word in @("$Header" -split '\s+' | Where-Object { $_ })) {
        $text = [Windows.Media.FormattedText]::new($word, [Globalization.CultureInfo]::CurrentUICulture,
            [Windows.FlowDirection]::LeftToRight, $face, $FontSize, [Windows.Media.Brushes]::Black)
        $widest = [Math]::Max($widest, $text.WidthIncludingTrailingWhitespace)
    }
    [Math]::Max(40, [Math]::Ceiling($widest) + 20)
}

# Column widths for $Available pixels: each column gets $Base times one shared factor, kept between its $Min and $Max.
# The factor is the largest one that still fits, so the columns fill the grid; when even the minimums don't fit,
# every column is at its minimum and the grid scrolls sideways.
function Get-FitColumnWidths {
    param([double[]]$Base, [double[]]$Min, [double[]]$Max, [double]$Available)
    $n = $Base.Count
    $at = {
        param([double]$f)
        $total = 0.0
        for ($i = 0; $i -lt $n; $i++) { $total += [Math]::Min($Max[$i], [Math]::Max($Min[$i], $Base[$i] * $f)) }
        $total
    }
    $lo = 0.0; $hi = 1000.0
    if ((& $at $hi) -le $Available) { $lo = $hi }
    else { for ($k = 0; $k -lt 50; $k++) { $mid = ($lo + $hi) / 2; if ((& $at $mid) -le $Available) { $lo = $mid } else { $hi = $mid } } }
    $w = @(for ($i = 0; $i -lt $n; $i++) { [Math]::Floor([Math]::Min($Max[$i], [Math]::Max($Min[$i], $Base[$i] * $lo))) })
    # Whole pixels: what rounding left over goes to the last column that may still grow.
    $left = [Math]::Floor($Available - ($w | Measure-Object -Sum).Sum)
    for ($i = $n - 1; $i -ge 0 -and $left -gt 0; $i--) {
        $add = [Math]::Min($left, $Max[$i] - $w[$i])
        if ($add -gt 0) { $w[$i] += $add; $left -= $add }
    }
    ,$w
}

# One grid: its columns are sized here, not by the DataGrid, every time the room for them changes. A column with a
# pixel width in the XAML never grows past it and shrinks with the others; a * column (100 px a star) takes the
# rest. Every column keeps at least its header's longest word, and text columns wrap.
function Set-DataGridFit {
    param([Parameter(Mandatory)][Windows.Controls.DataGrid]$Grid)
    $plan = @()
    foreach ($col in @($Grid.Columns)) {
        $min = Get-GridHeaderMinWidth -Header $col.Header -FontFamily $Grid.FontFamily -FontSize $Grid.FontSize
        $min = [Math]::Max($min, $col.MinWidth)
        $width = $col.Width
        if ($width.IsAbsolute) { $plan += [pscustomobject]@{ Column = $col; Base = $width.Value; Min = $min; Max = [Math]::Max($width.Value, $min) } }
        elseif ($width.IsStar) { $plan += [pscustomobject]@{ Column = $col; Base = $width.Value * 100; Min = $min; Max = [double]::PositiveInfinity } }

        if ($col -is [Windows.Controls.DataGridTextColumn]) {
            $base = $col.ElementStyle
            if (-not $base) { $base = [Windows.Controls.DataGridTextColumn]::DefaultElementStyle }
            $style = [Windows.Style]::new([Windows.Controls.TextBlock], $base)
            $style.Setters.Add([Windows.Setter]::new([Windows.Controls.TextBlock]::TextWrappingProperty, [Windows.TextWrapping]::Wrap))
            $style.Setters.Add([Windows.Setter]::new([Windows.Controls.TextBlock]::TextTrimmingProperty, [Windows.TextTrimming]::CharacterEllipsis))
            # Three lines at most; the row's 32 px minimum keeps one-line rows as they were.
            $style.Setters.Add([Windows.Setter]::new([Windows.FrameworkElement]::MaxHeightProperty, [double]($Grid.FontSize * 4.2)))
            $style.Setters.Add([Windows.Setter]::new([Windows.FrameworkElement]::MarginProperty, [Windows.Thickness]::new(0, 6, 0, 6)))
            $col.ElementStyle = $style
        }
    }
    if (-not $plan) { return }
    foreach ($p in $plan) { $p.Column.MinWidth = $p.Min; $p.Column.Width = [Windows.Controls.DataGridLength]::new($p.Base) }

    # Remove + Add, not AddOrUpdate: Windows PowerShell 5.1's .NET Framework doesn't have it.
    [void]$script:FitPlans.Remove($Grid)
    $script:FitPlans.Add($Grid, [pscustomobject]@{ Plan = $plan; Last = -1.0 })
    # The handlers are plain script blocks of this module, so they reach Update-DataGridFit when WPF calls them later.
    # (A closure made inside another closure's event handler loses the outer variables: that broke the console.)
    $Grid.Add_SizeChanged({ param($s, $e) Update-DataGridFit $s })
    $Grid.Add_Loaded({
        param($s, $e)
        $sv = $s.Template.FindName('DG_ScrollViewer', $s)
        # The room also changes when the grid's own vertical scroll bar comes or goes.
        if ($sv -and -not $sv.Tag) {
            $sv.Tag = 'GridFit'
            $sv.Add_ScrollChanged({
                param($x, $e)
                if ($e.ViewportWidthChange -ne 0) { Update-DataGridFit $x.TemplatedParent }
            })
        }
        Update-DataGridFit $s
    })
}

# Sizes the columns of a grid that Set-DataGridFit prepared to the room it has now. Never throws: a layout problem
# must not stop the console.
function Update-DataGridFit($Grid) {
    try {
        $fit = $null
        if (-not ($Grid -is [Windows.Controls.DataGrid]) -or -not $script:FitPlans.TryGetValue($Grid, [ref]$fit)) { return }
        $plan = $fit.Plan
        $sv = $Grid.Template.FindName('DG_ScrollViewer', $Grid)
        $room = if ($sv -and $sv.ViewportWidth -gt 0) { $sv.ViewportWidth } else { $Grid.ActualWidth - $Grid.BorderThickness.Left - $Grid.BorderThickness.Right }
        $shown = @($plan | Where-Object { $_.Column.Visibility -eq 'Visible' })
        # Columns sized another way (Auto) keep their room.
        foreach ($col in $Grid.Columns) { if ($col.Visibility -eq 'Visible' -and -not ($plan.Column -contains $col)) { $room -= $col.ActualWidth } }
        $room = [Math]::Floor($room) - 1
        if ($room -le 0 -or -not $shown -or [Math]::Abs($room - $fit.Last) -lt 1) { return }
        $fit.Last = $room
        $widths = Get-FitColumnWidths -Base @($shown.Base) -Min @($shown.Min) -Max @($shown.Max) -Available $room
        for ($i = 0; $i -lt $shown.Count; $i++) { $shown[$i].Column.Width = [Windows.Controls.DataGridLength]::new($widths[$i]) }
    } catch { }
}

# Every DataGrid in the window's XAML, on every tab.
function Get-LogicalDataGrids($Node) {
    if ($Node -is [Windows.Controls.DataGrid]) { $Node }
    if ($Node -is [Windows.DependencyObject]) {
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($Node)) { Get-LogicalDataGrids $child }
    }
}

function Enable-GridFit {
    param([Parameter(Mandatory)]$Window)
    foreach ($grid in @(Get-LogicalDataGrids $Window)) { Set-DataGridFit -Grid $grid }
}

Export-ModuleMember -Function Get-GridHeaderMinWidth, Get-FitColumnWidths, Set-DataGridFit, Update-DataGridFit, Enable-GridFit
