# Plain-PowerShell tests for the WinPE deploy wizard's logic (the WinForms window itself needs Windows).
# Run: pwsh -File tests/DeployWizard.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployWizard.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Computer names.
Assert-Equal (Test-ComputerNameValue 'LAB-PC-042') '' 'valid name passes'
Assert-Equal (Test-ComputerNameValue '') 'Type a computer name.' 'empty name is rejected'
Assert-Equal (Test-ComputerNameValue 'ABCDEFGHIJKLMNOP') 'A computer name can have at most 15 characters.' '16 characters is too long'
Assert-Equal (Test-ComputerNameValue 'PC_01') 'Use only letters, digits and dashes.' 'underscore is rejected'
Assert-Equal (Test-ComputerNameValue '12345') 'A computer name cannot be only digits.' 'all digits is rejected'
Assert-Equal (Test-ComputerNameValue '-PC') 'A computer name cannot start or end with a dash.' 'leading dash is rejected'

# Disks.
$disk = [pscustomobject]@{ Number = 0; FriendlyName = 'NVMe SSD '; Size = 512GB; BusType = 'NVMe' }
Assert-Equal (Format-DiskChoice $disk) '0: NVMe SSD (512 GB, NVMe)' 'disk line shows number, name, size and bus'

# Applications: answer file's in its order and ticked, then the rest of the library sorted and unticked.
$choices = @(Get-AppChoices -Selected 'Office', 'Zoom' -Available 'Zoom', 'Adobe-Reader', 'Office', '7-Zip')
Assert-Equal (($choices | ForEach-Object { "$($_.Name)=$($_.Checked)" }) -join ',') 'Office=True,Zoom=True,7-Zip=False,Adobe-Reader=False' 'app choices keep order and tick the answer file''s'
Assert-Equal @(Get-AppChoices -Selected @() -Available @()).Count 0 'no applications gives no choices'

# Summary.
$answer = Read-AnswerFile -Path (Join-Path $repo 'config/answer-files/Default.xml')
$plan = [pscustomobject]@{ ImagePath = 'D:\Images\Win11-Enterprise.wim'; DriverPack = $null }
$lines = @(Get-DeploySummary -Answer $answer -Plan $plan -ComputerName 'LAB-01' -Disk $disk -Applications @())
Assert-Equal $lines.Count 7 'summary has seven lines'
Assert-Equal $lines[2] 'Drivers:      inbox only' 'summary says inbox drivers when no pack matches'
Assert-Equal $lines[5] 'Joins:        workgroup WORKGROUP' 'summary shows the workgroup'
Assert-Equal $lines[6] 'ERASE disk:   0: NVMe SSD (512 GB, NVMe)' 'summary names the disk to erase'

$domain = $answer.PSObject.Copy()
$domain.Membership = 'Domain'; $domain.OrganizationalUnit = 'OU=Labs,DC=corp,DC=example,DC=com'
$lines = @(Get-DeploySummary -Answer $domain -Plan $plan -ComputerName 'LAB-01' -Disk $disk -Applications 'Office', 'Zoom')
Assert-Equal $lines[3] 'Applications: Office, Zoom' 'summary lists the chosen applications'
Assert-Equal $lines[5] 'Joins:        domain corp.example.com (OU=Labs,DC=corp,DC=example,DC=com)' 'summary shows the domain and OU'
$withDetails = [pscustomobject]@{ ImagePath = $plan.ImagePath; DriverPack = $null; Details = @('Firmware:     UEFI (GPT disk)') }
$lines = @(Get-DeploySummary -Answer $answer -Plan $withDetails -ComputerName 'LAB-01' -Disk $disk)
Assert-Equal "$($lines.Count)|$($lines[6])|$($lines[7])" '8|Firmware:     UEFI (GPT disk)|ERASE disk:   0: NVMe SSD (512 GB, NVMe)' 'plan details go just before the ERASE line'

# Every script and module still parses (the wizard is only exercised on Windows).
foreach ($f in Get-ChildItem (Join-Path $repo 'src') -Recurse -Include *.ps1, *.psm1) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    Assert-Equal (@($errors).Count) 0 "$($f.Name) parses"
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
