#!/usr/bin/env bash
# Shared PASS/FAIL accumulator for verify-*.sh scripts.
#
# Usage:
#   source scripts/lib/check-harness.sh
#   check_init
#   check "name" PASS "detail"
#   check_summary "verify-cysvuln results"
#
# check_wazuh-agent.sh expects check() to exist before sourcing.

check_init() {
    CHECK_PASS=0
    CHECK_FAIL=0
    CHECK_RESULTS=()
}

check() {
    local name="$1"
    local status="$2"
    local detail="${3:-}"
    if [ "$status" = "PASS" ]; then
        CHECK_RESULTS+=("PASS  $name  $detail")
        CHECK_PASS=$((CHECK_PASS + 1))
    else
        CHECK_RESULTS+=("FAIL  $name  $detail")
        CHECK_FAIL=$((CHECK_FAIL + 1))
    fi
}

check_summary() {
    local title="${1:-verify results}"
    echo
    echo "===== $title ====="
    local r
    for r in "${CHECK_RESULTS[@]}"; do
        echo "  $r"
    done
    echo "---------------------------------"
    echo "  $CHECK_PASS pass / $CHECK_FAIL fail"
    echo "================================="
    [ "$CHECK_FAIL" -eq 0 ]
}
