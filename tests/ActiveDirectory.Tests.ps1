# Plain-PowerShell tests for reading computers from Active Directory (src/ActiveDirectory.psm1): distinguished
# names, OU paths, LDAP filters and turning search results into grid rows. No domain needed.
# Run: pwsh -File tests/ActiveDirectory.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/ActiveDirectory.psm1') -Force

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# Domains and distinguished names
Assert-Equal (ConvertTo-DomainDN 'corp.example.com') 'DC=corp,DC=example,DC=com' 'a DNS domain becomes its DN'
Assert-Equal (ConvertTo-DomainDN 'corp.local.') 'DC=corp,DC=local' 'a trailing dot is ignored'
Assert-Equal (ConvertTo-DomainDN 'DC=corp,DC=local') 'DC=corp,DC=local' 'a DN stays as it is'
Assert-Equal (ConvertTo-DomainDN '') '' 'no domain gives no DN'

$dn = 'CN=PC01,OU=Laptops,OU=Sales,DC=corp,DC=local'
Assert-Equal (Get-AdParentDN $dn) 'OU=Laptops,OU=Sales,DC=corp,DC=local' 'parent of a computer is its OU'
Assert-Equal (Get-AdParentDN 'CN=PC\, old,OU=Lab,DC=corp,DC=local') 'OU=Lab,DC=corp,DC=local' 'an escaped comma in a name does not split it'
Assert-Equal (ConvertTo-AdFriendlyPath 'OU=Laptops,OU=Sales,DC=corp,DC=local') 'Sales/Laptops' 'OU path reads top first'
Assert-Equal (ConvertTo-AdFriendlyPath 'CN=Computers,DC=corp,DC=local') 'Computers' 'the default container has a short path'
Assert-Equal (ConvertTo-AdFriendlyPath 'DC=corp,DC=local') '(domain root)' 'the domain itself'
Assert-Equal (ConvertTo-AdFriendlyPath 'OU=R\&D\, Lab,DC=corp,DC=local') 'R&D, Lab' 'escapes are removed from the path'

Assert-Equal (Get-AdJoinOU $dn) 'OU=Laptops,OU=Sales,DC=corp,DC=local' 'a PC in an OU joins back into it'
Assert-Equal (Get-AdJoinOU 'CN=PC02,CN=Computers,DC=corp,DC=local') '' 'a PC in the Computers container gets no OU (the domain default)'

# LDAP paths and filters
Assert-Equal (Get-AdLdapPath -DN 'DC=corp,DC=local') 'LDAP://DC=corp,DC=local' 'serverless LDAP path'
Assert-Equal (Get-AdLdapPath -Server 'dc01.corp.local' -DN 'OU=A/B,DC=corp,DC=local') 'LDAP://dc01.corp.local/OU=A\/B,DC=corp,DC=local' 'LDAP path with a server escapes a slash in the DN'

Assert-Equal (ConvertTo-LdapFilterValue 'a(b)*c\d') 'a\28b\29\2ac\5cd' 'filter values are escaped'
Assert-Equal (ConvertTo-LdapFilterValue 'LAB-*' -AllowWildcard) 'LAB-*' 'a wildcard can stay'
$f = Get-AdComputerFilter
Assert-Equal ($f.StartsWith('(&(objectCategory=computer)(objectClass=computer)')) $true 'the filter finds computer accounts'
Assert-Equal ($f -match 'userAccountControl:1\.2\.840\.113556\.1\.4\.803:=2\)') $true 'disabled accounts are left out by default'
Assert-Equal ($f -match 'operatingSystem=\*Server\*') $true 'servers are left out by default'
Assert-Equal ($f -match ':=8192') $true 'domain controllers are left out by default'
$all = Get-AdComputerFilter -IncludeDisabled -IncludeServers
Assert-Equal $all '(&(objectCategory=computer)(objectClass=computer))' 'with disabled and servers the filter is only computers'
Assert-Equal ((Get-AdComputerFilter -Name 'LAB' -IncludeDisabled -IncludeServers)) '(&(objectCategory=computer)(objectClass=computer)(name=*LAB*))' 'a name without * matches part of a name'
Assert-Equal ((Get-AdComputerFilter -Name 'LAB-*' -IncludeDisabled -IncludeServers)) '(&(objectCategory=computer)(objectClass=computer)(name=LAB-*))' 'a pattern is used as it is'
Assert-Equal ((Get-AdComputerFilter -Name 'x)(name=*' -IncludeDisabled -IncludeServers)) '(&(objectCategory=computer)(objectClass=computer)(name=x\29\28name=*))' 'a name cannot change the filter'

# The domain of the Deploy Settings account
Assert-Equal (Get-AdDomainFromAccount 'svc-deploy@Corp.Local') 'corp.local' 'a user@domain account gives its DNS domain'
Assert-Equal (Get-AdDomainFromAccount 'CORP\svc-deploy') '' 'a DOMAIN\user account gives no DNS domain (the PC''s own is used)'
Assert-Equal (Get-AdDomainFromAccount '') '' 'no account gives no domain'
Assert-Equal (Resolve-AdDomain -Server 'DC01.Corp.Local' -Account 'x@other.com' -Saved 's.local' -Default 'pc.local') 'corp.local' 'the domain controller''s full name gives the domain'
Assert-Equal (Resolve-AdDomain -Server 'dc01' -Account 'svc@corp.local' -Saved 's.local' -Default 'pc.local') 'corp.local' 'a short DC name: the account''s domain'
Assert-Equal (Resolve-AdDomain -Server '10.0.0.5' -Account 'CORP\svc' -Saved 's.local' -Default 'pc.local') 's.local' 'an IP and DOMAIN\user: the domain an older console saved'
Assert-Equal (Resolve-AdDomain -Server '' -Account '' -Saved '' -Default 'pc.local') 'pc.local' 'nothing set: this PC''s domain'

# Last logon (FILETIME)
$when = [DateTime]::new(2026, 11, 2, 15, 30, 0, [DateTimeKind]::Utc)
Assert-Equal (ConvertFrom-AdFileTime $when.ToFileTimeUtc()).ToUniversalTime().ToString('o') $when.ToString('o') 'lastLogonTimestamp is read as a date'
Assert-Equal ($null -eq (ConvertFrom-AdFileTime 0)) $true 'a last logon of 0 is never'
Assert-Equal ($null -eq (ConvertFrom-AdFileTime ([int64]::MaxValue))) $true 'a last logon of the max value is never'
Assert-Equal ($null -eq (ConvertFrom-AdFileTime $null)) $true 'no last logon is never'

# Search results to rows: SearchResult.Properties has lower case keys and a list per property.
$props = @{
    name = @('pc01'); dnshostname = @('PC01.corp.local'); operatingsystem = @('Windows 11 Pro'); operatingsystemversion = @('10.0 (26100)')
    lastlogontimestamp = @($when.ToFileTimeUtc()); useraccountcontrol = @(4096); description = @('Reception'); distinguishedname = @($dn)
}
$row = ConvertFrom-AdComputerProperties $props
Assert-Equal $row.Name 'PC01' 'row name is upper case'
Assert-Equal $row.Address 'PC01.corp.local' 'the PC is reached by its DNS name'
Assert-Equal $row.OperatingSystem 'Windows 11 Pro' 'row operating system'
Assert-Equal $row.OUPath 'Sales/Laptops' 'row OU path'
Assert-Equal $row.JoinOU 'OU=Laptops,OU=Sales,DC=corp,DC=local' 'row join OU'
Assert-Equal $row.Enabled $true 'an enabled account'
Assert-Equal $row.LastLogonText ($when.ToLocalTime().ToString('yyyy-MM-dd')) 'last logon date text'
Assert-Equal $row.Description 'Reception' 'row description'

$bare = ConvertFrom-AdComputerProperties @{ cn = @('LAB-07'); useraccountcontrol = @(4098); distinguishedname = @('CN=LAB-07,CN=Computers,DC=corp,DC=local') }
Assert-Equal $bare.Name 'LAB-07' 'the cn is used when name is missing'
Assert-Equal $bare.Address 'LAB-07' 'without a DNS name the PC is reached by its name'
Assert-Equal $bare.Enabled $false 'a disabled account (userAccountControl bit 2)'
Assert-Equal $bare.LastLogonText 'never' 'a PC that never logged on'
Assert-Equal $bare.JoinOU '' 'a PC in the Computers container'

# The module stays ASCII (Windows PowerShell 5.1 reads a file without a BOM as ANSI).
$bytes = [IO.File]::ReadAllBytes((Join-Path $repo 'src/ActiveDirectory.psm1'))
Assert-Equal (@($bytes | Where-Object { $_ -gt 127 }).Count) 0 'ActiveDirectory.psm1 is ASCII'

# The Name box: a name, an IP address, or both
$q = ConvertFrom-AdSearchText '10.1.2.34'
Assert-Equal "$($q.Name)|$($q.Ip)" '|10.1.2.34' 'search: an IP address alone'
$q = ConvertFrom-AdSearchText ' GWHZLG3  10.1.2.34 '
Assert-Equal "$($q.Name)|$($q.Ip)" 'GWHZLG3|10.1.2.34' 'search: a name and its IP'
$q = ConvertFrom-AdSearchText '10.1.2.34, GWHZLG3'
Assert-Equal "$($q.Name)|$($q.Ip)" 'GWHZLG3|10.1.2.34' 'search: IP first, comma between'
$q = ConvertFrom-AdSearchText 'LAB-*'
Assert-Equal "$($q.Name)|$($q.Ip)" 'LAB-*|' 'search: a pattern stays a name'
$q = ConvertFrom-AdSearchText '10.1.2.999'
Assert-Equal "$($q.Name)|$($q.Ip)" '10.1.2.999|' 'search: a number that is not an IP is a name'
$nbt = @('', 'Ethernet:', 'Node IpAddress: [10.1.2.5] Scope Id: []', '', '           NetBIOS Remote Machine Name Table', '',
    '       Name               Type         Status', '    ---------------------------------------------',
    '    GWHZLG3        <00>  UNIQUE      Registered', '    BOREALC        <00>  GROUP       Registered', '    GWHZLG3        <20>  UNIQUE      Registered')
Assert-Equal (ConvertFrom-NbtstatOutput -Lines $nbt) 'GWHZLG3' 'nbtstat: the first <00> name is the PC'
Assert-Equal (ConvertFrom-NbtstatOutput -Lines @('Host not found.')) '' 'nbtstat: no answer gives no name'

# A PC found by IP that is not in Active Directory
$row = New-LocalComputerRow -Ip '10.1.2.40' -Name 'desktop-ab12'
Assert-Equal $row.Name 'DESKTOP-AB12' 'local row: the name it answered with'
Assert-Equal $row.Address '10.1.2.40' 'local row: reached at its IP'
Assert-Equal $row.NotInDomain $true 'local row: not in the domain'
Assert-Equal $row.JoinOU '' 'local row: no OU'
Assert-Equal (New-LocalComputerRow -Ip '10.1.2.40').Name '10.1.2.40' 'local row: no name answered shows the IP'

Complete-Tests 'All Active Directory tests passed.'
