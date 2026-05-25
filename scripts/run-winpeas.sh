#!/usr/bin/env bash
set -uo pipefail

# Run winPEASx64.exe as User_Joe on the CysVuln VM and capture stdout
# to a timestamped log under artifacts/cysvuln/.
#
# Usage:
#   ./scripts/run-winpeas.sh [target-ip]
#
# Env knobs:
#   WINRM_PORT       WinRM port on the target (default 15985)
#   ADMIN_PW         Administrator password used for the WinRM transport
#                    (default PizzaMan123!)
#   JOE_USER         Standard-user account winPEAS impersonates via PsExec
#                    (default User_Joe)
#   JOE_PW           JOE_USER password (default VeryStrongPassword123!@#)
#   WINPEAS_URL      Override download URL (default upstream latest release)
#   WINPEAS_SHA256   Pin local binary hash; observed hash is logged regardless
#   WINPEAS_LOCAL    Skip download and use this local path
#   WINPEAS_LOG      Override output log path
#   WINPEAS_KEEP     If set to 1, leave the binary + output on the victim
#   WINPEAS_HOST_FROM_GUEST  Address the guest uses to pull the binary
#                            (default 10.0.2.2 = QEMU user-mode gateway)
#   WINPEAS_SERVE_PORT       Local staging port (default: random free port)

TARGET="${1:-127.0.0.1}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_USER="${JOE_USER:-User_Joe}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
TS="$(date -u +%Y%m%d-%H%M%S)"
LOG="${WINPEAS_LOG:-artifacts/cysvuln/winpeas-joe-${TS}.log}"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "[*] winpeas log: $LOG"
echo "[*] started: $(date -Is)"

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi

ARGS=(
    --target "$TARGET"
    --winrm-port "$WINRM_PORT"
    --admin-password "$ADMIN_PW"
    --joe-user "$JOE_USER"
    --joe-password "$JOE_PW"
)
if [ -n "${WINPEAS_URL:-}" ]; then ARGS+=(--url "$WINPEAS_URL"); fi
if [ -n "${WINPEAS_SHA256:-}" ]; then ARGS+=(--sha256 "$WINPEAS_SHA256"); fi
if [ -n "${WINPEAS_LOCAL:-}" ]; then ARGS+=(--local "$WINPEAS_LOCAL"); fi
if [ "${WINPEAS_KEEP:-0}" = "1" ]; then ARGS+=(--keep); fi
if [ -n "${WINPEAS_HOST_FROM_GUEST:-}" ]; then
    ARGS+=(--host-from-guest "$WINPEAS_HOST_FROM_GUEST")
fi
if [ -n "${WINPEAS_SERVE_PORT:-}" ]; then
    ARGS+=(--serve-port "$WINPEAS_SERVE_PORT")
fi

python3 scripts/validate/run_winpeas_as_joe.py "${ARGS[@]}"
RC=$?

echo
echo "===== run-winpeas ====="
echo "  exit code: $RC"
echo "  finished:  $(date -Is)"
echo "  log:       $LOG"
echo "======================="
exit "$RC"
