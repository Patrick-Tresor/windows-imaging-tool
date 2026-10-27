# Plain-PowerShell tests for the post-deploy checks. Run: pwsh -File tests/PostDeployChecks.Tests.ps1
# Works on Windows and Linux (facts are built by hand); exits non-zero if any check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/PostDeployChecks.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployStatus.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function Get-Result($Results, $Name) { ($Results | Where-Object name -eq $Name).result }

$answer = [pscustomobject]@{ Name = 'Lab'; Membership = 'Domain'; Domain = 'corp.example.com'; Workgroup = 'WORKGROUP' }
$apps = @(
    [pscustomobject]@{ name = 'Chrome'; command = 'x'; successCodes = @(0); detect = [pscustomobject]@{ displayName = 'Google Chrome*' } }
    [pscustomobject]@{ name = 'Zoom'; command = 'x'; successCodes = @(0); detect = $null }
)

# Plan
$plan = New-PostDeployCheckPlan -Answer $answer -ComputerName 'LAB-5CG1234567890' -AppDefinitions $apps
Assert-Equal "$($plan.membership)|$($plan.domain)|$($plan.bitLocker)|$($plan.deviceErrors)" 'Domain|corp.example.com|Report|Required' 'defaults: devices required, BitLocker reported without an answer file BitLocker section'
Assert-Equal ($plan.applications.name -join ',') 'Chrome,Zoom' 'plan lists the applications'
$bl = [pscustomobject]@{ Name = 'Lab'; Membership = 'Workgroup'; Workgroup = 'LAB'; BitLocker = [pscustomobject]@{ Enabled = $true } }
Assert-Equal (New-PostDeployCheckPlan -Answer $bl).bitLocker 'Required' 'Auto requires BitLocker when the answer file turns it on'
$off = [pscustomobject]@{ checks = [pscustomobject]@{ enabled = $false } }
Assert-Equal ($null -eq (New-PostDeployCheckPlan -Answer $answer -Settings $off)) $true 'checks can be turned off in deploy settings'
$tuned = [pscustomobject]@{ checks = [pscustomobject]@{ bitLocker = 'Off'; deviceErrors = 'Report'; ignoreDevices = @('*Smart Card*') } }
$p2 = New-PostDeployCheckPlan -Answer $answer -Settings $tuned -AppDefinitions $apps
Assert-Equal "$($p2.bitLocker)|$($p2.deviceErrors)|$($p2.ignoreDevices -join ',')" 'Off|Report|*Smart Card*' 'deploy settings tune the checks'

# A healthy PC
$good = [pscustomobject]@{
    ComputerName = 'LAB-5CG12345678'; PartOfDomain = $true; Domain = 'corp.example.com'; SecureChannel = $true
    ProblemDevices = @([pscustomobject]@{ Name = 'Disabled NIC'; DeviceId = 'PCI\X'; ErrorCode = 22 })
    InstalledPrograms = @('Google Chrome', 'Zoom Workplace')
    BitLocker = [pscustomobject]@{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On'; EncryptionPercentage = 100; Protectors = @('Tpm', 'RecoveryPassword') }
}
$appRuns = @([pscustomobject]@{ name = 'Chrome'; exitCode = 0; ok = $true }, [pscustomobject]@{ name = 'Zoom'; exitCode = 3010; ok = $true })
$r = Invoke-PostDeployCheck -Plan $plan -Facts $good -AppResults $appRuns
Assert-Equal (($r | ForEach-Object { "$($_.name)=$($_.result)" }) -join ';') 'Computer name=Passed;Domain join=Passed;Device drivers=Passed;App: Chrome=Passed;App: Zoom=Passed;BitLocker=Passed' 'healthy PC passes every check (name cut to 15, disabled device ignored)'
$sum = Get-PostDeployCheckSummary -Results $r
Assert-Equal "$($sum.Result)|$($sum.Text)" 'Passed|Passed 6/6' 'summary of a healthy PC'
Assert-Equal ($null -eq (ConvertTo-CheckWarning $sum)) $true 'no warning when checks pass'

# A PC with problems
$bad = [pscustomobject]@{
    ComputerName = 'MINWINPC'; PartOfDomain = $false; Domain = 'WORKGROUP'; SecureChannel = $null
    ProblemDevices = @(
        [pscustomobject]@{ Name = 'PCI Simple Communications Controller'; DeviceId = 'PCI\VEN_8086'; ErrorCode = 28 }
        [pscustomobject]@{ Name = 'Smart Card Reader'; DeviceId = 'USB\VID_1'; ErrorCode = 28 }
    )
    InstalledPrograms = @('Zoom Workplace')
    BitLocker = [pscustomobject]@{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off'; EncryptionPercentage = 0; Protectors = @() }
}
$runs = @([pscustomobject]@{ name = 'Chrome'; exitCode = 0; ok = $true }, [pscustomobject]@{ name = 'Zoom'; exitCode = 1603; ok = $false })
$r = Invoke-PostDeployCheck -Plan $plan -Facts $bad -AppResults $runs
Assert-Equal (Get-Result $r 'Computer name') 'Failed' 'wrong name fails'
Assert-Equal (Get-Result $r 'Domain join') 'Failed' 'not joined fails'
Assert-Equal (($r | Where-Object name -eq 'Device drivers').detail) '2 device(s) with errors: PCI Simple Communications Controller (code 28), Smart Card Reader (code 28)' 'device errors are listed'
Assert-Equal (Get-Result $r 'App: Chrome') 'Failed' 'exit code 0 but not installed fails the detection rule'
Assert-Equal (($r | Where-Object name -eq 'App: Zoom').detail) 'Installer exit code 1603' 'a failed installer fails its check'
Assert-Equal (Get-Result $r 'BitLocker') 'Warning' 'BitLocker off is a warning when only reported'
$sum = Get-PostDeployCheckSummary -Results $r
Assert-Equal $sum.Text 'Failed 0/6: Computer name, Domain join, Device drivers, App: Chrome, App: Zoom, BitLocker' 'summary names failed then warned checks'
Assert-Equal (ConvertTo-CheckWarning $sum) "Post-deploy checks: $($sum.Text)" 'failed checks become a deployment warning'

$p2.computerName = $null
$r = Invoke-PostDeployCheck -Plan $p2 -Facts $bad -AppResults @($runs[0])
Assert-Equal (Get-Result $r 'Device drivers') 'Warning' 'Report mode turns device errors into a warning'
Assert-Equal (($r | Where-Object name -eq 'Device drivers').detail) '1 device(s) with errors: PCI Simple Communications Controller (code 28)' 'ignored devices are left out'
Assert-Equal ($null -eq ($r | Where-Object name -eq 'BitLocker')) $true 'BitLocker Off skips the check'
Assert-Equal ($null -eq ($r | Where-Object name -eq 'Computer name')) $true 'no expected name, no name check'
Assert-Equal (Get-Result $r 'App: Zoom') 'Failed' 'an app with no run result did not run'

# Edge cases
$joined = $good.PSObject.Copy(); $joined.Domain = 'CORP'; $joined.SecureChannel = $false
$r = Invoke-PostDeployCheck -Plan $plan -Facts $joined -AppResults $appRuns
Assert-Equal (Get-Result $r 'Domain join') 'Warning' 'joined (NetBIOS name matches) but no DC answered is a warning'
$enc = $good.PSObject.Copy(); $enc.BitLocker = [pscustomobject]@{ VolumeStatus = 'EncryptionInProgress'; ProtectionStatus = 'Off'; EncryptionPercentage = 40; Protectors = @('Tpm') }
$req = $plan.PSObject.Copy(); $req.bitLocker = 'Required'
$r = Invoke-PostDeployCheck -Plan $req -Facts $enc -AppResults $appRuns
Assert-Equal (($r | Where-Object name -eq 'BitLocker').detail) 'Encrypting, 40 % done (Tpm)' 'encryption in progress with a protector passes'
$enc.BitLocker = $null
Assert-Equal (Get-Result (Invoke-PostDeployCheck -Plan $req -Facts $enc -AppResults $appRuns) 'BitLocker') 'Failed' 'required BitLocker with no status fails'
$wg = [pscustomobject]@{ membership = 'Workgroup'; workgroup = 'LAB'; deviceErrors = 'Off'; applications = @() }
Assert-Equal (Get-Result (Invoke-PostDeployCheck -Plan $wg -Facts $good) 'Workgroup') 'Failed' 'a workgroup PC that joined a domain fails'
Assert-Equal (Get-PostDeployCheckSummary -Results @()).Result 'None' 'no checks, no result'

# Dashboard: results on the status record, and a re-run that passes clears the warning
$root = Join-Path ([IO.Path]::GetTempPath()) ("checks-test-" + [guid]::NewGuid())
try {
    $folder = Join-Path $root 'Status'
    $hw = [pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5440'; Serial = 'ABC123' }
    $null = Start-DeployStatus -Folder $folder -Identity $hw -LogPath @()
    $failed = Invoke-PostDeployCheck -Plan $plan -Facts $bad -AppResults $appRuns
    $fs = Get-PostDeployCheckSummary -Results $failed
    Set-DeployCheckResult -Results $failed -Summary $fs -Warning (ConvertTo-CheckWarning $fs)
    Set-DeployStatus -Step 'Deployment complete' -Percent 100 -State Succeeded
    $row = @(Get-DeploymentStatus -Folder $folder)[0]
    Assert-Equal "$($row.State)|$($row.CheckResult)|$(@($row.CheckResults).Count)" 'Warning|Failed|6' 'failed checks show on the dashboard and make the deployment a Warning'
    Assert-Equal $row.Checks $fs.Text 'the Checks column shows the summary'
    $utc = { param($d) ([datetime]$d).ToUniversalTime().ToString('s') }    # PowerShell 7 reads ISO dates back as DateTime
    $finished = & $utc (Get-DeployStatusRecord).finished

    Import-Module (Join-Path $repo 'src/DeployStatus.psm1') -Force    # Test-Deployment.ps1 runs in a new process
    $null = Resume-DeployStatus -Folder $folder -Id 'ABC123'
    $passed = Invoke-PostDeployCheck -Plan $plan -Facts $good -AppResults $appRuns
    $ps = Get-PostDeployCheckSummary -Results $passed
    Set-DeployCheckResult -Results $passed -Summary $ps -Warning (ConvertTo-CheckWarning $ps)
    $row = @(Get-DeploymentStatus -Folder $folder)[0]
    Assert-Equal "$($row.State)|$($row.CheckResult)|$($row.Warnings)" 'Succeeded|Passed|' 'a passing re-run clears the check warning'
    Assert-Equal (& $utc (Get-DeployStatusRecord).finished) $finished 'a re-run keeps the finish time'
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
