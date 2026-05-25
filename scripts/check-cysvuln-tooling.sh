#!/usr/bin/env bash
set -uo pipefail

# Verify attacker/build tooling is on PATH for CysVuln validation.
#
# Usage:
#   ./scripts/check-cysvuln-tooling.sh [--default|--kali]

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

echo "===== check-cysvuln-tooling ($MODE) ====="

check_bin packer
check_bin qemu-system-x86_64
check_bin python3
check_bin curl
check_bin nc
check_bin wixl
check_py winrm
check_py keystone

if [ "$MODE" = "--kali" ]; then
    check_bin nmap
    check_bin msfvenom
    check_bin evil-winrm
    check_bin searchsploit
fi

echo "-----------------------------------------"
echo "  $PASS pass / $FAIL fail"
echo "========================================="

[ "$FAIL" -eq 0 ]
