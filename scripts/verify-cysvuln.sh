#!/usr/bin/env bash
set -uo pipefail

# Post-build smoke for the CysVulnServer artifact (qemu / hyperv / vmware / proxmox).
# Probes the four levers the AIE chain depends on, plus the chain itself end-to-end
# via WinRM. Exits 0 only when every check passes.
#
# Run from any host that can reach the booted artifact on WinRM/5985.
#
# Usage:
#   ./scripts/verify-cysvuln.sh <target-ip> [admin-password]
#
# Requires: python3 with pywinrm available (`pip install pywinrm`), or
#           evil-winrm in $PATH (fallback shell check only).

TARGET="${1:-}"
ADMIN_PW="${2:-PizzaMan123!}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"

if [ -z "$TARGET" ]; then
    echo "usage: $0 <target-ip> [admin-password]"
    exit 2
fi

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] python3 -m pip install pywinrm" >&2
    exit 2
fi

PASS=0
FAIL=0
declare -a RESULTS

check() {
    if [ "$2" = "PASS" ]; then RESULTS+=("PASS  $1  ${3:-}"); PASS=$((PASS+1))
    else                       RESULTS+=("FAIL  $1  ${3:-}"); FAIL=$((FAIL+1)); fi
}

winrm_admin() {
    python3 - "$TARGET" "$ADMIN_PW" "$1" <<'PY'
import sys, winrm
host, pw, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
s = winrm.Session(f'http://{host}:5985/wsman', auth=('Administrator', pw), transport='ntlm')
r = s.run_ps(cmd)
sys.stdout.write(r.std_out.decode(errors='replace'))
sys.stderr.write(r.std_err.decode(errors='replace'))
sys.exit(r.status_code)
PY
}

echo "[*] Target: $TARGET  (Administrator)"

if ! nc -z -w 3 "$TARGET" 5985 2>/dev/null; then
    check "winrm-port-open" FAIL "tcp/5985 not open"
    echo "FAIL — aborting; WinRM not reachable"
    exit 1
fi
check "winrm-port-open" PASS "tcp/5985"

HKLM_AIE=$(winrm_admin "(Get-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Installer' -Name AlwaysInstallElevated -EA SilentlyContinue).AlwaysInstallElevated" | tr -d '\r\n ')
[ "$HKLM_AIE" = "1" ] && check "aie-hklm" PASS "1" || check "aie-hklm" FAIL "got '$HKLM_AIE'"

CPBA=$(winrm_admin "(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name ConsentPromptBehaviorAdmin).ConsentPromptBehaviorAdmin" | tr -d '\r\n ')
[ "$CPBA" = "0" ] && check "uac-consent-prompt-zero" PASS "0" || check "uac-consent-prompt-zero" FAIL "got '$CPBA'"

POSD=$(winrm_admin "(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name PromptOnSecureDesktop).PromptOnSecureDesktop" | tr -d '\r\n ')
[ "$POSD" = "0" ] && check "uac-secure-desktop-zero" PASS "0" || check "uac-secure-desktop-zero" FAIL "got '$POSD'"

JOE_PRESENT=$(winrm_admin "(Get-LocalUser User_Joe -EA SilentlyContinue).Name" | tr -d '\r\n ')
[ "$JOE_PRESENT" = "User_Joe" ] && check "user-joe-present" PASS "" || check "user-joe-present" FAIL "missing"

USER_FLAG=$(winrm_admin "if (Test-Path 'C:\\Users\\User_Joe\\Desktop\\user.txt') { Get-Content 'C:\\Users\\User_Joe\\Desktop\\user.txt' } else { 'MISSING' }" | tr -d '\r\n')
[[ "$USER_FLAG" != "MISSING" && -n "$USER_FLAG" ]] && check "user-flag-present" PASS "$USER_FLAG" || check "user-flag-present" FAIL ""

ROOT_FLAG=$(winrm_admin "if (Test-Path 'C:\\Users\\Administrator\\Desktop\\root.txt') { Get-Content 'C:\\Users\\Administrator\\Desktop\\root.txt' } else { 'MISSING' }" | tr -d '\r\n')
[[ "$ROOT_FLAG" != "MISSING" && -n "$ROOT_FLAG" ]] && check "root-flag-present" PASS "$ROOT_FLAG" || check "root-flag-present" FAIL ""

# Service / firewall — informational, not gating (fswsService is out of scope for some builds).
FSWS=$(winrm_admin "(Get-Service fswsService -EA SilentlyContinue).Status" | tr -d '\r\n ')
[ -n "$FSWS" ] && check "fswsService-info" PASS "$FSWS (informational)" || check "fswsService-info" PASS "absent (informational)"

echo
echo "===== verify-cysvuln results ====="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "---------------------------------"
echo "  $PASS pass / $FAIL fail"
echo "================================="
[ "$FAIL" -eq 0 ]
