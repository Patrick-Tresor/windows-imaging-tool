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
            [void]$res.RemoveChild($child)
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

function Set-ConsoleLogo {
    # The tool's logo (src\Assets): the window's icon, and the picture of an Image named ImgLogo in the window.
    # A missing or unreadable file leaves the window without it.
    param([Parameter(Mandatory)]$Window, [hashtable]$Controls = @{})
    $assets = [IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'Assets')
    try {
        $ico = [IO.Path]::Combine($assets, 'logo.ico')
        if ([IO.File]::Exists($ico)) { $Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ico)) }
        $png = [IO.Path]::Combine($assets, 'logo.png')
        if ($Controls['ImgLogo'] -and [IO.File]::Exists($png)) {
            $bmp = New-Object Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = [Uri]::new($png); $bmp.EndInit()
            $Controls['ImgLogo'].Source = $bmp
        }
    } catch { }
}

function New-ConsoleWindow {
    # Loads src\Console\<Name>, with the shared styles, wheel scrolling and -Owner. Returns Window and Controls.
    param([Parameter(Mandatory)][string]$Name, $Owner)
    $xaml = Read-ConsoleXaml -Path (Join-Path $PSScriptRoot $Name)
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
    if ($Owner) { $window.Owner = $Owner }
    Enable-WheelScrolling $window
    $controls = Get-XamlControls -Xaml $xaml -Window $window
    Set-ConsoleLogo -Window $window -Controls $controls
    [pscustomobject]@{ Window = $window; Controls = $controls }
}

function Show-WindowMessage {
    # A message box over a console window: Show-WindowMessage $dlg 'Update Image' 'Add at least one update package.'
    param([Parameter(Mandatory)]$Owner, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Text, [string]$Icon = 'Warning')
    [void][Windows.MessageBox]::Show($Owner, $Text, $Title, 'OK', $Icon)
}

#region Library editors (Application and Task windows)

function ConvertFrom-ListText {
    # "Dell, HP" -> Dell, HP. -Numbers: "0, 3010; 1641" -> 0, 3010, 1641 (commas, semicolons or spaces).
    param([AllowEmptyString()][string]$Text, [switch]$Numbers)
    if ($Numbers) { return @($Text -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
    @($Text -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Set-RequirementBoxes {
    # Fills the Makers and Models boxes (TxtMakers, TxtModels) from a definition's requirements.
    param([Parameter(Mandatory)]$Controls, [Parameter(Mandatory)]$Definition)
    $Controls.TxtMakers.Text = @($Definition.requirements.makers) -join ', '
    $Controls.TxtModels.Text = @($Definition.requirements.models) -join ', '
}

function Get-RequirementBoxes {
    # The requirements as typed in the Makers and Models boxes.
    param([Parameter(Mandatory)]$Controls)
    [pscustomobject]@{ makers = @(ConvertFrom-ListText $Controls.TxtMakers.Text); models = @(ConvertFrom-ListText $Controls.TxtModels.Text) }
}

function Initialize-TemplatePicker {
    # Lists the templates in CmbTemplate after "(none)" and shows the picked one's note in TxtTemplateNote.
    # -Note { param($Template) } gives the note; "Best guess, test it on a VM first." goes in front for a template to verify.
    param([Parameter(Mandatory)]$Controls, [object[]]$Templates = @(), [scriptblock]$Note = { param($t) "$($t.notes)" })
    $c = $Controls
    $list = @($Templates)
    $c.CmbTemplate.ItemsSource = @('(none)') + @($list | ForEach-Object { "$($_.name)$(if ($_.verify) { ' (verify)' })" })
    $c.CmbTemplate.SelectedIndex = 0
    $c.CmbTemplate.Add_SelectionChanged({
        # Inline, not Get-PickedTemplate: this closure does not see the module's functions.
        $i = $c.CmbTemplate.SelectedIndex
        $t = if ($i -gt 0) { $list[$i - 1] }
        $c.TxtTemplateNote.Text = if ($t) { "$(if ($t.verify) { 'Best guess, test it on a VM first. ' })$(& $Note $t)" } else { '' }
    }.GetNewClosure())
}

function Get-PickedTemplate {
    # The template picked in CmbTemplate, or $null for "(none)".
    param([Parameter(Mandatory)]$Controls, [object[]]$Templates = @())
    $i = $Controls.CmbTemplate.SelectedIndex
    if ($i -gt 0) { @($Templates)[$i - 1] }
}

function Register-SourceBrowse {
    # File... and Folder... (BtnSourceFile, BtnSourceFolder) put the path in TxtSource, then run -After.
    param([Parameter(Mandatory)]$Controls, [Parameter(Mandatory)]$Owner, [Parameter(Mandatory)][string]$Filter,
          [Parameter(Mandatory)][string]$FolderText, [scriptblock]$After = { })
    $c = $Controls
    $c.BtnSourceFile.Add_Click({
        $f = [Microsoft.Win32.OpenFileDialog]::new()
        $f.Filter = $Filter
        if ($f.ShowDialog($Owner)) { $c.TxtSource.Text = $f.FileName; & $After }
    }.GetNewClosure())
    $c.BtnSourceFolder.Add_Click({
        $f = [Windows.Forms.FolderBrowserDialog]::new()
        $f.Description = $FolderText
        if ($f.ShowDialog() -eq 'OK') { $c.TxtSource.Text = $f.SelectedPath; & $After }
    }.GetNewClosure())
}

#endregion

Export-ModuleMember -Function Read-ConsoleXaml, Get-XamlControls, Set-ConsoleLogo, New-ConsoleWindow, Show-WindowMessage,
    ConvertFrom-ListText, Set-RequirementBoxes, Get-RequirementBoxes, Initialize-TemplatePicker, Get-PickedTemplate, Register-SourceBrowse
