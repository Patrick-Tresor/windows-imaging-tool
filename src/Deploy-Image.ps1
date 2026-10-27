<#
.SYNOPSIS
    Deploys a Windows image to this PC from WinPE, driven by an answer file, and injects the matching OEM drivers.
.DESCRIPTION
    Launched by startnet.cmd. Finds content on a USB volume labelled DEPLOY, or on the network share in
    deploy-settings.json (LAN or PXE boot), where the image can come by WDS multicast. Reads an answer file
    from <content root>\AnswerFiles: image, applications, disk, user data migration, regional settings, naming,
    domain join, tasks, extra shares, BIOS settings and BitLocker.
    Wipes the target disk (or, when user data is kept on the disk, only its Windows partition) and partitions it
    to match the firmware WinPE booted with: GPT for UEFI, MBR for legacy BIOS.
.EXAMPLE
    X:\Deploy\Deploy-Image.ps1 -AnswerFile W11-Office-FR -NoPrompt
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [string]$AnswerFile,        # name in AnswerFiles\ without .xml; defaults to defaultAnswerFile in settings
    [string]$ComputerName,      # overrides the answer file's naming
    [switch]$NoPrompt           # no countdown or confirmation, whatever the answer file's mode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PostDeployChecks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BiosSettings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UserState.psm1') -Force
$usmtDir = Join-Path $PSScriptRoot 'USMT'

function Resolve-ContentPath([string]$Root, [string]$Path) {
    # Answer file paths are relative to the content root unless they are absolute (Y:\..., \\server\...).
    if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Root $Path }
}

function Select-AnswerFile([string]$Root, [string]$Default, [bool]$Interactive) {
    $files = @(Get-ChildItem -Path (Join-Path $Root 'AnswerFiles') -Filter *.xml -File | Sort-Object Name)
    if (-not $files) { throw "No answer files in $Root\AnswerFiles." }
    if (-not $Interactive -or $files.Count -eq 1) {
        if ($Default) { return $Default }
        return $files[0].BaseName
    }
    Write-Host ''
    Write-Host 'Answer files:'
    for ($i = 0; $i -lt $files.Count; $i++) {
        $mark = if ($files[$i].BaseName -eq $Default) { ' (default)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $files[$i].BaseName, $mark)
    }
    $pick = Read-Host 'Number to deploy (Enter for the default)'
    if (-not $pick -and $Default) { return $Default }
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) { return $files[$n - 1].BaseName }
    throw "No answer file number '$pick'."
}

function Wait-Countdown([int]$Seconds) {
    # Unattended mode: start after a short countdown that any key cancels, like SmartDeploy's unattend delay.
    for ($s = $Seconds; $s -gt 0; $s--) {
        Write-Host -NoNewline "`rStarting in $s s. Press any key to cancel. "
        for ($t = 0; $t -lt 10; $t++) {
            if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); Write-Host ''; return $false }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ''
    $true
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
$status = 'FAILED'; $failure = $null
try {
    $hw = Get-HardwareIdentity
    Write-DeployLog ("Hardware: {0} | {1} | type {2} | SKU {3} | serial {4} | UEFI {5}" -f
        $hw.Maker, $hw.Model, $hw.MachineType, $hw.Sku, $hw.Serial, $hw.IsUefi)
    # The disk layout and boot files follow how WinPE booted. A UEFI PC booted through CSM deploys as BIOS.
    $firmware = if ($hw.IsUefi) { 'UEFI' } else { 'BIOS' }

    $root = Find-ContentRoot -SettingsPath $SettingsPath

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

    if (-not $AnswerFile) { $AnswerFile = Select-AnswerFile -Root $root -Default $settings.defaultAnswerFile -Interactive (-not $NoPrompt) }
    $answer = Read-AnswerFile -Path (Join-Path $root "AnswerFiles\$AnswerFile.xml")
    Write-DeployLog "Answer file: $($answer.Name) ($($answer.Mode))"
    Set-DeployStatus -Step 'Checking the answer file' -Percent 3 -Fields @{ answerFile = $answer.Name; image = $answer.ImageFile }

    foreach ($share in $answer.Shares) {
        $pw = if ($share.PasswordFile) { Read-SecretFile -ContentRoot $root -RelativePath $share.PasswordFile } else { $null }
        $user = if ($share.Domain -and $share.Username) { "$($share.Domain)\$($share.Username)" } else { $share.Username }
        Mount-NetworkShare -LocalName $share.LocalName -RemoteName $share.RemoteName -User $user -Password $pw
    }

    $imagePath = Resolve-ContentPath $root $answer.ImageFile
    if ($answer.ImageVersion) {
        # Pinned to an earlier version kept in Images\Previous.
        $imagePath = Get-ImageVersionPath -ImagePath $imagePath -Version $answer.ImageVersion
        Write-DeployLog "Image version $($answer.ImageVersion): $imagePath"
    }
    if (-not (Test-Path $imagePath)) { throw "Image not found: $imagePath" }

    $driverRoot = Resolve-ContentPath $root $answer.DriverRoot
    $driverMatch = Resolve-DriverPack -Identity $hw -CatalogPath (Join-Path $root 'config\driver-catalog.json') -DriverRoot $driverRoot -Detailed
    $driverPack = $driverMatch.FullPath
    Set-DeployStatus -Fields @{ driverPack = $(if ($driverPack) { $driverPack.Substring($driverRoot.TrimEnd('\').Length).TrimStart('\') } else { 'inbox only' }) }
    if (-not $driverPack) { Set-DeployStatus -Warning "No driver pack for $($hw.Maker) $($hw.Model)" }

    # Applications are checked now, before the disk is wiped.
    $appRoot = Resolve-ContentPath $root $answer.AppLocation
    $apps = @($answer.Applications | ForEach-Object { Get-AppDefinition -AppRoot $appRoot -Name $_ })

    $joinPassword  = if ($answer.Membership -eq 'Domain') { Read-SecretFile -ContentRoot $root -RelativePath $answer.JoinPasswordFile } else { $null }
    $adminPassword = if ($answer.EnableAdministrator) { Read-SecretFile -ContentRoot $root -RelativePath $answer.AdminPasswordFile } else { $null }
    $bl = $answer.BitLocker
    $bitLockerPin  = if ($bl.Enabled -and $bl.Protector -eq 'TpmPin') { Read-SecretFile -ContentRoot $root -RelativePath $bl.PinFile } else { $null }
    $bios = $answer.Bios
    # No password file means the BIOS has no admin password yet.
    $biosPassword  = if ($bios.Enabled -and $bios.PasswordFile) { Read-SecretFile -ContentRoot $root -RelativePath $bios.PasswordFile } else { $null }

    $interactive = -not $NoPrompt -and $answer.Mode -eq 'Interactive'
    if (-not $ComputerName) {
        $wmiValue = try { Get-WmiNamingValue -Query $answer.WmiQuery } catch { Write-DeployLog "WMI naming query failed: $($_.Exception.Message)" -Level WARN; $hw.Serial }
        if (-not $wmiValue) { $wmiValue = $hw.Serial }
        $ComputerName = Resolve-ComputerName -Answer $answer -WmiValue $wmiValue -Serial $hw.Serial
        if ($answer.NamingMode -eq 'Prompt' -and $interactive) {
            $typed = Read-Host "Computer name (Enter for $ComputerName)"
            if ($typed) { $ComputerName = Resolve-ComputerName -Answer $answer -WmiValue $wmiValue -Serial $hw.Serial -Typed $typed }
        }
    }

    Set-DeployStatus -Fields @{ computerName = $ComputerName }
    # User data: find the old Windows and check the backup can be done, still before anything is erased.
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
    Write-Host ''
    Write-Host "Answer file:  $($answer.Name)"
    Write-Host "Image:        $imagePath (index $($answer.ImageIndex)$(if ($answer.ImageVersion) { ", version $($answer.ImageVersion)" }))"
    Write-Host "Drivers:      $(if ($driverPack) { $driverPack } else { 'inbox only' })"
    Write-Host "Applications: $(if ($apps) { ($apps.name -join ', ') } else { 'none' })"
    Write-Host "Name:         $ComputerName"
    Write-Host "Joins:        $(if ($answer.Membership -eq 'Domain') { "domain $($answer.Domain)" } else { "workgroup $($answer.Workgroup)" })"
    Write-Host "Firmware:     $firmware ($(if ($firmware -eq 'UEFI') { 'GPT' } else { 'MBR' }) disk)"
    $biosCount = @($bios.Settings | Where-Object Maker -eq $hw.Maker).Count
    Write-Host "BIOS:         $(if ($bios.Enabled -and $biosCount) { "$biosCount setting(s) for $($hw.Maker)" } else { 'unchanged' })"
    Write-Host "BitLocker:    $(if ($bl.Enabled) { "$($bl.Protector), $($bl.EncryptionMethod), at first boot" } else { 'off' })"
    if ($migration) { Write-Host "User data:    $($migration.Summary)" }
    if ($keepPartitions) {
        Write-Host ("ERASE:        everything on {0} except the user data, disk {1} {2}" -f $migration.Volume.Drive, $disk.Number, $disk.FriendlyName) -ForegroundColor Red
    } else {
        Write-Host ("ERASE disk:   {0} {1} ({2:N0} GB)" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Red
    }
    if (-not $NoPrompt) {
        Set-DeployStatus -Step $(if ($answer.Mode -eq 'Unattended') { 'Counting down' } else { 'Waiting for the operator' }) -Percent 5
        $go = if ($answer.Mode -eq 'Unattended') { Wait-Countdown $answer.UnattendDelay } else { (Read-Host 'Type YES to continue') -eq 'YES' }
        if (-not $go) { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
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
        (Join-Path $PSScriptRoot 'PostDeployChecks.psm1'), (Join-Path $PSScriptRoot 'Test-Deployment.ps1') 'W:\Deploy\'
    $plan = New-FirstBootPlan -Answer $answer -AppDefinitions $apps -UserState $userState -BitLockerPin $bitLockerPin
    # What the post-deploy checks expect at the end of first boot (deploy-settings "checks" turns them off or tunes them).
    $checks = New-PostDeployCheckPlan -Answer $answer -ComputerName $ComputerName -AppDefinitions $apps -Settings $settings
    if ($checks) { $plan | Add-Member -NotePropertyName checks -NotePropertyValue $checks }
    # The new Windows can keep reporting only to a UNC path (as the computer account), not to WinPE's drive letters.
    if ($statusTarget -and $statusTarget.Unc) {
        $plan | Add-Member -NotePropertyName status -NotePropertyValue ([pscustomobject]@{ folder = $statusTarget.Unc; id = $statusId })
    }
    $plan | ConvertTo-Json -Depth 6 | Set-Content 'W:\Deploy\firstboot.json' -Encoding utf8
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
    # Which drivers this PC got, for the console's Unknown Models report. Never fails the deployment.
    if ($root -and $hw -and $driverMatch -and $status -ne 'CANCELLED') {
        try {
            Write-DriverReport -ContentRoot $root -Identity $hw -Match $driverMatch -ComputerName $ComputerName `
                -AnswerFile $(if ($answer) { $answer.Name }) -Result $status
        } catch { Write-Warning "Could not write the driver report: $($_.Exception.Message)" }
    }
}

if ($status -eq 'OK' -and $answer.Shutdown) { & wpeutil.exe shutdown }
elseif ($status -eq 'OK' -and $answer.Reboot) { & wpeutil.exe reboot }
if ($status -ne 'OK') { exit 1 }
