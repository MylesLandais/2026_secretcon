#!/usr/bin/env bash
# shellcheck shell=bash
#
# evidence-harness.sh -- PASS/FAIL/WARN accumulator with optional evidence file.
#
# Usage:
#   source scripts/lib/evidence-harness.sh
#   evidence_init [EVIDENCE_FILE]
#   evidence_record PASS "name" "detail"
#   evidence_summary "preflight results"

evidence_init() {
    EVIDENCE_FILE="${1:-}"
    EVIDENCE_PASS=0
    EVIDENCE_FAIL=0
    EVIDENCE_WARN=0
    if [ -n "$EVIDENCE_FILE" ]; then
        mkdir -p "$(dirname "$EVIDENCE_FILE")"
        : > "$EVIDENCE_FILE"
    fi
}

evidence_record() {
    local status="$1"
    local name="$2"
    local detail="${3:-}"
    local line="${status}  ${name}  ${detail}"
    if [ -n "${EVIDENCE_FILE:-}" ]; then
        printf '%s\n' "$line" >> "$EVIDENCE_FILE"
    fi
    case "$status" in
        PASS) EVIDENCE_PASS=$((EVIDENCE_PASS + 1)) ;;
        WARN) EVIDENCE_WARN=$((EVIDENCE_WARN + 1)) ;;
        *)    EVIDENCE_FAIL=$((EVIDENCE_FAIL + 1)) ;;
    esac
    if [ "${EVIDENCE_QUIET:-0}" -eq 1 ] && [ "$status" = "PASS" ]; then
        return 0
    fi
    printf '  %s\n' "$line"
}

evidence_summary() {
    local title="${1:-evidence results}"
    echo
    echo "===== $title ====="
    echo "  ${EVIDENCE_PASS} pass / ${EVIDENCE_WARN} warn / ${EVIDENCE_FAIL} fail"
    echo "================================="
    [ "${EVIDENCE_FAIL}" -eq 0 ]
}
