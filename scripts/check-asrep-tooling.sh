#!/usr/bin/env bash
set -uo pipefail

# Verify attacker/build tooling is on PATH for ASREP validation.
#
# Usage:
#   ./scripts/check-asrep-tooling.sh [--default|--kali]

MODE="${1:---default}"

PASS=0
FAIL=0

check_bin() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "  PASS  $name  $(command -v "$name")"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name  not on PATH"
        FAIL=$((FAIL + 1))
    fi
}

check_py() {
    local mod="$1"
    if python3 -c "import ${mod}" 2>/dev/null; then
        echo "  PASS  python3 -m ${mod}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  python3 -m ${mod}"
        FAIL=$((FAIL + 1))
    fi
}

echo "===== check-asrep-tooling ($MODE) ====="

check_bin packer
check_bin qemu-system-x86_64
check_bin python3
check_bin curl
check_bin nc
check_bin jq
check_bin docker
check_py winrm

if [ "$MODE" = "--kali" ]; then
    check_bin GetNPUsers.py
    check_bin hashcat
    check_bin nmap
fi

echo "-----------------------------------------"
echo "  $PASS pass / $FAIL fail"
echo "========================================="

[ "$FAIL" -eq 0 ]
