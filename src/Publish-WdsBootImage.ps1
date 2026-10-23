<#
.SYNOPSIS
    Publishes the WinPE boot.wim to a Windows Deployment Services (WDS) server so PCs can PXE boot the deploy tool.
.DESCRIPTION
    Run as admin on the WDS server itself, or on an admin PC that is an administrator of the server
    (it then uses PowerShell remoting and the server's ADMIN$ share).

    With -Setup it also installs the WDS role and initializes the server in standalone mode if needed,
    then answers all PXE clients. WDS only serves the boot image; the deploy itself reads the content
    root from the network share in deploy-settings.json, the same as an ISO boot.

    An existing boot image with the same name is replaced, so publishing again after a rebuild is safe.
    Settings not given on the command line come from the "wds" section of deploy-settings.json.
.EXAMPLE
    .\Publish-WdsBootImage.ps1 -BootWim C:\WinPE\boot.wim -Server wds01 -Setup -RemoteInstallPath D:\RemoteInstall
.EXAMPLE
    .\Publish-WdsBootImage.ps1 -Server wds01 -Status
    Shows whether the role is installed, the server is set up, and which boot images it serves.
#>
[CmdletBinding()]
param(
    [string]$BootWim,
    [string]$Server,                 # empty or localhost: this PC
    [string]$ImageName,              # name shown in the PXE boot menu
    [switch]$Setup,                  # install and initialize WDS if it is not set up yet
    [string]$RemoteInstallPath,      # where WDS keeps its files when -Setup initializes it; not the system drive
    [switch]$DhcpOnServer,           # DHCP runs on the WDS server too, so WDS must not listen on port 67
    [switch]$NoPrompt,               # boot without pressing F12/Enter (otherwise the prompt policy is left as is)
    [switch]$Status,                 # only report the server's state
    [string]$SettingsPath            # deploy-settings.json with a "wds" section for defaults
)

$ErrorActionPreference = 'Stop'

if ($SettingsPath -and (Test-Path $SettingsPath)) {
    $wds = (Get-Content -Raw $SettingsPath | ConvertFrom-Json).wds
    if ($wds) {
        if (-not $PSBoundParameters.ContainsKey('Server') -and $wds.server) { $Server = $wds.server }
        if (-not $ImageName -and $wds.imageName) { $ImageName = $wds.imageName }
        if (-not $RemoteInstallPath -and $wds.remoteInstallPath) { $RemoteInstallPath = $wds.remoteInstallPath }
        if (-not $PSBoundParameters.ContainsKey('Setup')) { $Setup = [bool]$wds.setup }
        if (-not $PSBoundParameters.ContainsKey('DhcpOnServer')) { $DhcpOnServer = [bool]$wds.dhcpOnServer }
        if (-not $PSBoundParameters.ContainsKey('NoPrompt')) { $NoPrompt = [bool]$wds.noPrompt }
    }
}
if (-not $ImageName) { $ImageName = 'Imaging Tool (x64)' }
if (-not $RemoteInstallPath) { $RemoteInstallPath = 'D:\RemoteInstall' }
$isLocal = -not $Server -or $Server -in 'localhost', '.', $env:COMPUTERNAME
if (-not $Status) {
    if (-not $BootWim -or -not (Test-Path $BootWim)) { throw "Boot image not found: $BootWim. Build it with New-DeploymentMedia.ps1 -Target Pxe." }
    $BootWim = (Resolve-Path $BootWim).Path
}

# Everything below runs on the WDS server. It is self-contained so Invoke-Command can send it as is.
# WDS output is localized (French servers print French), so state comes from the service, share and cmdlets,
# never from parsing wdsutil text.
$onServer = {
    param($Mode, $WimPath, $ImageName, $Setup, $RemoteInstallPath, $DhcpOnServer, $NoPrompt)
    $ErrorActionPreference = 'Stop'
    # A remote copy arrives as a path under the server's Windows folder (the ADMIN$ share).
    if ($WimPath -and -not [IO.Path]::IsPathRooted($WimPath)) { $WimPath = Join-Path $env:windir $WimPath }

    function Get-State {
        $feature = if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) { Get-WindowsFeature WDS } else { $null }
        $share = Get-SmbShare -Name REMINST -ErrorAction SilentlyContinue
        $service = Get-Service WDSServer -ErrorAction SilentlyContinue
        $images = @()
        if ($share -and (Get-Command Get-WdsBootImage -ErrorAction SilentlyContinue)) {
            $images = @(Get-WdsBootImage -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) ($($_.Architecture))" })
        }
        [pscustomobject]@{
            Server        = $env:COMPUTERNAME
            IsServerOS    = [bool]$feature
            RoleInstalled = [bool]($feature -and $feature.Installed)
            Configured    = [bool]$share
            RemoteInstall = if ($share) { $share.Path } else { '' }
            Running       = [bool]($service -and $service.Status -eq 'Running')
            BootImages    = $images
        }
    }

    function Invoke-WdsUtil {
        & wdsutil.exe @args | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "wdsutil $($args -join ' ') failed with exit code $LASTEXITCODE" }
    }

    $state = Get-State
    if ($Mode -eq 'Status') { return $state }

    if (-not $state.IsServerOS) { throw "$($state.Server) is not Windows Server. WDS needs Windows Server." }
    if (-not $state.RoleInstalled) {
        if (-not $Setup) { throw "The WDS role is not installed on $($state.Server). Tick 'Set up WDS if needed' or install it in Server Manager." }
        Write-Host "Installing the WDS role on $($state.Server)..."
        Install-WindowsFeature WDS -IncludeManagementTools | Out-Null
    }
    if (-not $state.Configured) {
        if (-not $Setup) { throw "WDS is installed on $($state.Server) but not configured. Tick 'Set up WDS if needed' or run the WDS console's Configure Server." }
        if ($RemoteInstallPath -match "^$([regex]::Escape($env:SystemDrive))") {
            Write-Warning "$RemoteInstallPath is on the system drive. Microsoft recommends another volume for WDS."
        }
        Write-Host "Initializing WDS in $RemoteInstallPath (standalone mode, no Active Directory needed)..."
        Invoke-WdsUtil /Initialize-Server "/RemInst:$RemoteInstallPath" /Standalone
        # A new server ignores PXE clients until told to answer them.
        Invoke-WdsUtil /Set-Server /AnswerClients:All
    }
    if ($DhcpOnServer) {
        # DHCP owns port 67 on this box; WDS listens on 4011 and DHCP option 60 tells clients where it is.
        Invoke-WdsUtil /Set-Server /UseDhcpPorts:No /DhcpOption60:Yes
    }
    if ($NoPrompt) { Invoke-WdsUtil /Set-Server /PxePromptPolicy /New:NoPrompt /Known:NoPrompt }
    if ((Get-Service WDSServer).Status -ne 'Running') { Start-Service WDSServer }

    # Replace, not add: WDS refuses a second image with the same name.
    $fileName = 'ImagingTool-' + ($ImageName -replace '[^A-Za-z0-9]+', '-').Trim('-') + '.wim'
    $existing = Get-WdsBootImage -Architecture X64 -ImageName $ImageName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Replacing boot image '$ImageName'..."
        Remove-WdsBootImage -Architecture X64 -ImageName $ImageName -FileName $existing.FileName | Out-Null
    }
    Write-Host "Importing boot image '$ImageName'..."
    Import-WdsBootImage -Path $WimPath -NewImageName $ImageName -NewFileName $fileName `
        -NewDescription "WinPE deploy and capture, published $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -SkipVerify | Out-Null

    # Make it the default entry in the UEFI boot menu so an unattended PXE boot picks it.
    Invoke-WdsUtil /Set-Server "/BootImage:Boot\x64\Images\$fileName" /Architecture:x64uefi
    Get-State
}

$mode = if ($Status) { 'Status' } else { 'Publish' }
$wimArg = $null
$remoteCopy = $null
try {
    if ($isLocal) {
        $wimArg = $BootWim
        $result = & $onServer $mode $wimArg $ImageName ([bool]$Setup) $RemoteInstallPath ([bool]$DhcpOnServer) ([bool]$NoPrompt)
    } else {
        if (-not $Status) {
            # Stage the WIM where the server can read it as a local file. ADMIN$ is C:\Windows on the server.
            $remoteCopy = "\\$Server\ADMIN$\Temp\ImagingTool-boot.wim"
            Write-Host "Copying boot.wim to $Server..."
            Copy-Item $BootWim $remoteCopy -Force
            $wimArg = 'Temp\ImagingTool-boot.wim'
        }
        $result = Invoke-Command -ComputerName $Server -ScriptBlock $onServer `
            -ArgumentList $mode, $wimArg, $ImageName, ([bool]$Setup), $RemoteInstallPath, ([bool]$DhcpOnServer), ([bool]$NoPrompt)
    }
}
finally {
    if ($remoteCopy -and (Test-Path $remoteCopy)) { Remove-Item $remoteCopy -Force -ErrorAction SilentlyContinue }
}

if (-not $Status) {
    Write-Host "Published '$ImageName' to $($result.Server). PCs can now PXE boot it (UEFI network boot)."
    if (-not $DhcpOnServer) {
        Write-Host 'If DHCP runs on another server or a router, point PXE clients at this server: an IP helper on the'
        Write-Host "client VLAN's router (recommended for UEFI), or DHCP options 66 = $($result.Server) and 67 = boot\x64\wdsmgfm.efi."
    }
}
$result
