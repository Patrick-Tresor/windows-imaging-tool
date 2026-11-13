# Reads the computers in Active Directory for the console's Computers tab, so they can be reimaged from there.
# Plain LDAP through System.DirectoryServices (ADSI): no RSAT or ActiveDirectory module needed on the console PC.
# The console PC can be joined to the domain (the signed-in account is used) or not (a domain controller and an
# account are given). Only reads: nothing in Active Directory is changed.
# PowerShell 5.1 compatible. Everything but Get-AdComputers, Get-AdOrganizationalUnits and Get-AdDefaultDomain
# works without a domain, for the tests.

function ConvertTo-DomainDN {
    # corp.example.com -> DC=corp,DC=example,DC=com. A DN that is given stays as it is.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Domain)
    $d = $Domain.Trim().TrimEnd('.')
    if (-not $d) { return '' }
    if ($d -match '(?i)^DC=') { return $d }
    (@($d -split '\.' | Where-Object { $_ } | ForEach-Object { "DC=$_" })) -join ','
}

function Split-AdDN {
    # The parts of a distinguished name, without splitting on escaped commas (OU=Smith\, John).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DN)
    if (-not $DN) { return @() }
    @([regex]::Split($DN, '(?<!\\),') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-AdParentDN {
    # CN=PC01,OU=Laptops,DC=corp,DC=local -> OU=Laptops,DC=corp,DC=local
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DN)
    $parts = @(Split-AdDN $DN)
    if ($parts.Count -lt 2) { return '' }
    ($parts[1..($parts.Count - 1)]) -join ','
}

function ConvertTo-AdFriendlyPath {
    # OU=Laptops,OU=Sales,DC=corp,DC=local -> Sales/Laptops (top first, as Active Directory Users and Computers
    # shows it). The domain part is left out; a DN that is only the domain is '(domain root)'.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DN)
    $names = @(Split-AdDN $DN | Where-Object { $_ -notmatch '(?i)^DC=' } | ForEach-Object { ($_ -replace '^[A-Za-z]+=', '') -replace '\\(.)', '$1' })
    if (-not $names) { return $(if ($DN) { '(domain root)' } else { '' }) }
    [array]::Reverse($names)
    $names -join '/'
}

function Get-AdJoinOU {
    # The OU to join a reimaged PC back into: its current parent. The default Computers container (CN=Computers) and
    # other CN= containers are not OUs; there the join is left to put it in the domain's default place ('').
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DN)
    $parent = Get-AdParentDN $DN
    if ($parent -match '(?i)^OU=') { $parent } else { '' }
}

function ConvertTo-LdapFilterValue {
    # Escapes a value for an LDAP filter (RFC 4515). With -AllowWildcard a * stays a wildcard.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [switch]$AllowWildcard)
    $sb = [Text.StringBuilder]::new()
    foreach ($c in $Value.ToCharArray()) {
        switch ($c) {
            '\' { [void]$sb.Append('\5c') }
            '(' { [void]$sb.Append('\28') }
            ')' { [void]$sb.Append('\29') }
            '*' { if ($AllowWildcard) { [void]$sb.Append('*') } else { [void]$sb.Append('\2a') } }
            ([char]0) { [void]$sb.Append('\00') }
            default { [void]$sb.Append($c) }
        }
    }
    $sb.ToString()
}

function Get-AdComputerFilter {
    # The LDAP filter for the computer search. Name: part of a name (LAB matches LAB-01 and XLAB) or a pattern
    # with * (LAB-*). Disabled accounts and servers (domain controllers among them) are left out unless asked for.
    param([string]$Name, [switch]$IncludeDisabled, [switch]$IncludeServers)
    $f = '(objectCategory=computer)(objectClass=computer)'
    $n = "$Name".Trim()
    if ($n) {
        if ($n -notmatch '\*') { $n = "*$n*" }
        $f += "(name=$(ConvertTo-LdapFilterValue $n -AllowWildcard))"
    }
    # 1.2.840.113556.1.4.803 = bitwise AND; userAccountControl bit 2 = account disabled.
    if (-not $IncludeDisabled) { $f += '(!(userAccountControl:1.2.840.113556.1.4.803:=2))' }
    # 8192 = SERVER_TRUST_ACCOUNT (domain controllers).
    if (-not $IncludeServers) { $f += '(!(operatingSystem=*Server*))(!(userAccountControl:1.2.840.113556.1.4.803:=8192))' }
    "(&$f)"
}

function Get-AdLdapPath {
    # LDAP://dc01.corp.local/OU=Laptops,DC=corp,DC=local. Without a server the domain is found through DNS
    # (serverless binding), which works on a PC joined to it. A / in a DN must be escaped in an ADsPath.
    param([string]$Server, [Parameter(Mandatory)][string]$DN)
    $escaped = $DN -replace '(?<!\\)/', '\/'
    if ("$Server".Trim()) { "LDAP://$($Server.Trim())/$escaped" } else { "LDAP://$escaped" }
}

function ConvertFrom-AdFileTime {
    # lastLogonTimestamp is a Windows FILETIME (100 ns since 1601, UTC). 0 or missing = never.
    param($Value)
    if ($null -eq $Value) { return $null }
    try { $v = [int64]$Value } catch { return $null }
    if ($v -le 0 -or $v -ge [DateTime]::MaxValue.ToFileTimeUtc()) { return $null }
    [DateTime]::FromFileTimeUtc($v).ToLocalTime()
}

function Get-AdValue($Properties, [string]$Name) {
    # First value of a property from a SearchResult's Properties (keys are lower case), or a hashtable in tests.
    $v = $Properties[$Name.ToLowerInvariant()]
    if ($null -eq $v) { return $null }
    if ($v -is [string]) { return $v }
    if ($v -is [Collections.IEnumerable]) { foreach ($x in $v) { return $x }; return $null }
    $v
}

function ConvertFrom-AdComputerProperties {
    # One grid row from one search result's properties.
    param([Parameter(Mandatory)]$Properties)
    $dn = "$(Get-AdValue $Properties 'distinguishedName')"
    $name = "$(Get-AdValue $Properties 'name')"
    if (-not $name) { $name = "$(Get-AdValue $Properties 'cn')" }
    $dns = "$(Get-AdValue $Properties 'dNSHostName')"
    $uac = Get-AdValue $Properties 'userAccountControl'
    $last = ConvertFrom-AdFileTime (Get-AdValue $Properties 'lastLogonTimestamp')
    [pscustomobject]@{
        Name              = $name.ToUpperInvariant()
        DnsName           = $dns
        Address           = if ($dns) { $dns } else { $name }
        OperatingSystem   = "$(Get-AdValue $Properties 'operatingSystem')"
        OSVersion         = "$(Get-AdValue $Properties 'operatingSystemVersion')"
        LastLogon         = $last
        LastLogonText     = if ($last) { $last.ToString('yyyy-MM-dd') } else { 'never' }
        OUPath            = ConvertTo-AdFriendlyPath (Get-AdParentDN $dn)
        JoinOU            = Get-AdJoinOU $dn
        Enabled           = -not ($uac -and (([int64]$uac -band 2) -ne 0))
        Description       = "$(Get-AdValue $Properties 'description')"
        DistinguishedName = $dn
    }
}

function Get-AdDomainFromAccount {
    # The DNS domain in an account written user@corp.local. CORP\user names only the short (NetBIOS) domain, which
    # LDAP cannot find by itself: ''.
    param([AllowEmptyString()][AllowNull()][string]$Account)
    if ("$Account".Trim() -match '^[^@\\\s]+@([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)$') { return $Matches[1].ToLowerInvariant() }
    ''
}

function Get-AdDefaultDomain {
    # The domain the console PC (or else the signed-in user) belongs to, or '' when it is in a workgroup.
    try { return [DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name } catch { }
    if ($env:USERDNSDOMAIN) { return $env:USERDNSDOMAIN.ToLowerInvariant() }
    ''
}

function New-AdDirectoryEntry {
    param([Parameter(Mandatory)][string]$Path, [pscredential]$Credential)
    if ($Credential) {
        New-Object DirectoryServices.DirectoryEntry($Path, $Credential.UserName, $Credential.GetNetworkCredential().Password)
    } else {
        New-Object DirectoryServices.DirectoryEntry($Path)
    }
}

function Invoke-AdSearch {
    # Paged search (Active Directory returns at most 1000 results per page otherwise). Returns each result's Properties.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Filter, [string[]]$Properties, [pscredential]$Credential)
    $entry = New-AdDirectoryEntry -Path $Path -Credential $Credential
    $searcher = New-Object DirectoryServices.DirectorySearcher($entry)
    try {
        $searcher.Filter = $Filter
        $searcher.PageSize = 500
        $searcher.SearchScope = 'Subtree'
        foreach ($p in $Properties) { [void]$searcher.PropertiesToLoad.Add($p) }
        $results = $searcher.FindAll()
        try { foreach ($r in $results) { , $r.Properties } } finally { $results.Dispose() }
    } catch [Runtime.InteropServices.COMException] {
        # 0x8007203A: the server is not operational; 0x8007052E: wrong user name or password.
        throw "Active Directory did not answer at $Path`: $($_.Exception.Message.Trim())"
    } finally { $searcher.Dispose(); $entry.Dispose() }
}

function Get-AdComputers {
    <#
    .SYNOPSIS
        The computer accounts in a domain, or in one OU and the OUs under it, as grid rows.
    .EXAMPLE
        Get-AdComputers -Domain corp.local -SearchBase 'OU=Laptops,DC=corp,DC=local' -Name 'LAB-*'
    #>
    param(
        [string]$Domain,          # corp.local; empty = the console PC's domain
        [string]$Server,          # a domain controller, needed when the console PC is not in the domain
        [string]$SearchBase,      # an OU's DN; empty = the whole domain
        [string]$Name,
        [switch]$IncludeDisabled,
        [switch]$IncludeServers,
        [pscredential]$Credential
    )
    if (-not $Domain) { $Domain = Get-AdDefaultDomain }
    $base = if ($SearchBase) { $SearchBase } else { ConvertTo-DomainDN $Domain }
    if (-not $base) { throw 'Type the domain name (for example corp.local): this PC is not joined to a domain.' }
    $filter = Get-AdComputerFilter -Name $Name -IncludeDisabled:$IncludeDisabled -IncludeServers:$IncludeServers
    $props = 'name', 'cn', 'dNSHostName', 'operatingSystem', 'operatingSystemVersion', 'lastLogonTimestamp', 'userAccountControl', 'description', 'distinguishedName'
    @(Invoke-AdSearch -Path (Get-AdLdapPath -Server $Server -DN $base) -Filter $filter -Properties $props -Credential $Credential |
        ForEach-Object { ConvertFrom-AdComputerProperties $_ } | Sort-Object OUPath, Name)
}

function Get-AdOrganizationalUnits {
    # Every OU in the domain, plus the default Computers container, for the OU list: Path (Sales/Laptops) and DN.
    param([string]$Domain, [string]$Server, [pscredential]$Credential)
    if (-not $Domain) { $Domain = Get-AdDefaultDomain }
    $root = ConvertTo-DomainDN $Domain
    if (-not $root) { throw 'Type the domain name (for example corp.local): this PC is not joined to a domain.' }
    $ous = @(Invoke-AdSearch -Path (Get-AdLdapPath -Server $Server -DN $root) -Filter '(objectClass=organizationalUnit)' -Properties 'distinguishedName' -Credential $Credential |
        ForEach-Object { $dn = "$(Get-AdValue $_ 'distinguishedName')"; [pscustomobject]@{ Path = ConvertTo-AdFriendlyPath $dn; DN = $dn } })
    @([pscustomobject]@{ Path = 'Computers'; DN = "CN=Computers,$root" }) + @($ous | Sort-Object Path)
}

Export-ModuleMember -Function ConvertTo-DomainDN, Split-AdDN, Get-AdParentDN, ConvertTo-AdFriendlyPath, Get-AdJoinOU,
    ConvertTo-LdapFilterValue, Get-AdComputerFilter, Get-AdLdapPath, ConvertFrom-AdFileTime, ConvertFrom-AdComputerProperties,
    Get-AdDomainFromAccount, Get-AdDefaultDomain, Get-AdComputers, Get-AdOrganizationalUnits
