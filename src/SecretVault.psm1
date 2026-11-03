# Keeps passwords off the USB stick in plain text. The build puts the content root's password files (join account,
# share accounts, local Administrator, BitLocker PIN, BIOS password, USMT key) into one encrypted file baked into
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

function Test-SecretPath {
    # True for a path inside config\secrets, which offline media leave out unless the admin asks for them.
    param([string]$RelativePath)
    (ConvertTo-SecretKey $RelativePath) -like 'config\secrets\*' -or (ConvertTo-SecretKey $RelativePath) -eq 'config\secrets'
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
        param([string]$Path, [string]$Label, [string]$Share)
        if (-not $Path) { return }
        $key = ConvertTo-SecretKey $Path
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $list.Add([pscustomobject]@{ Key = $key; RelativePath = $Path; Label = $Label; Share = $Share })
    }
    if ($Answer.EnableAdministrator) { & $add $Answer.AdminPasswordFile 'Local Administrator password' }
    if ($Answer.Membership -eq 'Domain') {
        $account = try { (Resolve-JoinAccount -Answer $Answer).Account } catch { $null }
        & $add $Answer.JoinPasswordFile $(if ($account) { "Join account password ($account)" } else { 'Join account password' })
    }
    foreach ($share in @($Answer.Shares | Where-Object { $_ })) {
        & $add $share.PasswordFile "Password for $($share.RemoteName)$(if ($share.Username) { " ($($share.Username))" })" $share.LocalName
    }
    $bl = $Answer.BitLocker
    if ($bl -and $bl.Enabled -and $bl.Protector -eq 'TpmPin') { & $add $bl.PinFile 'BitLocker PIN' }
    $bios = $Answer.Bios
    if ($bios -and $bios.Enabled) { & $add $bios.PasswordFile 'BIOS admin password' }
    if ($Answer.MigrateUserData -and $Answer.UserDataStore -eq 'Share' -and $Answer.UserDataEncrypt) {
        & $add $Answer.UserDataKeyFile 'User data encryption key'
    }
    $list.ToArray()
}

Export-ModuleMember -Function ConvertTo-SecretKey, New-SecretVault, Unlock-SecretVault, Get-ContentSecrets, Test-SecretPath, Get-AnswerSecrets
