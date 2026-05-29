#!/usr/bin/env bash
# shellcheck shell=bash
#
# stress-campaign.sh -- shared stress-campaign scaffold (logging, CSV, scorecards).
#
# Usage:
#   source scripts/lib/stress-campaign.sh
#   campaign_init "$OUT_BASE" "$RUN_ID" "CysVuln stress x${ITERATIONS}"
#   campaign_iter_begin "$i" "$ITER_DIR"
#   campaign_iter_score "$i" "$ITER_DIR" "$chain_ok" "$pass_count" "$fail_count"
#   campaign_finish

campaign_init() {
    local out_base="$1"
    local run_id="$2"
    local title="$3"
    OUT_BASE="${out_base}"
    RUN_ID="${run_id}"
    mkdir -p "${OUT_BASE}"
    LOG="${OUT_BASE}/campaign.log"
    CSV="${OUT_BASE}/campaign-summary.csv"
    echo "iter,chain_ok,pass,fail,score" > "${CSV}"
    exec > >(tee -a "${LOG}") 2>&1
    echo "================================================="
    echo "${title} (${RUN_ID})"
    echo "================================================="
}

campaign_iter_begin() {
    local iter="$1"
    local iter_dir="$2"
    mkdir -p "${iter_dir}"
    echo ""
    echo "--- iteration ${iter} ---"
}

campaign_iter_score() {
    local iter="$1"
    local iter_dir="$2"
    local chain_ok="$3"
    local pass_count="$4"
    local fail_count="$5"
    local pivot_score="${6:-0}"
    echo "${iter},${chain_ok},${pass_count},${fail_count},${pivot_score}" >> "${CSV}"
    cat > "${iter_dir}/scorecard.json" <<JSON
{"iter":${iter},"chain_ok":${chain_ok},"pass":${pass_count},"fail":${fail_count},"score":${pivot_score}}
JSON
}

campaign_finish() {
    echo ""
    echo "[*] Campaign complete: ${OUT_BASE}"
    echo "[*] Summary: ${CSV}"
}
