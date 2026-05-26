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
#   ./scripts/verify-cysvuln.sh --chain <target-ip> [admin-password]
#
# Environment:
#   WINRM_PORT   WinRM port (default 5985; use 15985 for run-local-cysvuln.sh)
#   JOE_PW       User_Joe password override
#
# Requires: python3 with pywinrm (provided by nix develop).

TARGET="${1:-}"
ADMIN_PW="${2:-PizzaMan123!}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
WINRM_PORT="${WINRM_PORT:-5985}"
CHAIN_MODE=0

if [ "${1:-}" = "--chain" ]; then
    CHAIN_MODE=1
    TARGET="${2:-}"
    ADMIN_PW="${3:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}"
fi

if [ -z "$TARGET" ]; then
    echo "usage: $0 <target-ip> [admin-password]"
    exit 2
fi

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] python3 -m pip install pywinrm" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/check-harness.sh
source "${SCRIPT_DIR}/lib/check-harness.sh"
check_init

winrm_admin() {
    python3 - "$TARGET" "$ADMIN_PW" "$WINRM_PORT" "$1" <<'PY'
import sys, winrm
host, pw, port, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = winrm.Session(f'http://{host}:{port}/wsman', auth=('Administrator', pw), transport='ntlm')
r = s.run_ps(cmd)
sys.stdout.write(r.std_out.decode(errors='replace'))
sys.stderr.write(r.std_err.decode(errors='replace'))
sys.exit(r.status_code)
PY
}

echo "[*] Target: $TARGET  (Administrator)  WinRM:$WINRM_PORT"

if ! nc -z -w 3 "$TARGET" "$WINRM_PORT" 2>/dev/null; then
    check "winrm-port-open" FAIL "tcp/$WINRM_PORT not open"
    echo "FAIL — aborting; WinRM not reachable"
    exit 1
fi
check "winrm-port-open" PASS "tcp/$WINRM_PORT"

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

# Wazuh manager-side: agent enrolled and active?
# shellcheck source=lib/check-wazuh-agent.sh
. "${SCRIPT_DIR}/lib/check-wazuh-agent.sh"
check_wazuh_agent "$TARGET"

if [ "$CHAIN_MODE" -eq 1 ]; then
    CHAIN_DC_IP="${CHAIN_DC_IP:-192.168.61.52}"
    CHAIN_DOMAIN="${CHAIN_DOMAIN:-secretcon.local}"
    if ping -c1 -W2 "$CHAIN_DC_IP" >/dev/null 2>&1; then
        check "chain-dc-ping" PASS "$CHAIN_DC_IP"
    else
        check "chain-dc-ping" FAIL "$CHAIN_DC_IP unreachable"
    fi
    if command -v dig >/dev/null 2>&1; then
        if dig +time=2 +tries=1 "@${CHAIN_DC_IP}" "${CHAIN_DOMAIN}" SOA +short 2>/dev/null | grep -q .; then
            check "chain-dns-soa" PASS "${CHAIN_DOMAIN} @ ${CHAIN_DC_IP}"
        else
            check "chain-dns-soa" FAIL "no SOA for ${CHAIN_DOMAIN} via ${CHAIN_DC_IP}"
        fi
    else
        check "chain-dns-soa" PASS "skipped (dig not installed)"
    fi
fi

check_summary "verify-cysvuln results"
