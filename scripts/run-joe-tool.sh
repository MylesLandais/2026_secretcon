#!/usr/bin/env bash
set -uo pipefail

# Single entry point for "run <tool> as User_Joe on the CysVuln VM and
# capture its output" workflows. Replaces three near-identical shell
# wrappers (run-sharpup.sh, run-winpeas.sh, run-msfvenom-aie.sh).
#
# Usage:
#   ./scripts/run-joe-tool.sh <tool> [target-ip] [tool-args...]
#
# Tools:
#   sharpup       — SharpUp.exe via scheduled-task; runs `audit` by default.
#                   Vendored binary at infrastructure/artifacts/cysvuln/SharpUp.exe.
#                   Env knobs: SHARPUP_URL, SHARPUP_SHA256, SHARPUP_LOCAL,
#                              SHARPUP_KEEP, SHARPUP_HOST_FROM_GUEST,
#                              SHARPUP_SERVE_PORT, SHARPUP_ARGS, SHARPUP_LOG
#   winpeas       — winPEASx64.exe via scheduled-task; runs a curated module set.
#                   Default URL pulls latest from peass-ng/PEASS-ng releases.
#                   Env knobs: WINPEAS_URL, WINPEAS_SHA256, WINPEAS_LOCAL,
#                              WINPEAS_KEEP, WINPEAS_HOST_FROM_GUEST,
#                              WINPEAS_SERVE_PORT, WINPEAS_LOG
#   msfvenom-aie  — build msfvenom MSI on the attacker, stage on the victim,
#                   trigger as User_Joe via PsExec to confirm AIE end-to-end.
#                   Needs: nix develop .#kali (msfvenom + xfreerdp).
#                   Env knobs: MSF_PAYLOAD, MSF_CMD, MSF_EXITFUNC, MSF_LOCAL,
#                              MSF_MSI_VICTIM_PATH, MSF_FLAG_VICTIM_PATH,
#                              MSF_LOG_VICTIM_PATH, MSF_HOST_FROM_GUEST,
#                              MSF_SERVE_PORT, MSF_KEEP, MSF_POLL_TIMEOUT,
#                              MSF_LOG, plus ADMIN_PW / JOE_PW / RDP_PORT
#
# Shared env knobs (apply to every tool):
#   WINRM_PORT   default 15985
#   ADMIN_PW     default PizzaMan123!
#   JOE_USER     default User_Joe
#   JOE_PW       default VeryStrongPassword123!@#

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '3,33p' "$0"
    exit 0
fi

TOOL="$1"; shift
TARGET="${1:-127.0.0.1}"
if [ $# -gt 0 ]; then shift; fi
TOOL_EXTRA=("$@")

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_USER="${JOE_USER:-User_Joe}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
TS="$(date -u +%Y%m%d-%H%M%S)"

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi

# Per-tool default log path; the env override slot follows joe_task_runner's
# <PREFIX>_LOG convention.
default_log() {
    case "$1" in
        sharpup)      echo "artifacts/cysvuln/sharpup-joe-${TS}.log" ;;
        winpeas)      echo "artifacts/cysvuln/winpeas-joe-${TS}.log" ;;
        msfvenom-aie) echo "artifacts/cysvuln/msfvenom-aie-${TS}.log" ;;
        *) echo "" ;;
    esac
}

case "$TOOL" in
    sharpup)  LOG="${SHARPUP_LOG:-$(default_log "$TOOL")}" ;;
    winpeas)  LOG="${WINPEAS_LOG:-$(default_log "$TOOL")}" ;;
    msfvenom-aie) LOG="${MSF_LOG:-$(default_log "$TOOL")}" ;;
    *)
        echo "[!] unknown tool: ${TOOL}" >&2
        echo "    known: sharpup, winpeas, msfvenom-aie" >&2
        exit 2
        ;;
esac

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "[*] ${TOOL} log: ${LOG}"
echo "[*] started: $(date -Is)"

# Build the python invocation depending on the tool. The
# joe-task tools share one CLI (run_joe_tool.py <tool>); the msfvenom
# flow is more involved (msi build + interactive trigger) and lives in
# run_msfvenom_aie.py.
case "$TOOL" in
    sharpup|winpeas)
        ARGS=(
            --target "$TARGET"
            --winrm-port "$WINRM_PORT"
            --admin-password "$ADMIN_PW"
            --joe-user "$JOE_USER"
            --joe-password "$JOE_PW"
        )
        # Tool-specific env knobs forwarded as CLI args. We only translate
        # the ones build_common_parser understands; everything else is
        # consumed directly by python via os.environ.
        if [ "$TOOL" = "sharpup" ]; then
            PFX="SHARPUP"
        else
            PFX="WINPEAS"
        fi
        for var in URL SHA256 LOCAL ARGS HOST_FROM_GUEST SERVE_PORT; do
            env_name="${PFX}_${var}"
            val="${!env_name:-}"
            if [ -n "$val" ]; then
                case "$var" in
                    HOST_FROM_GUEST) ARGS+=(--host-from-guest "$val") ;;
                    SERVE_PORT)      ARGS+=(--serve-port "$val") ;;
                    ARGS)            ARGS+=(--args "$val") ;;
                    URL)             ARGS+=(--url "$val") ;;
                    SHA256)          ARGS+=(--sha256 "$val") ;;
                    LOCAL)           ARGS+=(--local "$val") ;;
                esac
            fi
        done
        keep_env="${PFX}_KEEP"
        if [ "${!keep_env:-0}" = "1" ]; then
            ARGS+=(--keep)
        fi
        python3 "${REPO_ROOT}/scripts/validate/run_joe_tool.py" "$TOOL" "${ARGS[@]}" "${TOOL_EXTRA[@]}"
        RC=$?
        ;;
    msfvenom-aie)
        python3 "${REPO_ROOT}/scripts/validate/run_msfvenom_aie.py" \
            --target "$TARGET" \
            --winrm-port "$WINRM_PORT" \
            --admin-password "$ADMIN_PW" \
            --joe-password "$JOE_PW" \
            "${TOOL_EXTRA[@]}"
        RC=$?
        ;;
esac

echo
echo "===== run-joe-tool ${TOOL} ====="
echo "  exit code: $RC"
echo "  finished:  $(date -Is)"
echo "  log:       $LOG"
echo "================================"
exit "$RC"
