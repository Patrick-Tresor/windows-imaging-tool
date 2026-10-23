# Post-deploy checks: after first boot, confirm the PC is ready (name, domain join, no device driver errors,
# applications installed, BitLocker on) and report pass/fail per check to the dashboard.
# Get-PostDeployFacts reads the PC (Windows only); everything else is plain data so it can be tested without Windows.
# PowerShell 5.1 compatible.

#region Plan (WinPE)

function New-PostDeployCheckPlan {
    # What the deployed PC should look like, written into firstboot.json by Deploy-Image.ps1.
    # Settings come from deploy-settings.json "checks"; missing settings mean every check is on.
    #   bitLocker: Auto (Required when the answer file turns BitLocker on, Report otherwise), Required, Report or Off.
    #   deviceErrors: Required, Report or Off. ignoreDevices: wildcards matched against device names and ids.
    param(
        [Parameter(Mandatory)]$Answer,
        [string]$ComputerName,
        [object[]]$AppDefinitions = @(),
        $Settings
    )
    $c = if ($Settings -and $Settings.PSObject.Properties['checks']) { $Settings.checks } else { $null }
    $get = { param($name, $default) if ($c -and $c.PSObject.Properties[$name] -and $null -ne $c.$name -and "$($c.$name)" -ne '') { $c.$name } else { $default } }
    if (-not (ConvertTo-CheckBool (& $get 'enabled' $true))) { return $null }

    $bitLocker = & $get 'bitLocker' 'Auto'
    if ($bitLocker -eq 'Auto') {
        # The answer file's <bitlocker> section, when present, decides whether encryption is expected.
        $encrypts = $Answer.PSObject.Properties['BitLocker'] -and $Answer.BitLocker -and $Answer.BitLocker.Enabled
        $bitLocker = if ($encrypts) { 'Required' } else { 'Report' }
    }
    [pscustomobject]@{
        computerName  = $ComputerName
        membership    = $Answer.Membership
        domain        = if ($Answer.Membership -eq 'Domain') { $Answer.Domain } else { $null }
        workgroup     = if ($Answer.Membership -ne 'Domain') { $Answer.Workgroup } else { $null }
        bitLocker     = $bitLocker
        deviceErrors  = & $get 'deviceErrors' 'Required'
        ignoreDevices = @(& $get 'ignoreDevices' @())
        applications  = @($AppDefinitions | ForEach-Object {
            [pscustomobject]@{ name = $_.name; detect = if ($_.PSObject.Properties['detect']) { $_.detect } else { $null } }
        })
    }
}

function ConvertTo-CheckBool($Value) {
    if ($Value -is [bool]) { return $Value }
    "$Value" -notmatch '^(false|0|no|off)$'
}

#endregion

#region Facts (the deployed PC)

function Get-PostDeployFacts {
    # Reads what the checks need. Each part is independent: one that cannot be read is $null and its check says so.
    $facts = [ordered]@{
        ComputerName = $env:COMPUTERNAME; PartOfDomain = $null; Domain = $null; SecureChannel = $null
        ProblemDevices = $null; InstalledPrograms = $null; BitLocker = $null
    }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $facts.ComputerName = $cs.Name
        $facts.PartOfDomain = [bool]$cs.PartOfDomain
        $facts.Domain = $cs.Domain       # the domain's DNS name when joined, the workgroup name otherwise
    } catch { }
    if ($facts.PartOfDomain) {
        # Joined is not enough: the computer account's secure channel must work, or nobody can log on with a domain account.
        try { $facts.SecureChannel = [bool](Test-ComputerSecureChannel -ErrorAction Stop) } catch { $facts.SecureChannel = $false }
    }
    try {
        # ConfigManagerErrorCode is the Device Manager error (28 = no driver, 10 = cannot start, 43 = stopped, ...).
        $facts.ProblemDevices = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; DeviceId = $_.PNPDeviceID; ErrorCode = [int]$_.ConfigManagerErrorCode } })
    } catch { }
    $facts.InstalledPrograms = @(
        foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                         'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
                ForEach-Object DisplayName
        }
    )
    try {
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $facts.BitLocker = [pscustomobject]@{
            VolumeStatus         = "$($v.VolumeStatus)"         # FullyEncrypted, EncryptionInProgress, FullyDecrypted, ...
            ProtectionStatus     = "$($v.ProtectionStatus)"     # On, Off
            EncryptionPercentage = [int]$v.EncryptionPercentage
            Protectors           = @($v.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })
        }
    } catch { }
    [pscustomobject]$facts
}

#endregion

#region Evaluation

function Invoke-PostDeployCheck {
    # Compares the facts with the plan. One result per check: Passed, Failed, Warning (a Report-only check that
    # did not pass, or something worth a look) or Skipped. AppResults are FirstBoot.ps1's install exit codes.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Facts,
        [object[]]$AppResults = @()
    )
    $results = [Collections.Generic.List[object]]::new()
    $add = { param($name, $result, $detail) $results.Add([pscustomobject]@{ name = $name; result = $result; detail = $detail }) }

    # Computer name. Windows cuts names to 15 characters.
    if ($Plan.computerName) {
        $want = $Plan.computerName.Substring(0, [Math]::Min(15, $Plan.computerName.Length))
        if ($Facts.ComputerName -ieq $want) { & $add 'Computer name' 'Passed' $Facts.ComputerName }
        else { & $add 'Computer name' 'Failed' "Named $($Facts.ComputerName), expected $want" }
    }

    # Domain or workgroup membership.
    if ($Plan.membership -eq 'Domain') {
        $short = { param($d) "$d".Split('.')[0] }
        if ($null -eq $Facts.PartOfDomain) { & $add 'Domain join' 'Failed' 'Could not read domain membership' }
        elseif (-not $Facts.PartOfDomain) { & $add 'Domain join' 'Failed' "Not joined to $($Plan.domain) (in workgroup $($Facts.Domain)); see C:\Windows\Debug\NetSetup.log" }
        elseif ($Facts.Domain -ine $Plan.domain -and (& $short $Facts.Domain) -ine (& $short $Plan.domain)) {
            & $add 'Domain join' 'Failed' "Joined to $($Facts.Domain), expected $($Plan.domain)"
        }
        elseif ($Facts.SecureChannel -eq $false) { & $add 'Domain join' 'Warning' "Joined to $($Facts.Domain), but no domain controller answered (secure channel test failed)" }
        else { & $add 'Domain join' 'Passed' "Joined to $($Facts.Domain)" }
    } elseif ($Plan.membership) {
        if ($Facts.PartOfDomain) { & $add 'Workgroup' 'Failed' "Joined to domain $($Facts.Domain), expected workgroup $($Plan.workgroup)" }
        else { & $add 'Workgroup' 'Passed' "In workgroup $($Facts.Domain)" }
    }

    # Device Manager errors. Code 22 is a device someone disabled on purpose.
    if ($Plan.deviceErrors -ne 'Off') {
        if ($null -eq $Facts.ProblemDevices) { & $add 'Device drivers' (Get-CheckOutcome $Plan.deviceErrors) 'Could not list devices' }
        else {
            $ignore = @($Plan.ignoreDevices | Where-Object { $_ })
            $bad = @($Facts.ProblemDevices | Where-Object {
                $d = $_
                $d.ErrorCode -ne 22 -and -not ($ignore | Where-Object { $d.Name -like $_ -or $d.DeviceId -like $_ })
            })
            if (-not $bad) { & $add 'Device drivers' 'Passed' 'No device errors' }
            else {
                $list = ($bad | Select-Object -First 5 | ForEach-Object { "$(if ($_.Name) { $_.Name } else { $_.DeviceId }) (code $($_.ErrorCode))" }) -join ', '
                if ($bad.Count -gt 5) { $list += ", and $($bad.Count - 5) more" }
                & $add 'Device drivers' (Get-CheckOutcome $Plan.deviceErrors) "$($bad.Count) device(s) with errors: $list"
            }
        }
    }

    # Applications: the installer's exit code, then the app's detection rule from app.json when it has one.
    foreach ($app in @($Plan.applications)) {
        $name = "App: $($app.name)"
        $run = @($AppResults | Where-Object name -eq $app.name) | Select-Object -Last 1
        if ($run -and -not $run.ok) { & $add $name 'Failed' "Installer exit code $($run.exitCode)"; continue }
        $detect = $app.detect
        if ($detect -and $detect.PSObject.Properties['displayName'] -and $detect.displayName) {
            $hit = @($Facts.InstalledPrograms | Where-Object { $_ -like $detect.displayName }) | Select-Object -First 1
            if ($hit) { & $add $name 'Passed' "Installed: $hit" } else { & $add $name 'Failed' "Not in installed programs (looked for '$($detect.displayName)')" }
        } elseif ($detect -and $detect.PSObject.Properties['path'] -and $detect.path) {
            $path = [Environment]::ExpandEnvironmentVariables($detect.path)
            if (Test-Path -LiteralPath $path) { & $add $name 'Passed' "Found $path" } else { & $add $name 'Failed' "Missing $path" }
        } elseif ($run) { & $add $name 'Passed' "Installer exit code $($run.exitCode)" }
        else { & $add $name 'Failed' 'Did not run' }
    }

    # BitLocker on the Windows drive. Encryption still running counts once a protector is in place.
    if ($Plan.bitLocker -and $Plan.bitLocker -ne 'Off') {
        $b = $Facts.BitLocker
        $outcome = Get-CheckOutcome $Plan.bitLocker
        if (-not $b) { & $add 'BitLocker' $outcome 'BitLocker status unavailable (not supported on this edition, or no access)' }
        elseif ($b.VolumeStatus -eq 'FullyEncrypted' -and $b.ProtectionStatus -eq 'On') { & $add 'BitLocker' 'Passed' "On ($(@($b.Protectors) -join ', '))" }
        elseif ($b.VolumeStatus -eq 'EncryptionInProgress' -and @($b.Protectors).Count) { & $add 'BitLocker' 'Passed' "Encrypting, $($b.EncryptionPercentage) % done ($(@($b.Protectors) -join ', '))" }
        elseif ($b.VolumeStatus -eq 'FullyEncrypted') { & $add 'BitLocker' $outcome 'Encrypted but protection is suspended or off' }
        else { & $add 'BitLocker' $outcome "Off ($($b.VolumeStatus))" }
    }
    , $results.ToArray()
}

function Get-CheckOutcome([string]$Mode) { if ($Mode -eq 'Report') { 'Warning' } else { 'Failed' } }

function Get-PostDeployCheckSummary {
    # Overall result for the dashboard: Failed if any check failed, Warning if any warned, otherwise Passed.
    param([object[]]$Results = @())
    $Results = @($Results | Where-Object { $_ })
    $failed = @($Results | Where-Object result -eq 'Failed')
    $warned = @($Results | Where-Object result -eq 'Warning')
    $passed = @($Results | Where-Object result -eq 'Passed')
    $counted = @($Results | Where-Object result -ne 'Skipped').Count
    $result = if (-not $Results) { 'None' } elseif ($failed) { 'Failed' } elseif ($warned) { 'Warning' } else { 'Passed' }
    $text = switch ($result) {
        'None'    { '' }
        'Passed'  { "Passed $($passed.Count)/$counted" }
        default   { "$result $($passed.Count)/$counted`: " + ((@($failed) + @($warned) | ForEach-Object name) -join ', ') }
    }
    [pscustomobject]@{ Result = $result; Passed = $passed.Count; Total = $counted; Failed = @($failed | ForEach-Object name); Text = $text }
}

function Start-PostDeployCheck {
    # Reads the PC, runs the checks and saves the report next to the state file. Used by FirstBoot.ps1 and Test-Deployment.ps1.
    param([Parameter(Mandatory)]$Plan, [object[]]$AppResults = @(), [string]$ReportPath)
    $results = Invoke-PostDeployCheck -Plan $Plan -Facts (Get-PostDeployFacts) -AppResults $AppResults
    $summary = Get-PostDeployCheckSummary -Results $results
    if ($ReportPath) {
        try {
            [pscustomobject]@{ checked = (Get-Date).ToString('o'); result = $summary.Result; summary = $summary.Text; checks = $results } |
                ConvertTo-Json -Depth 4 | Set-Content -Path $ReportPath -Encoding utf8 -ErrorAction Stop
        } catch { Write-Warning "Could not save the check report to $ReportPath`: $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Results = $results; Summary = $summary }
}

function ConvertTo-CheckWarning {
    # The line added to the deployment's warnings when checks do not pass. Starts with a fixed prefix so a re-run can replace it.
    param([Parameter(Mandatory)]$Summary)
    if ($Summary.Result -in 'Passed', 'None') { return $null }
    "Post-deploy checks: $($Summary.Text)"
}

#endregion

Export-ModuleMember -Function New-PostDeployCheckPlan, Get-PostDeployFacts, Invoke-PostDeployCheck,
    Get-PostDeployCheckSummary, Start-PostDeployCheck, ConvertTo-CheckWarning
