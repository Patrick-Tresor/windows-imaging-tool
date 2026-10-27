# Mouse wheel scrolling for the console windows.
# WPF hands the wheel to the innermost grid, list or text box under the pointer, and that control keeps it even when
# it has nothing left to scroll. So a page that holds a grid stops scrolling while the pointer is over the grid, and a
# grid that is already at its end blocks the page around it. Enable-WheelScrolling sends each wheel turn to the
# nearest scroll area under the pointer that can still move that way: the grid first, then the page.

# The nearest ScrollViewer at or above $Source that can still scroll in the wheel's direction, or $null.
# $Delta is the wheel delta: above 0 scrolls up, below 0 scrolls down.
function Get-WheelScrollTarget($Source, [double]$Delta) {
    $node = $Source
    while ($null -ne $node) {
        if ($node -is [Windows.Controls.ScrollViewer] -and $node.ScrollableHeight -gt 0) {
            if ($Delta -gt 0 -and $node.VerticalOffset -gt 0.5) { return $node }
            if ($Delta -lt 0 -and $node.VerticalOffset -lt $node.ScrollableHeight - 0.5) { return $node }
        }
        # An open drop-down list lives in its own popup: never scroll the page behind it.
        if ($node.GetType().Name -eq 'PopupRoot') { return $null }
        $parent = $null
        if ($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]) {
            $parent = [Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        # Text runs and other content elements are not visuals; their logical parent is.
        if ($null -eq $parent -and $node -is [Windows.DependencyObject]) { $parent = [Windows.LogicalTreeHelper]::GetParent($node) }
        $node = $parent
    }
    $null
}

# Scrolls $ScrollViewer by one wheel turn of $Delta, as far as Windows' "lines per notch" setting says.
function Invoke-WheelScroll([Windows.Controls.ScrollViewer]$ScrollViewer, [double]$Delta) {
    $lines = [Windows.SystemParameters]::WheelScrollLines
    if ($lines -lt 0) {
        # Windows is set to scroll one screen at a time.
        if ($Delta -gt 0) { $ScrollViewer.PageUp() } else { $ScrollViewer.PageDown() }
        return
    }
    # Precision touchpads send small deltas; scroll at least one line for each.
    $count = [Math]::Max(1, [int][Math]::Round([Math]::Abs($Delta) * $lines / 120))
    for ($i = 0; $i -lt $count; $i++) {
        if ($Delta -gt 0) { $ScrollViewer.LineUp() } else { $ScrollViewer.LineDown() }
    }
}

function Enable-WheelScrolling([Windows.Window]$Window) {
    $Window.Add_PreviewMouseWheel({
        param($s, $e)
        try {
            # Ctrl+wheel is zoom, not scrolling.
            if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) { return }
            $target = Get-WheelScrollTarget $e.OriginalSource $e.Delta
            if ($target) {
                Invoke-WheelScroll $target $e.Delta
                $e.Handled = $true
            }
        } catch { }
    })
}

Export-ModuleMember -Function Get-WheelScrollTarget, Invoke-WheelScroll, Enable-WheelScrolling
