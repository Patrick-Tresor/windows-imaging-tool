# Plain-PowerShell tests for what the Application and Task editor windows share (XamlWindow.psm1): the list boxes
# and the Makers / Models boxes. Run: pwsh -File tests/LibraryEditors.Tests.ps1. No window is opened.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/XamlWindow.psm1') -Force
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Assert-Equal ((ConvertFrom-ListText ' Dell ,HP,, Lenovo ') -join '|') 'Dell|HP|Lenovo' 'list: trimmed, empty items left out'
Assert-Equal @(ConvertFrom-ListText '').Count 0 'list: empty text is an empty list'
Assert-Equal ((ConvertFrom-ListText '0, 3010;1641 ' -Numbers) -join '|') '0|3010|1641' 'codes: commas, semicolons or spaces'
Assert-Equal ((ConvertFrom-ListText '0' -Numbers)[0].GetType().Name) 'Int32' 'codes are numbers'

$boxes = [pscustomobject]@{ TxtMakers = [pscustomobject]@{ Text = '' }; TxtModels = [pscustomobject]@{ Text = '' } }
Set-RequirementBoxes -Controls $boxes -Definition ([pscustomobject]@{ requirements = [pscustomobject]@{ makers = @('Dell', 'HP'); models = @('Latitude*') } })
Assert-Equal "$($boxes.TxtMakers.Text)|$($boxes.TxtModels.Text)" 'Dell, HP|Latitude*' 'requirements fill the boxes'
$boxes.TxtModels.Text = ''
$r = Get-RequirementBoxes -Controls $boxes
Assert-Equal "$($r.makers -join ',')|$(@($r.models).Count)" 'Dell,HP|0' 'the boxes give the requirements back'
Assert-Equal (($r | ConvertTo-Json -Compress) -match '"models":\[\]') $true 'no models is [] in JSON, not {}'

$picker = [pscustomobject]@{ CmbTemplate = [pscustomobject]@{ SelectedIndex = 2 } }
Assert-Equal (Get-PickedTemplate -Controls $picker -Templates @([pscustomobject]@{ name = 'A' }, [pscustomobject]@{ name = 'B' })).name 'B' 'picked template: index 0 is (none)'
$picker.CmbTemplate.SelectedIndex = 0
Assert-Equal $null (Get-PickedTemplate -Controls $picker -Templates @([pscustomobject]@{ name = 'A' })) 'picked template: (none) is nothing'

# Both editors use them, and no longer carry their own copies.
foreach ($f in 'AppPackEditor.ps1', 'TaskEditor.ps1') {
    $text = Get-Content -Raw (Join-Path $repo "src/Console/$f")
    Assert-Equal ($text.Contains('Register-SourceBrowse') -and $text.Contains('Initialize-TemplatePicker') -and $text.Contains('Get-RequirementBoxes')) $true "$f uses the shared editor helpers"
    Assert-Equal ($text.Contains('OpenFileDialog') -or $text.Contains("-split '[,; ]+'")) $false "$f has no copy of its own"
}

Complete-Tests 'All library editor checks passed.'
