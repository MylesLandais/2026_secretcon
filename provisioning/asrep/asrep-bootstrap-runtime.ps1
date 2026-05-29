# Runs on the guest after staging (Packer pass or startup scheduled task).
# Reads config from environment variables set by bootstrap_asrep.ps1 / Packer.

$ErrorActionPreference = 'Stop'

$domain    = if ($env:AD_DOMAIN) { $env:AD_DOMAIN } else { 'secretcon.local' }
$netbios   = if ($env:AD_NETBIOS) { $env:AD_NETBIOS } else { 'SECRETCON' }
$dsrmPlain = if ($env:AD_SAFEMODE_PASSWORD) { $env:AD_SAFEMODE_PASSWORD } else { 'PizzaMan123!' }
$asrepUser = if ($env:SECRETCON_ASREP_USER) { $env:SECRETCON_ASREP_USER } else { 'enite' }
$asrepPass = if ($env:SECRETCON_ASREP_PASSWORD) { $env:SECRETCON_ASREP_PASSWORD } else { 'stud87' }
$asrepFlag = if ($env:SECRETCON_ASREP_FLAG) { $env:SECRETCON_ASREP_FLAG } else { 'asrep-flag-placeholder' }
$userFlag = if ($env:SECRETCON_DC_USER_FLAG) { $env:SECRETCON_DC_USER_FLAG } elseif ($env:SECRETCON_ASREP_FLAG) { $env:SECRETCON_ASREP_FLAG } else { 'asrep-user-flag-placeholder' }
$rootFlag = if ($env:SECRETCON_DC_ROOT_FLAG) { $env:SECRETCON_DC_ROOT_FLAG } else { 'asrep-root-flag-placeholder' }
$eniteDa = -not ($env:SECRETCON_ASREP_ENITE_DA -eq '0')

$promoteLog = 'C:\secretcon\asrep-promote.log'
$seedMarker = 'C:\secretcon\asrep-seed.marker'
$promoteMarker = 'C:\secretcon\asrep-promoted.marker'
$transcriptActive = $false

function Stop-TranscriptSafe {
    if (-not $transcriptActive) { return }
    try { Stop-Transcript | Out-Null } catch { }
    $script:transcriptActive = $false
}

function Test-AsrepAdReady {
    param([string]$Domain)
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $null = Get-ADDomain -Identity $Domain -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Wait-AsrepAdReady {
    param(
        [string]$Domain,
        [int]$TimeoutMinutes = 15
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-AsrepAdReady -Domain $Domain) {
            return $true
        }
        Write-Host '[*] Waiting for AD Web Services / Get-ADDomain...'
        Start-Sleep -Seconds 15
    }
    return $false
}

Start-Transcript -Path $promoteLog -Append | Out-Null
$transcriptActive = $true

try {
    if (Test-Path $seedMarker) {
        Write-Host '[*] ASREP seed already complete'
        return
    }

    $isDc = $false
    $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    if ($domainRole -ge 4 -or (Test-Path $promoteMarker)) {
        Write-Host "[*] DC role detected (DomainRole=$domainRole); waiting for AD readiness"
        if (Wait-AsrepAdReady -Domain $domain) {
            $isDc = $true
            Write-Host "[*] Domain ready: $domain"
        } else {
            throw "AD not ready after promotion (see $promoteLog)"
        }
    } elseif (Test-AsrepAdReady -Domain $domain) {
        $isDc = $true
        Write-Host "[*] Domain already present: $domain"
    } else {
        Write-Host '[*] Domain not present yet; promoting forest'
    }

    if (-not $isDc) {
        Import-Module ADDSDeployment
        $dsrm = ConvertTo-SecureString $dsrmPlain -AsPlainText -Force
        $noReboot = ($env:SECRETCON_ASREP_PACKER -eq '1')
        Install-ADDSForest `
            -DomainName $domain `
            -DomainNetbiosName $netbios `
            -SafeModeAdministratorPassword $dsrm `
            -InstallDns `
            -CreateDnsDelegation:$false `
            -DatabasePath 'C:\Windows\NTDS' `
            -LogPath 'C:\Windows\NTDS' `
            -SysvolPath 'C:\Windows\SYSVOL' `
            -ForestMode WinThreshold `
            -DomainMode WinThreshold `
            -NoRebootOnCompletion:$noReboot `
            -Force
        New-Item -Path $promoteMarker -ItemType File -Force | Out-Null
        if ($noReboot) {
            Write-Host '[*] Forest promotion complete (Packer will reboot)'
            return
        }
        Write-Host '[*] Install-ADDSForest initiated reboot'
        return
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    Set-ADDefaultDomainPasswordPolicy -Identity $domain `
        -ComplexityEnabled $false `
        -MinPasswordLength 4 `
        -LockoutThreshold 0

    auditpol /set /subcategory:"Kerberos Authentication Service" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable /failure:enable | Out-Null

    # Server 2016 default already permits RC4; declare explicitly so the
    # ASREP roast hash comes back as etype 23 (krb5asrep$23$, hashcat -m 18200)
    # instead of an AES variant. Mirrors `ksetup /setenctypeattr <domain> ...`.
    try {
        ksetup /setenctypeattr $domain RC4-HMAC-MD5 AES128-CTS-HMAC-SHA1-96 AES256-CTS-HMAC-SHA1-96 | Out-Null
    } catch {
        Write-Host "[!] ksetup setenctypeattr failed (non-fatal): $($_.Exception.Message)"
    }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' `
        -Name 'SupportedEncryptionTypes' -Value 0x7FFFFFFF -Type DWord -Force -ErrorAction SilentlyContinue

    if (-not (Get-NetFirewallRule -DisplayName 'SecretCon Kerberos TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'SecretCon Kerberos TCP' -Direction Inbound -Protocol TCP -LocalPort 88 -Action Allow | Out-Null
        New-NetFirewallRule -DisplayName 'SecretCon Kerberos UDP' -Direction Inbound -Protocol UDP -LocalPort 88 -Action Allow | Out-Null
        New-NetFirewallRule -DisplayName 'SecretCon LDAP TCP' -Direction Inbound -Protocol TCP -LocalPort 389 -Action Allow | Out-Null
    }

    foreach ($profile in Get-NetConnectionProfile) {
        Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }

    $asrepSecure = ConvertTo-SecureString $asrepPass -AsPlainText -Force
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$asrepUser'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $asrepUser -SamAccountName $asrepUser `
            -UserPrincipalName ("$asrepUser@$domain") `
            -AccountPassword $asrepSecure `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -KerberosEncryptionType RC4
    } else {
        Set-ADAccountPassword -Identity $asrepUser -NewPassword $asrepSecure
        Set-ADUser -Identity $asrepUser -Enabled $true -KerberosEncryptionType RC4
    }
    Set-ADAccountControl -Identity $asrepUser -DoesNotRequirePreAuth $true
    # Re-assert RC4-only encryption after any password reset (Set-ADAccountPassword
    # can flip the supported types depending on the reset path).
    Set-ADUser -Identity $asrepUser -KerberosEncryptionType RC4 -ErrorAction SilentlyContinue

    if ($eniteDa) {
        Add-ADGroupMember -Identity 'Domain Admins' -Members $asrepUser -ErrorAction SilentlyContinue
        Write-Host "[+] $asrepUser added to Domain Admins (campaign mode)"
    }

    $decoys = @('jdoe', 'asmith', 'bwilson', 'clee', 'dpark')
    foreach ($u in $decoys) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$u'" -ErrorAction SilentlyContinue)) {
            $rand = (New-Guid).Guid + 'Aa1!'
            New-ADUser -Name $u -SamAccountName $u `
                -UserPrincipalName ("$u@$domain") `
                -AccountPassword (ConvertTo-SecureString $rand -AsPlainText -Force) `
                -Enabled $true `
                -PasswordNeverExpires $true
        }
    }

    New-Item -ItemType Directory -Path 'C:\Users\Public' -Force | Out-Null
    $userFlagPath = 'C:\Users\Public\user.txt'
    $rootFlagPath = 'C:\Users\Administrator\Desktop\root.txt'
    New-Item -ItemType Directory -Path (Split-Path $rootFlagPath) -Force | Out-Null

    [System.IO.File]::WriteAllText($userFlagPath, $userFlag, [System.Text.UTF8Encoding]::new($false))
    icacls $userFlagPath /inheritance:r /grant "Domain Users:R" "SYSTEM:F" "Domain Admins:F" | Out-Null

    [System.IO.File]::WriteAllText($rootFlagPath, $rootFlag, [System.Text.UTF8Encoding]::new($false))
    icacls $rootFlagPath /inheritance:r /grant "Administrators:F" "SYSTEM:F" | Out-Null
    icacls $rootFlagPath /deny "Domain Users:(R)" | Out-Null

    # Legacy alias for standalone ASREP validators
    Set-Content -Path 'C:\Users\Public\enite-flag.txt' -Value $userFlag -Encoding ASCII

    New-Item -Path $seedMarker -ItemType File -Force | Out-Null
    Write-Host '[+] ASREP domain seed complete'
} catch {
    Write-Host "ERROR: $_"
    throw
} finally {
    Stop-TranscriptSafe
}
