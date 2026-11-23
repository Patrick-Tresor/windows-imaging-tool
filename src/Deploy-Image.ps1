<#
.SYNOPSIS
    Deploys a Windows image to this PC from WinPE, driven by an answer file, and injects the matching OEM drivers.
.DESCRIPTION
    Launched by startnet.cmd. Finds content on a USB volume labelled DEPLOY, or on the network share in
    deploy-settings.json (ISO or network boot). Reads an answer file
    from <content root>\AnswerFiles: image, applications, disk, regional settings, naming,
    domain join, tasks, extra shares and BitLocker.
    A reimage started from the console's Computers tab left a job for this PC's BIOS serial in Reimage\ on the
    share (RemoteReimage.psm1): its answer file, computer name and OU are used without asking, after a countdown.
    Unless -NoPrompt, an Unattended answer file or such a job starts it, a graphical wizard
    (DeployWizard.psm1) lets the operator pick the answer file, name, OU, disk and applications.
    Wipes the target disk and partitions it GPT for UEFI. WinPE must be booted in UEFI mode.
.EXAMPLE
    X:\Deploy\Deploy-Image.ps1 -AnswerFile W11-Office-FR -NoPrompt
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [string]$AnswerFile,        # name in AnswerFiles\ without .xml; otherwise a reimage job's, the only one, or the wizard asks
    [string]$ComputerName,      # overrides the answer file's naming (the wizard still lets the operator change it)
    [switch]$NoPrompt           # no wizard, countdown or confirmation, whatever the answer file's mode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'JsonFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PostDeployChecks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LibraryPack.psm1') -Force   # Test-PackRequirement
Import-Module (Join-Path $PSScriptRoot 'AppPack.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TaskPack.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployWizard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecretVault.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SysprepAtDeploy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'FirstBootState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ToolVersion.psm1') -Force

# Passwords: encrypted in the answer file (decrypted with the answer file key in boot.wim or the vault), else typed
# by the operator (kept in memory only). Plain password files are never read.
# The answer files still name each password by its old password file path (passwordFile): only a name now.
$script:Vault = @{}
$script:AnswerKey = $null
$script:TypedSecrets = @{}
$script:CanAskSecrets = $false
# The share account's password the build encrypted in X:\Deploy\config\deploy-settings.json, decrypted with the
# answer file key in the boot image (or in the vault).
$script:DecryptShare = {
    param([string]$Value)
    if (-not $script:AnswerKey) { $script:AnswerKey = Find-AnswerKey -Vault $script:Vault -ScriptRoot $PSScriptRoot }
    if (-not $script:AnswerKey) { throw 'this boot image has no answer file key' }
    Unprotect-AnswerPassword -Value $Value -Key $script:AnswerKey
}

function Resolve-ContentPath([string]$Root, [string]$Path) {
    # Answer file paths are relative to the content root unless they are absolute (Y:\..., \\server\...).
    if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Root $Path }
}

function Add-AnswerPasswords([string]$Root, $Answer) {
    # The passwords encrypted in the answer file, decrypted now (key = normalized password file path), as
    # $Answer.Passwords. One that can't be decrypted is logged and left out: the wizard's Passwords page or
    # Get-DeploySecret then deals with it as a password that is not on the media.
    $map = @{}
    $Answer | Add-Member -NotePropertyName Passwords -NotePropertyValue $map -Force
    $encrypted = @(Get-AnswerSecrets -Answer $Answer | Where-Object Encrypted)
    if (-not $encrypted) { return }
    if (-not $script:AnswerKey) { $script:AnswerKey = Find-AnswerKey -Vault $script:Vault -ScriptRoot $PSScriptRoot -ContentRoot $Root }
    if (-not $script:AnswerKey) {
        Write-DeployLog "Answer file $($Answer.Name) has encrypted passwords but this media has no answer file key: rebuild the stick or boot image from the console" -Level WARN
        return
    }
    foreach ($s in $encrypted) {
        try { $map[$s.Key] = Unprotect-AnswerPassword -Value $s.Encrypted -Key $script:AnswerKey }
        catch { Write-DeployLog "$($s.Label) in answer file $($Answer.Name) not usable: $($_.Exception.Message)" -Level WARN }
    }
    if ($map.Count) { Write-DeployLog "Answer file $($Answer.Name): $($map.Count) encrypted password(s) decrypted" }
}

function Read-DeployAnswer([string]$Root, [string]$Name, [string]$JobOU) {
    # Reads an answer file; a reimage job's OU (the OU the PC was in) replaces the answer file's (domain joins only).
    $dir = [IO.Path]::Combine($Root, 'AnswerFiles')
    $path = [IO.Path]::Combine($dir, "$Name.xml")
    if (-not [IO.File]::Exists($path)) { throw "Answer file $Name not found in $dir." }
    $a = Read-AnswerFile -Path $path
    Add-AnswerPasswords -Root $Root -Answer $a
    if ($JobOU) {
        if ($a.Membership -eq 'Domain') { $a.OrganizationalUnit = $JobOU }
        else { Write-DeployLog "Reimage OU $JobOU ignored: answer file $($a.Name) joins a workgroup" -Level WARN }
    }
    $a
}

$script:Mounted = @{}
$script:DiskNotes = @{}
$script:PeDriversLoaded = $false
$script:NoDiskLogged = $false

function Get-ContentDiskNumber([string]$Root) {
    # The disk the content root is on (the USB stick's DEPLOY partition), or nothing for a network share.
    if ($Root -notmatch '^([A-Za-z]):') { return }
    try { (Get-Partition -DriveLetter $Matches[1] -ErrorAction Stop).DiskNumber } catch { }
}

function Assert-JoinAccount($Root, $Answer) {
    # Signs in to the domain with the join account now (Test-JoinAccount). A refused account stops the deploy before
    # the disk is wiped; a domain WinPE cannot reach is only logged, and the join is left to Windows as before.
    if ($Answer.Membership -ne 'Domain' -or -not $Answer.JoinPasswordFile) { return }
    $account = (Resolve-JoinAccount -Answer $Answer).Account
    $password = Get-DeploySecret -Root $Root -RelativePath $Answer.JoinPasswordFile -Answer $Answer -Label "password of the join account $account"
    $check = Test-JoinAccount -Domain $Answer.Domain -Account $account -Password $password
    if (-not $check.Cached) {
        switch ($check.Result) {
            'Passed'     { Write-DeployLog "Join account $account signed in to $($Answer.Domain)" }
            'NotChecked' { Write-DeployLog "Join account $account not checked: $($check.Reason)" -Level WARN }
            default      { Write-DeployLog "The domain $($Answer.Domain) refused the join account $($account): $($check.Reason) (error $($check.Code)). Fix the account or its password in the answer file, then copy it to the media." -Level ERROR }
        }
    }
    if ($check.Result -eq 'Refused') {
        # A typed password is asked again on the next try (the wizard's Next), not reused.
        $script:TypedSecrets.Remove((ConvertTo-SecretKey $Answer.JoinPasswordFile))
        throw "The domain refused the join account $account ($($check.Reason)). Fix it in the answer file." }
}

function Get-DeployPlan($Root, $Answer, $Hardware) {
    # Everything that must be found before the disk is wiped. The wizard calls this each time an answer file is picked,
    # so a problem (missing image, no disk, a wrong join password) shows there.
    # No Windows 11 hardware check: Windows is installed on any PC (Patrick, 2026-11-22).
    # Passwords not on the media were typed on the wizard's Passwords page; Get-DeploySecret says which one is missing.
    foreach ($share in $Answer.Shares) {
        if ($script:Mounted[$share.LocalName] -eq $share.RemoteName) { continue }
        $pw = if ($share.PasswordFile) { Get-DeploySecret -Root $Root -RelativePath $share.PasswordFile -Answer $Answer -Label "password for $($share.RemoteName)" } else { $null }
        # A user name that already names its domain (CORP\svc, svc@corp.example.com) gets no second one in front.
        $user = if ($share.Domain -and $share.Username -and $share.Username -notmatch '[\\@]') { "$($share.Domain)\$($share.Username)" } else { $share.Username }
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

    # The disk Windows goes on: never the USB stick or the disk holding the content, even when the answer file
    # says disk 0 and the stick took that number. The wizard preselects it; the operator can still pick another.
    $exclude = @(Get-ContentDiskNumber $Root)
    $target = Resolve-TargetDisk -Disks @(Get-Disk) -Requested $Answer.DiskNumber -Exclude $exclude
    if (-not $target.Disk -and -not $script:PeDriversLoaded) {
        # No internal disk: load the storage drivers on the stick or share (Drivers\_WinPE) and look again, once.
        $script:PeDriversLoaded = $true
        if (Import-WinPEDrivers -Folder (Join-Path $Root 'Drivers\_WinPE')) {
            $target = Resolve-TargetDisk -Disks @(Get-Disk) -Requested $Answer.DiskNumber -Exclude $exclude
        }
    }
    if (-not $target.Disk) {
        # Logged once, however often the wizard's Next is pressed; the wizard shows the short line.
        if (-not $script:NoDiskLogged) {
            $script:NoDiskLogged = $true
            Write-DeployLog $target.Reason -Level ERROR
            foreach ($d in @(Get-DevicesWithoutDriver)) { Write-DeployLog "No driver in WinPE for: $d" -Level WARN }
        }
        throw $target.Short
    }
    if ($target.Disk.Number -ne $Answer.DiskNumber) {
        if ($script:DiskNotes[$Answer.Name] -ne $target.Reason) { Write-DeployLog "Target disk: $($target.Reason)" -Level WARN }
        $Answer.DiskNumber = $target.Disk.Number
    } elseif ($script:DiskNotes[$Answer.Name] -ne $target.Reason) { Write-DeployLog "Target disk: $(Format-DiskChoice $target.Disk), $($target.Reason)" }
    $script:DiskNotes[$Answer.Name] = $target.Reason

    # The domain join account is checked now, before the disk is wiped: a wrong password would otherwise only show
    # after the restart.
    Assert-JoinAccount -Root $Root -Answer $Answer

    $driverRoot = Resolve-ContentPath $Root $Answer.DriverRoot
    $driverMatch = Resolve-DriverPack -Identity $Hardware -CatalogPath (Join-Path $Root 'config\driver-catalog.json') -DriverRoot $driverRoot -WinPEDriverRoot (Join-Path $Root 'Drivers\_WinPE') -Detailed

    # The wizard offers every application in the library, not only the answer file's.
    $appRoot = Resolve-ContentPath $Root $Answer.AppLocation
    $available = @(Get-ChildItem -Path $appRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'app.json') } | ForEach-Object Name)

    # Only an older answer file with a WMI query other than the serial number runs it (Read-AnswerFile).
    $wmiValue = if ($Answer.NamingMode -ne 'WMI') { $Hardware.Serial } else { try { Get-WmiNamingValue -Query $Answer.WmiQuery } catch { Write-DeployLog "WMI naming query failed: $($_.Exception.Message)" -Level WARN; $Hardware.Serial } }
    if (-not $wmiValue) { $wmiValue = $Hardware.Serial }

    # Extra summary lines, shown before ERASE in the wizard and on the console.
    $bl = $Answer.BitLocker
    $details = @(
        "BitLocker:    $(if ($bl.Enabled) { "$($bl.Protector), $($bl.EncryptionMethod), at first boot" } else { 'off' })"
    )

    [pscustomobject]@{
        ImagePath     = $imagePath
        DriverMatch   = $driverMatch
        DriverPack    = $driverMatch.FullPath
        DriverRoot    = $driverRoot
        AppRoot       = $appRoot
        AvailableApps = $available
        WmiValue      = $wmiValue
        DefaultName   = Resolve-ComputerName -Answer $Answer -WmiValue $wmiValue -Serial $Hardware.Serial
        NameSource    = "answer file, $(if ($Answer.NamingMode -eq 'Custom') { "pattern $($Answer.CustomScheme)" } else { $Answer.WmiQuery })"
        Details       = $details
    }
}

function Unlock-DeployMedia {
    # Media built with a WinPE password carry config\vault.json: nothing runs until the operator types it.
    # Five wrong tries or Shut down turn the PC off (exit code 3 tells startnet.cmd to shut down too).
    $path = Join-Path $PSScriptRoot 'config\vault.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $vault = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $problem = $null
    for ($try = 1; $try -le 5; $try++) {
        $pw = Show-PasswordPrompt -Message 'This deployment media is locked. Type the WinPE password to continue.' -Problem $problem -CancelText 'Shut down'
        if ($null -eq $pw) { break }
        $secrets = Unlock-SecretVault -Vault $vault -Password $pw
        if ($null -ne $secrets) {
            $script:Vault = $secrets
            Write-DeployLog "WinPE unlocked; $($secrets.Count) item(s) in the vault"
            return
        }
        Write-DeployLog "Wrong WinPE password (try $try of 5)" -Level WARN
        $problem = "Wrong password. $(5 - $try) tries left."
    }
    Write-DeployLog 'WinPE password not given: shutting down' -Level ERROR
    & wpeutil.exe shutdown
    exit 3
}

function Get-DeploySecret([string]$Root, [string]$RelativePath, $Answer, [string]$Label) {
    # A password the answer file needs (named by its passwordFile path): decrypted from the answer file, or typed on
    # the wizard's Passwords page. Throws when it is neither, before anything is erased.
    if (-not $RelativePath) { throw "No password file is set for $Label in the answer file." }
    $key = ConvertTo-SecretKey $RelativePath
    if ($Answer -and $Answer.PSObject.Properties['Passwords'] -and $Answer.Passwords.ContainsKey($key)) { return $Answer.Passwords[$key] }
    if ($script:Vault.ContainsKey($key)) { return $script:Vault[$key] }
    if ($script:TypedSecrets.ContainsKey($key)) { return $script:TypedSecrets[$key] }
    # The wizard's Passwords page asks for every password Get-AnswerSecrets lists, so this is a password nobody was
    # asked for (no wizard: -NoPrompt or a reimage job), or one the answer file names in a way it does not know.
    throw "The $Label ($RelativePath) is not on this media. Type it in the answer file editor and rebuild the stick (it is saved encrypted in the answer file)."
}

function Test-DeploySecretKnown([string]$Root, [string]$RelativePath, $Answer) {
    # True when Get-DeploySecret can return this password without asking anyone.
    $key = ConvertTo-SecretKey $RelativePath
    $inAnswer = $Answer -and $Answer.PSObject.Properties['Passwords'] -and $Answer.Passwords.ContainsKey($key)
    $inAnswer -or $script:Vault.ContainsKey($key) -or $script:TypedSecrets.ContainsKey($key)
}

function Get-MissingDeploySecrets([string]$Root, $Answer) {
    # The passwords this answer file needs that are not on the media, in the vault or typed already: the wizard's
    # Passwords page asks for exactly these, all at once, so nothing pops up once Windows starts installing.
    # Nothing when nobody is at the PC to type them (Get-DeploySecret then says what is missing).
    if (-not $script:CanAskSecrets) { return @() }
    @(Get-AnswerSecrets -Answer $Answer | Where-Object {
        -not ($_.Share -and $script:Mounted[$_.Share]) -and -not (Test-DeploySecretKnown -Root $Root -RelativePath $_.RelativePath -Answer $Answer)
    })
}

function Save-TypedSecrets([hashtable]$Values, [object[]]$Secrets) {
    # Keeps what the operator typed (key -> text) in memory for this deployment only; never written anywhere.
    foreach ($s in $Secrets) {
        if (-not $Values.ContainsKey($s.Key) -or -not $Values[$s.Key]) { continue }
        $script:TypedSecrets[$s.Key] = $Values[$s.Key]
        Write-DeployLog "$($s.Label) typed by the operator ($($s.RelativePath) is not on the media)"
    }
}

function Protect-StagedItem([string]$Path, [switch]$Folder) {
    # Administrators and SYSTEM only (Get-AdminOnlyAclArgs): C:\Temp lets every signed-in user change what is in it,
    # and first boot keeps the BitLocker PIN there and runs the installers as SYSTEM. A failure only warns.
    $out = & icacls.exe @(Get-AdminOnlyAclArgs -Path $Path -Folder:$Folder) 2>&1
    if ($LASTEXITCODE -ne 0) { Write-DeployLog "Could not limit $Path to administrators (icacls exit $LASTEXITCODE): $(@($out) -join ' ')" -Level WARN }
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

function Wait-MediaRemoval([string]$Root, [int]$Seconds = 60) {
    # Waits until the USB stick holding the content is pulled out, at most $Seconds. The progress window counts down.
    try {
        for ($s = $Seconds; $s -gt 0; $s--) {
            if (-not (Test-Path -LiteralPath $Root)) { Write-Host ''; Write-DeployLog 'USB stick removed'; return }
            Write-Host -NoNewline "`rRemove the USB stick now. Continuing in $s s. "
            Set-DeployStatus -LocalOnly -Fields @{ removeMedia = $s }
            Start-Sleep -Seconds 1
        }
        Write-Host ''
        Write-DeployLog 'USB stick still in; continuing (the next boot is set to Windows Boot Manager on UEFI PCs)' -Level WARN
    }
    finally { Set-DeployStatus -LocalOnly -Fields @{ removeMedia = 0 } }
}

function Start-ProgressWindow([string]$ProgressPath) {
    # The window on this PC's screen (DeployProgressWindow.ps1), in its own process so it keeps redrawing while DISM runs.
    try {
        $script = Join-Path $PSScriptRoot 'DeployProgressWindow.ps1'
        # The process, so the end of this script can tell whether the window is still there to show a failure.
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script`"",
            '-ProgressPath', "`"$ProgressPath`"", '-DeployProcessId', $PID)
    } catch {
        Write-DeployLog "Progress window not started: $($_.Exception.Message)" -Level WARN
        $false
    }
}

$script:LastDashboardWrite = [datetime]::MinValue
function Update-NativeStepStatus([string]$Step, [Nullable[int]]$Percent) {
    # Progress of a running DISM step. The local window gets every update; the dashboard (a file on a share)
    # every 15 s, which is also its heartbeat.
    $update = @{}
    if ($Step) { $update.Step = $Step }
    if ($null -ne $Percent) { $update.Percent = $Percent }
    if (((Get-Date) - $script:LastDashboardWrite).TotalSeconds -ge 15) {
        $script:LastDashboardWrite = Get-Date
        Set-DeployStatus @update
    } else { Set-DeployStatus -LocalOnly @update }
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
        if ($Settings.share.user) {
            # The password the console encrypted into the settings. Without a password net use would stop and prompt,
            # so the account is only passed when its password is known.
            $cred = Get-ShareCredential -SettingsPath $SettingsPath -Decrypt $script:DecryptShare
            if ($cred.Password) { $user = $Settings.share.user; $pw = $cred.Password }
        }
        Mount-NetworkShare -LocalName 'R:' -RemoteName $target.Map -User $user -Password $pw
        $target
    } catch {
        # A USB deploy (content on the stick, not the share's Z:) keeps its status on the stick instead, so the
        # console still shows it once the stick is plugged in there (Import-StickDeployStatus). No first boot reporting.
        if ($Root.TrimEnd('\') -ne 'Z:') {
            Write-DeployLog "Status share $($target.Map) unavailable ($($_.Exception.Message)); keeping the status on the USB stick for the console's dashboard" -Level WARN
            return Resolve-StatusTarget -ContentRoot $Root
        }
        Write-DeployLog "Status share $($target.Map) unavailable, no progress reporting: $($_.Exception.Message)" -Level WARN
        $null
    }
}

function Set-SysprepAtDeploy([string]$UnattendXml) {
    # The image was captured without sysprep: copy the first-start sysprep script to the new Windows and make it run
    # once at its next start (src\SysprepAtDeploy.psm1). Its offline registry is loaded with reg.exe, as WinPE has
    # no other way to write it; it is always unloaded again, or bcdboot and the restart would find it in use.
    $ErrorActionPreference = 'Continue'   # reg.exe query writes to stderr for a missing value; failures still throw
    $folder = 'W:\ProgramData\ImagingTool\Sysprep'
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'Invoke-SysprepAtDeploy.ps1'), (Join-Path $PSScriptRoot 'SysprepAtDeploy.psm1'), (Join-Path $PSScriptRoot 'ScriptLog.psm1'),
        (Join-Path $PSScriptRoot 'Prepare-Reference.ps1') $folder -Force -ErrorAction Stop
    # sysprep /unattend caches its own copy in Windows\Panther; the script deletes this one as soon as sysprep returns.
    $UnattendXml | Set-Content -Path (Join-Path $folder 'unattend.xml') -Encoding utf8 -ErrorAction Stop
    $hive = 'HKLM\ImagingToolTarget'
    # reg.exe output goes to the log only: the deploy screen shows nothing about sysprep.
    $quietReg = {
        param([string[]]$RegArgs)
        Add-Content -Path 'X:\Windows\Temp\Deploy.log' -Value ("  > reg.exe $($RegArgs -join ' ')") -ErrorAction SilentlyContinue
        $out = & reg.exe @RegArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "reg.exe $($RegArgs[0]) failed (exit $LASTEXITCODE): $out" }
    }
    & $quietReg @('load', $hive, 'W:\Windows\System32\config\SYSTEM')
    try {
        $controlSet = Get-ControlSetName -Lines @(& reg.exe query "$hive\Select" /v Current 2>$null)
        $hasPrevent = Test-RegQueryHasValue -Name 'PreventDeviceEncryption' -Lines @(& reg.exe query "$hive\$controlSet\Control\BitLocker" /v PreventDeviceEncryption 2>$null)
        foreach ($regArgs in (Get-SysprepHookRegArgs -HiveKey $hive -Command (Get-SysprepHookCommand) -ControlSet $controlSet -PreventDeviceEncryption:(-not $hasPrevent))) {
            & $quietReg $regArgs
        }
    }
    finally {
        [GC]::Collect()
        for ($i = 0; $i -lt 5; $i++) {
            & reg.exe unload $hive 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 1
        }
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "Could not unload the new Windows' registry ($hive)." -Level WARN }
    }
    Save-JsonFile -Path (Join-Path $folder 'sysprep.json') -InputObject ([pscustomobject]@{ preventDeviceEncryptionSet = (-not $hasPrevent); controlSet = $controlSet })
    Add-Content -Path 'X:\Windows\Temp\Deploy.log' -Value ('{0:yyyy-MM-dd HH:mm:ss} [INFO] Sysprep set up for the first start of this PC.' -f (Get-Date)) -ErrorAction SilentlyContinue
}

function Invoke-Phase([string]$Phase, [object[]]$Tasks, [string]$Root) {
    # POSTIMAGE tasks run here in WinPE with the new Windows at %OSDRIVE% (W:) and content at %DEPLOYROOT%.
    # A task stops the deployment when it fails only when it is set to (stopOnFailure); plain commands always are.
    $env:OSDRIVE = 'W:'
    $env:DEPLOYROOT = $Root.TrimEnd('\')
    foreach ($t in @($Tasks | Where-Object Phase -eq $Phase)) {
        Write-DeployLog "Running task $($t.Name)"
        Set-DeployStatus -Step "Running task $($t.Name)"
        # The log stays on the new Windows, next to Deploy.log.
        $logName = Get-TaskLogName $t.Name
        $r = try { Invoke-TaskPack -Definition $t.Definition -Folder $t.Folder -ExtraArguments $t.Arguments -LogPath "W:\Windows\Temp\$logName" -Log { param($m) Write-DeployLog $m } }
             catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; Message = $_.Exception.Message } }
        if ($r.Status -eq 'Succeeded') { Write-DeployLog "  task $($t.Name) OK ($($r.Message))"; continue }
        if ($t.Definition.stopOnFailure) { throw "Task $($t.Name) $($r.Status.ToLowerInvariant()): $($r.Message). See C:\Windows\Temp\$logName." }
        Write-DeployLog "  task $($t.Name) $($r.Status): $($r.Message)" -Level WARN
        Set-DeployStatus -Warning "Task $($t.Name) $($r.Status.ToLowerInvariant())"
    }
}

# Locked media: the WinPE password first, before the content, the wizard or anything else.
# The deploy windows fill the screen and show the log, so the console window behind them is hidden in WinPE.
# Whatever stops this script before its own end (the trap) or makes it fail with no progress window brings the
# console back, so startnet.cmd's command prompt and the error can be seen.
[void](Set-DeployConsoleWindow)
trap { [void](Set-DeployConsoleWindow -Show); break }

Unlock-DeployMedia

$root = $null; $hw = $null; $answer = $null; $driverMatch = $null; $plan = $null; $statusTarget = $null; $logName = $null
$progressWindow = $false; $onStick = $false; $job = $null
$status = 'FAILED'; $failure = $null
try {
    # A wide console whose lines wrap instead of running off the right edge.
    Set-DeployConsole
    # Which version of the tool built this media: the first thing to check when a fix "did not work" (old stick).
    $toolVersion = Get-ToolVersion -SourceRoot $PSScriptRoot
    $deployStarted = Get-Date
    $script:DriversInjected = $null
    Write-DeployLog "Imaging tool version $($toolVersion.Text)"
    $hw = Get-HardwareIdentity
    Write-DeployLog ("Hardware: {0} | {1} | type {2} | SKU {3} | serial {4} | UEFI {5}" -f
        $hw.Maker, $hw.Model, $hw.MachineType, $hw.Sku, $hw.Serial, $hw.IsUefi)

    # Every Set-DeployStatus from here on also updates the progress window on this PC's screen.
    $progressPath = 'X:\Windows\Temp\DeployProgress.json'
    Start-LocalProgress -Path $progressPath -Identity $hw
    $progressWindow = Start-ProgressWindow -ProgressPath $progressPath

    Set-DeployStatus -LocalOnly -Step 'Looking for the deployment content (USB DEPLOY volume or network share)' -Percent 1
    $root = Find-ContentRoot -SettingsPath $SettingsPath -Decrypt $script:DecryptShare
    # Which WinPE drivers this boot image was built with, so "no internal disk" can be explained from the log.
    Write-WinPEDriverReport -Path (Join-Path $PSScriptRoot 'config\winpe-drivers.json')
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
    # Only UEFI deploys (GPT disk). A PC whose USB stick or network boot started WinPE through CSM/legacy BIOS stops here,
    # before anything is erased.
    if (-not $hw.IsUefi) {
        Write-DeployLog 'Legacy BIOS deploys are not supported. Restart, and in the boot menu pick the UEFI entry for the USB stick or network (or turn off CSM/legacy boot in the firmware settings).' -Level ERROR
        throw 'WinPE started in legacy BIOS mode. Boot it in UEFI mode.'
    }

    # A reimage from the console's Computers tab: a job for this PC's serial on the share. Taking it moves it to
    # Reimage\Started, so WinPE starting again on this PC does not reimage it a second time.
    if ($null -eq (Get-ContentDiskNumber $root)) {
        try {
            $uuid = "$((Get-CimInstance Win32_ComputerSystemProduct).UUID)".Trim()
            $job = Receive-ReimageJob -ContentRoot $root -Serial "$($hw.Serial)" -Uuid $uuid -OnNote { param($m) Write-DeployLog $m -Level WARN }
        } catch { Write-DeployLog "Could not check the share for a reimage job: $($_.Exception.Message)" -Level WARN }
    }
    if ($job) {
        Write-DeployLog ("Reimage requested by {0} at {1}: answer file {2}, name '{3}', OU '{4}'" -f $job.requestedBy, $job.requestedAt, $job.answerFile, $job.computerName, $job.ou)
        $AnswerFile = $job.answerFile
        if ($job.computerName -and -not $ComputerName) {
            if (Test-GenericComputerName $job.computerName) {
                Write-DeployLog "Not keeping the name $($job.computerName): Windows made it up; the PC is named by the answer file"
            } else { $ComputerName = $job.computerName }
        }
    }
    $givenName = $ComputerName
    # Someone is at this PC to type a password that is not on the media, unless -NoPrompt or a reimage job started it.
    $script:CanAskSecrets = -not $NoPrompt -and -not $job

    # A reimage puts the PC back into the OU it was in, whatever the answer file says.
    $jobOU = if ($job) { "$($job.ou)" } else { '' }

    $names = @(Get-AnswerFileNames -ContentRoot $root -Required)
    if (-not $AnswerFile) {
        if ($names.Count -eq 1) { $AnswerFile = $names[0] }
        elseif ($NoPrompt) { throw "There are $($names.Count) answer files ($($names -join ', ')): pass -AnswerFile to choose one." }
    }
    $readAnswer  = { param($Name) Read-DeployAnswer -Root $root -Name $Name -JobOU $jobOU }
    $missingSecrets = { param($Answer) Get-MissingDeploySecrets -Root $root -Answer $Answer }
    $saveSecrets = { param($Values, $Secrets) Save-TypedSecrets -Values $Values -Secrets $Secrets }
    $preparePlan = { param($Answer) Get-DeployPlan -Root $root -Answer $Answer -Hardware $hw }

    # -NoPrompt and Unattended answer files start without the wizard. A key pressed during
    # the countdown opens the wizard instead, so the operator can change anything.
    $deployPlan = $null; $confirmed = $false; $wizardNotice = $null
    # A Windows deployed here that never started means the PC came back to WinPE after the restart, usually because
    # the USB stick is still first in the boot order. Ask instead of counting down, or it would be wiped again.
    # Only a safety check: if it fails, log it and carry on, so it can never stop a deploy.
    $unstarted = $null
    if (-not $NoPrompt -and -not $job) {
        try { $unstarted = Find-UnstartedDeployment -Serial "$($hw.Serial)" -ExcludeRoots @($root) }
        catch { Write-DeployLog "Could not check this PC's disks for an earlier deployment: $($_.Exception.Message)" -Level WARN }
    }
    if ($unstarted) {
        Write-DeployLog ("Windows was deployed to this PC at {0} ({1}) and has not started yet: no countdown. Remove the USB stick and restart to start Windows." -f $unstarted.deployed, $unstarted.path) -Level WARN
        $wizardNotice = 'Windows is already installed here but has not started. Remove the USB stick and restart, or deploy again.'
    }
    if ($AnswerFile) {
        $answer = & $readAnswer $AnswerFile
        # Passwords are typed only on the wizard's Passwords page: an Unattended answer file that needs one opens the
        # wizard instead of counting down.
        $needsPasswords = $answer.Mode -eq 'Unattended' -and -not $NoPrompt -and -not $job -and @(& $missingSecrets $answer).Count
        if ($needsPasswords) {
            Write-DeployLog 'The answer file needs passwords that are not on this media: opening the wizard instead of the countdown' -Level WARN
            if (-not $wizardNotice) { $wizardNotice = 'Some passwords are not on this USB stick: type them on the Passwords page.' }
        }
        if ($NoPrompt) { $confirmed = $true }
        elseif (($answer.Mode -eq 'Unattended' -and -not $unstarted -and -not $needsPasswords) -or $job) {
            $deployPlan = & $preparePlan $answer
            $name = if ($ComputerName) { $ComputerName } else { $deployPlan.DefaultName }
            Write-Host ''
            Get-DeploySummary -Answer $answer -Plan $deployPlan -ComputerName $name -Disk (Get-Disk -Number $answer.DiskNumber) -Applications $answer.Applications |
                ForEach-Object { Write-Host $_ }
            Set-DeployStatus -Step 'Counting down' -Percent 5
            # Nobody may be at a PC reimaged from the console: count down, so someone who is can still stop it.
            $confirmed = Wait-Countdown $(if ($job) { [Math]::Max([int]$answer.UnattendDelay, 15) } else { $answer.UnattendDelay })
            if ($confirmed) { $ComputerName = $name } else { Write-DeployLog 'Countdown cancelled by operator' -Level WARN }
        }
    }

    if (-not $confirmed) {
        Set-DeployStatus -Step 'Waiting for the operator' -Percent 5
        $choice = Show-DeployWizard -Hardware $hw -AnswerFiles $names -Default $AnswerFile -ComputerName $ComputerName `
            -ReadAnswer $readAnswer -PreparePlan $preparePlan -MissingSecrets $missingSecrets -SaveSecrets $saveSecrets -Disks @(Get-TargetDisks -Exclude @(Get-ContentDiskNumber $root)) -Notice $wizardNotice
        if (-not $choice) { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
        $answer = $choice.Answer; $deployPlan = $choice.Plan; $ComputerName = $choice.ComputerName
        $confirmed = $true
    }

    if (-not $deployPlan) { $deployPlan = & $preparePlan $answer }
    if (-not $ComputerName) { $ComputerName = $deployPlan.DefaultName }
    $nameSource = if ($givenName -and $ComputerName -eq $givenName) { if ($job -and $job.computerName -eq $givenName) { 'kept from Active Directory' } else { 'parameter' } }
                  elseif ($ComputerName -eq $deployPlan.DefaultName) { $deployPlan.NameSource } else { 'typed by the operator' }
    Write-DeployLog "Answer file: $($answer.Name) ($($answer.Mode)), name $ComputerName ($nameSource), disk $($answer.DiskNumber)"
    Set-DeployStatus -Step 'Checking the answer file' -Percent 6 -Fields @{ answerFile = $answer.Name; image = $answer.ImageFile; computerName = $ComputerName; toolVersion = $toolVersion.Text }

    $imagePath = $deployPlan.ImagePath; $driverMatch = $deployPlan.DriverMatch; $driverPack = $deployPlan.DriverPack
    $driverRoot = $deployPlan.DriverRoot; $appRoot = $deployPlan.AppRoot
    $driverPackName = if (-not $driverPack) { 'inbox only' } elseif ($driverPack.StartsWith($driverRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { $driverPack.Substring($driverRoot.TrimEnd('\').Length).TrimStart('\') } else { $driverPack }
    Set-DeployStatus -Fields @{ driverPack = $driverPackName; driverStatus = "$($driverMatch.Status)" }   # driverStatus: the Unknown Models report
    if (-not $driverPack) { Set-DeployStatus -Warning "No driver pack for $($hw.Maker) $($hw.Model)" }

    # Applications are checked now, before the disk is wiped.
    # Apps limited to other makers or models (Dell Command Update on a Lenovo) are left out.
    $apps = @($answer.Applications | ForEach-Object { Get-AppDefinition -AppRoot $appRoot -Name $_ } | Where-Object {
        if (Test-PackRequirement -Definition $_ -Identity $hw) { return $true }
        Write-DeployLog "Skipping application $($_.name): it is for $((@($_.requirements.makers) + @($_.requirements.models)) -join ', ') only"
        $false
    })
    # So are the task library's scripts: a missing or broken one stops here, not halfway through.
    $taskRoot = Resolve-ContentPath $root $answer.TaskLocation
    $deployTasks = @(Resolve-DeployTasks -Answer $answer -TaskRoot $taskRoot -Identity $hw -OnSkip { param($m) Write-DeployLog $m })
    $libraryTasks = @($deployTasks | Where-Object Folder)   # the ones with a folder to stage
    if ($libraryTasks) { Write-DeployLog "Tasks: $(($libraryTasks | ForEach-Object { "$($_.Name) ($($_.Phase))" }) -join ', ')" }

    $joinPassword  = if ($answer.Membership -eq 'Domain') { Get-DeploySecret -Root $root -RelativePath $answer.JoinPasswordFile -Answer $answer -Label 'join account password' } else { $null }
    if ($answer.Membership -eq 'Domain') {
        # CORP\svc typed as the user name with another account's domain: the user name wins (Resolve-JoinAccount).
        $joinNote = (Resolve-JoinAccount -Answer $answer).Note
        if ($joinNote) { Write-DeployLog $joinNote -Level WARN }
    }
    $adminPassword = if ($answer.EnableAdministrator) { Get-DeploySecret -Root $root -RelativePath $answer.AdminPasswordFile -Answer $answer -Label 'local Administrator password' } else { $null }
    $bl = $answer.BitLocker
    $bitLockerPin  = if ($bl.Enabled -and $bl.Protector -eq 'TpmPin') { Get-DeploySecret -Root $root -RelativePath $bl.PinFile -Answer $answer -Label 'BitLocker PIN' } else { $null }

    # The unattend is built and checked now, before the disk is wiped: a setting Windows Setup rejects would only show
    # after the restart, as "could not parse or process the unattend answer file" at Getting ready.
    # FIRSTLOGON tasks (plain commands too) run through Run-LogonTask.ps1 in C:\ProgramData\ImagingTool\Tasks, which
    # stays after first boot clears C:\Temp, so they get the same timeout, success codes and log as FIRSTBOOT tasks.
    $logonCount = @($deployTasks | Where-Object Phase -eq 'FIRSTLOGON').Count
    $logonCommands = @(for ($i = 0; $i -lt $logonCount; $i++) { Get-LogonTaskCommand -Index $i })
    $unattendXml = New-UnattendXml -Answer $answer -ComputerName $ComputerName -JoinPassword $joinPassword -AdminPassword $adminPassword -LogonCommands $logonCommands
    $unattendProblems = @(Test-UnattendXml -Xml $unattendXml)
    if ($unattendProblems) {
        foreach ($up in $unattendProblems) { Write-DeployLog "Windows settings (unattend.xml): $up" -Level ERROR }
        throw "Windows would reject these settings: $($unattendProblems[0]) Nothing was erased."
    }

    $disk = Get-Disk -Number $answer.DiskNumber

    $summary = @(Get-DeploySummary -Answer $answer -Plan $deployPlan -ComputerName $ComputerName -Disk $disk -Applications @($apps | ForEach-Object name))
    foreach ($line in $summary) { Write-DeployLog $line }

    # 1. Partition: EFI, MSR, Windows, Recovery.
    Set-DeployStatus -Step 'Partitioning the disk' -Percent 8
    $dp = Join-Path $env:TEMP 'diskpart.txt'
    New-DiskpartScript -DiskNumber $answer.DiskNumber | Set-Content -Path $dp -Encoding ascii
    Invoke-Native -FilePath 'diskpart.exe' -ArgumentList @('/s', $dp)

    # 2. Apply the image. Split images (.swm) need /SWMFile.
    $applyArgs = @('/Apply-Image', "/ImageFile:$imagePath", "/Index:$($answer.ImageIndex)", '/ApplyDir:W:\')
    if ($imagePath -like '*.swm') { $applyArgs += "/SWMFile:$($imagePath -replace '\.swm$', '*.swm')" }
    # The longest step: DISM's percentage maps to 10-70 % overall. The window on this PC follows every few seconds;
    # the dashboard gets a write at most every 15 s (Update-NativeStepStatus).
    Set-DeployStatus -Step 'Applying the image' -Percent 10
    Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList $applyArgs -OnProgress {
        param($pct)
        if ($null -ne $pct) { Update-NativeStepStatus -Step "Applying the image: $pct %" -Percent (10 + [int]($pct * 0.6)) }
        else { Update-NativeStepStatus }
    }

    # 3. Inject the OEM driver pack offline.
    if ($driverPack) {
        # 72-79 % overall, by the count of drivers DISM has installed.
        Set-DeployStatus -Step 'Injecting drivers' -Percent 72
        $injectDrivers = {
            $driverSource = $driverPack
            $unpacked = $null
            try {
                if ($driverPack -like '*.wim') {
                    # The stick carries the pack as one file (fast to copy): unpack it onto the new Windows
                    # partition, add the drivers from there, then delete the copy.
                    $unpacked = 'W:\_ImagingDrivers'
                    [void][IO.Directory]::CreateDirectory($unpacked)
                    Set-DeployStatus -Step 'Unpacking drivers' -Percent 72
                    Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList @('/Apply-Image', "/ImageFile:$driverPack", '/Index:1', "/ApplyDir:$unpacked") -OnProgress {
                        param($pct)
                        if ($null -ne $pct) { Update-NativeStepStatus -Step "Unpacking drivers: $pct %" -Percent 72 }
                        else { Update-NativeStepStatus }
                    }
                    $driverSource = $unpacked
                    Set-DeployStatus -Step 'Injecting drivers' -Percent 72
                }
                Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList (Get-AddDriverArgs -ImageRoot 'W:\' -DriverPath $driverSource) -OnProgress {
                    param($pct, $info)
                    if ($info -and $info.Total) {
                        $script:DriversInjected = [int]$info.Total
                        Update-NativeStepStatus -Step "Injecting drivers: $($info.Done) of $($info.Total) ($pct %)" -Percent (72 + [int]($pct * 0.07))
                    } else { Update-NativeStepStatus }
                }
            } finally {
                # rd, not Remove-Item: W: was made by diskpart after PowerShell started, so it has no PowerShell drive.
                if ($unpacked) { try { & cmd.exe /c "rd /s /q `"$unpacked`"" 2>&1 | Out-Null } catch { } }
            }
        }
        if ($driverMatch -and $driverMatch.PSObject.Properties['WinPEFallback'] -and $driverMatch.WinPEFallback) {
            # A model with no driver pack gets the WinPE packs' storage and network drivers. They are a bonus, made
            # for WinPE: a DISM error on them must not stop a deploy whose disk is already erased.
            try { & $injectDrivers }
            catch {
                Write-DeployLog "Not every WinPE driver could be added to Windows ($($_.Exception.Message)); Windows uses its own drivers for the rest. DISM's log: X:\Windows\Logs\DISM\dism.log" -Level WARN
                Set-DeployStatus -Warning "Some WinPE drivers not added for $($hw.Maker) $($hw.Model)"
            }
        } else { & $injectDrivers }
        # For the end-of-deploy summary (dashboard and C:\Windows\Temp\DeployResult.txt).
        if ($null -ne $script:DriversInjected) {
            Write-DeployLog "$($script:DriversInjected) driver(s) added from $driverPackName"
            Set-DeployStatus -Fields @{ driversAdded = $script:DriversInjected }
        }
    }

    # An image captured from a VM that was only shut down (the capture wizard's "sysprep on each PC" choice) is
    # generalized by this PC at its first start; everything below is the same as for a sysprepped image.
    $imageState = Get-OfflineImageState -Root 'W:\'
    $sysprepOnPC = -not $imageState.Generalized
    # Only the log says so: whoever deploys sees the usual steps.
    if ($sysprepOnPC) { Add-Content -Path 'X:\Windows\Temp\Deploy.log' -Value ('{0:yyyy-MM-dd HH:mm:ss} [INFO] The image was not sysprepped ({1}), so this PC runs sysprep at its first start.' -f (Get-Date), $imageState.ImageState) -ErrorAction SilentlyContinue }

    # 4. Unattend generated from the answer file. Setup blanks the passwords in it after use.
    Set-DeployStatus -Step 'Writing Windows settings' -Percent 80
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    $logonPlan = @(New-LogonTaskPlan -Tasks $deployTasks)
    $unattendXml | Set-Content -Path 'W:\Windows\Panther\unattend.xml' -Encoding utf8
    $joinText = if ($answer.Membership -eq 'Domain') { "joins $($answer.Domain) as $((Resolve-JoinAccount -Answer $answer).Account)" } else { "workgroup $($answer.Workgroup)" }
    Write-DeployLog "Unattend written: name $ComputerName, $joinText"

    # 5. First boot: applications and FIRSTBOOT tasks run as SYSTEM from SetupComplete.cmd.
    Set-DeployStatus -Step 'Staging applications' -Percent 82
    # Both folders are limited to administrators before anything goes in, so what is copied (or downloaded at first
    # boot) in them gets the same rights.
    foreach ($f in 'W:\Temp\Apps', 'W:\Temp\Tasks') {
        New-Item -ItemType Directory -Path $f -Force | Out-Null
        Protect-StagedItem -Path $f -Folder
    }
    foreach ($app in $apps) {
        Write-DeployLog "Staging application $($app.name)"
        Copy-Item -Path (Join-Path $appRoot $app.name) -Destination 'W:\Temp\Apps\' -Recurse -Force
    }
    # Library tasks: FIRSTBOOT ones next to the applications, FIRSTLOGON ones where the first user's logon finds them.
    foreach ($t in @($libraryTasks | Where-Object Phase -in 'FIRSTBOOT', 'FIRSTLOGON')) {
        $dest = if ($t.Phase -eq 'FIRSTBOOT') { 'W:\Temp\Tasks' } else { 'W:\ProgramData\ImagingTool\Tasks' }
        Write-DeployLog "Staging task $($t.Name) ($($t.Phase))"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path $t.Folder -Destination $dest -Recurse -Force
    }
    if ($logonPlan) {
        $logonDir = 'W:\ProgramData\ImagingTool\Tasks'
        Copy-Item (Join-Path $PSScriptRoot 'Run-LogonTask.ps1'), (Join-Path $PSScriptRoot 'TaskPack.psm1'), (Join-Path $PSScriptRoot 'LibraryPack.psm1') $logonDir -Force
        Save-JsonFile -Path (Join-Path $logonDir 'logon-tasks.json') -InputObject $logonPlan -Depth 8
    }
    Copy-Item (Join-Path $PSScriptRoot 'FirstBoot.ps1'), (Join-Path $PSScriptRoot 'DeployStatus.psm1'),
        (Join-Path $PSScriptRoot 'PostDeployChecks.psm1'), (Join-Path $PSScriptRoot 'Test-Deployment.ps1'),
        (Join-Path $PSScriptRoot 'AppPack.psm1'), (Join-Path $PSScriptRoot 'TaskPack.psm1'), (Join-Path $PSScriptRoot 'LibraryPack.psm1'),
        (Join-Path $PSScriptRoot 'ScriptLog.psm1'), (Join-Path $PSScriptRoot 'FirstBootState.psm1') 'W:\Temp\'
    # Removes the passwords from unattend.xml once OOBE is over (FirstBoot.ps1 sets up the logon task that runs it).
    # It runs as SYSTEM, so only Administrators and SYSTEM may change it.
    New-Item -ItemType Directory -Path 'W:\ProgramData\ImagingTool' -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'Clear-UnattendPasswords.ps1'), (Join-Path $PSScriptRoot 'ScriptLog.psm1') 'W:\ProgramData\ImagingTool\' -Force
    Protect-StagedItem -Path 'W:\ProgramData\ImagingTool\Clear-UnattendPasswords.ps1'
    Protect-StagedItem -Path 'W:\ProgramData\ImagingTool\ScriptLog.psm1'
    $plan = New-FirstBootPlan -Answer $answer -AppDefinitions $apps -BitLockerPin $bitLockerPin -Tasks $deployTasks
    # What the post-deploy checks expect at the end of first boot (deploy-settings "checks" turns them off or tunes them).
    $checks = New-PostDeployCheckPlan -Answer $answer -ComputerName $ComputerName -AppDefinitions $apps -Settings $settings
    if ($checks) { $plan | Add-Member -NotePropertyName checks -NotePropertyValue $checks }
    # What WinPE did, for the end-of-deploy summary first boot writes (also without a status folder).
    $plan | Add-Member -NotePropertyName deploy -NotePropertyValue ([pscustomobject]@{
        started = $deployStarted.ToString('o'); toolVersion = $toolVersion.Text; answerFile = $answer.Name; image = $answer.ImageFile
        maker = $hw.Maker; model = $hw.Model; serial = $hw.Serial; computerName = $ComputerName
        driverPack = $driverPackName; driversAdded = $script:DriversInjected })
    # The new Windows can keep reporting only to a UNC path (as the computer account), not to WinPE's drive letters.
    if ($statusTarget -and $statusTarget.Unc) {
        $plan | Add-Member -NotePropertyName status -NotePropertyValue ([pscustomobject]@{ folder = $statusTarget.Unc; id = $statusId })
    }
    Save-JsonFile -Path 'W:\Temp\firstboot.json' -InputObject $plan -Depth 8
    # Made here so they get the same rights: first boot only writes into them (its progress, and the file it holds
    # open so only one run goes at a time).
    Set-Content -Path 'W:\Temp\firstboot-progress.json' -Value '{}' -Encoding ascii
    Set-Content -Path 'W:\Temp\firstboot.lock' -Value '' -Encoding ascii
    foreach ($f in 'FirstBoot.ps1', 'DeployStatus.psm1', 'PostDeployChecks.psm1', 'Test-Deployment.ps1', 'AppPack.psm1', 'TaskPack.psm1',
                   'LibraryPack.psm1', 'ScriptLog.psm1', 'FirstBootState.psm1', 'firstboot.json', 'firstboot-progress.json', 'firstboot.lock') {
        Protect-StagedItem -Path "W:\Temp\$f"
    }
    New-Item -ItemType Directory -Path 'W:\Windows\Setup\Scripts' -Force | Out-Null
    "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Temp\FirstBoot.ps1`r`n" |
        Set-Content -Path 'W:\Windows\Setup\Scripts\SetupComplete.cmd' -Encoding ascii

    if ($sysprepOnPC) {
        Set-SysprepAtDeploy -UnattendXml $unattendXml
    }

    # 6. POSTIMAGE tasks, then boot files.
    Set-DeployStatus -Step 'Running post-image tasks' -Percent 86
    Invoke-Phase -Phase 'POSTIMAGE' -Tasks $deployTasks -Root $root
    Set-DeployStatus -Step 'Writing boot files' -Percent 88
    Invoke-Native -FilePath 'W:\Windows\System32\bcdboot.exe' -ArgumentList @('W:\Windows', '/s', 'S:', '/f', 'UEFI')
    # bcdboot adds Windows Boot Manager, but many PCs keep the USB stick or the network first in their own boot order
    # and would start WinPE again. BootNext makes the restart start Windows; it never fails the deployment.
    $bootNext = Set-WindowsBootNext -SystemDrive 'S:'
    Write-DeployLog $bootNext.Message -Level $(if ($bootNext.Ok) { 'INFO' } else { 'WARN' })
    Save-JsonFile -Path 'W:\Temp\deployed.json' -InputObject (New-DeployedMarker -Identity $hw -AnswerFile $answer.Name -ComputerName $ComputerName)
    Protect-StagedItem -Path 'W:\Temp\deployed.json'

    Write-DeployLog 'Deployment finished'
    $status = 'OK'
}
catch {
    $failure = $_.Exception.Message
    Write-DeployLog $failure -Level ERROR
}
finally {
    # Keep the log on the deployed disk and, when available, on the content root for central review.
    if (Test-Path 'W:\Windows') { Copy-Item 'X:\Windows\Temp\Deploy.log' 'W:\Windows\Temp\' -ErrorAction SilentlyContinue }
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
    if ($status -eq 'OK') {
        # A PC reimaged from the console restarts into Windows by itself: nobody may be there to do it.
        if ($job -and -not $answer.Shutdown -and -not $answer.Reboot) { $answer.Reboot = $true; Write-DeployLog 'Reimage job: restarting into Windows' }
        # The dashboard waits for first boot; the window on this PC is done with its part.
        $whenDone = if ($answer.Shutdown) { 'shutdown' } elseif ($answer.Reboot) { 'restart' } else { 'stay' }
        # Content on a disk of this PC is the USB stick (a network share has no disk number).
        $onStick = $null -ne (Get-ContentDiskNumber $root)
        Set-DeployStatus -LocalOnly -Step 'Image applied' -Percent 100 -State Succeeded -Fields @{ whenDone = $whenDone; removableMedia = $onStick }
    }
}

# Let the window show the result before the screen goes dark. From a USB stick, give the operator time to pull it
# out first (WinPE runs from memory, so that is safe now): the next start then cannot come back to WinPE.
if ($status -eq 'OK' -and ($answer.Shutdown -or $answer.Reboot)) {
    if ($onStick) { Wait-MediaRemoval -Root $root -Seconds 60 }
    elseif ($progressWindow) { Start-Sleep -Seconds 5 }
}
if ($status -eq 'OK' -and $answer.Shutdown) { & wpeutil.exe shutdown }
elseif ($status -eq 'OK' -and $answer.Reboot) { & wpeutil.exe reboot }
# The progress window shows the result with View log, Command prompt, Restart and Shut down. Once it is closed (or
# when there is none), the console comes back: startnet.cmd leaves a command prompt there, and an empty screen
# would look like the PC hung.
if ($progressWindow -is [Diagnostics.Process]) { try { $progressWindow.WaitForExit() } catch { } }
[void](Set-DeployConsoleWindow -Show)
if ($status -ne 'OK') { exit 1 }
