# Keeps passwords off the USB stick in plain text: encrypted in the answer files (below), and with a WinPE
# password also in a vault. The build puts the content root's password files (join account,
# share accounts, local Administrator, BitLocker PIN) into one encrypted file baked into
# boot.wim (X:\Deploy\config\vault.json), locked with the WinPE password the admin sets on the Media tab. WinPE asks
# for that password before anything else, so a lost stick or a copied boot.wim gives away nothing.
#
# PBKDF2-SHA256 turns the password into two keys: AES-256-CBC encrypts the secrets, HMAC-SHA256 over the IV and the
# encrypted bytes tells a wrong password (or a changed file) apart from a right one. PowerShell 5.1 compatible.

Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1')

$script:VaultIterations = 200000

function ConvertTo-SecretKey {
    # Normalizes a password file path so the build and WinPE agree: config\secrets\Staff-join.txt -> config\secrets\staff-join.txt
    param([string]$RelativePath)
    if (-not $RelativePath) { return '' }
    ($RelativePath -replace '/', '\').Trim().TrimStart('.', '\').ToLowerInvariant()
}

function Get-VaultKeys([string]$Password, [byte[]]$Salt, [int]$Iterations) {
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $bytes = $kdf.GetBytes(64)
        [pscustomobject]@{ Enc = [byte[]]($bytes[0..31]); Mac = [byte[]]($bytes[32..63]) }
    } finally { $kdf.Dispose() }
}

function Get-VaultMac([byte[]]$Key, [byte[]]$Iv, [byte[]]$Data) {
    $h = New-Object Security.Cryptography.HMACSHA256 (, $Key)
    try { $h.ComputeHash([byte[]]($Iv + $Data)) } finally { $h.Dispose() }
}

function Test-BytesEqual([byte[]]$A, [byte[]]$B) {
    # Same time whichever byte differs.
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    $diff -eq 0
}

function New-SecretVault {
    <#
    .SYNOPSIS
        Encrypts Secrets (relative password file path -> password) with Password. Returns the object to save as JSON.
    #>
    param(
        [Parameter(Mandatory)][string]$Password,
        [hashtable]$Secrets = @{},
        [int]$Iterations = $script:VaultIterations
    )
    if ($Password.Length -lt 8) { throw 'The WinPE password needs at least 8 characters.' }
    $map = [ordered]@{}
    foreach ($k in @($Secrets.Keys | Sort-Object)) { $map[(ConvertTo-SecretKey $k)] = "$($Secrets[$k])" }
    $plain = [Text.Encoding]::UTF8.GetBytes(($map | ConvertTo-Json -Compress -Depth 2))
    if (-not $map.Count) { $plain = [Text.Encoding]::UTF8.GetBytes('{}') }

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $salt = New-Object byte[] 16; $rng.GetBytes($salt)
    $keys = Get-VaultKeys $Password $salt $Iterations
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keys.Enc; $aes.GenerateIV()
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $enc = $aes.CreateEncryptor()
        $data = $enc.TransformFinalBlock($plain, 0, $plain.Length)
        $iv = $aes.IV
    } finally { $aes.Dispose(); $rng.Dispose() }
    [ordered]@{
        version    = 1
        kdf        = 'PBKDF2-SHA256'
        iterations = $Iterations
        salt       = [Convert]::ToBase64String($salt)
        iv         = [Convert]::ToBase64String($iv)
        data       = [Convert]::ToBase64String($data)
        mac        = [Convert]::ToBase64String((Get-VaultMac $keys.Mac $iv $data))
        count      = $map.Count
    }
}

function Unlock-SecretVault {
    <#
    .SYNOPSIS
        The vault's secrets as a hashtable (normalized path -> password), or $null when the password is wrong
        or the file was changed.
    #>
    param([Parameter(Mandatory)]$Vault, [Parameter(Mandatory)][AllowEmptyString()][string]$Password)
    if (-not $Password) { return $null }
    $salt = [Convert]::FromBase64String($Vault.salt)
    $iv = [Convert]::FromBase64String($Vault.iv)
    $data = [Convert]::FromBase64String($Vault.data)
    $keys = Get-VaultKeys $Password $salt ([int]$Vault.iterations)
    if (-not (Test-BytesEqual (Get-VaultMac $keys.Mac $iv $data) ([Convert]::FromBase64String($Vault.mac)))) { return $null }
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keys.Enc; $aes.IV = $iv; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $plain = $aes.CreateDecryptor().TransformFinalBlock($data, 0, $data.Length)
    } finally { $aes.Dispose() }
    $out = @{}
    $obj = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    foreach ($p in @($obj.PSObject.Properties)) { $out[$p.Name] = "$($p.Value)" }
    $out
}

function Get-ContentSecrets {
    <#
    .SYNOPSIS
        Every password file under the content root's config\secrets, plus the share account's password file named
        in deploy-settings.json, read as text (Read-SecretFile). Path -> password, for New-SecretVault.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$SettingsPath)
    $out = @{}
    $dir = Join-Path $ContentRoot ('config\secrets' -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
    $rootFull = (Get-Item -LiteralPath $ContentRoot).FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Length -gt 64KB) { continue }   # a password file, not a stray document
        $rel = $f.FullName.Substring($rootFull.Length + 1)
        $out[(ConvertTo-SecretKey $rel)] = (ConvertFrom-SecretBytes ([IO.File]::ReadAllBytes($f.FullName))).Trim()
    }
    if ($SettingsPath -and (Test-Path -LiteralPath $SettingsPath)) {
        $s = try { Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json } catch { $null }
        $pf = if ($s -and $s.share) { "$($s.share.passwordFile)" } else { '' }
        if ($pf -and -not $out.ContainsKey((ConvertTo-SecretKey $pf))) {
            $full = Join-Path $ContentRoot ($pf -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $full) { $out[(ConvertTo-SecretKey $pf)] = (ConvertFrom-SecretBytes ([IO.File]::ReadAllBytes($full))).Trim() }
        }
    }
    $out
}

function Get-AnswerSecrets {
    <#
    .SYNOPSIS
        Every password file an answer file needs during a deployment, once each (two settings naming the same file
        give one entry), in the order the deploy wizard shows them; wrap the call in @(). Key is ConvertTo-SecretKey of the path, the
        same key the vault and the typed passwords use. Share is set for a share's password (LocalName), so a
        share that is already mapped can be left out.
    #>
    param([Parameter(Mandatory)]$Answer)
    $seen = @{}
    $list = New-Object Collections.Generic.List[object]
    $add = {
        param([string]$Path, [string]$Label, [string]$Share, [string]$Encrypted)
        if (-not $Path) { return }
        $key = ConvertTo-SecretKey $Path
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $list.Add([pscustomobject]@{ Key = $key; RelativePath = $Path; Label = $Label; Share = $Share; Encrypted = $Encrypted })
    }
    $enc = { param($o, $p) if ($o -and $o.PSObject.Properties[$p]) { "$($o.$p)" } else { '' } }
    if ($Answer.EnableAdministrator) { & $add $Answer.AdminPasswordFile 'Local Administrator password' '' (& $enc $Answer 'AdminPasswordEncrypted') }
    if ($Answer.Membership -eq 'Domain') {
        $account = try { (Resolve-JoinAccount -Answer $Answer).Account } catch { $null }
        & $add $Answer.JoinPasswordFile $(if ($account) { "Join account password ($account)" } else { 'Join account password' }) '' (& $enc $Answer 'JoinPasswordEncrypted')
    }
    foreach ($share in @($Answer.Shares | Where-Object { $_ })) {
        & $add $share.PasswordFile "Password for $($share.RemoteName)$(if ($share.Username) { " ($($share.Username))" })" $share.LocalName (& $enc $share 'PasswordEncrypted')
    }
    $bl = $Answer.BitLocker
    if ($bl -and $bl.Enabled -and $bl.Protector -eq 'TpmPin') { & $add $bl.PinFile 'BitLocker PIN' '' (& $enc $bl 'PinEncrypted') }
    $list.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------
# Passwords inside the answer file, encrypted. The answer file carries each password as
#   aes256:<key id>:<base64 of IV + AES-256-CBC bytes + HMAC-SHA256>
# next to its passwordFile, so a stick deploys hands-free with no password files on it. The key is random (64 bytes:
# 32 to encrypt, 32 for the HMAC), made once in <content root>\config\secrets\answer-key.txt, which never goes on the
# stick. Each build puts it in boot.wim: inside the WinPE password vault when there is one, else as
# X:\Deploy\config\answer-key.txt. So the XML alone (copied off the stick, mailed, shown on screen) gives nothing,
# but whoever has the whole stick and no WinPE password can take the key out of boot.wim: set a WinPE password
# for that. Unlike unattend.xml's PlainText=false, which is only base64, this is real encryption.

$script:AnswerKeyFile = 'config\secrets\answer-key.txt'

function New-AnswerKey {
    # 64 random bytes, base64: the text of answer-key.txt.
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $b = New-Object byte[] 64; $rng.GetBytes($b); [Convert]::ToBase64String($b) } finally { $rng.Dispose() }
}

function ConvertFrom-AnswerKey([string]$Key) {
    $b = try { [Convert]::FromBase64String("$Key".Trim()) } catch { $null }
    if (-not $b -or $b.Length -ne 64) { throw 'The answer file key is not valid (answer-key.txt must hold 64 bytes in base64).' }
    [pscustomobject]@{ Enc = [byte[]]($b[0..31]); Mac = [byte[]]($b[32..63]); Id = Get-AnswerKeyId $Key }
}

function Get-AnswerKeyId([string]$Key) {
    # 8 hex characters that name the key, so WinPE can say "made with another key" instead of "changed".
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes("$Key".Trim())) } finally { $sha.Dispose() }
    (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-AnswerPasswordText([string]$Value) {
    # True for a value Protect-AnswerPassword wrote.
    "$Value" -match '^aes256:[0-9a-f]{8}:[A-Za-z0-9+/=]+$'
}

function Protect-AnswerPassword {
    <#
    .SYNOPSIS
        Encrypts one password for the answer file with the answer file key. Same password twice gives different text.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Password, [Parameter(Mandatory)][string]$Key)
    $k = ConvertFrom-AnswerKey $Key
    $plain = [Text.Encoding]::UTF8.GetBytes($Password)
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $k.Enc; $aes.GenerateIV(); $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $data = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
        $iv = $aes.IV
    } finally { $aes.Dispose() }
    $mac = Get-VaultMac $k.Mac $iv $data
    "aes256:$($k.Id):$([Convert]::ToBase64String([byte[]]($iv + $data + $mac)))"
}

function Unprotect-AnswerPassword {
    <#
    .SYNOPSIS
        The password Protect-AnswerPassword encrypted. Throws a short reason when the key is another one or the
        text was changed.
    #>
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Key)
    if (-not (Test-AnswerPasswordText $Value)) { throw 'not an encrypted password' }
    $k = ConvertFrom-AnswerKey $Key
    $parts = $Value -split ':'
    if ($parts[1] -ne $k.Id) { throw "encrypted with another answer file key ($($parts[1]), this media has $($k.Id))" }
    $all = [Convert]::FromBase64String($parts[2])
    if ($all.Length -lt 16 + 16 + 32) { throw 'the encrypted password is cut short' }
    $iv = [byte[]]($all[0..15]); $data = [byte[]]($all[16..($all.Length - 33)]); $mac = [byte[]]($all[($all.Length - 32)..($all.Length - 1)])
    if (-not (Test-BytesEqual (Get-VaultMac $k.Mac $iv $data) $mac)) { throw 'the encrypted password was changed' }
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $k.Enc; $aes.IV = $iv; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($data, 0, $data.Length))
    } finally { $aes.Dispose() }
}

function Get-AnswerKey {
    <#
    .SYNOPSIS
        The content root's answer file key (config\secrets\answer-key.txt); -Create makes it the first time.
        Nothing when there is none and -Create is not given.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [switch]$Create)
    $path = [IO.Path]::Combine($ContentRoot, ($script:AnswerKeyFile -replace '\\', [IO.Path]::DirectorySeparatorChar))
    if ([IO.File]::Exists($path)) { return ([IO.File]::ReadAllText($path)).Trim() }
    if (-not $Create) { return }
    $key = New-AnswerKey
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $key, [Text.Encoding]::ASCII)
    $key
}

function Find-AnswerKey {
    <#
    .SYNOPSIS
        The answer file key WinPE has: from the vault the WinPE password unlocked, from boot.wim (ScriptRoot\config),
        or from the content root (network share). .NET calls only: in WinPE, volumes found through DriveInfo have no
        PowerShell drive, so Join-Path and Test-Path fail on them.
    #>
    param([hashtable]$Vault = @{}, [string]$ScriptRoot, [string]$ContentRoot)
    $vk = ConvertTo-SecretKey $script:AnswerKeyFile
    if ($Vault -and $Vault.ContainsKey($vk) -and $Vault[$vk]) { return "$($Vault[$vk])".Trim() }
    $paths = @()
    if ($ScriptRoot) { $paths += [IO.Path]::Combine($ScriptRoot, 'config', 'answer-key.txt') }
    if ($ContentRoot) { $paths += [IO.Path]::Combine($ContentRoot, 'config', 'secrets', 'answer-key.txt') }
    foreach ($p in $paths) {
        try { if ([IO.File]::Exists($p)) { return ([IO.File]::ReadAllText($p)).Trim() } } catch { }
    }
}

function Get-AnswerPasswordFields {
    <#
    .SYNOPSIS
        Each password an answer file can hold, as XPath of its passwordFile and of its encrypted value. Used to
        fill the encrypted values in place, keeping the file's comments.
    #>
    param([Parameter(Mandatory)][xml]$Xml)
    $d = $Xml.SelectSingleNode('/deployment')
    if (-not $d) { return @() }
    $out = @(
        [pscustomobject]@{ Parent = $d.SelectSingleNode('network/joinCredentials'); File = 'passwordFile'; Value = 'encryptedPassword' }
        [pscustomobject]@{ Parent = $d.SelectSingleNode('options'); File = 'administratorPasswordFile'; Value = 'administratorEncryptedPassword' }
        [pscustomobject]@{ Parent = $d.SelectSingleNode('bitlocker'); File = 'pinFile'; Value = 'encryptedPin' }
    )
    foreach ($s in @($d.SelectNodes('shares/share'))) { $out += [pscustomobject]@{ Parent = $s; File = 'passwordFile'; Value = 'encryptedPassword' } }
    @($out | Where-Object { $_.Parent })
}

function Sync-AnswerFilePasswords {
    <#
    .SYNOPSIS
        Puts the password of each password file an answer file names (when that file exists under the content root)
        into the answer file, encrypted with the content root's key, so the answer file deploys without the password
        files. Rewrites only the files whose passwords changed. Returns one line per answer file it updated.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [string[]]$Names)
    $dir = [IO.Path]::Combine($ContentRoot, 'AnswerFiles')
    if (-not [IO.Directory]::Exists($dir)) { return }
    $key = $null
    foreach ($file in @([IO.Directory]::GetFiles($dir, '*.xml') | Sort-Object)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($file)
        if ($Names -and $name -notin $Names) { continue }
        $xml = New-Object Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        try { $xml.Load($file) } catch { continue }
        $changed = @()
        foreach ($f in Get-AnswerPasswordFields -Xml $xml) {
            $rel = "$($f.Parent.SelectSingleNode($f.File).InnerText)".Trim()
            if (-not $rel -or [IO.Path]::IsPathRooted($rel)) { continue }
            $pwPath = [IO.Path]::Combine($ContentRoot, ($rel -replace '[\\/]', [IO.Path]::DirectorySeparatorChar))
            if (-not [IO.File]::Exists($pwPath)) { continue }
            $pw = (ConvertFrom-SecretBytes ([IO.File]::ReadAllBytes($pwPath))).Trim()
            if (-not $key) { $key = Get-AnswerKey -ContentRoot $ContentRoot -Create }
            $node = $f.Parent.SelectSingleNode($f.Value)
            $current = if ($node) { "$($node.InnerText)".Trim() } else { '' }
            $same = $false
            if ($current) { try { $same = (Unprotect-AnswerPassword -Value $current -Key $key) -ceq $pw } catch { } }
            if ($same) { continue }
            if (-not $node) {
                $node = $xml.CreateElement($f.Value)
                $fileNode = $f.Parent.SelectSingleNode($f.File)
                $indent = if ($fileNode.PreviousSibling -is [Xml.XmlWhitespace]) { $fileNode.PreviousSibling.Value } else { '' }
                [void]$f.Parent.InsertAfter($node, $fileNode)
                if ($indent) { [void]$f.Parent.InsertAfter($xml.CreateWhitespace($indent), $fileNode) }
            }
            $node.InnerText = Protect-AnswerPassword -Password $pw -Key $key
            $changed += $rel
        }
        if ($changed) {
            $xml.Save($file)
            "Answer file ${name}: $($changed -join ', ') now encrypted in the answer file"
        }
    }
}

Export-ModuleMember -Function ConvertTo-SecretKey, New-SecretVault, Unlock-SecretVault, Get-ContentSecrets, Get-AnswerSecrets,
    New-AnswerKey, Get-AnswerKeyId, Test-AnswerPasswordText, Protect-AnswerPassword,
    Unprotect-AnswerPassword, Get-AnswerKey, Find-AnswerKey, Get-AnswerPasswordFields, Sync-AnswerFilePasswords
