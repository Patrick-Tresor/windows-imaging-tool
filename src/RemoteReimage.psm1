# Reimaging running PCs from the console (Computers tab): a job on the deployment share, and WinPE started from the
# PC's own disk. Used by Start-RemoteReimage.ps1 on the console PC and, in WinPE, by Deploy-Image.ps1 (to take a job).
#
# How a reimage goes:
#   1. The console reads the PC over PowerShell remoting (WinRM): its name, BIOS serial, UUID and firmware.
#   2. It writes Reimage\<serial>.json on the share: answer file, computer name and OU to keep, expiry.
#   3. It copies the network boot image (Boot\boot.wim on the content root) to C:\_ImagingBoot on the PC, adds a
#      one-time RAM disk boot entry for it (as WDS does over the network, but from the PC's disk, so no PXE),
#      suspends BitLocker for that one restart, and restarts the PC.
#   4. WinPE maps the share from its deploy-settings.json, finds the job for its serial, moves it to
#      Reimage\Started (so it can't run twice) and deploys with that answer file without asking.
#
# The share layout:
#   Reimage\<serial>.json                     a pending job
#   Reimage\Started\<serial>_<time>.json      jobs WinPE took
# PowerShell 5.1 compatible. The job and boot entry functions work off Windows, for the tests.

function Join-RootPath {
    # Paths use backslashes (they are read in WinPE); normalize so the module also runs in tests off Windows.
    param([string]$Root, [string]$Child)
    [IO.Path]::Combine($Root, ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar))
}

#region Serial numbers

# Serials some makers leave in the BIOS of boards they did not fill in: many PCs share them, so a job keyed by one
# could be taken by the wrong PC.
$script:GenericSerials = @('', '0', '00000000', '0123456789', '1234567890', 'NONE', 'N/A', 'NA', 'DEFAULT STRING', 'DEFAULT',
    'TO BE FILLED BY O.E.M.', 'TO BE FILLED BY OEM', 'SYSTEM SERIAL NUMBER', 'SERIAL NUMBER', 'INVALID', 'NOT APPLICABLE',
    'NOT SPECIFIED', 'CHASSIS SERIAL NUMBER', 'XXXXXXXX')

function Test-UsableSerial {
    param([AllowEmptyString()][AllowNull()][string]$Serial)
    $s = "$Serial".Trim().ToUpperInvariant()
    -not ($s -in $script:GenericSerials -or $s -match '^(.)\1+$')
}

function ConvertTo-SerialKey {
    # A file name for a serial: upper case, anything but letters, digits and dashes becomes _ (VMware serials have
    # spaces and commas). Refuses serials many PCs share.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Serial)
    if (-not (Test-UsableSerial $Serial)) { throw "BIOS serial '$Serial' is not unique to one PC, so it can't be reimaged remotely. Reimage it from the USB stick." }
    ($Serial.Trim().ToUpperInvariant() -replace '[^A-Z0-9-]', '_')
}

#endregion

#region Reimage jobs

function Get-JobFolder { param([string]$ContentRoot) Join-RootPath $ContentRoot 'Reimage' }

function ConvertFrom-JobTime([string]$Value) {
    [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function New-ReimageJob {
    # Queues a reimage for one PC. WinPE takes it by BIOS serial (and checks the UUID), uses its answer file without
    # asking, and moves it to Started, so a later boot of WinPE does not reimage the PC again. Jobs expire.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Serial,
        [string]$Uuid,
        [Parameter(Mandatory)][string]$AnswerFile,
        [string]$ComputerName,          # the name to keep; empty = the answer file's naming
        [string]$OU,                    # the OU to join it to; empty = the answer file's OU
        [int]$ExpiresHours = 4,
        [datetime]$Now = (Get-Date)
    )
    if (-not (Test-Path -LiteralPath (Join-RootPath $ContentRoot "AnswerFiles\$AnswerFile.xml"))) { throw "No answer file named $AnswerFile on $ContentRoot." }
    $key = ConvertTo-SerialKey $Serial
    $dir = Get-JobFolder $ContentRoot
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $job = [pscustomobject][ordered]@{
        serial       = $Serial.Trim()
        uuid         = "$Uuid".Trim()
        answerFile   = $AnswerFile
        computerName = "$ComputerName".Trim().ToUpperInvariant()
        ou           = "$OU".Trim()
        requestedBy  = "$env:USERDOMAIN\$env:USERNAME".Trim('\')
        requestedAt  = $Now.ToString('o')
        expiresAt    = $Now.AddHours($ExpiresHours).ToString('o')
    }
    $job | ConvertTo-Json | Set-Content -Path (Join-RootPath $dir "$key.json") -Encoding utf8
    $job
}

function Test-JobExpired {
    param([Parameter(Mandatory)]$Job, [datetime]$Now = (Get-Date))
    (ConvertFrom-JobTime $Job.expiresAt) -lt $Now
}

function Get-ReimageJob {
    # The pending job for a PC, or $null.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Serial)
    $path = Join-RootPath (Get-JobFolder $ContentRoot) "$(ConvertTo-SerialKey $Serial).json"
    if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
}

function Remove-ReimageJob {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Serial)
    Remove-Item -LiteralPath (Join-RootPath (Get-JobFolder $ContentRoot) "$(ConvertTo-SerialKey $Serial).json") -ErrorAction SilentlyContinue
}

function Receive-ReimageJob {
    <#
    .SYNOPSIS
        In WinPE: takes the job for this PC's serial, if one is waiting and has not expired. A job that names a UUID is
        only taken by the PC with that UUID. Returns the job, or $null. OnNote gets a line for the log when a job is
        there but not taken.
    #>
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Serial,
        [string]$Uuid,
        [datetime]$Now = (Get-Date),
        [scriptblock]$OnNote = { },
        # WinPE's clock can be hours off (a stick built before WinPE got the console's time zone reads the PC's local
        # clock as Pacific time), so expiry allows this much. The console removes a job that was not taken in time.
        [int]$ClockSkewHours = 14
    )
    if (-not (Test-UsableSerial $Serial)) { return $null }
    $key = ConvertTo-SerialKey $Serial
    $dir = Get-JobFolder $ContentRoot
    $path = Join-RootPath $dir "$key.json"
    # .NET, not Test-Path: WinPE maps the share as Z: through net use, which PowerShell may have no drive for.
    if (-not [IO.File]::Exists($path)) { return $null }
    $job = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if (Test-JobExpired -Job $job -Now $Now.AddHours(-$ClockSkewHours)) { & $OnNote "A reimage job for this PC expired at $($job.expiresAt); not used."; return $null }
    if ($job.uuid -and $Uuid -and $job.uuid.Trim() -ne $Uuid.Trim()) {
        & $OnNote "A reimage job for serial $Serial is for another PC (UUID $($job.uuid), this PC has $Uuid); not used."
        return $null
    }
    $job | Add-Member -NotePropertyName startedAt -NotePropertyValue $Now.ToString('o') -Force
    $started = Join-RootPath $dir 'Started'
    [void][IO.Directory]::CreateDirectory($started)
    [IO.File]::WriteAllText((Join-RootPath $started ("{0}_{1:yyyyMMdd-HHmmss}.json" -f $key, $Now)), ($job | ConvertTo-Json))
    [IO.File]::Delete($path)
    $job
}

function Get-StartedJob {
    <#
    .SYNOPSIS
        The job WinPE took for a PC, or $null. -RequestedAt (the requestedAt of the job the console queued) finds that
        very job whatever WinPE's clock says; -Since takes the most recent one WinPE started after a given time.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Serial, [datetime]$Since = [datetime]::MinValue, [string]$RequestedAt)
    $key = ConvertTo-SerialKey $Serial
    $files = @(Get-ChildItem -LiteralPath (Join-RootPath (Get-JobFolder $ContentRoot) 'Started') -Filter "${key}_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
    foreach ($f in $files) {
        try { $job = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if ($RequestedAt) {
            # ConvertFrom-Json may turn the text into a date: compare as round-trip text either way.
            $r = if ($job.requestedAt -is [datetime]) { $job.requestedAt.ToString('o') } else { "$($job.requestedAt)" }
            if ($r -eq $RequestedAt -or ((ConvertFrom-JobTime $r) -eq (ConvertFrom-JobTime $RequestedAt))) { return $job }
            continue
        }
        if ((ConvertFrom-JobTime $job.startedAt) -ge $Since) { return $job }
        return $null
    }
    $null
}

function Get-ReimageStates {
    # What the Computers tab shows in its Reimage column, by computer name: a waiting job, or one WinPE took in
    # the last day.
    param([Parameter(Mandatory)][string]$ContentRoot, [datetime]$Now = (Get-Date))
    $states = @{}
    $dir = Get-JobFolder $ContentRoot
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-RootPath $dir 'Started') -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try { $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if (-not $j.computerName -or -not $j.startedAt) { continue }
        $at = (ConvertFrom-JobTime $j.startedAt).ToLocalTime()
        if ($at -lt $Now.AddDays(-1)) { continue }
        $states[$j.computerName] = "Started $($at.ToString('HH:mm'))"
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if (-not $j.computerName) { continue }
        $states[$j.computerName] = if (Test-JobExpired -Job $j -Now $Now) { 'Expired' } else { "Waiting: $($j.answerFile)" }
    }
    $states
}

function Find-ReimageJobByName {
    # The pending job for a computer name (to cancel it from the console), or $null.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ComputerName)
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-JobFolder $ContentRoot) -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if ($j.computerName -eq $ComputerName.ToUpperInvariant()) { return $j }
    }
    $null
}

#endregion

#region Reaching the PCs

function Test-WinRMReachable {
    # Which of these hosts answer on the WinRM port, checked in parallel, 200 at a time. Ping is often blocked by
    # Windows Firewall; WinRM is what the reimage needs anyway.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ComputerName, [int]$TimeoutMs = 1500, [int]$Port = 5985)
    $result = @{}
    $names = @($ComputerName | Where-Object { $_ } | Select-Object -Unique)
    for ($i = 0; $i -lt $names.Count; $i += 200) {
        $batch = $names[$i..([Math]::Min($i + 199, $names.Count - 1))]
        $checks = foreach ($c in $batch) {
            $tcp = [Net.Sockets.TcpClient]::new()
            [pscustomobject]@{ Name = $c; Client = $tcp; Task = $(try { $tcp.ConnectAsync($c, $Port) } catch { $null }) }
        }
        $tasks = @($checks | Where-Object Task | ForEach-Object Task)
        if ($tasks) { try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, $TimeoutMs) } catch { } }
        foreach ($c in $checks) {
            $result[$c.Name] = [bool]($c.Task -and $c.Task.Status -eq 'RanToCompletion' -and $c.Client.Connected)
            $c.Client.Close()
        }
    }
    $result
}

$script:RemoteInfoScript = {
    # Runs on the target PC.
    $bl = $null
    try { $bl = (Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop).ProtectionStatus.ToString() } catch { }
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Firmware     = $env:firmware_type
        Serial       = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
        Uuid         = "$((Get-CimInstance Win32_ComputerSystemProduct).UUID)".Trim()
        Model        = "$((Get-CimInstance Win32_ComputerSystem).Model)".Trim()
        FreeC        = [int64](Get-PSDrive C).Free
        BitLocker    = $bl
    }
}

function Get-RemoteComputerInfo {
    # Reads a running PC over PowerShell remoting. Needs admin rights on it.
    param([Parameter(Mandatory)][string]$ComputerName, [pscredential]$Credential)
    $credArgs = @{}
    if ($Credential) { $credArgs.Credential = $Credential }
    Invoke-Command -ComputerName $ComputerName -ScriptBlock $script:RemoteInfoScript -ErrorAction Stop @credArgs
}

function Test-RemoteTarget {
    # Problems that stop a reimage, from Get-RemoteComputerInfo, before anything is changed on the PC.
    # ExpectedName: the computer name in Active Directory. A stale DNS record can point at another PC.
    param([Parameter(Mandatory)]$Info, [string]$ExpectedName)
    if ($ExpectedName -and "$($Info.ComputerName)" -and $Info.ComputerName -ne $ExpectedName) {
        "its address answers as $($Info.ComputerName), not $ExpectedName (an old DNS record?)"
    }
    if ($Info.Firmware -ne 'UEFI') { 'it starts Windows in legacy BIOS mode; deploys need UEFI' }
    if (-not (Test-UsableSerial $Info.Serial)) { "its BIOS serial '$($Info.Serial)' is not unique to one PC" }
    if ($Info.FreeC -and $Info.FreeC -lt 2GB) { "only $([int]($Info.FreeC / 1MB)) MB free on C: (WinPE needs about 1 GB)" }
}

#endregion

#region WinPE from the PC's own disk

function Get-BcdGuid {
    # The {GUID} in bcdedit /create's output ("The entry {...} was successfully created."), in any language.
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}') { return $Matches[0] }
    $null
}

function Get-LocalBootCommands {
    <#
    .SYNOPSIS
        The bcdedit commands that start WinPE once from a boot.wim on the PC's own disk, as a RAM disk (UEFI).
        RamdiskId and LoaderId are the GUIDs bcdedit /create gave. Each item is one argument list.
    #>
    param(
        [Parameter(Mandatory)][string]$RamdiskId,
        [Parameter(Mandatory)][string]$LoaderId,
        [string]$Drive = 'C:',
        [string]$Folder = '\_ImagingBoot'
    )
    $wim = "ramdisk=[$Drive]$Folder\boot.wim,$RamdiskId"
    @(
        , @('/set', $RamdiskId, 'ramdisksdidevice', "partition=$Drive")
        , @('/set', $RamdiskId, 'ramdisksdipath', "$Folder\boot.sdi")
        , @('/set', $LoaderId, 'device', $wim)
        , @('/set', $LoaderId, 'osdevice', $wim)
        , @('/set', $LoaderId, 'path', '\windows\system32\boot\winload.efi')
        , @('/set', $LoaderId, 'systemroot', '\windows')
        , @('/set', $LoaderId, 'winpe', 'yes')
        , @('/set', $LoaderId, 'detecthal', 'yes')
        # One time only: the next restart after this one uses the normal boot order again.
        , @('/bootsequence', $LoaderId)
    )
}

function Get-LocalBootFolderAclArgs {
    # icacls arguments that leave C:\_ImagingBoot readable by Administrators and SYSTEM only: boot.wim holds the
    # answer file key (the network boot image has no WinPE password), so a user of the PC must not copy it.
    param([string]$Folder = 'C:\_ImagingBoot')
    @($Folder, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
}

function Get-LocalBootCleanupCommand {
    # What the PC runs at its next Windows start (SYSTEM startup task): WinPE did not reimage it, so WinPE and its
    # boot entry go, and the task removes itself. A reimaged PC never runs it: its disk is erased.
    param([string]$BootEntry, [string]$Folder = 'C:\_ImagingBoot', [string]$TaskName = 'ImagingTool\RemoveImagingBoot')
    # No quotes: schtasks /TR keeps a quoted path badly in Windows PowerShell, and these paths have no spaces.
    $cmd = "rd /s /q $Folder"
    if ($BootEntry) { $cmd += " & bcdedit /delete $BootEntry /f" }
    "cmd.exe /c $cmd & schtasks /Delete /TN $TaskName /F"
}

function Remove-LocalDiskBoot {
    # Takes WinPE off a PC that is back in Windows without being reimaged: the folder, the boot entry and the task.
    param([Parameter(Mandatory)][string]$ComputerName, [string]$BootEntry, [pscredential]$Credential)
    $credArgs = @{}
    if ($Credential) { $credArgs.Credential = $Credential }
    Invoke-Command -ComputerName $ComputerName -ErrorAction Stop @credArgs -ArgumentList "$BootEntry" -ScriptBlock {
        param($Entry)
        if ($Entry) { & bcdedit.exe /delete $Entry /f 2>&1 | Out-Null }
        & schtasks.exe /Delete /TN 'ImagingTool\RemoveImagingBoot' /F 2>&1 | Out-Null
        Remove-Item 'C:\_ImagingBoot' -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path 'C:\_ImagingBoot') { throw 'C:\_ImagingBoot could not be removed.' }
    }
}

function Invoke-LocalDiskBoot {
    <#
    .SYNOPSIS
        Copies boot.wim to C:\_ImagingBoot on a running PC over PowerShell remoting, adds a one-time RAM disk boot
        entry for it, suspends BitLocker for one restart (the boot manager must read C:), and restarts it.
        On a failure before the restart, the boot entries are removed again and the PC is left as it was.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$BootWim,
        [pscredential]$Credential,
        [int]$DelaySeconds = 60,
        [string]$Message = 'IT is reinstalling Windows on this PC. Save your work: it restarts shortly.',
        [scriptblock]$OnStage = { }
    )
    if (-not (Test-Path -LiteralPath $BootWim)) { throw "No network boot image at $BootWim." }
    $credArgs = @{}
    if ($Credential) { $credArgs.Credential = $Credential }
    $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop @credArgs
    $created = @()
    try {
        & $OnStage 'copy'
        Invoke-Command -Session $session -ArgumentList (, (Get-LocalBootFolderAclArgs)) -ScriptBlock {
            param($AclArgs)
            New-Item -ItemType Directory -Path 'C:\_ImagingBoot' -Force | Out-Null
            # Admins and SYSTEM only, before boot.wim (with the answer file key) is copied in.
            $o = & icacls.exe @AclArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Could not limit C:\_ImagingBoot to administrators: $o" }
        }
        Copy-Item -LiteralPath $BootWim -Destination 'C:\_ImagingBoot\boot.wim' -ToSession $session -Force
        & $OnStage 'bootentry'
        $out = Invoke-Command -Session $session -ScriptBlock {
            $sdi = 'C:\Windows\Boot\DVD\EFI\boot.sdi'
            if (-not (Test-Path $sdi)) { throw "$sdi is missing on this PC." }
            Copy-Item $sdi 'C:\_ImagingBoot\boot.sdi' -Force
            $ram = (& bcdedit.exe /create /d 'Imaging RAM disk' /device) -join ' '
            $ldr = (& bcdedit.exe /create /d 'Reinstall Windows (WinPE)' /application osloader) -join ' '
            @($ram, $ldr)
        }
        $ramId = Get-BcdGuid $out[0]; $loaderId = Get-BcdGuid $out[1]
        $created = @($ramId, $loaderId | Where-Object { $_ })
        if (-not $ramId -or -not $loaderId) { throw "bcdedit could not create the boot entries: $($out -join ' | ')" }
        $steps = Get-LocalBootCommands -RamdiskId $ramId -LoaderId $loaderId
        $cleanup = Get-LocalBootCleanupCommand -BootEntry $loaderId
        & $OnStage 'restart'
        Invoke-Command -Session $session -ArgumentList $steps, $DelaySeconds, $Message, $cleanup -ScriptBlock {
            param($Steps, $Delay, $Message, $Cleanup)
            foreach ($a in $Steps) {
                $o = & bcdedit.exe @a 2>&1
                if ($LASTEXITCODE -ne 0) { throw "bcdedit $($a -join ' ') failed: $o" }
            }
            # If WinPE does not reimage the PC and Windows starts again, this removes WinPE and its boot entry.
            $o = & schtasks.exe /Create /TN 'ImagingTool\RemoveImagingBoot' /TR $Cleanup /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Could not create the cleanup task: $o" }
            # With BitLocker on, the changed boot would ask for the recovery key. One restart without it; the deploy
            # erases the disk anyway.
            $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
            if ($bl -and $bl.ProtectionStatus -eq 'On') { Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 | Out-Null }
            # /d p:4:1 = planned, application installation. A delay over 0 also closes the apps that are open.
            & shutdown.exe /r /t $Delay /c $Message /d p:4:1
            if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed (exit $LASTEXITCODE)." }
        }
        $created = @()
        [pscustomobject]@{ ComputerName = $ComputerName; BootEntry = $loaderId }
    } catch {
        $err = $_
        try {
            Invoke-Command -Session $session -ArgumentList (, $created) -ScriptBlock {
                param($Ids)
                foreach ($id in $Ids) { & bcdedit.exe /delete $id /f 2>&1 | Out-Null }
                & schtasks.exe /Delete /TN 'ImagingTool\RemoveImagingBoot' /F 2>&1 | Out-Null
                Remove-Item 'C:\_ImagingBoot' -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        throw $err
    } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
}

#region Console checks

function Get-NetworkBootImage {
    # The network boot image the Computers tab starts on PCs: <content root>\Boot\boot.wim, and what its build wrote
    # next to it (boot.json: when, WinPE password or not, which share it maps).
    param([Parameter(Mandatory)][string]$ContentRoot)
    $wim = Join-RootPath $ContentRoot 'Boot\boot.wim'
    $info = $null
    try { $info = Get-Content -Raw -LiteralPath (Join-RootPath $ContentRoot 'Boot\boot.json') -ErrorAction Stop | ConvertFrom-Json } catch { }
    $exists = Test-Path -LiteralPath $wim
    [pscustomobject]@{
        Path   = $wim
        Exists = $exists
        Built  = if ($info -and $info.built) { "$($info.built)" } elseif ($exists) { (Get-Item -LiteralPath $wim).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        Locked = [bool]($info -and $info.locked)
        Share  = if ($info) { "$($info.share)" } else { '' }
    }
}

function Get-RemoteReimageProblems {
    # What stops a reimage from the Computers tab, before any PC is touched. Settings: the content root's
    # deploy-settings.json. Boot: Get-NetworkBootImage.
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Boot)
    $share = "$($Settings.share.path)".Trim()
    if (-not $share) { 'No deployment share: set Network share on the Deploy Settings tab (the PCs load the image from there), then build the network boot image.' }
    if (-not $Boot.Exists) { 'No network boot image yet: click Build network boot image.' }
    elseif ($Boot.Locked) { 'The network boot image has a WinPE password, so each PC would wait for someone to type it: click Build network boot image (it builds one without).' }
    elseif ($share -and $Boot.Share -and $Boot.Share -ne $share) { "The network boot image maps $($Boot.Share), but the share is now $share`: click Build network boot image." }
}

#endregion

#endregion

Export-ModuleMember -Function Test-UsableSerial, ConvertTo-SerialKey, New-ReimageJob, Test-JobExpired, Get-ReimageJob, Remove-ReimageJob,
    Receive-ReimageJob, Get-StartedJob, Get-ReimageStates, Find-ReimageJobByName, Test-WinRMReachable, Get-RemoteComputerInfo,
    Test-RemoteTarget, Get-BcdGuid, Get-LocalBootCommands, Get-LocalBootFolderAclArgs, Get-LocalBootCleanupCommand, Remove-LocalDiskBoot, Invoke-LocalDiskBoot, Get-NetworkBootImage, Get-RemoteReimageProblems
