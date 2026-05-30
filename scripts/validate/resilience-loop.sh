#!/usr/bin/env bash
# Self-improvement loop: fast gate always; optional full QEMU gate when disks exist.
#
# Usage:
#   ./scripts/validate/resilience-loop.sh           # fast gate only
#   ./scripts/validate/resilience-loop.sh --full    # fast + QEMU if possible
#   ./scripts/validate/resilience-loop.sh --full --skip-build

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

FULL=0
EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --full) FULL=1; shift ;;
        --skip-build) EXTRA+=(--skip-build); shift ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done

MAX_ATTEMPTS="${RESILIENCE_LOOP_ATTEMPTS:-3}"
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "[loop] attempt ${attempt}/${MAX_ATTEMPTS}"
    if ./scripts/validate/resilience-gate-fast.sh; then
        if [ "$FULL" -eq 0 ]; then
            echo "[loop] fast gate green — done"
            exit 0
        fi
        if ./scripts/validate/resilience-local-qemu.sh "${EXTRA[@]}"; then
            echo "[loop] full gate green — done"
            exit 0
        fi
        echo "[loop] full gate failed (VM/disk may be missing — fast gate still passed)"
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 2
done
echo "[loop] fast gate failed after ${MAX_ATTEMPTS} attempts"
exit 1
