#!/usr/bin/env bash
# Verify SecretConWatchdog service + supervisor task on a Windows guest.
#
# Usage:
#   ./scripts/validate/test-watchdog-agent.sh --target <ip> [--winrm-port PORT] [--profile ews|cysvuln]

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET=""
WINRM_PORT="${WINRM_PORT:-5985}"
ADMIN_PW="${ADMIN_PW:-${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}}"
PROFILE="ews"
ARTIFACTS="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts/resilience-validate/latest}"

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --winrm-port) WINRM_PORT="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        -h|--help) sed -n '3,6p' "$0"; exit 0 ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done
[ -n "$TARGET" ] || { echo "[!] --target required" >&2; exit 2; }

case "${PROFILE}" in
    ews) CHALLENGE_SVC=SecretConEwsSync ;;
    cysvuln) CHALLENGE_SVC=fswsService ;;
    *) echo "[!] profile must be ews or cysvuln" >&2; exit 2 ;;
esac

mkdir -p "${ARTIFACTS}"
PASS=0
FAIL=0
record() { printf '%s  %s\n' "$1" "$2"; [ "$1" = PASS ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1)); }

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

PS_CHECK=$(cat <<EOF
\$agent = Get-Service -Name SecretConWatchdog -ErrorAction SilentlyContinue
\$task = Get-ScheduledTask -TaskName SecretCon-Watchdog-Supervisor -ErrorAction SilentlyContinue
\$challenge = Get-Service -Name ${CHALLENGE_SVC} -ErrorAction SilentlyContinue
Write-Host "AGENT=\$(\$agent.Status)"
Write-Host "TASK=\$(if (\$task) { 'present' } else { 'missing' })"
Write-Host "CHALLENGE=\$(\$challenge.Status)"
Write-Host "CONFIG=\$(Test-Path -LiteralPath 'C:\\secretcon\\watchdog-config.json')"
EOF
)

OUT="$(winrm_ps "$PS_CHECK" 2>&1 || true)"
echo "$OUT" | tee "${ARTIFACTS}/watchdog-agent-${PROFILE}.out"

echo "$OUT" | grep -q 'AGENT=Running' && record PASS agent-service || record FAIL agent-service
echo "$OUT" | grep -q 'TASK=present' && record PASS supervisor-task || record FAIL supervisor-task
echo "$OUT" | grep -q 'CHALLENGE=Running' && record PASS challenge-service || record FAIL challenge-service
echo "$OUT" | grep -q 'CONFIG=True' && record PASS config-present || record FAIL config-present

echo "===== watchdog-agent (${PROFILE}): ${PASS} pass / ${FAIL} fail ====="
[ "$FAIL" -eq 0 ]
