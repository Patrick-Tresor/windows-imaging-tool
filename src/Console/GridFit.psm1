# Grids that fit their window. WPF keeps a column with a pixel width at that width, so in a smaller window the grid's
# other columns are squeezed to nothing and the last ones run off the right edge. Enable-GridFit turns every pixel
# width into a share of the grid (it never grows past the width in the XAML, and shrinks with the others when room
# is short), keeps each column at least as wide as the longest word of its header, wraps header and cell text, and
# lets a row grow to three lines instead of cutting its text off.

# The smallest width a column can have: its header's longest word plus the header's padding and gripper.
function Get-GridHeaderMinWidth {
    param([string]$Header, [Windows.Media.FontFamily]$FontFamily = [Windows.Media.FontFamily]::new('Segoe UI'), [double]$FontSize = 13)
    $face = [Windows.Media.Typeface]::new($FontFamily, [Windows.FontStyles]::Normal, [Windows.FontWeights]::SemiBold, [Windows.FontStretches]::Normal)
    $widest = 0.0
    foreach ($word in @("$Header" -split '\s+' | Where-Object { $_ })) {
        $text = [Windows.Media.FormattedText]::new($word, [Globalization.CultureInfo]::CurrentUICulture,
            [Windows.FlowDirection]::LeftToRight, $face, $FontSize, [Windows.Media.Brushes]::Black)
        $widest = [Math]::Max($widest, $text.WidthIncludingTrailingWhitespace)
    }
    [Math]::Max(48, [Math]::Ceiling($widest) + 24)
}

# One grid: pixel widths become shares, every column gets a header-sized minimum, text columns wrap.
function Set-DataGridFit {
    param([Parameter(Mandatory)][Windows.Controls.DataGrid]$Grid)
    foreach ($col in @($Grid.Columns)) {
        $min = Get-GridHeaderMinWidth -Header $col.Header -FontFamily $Grid.FontFamily -FontSize $Grid.FontSize
        $width = $col.Width
        if ($width.IsAbsolute) {
            # 100 px is worth one star: a 120 px column next to a * column gets a bit more room than it.
            $px = $width.Value
            $col.Width = [Windows.Controls.DataGridLength]::new($px / 100, [Windows.Controls.DataGridLengthUnitType]::Star)
            $col.MaxWidth = [Math]::Max($px, $min)
        }
        if ($col.MinWidth -lt $min) { $col.MinWidth = $min }

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

Export-ModuleMember -Function Get-GridHeaderMinWidth, Set-DataGridFit, Enable-GridFit
