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
NMAP_PORTS="$(nmap -Pn -n -p 22,5900 --open --host-timeout 30s "$TARGET" 2>/dev/null || true)"
if echo "${NMAP_PORTS}" | grep -qE '5900/tcp[[:space:]]+open'; then
    check "vnc-port-open" PASS "tcp/5900"
else
    check "vnc-port-open" FAIL "tcp/5900 not open"
fi
if echo "${NMAP_PORTS}" | grep -qE '22/tcp[[:space:]]+open'; then
    check "ssh-port-open" PASS "tcp/22"
else
    check "ssh-port-open" FAIL "tcp/22 not open"
fi

# 2. VNC foothold credential (RFB probe -> wordlist brute -> hydra -> registry)
VNC_CRED_OK=0
VNC_CRED_VIA=""
CRED_TOOL="${SCRIPT_DIR}/observability/vnc-cred-tool.py"
AUTH_PROBE="${SCRIPT_DIR}/../ansible/roles/ultravnc/files/check_vnc_auth.py"
VNC_WORDLIST="${SCRIPT_DIR}/../provisioning/wordlists/vnc-betterdefaultpasslist.txt"
if [ "$VNC_CRED_OK" -eq 0 ] && command -v python3 >/dev/null 2>&1 && [ -f "$AUTH_PROBE" ] && [ -f "$CRED_TOOL" ]; then
    if python3 "$AUTH_PROBE" --host "$TARGET" --port 5900 --password "$VNC_PW" --cred-tool "$CRED_TOOL" >/dev/null 2>&1; then
        VNC_CRED_OK=1
        VNC_CRED_VIA="rfb-probe"
    fi
fi
if [ "$VNC_CRED_OK" -eq 0 ] && command -v python3 >/dev/null 2>&1 && [ -f "$AUTH_PROBE" ] && [ -f "$CRED_TOOL" ] && [ -f "$VNC_WORDLIST" ]; then
    if python3 "$AUTH_PROBE" --host "$TARGET" --port 5900 --wordlist "$VNC_WORDLIST" --cred-tool "$CRED_TOOL" >/dev/null 2>&1; then
        VNC_CRED_OK=1
        VNC_CRED_VIA="rfb-wordlist"
    fi
fi
if [ "$VNC_CRED_OK" -eq 0 ] && command -v hydra >/dev/null 2>&1; then
    PWLIST=$(mktemp)
    echo "$VNC_PW" > "$PWLIST"
    if hydra -P "$PWLIST" -t 1 -f -o /dev/null -s 5900 "$TARGET" vnc 2>/dev/null | grep -q "host:.*password:"; then
        VNC_CRED_OK=1
        VNC_CRED_VIA="hydra-compat"
    fi
    rm -f "$PWLIST"
fi
# Hydra often fails against UltraVNC (multi security-type handshake); fall back to
# registry blob check via Administrator when ANSIBLE_ADMIN_PASSWORD is set.
if [ "$VNC_CRED_OK" -eq 0 ] && command -v python3 >/dev/null 2>&1; then
    ADMIN_PW="${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-}}"
    if [ -n "$ADMIN_PW" ] && command -v sshpass >/dev/null 2>&1; then
        VNC_REG_HEX=$(sshpass -p "$ADMIN_PW" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "Administrator@$TARGET" \
            'cmd /c reg query HKLM\SOFTWARE\ORL\WinVNC3 /v Password' 2>/dev/null \
            | sed -n 's/.*Password[[:space:]]*REG_BINARY[[:space:]]*//p' | tr -d '\r\n ')
        if [ -z "$VNC_REG_HEX" ]; then
            VNC_REG_HEX=$(sshpass -p "$ADMIN_PW" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=10 "Administrator@$TARGET" \
                'cmd /c reg query HKLM\SOFTWARE\TightVNC\Server /v Password' 2>/dev/null \
                | sed -n 's/.*Password[[:space:]]*REG_BINARY[[:space:]]*//p' | tr -d '\r\n ')
        fi
        if [ -n "$VNC_REG_HEX" ]; then
            DECODED=$(python3 "${SCRIPT_DIR}/observability/vnc-cred-tool.py" decode \
                --hex "$VNC_REG_HEX" --wordlist "${SCRIPT_DIR}/../provisioning/wordlists/vnc-betterdefaultpasslist.txt" 2>/dev/null || true)
            if [ "$DECODED" = "$VNC_PW" ]; then
                VNC_CRED_OK=1
                VNC_CRED_VIA="registry-decode"
            fi
        fi
    fi
fi
if [ "$VNC_CRED_OK" -eq 1 ]; then
    check "vnc-foothold-creds" PASS "$VNC_PW accepted (${VNC_CRED_VIA:-ok})"
else
    check "vnc-foothold-creds" FAIL "$VNC_PW not accepted (rfb-probe/rfb-wordlist/hydra-compat/registry all failed)"
fi

# 2b. Wordlist sweep — always exercised (even when the single probe passed) so
# the paced brute path stays regression-tested. --delay-seconds keeps the sweep
# under TightVNC's in-memory pace limiter; see docs/runbooks/ews-vnc-adversary-emulation.md.
if command -v python3 >/dev/null 2>&1 && [ -f "$AUTH_PROBE" ] && [ -f "$CRED_TOOL" ] && [ -f "$VNC_WORDLIST" ]; then
    # Pause so a just-run single probe doesn't leave the limiter armed.
    sleep 1
    WL_JSON="$(python3 "$AUTH_PROBE" --host "$TARGET" --port 5900 \
        --wordlist "$VNC_WORDLIST" --cred-tool "$CRED_TOOL" \
        --delay-seconds 0.5 --json 2>/dev/null || true)"
    WL_FOUND="$(printf '%s' "$WL_JSON" | sed -n 's/.*"found": *"\([^"]*\)".*/\1/p')"
    WL_LAST="$(printf '%s' "$WL_JSON" | sed -n 's/.*"last_outcome": *"\([^"]*\)".*/\1/p')"
    if [ "$WL_FOUND" = "$VNC_PW" ]; then
        check "vnc-wordlist-brute" PASS "$VNC_PW found via paced RFB wordlist sweep"
    else
        check "vnc-wordlist-brute" FAIL "wordlist sweep did not recover $VNC_PW (last_outcome=${WL_LAST:-unknown}); raise --delay-seconds if last_outcome=no_vnc_auth"
    fi
else
    check "vnc-wordlist-brute" PASS "skipped (python3/check_vnc_auth.py/vnc-cred-tool/wordlist not all available)"
fi

# 3. SSH as patrick — service-path LPE preconditions
ssh_as_patrick() {
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$PATRICK_PW" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "patrick@$TARGET" "$@" 2>&1
    else
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "patrick@$TARGET" "$@" 2>&1
    fi
}

REG_OUT=$(ssh_as_patrick 'cmd /c reg query HKLM\SYSTEM\CurrentControlSet\Services\SecretConEwsSync /v ImagePath')
if [ -z "$REG_OUT" ]; then
    check "ssh-patrick-login" FAIL "could not read service ImagePath as patrick"
else
    check "ssh-patrick-login" PASS ""
    IMAGE_PATH=$(echo "$REG_OUT" | sed -n 's/.*ImagePath[[:space:]]*REG_[^[:space:]]*[[:space:]]*//p' | tr -d '\r\n')
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

    ICACLS_OUT=$(ssh_as_patrick 'cmd /c icacls "C:\Program Files\SecretCon"')
    if echo "$ICACLS_OUT" | grep -qi 'BUILTIN\\Users.*(M)'; then
        check "service-root-user-writable" PASS "Users:(M) on C:\\Program Files\\SecretCon"
    else
        check "service-root-user-writable" FAIL "BUILTIN\\Users does not have Modify on C:\\Program Files\\SecretCon"
    fi

    # User flag readable as patrick
    USER_FLAG=$(ssh_as_patrick 'cmd /c type C:\Users\patrick\Desktop\flag.txt')
    if [ -n "$USER_FLAG" ]; then
        check "user-flag-readable-as-patrick" PASS "$USER_FLAG"
    else
        check "user-flag-readable-as-patrick" FAIL "empty or unreadable"
    fi

    # Root flag NOT readable as patrick
    ROOT_OUT=$(ssh_as_patrick 'cmd /c type C:\Users\Administrator\Desktop\root.txt 2>&1')
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
