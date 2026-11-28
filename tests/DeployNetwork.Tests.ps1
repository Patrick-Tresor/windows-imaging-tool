# Tests for reaching the share from WinPE (DeployCommon.psm1). GWHZLG3, 2026-11-25: a reimage through its agent got
# to WinPE, then "System error 53" mapping \\IMAGER\imager: WaitForNetwork returns at once with no cable (WinPE has
# no Wi-Fi), and a short server name may not resolve in WinPE.
# Run: powershell -File tests/DeployNetwork.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force
Set-DeployLogPath -Path (Join-Path ([IO.Path]::GetTempPath()) "DeployNetwork-$([guid]::NewGuid().ToString('N')).log")

# Waiting for an address.
$calls = 0
$r = Wait-DeployNetwork -TimeoutSeconds 60 -Sleep { } -GetState {
    $script:calls++
    if ($script:calls -lt 3) { [pscustomobject]@{ Name = 'Intel Ethernet'; Up = $true; Ips = @() } }
    else { [pscustomobject]@{ Name = 'Intel Ethernet'; Up = $true; Ips = @('10.10.64.51') } }
}
Assert-Equal "$($r.Ok)|$($r.Text)" 'True|Intel Ethernet: 10.10.64.51' 'it waits until DHCP gives an address'
$r = Wait-DeployNetwork -TimeoutSeconds 0 -Sleep { } -GetState { [pscustomobject]@{ Name = 'Intel Ethernet'; Up = $false; Ips = @() } }
Assert-Equal "$($r.Ok)|$($r.Text)" 'False|Intel Ethernet: no cable' 'no cable: no network'
Assert-Equal ((Get-NoNetworkMessage -Adapters $r.Adapters) -match 'no Wi-Fi: connect a network cable') $true 'the message says WinPE needs a cable'
Assert-Equal ((Get-NoNetworkMessage -Adapters @()) -match 'no network adapter') $true 'no adapter at all says so'

# Other names for the share's server.
$c = Get-ShareCandidates -SharePath '\\IMAGER\imager' -OtherHosts @('IMAGER.borealc.on.ca', '10.10.64.10', '', 'IMAGER')
Assert-Equal ($c -join '|') '\\IMAGER\imager|\\IMAGER.borealc.on.ca\imager|\\10.10.64.10\imager' 'the share on its full name and IP, after the path as set'
Assert-Equal ((Get-ShareCandidates -SharePath '\\IMAGER\imager\Deploy' -OtherHosts @('10.0.0.5')) -join '|') '\\IMAGER\imager\Deploy|\\10.0.0.5\imager\Deploy' 'a deeper path keeps its folders'
$entry = [pscustomobject]@{ HostName = 'IMAGER.borealc.on.ca'; AddressList = @([Net.IPAddress]::Parse('10.10.64.10'), [Net.IPAddress]::Parse('127.0.0.1'), [Net.IPAddress]::Parse('169.254.3.4')) }
$h = Get-ShareHosts -SharePath '\\IMAGER\imager' -Resolve { param($n) $entry }
Assert-Equal "$($h.server)|$($h.fqdn)|$($h.ips -join ',')" 'IMAGER|IMAGER.borealc.on.ca|10.10.64.10' 'the build records the full name and real addresses'
Assert-Equal (Get-ShareHosts -SharePath '\\10.0.0.5\imager' -Resolve { throw 'not called' }) $null 'nothing to add for an IP path'

# Mapping: retried on network errors, on each name, stopped at once on a sign-in error.
function New-NetError([int]$Code) { $e = New-Object Exception "System error $Code has occurred."; $e.Data['NetUseCode'] = $Code; $e }
$tried = [Collections.Generic.List[string]]::new()
$used = Connect-DeployShare -LocalName 'Z:' -SharePath '\\IMAGER\imager' -OtherHosts @('IMAGER.borealc.on.ca', '10.10.64.10') -Sleep { } -Mount {
    param($Path) $tried.Add($Path); if ($Path -ne '\\10.10.64.10\imager') { throw (New-NetError 53) } }
Assert-Equal "$used|$($tried.Count)" '\\10.10.64.10\imager|3' 'error 53 on the short and full names: the IP address is used'
$tried.Clear()
$n = 0
$used = Connect-DeployShare -LocalName 'Z:' -SharePath '\\IMAGER\imager' -RetrySeconds 60 -Sleep { } -Mount {
    param($Path) $script:n++; if ($script:n -lt 3) { throw (New-NetError 53) } }
Assert-Equal "$used|$n" '\\IMAGER\imager|3' 'tried again while the network comes up'
$n = 0
$err = try { Connect-DeployShare -LocalName 'Z:' -SharePath '\\IMAGER\imager' -OtherHosts @('10.10.64.10') -Sleep { } -Mount { param($Path) $script:n++; throw (New-NetError 1326) } } catch { $_.Exception.Message }
Assert-Equal "$n|$($err -match '1326')" '1|True' 'a wrong password stops at once (no failed logons on every address)'
$err = try { Connect-DeployShare -LocalName 'Z:' -SharePath '\\IMAGER\imager' -RetrySeconds 0 -Sleep { } -Mount { param($Path) throw (New-NetError 53) } } catch { $_.Exception.Message }
Assert-Equal ($err -match 'Could not reach \\\\IMAGER\\imager from WinPE') $true 'giving up says which share and what the network looks like'

# Deploy-Image's Find-ContentRoot uses them.
$text = [IO.File]::ReadAllText((Join-Path $repo 'src/DeployCommon.psm1'))
$find = $text.Substring($text.IndexOf('function Find-ContentRoot'), 3500)
Assert-Equal ($find -match 'Wait-DeployNetwork' -and $find -match 'Connect-DeployShare' -and $find -match 'share-hosts\.json') $true 'Find-ContentRoot waits for an address and tries every name'
# A WinPE-only stick (network-stick.json, no Images) is not used as content: WinPE maps the share instead.
Assert-Equal ($find -match "network-stick\.json" -and $find.IndexOf("'Images'") -lt $find.IndexOf('network-stick.json')) $true 'a WinPE-only stick falls through to the share'
Assert-Equal ([IO.File]::ReadAllText((Join-Path $repo 'src/New-DeploymentMedia.ps1')) -match 'share-hosts\.json') $true 'the build writes the server names into boot.wim'

Complete-Tests 'All deploy network tests passed.'
