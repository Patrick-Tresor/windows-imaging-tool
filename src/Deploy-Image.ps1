<#
.SYNOPSIS
    Deploys a Windows image to this PC from WinPE, driven by an answer file, and injects the matching OEM drivers.
.DESCRIPTION
    Launched by startnet.cmd. Finds content on a USB volume labelled DEPLOY, or on the network share in
    deploy-settings.json (LAN or PXE boot), where the image can come by WDS multicast. Reads an answer file
    from <content root>\AnswerFiles: image, applications, disk, user data migration, regional settings, naming,
    domain join, tasks, extra shares, BIOS settings and BitLocker.
    If config\naming-list.csv on the content root lists this PC's BIOS serial, its computer name, OU and
    answer file win over the answer file's naming, the answer file's OU and the default answer file.
    Unless -NoPrompt, an Unattended answer file or a remote reimage job starts it, a graphical wizard
    (DeployWizard.psm1) lets the operator pick the answer file, name, OU, disk and applications.
    Wipes the target disk (or, when user data is kept on the disk, only its Windows partition) and partitions it
    to match the firmware WinPE booted with: GPT for UEFI, MBR for legacy BIOS.
.EXAMPLE
    X:\Deploy\Deploy-Image.ps1 -AnswerFile W11-Office-FR -NoPrompt
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [string]$AnswerFile,        # name in AnswerFiles\ without .xml; defaults to defaultAnswerFile in settings
    [string]$ComputerName,      # overrides the naming list and the answer file's naming (the wizard still lets the operator change it)
    [switch]$NoPrompt,          # no wizard, countdown or confirmation, whatever the answer file's mode
    [switch]$IgnoreWindows11Check   # deploy even when a Windows 11 requirement fails in Block mode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Win11Readiness.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PostDeployChecks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BiosSettings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UserState.psm1') -Force
$usmtDir = Join-Path $PSScriptRoot 'USMT'
Import-Module (Join-Path $PSScriptRoot 'AppPack.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NamingList.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployWizard.psm1') -Force

function Resolve-ContentPath([string]$Root, [string]$Path) {
    # Answer file paths are relative to the content root unless they are absolute (Y:\..., \\server\...).
    if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Root $Path }
}

function Get-AnswerFileNames([string]$Root) {
    # The answer file says which image to deploy, so without one there is nothing to do. Old USB sticks were built
    # without the AnswerFiles folder; say how to fix that instead of PowerShell's "Cannot find path".
    $dir = Join-Path $Root 'AnswerFiles'
    $names = @(Get-ChildItem -Path $dir -Filter *.xml -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object BaseName)
    if (-not $names) {
        throw ("No answer files in $dir, so this media doesn't know which image to deploy. " +
            'Rebuild the USB stick from the console (Media tab, with the answer files checked), ' +
            'or copy AnswerFiles\<name>.xml and the image it names from the content root to the stick.')
    }
    $names
}

function Select-AnswerFile([string[]]$Names, [string]$Default) {
    # Console fallback when WinPE has no WinForms (media built without WinPE-NetFX).
    if ($Names.Count -eq 1) { return $Names[0] }
    Write-Host ''
    Write-Host 'Answer files:'
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $mark = if ($Names[$i] -eq $Default) { ' (default)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $Names[$i], $mark)
    }
    $pick = Read-Host 'Number to deploy (Enter for the default)'
    if (-not $pick -and $Default) { return $Default }
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $Names.Count) { return $Names[$n - 1] }
    throw "No answer file number '$pick'."
}

function Read-DeployAnswer([string]$Root, [string]$Name, $Listed) {
    # Reads an answer file; a naming list entry's OU replaces the answer file's (domain joins only).
    $path = Join-Path $Root "AnswerFiles\$Name.xml"
    if (-not (Test-Path $path)) { throw "Answer file $Name not found in $Root\AnswerFiles." }
    $a = Read-AnswerFile -Path $path
    if ($Listed -and $Listed.OU) {
        if ($a.Membership -eq 'Domain') { $a.OrganizationalUnit = $Listed.OU }
        else { Write-DeployLog "Naming list OU $($Listed.OU) ignored: answer file $($a.Name) joins a workgroup" -Level WARN }
    }
    $a
}

$script:Mounted = @{}
function Get-DeployPlan($Root, $Answer, $Hardware, $Listed, [string]$Firmware, [bool]$IgnoreWin11) {
    # Everything that must be found before the disk is wiped. The wizard calls this each time an answer file is picked,
    # so a problem (missing image, a PC that fails the Windows 11 check in Block mode) shows there.
    foreach ($share in $Answer.Shares) {
        if ($script:Mounted[$share.LocalName] -eq $share.RemoteName) { continue }
        $pw = if ($share.PasswordFile) { Read-SecretFile -ContentRoot $Root -RelativePath $share.PasswordFile } else { $null }
        $user = if ($share.Domain -and $share.Username) { "$($share.Domain)\$($share.Username)" } else { $share.Username }
        Mount-NetworkShare -LocalName $share.LocalName -RemoteName $share.RemoteName -User $user -Password $pw
        $script:Mounted[$share.LocalName] = $share.RemoteName
    }

    $imagePath = Resolve-ContentPath $Root $Answer.ImageFile
    if ($Answer.ImageVersion) {
        # Pinned to an earlier version kept in Images\Previous.
        $imagePath = Get-ImageVersionPath -ImagePath $imagePath -Version $Answer.ImageVersion
        Write-DeployLog "Image version $($Answer.ImageVersion): $imagePath"
    }
    if (-not (Test-Path $imagePath)) { throw "Image not found: $imagePath" }

    # Windows 11 hardware requirements are checked now, before the disk is wiped.
    $win11 = Invoke-Windows11Check -Answer $Answer -ImagePath $imagePath -Hardware $Hardware -Override $IgnoreWin11

    $driverRoot = Resolve-ContentPath $Root $Answer.DriverRoot
    $driverMatch = Resolve-DriverPack -Identity $Hardware -CatalogPath (Join-Path $Root 'config\driver-catalog.json') -DriverRoot $driverRoot -Detailed

    # The wizard offers every application in the library, not only the answer file's.
    $appRoot = Resolve-ContentPath $Root $Answer.AppLocation
    $available = @(Get-ChildItem -Path $appRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'app.json') } | ForEach-Object Name)

    $wmiValue = try { Get-WmiNamingValue -Query $Answer.WmiQuery } catch { Write-DeployLog "WMI naming query failed: $($_.Exception.Message)" -Level WARN; $Hardware.Serial }
    if (-not $wmiValue) { $wmiValue = $Hardware.Serial }
    $fromList = $Listed -and $Listed.ComputerName

    # Extra summary lines, shown before ERASE in the wizard and on the console.
    $biosCount = @($Answer.Bios.Settings | Where-Object Maker -eq $Hardware.Maker).Count
    $bl = $Answer.BitLocker
    $details = @(
        "Windows 11:   $win11"
        "Firmware:     $Firmware ($(if ($Firmware -eq 'UEFI') { 'GPT' } else { 'MBR' }) disk)"
        "BIOS:         $(if ($Answer.Bios.Enabled -and $biosCount) { "$biosCount setting(s) for $($Hardware.Maker)" } else { 'unchanged' })"
        "BitLocker:    $(if ($bl.Enabled) { "$($bl.Protector), $($bl.EncryptionMethod), at first boot" } else { 'off' })"
    )
    if ($Answer.MigrateUserData) { $details += "User data:    kept ($($Answer.UserDataStore) store), checked once the disk is chosen" }

    [pscustomobject]@{
        ImagePath     = $imagePath
        DriverMatch   = $driverMatch
        DriverPack    = $driverMatch.FullPath
        DriverRoot    = $driverRoot
        AppRoot       = $appRoot
        AvailableApps = $available
        WmiValue      = $wmiValue
        DefaultName   = if ($fromList) { $Listed.ComputerName.ToUpperInvariant() } else { Resolve-ComputerName -Answer $Answer -WmiValue $wmiValue -Serial $Hardware.Serial }
        NameSource    = if ($fromList) { 'naming list' } else { "answer file, $($Answer.NamingMode)" }
        Win11         = $win11
        Details       = $details
    }
}

function Invoke-Windows11Check($Answer, [string]$ImagePath, $Hardware, [bool]$Override) {
    # Logs each requirement and throws when the answer file blocks unsupported PCs. Returns the summary line.
    if ($Answer.Windows11Check -eq 'Off') { return 'not checked (off in the answer file)' }
    $isWin11 = Test-Win11Image -ImagePath $ImagePath -Index $Answer.ImageIndex
    if ($isWin11 -eq $false) { return 'not needed (Windows 10 image)' }
    $results = @(Test-Win11Readiness -Facts (Get-Win11ReadinessFacts -DiskNumber $Answer.DiskNumber -IsUefi $Hardware.IsUefi))
    foreach ($r in $results) {
        $level = @{ Pass = 'INFO'; Warn = 'WARN'; Fail = 'ERROR' }[$r.Result]
        Write-DeployLog ("Windows 11 {0}: {1} ({2})" -f $r.Check, $r.Result.ToUpperInvariant(), $r.Detail) -Level $level
    }
    $decision = Get-Win11ReadinessDecision -Mode $Answer.Windows11Check -IsWin11 $isWin11 -Results $results -Override:$Override
    if ($null -eq $isWin11) { Write-DeployLog 'Could not tell whether the image is Windows 11; requirements are shown but never block.' -Level WARN }
    if ($decision.Action -eq 'Block') {
        throw "This PC does not meet the Windows 11 requirements ($($decision.Summary -replace '^NOT READY: ')). Nothing was erased. " +
              'Fix it in the firmware settings, deploy a Windows 10 answer file, or set the Windows 11 check to Warn.'
    }
    if ($decision.Failed -and $Override) { Write-DeployLog 'Deploying anyway: -IgnoreWindows11Check' -Level WARN }
    $decision.Summary
}

function Wait-Countdown([int]$Seconds) {
    # Unattended mode: start after a short countdown that any key, or Change settings in the progress window, cancels.
    try {
        for ($s = $Seconds; $s -gt 0; $s--) {
            Write-Host -NoNewline "`rStarting in $s s. Press any key to cancel. "
            Set-DeployStatus -LocalOnly -Fields @{ countdown = $s }
            for ($t = 0; $t -lt 10; $t++) {
                if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); Write-Host ''; return $false }
                if (Receive-ProgressCancel) { Write-Host ''; return $false }
                Start-Sleep -Milliseconds 100
            }
        }
        Write-Host ''
        $true
    }
    finally { Set-DeployStatus -LocalOnly -Fields @{ countdown = 0 } }
}

function Start-ProgressWindow([string]$ProgressPath) {
    # The window on this PC's screen (DeployProgressWindow.ps1), in its own process so it keeps redrawing while DISM runs.
    # Without WinForms (media built without WinPE-NetFX) the console shows the log as before.
    if (-not (Test-DeployWizardAvailable)) { return $false }
    try {
        $script = Join-Path $PSScriptRoot 'DeployProgressWindow.ps1'
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script`"",
            '-ProgressPath', "`"$ProgressPath`"", '-DeployProcessId', $PID) | Out-Null
        $true
    } catch {
        Write-DeployLog "Progress window not started: $($_.Exception.Message)" -Level WARN
        $false
    }
}

function Connect-StatusFolder([string]$Root, $Settings) {
    # Where this PC reports progress for the console's dashboard (see Resolve-StatusTarget). $null if unreachable.
    $report = if ($Settings.PSObject.Properties['reporting']) { $Settings.reporting.path } else { $null }
    $target = Resolve-StatusTarget -ContentRoot $Root -SharePath $Settings.share.path -ReportPath $report
    if (-not $target.Map) { return $target }
    try {
        # A separate status share (USB deployments reporting to a server): needs the network and the share account.
        & wpeutil.exe WaitForNetwork | Out-Null
        $user = $null; $pw = $null
        if ($Settings.share.user -and $Settings.share.passwordFile) {
            $pwFile = @((Join-Path $Root $Settings.share.passwordFile),
                        (Join-Path (Split-Path $SettingsPath -Parent | Split-Path -Parent) $Settings.share.passwordFile)) |
                Where-Object { Test-Path $_ } | Select-Object -First 1
            # Without a password net use would stop and prompt, so only pass the account when its password is known.
            if ($pwFile) { $user = $Settings.share.user; $pw = (Get-Content -Raw $pwFile).Trim() }
        }
        Mount-NetworkShare -LocalName 'R:' -RemoteName $target.Map -User $user -Password $pw
        $target
    } catch {
        Write-DeployLog "Status share $($target.Map) unavailable, no progress reporting: $($_.Exception.Message)" -Level WARN
        $null
    }
}

function Invoke-Phase([string]$Phase, $Answer, [string]$Root) {
    # POSTIMAGE tasks run here in WinPE with the new Windows at %OSDRIVE% (W:) and content at %DEPLOYROOT%.
    $env:OSDRIVE = 'W:'
    $env:DEPLOYROOT = $Root.TrimEnd('\')
    foreach ($t in $Answer.Tasks | Where-Object Phase -eq $Phase) {
        Invoke-Native -FilePath 'cmd.exe' -ArgumentList @('/c', $t.Command)
    }
}

$root = $null; $hw = $null; $answer = $null; $driverMatch = $null; $plan = $null; $statusTarget = $null; $logName = $null
$job = $null; $adapters = @(); $progressWindow = $false
$status = 'FAILED'; $failure = $null
try {
    $hw = Get-HardwareIdentity
    Write-DeployLog ("Hardware: {0} | {1} | type {2} | SKU {3} | serial {4} | UEFI {5}" -f
        $hw.Maker, $hw.Model, $hw.MachineType, $hw.Sku, $hw.Serial, $hw.IsUefi)
    # The disk layout and boot files follow how WinPE booted. A UEFI PC booted through CSM deploys as BIOS.
    $firmware = if ($hw.IsUefi) { 'UEFI' } else { 'BIOS' }

    # Every Set-DeployStatus from here on also updates the progress window on this PC's screen.
    $progressPath = 'X:\Windows\Temp\DeployProgress.json'
    Start-LocalProgress -Path $progressPath -Identity $hw
    $progressWindow = Start-ProgressWindow -ProgressPath $progressPath

    Set-DeployStatus -LocalOnly -Step 'Looking for the deployment content (USB DEPLOY volume or network share)' -Percent 1
    $root = Find-ContentRoot -SettingsPath $SettingsPath
    Set-DeployStatus -LocalOnly -Step 'Reading the answer files' -Percent 3

    # Settings on the content root (edited in the console) win over the copy baked into the media.
    $rootSettings = Join-Path $root 'config\deploy-settings.json'
    $settings = Get-Content -Raw $(if (Test-Path $rootSettings) { $rootSettings } else { $SettingsPath }) | ConvertFrom-Json

    # Report to the dashboard from here on, so even the checks below show up as failures in the console.
    $statusTarget = Connect-StatusFolder -Root $root -Settings $settings
    if ($statusTarget) {
        $net = Get-PrimaryNetworkAddress
        $statusId = Start-DeployStatus -Folder $statusTarget.Local -Identity $hw -MacAddress $net.MacAddress -IpAddress $net.IpAddress
        Write-DeployLog "Reporting status to $($statusTarget.Local) as $statusId"
    }

    # A remote reimage from the console queued a job for this PC's MAC: use its answer file without asking.
    # Taking the job deletes it, so the next network boot of this PC does not reimage it again.
    $adapters = @(Get-LocalMacAddresses)
    $job = Receive-ReimageJob -ContentRoot $root -Mac @($adapters | ForEach-Object Mac)
    if ($job) {
        Write-DeployLog "Remote reimage requested by $($job.requestedBy) at $($job.requestedAt): answer file $($job.answerFile)"
        $AnswerFile = $job.answerFile
        if ($job.computerName -and -not $ComputerName) { $ComputerName = $job.computerName }
    }
    $givenName = $ComputerName

    # Naming list: this PC's own name, OU and answer file, by BIOS serial. Checked before anything is wiped.
    $listed = Find-NamingEntry -Entries @(Read-NamingList -Path (Join-Path $root 'config\naming-list.csv')) -Serial $hw.Serial
    if ($listed) {
        $problems = @(Test-NamingEntry -Entry $listed)
        if ($problems) { throw "Naming list entry for serial $($hw.Serial) has problems: $($problems -join ' ')" }
        Write-DeployLog ("Naming list entry for serial {0}: name '{1}', OU '{2}', answer file '{3}'" -f $hw.Serial, $listed.ComputerName, $listed.OU, $listed.AnswerFile)
        if (-not $AnswerFile -and $listed.AnswerFile) { $AnswerFile = $listed.AnswerFile }
    } else {
        Write-DeployLog "Serial $($hw.Serial) is not in the naming list; using the answer file's naming"
    }

    $names = Get-AnswerFileNames -Root $root
    if (-not $AnswerFile) {
        if ($settings.defaultAnswerFile -and ($NoPrompt -or $settings.defaultAnswerFile -in $names)) { $AnswerFile = $settings.defaultAnswerFile }
        elseif ($NoPrompt -or $names.Count -eq 1) { $AnswerFile = $names[0] }
    }
    $readAnswer  = { param($Name) Read-DeployAnswer -Root $root -Name $Name -Listed $listed }
    $preparePlan = { param($Answer) Get-DeployPlan -Root $root -Answer $Answer -Hardware $hw -Listed $listed -Firmware $firmware -IgnoreWin11 $IgnoreWindows11Check.IsPresent }

    # -NoPrompt, Unattended answer files and remote reimage jobs start without the wizard. A key pressed during
    # the countdown opens the wizard instead, so the operator can change anything.
    $deployPlan = $null; $confirmed = $false
    if ($AnswerFile) {
        $answer = & $readAnswer $AnswerFile
        if ($NoPrompt) { $confirmed = $true }
        elseif ($answer.Mode -eq 'Unattended' -or $job) {
            $deployPlan = & $preparePlan $answer
            $name = if ($ComputerName) { $ComputerName } else { $deployPlan.DefaultName }
            Write-Host ''
            Get-DeploySummary -Answer $answer -Plan $deployPlan -ComputerName $name -Disk (Get-Disk -Number $answer.DiskNumber) -Applications $answer.Applications |
                ForEach-Object { Write-Host $_ }
            Set-DeployStatus -Step 'Counting down' -Percent 5
            # Nobody is at a remotely reimaged PC: count down, so someone who is can still cancel.
            $confirmed = Wait-Countdown $(if ($job) { [Math]::Max([int]$answer.UnattendDelay, 15) } else { $answer.UnattendDelay })
            if ($confirmed) { $ComputerName = $name } else { Write-DeployLog 'Countdown cancelled by operator' -Level WARN }
        }
    }

    if (-not $confirmed -and (Test-DeployWizardAvailable)) {
        Set-DeployStatus -Step 'Waiting for the operator' -Percent 5
        $choice = Show-DeployWizard -Hardware $hw -AnswerFiles $names -Default $AnswerFile -ComputerName $ComputerName `
            -ReadAnswer $readAnswer -PreparePlan $preparePlan
        if (-not $choice) { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
        $answer = $choice.Answer; $deployPlan = $choice.Plan; $ComputerName = $choice.ComputerName
        $confirmed = $true
    }

    if (-not $answer) { $answer = & $readAnswer (Select-AnswerFile -Names $names -Default $settings.defaultAnswerFile) }
    if (-not $deployPlan) { $deployPlan = & $preparePlan $answer }
    if (-not $ComputerName) {
        $ComputerName = $deployPlan.DefaultName
        if ($answer.NamingMode -eq 'Prompt' -and -not $confirmed -and -not ($listed -and $listed.ComputerName)) {
            $typed = Read-Host "Computer name (Enter for $ComputerName)"
            if ($typed) { $ComputerName = Resolve-ComputerName -Answer $answer -WmiValue $deployPlan.WmiValue -Serial $hw.Serial -Typed $typed }
        }
    }
    $nameSource = if ($givenName -and $ComputerName -eq $givenName) { if ($job -and $givenName -eq $job.computerName) { 'remote reimage' } else { 'parameter' } }
                  elseif ($ComputerName -eq $deployPlan.DefaultName) { $deployPlan.NameSource } else { 'typed by the operator' }
    Write-DeployLog "Answer file: $($answer.Name) ($($answer.Mode)), name $ComputerName ($nameSource), disk $($answer.DiskNumber)"
    Set-DeployStatus -Step 'Checking the answer file' -Percent 6 -Fields @{ answerFile = $answer.Name; image = $answer.ImageFile; computerName = $ComputerName }

    $imagePath = $deployPlan.ImagePath; $driverMatch = $deployPlan.DriverMatch; $driverPack = $deployPlan.DriverPack
    $driverRoot = $deployPlan.DriverRoot; $appRoot = $deployPlan.AppRoot
    Set-DeployStatus -Fields @{ driverPack = $(if ($driverPack) { $driverPack.Substring($driverRoot.TrimEnd('\').Length).TrimStart('\') } else { 'inbox only' }) }
    if (-not $driverPack) { Set-DeployStatus -Warning "No driver pack for $($hw.Maker) $($hw.Model)" }

    # Applications are checked now, before the disk is wiped.
    # Apps limited to other makers or models (Dell Command Update on a Lenovo) are left out.
    $apps = @($answer.Applications | ForEach-Object { Get-AppDefinition -AppRoot $appRoot -Name $_ } | Where-Object {
        if (Test-AppRequirement -Definition $_ -Identity $hw) { return $true }
        Write-DeployLog "Skipping application $($_.name): it is for $((@($_.requirements.makers) + @($_.requirements.models)) -join ', ') only"
        $false
    })

    $joinPassword  = if ($answer.Membership -eq 'Domain') { Read-SecretFile -ContentRoot $root -RelativePath $answer.JoinPasswordFile } else { $null }
    $adminPassword = if ($answer.EnableAdministrator) { Read-SecretFile -ContentRoot $root -RelativePath $answer.AdminPasswordFile } else { $null }
    $bl = $answer.BitLocker
    $bitLockerPin  = if ($bl.Enabled -and $bl.Protector -eq 'TpmPin') { Read-SecretFile -ContentRoot $root -RelativePath $bl.PinFile } else { $null }
    $bios = $answer.Bios
    $biosCount = @($bios.Settings | Where-Object Maker -eq $hw.Maker).Count
    # No password file means the BIOS has no admin password yet.
    $biosPassword  = if ($bios.Enabled -and $bios.PasswordFile) { Read-SecretFile -ContentRoot $root -RelativePath $bios.PasswordFile } else { $null }

    # User data: find the old Windows on the chosen disk and check the backup can be done, still before anything is erased.
    $migration = $null
    if ($answer.MigrateUserData) {
        $migration = Get-UserStatePlan -Answer $answer -ContentRoot $root -UsmtDir $usmtDir -Serial $hw.Serial `
            -SharePath (Resolve-ContentPath $root $answer.UserDataPath)
        Write-DeployLog "User data: $($migration.Summary)" -Level $(if ($migration.Mode -eq 'None') { 'WARN' } else { 'INFO' })
    }
    $keepPartitions = $migration -and $migration.Store -eq 'Local' -and $migration.Mode -ne 'None'
    if ($keepPartitions -and $firmware -ne 'UEFI') {
        throw 'Keeping user data on the disk keeps its GPT partitions, which only boot in UEFI mode, but WinPE booted in legacy BIOS mode. Boot WinPE in UEFI mode, or store the user data on a share.'
    }

    $disk = Get-Disk -Number $answer.DiskNumber
    if ($firmware -eq 'BIOS') {
        Write-DeployLog 'Legacy BIOS boot: the disk will be MBR. Boot WinPE in UEFI mode instead if this PC supports it.' -Level WARN
        if ($disk.Size -gt 2TB) { Write-DeployLog ("Disk is {0:N0} GB; MBR can only use the first 2 TB." -f ($disk.Size / 1GB)) -Level WARN }
        $build = try { [version](Get-WindowsImage -ImagePath $imagePath -Index $answer.ImageIndex).Version } catch { $null }
        if ($build -and $build.Build -ge 22000) {
            Write-DeployLog 'This is a Windows 11 image. It installs on legacy BIOS, but Microsoft does not support it there and Windows Update may withhold feature updates.' -Level WARN
        }
    }

    $summary = @(Get-DeploySummary -Answer $answer -Plan $deployPlan -ComputerName $ComputerName -Disk $disk -Applications @($apps | ForEach-Object name))
    if ($migration) {
        # The real user data plan, now that the disk is known, replaces the wizard's placeholder line.
        $summary = @($summary | Where-Object { $_ -notlike 'User data:*' -and $_ -notlike 'ERASE*' })
        $summary += "User data:    $($migration.Summary)"
        $summary += if ($keepPartitions) { "ERASE:        everything on $($migration.Volume.Drive) except the user data, disk $(Format-DiskChoice $disk)" } else { "ERASE disk:   $(Format-DiskChoice $disk)" }
    }
    foreach ($line in $summary) { Write-DeployLog $line }
    if (-not $confirmed) {
        Write-Host ''
        $summary | ForEach-Object { Write-Host $_ -ForegroundColor $(if ($_ -like 'ERASE*') { 'Red' } elseif ($_ -like 'Windows 11:   NOT READY*') { 'Yellow' } else { 'Gray' }) }
        Set-DeployStatus -Step 'Waiting for the operator'
        if ((Read-Host 'Type YES to continue') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
    }

    # 0. BIOS settings, before anything is erased. They take effect on the reboot into Windows.
    if ($bios.Enabled -and $biosCount) {
        $biosFailed = try {
            @(Set-BiosSettings -Maker $hw.Maker -Settings $bios.Settings -Password $biosPassword -ToolsDir (Resolve-ContentPath $root $bios.ToolsRoot) |
                Where-Object { -not $_.Ok }).Count
        } catch { Write-DeployLog "BIOS settings not applied: $($_.Exception.Message)" -Level WARN; $biosCount }
        if ($biosFailed -and $bios.StopOnError) { throw "$biosFailed BIOS setting(s) failed and the answer file says to stop (bios/stopOnError)." }
    }

    # 1. Back up the user data, then partition. A failed backup stops here, with the disk untouched.
    if ($migration -and $migration.Mode -eq 'Backup') {
        Set-DeployStatus -Step 'Backing up user data' -Percent 7
        Backup-UserState -Plan $migration -Answer $answer -UsmtDir $usmtDir
    }

    Set-DeployStatus -Step 'Partitioning the disk' -Percent 8
    if ($keepPartitions) {
        # Hard-link store: keep the partitions and empty the Windows partition around it.
        Clear-WindowsPartition -Plan $migration -DiskNumber $answer.DiskNumber
    } else {
        # EFI, MSR, Windows, Recovery on UEFI; System, Windows, Recovery on BIOS.
        $dp = Join-Path $env:TEMP 'diskpart.txt'
        New-DiskpartScript -DiskNumber $answer.DiskNumber -Firmware $firmware | Set-Content -Path $dp -Encoding ascii
        Invoke-Native -FilePath 'diskpart.exe' -ArgumentList @('/s', $dp)
    }

    # 2. Apply the image. With multicast on, a room of PCs downloads it together onto the new Windows
    #    partition first (WDS sends it once for all of them), then applies it from there.
    $applyFrom = $imagePath
    $mcPlan = Get-MulticastPlan -Settings $settings -ContentRoot $root -ImagePath $imagePath -IsNetworkRoot ($root -eq 'Z:\')
    if ($mcPlan) {
        Set-DeployStatus -Step 'Downloading the image by multicast' -Percent 9
        try {
            $cred = Get-ShareCredential -SettingsPath $SettingsPath
            $applyFrom = Receive-MulticastImage -Plan $mcPlan -Destination (Join-Path 'W:\_Multicast' (Split-Path $imagePath -Leaf)) -User $cred.User -Password $cred.Password
        }
        catch {
            if (-not $mcPlan.Fallback) { throw "Multicast download failed: $($_.Exception.Message)" }
            Write-DeployLog "Multicast download failed, applying from the share instead: $($_.Exception.Message)" -Level WARN
            Set-DeployStatus -Warning 'Multicast download failed; applied from the share instead'
            Remove-Item 'W:\_Multicast' -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # Split images (.swm) need /SWMFile.
    $applyArgs = @('/Apply-Image', "/ImageFile:$applyFrom", "/Index:$($answer.ImageIndex)", '/ApplyDir:W:\')
    if ($applyFrom -like '*.swm') { $applyArgs += "/SWMFile:$($applyFrom -replace '\.swm$', '*.swm')" }
    # The longest step: DISM's percentage maps to 10-70 % overall, and each poll is a heartbeat for the dashboard.
    Set-DeployStatus -Step 'Applying the image' -Percent 10
    Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList $applyArgs -OnProgress {
        param($pct)
        if ($null -ne $pct) { Set-DeployStatus -Step "Applying the image ($pct %)" -Percent (10 + [int]($pct * 0.6)) }
        else { Set-DeployStatus }
    }
    if ($applyFrom -ne $imagePath) { Remove-Item 'W:\_Multicast' -Recurse -Force }

    # 3. Inject the OEM driver pack offline.
    if ($driverPack) {
        Set-DeployStatus -Step 'Injecting drivers' -Percent 72
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Image:W:\', '/Add-Driver', "/Driver:$driverPack", '/Recurse', '/ForceUnsigned:No')
    }

    # 4. Unattend generated from the answer file. Setup blanks the passwords in it after use.
    Set-DeployStatus -Step 'Writing Windows settings' -Percent 80
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    New-UnattendXml -Answer $answer -ComputerName $ComputerName -JoinPassword $joinPassword -AdminPassword $adminPassword |
        Set-Content -Path 'W:\Windows\Panther\unattend.xml' -Encoding utf8
    Write-DeployLog "Unattend written: name $ComputerName, $($answer.Membership)"

    # 5. First boot: applications and FIRSTBOOT tasks run as SYSTEM from SetupComplete.cmd.
    Set-DeployStatus -Step 'Staging applications' -Percent 82
    New-Item -ItemType Directory -Path 'W:\Deploy\Apps' -Force | Out-Null
    foreach ($app in $apps) {
        Write-DeployLog "Staging application $($app.name)"
        Copy-Item -Path (Join-Path $appRoot $app.name) -Destination 'W:\Deploy\Apps\' -Recurse -Force
    }
    # User data is restored by FirstBoot.ps1 after the applications.
    $userState = if ($migration -and $migration.Mode -ne 'None') { Copy-UserStateForRestore -Plan $migration -Answer $answer -UsmtDir $usmtDir } else { $null }
    Copy-Item (Join-Path $PSScriptRoot 'FirstBoot.ps1'), (Join-Path $PSScriptRoot 'DeployStatus.psm1'),
        (Join-Path $PSScriptRoot 'PostDeployChecks.psm1'), (Join-Path $PSScriptRoot 'Test-Deployment.ps1'),
        (Join-Path $PSScriptRoot 'AppPack.psm1') 'W:\Deploy\'
    $plan = New-FirstBootPlan -Answer $answer -AppDefinitions $apps -UserState $userState -BitLockerPin $bitLockerPin
    # What the post-deploy checks expect at the end of first boot (deploy-settings "checks" turns them off or tunes them).
    $checks = New-PostDeployCheckPlan -Answer $answer -ComputerName $ComputerName -AppDefinitions $apps -Settings $settings
    if ($checks) { $plan | Add-Member -NotePropertyName checks -NotePropertyValue $checks }
    # The new Windows can keep reporting only to a UNC path (as the computer account), not to WinPE's drive letters.
    if ($statusTarget -and $statusTarget.Unc) {
        $plan | Add-Member -NotePropertyName status -NotePropertyValue ([pscustomobject]@{ folder = $statusTarget.Unc; id = $statusId })
    }
    $plan | ConvertTo-Json -Depth 8 | Set-Content 'W:\Deploy\firstboot.json' -Encoding utf8
    New-Item -ItemType Directory -Path 'W:\Windows\Setup\Scripts' -Force | Out-Null
    "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Deploy\FirstBoot.ps1`r`n" |
        Set-Content -Path 'W:\Windows\Setup\Scripts\SetupComplete.cmd' -Encoding ascii

    # 6. POSTIMAGE tasks, then boot files.
    Set-DeployStatus -Step 'Running post-image tasks' -Percent 86
    Invoke-Phase -Phase 'POSTIMAGE' -Answer $answer -Root $root
    Set-DeployStatus -Step 'Writing boot files' -Percent 88
    Invoke-Native -FilePath 'W:\Windows\System32\bcdboot.exe' -ArgumentList @('W:\Windows', '/s', 'S:', '/f', $firmware)

    Write-DeployLog 'Deployment finished'
    $status = 'OK'
}
catch {
    $failure = $_.Exception.Message
    Write-DeployLog $failure -Level ERROR
}
finally {
    # Keep the log on the deployed disk and, when available, on the content root for central review.
    if (Test-Path 'W:\Windows') { Copy-Item 'X:\Windows\Temp\Deploy.log', 'X:\Windows\Temp\ScanState.log' 'W:\Windows\Temp\' -ErrorAction SilentlyContinue }
    if ($root -and $hw -and $status -ne 'CANCELLED') {
        $logDir = Join-Path $root 'Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        $logName = "{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $hw.Serial, (Get-Date), $status
        Copy-Item 'X:\Windows\Temp\Deploy.log' (Join-Path $logDir $logName) -ErrorAction SilentlyContinue
        # Remember this PC (MAC, IP, model) so the console can wake and reimage it later.
        $nic = $adapters | Where-Object IP | Select-Object -First 1
        if ($nic) {
            try { Save-DeployedComputer -ContentRoot $root -Adapter $nic -Identity $hw -ComputerName $ComputerName -AnswerFile $AnswerFile -Result $status | Out-Null }
            catch { Write-DeployLog "Could not update the computer list: $($_.Exception.Message)" -Level WARN }
        }
    }
    $final = @{ logFile = $logName }
    switch ($status) {
        'OK' {
            if ($plan -and $plan.PSObject.Properties['status']) {
                # FirstBoot.ps1 takes over from 90 % and marks the deployment finished.
                Set-DeployStatus -Step 'Waiting for first boot in Windows' -Percent 90 -Phase 'FirstBoot' -Fields $final
            } else {
                Set-DeployStatus -Step 'Image applied; applications install at first boot' -Percent 100 -State Succeeded -Fields $final
            }
        }
        'CANCELLED' { Set-DeployStatus -Step 'Cancelled by operator' -State Cancelled -Fields $final }
        default     { Set-DeployStatus -Message $failure -State Failed -Fields $final }
    }
    if ($status -eq 'OK') {
        # The dashboard waits for first boot; the window on this PC is done with its part.
        $whenDone = if ($answer.Shutdown) { 'shutdown' } elseif ($answer.Reboot) { 'restart' } else { 'stay' }
        Set-DeployStatus -LocalOnly -Step 'Image applied' -Percent 100 -State Succeeded -Fields @{ whenDone = $whenDone }
    }
    # Which drivers this PC got, for the console's Unknown Models report. Never fails the deployment.
    if ($root -and $hw -and $driverMatch -and $status -ne 'CANCELLED') {
        try {
            Write-DriverReport -ContentRoot $root -Identity $hw -Match $driverMatch -ComputerName $ComputerName `
                -AnswerFile $(if ($answer) { $answer.Name }) -Result $status
        } catch { Write-Warning "Could not write the driver report: $($_.Exception.Message)" }
    }
}

# Let the window show the result before the screen goes dark.
if ($status -eq 'OK' -and $progressWindow -and ($answer.Shutdown -or $answer.Reboot)) { Start-Sleep -Seconds 5 }
if ($status -eq 'OK' -and $answer.Shutdown) { & wpeutil.exe shutdown }
elseif ($status -eq 'OK' -and $answer.Reboot) { & wpeutil.exe reboot }
if ($status -ne 'OK') { exit 1 }
