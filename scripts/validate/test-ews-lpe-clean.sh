#!/usr/bin/env bash
# EWS unquoted service path clean exploit test (full LPE chain + post-reset health).
#
# Wraps validate-ews-lpe-chain.sh and adds VNC listener check after reset.
#
# Usage:
#   ./scripts/validate/test-ews-lpe-clean.sh --target <ip> [--no-reset]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET=""
EXTRA=()
ARTIFACTS="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts/resilience-validate/latest}"

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --no-reset) EXTRA+=(--no-reset); shift ;;
        -h|--help)
            sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

[ -n "$TARGET" ] || { echo "[!] --target required" >&2; exit 2; }

mkdir -p "${ARTIFACTS}"
export ARTIFACTS_DIR="${ARTIFACTS}"

echo "[*] EWS LPE clean test via validate-ews-lpe-chain.sh"
if "${REPO_ROOT}/scripts/validate/validate-ews-lpe-chain.sh" \
    --target "$TARGET" "${EXTRA[@]}" 2>&1 | tee "${ARTIFACTS}/ews-lpe-clean.log"; then
    :
else
    echo "[!] validate-ews-lpe-chain failed"
    exit 1
fi

PASS=0
FAIL=0
record() { local s="$1" n="$2" d="${3:-}"; printf '%s  %s  %s\n' "$s" "$n" "$d"; [ "$s" = PASS ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1)); }

if nmap -Pn -n -p 5900 --open --host-timeout 10s "$TARGET" 2>/dev/null | grep -qE '5900/tcp[[:space:]]+open'; then
    record PASS vnc-after-reset "tcp/5900 open"
else
    record FAIL vnc-after-reset "VNC not listening after reset"
fi

echo "===== ews-lpe-clean post-checks: ${PASS} pass / ${FAIL} fail ====="
[ "$FAIL" -eq 0 ]
