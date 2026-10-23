# User data migration with USMT (ScanState and LoadState from the Windows ADK): back up the user profiles
# of the Windows already on the target disk from WinPE, before it is erased, and restore them on first boot.
# Two stores:
#   Local  hard links on the old Windows partition. Nothing is copied, so it is fast, but the partitions are
#          kept and only the Windows partition is emptied.
#   Share  a compressed (optionally encrypted) copy under <store path>\<serial>, on the content root or a share.
#          The disk is recreated as usual, and the copy stays there as a backup.
# The argument builders have no WinPE dependencies so they are unit tested. PowerShell 5.1 compatible.

Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1')

$script:StoreFolder = 'UserState'       # on the Windows partition: hard-link store, and the restore copy
$script:BuiltInRules = 'MigDocs.xml', 'MigApp.xml', 'MigUser.xml'
$script:EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:BasicType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

function Join-WinPath([string]$Dir, [string]$Leaf) { '{0}\{1}' -f $Dir.TrimEnd('\'), $Leaf.TrimStart('\') }

function Get-UserStateStoreName {
    # One store per PC under the share path, named after the BIOS serial.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Serial)
    $name = $Serial -replace '[^A-Za-z0-9._-]', ''
    if ($name) { $name } else { 'NO-SERIAL' }
}

function Resolve-UsmtRuleFile {
    <#
    .SYNOPSIS
        Full path of one rule file. MigDocs.xml, MigApp.xml and MigUser.xml come with USMT; other files are
        relative to the content root (or absolute). Without -ContentRoot every file is taken from UsmtDir, which
        is where Deploy-Image copies the extra files for LoadState on the deployed PC.
    #>
    param([Parameter(Mandatory)][string]$Rule, [Parameter(Mandatory)][string]$UsmtDir, [string]$ContentRoot)
    $leaf = ($Rule -split '[\\/]')[-1]
    if (-not $ContentRoot -or ($Rule -eq $leaf -and $leaf -in $script:BuiltInRules)) { return Join-WinPath $UsmtDir $leaf }
    if ($Rule -match '^([A-Za-z]:\\|\\\\)') { return $Rule }
    Join-WinPath $ContentRoot $Rule
}

function Get-ScanStateArguments {
    <#
    .SYNOPSIS
        ScanState arguments for an offline backup, from WinPE, of the Windows in WindowsDir.
    #>
    param(
        [Parameter(Mandatory)]$Answer,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$WindowsDir,      # D:\Windows: the old Windows, seen from WinPE
        [Parameter(Mandatory)][string[]]$RuleFiles,     # full paths (Resolve-UsmtRuleFile)
        [string]$KeyFile,                               # Share store with encryption: file holding the key
        [string]$LogDir = 'X:\Windows\Temp'
    )
    $a = @($StorePath, "/offlineWinDir:$WindowsDir")
    $a += $RuleFiles | ForEach-Object { "/i:$_" }
    # /o overwrites a store left by an earlier attempt; /c goes on past files it can't read and logs them.
    $a += '/o', '/c', '/v:5', "/l:$(Join-WinPath $LogDir 'ScanState.log')", "/progress:$(Join-WinPath $LogDir 'ScanStateProgress.log')"
    if ($Answer.UserDataStore -eq 'Local') { $a += '/hardlink', '/nocompress' }
    elseif ($KeyFile) { $a += '/encrypt:AES_256', "/keyfile:$KeyFile" }
    $a += @($Answer.UserDataExclude) | Where-Object { $_ } | ForEach-Object { "/ue:$_" }
    $a
}

function Get-LoadStateArguments {
    <#
    .SYNOPSIS
        LoadState arguments for the restore on the deployed PC. The rule files must be the ones ScanState used.
    #>
    param(
        [Parameter(Mandatory)]$Answer,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string[]]$RuleFiles,
        [string]$KeyFile,
        [string]$LogDir = 'C:\Windows\Temp'
    )
    $a = @($StorePath)
    $a += $RuleFiles | ForEach-Object { "/i:$_" }
    $a += '/c', '/v:5', "/l:$(Join-WinPath $LogDir 'LoadState.log')", "/progress:$(Join-WinPath $LogDir 'LoadStateProgress.log')"
    # /lac creates the local accounts the store has profiles for. They are created disabled (no /lae), with no
    # password, so an administrator enables them; domain accounts need nothing.
    if ($Answer.UserDataLocalAccounts) { $a += '/lac' }
    if ($Answer.UserDataStore -eq 'Local') { $a += '/hardlink', '/nocompress' }
    elseif ($KeyFile) { $a += '/decrypt:AES_256', "/keyfile:$KeyFile" }
    $a
}

function Test-UsmtExitCode([int]$Code) {
    # 0: success. 3: success, but /c skipped at least one error (see the log). Anything else failed.
    $Code -in 0, 3
}

#region WinPE

function Get-VolumeEncryption {
    # 'None', 'Locked' or 'Unlocked' (BitLocker on, readable). Needs WinPE-SecureStartup; 'None' when unknown.
    param([Parameter(Mandatory)][string]$Drive)
    try {
        $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$Drive'" -ErrorAction Stop
        if (-not $v) { return 'None' }
        if ((Invoke-CimMethod -InputObject $v -MethodName GetLockStatus).LockStatus -eq 1) { return 'Locked' }
        if ((Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus).ConversionStatus -ne 0) { return 'Unlocked' }
        'None'
    } catch { 'None' }
}

function Find-UserStateSource {
    <#
    .SYNOPSIS
        Looks on the target disk for a Windows to back up, or a store left by an earlier attempt that failed
        after the backup. Gives every data partition a drive letter to look at it.
    #>
    param([Parameter(Mandatory)][int]$DiskNumber)
    $disk = Get-Disk -Number $DiskNumber
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
    $esp = $parts | Where-Object GptType -eq $script:EspType | Select-Object -First 1
    $found = $null
    foreach ($p in $parts | Where-Object { $_.GptType -eq $script:BasicType -or $_.MbrType -eq 7 }) {
        if (-not [char]::IsLetter([char]$p.DriveLetter)) {
            $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
            $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber
            if (-not [char]::IsLetter([char]$p.DriveLetter)) { continue }
        }
        $drive = "$($p.DriveLetter):"
        $enc = Get-VolumeEncryption -Drive $drive
        $hasWindows = $enc -ne 'Locked' -and (Test-Path "$drive\Windows\System32\config\SOFTWARE")
        $hasStore = $enc -ne 'Locked' -and (Test-Path "$drive\$($script:StoreFolder)\USMT")
        if ($enc -eq 'Locked' -or $hasWindows -or $hasStore) {
            $found = [pscustomobject]@{ PartitionNumber = $p.PartitionNumber; Drive = $drive; Encryption = $enc; HasWindows = $hasWindows; HasStore = $hasStore }
            break
        }
    }
    [pscustomobject]@{
        PartitionStyle = "$($disk.PartitionStyle)"
        EspPartition   = if ($esp) { $esp.PartitionNumber } else { $null }
        Volume         = $found
    }
}

function Get-UserStatePlan {
    <#
    .SYNOPSIS
        Decides, before the disk is touched, what the migration does on this PC. Throws when it can't be done
        safely, so nothing is erased. Mode: Backup (run ScanState), Reuse (a store from an earlier attempt is
        there) or None (no Windows on the disk: a new PC, deployed without user data).
    #>
    param(
        [Parameter(Mandatory)]$Answer,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$UsmtDir,
        [Parameter(Mandatory)][string]$Serial,
        [string]$SharePath                  # the answer file's store path, already resolved against the content root
    )
    if (-not (Test-Path (Join-Path $UsmtDir 'scanstate.exe'))) {
        throw "User data migration is on, but USMT isn't in this boot image ($UsmtDir). Install the ADK's User State Migration Tool feature and rebuild the media."
    }
    $keyFile = $null
    if ($Answer.UserDataStore -eq 'Share' -and $Answer.UserDataEncrypt) {
        $keyFile = Join-Path $ContentRoot $Answer.UserDataKeyFile
        if (-not (Test-Path $keyFile)) { throw "User data encryption key file not found: $keyFile" }
    }
    $rules = @($Answer.UserDataRules | ForEach-Object { Resolve-UsmtRuleFile -Rule $_ -UsmtDir $UsmtDir -ContentRoot $ContentRoot.TrimEnd('\') })
    foreach ($r in $rules) { if (-not (Test-Path $r)) { throw "USMT rule file not found: $r" } }

    $src = Find-UserStateSource -DiskNumber $Answer.DiskNumber
    $vol = $src.Volume
    if ($vol -and $vol.Encryption -eq 'Locked') {
        throw "The Windows partition $($vol.Drive) is locked by BitLocker, so its user data can't be read. Unlock it (manage-bde -unlock $($vol.Drive) -RecoveryPassword <key>) and start again, or suspend BitLocker in Windows before deploying."
    }

    $plan = [pscustomobject]@{
        Mode = 'None'; Store = $Answer.UserDataStore; Volume = $vol; EspPartition = $src.EspPartition
        StorePath = $null; KeyFile = $keyFile; RuleFiles = $rules; Summary = 'no Windows on the disk, nothing to migrate'
    }
    if ($Answer.UserDataStore -eq 'Local') {
        if (-not $vol) { return $plan }
        if ($src.PartitionStyle -ne 'GPT' -or -not $src.EspPartition) {
            throw "Keeping user data on the disk keeps its partitions, but disk $($Answer.DiskNumber) is $($src.PartitionStyle) without an EFI partition. Store the user data on a share instead."
        }
        if ($vol.Encryption -eq 'Unlocked') {
            throw "The Windows partition $($vol.Drive) is BitLocker encrypted. Decrypt it in Windows first (manage-bde -off C:), or store the user data on a share."
        }
        $plan.StorePath = "$($vol.Drive)\$($script:StoreFolder)"
        $plan.Mode = if ($vol.HasWindows) { 'Backup' } else { 'Reuse' }
        $plan.Summary = if ($vol.HasWindows) { "back up from $($vol.Drive) with hard links, keep the partitions" } else { "restore the store left on $($vol.Drive) by an earlier attempt" }
        return $plan
    }

    $plan.StorePath = Join-Path $SharePath (Get-UserStateStoreName $Serial)
    if ($vol -and $vol.HasWindows) {
        $plan.Mode = 'Backup'; $plan.Summary = "back up from $($vol.Drive) to $($plan.StorePath)"
    } elseif (Test-Path (Join-Path $plan.StorePath 'USMT')) {
        $plan.Mode = 'Reuse'; $plan.Summary = "restore the earlier backup in $($plan.StorePath)"
    }
    $plan
}

function Invoke-Usmt {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$ArgumentList)
    Write-DeployLog "> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList | Out-Null
    $code = $LASTEXITCODE
    if (-not (Test-UsmtExitCode $code)) { throw "$(Split-Path $FilePath -Leaf) failed with exit code $code. See its log in the Windows\Temp folder." }
    if ($code -eq 3) { Write-DeployLog "$(Split-Path $FilePath -Leaf) skipped some files it couldn't read; see its log." -Level WARN }
}

function Backup-UserState {
    # Runs ScanState against the old Windows. Throws on failure, before anything is erased.
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Answer, [Parameter(Mandatory)][string]$UsmtDir)
    # USMT reads this to migrate a 64-bit offline Windows.
    $env:MIG_OFFLINE_PLATFORM_ARCH = '64'
    $scanArgs = Get-ScanStateArguments -Answer $Answer -StorePath $Plan.StorePath -WindowsDir "$($Plan.Volume.Drive)\Windows" `
        -RuleFiles $Plan.RuleFiles -KeyFile $Plan.KeyFile
    Invoke-Usmt -FilePath (Join-Path $UsmtDir 'scanstate.exe') -ArgumentList $scanArgs
}

function Clear-WindowsPartition {
    <#
    .SYNOPSIS
        For a Local store: gives the old Windows partition W: and the EFI partition S:, then deletes everything
        on W: except the store, so the image can be applied without losing the hard-linked files.
    #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][int]$DiskNumber)
    $dp = Join-Path $env:TEMP 'diskpart-keep.txt'
    @"
select disk $DiskNumber
select partition $($Plan.Volume.PartitionNumber)
remove noerr
assign letter=W
select partition $($Plan.EspPartition)
remove noerr
assign letter=S
exit
"@ | Set-Content -Path $dp -Encoding ascii
    & diskpart.exe /s $dp | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "diskpart couldn't assign W: and S: (exit code $LASTEXITCODE)." }
    if (-not (Test-Path "W:\$($script:StoreFolder)")) { throw "W:\$($script:StoreFolder) is missing after the drive letter change; stopping before anything is deleted." }

    # rd /s doesn't follow junctions (Documents and Settings, Application Data). Files owned by TrustedInstaller
    # need takeown and icacls first.
    Write-DeployLog "Emptying W: except \$($script:StoreFolder)"
    $keep = $script:StoreFolder, 'System Volume Information'
    foreach ($item in Get-ChildItem -Path 'W:\' -Force | Where-Object { $_.Name -notin $keep }) {
        $path = $item.FullName
        if ($item.PSIsContainer) {
            & cmd.exe /c "rd /s /q `"$path`"" 2>&1 | Out-Null
            if (Test-Path $path) {
                & takeown.exe /f $path /r /d y 2>&1 | Out-Null
                & icacls.exe $path /grant '*S-1-5-18:F' /t /c /q 2>&1 | Out-Null
                & cmd.exe /c "rd /s /q `"$path`"" 2>&1 | Out-Null
            }
        } else {
            & cmd.exe /c "del /f /q /a `"$path`"" 2>&1 | Out-Null
        }
        if (Test-Path $path) { throw "Couldn't delete $path from the old Windows partition." }
    }
}

function Copy-UserStateForRestore {
    <#
    .SYNOPSIS
        After the image is applied: puts the store at W:\UserState (copied from the share for a Share store),
        the USMT files and extra rule files in W:\Deploy\USMT, and the key file. Returns the userState part of
        firstboot.json.
    #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Answer, [Parameter(Mandatory)][string]$UsmtDir)
    $restoreStore = "W:\$($script:StoreFolder)"
    if ($Plan.Store -eq 'Share') {
        Write-DeployLog "Copying the user data from $($Plan.StorePath) to $restoreStore"
        & robocopy.exe $Plan.StorePath $restoreStore /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copying the user data from $($Plan.StorePath) failed (robocopy exit code $LASTEXITCODE)." }
    }
    $pcUsmt = 'W:\Deploy\USMT'
    New-Item -ItemType Directory -Path $pcUsmt -Force | Out-Null
    Copy-Item -Path (Join-Path $UsmtDir '*') -Destination $pcUsmt -Recurse -Force
    foreach ($r in $Plan.RuleFiles) { Copy-Item -Path $r -Destination $pcUsmt -Force }

    $key = $null
    if ($Plan.KeyFile) { Copy-Item $Plan.KeyFile 'W:\Deploy\usmt.key' -Force; $key = 'C:\Deploy\usmt.key' }
    $rules = @($Answer.UserDataRules | ForEach-Object { Resolve-UsmtRuleFile -Rule $_ -UsmtDir 'C:\Deploy\USMT' })
    [pscustomobject]@{
        loadState = 'C:\Deploy\USMT\loadstate.exe'
        arguments = @(Get-LoadStateArguments -Answer $Answer -StorePath "C:\$($script:StoreFolder)" -RuleFiles $rules -KeyFile $key)
        store     = "C:\$($script:StoreFolder)"
        keepStore = [bool]$Answer.UserDataKeepStore
    }
}

#endregion

Export-ModuleMember -Function Get-UserStateStoreName, Resolve-UsmtRuleFile, Get-ScanStateArguments, Get-LoadStateArguments,
    Test-UsmtExitCode, Get-VolumeEncryption, Find-UserStateSource, Get-UserStatePlan, Invoke-Usmt, Backup-UserState,
    Clear-WindowsPartition, Copy-UserStateForRestore
