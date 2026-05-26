#!/usr/bin/env bash
set -uo pipefail

# Post-build verify for the SecretCon EWS challenge VM.
# Run from Kali (or any attacker box) on vmbr1 against the deployed VM IP.
# Mirrors Jovan's two rebuild-validation prompts:
#   1. Can a tester confirm VNC is reachable via the SecLists default password?
#   2. Can a tester get SYSTEM via the unquoted service path? (preconditions only)
#
# Exits 0 only if every check passes.
#
# Requires: nmap, hydra, sshpass (or an SSH key for patrick), awk.

TARGET="${1:-}"
CHAIN_MODE=0
if [ "${1:-}" = "--chain" ]; then
    CHAIN_MODE=1
    TARGET="${2:-}"
fi
if [ -z "$TARGET" ]; then
    echo "usage: $0 [--chain] <target-ip> [patrick-password]"
    exit 2
fi
if [ "$CHAIN_MODE" -eq 1 ]; then
    PATRICK_PW="${3:-Changeme123!}"
else
    PATRICK_PW="${2:-Changeme123!}"
fi
VNC_PW="${VNC_PW:-FELDTECH_VNC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/check-harness.sh
source "${SCRIPT_DIR}/lib/check-harness.sh"
check_init

echo "[*] Target: $TARGET"

# 1. Port reachability
if nmap -Pn -n -p 22,5900 --open --host-timeout 30s "$TARGET" 2>/dev/null | grep -q "5900/tcp open"; then
    check "vnc-port-open" PASS "tcp/5900"
else
    check "vnc-port-open" FAIL "tcp/5900 not open"
fi
if nmap -Pn -n -p 22,5900 --open --host-timeout 30s "$TARGET" 2>/dev/null | grep -q "22/tcp open"; then
    check "ssh-port-open" PASS "tcp/22"
else
    check "ssh-port-open" FAIL "tcp/22 not open"
fi

# 2. VNC default-password bruteforce (deterministic — single-password list)
PWLIST=$(mktemp)
echo "$VNC_PW" > "$PWLIST"
if command -v hydra >/dev/null 2>&1; then
    if hydra -P "$PWLIST" -t 1 -f -o /dev/null "vnc://$TARGET" 2>/dev/null | grep -q "host:.*password:"; then
        check "vnc-foothold-creds" PASS "$VNC_PW accepted"
    else
        check "vnc-foothold-creds" FAIL "hydra did not land $VNC_PW"
    fi
else
    check "vnc-foothold-creds" FAIL "hydra not installed"
fi
rm -f "$PWLIST"

# 3. SSH as patrick — service-path LPE preconditions
ssh_as_patrick() {
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$PATRICK_PW" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "patrick@$TARGET" "$@" 2>/dev/null
    else
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "patrick@$TARGET" "$@" 2>/dev/null
    fi
}

SC_OUT=$(ssh_as_patrick 'sc qc SecretConEwsSync')
if [ -z "$SC_OUT" ]; then
    check "ssh-patrick-login" FAIL "could not exec sc qc as patrick"
else
    check "ssh-patrick-login" PASS ""
    IMAGE_PATH=$(echo "$SC_OUT" | awk -F': ' '/BINARY_PATH_NAME/ {print $2}' | tr -d '\r')
    if [ -z "$IMAGE_PATH" ]; then
        check "service-image-path" FAIL "could not read BINARY_PATH_NAME"
    else
        if [[ "$IMAGE_PATH" =~ ^\".*\"$ ]]; then
            check "service-path-unquoted" FAIL "ImagePath is quoted: $IMAGE_PATH"
        else
            check "service-path-unquoted" PASS "$IMAGE_PATH"
        fi
        if [[ "$IMAGE_PATH" =~ \  ]]; then
            check "service-path-has-space" PASS "exploitable"
        else
            check "service-path-has-space" FAIL "no space in $IMAGE_PATH"
        fi
    fi

    ICACLS_OUT=$(ssh_as_patrick 'icacls "C:\Program Files\SecretCon"')
    if echo "$ICACLS_OUT" | grep -qi 'BUILTIN\\Users.*(M)'; then
        check "service-root-user-writable" PASS "Users:(M) on C:\\Program Files\\SecretCon"
    else
        check "service-root-user-writable" FAIL "BUILTIN\\Users does not have Modify on C:\\Program Files\\SecretCon"
    fi

    # User flag readable as patrick
    USER_FLAG=$(ssh_as_patrick 'type C:\Users\patrick\Desktop\flag.txt')
    if [ -n "$USER_FLAG" ]; then
        check "user-flag-readable-as-patrick" PASS "$USER_FLAG"
    else
        check "user-flag-readable-as-patrick" FAIL "empty or unreadable"
    fi

    # Root flag NOT readable as patrick
    ROOT_OUT=$(ssh_as_patrick 'type C:\Users\Administrator\Desktop\root.txt 2>&1')
    if echo "$ROOT_OUT" | grep -qiE 'denied|cannot find|not have permission'; then
        check "root-flag-protected-from-patrick" PASS "access denied as expected"
    elif [ -z "$ROOT_OUT" ]; then
        check "root-flag-protected-from-patrick" PASS "empty (likely access denied)"
    else
        check "root-flag-protected-from-patrick" FAIL "patrick read root.txt: $ROOT_OUT"
    fi
fi

# Wazuh manager-side: agent enrolled and active?
# shellcheck source=lib/check-wazuh-agent.sh
. "${SCRIPT_DIR}/lib/check-wazuh-agent.sh"
check_wazuh_agent "$TARGET"

if [ "$CHAIN_MODE" -eq 1 ]; then
    CHAIN_DC_IP="${CHAIN_DC_IP:-192.168.61.52}"
    CHAIN_DOMAIN="${CHAIN_DOMAIN:-secretcon.local}"
    SHARED_ADMIN_PW="${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}"
    if ping -c1 -W2 "$CHAIN_DC_IP" >/dev/null 2>&1; then
        check "chain-dc-ping" PASS "$CHAIN_DC_IP"
    else
        check "chain-dc-ping" FAIL "$CHAIN_DC_IP unreachable"
    fi
    if python3 -c "import winrm" 2>/dev/null && nc -z -w2 "$TARGET" 5985 2>/dev/null; then
        ADMIN_OK=$(python3 - "$TARGET" "$SHARED_ADMIN_PW" <<'PY'
import sys, winrm
host, pw = sys.argv[1:3]
s = winrm.Session(f"http://{host}:5985/wsman", auth=("Administrator", pw), transport="ntlm")
r = s.run_ps("(Get-LocalUser Administrator).Enabled")
print("1" if r.status_code == 0 and "True" in r.std_out.decode(errors="replace") else "0")
PY
)
        [ "$ADMIN_OK" = "1" ] && check "chain-shared-admin-winrm" PASS "Administrator logon" \
            || check "chain-shared-admin-winrm" FAIL "shared local admin password rejected"
    else
        check "chain-shared-admin-winrm" PASS "skipped (WinRM unavailable)"
    fi
    if command -v dig >/dev/null 2>&1; then
        if dig +time=2 +tries=1 "@${CHAIN_DC_IP}" "${CHAIN_DOMAIN}" SOA +short 2>/dev/null | grep -q .; then
            check "chain-dns-soa" PASS "${CHAIN_DOMAIN} @ ${CHAIN_DC_IP}"
        else
            check "chain-dns-soa" FAIL "no SOA for ${CHAIN_DOMAIN}"
        fi
    fi
fi

check_summary "verify-ews results"
