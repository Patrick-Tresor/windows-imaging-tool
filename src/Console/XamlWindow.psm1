# Loading the console's WPF windows: every window gets the shared styles in Styles.xaml, wheel scrolling
# (WheelScroll.psm1) and a map of its named controls.

Import-Module (Join-Path $PSScriptRoot 'WheelScroll.psm1')

$script:XamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'

function Read-ConsoleXaml {
    # A window's XAML with Styles.xaml merged into its resources. The window's own styles come after the shared
    # ones, so they win, and BasedOn="{StaticResource {x:Type Button}}" in a window builds on the shared style.
    # <ResourceDictionary Source="FormStyles.xaml"/> in the window's resources is replaced by that file's styles.
    param([Parameter(Mandatory)][string]$Path)
    [xml]$xaml = Get-Content -Raw -LiteralPath $Path
    [xml]$shared = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Styles.xaml')
    $root = $xaml.DocumentElement
    $ns = $root.NamespaceURI
    $resName = "$($root.LocalName).Resources"
    $res = @($root.ChildNodes | Where-Object { $_.LocalName -eq $resName })[0]
    if (-not $res) { $res = $root.PrependChild($xaml.CreateElement($resName, $ns)) }
    $dict = $xaml.CreateElement('ResourceDictionary', $ns)
    $merged = $dict.AppendChild($xaml.CreateElement('ResourceDictionary.MergedDictionaries', $ns))
    [void]$merged.AppendChild($xaml.ImportNode($shared.DocumentElement, $true))
    foreach ($child in @($res.ChildNodes)) {
        if ($child.LocalName -eq 'ResourceDictionary' -and $child.GetAttribute('Source')) {
            [xml]$part = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot $child.GetAttribute('Source'))
            foreach ($style in @($part.DocumentElement.ChildNodes | Where-Object NodeType -eq 'Element')) { [void]$dict.AppendChild($xaml.ImportNode($style, $true)) }
        } else { [void]$dict.AppendChild($child) }
    }
    [void]$res.AppendChild($dict)
    $xaml
}

function Get-XamlControls {
    # Name -> control, for every x:Name in the window's XAML.
    param([Parameter(Mandatory)][xml]$Xaml, [Parameter(Mandatory)]$Window)
    $map = @{}
    foreach ($node in $Xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', $script:XamlNs)
        if ($name) { $map[$name] = $Window.FindName($name) }
    }
    $map
}

function New-ConsoleWindow {
    # Loads src\Console\<Name>, with the shared styles, wheel scrolling and -Owner. Returns Window and Controls.
    param([Parameter(Mandatory)][string]$Name, $Owner)
    $xaml = Read-ConsoleXaml -Path (Join-Path $PSScriptRoot $Name)
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
    if ($Owner) { $window.Owner = $Owner }
    Enable-WheelScrolling $window
    [pscustomobject]@{ Window = $window; Controls = (Get-XamlControls -Xaml $xaml -Window $window) }
}

Export-ModuleMember -Function Read-ConsoleXaml, Get-XamlControls, New-ConsoleWindow
