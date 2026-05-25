#!/usr/bin/env bash
set -uo pipefail

# Tier 2 CysVuln validation: known User_Joe creds -> interactive msiexec -> root flag.
#
# Usage:
#   ./scripts/validate-cysvuln-aie-joe.sh [target-ip]

TARGET="${1:-127.0.0.1}"
HTTP_PORT="${CYSVULN_HTTP_PORT:-18080}"
WINRM_PORT="${WINRM_PORT:-15985}"
RDP_PORT="${CYSVULN_RDP_PORT:-13389}"
VALIDATION_LOG="${VALIDATION_LOG:-artifacts/cysvuln/validation-aie-joe.log}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"

mkdir -p "$(dirname "$VALIDATION_LOG")"
exec > >(tee -a "$VALIDATION_LOG") 2>&1
echo "[*] validation log: $VALIDATION_LOG"
echo "[*] started: $(date -Is)"

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi

PASS=0
FAIL=0

step() { echo; echo "===== $1 ====="; }
ok() { echo "[+] PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "[!] FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

step "prep"
if WINRM_PORT="$WINRM_PORT" CYSVULN_HTTP_PORT="$HTTP_PORT" ./scripts/cysvuln-local-prep.sh "$TARGET"; then
    ok "local prep"
else
    bad "local prep"
fi

step "smoke"
if WINRM_PORT="$WINRM_PORT" ./scripts/verify-cysvuln.sh "$TARGET"; then
    ok "verify-cysvuln"
else
    bad "verify-cysvuln"
fi

step "audit aie (User_Joe hive)"
if python3 scripts/validate/audit_aie.py \
    --target "$TARGET" --port "$WINRM_PORT" \
    --user Administrator --password "$ADMIN_PW" \
    --profile-user User_Joe; then
    ok "audit_aie"
else
    bad "audit_aie"
fi

step "AIE via interactive User_Joe (PsExec / RDP fallback)"
if python3 scripts/validate/run_aie_as_joe_interactive.py \
    --target "$TARGET" --winrm-port "$WINRM_PORT" --rdp-port "$RDP_PORT" \
    --admin-password "$ADMIN_PW" --joe-password "$JOE_PW"; then
    ok "AIE via interactive User_Joe"
else
    bad "AIE via interactive User_Joe"
fi

step "root flag cross-check"
python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_PW" <<'PY'
import sys, winrm
host, port, pw = sys.argv[1:4]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
ps = r"""
$aie = Get-Content 'C:\Users\Public\aie-flag.txt' -Raw -EA SilentlyContinue
$root = Get-Content 'C:\Users\Administrator\Desktop\root.txt' -Raw -EA SilentlyContinue
if (-not $aie -or -not $root) { exit 1 }
Write-Host "aie-flag:" $aie.Trim()
Write-Host "root.txt:" $root.Trim()
if ($aie.Trim() -eq $root.Trim()) { exit 0 } else { exit 2 }
"""
r = s.run_ps(ps)
print(r.std_out.decode(errors="replace").strip())
sys.exit(r.status_code)
PY

case $? in
    0) ok "root flag matches aie-flag.txt" ;;
    *) bad "root flag cross-check" ;;
esac

echo
echo "===== validate-cysvuln-aie-joe ====="
echo "  $PASS pass / $FAIL fail"
echo "  finished: $(date -Is)"
echo "==================================="
[ "$FAIL" -eq 0 ]
