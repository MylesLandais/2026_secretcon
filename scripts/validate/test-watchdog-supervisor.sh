#!/usr/bin/env bash
# Kill SecretConWatchdog and assert 60s supervisor task restores it.
#
# Usage: ./scripts/validate/test-watchdog-supervisor.sh --target <ip> [--winrm-port PORT]

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET=""
WINRM_PORT="${WINRM_PORT:-5985}"
ADMIN_PW="${ADMIN_PW:-${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}}"
WAIT_SEC="${WATCHDOG_SUPERVISOR_WAIT:-70}"
ARTIFACTS="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts/resilience-validate/latest}"

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --winrm-port) WINRM_PORT="$2"; shift 2 ;;
        -h|--help) sed -n '3,6p' "$0"; exit 0 ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done
[ -n "$TARGET" ] || { echo "[!] --target required" >&2; exit 2; }

mkdir -p "${ARTIFACTS}"

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

winrm_ps 'Stop-Service -Name SecretConWatchdog -Force -ErrorAction SilentlyContinue; Write-Host KILLED'
echo "[*] waiting ${WAIT_SEC}s for supervisor task"
sleep "${WAIT_SEC}"
OUT="$(winrm_ps '$s=Get-Service SecretConWatchdog -EA SilentlyContinue; Write-Host "AGENT=$($s.Status)"' 2>&1 || true)"
echo "$OUT" | tee "${ARTIFACTS}/watchdog-supervisor.out"
echo "$OUT" | grep -q 'AGENT=Running'
