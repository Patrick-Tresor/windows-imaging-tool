<#
.SYNOPSIS
    Deploys a Windows image to this PC from WinPE, driven by an answer file, and injects the matching OEM drivers.
.DESCRIPTION
    Launched by startnet.cmd. Finds content on a USB volume labelled DEPLOY, or on the network share in
    deploy-settings.json (LAN or PXE boot). Reads an answer file
    from <content root>\AnswerFiles: image, applications, disk, regional settings, naming,
    domain join, tasks, extra shares and BitLocker.
    If config\naming-list.csv on the content root lists this PC's BIOS serial, its computer name, OU and
    answer file win over the answer file's naming, the answer file's OU and the default answer file.
    Unless -NoPrompt or an Unattended answer file starts it, a graphical wizard
    (DeployWizard.psm1) lets the operator pick the answer file, name, OU, disk and applications.
    Wipes the target disk and partitions it GPT for UEFI. WinPE must be booted in UEFI mode.
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
Import-Module (Join-Path $PSScriptRoot 'AppPack.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TaskPack.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NamingList.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployWizard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecretVault.psm1') -Force

# Passwords: from the content root's password files when they are there (network share, or a stick built with
# -SecretsOnMedia), else encrypted in the answer file (decrypted with the answer file key in boot.wim or the vault),
# else from the vault the WinPE password unlocked, else typed by the operator (kept in memory only).
$script:Vault = @{}
$script:AnswerKey = $null
$script:TypedSecrets = @{}
$script:CanAskSecrets = $false

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

function Read-DeployAnswer([string]$Root, [string]$Name, $Listed) {
    # Reads an answer file; a naming list entry's OU replaces the answer file's (domain joins only).
    $path = Join-Path $Root "AnswerFiles\$Name.xml"
    if (-not (Test-Path $path)) { throw "Answer file $Name not found in $Root\AnswerFiles." }
    $a = Read-AnswerFile -Path $path
    Add-AnswerPasswords -Root $Root -Answer $a
    if ($Listed -and $Listed.OU) {
        if ($a.Membership -eq 'Domain') { $a.OrganizationalUnit = $Listed.OU }
        else { Write-DeployLog "Naming list OU $($Listed.OU) ignored: answer file $($a.Name) joins a workgroup" -Level WARN }
    }
    $a
}

$script:Mounted = @{}
$script:DiskNotes = @{}
$script:PeDriversLoaded = $false
$script:NoDiskLogged = $false
$script:Win11Results = @{}

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

function Get-DeployPlan($Root, $Answer, $Hardware, $Listed, [bool]$IgnoreWin11) {
    # Everything that must be found before the disk is wiped. The wizard calls this each time an answer file is picked,
    # so a problem (missing image, a PC that fails the Windows 11 check in Block mode) shows there.
    # Passwords not on the media are asked for here, all in one window, unless the wizard's Passwords page did it.
    Request-DeploySecrets -Root $Root -Answer $Answer
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

    # Windows 11 hardware requirements are checked now, before the disk is wiped.
    $win11 = Invoke-Windows11Check -Answer $Answer -ImagePath $imagePath -Hardware $Hardware -Override $IgnoreWin11 -Disk $target.Disk

    # So is the domain join account: a wrong password would otherwise only show after the restart.
    Assert-JoinAccount -Root $Root -Answer $Answer

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
    $bl = $Answer.BitLocker
    $details = @(
        "Windows 11:   $win11"
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
        DefaultName   = if ($fromList) { $Listed.ComputerName.ToUpperInvariant() } else { Resolve-ComputerName -Answer $Answer -WmiValue $wmiValue -Serial $Hardware.Serial }
        NameSource    = if ($fromList) { 'naming list' } else { "answer file, $($Answer.NamingMode)" }
        Win11         = $win11
        Details       = $details
    }
}

function Invoke-Windows11Check($Answer, [string]$ImagePath, $Hardware, [bool]$Override, $Disk) {
    # Logs each requirement and throws when the answer file blocks unsupported PCs. Returns the summary line.
    # The hardware does not change while WinPE runs, so each disk is checked and logged once, however often
    # the wizard's Next is pressed.
    if ($Answer.Windows11Check -eq 'Off') { return 'not checked (off in the answer file)' }
    $isWin11 = Test-Win11Image -ImagePath $ImagePath -Index $Answer.ImageIndex
    if ($isWin11 -eq $false) { return 'not needed (Windows 10 image)' }
    $key = "$($Disk.Number)"
    $results = $script:Win11Results[$key]
    if (-not $results) {
        $results = @(Test-Win11Readiness -Facts (Get-Win11ReadinessFacts -Disk $Disk -DiskNumber $Answer.DiskNumber -IsUefi $Hardware.IsUefi))
        foreach ($r in $results) {
            $level = @{ Pass = 'INFO'; Warn = 'WARN'; Fail = 'ERROR' }[$r.Result]
            Write-DeployLog ("Windows 11 {0}: {1} ({2})" -f $r.Check, $r.Result.ToUpperInvariant(), $r.Detail) -Level $level
        }
        $script:Win11Results[$key] = $results
    }
    $decision = Get-Win11ReadinessDecision -Mode $Answer.Windows11Check -IsWin11 $isWin11 -Results $results -Override:$Override
    if ($null -eq $isWin11) { Write-DeployLog 'Could not tell whether the image is Windows 11; requirements are shown but never block.' -Level WARN }
    if ($decision.Action -eq 'Block') {
        # Each failed requirement and how to fix it is already in the log (above); the wizard gets one short line.
        Write-DeployLog 'Fix the failed Windows 11 requirement, deploy a Windows 10 answer file, or set the Windows 11 check to Warn.' -Level ERROR
        throw "Not ready for Windows 11 ($($decision.Summary -replace '^NOT READY: ')). Nothing was erased; see the log."
    }
    if ($decision.Failed -and $Override) { Write-DeployLog 'Deploying anyway: -IgnoreWindows11Check' -Level WARN }
    $decision.Summary
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
            Write-DeployLog "WinPE unlocked; $($secrets.Count) password file(s) in the vault"
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
    # The password in a password file of the answer file, wherever it is (see $script:Vault above). Throws when it
    # is nowhere and nobody is there to type it, before anything is erased.
    if (-not $RelativePath) { throw "No password file is set for $Label in the answer file." }
    $key = ConvertTo-SecretKey $RelativePath
    if ($Root -and [IO.File]::Exists([IO.Path]::Combine($Root, $RelativePath))) { return Read-SecretFile -ContentRoot $Root -RelativePath $RelativePath }
    if ($Answer -and $Answer.PSObject.Properties['Passwords'] -and $Answer.Passwords.ContainsKey($key)) { return $Answer.Passwords[$key] }
    if ($script:Vault.ContainsKey($key)) { return $script:Vault[$key] }
    if ($script:TypedSecrets.ContainsKey($key)) { return $script:TypedSecrets[$key] }
    if (-not $script:CanAskSecrets) {
        throw "The $Label ($RelativePath) is not on this media. Type it in the answer file editor and rebuild the stick (it is saved encrypted in the answer file)."
    }
    # Get-AnswerSecrets lists every password up front, so this is only reached for one it does not know about.
    Write-DeployLog "The $Label ($RelativePath) was not asked for with the other passwords" -Level WARN
    $typed = Show-PasswordPrompt -Message "Type the $Label. It is not on this USB stick, and is kept in memory only for this deployment."
    if ($null -eq $typed) { throw "The $Label was not typed." }
    Write-DeployLog "$Label typed by the operator ($RelativePath is not on the media)"
    $script:TypedSecrets[$key] = $typed
    $typed
}

function Test-DeploySecretKnown([string]$Root, [string]$RelativePath, $Answer) {
    # True when Get-DeploySecret can return this password without asking anyone.
    $key = ConvertTo-SecretKey $RelativePath
    # .NET, not Join-Path: Join-Path throws for a drive letter PowerShell has no drive for (WinPE).
    $onMedia = $Root -and [IO.File]::Exists([IO.Path]::Combine($Root, $RelativePath))
    $inAnswer = $Answer -and $Answer.PSObject.Properties['Passwords'] -and $Answer.Passwords.ContainsKey($key)
    $onMedia -or $inAnswer -or $script:Vault.ContainsKey($key) -or $script:TypedSecrets.ContainsKey($key)
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

function Request-DeploySecrets([string]$Root, $Answer) {
    # Without the wizard (unattended answer file, no WinForms): every missing password in one window, before the
    # countdown and before anything is erased. With the wizard its Passwords page has asked already: nothing to do.
    $missing = @(Get-MissingDeploySecrets -Root $Root -Answer $Answer)
    if (-not $missing) { return }
    $typed = Show-SecretsPrompt -Secrets $missing
    if ($null -eq $typed) { throw 'The passwords were not typed.' }
    Save-TypedSecrets -Values $typed -Secrets $missing
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
        if ($Settings.share.user -and $Settings.share.passwordFile) {
            $pwFile = @((Join-Path $Root $Settings.share.passwordFile),
                        (Join-Path (Split-Path $SettingsPath -Parent | Split-Path -Parent) $Settings.share.passwordFile)) |
                Where-Object { Test-Path $_ } | Select-Object -First 1
            # Without a password net use would stop and prompt, so only pass the account when its password is known.
            if ($pwFile) { $user = $Settings.share.user; $pw = (Get-Content -Raw $pwFile).Trim() }
            elseif ($script:Vault.ContainsKey((ConvertTo-SecretKey $Settings.share.passwordFile))) { $user = $Settings.share.user; $pw = $script:Vault[(ConvertTo-SecretKey $Settings.share.passwordFile)] }
        }
        Mount-NetworkShare -LocalName 'R:' -RemoteName $target.Map -User $user -Password $pw
        $target
    } catch {
        Write-DeployLog "Status share $($target.Map) unavailable, no progress reporting: $($_.Exception.Message)" -Level WARN
        $null
    }
}

function Invoke-Phase([string]$Phase, [object[]]$Tasks, [string]$Root) {
    # POSTIMAGE tasks run here in WinPE with the new Windows at %OSDRIVE% (W:) and content at %DEPLOYROOT%.
    # Plain commands stop the deployment when they fail; library tasks only when they are set to (stopOnFailure).
    $env:OSDRIVE = 'W:'
    $env:DEPLOYROOT = $Root.TrimEnd('\')
    foreach ($t in @($Tasks | Where-Object Phase -eq $Phase)) {
        if (-not $t.Definition) { Invoke-Native -FilePath 'cmd.exe' -ArgumentList @('/c', $t.Command); continue }
        Write-DeployLog "Running task $($t.Name)"
        Set-DeployStatus -Step "Running task $($t.Name)"
        # The log stays on the new Windows, next to Deploy.log.
        $r = try { Invoke-TaskPack -Definition $t.Definition -Folder $t.Folder -ExtraArguments $t.Arguments -LogPath "W:\Windows\Temp\Task-$($t.Name).log" -Log { param($m) Write-DeployLog $m } }
             catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; Message = $_.Exception.Message } }
        if ($r.Status -eq 'Succeeded') { Write-DeployLog "  task $($t.Name) OK ($($r.Message))"; continue }
        if ($t.Definition.stopOnFailure) { throw "Task $($t.Name) $($r.Status.ToLowerInvariant()): $($r.Message). See C:\Windows\Temp\Task-$($t.Name).log." }
        Write-DeployLog "  task $($t.Name) $($r.Status): $($r.Message)" -Level WARN
        Set-DeployStatus -Warning "Task $($t.Name) $($r.Status.ToLowerInvariant())"
    }
}

# Locked media: the WinPE password first, before the content, the wizard or anything else.
Unlock-DeployMedia

$root = $null; $hw = $null; $answer = $null; $driverMatch = $null; $plan = $null; $statusTarget = $null; $logName = $null
$progressWindow = $false; $onStick = $false
$status = 'FAILED'; $failure = $null
try {
    # A wide console whose lines wrap instead of running off the right edge.
    Set-DeployConsole
    $hw = Get-HardwareIdentity
    Write-DeployLog ("Hardware: {0} | {1} | type {2} | SKU {3} | serial {4} | UEFI {5}" -f
        $hw.Maker, $hw.Model, $hw.MachineType, $hw.Sku, $hw.Serial, $hw.IsUefi)

    # Every Set-DeployStatus from here on also updates the progress window on this PC's screen.
    $progressPath = 'X:\Windows\Temp\DeployProgress.json'
    Start-LocalProgress -Path $progressPath -Identity $hw
    $progressWindow = Start-ProgressWindow -ProgressPath $progressPath

    Set-DeployStatus -LocalOnly -Step 'Looking for the deployment content (USB DEPLOY volume or network share)' -Percent 1
    $root = Find-ContentRoot -SettingsPath $SettingsPath -Vault $script:Vault
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

    $givenName = $ComputerName
    # Someone is at this PC to type a password that is not on the media, unless -NoPrompt.
    $script:CanAskSecrets = -not $NoPrompt

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
    $missingSecrets = { param($Answer) Get-MissingDeploySecrets -Root $root -Answer $Answer }
    $saveSecrets = { param($Values, $Secrets) Save-TypedSecrets -Values $Values -Secrets $Secrets }
    $preparePlan = { param($Answer) Get-DeployPlan -Root $root -Answer $Answer -Hardware $hw -Listed $listed -IgnoreWin11 $IgnoreWindows11Check.IsPresent }

    # -NoPrompt and Unattended answer files start without the wizard. A key pressed during
    # the countdown opens the wizard instead, so the operator can change anything.
    $deployPlan = $null; $confirmed = $false; $wizardNotice = $null
    # A Windows deployed here that never started means the PC came back to WinPE after the restart, usually because
    # the USB stick is still first in the boot order. Ask instead of counting down, or it would be wiped again.
    # Only a safety check: if it fails, log it and carry on, so it can never stop a deploy.
    $unstarted = $null
    if (-not $NoPrompt) {
        try { $unstarted = Find-UnstartedDeployment -Serial "$($hw.Serial)" -ExcludeRoots @($root) }
        catch { Write-DeployLog "Could not check this PC's disks for an earlier deployment: $($_.Exception.Message)" -Level WARN }
    }
    if ($unstarted) {
        Write-DeployLog ("Windows was deployed to this PC at {0} ({1}) and has not started yet: no countdown. Remove the USB stick and restart to start Windows." -f $unstarted.deployed, $unstarted.path) -Level WARN
        $wizardNotice = 'Windows is already installed here but has not started. Remove the USB stick and restart, or deploy again.'
    }
    if ($AnswerFile) {
        $answer = & $readAnswer $AnswerFile
        if ($NoPrompt) { $confirmed = $true }
        elseif ($answer.Mode -eq 'Unattended' -and -not $unstarted) {
            $deployPlan = & $preparePlan $answer
            $name = if ($ComputerName) { $ComputerName } else { $deployPlan.DefaultName }
            Write-Host ''
            Get-DeploySummary -Answer $answer -Plan $deployPlan -ComputerName $name -Disk (Get-Disk -Number $answer.DiskNumber) -Applications $answer.Applications |
                ForEach-Object { Write-Host $_ }
            Set-DeployStatus -Step 'Counting down' -Percent 5
            $confirmed = Wait-Countdown $answer.UnattendDelay
            if ($confirmed) { $ComputerName = $name } else { Write-DeployLog 'Countdown cancelled by operator' -Level WARN }
        }
    }

    if (-not $confirmed -and (Test-DeployWizardAvailable)) {
        Set-DeployStatus -Step 'Waiting for the operator' -Percent 5
        $choice = Show-DeployWizard -Hardware $hw -AnswerFiles $names -Default $AnswerFile -ComputerName $ComputerName `
            -ReadAnswer $readAnswer -PreparePlan $preparePlan -MissingSecrets $missingSecrets -SaveSecrets $saveSecrets -Disks @(Get-TargetDisks -Exclude @(Get-ContentDiskNumber $root)) -Notice $wizardNotice
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
    $nameSource = if ($givenName -and $ComputerName -eq $givenName) { 'parameter' }
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
    # So are the task library's scripts: a missing or broken one stops here, not halfway through.
    $taskRoot = Resolve-ContentPath $root $answer.TaskLocation
    $deployTasks = @(Resolve-DeployTasks -Answer $answer -TaskRoot $taskRoot -Identity $hw -OnSkip { param($m) Write-DeployLog $m })
    $libraryTasks = @($deployTasks | Where-Object Definition)
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
    # FIRSTLOGON library tasks run through Run-LogonTask.ps1 in C:\ProgramData\ImagingTool\Tasks, which stays after
    # first boot removes C:\Deploy, so they get the same timeout, success codes and log as FIRSTBOOT tasks.
    $logonIndex = 0
    $logonCommands = @($deployTasks | Where-Object Phase -eq 'FIRSTLOGON' | ForEach-Object {
        if ($_.Definition) { Get-LogonTaskCommand -Index $logonIndex; $logonIndex++ } else { $_.Command }
    })
    $unattendXml = New-UnattendXml -Answer $answer -ComputerName $ComputerName -JoinPassword $joinPassword -AdminPassword $adminPassword -LogonCommands $logonCommands
    $unattendProblems = @(Test-UnattendXml -Xml $unattendXml)
    if ($unattendProblems) {
        foreach ($up in $unattendProblems) { Write-DeployLog "Windows settings (unattend.xml): $up" -Level ERROR }
        throw "Windows would reject these settings: $($unattendProblems[0]) Nothing was erased."
    }

    $disk = Get-Disk -Number $answer.DiskNumber

    $summary = @(Get-DeploySummary -Answer $answer -Plan $deployPlan -ComputerName $ComputerName -Disk $disk -Applications @($apps | ForEach-Object name))
    foreach ($line in $summary) { Write-DeployLog $line }
    if (-not $confirmed) {
        Write-Host ''
        $summary | ForEach-Object { Write-Host $_ -ForegroundColor $(if ($_ -like 'ERASE*') { 'Red' } elseif ($_ -like 'Windows 11:   NOT READY*') { 'Yellow' } else { 'Gray' }) }
        Set-DeployStatus -Step 'Waiting for the operator'
        if ((Read-Host 'Type YES to continue') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
    }

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
        Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList (Get-AddDriverArgs -ImageRoot 'W:\' -DriverPath $driverPack) -OnProgress {
            param($pct, $info)
            if ($info -and $info.Total) {
                Update-NativeStepStatus -Step "Injecting drivers: $($info.Done) of $($info.Total) ($pct %)" -Percent (72 + [int]($pct * 0.07))
            } else { Update-NativeStepStatus }
        }
    }

    # 4. Unattend generated from the answer file. Setup blanks the passwords in it after use.
    Set-DeployStatus -Step 'Writing Windows settings' -Percent 80
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    $logonPlan = @(New-LogonTaskPlan -Tasks $deployTasks)
    $unattendXml | Set-Content -Path 'W:\Windows\Panther\unattend.xml' -Encoding utf8
    $joinText = if ($answer.Membership -eq 'Domain') { "joins $($answer.Domain) as $((Resolve-JoinAccount -Answer $answer).Account)" } else { "workgroup $($answer.Workgroup)" }
    Write-DeployLog "Unattend written: name $ComputerName, $joinText"

    # 5. First boot: applications and FIRSTBOOT tasks run as SYSTEM from SetupComplete.cmd.
    Set-DeployStatus -Step 'Staging applications' -Percent 82
    New-Item -ItemType Directory -Path 'W:\Deploy\Apps' -Force | Out-Null
    foreach ($app in $apps) {
        Write-DeployLog "Staging application $($app.name)"
        Copy-Item -Path (Join-Path $appRoot $app.name) -Destination 'W:\Deploy\Apps\' -Recurse -Force
    }
    # Library tasks: FIRSTBOOT ones next to the applications, FIRSTLOGON ones where the first user's logon finds them.
    foreach ($t in @($libraryTasks | Where-Object Phase -in 'FIRSTBOOT', 'FIRSTLOGON')) {
        $dest = if ($t.Phase -eq 'FIRSTBOOT') { 'W:\Deploy\Tasks' } else { 'W:\ProgramData\ImagingTool\Tasks' }
        Write-DeployLog "Staging task $($t.Name) ($($t.Phase))"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path $t.Folder -Destination $dest -Recurse -Force
    }
    if ($logonPlan) {
        $logonDir = 'W:\ProgramData\ImagingTool\Tasks'
        Copy-Item (Join-Path $PSScriptRoot 'Run-LogonTask.ps1'), (Join-Path $PSScriptRoot 'TaskPack.psm1') $logonDir -Force
        ConvertTo-Json -InputObject $logonPlan -Depth 8 | Set-Content (Join-Path $logonDir 'logon-tasks.json') -Encoding utf8
    }
    Copy-Item (Join-Path $PSScriptRoot 'FirstBoot.ps1'), (Join-Path $PSScriptRoot 'DeployStatus.psm1'),
        (Join-Path $PSScriptRoot 'PostDeployChecks.psm1'), (Join-Path $PSScriptRoot 'Test-Deployment.ps1'),
        (Join-Path $PSScriptRoot 'AppPack.psm1'), (Join-Path $PSScriptRoot 'TaskPack.psm1') 'W:\Deploy\'
    $plan = New-FirstBootPlan -Answer $answer -AppDefinitions $apps -BitLockerPin $bitLockerPin -Tasks $deployTasks
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
    Invoke-Phase -Phase 'POSTIMAGE' -Tasks $deployTasks -Root $root
    Set-DeployStatus -Step 'Writing boot files' -Percent 88
    Invoke-Native -FilePath 'W:\Windows\System32\bcdboot.exe' -ArgumentList @('W:\Windows', '/s', 'S:', '/f', 'UEFI')
    # bcdboot adds Windows Boot Manager, but many PCs keep the USB stick or the network first in their own boot order
    # and would start WinPE again. BootNext makes the restart start Windows; it never fails the deployment.
    $bootNext = Set-WindowsBootNext -SystemDrive 'S:'
    Write-DeployLog $bootNext.Message -Level $(if ($bootNext.Ok) { 'INFO' } else { 'WARN' })
    New-DeployedMarker -Identity $hw -AnswerFile $answer.Name -ComputerName $ComputerName |
        ConvertTo-Json | Set-Content -Path 'W:\Deploy\deployed.json' -Encoding utf8

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
        # The dashboard waits for first boot; the window on this PC is done with its part.
        $whenDone = if ($answer.Shutdown) { 'shutdown' } elseif ($answer.Reboot) { 'restart' } else { 'stay' }
        # Content on a disk of this PC is the USB stick (a network share has no disk number).
        $onStick = $null -ne (Get-ContentDiskNumber $root)
        Set-DeployStatus -LocalOnly -Step 'Image applied' -Percent 100 -State Succeeded -Fields @{ whenDone = $whenDone; removableMedia = $onStick }
    }
    # Which drivers this PC got, for the console's Unknown Models report. Never fails the deployment.
    if ($root -and $hw -and $driverMatch -and $status -ne 'CANCELLED') {
        try {
            Write-DriverReport -ContentRoot $root -Identity $hw -Match $driverMatch -ComputerName $ComputerName `
                -AnswerFile $(if ($answer) { $answer.Name }) -Result $status
        } catch { Write-Warning "Could not write the driver report: $($_.Exception.Message)" }
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
if ($status -ne 'OK') { exit 1 }
