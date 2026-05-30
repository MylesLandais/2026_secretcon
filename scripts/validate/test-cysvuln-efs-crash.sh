#!/usr/bin/env bash
# CysVuln EFS crash + recovery test (exec stager faults fswsService).
#
# Uses EDB-37951 USERID path via check_efs69_response.py (pinned 6.9).
# MSF 42256 (/sendemail.ghp) is manual-only — see scripts/validate/reference/.
#
# Usage:
#   ./scripts/validate/test-cysvuln-efs-crash.sh [target-ip]
#
# Env: CYSVULN_HTTP_PORT (18080), WINRM_PORT (15985), RECOVERY_TIMEOUT (90)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET="${1:-127.0.0.1}"
HTTP_PORT="${CYSVULN_HTTP_PORT:-18080}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-90}"
ARTIFACTS="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts/resilience-validate/latest}"

mkdir -p "${ARTIFACTS}"
LOG="${ARTIFACTS}/cysvuln-efs-crash.log"
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
sys.stderr.write(r.std_err.decode(errors="replace"))
sys.exit(r.status_code)
PY
}

echo "[*] CysVuln EFS crash test target=${TARGET} http=${HTTP_PORT} winrm=${WINRM_PORT}"

if ! WINRM_PORT="$WINRM_PORT" CYSVULN_HTTP_PORT="$HTTP_PORT" \
    "${REPO_ROOT}/scripts/cysvuln-local-prep.sh" "$TARGET"; then
    record FAIL prep "cysvuln-local-prep failed"
    exit 1
fi
record PASS prep "HTTP baseline up"

echo "[*] Sending exec stager (calc) — expect fswsService fault"
if python3 scripts/validate/check_efs69_response.py \
    --target "$TARGET" --port "$HTTP_PORT" --service-port 80 \
    --mode exec --cmd calc --timeout 15 2>&1; then
    record PASS exec-stager-sent "check_efs69_response exec"
else
    record FAIL exec-stager-sent "send failed"
fi
sleep 3

CRASH_OUT="$(winrm_ps "(Get-Service fswsService -EA SilentlyContinue).Status; Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} -MaxEvents 3 -EA SilentlyContinue | ForEach-Object { \$_.Message }" 2>&1 || true)"
printf '%s\n' "$CRASH_OUT" > "${ARTIFACTS}/cysvuln-crash-state.txt"

if echo "$CRASH_OUT" | grep -qiE 'Stopped|StopPending'; then
    record PASS crash-receipt "fswsService stopped after exec stager"
elif echo "$CRASH_OUT" | grep -qi 'fswsService.*c0000005\|c0000005.*fswsService'; then
    record PASS crash-receipt "Application 1000 access violation on fswsService.exe"
else
    record FAIL crash-receipt "service still running with no crash log — see ${ARTIFACTS}/cysvuln-crash-state.txt"
fi

echo "[*] Waiting up to ${RECOVERY_TIMEOUT}s for EFS HTTP recovery"
recovered=0
deadline=$(( $(date +%s) + RECOVERY_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    svc="$(winrm_ps "(Get-Service fswsService -EA SilentlyContinue).Status" 2>/dev/null | tr -d '\r\n ')"
    if curl -sf --max-time 5 -I "http://${TARGET}:${HTTP_PORT}/" 2>/dev/null | grep -qi 'Easy File Sharing'; then
        if [ "$svc" = "Running" ]; then
            recovered=1
            break
        fi
    fi
    sleep 5
done

if [ "$recovered" -eq 1 ]; then
    record PASS efs-recovery "fswsService Running + HTTP banner within ${RECOVERY_TIMEOUT}s"
else
    record FAIL efs-recovery "service/HTTP not healthy — see ${ARTIFACTS}/cysvuln-crash-state.txt"
fi

echo "===== cysvuln-efs-crash: ${PASS} pass / ${FAIL} fail ====="
[ "$FAIL" -eq 0 ]
