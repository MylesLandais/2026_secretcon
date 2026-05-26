# Post-promotion verification for Packer ASREP demo DC build.

$ErrorActionPreference = "Stop"

$domain    = if ($env:AD_DOMAIN) { $env:AD_DOMAIN } else { "secretcon.local" }
$asrepUser = if ($env:SECRETCON_ASREP_USER) { $env:SECRETCON_ASREP_USER } else { "enite" }
$asrepFlag = if ($env:SECRETCON_ASREP_FLAG) { $env:SECRETCON_ASREP_FLAG } else { "asrep-flag-placeholder" }
$seedMarker = "C:\secretcon\asrep-seed.marker"
$bootstrapPath = "C:\secretcon\asrep-bootstrap.ps1"

if (-not (Test-Path $seedMarker)) {
    if (Test-Path $bootstrapPath) {
        Write-Host "[*] Seed marker absent; running bootstrap script once"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $bootstrapPath
    }
}

if (-not (Test-Path $seedMarker)) {
    throw "ASREP seed marker missing: $seedMarker (see C:\secretcon\asrep-promote.log)"
}

Import-Module ActiveDirectory -ErrorAction Stop
$adDomain = Get-ADDomain -Identity $domain
Write-Host "[+] Domain:" $adDomain.DNSRoot "mode:" $adDomain.DomainMode

$user = Get-ADUser -Identity $asrepUser -Properties DoesNotRequirePreAuth, KerberosEncryptionType
if (-not $user.DoesNotRequirePreAuth) {
    throw "User $asrepUser is not AS-REP roastable (DoesNotRequirePreAuth=false)"
}
Write-Host "[+] $asrepUser DoesNotRequirePreAuth=true KerberosEncryptionType=$($user.KerberosEncryptionType)"

$flagPath = "C:\Users\Public\enite-flag.txt"
if (-not (Test-Path $flagPath)) {
    throw "Missing flag file: $flagPath"
}
$flag = (Get-Content $flagPath -Raw).Trim()
if (-not $flag) {
    throw "Flag file empty: $flagPath"
}
Write-Host "[+] Flag present at $flagPath"

if ($asrepFlag -ne "asrep-flag-placeholder" -and $flag -ne $asrepFlag) {
    throw "Flag mismatch: expected '$asrepFlag' got '$flag'"
}

Write-Host "[+] ASREP post-promote verification passed"
exit 0
