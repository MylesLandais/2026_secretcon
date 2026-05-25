#!/usr/bin/env bash
set -uo pipefail

# Run SharpUp.exe as User_Joe on the CysVuln VM and capture stdout to a
# timestamped log under artifacts/cysvuln/.
#
# Usage:
#   ./scripts/run-sharpup.sh [target-ip]
#
# Env knobs (mirror run-winpeas.sh):
#   WINRM_PORT       WinRM port on the target (default 15985)
#   ADMIN_PW         Administrator password used for the WinRM transport
#                    (default PizzaMan123!)
#   JOE_USER         Standard-user account SharpUp impersonates (default User_Joe)
#   JOE_PW           JOE_USER password (default VeryStrongPassword123!@#)
#   SHARPUP_URL      Override download URL (none by default; build from source)
#   SHARPUP_SHA256   Pin local binary hash
#   SHARPUP_LOCAL    Skip resolution and use this local path
#   SHARPUP_KEEP     If set to 1, leave SharpUp.exe + stdout on the victim
#   SHARPUP_HOST_FROM_GUEST  Guest -> attacker gateway (default 10.0.2.2)
#   SHARPUP_SERVE_PORT       Local HTTP staging port (default random)
#   SHARPUP_ARGS     Override SharpUp argument string (default "audit")
#   SHARPUP_LOG      Override output log path

TARGET="${1:-127.0.0.1}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_USER="${JOE_USER:-User_Joe}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
TS="$(date -u +%Y%m%d-%H%M%S)"
LOG="${SHARPUP_LOG:-artifacts/cysvuln/sharpup-joe-${TS}.log}"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "[*] sharpup log: $LOG"
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
if [ -n "${SHARPUP_URL:-}" ]; then ARGS+=(--url "$SHARPUP_URL"); fi
if [ -n "${SHARPUP_SHA256:-}" ]; then ARGS+=(--sha256 "$SHARPUP_SHA256"); fi
if [ -n "${SHARPUP_LOCAL:-}" ]; then ARGS+=(--local "$SHARPUP_LOCAL"); fi
if [ -n "${SHARPUP_ARGS:-}" ]; then ARGS+=(--args "$SHARPUP_ARGS"); fi
if [ "${SHARPUP_KEEP:-0}" = "1" ]; then ARGS+=(--keep); fi
if [ -n "${SHARPUP_HOST_FROM_GUEST:-}" ]; then
    ARGS+=(--host-from-guest "$SHARPUP_HOST_FROM_GUEST")
fi
if [ -n "${SHARPUP_SERVE_PORT:-}" ]; then
    ARGS+=(--serve-port "$SHARPUP_SERVE_PORT")
fi

python3 scripts/validate/run_sharpup_as_joe.py "${ARGS[@]}"
RC=$?

echo
echo "===== run-sharpup ====="
echo "  exit code: $RC"
echo "  finished:  $(date -Is)"
echo "  log:       $LOG"
echo "======================="
exit "$RC"
