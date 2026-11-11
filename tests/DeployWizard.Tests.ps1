# Plain-PowerShell tests for the WinPE deploy wizard's logic (the WinForms window itself needs Windows).
# Run: pwsh -File tests/DeployWizard.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployWizard.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force

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

# Target disk: a Dell Latitude 5521 booted from a 64 GB stick that WinPE numbered disk 0. The Windows 11 check
# measured the stick (58 GB) and the answer file's default disk 0 would have been the one erased.
$stick = [pscustomobject]@{ Number = 0; FriendlyName = 'SanDisk Ultra'; Size = 58GB; BusType = 'USB' }
$ssd   = [pscustomobject]@{ Number = 1; FriendlyName = 'PM9A1 NVMe Samsung 512GB'; Size = 477GB; BusType = 'NVMe' }
$sata  = [pscustomobject]@{ Number = 2; FriendlyName = 'ST1000LM'; Size = 931GB; BusType = 'SATA' }
$card  = [pscustomobject]@{ Number = 3; FriendlyName = 'SD Card Reader'; Size = 0; BusType = 'SD' }
Assert-Equal ((Select-TargetDisks -Disks $stick, $ssd, $sata, $card) | ForEach-Object Number) '1 2' 'USB sticks and empty card readers are never targets'
Assert-Equal ((Select-TargetDisks -Disks $ssd, $sata -Exclude 2) | ForEach-Object Number) '1' 'the disk holding the content is never a target'
$t = Resolve-TargetDisk -Disks $stick, $ssd -Requested 0
Assert-Equal $t.Disk.Number 1 'answer file disk 0 on the USB stick resolves to the internal SSD'
Assert-Equal $t.Reason 'the answer file says disk 0, but disk 0 is a USB disk (0: SanDisk Ultra (58 GB, USB)); using the internal disk 1 instead' 'reason names the stick and the disk used'
Assert-Equal (Resolve-TargetDisk -Disks $stick, $sata, $ssd -Requested 0).Disk.Number 1 'NVMe is picked before SATA'
Assert-Equal (Resolve-TargetDisk -Disks $stick, $ssd, $sata -Requested 2).Disk.Number 2 'an internal disk the answer file names is kept'
Assert-Equal (Resolve-TargetDisk -Disks $ssd -Requested 5).Reason 'the answer file says disk 5, but there is no disk 5; using the internal disk 1 instead' 'missing disk number falls back'
$none = Resolve-TargetDisk -Disks $stick -Requested 0
Assert-Equal "$($null -eq $none.Disk)" 'True' 'no internal disk gives no target'
Assert-Equal "$($none.Reason -like '*no internal disk*WinPE sees: 0: SanDisk Ultra (58 GB, USB).*Intel RST/VMD*')" 'True' 'no internal disk says what WinPE sees and points at RST/VMD'
Assert-Equal ($none.Short.Length -le 110) $true 'no internal disk: the wizard line is short (details go to the log)'

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
Assert-Equal $lines[5] 'Joins:        domain corp.example.com (OU=Labs,DC=corp,DC=example,DC=com) as CORP\svc-join' 'summary shows the domain, OU and the account Windows signs in as'
$withDetails = [pscustomobject]@{ ImagePath = $plan.ImagePath; DriverPack = $null; Details = @('Firmware:     UEFI (GPT disk)') }
$lines = @(Get-DeploySummary -Answer $answer -Plan $withDetails -ComputerName 'LAB-01' -Disk $disk)
Assert-Equal "$($lines.Count)|$($lines[6])|$($lines[7])" '8|Firmware:     UEFI (GPT disk)|ERASE disk:   0: NVMe SSD (512 GB, NVMe)' 'plan details go just before the ERASE line'

# WinPE drivers: only the x64 ones from a pack with x86 and x64 folders (Dell's WinPE pack), all of a flat folder.
$pe = Join-Path ([IO.Path]::GetTempPath()) ("winpe-drivers-" + [guid]::NewGuid())
try {
    foreach ($f in 'winpe/x64/storage/iaStorVD.inf', 'winpe/x64/network/e1d.inf', 'winpe/x86/storage/iaStorVD.inf') {
        $path = Join-Path $pe $f
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content $path 'inf'
    }
    Assert-Equal ((Get-WinPEDriverInfs -Folder $pe | ForEach-Object Name) -join ',') 'e1d.inf,iaStorVD.inf' 'winpe drivers: x64 only when the pack has x86 too'
    Assert-Equal @(Get-WinPEDriverInfs -Folder (Join-Path $pe 'winpe/x86')).Count 1 'winpe drivers: a flat folder gives all its drivers'
    Assert-Equal @(Get-WinPEDriverInfs -Folder (Join-Path $pe 'missing')).Count 0 'winpe drivers: missing folder gives none'
}
finally { Remove-Item $pe -Recurse -Force -ErrorAction SilentlyContinue }

# Driver injection: /ForceUnsigned is a bare switch (":No" made DISM fail with error 87 on the Latitude 5521).
$a = @(Get-AddDriverArgs -ImageRoot 'W:\' -DriverPath 'E:\Drivers\Dell\Latitude 5521')
Assert-Equal ($a -join '|') '/Image:W:\|/Add-Driver|/Driver:E:\Drivers\Dell\Latitude 5521|/Recurse' 'add-driver: no /ForceUnsigned argument, path with a space is one argument'
Assert-Equal (@($a | Where-Object { $_ -match '^/ForceUnsigned:' }).Count) 0 'add-driver: never /ForceUnsigned:value'
Assert-Equal (@(Get-AddDriverArgs -ImageRoot 'W:\' -DriverPath 'E:\Drivers\Dell\Latitude 5521\')[2]) '/Driver:E:\Drivers\Dell\Latitude 5521' 'add-driver: trailing backslash removed'
Assert-Equal (@(Get-AddDriverArgs -ImageRoot 'W:\' -DriverPath 'E:\' -ForceUnsigned) -join '|') '/Image:W:\|/Add-Driver|/Driver:E:\|/Recurse|/ForceUnsigned' 'add-driver: drive root keeps its backslash; -ForceUnsigned is bare'

# No DISM call anywhere passes a value to a flag-only switch.
foreach ($f in Get-ChildItem (Join-Path $repo 'src') -Recurse -Include *.ps1, *.psm1) {
    $bad = @(Select-String -Path $f.FullName -Pattern "'/(ForceUnsigned|Recurse|CheckIntegrity|Verify|Commit|Discard|ResetBase):" -SimpleMatch:$false)
    Assert-Equal $bad.Count 0 "$($f.Name): no value on a flag-only DISM switch"
}

# Progress while drivers go into boot.wim: number, folder and name, elapsed time.
Assert-Equal (Format-DriverProgressLine -Index 5 -Total 76 -Path 'C:\Cache\Dell-WinPE11-A11\winpe\x64\storage\iaStorVD.inf' -Root 'C:\Cache\Dell-WinPE11-A11' -Elapsed ([TimeSpan]::FromSeconds(42))) '[ 5/76] storage\iaStorVD.inf  (0:42)' 'driver progress: number, folder, name, time'
Assert-Equal (Format-DriverProgressLine -Index 1 -Total 1 -Path 'D:\PE\net.inf' -Root 'D:\PE') '[1/1] net.inf  (0:00)' 'driver progress: file at the root has no folder'

# The log line saying which WinPE drivers the boot image has (config\winpe-drivers.json from the build).
Assert-Equal (Format-WinPEDriverReport $null) 'This boot image has no WinPE driver report: it was built before WinPE drivers were added. Rebuild the media.' 'winpe report: older build'
$report = [pscustomobject]@{ built = '2026-11-02 10:40'; vmd = $true; problem = $null
    sources = @([pscustomobject]@{ name = 'Dell WinPE 11 driver pack A11'; added = 87; failed = @('bad.inf') }) }
Assert-Equal (Format-WinPEDriverReport $report) 'WinPE drivers in this boot image (built 2026-11-02 10:40): Dell WinPE 11 driver pack A11: 87 added, 1 failed. Intel RST/VMD storage driver: yes.' 'winpe report: pack added with VMD'
$report = [pscustomobject]@{ built = '2026-11-02 10:40'; vmd = $false; problem = 'Dell WinPE driver pack not added: no internet.'; sources = @() }
Assert-Equal (Format-WinPEDriverReport $report) 'No extra WinPE drivers in this boot image (built 2026-11-02 10:40). Dell WinPE driver pack not added: no internet. Intel RST/VMD storage driver: NO, so an SSD behind VMD stays hidden.' 'winpe report: download failed'

# Sidebar text fits its labels even when the font renders wider than Segoe UI (WinPE cut off "Deploy Win").
if ($env:OS -eq 'Windows_NT') {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $form = New-Object Windows.Forms.Form
    try {
        $labels = New-DeploySidebar -Form $form
        Set-DeploySidebarStep -Labels $labels -Current 4
        $heading = $form.Controls[0].Controls[0]
        foreach ($l in @($heading) + @($labels)) {
            $width = [Windows.Forms.TextRenderer]::MeasureText($l.Text, $l.Font).Width
            Assert-Equal ($width -le $l.Width) $true "sidebar: '$($l.Text)' fits ($width of $($l.Width) px)"
        }
        $wide = New-Object Windows.Forms.Label -Property @{ Width = 120; Text = 'Install Windows on this PC'; Font = New-Object Drawing.Font('Arial', 14) }
        Set-FittingFont -Label $wide
        Assert-Equal ($wide.Font.Size -lt 14) $true 'Set-FittingFont shrinks text that is too wide'
    }
    finally { $form.Dispose() }
} else { Write-Host 'SKIP WinForms sidebar (not Windows)' }

# Every script and module still parses (the wizard is only exercised on Windows).
foreach ($f in Get-ChildItem (Join-Path $repo 'src') -Recurse -Include *.ps1, *.psm1) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    Assert-Equal (@($errors).Count) 0 "$($f.Name) parses"
}

# Windows 11 check in Block mode: the wizard says how to go on (Install anyway), other errors stay as they are.
$blocked = New-Object System.InvalidOperationException 'Not ready for Windows 11 (Processor). Nothing was erased; see the log.'
$blocked.Data['Windows11Block'] = 'Processor'
Assert-Equal (Get-WizardErrorText -Exception $blocked) 'Not ready for Windows 11 (Processor). Nothing was erased. Tick Install anyway to continue, or see the log.' 'Windows 11 block offers Install anyway'
Assert-Equal (Get-WizardErrorText -Exception (New-Object System.Exception 'Pick the disk to install Windows on.')) 'Pick the disk to install Windows on.' 'other errors are shown as they are'
$wizSrc = Get-Content -Raw (Join-Path $repo 'src/DeployWizard.psm1')
Assert-Equal ($wizSrc -match '\$w\.PreparePlan \$w\.Answer \$w\.Win11Anyway\.Checked') $true 'wizard passes Install anyway to the plan'
$deploySrc = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($deploySrc -match "Data\['Windows11Block'\]") $true 'Deploy-Image marks the Windows 11 block for the wizard'
Assert-Equal ($deploySrc -match '-IgnoreWin11 \(\$IgnoreWindows11Check\.IsPresent -or \$IgnoreWin11\)') $true 'Install anyway from the wizard skips the block'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
