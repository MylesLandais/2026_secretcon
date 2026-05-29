#!/usr/bin/env bash
set -uo pipefail

# Stress campaign wrapper for the three-box Proxmox chain.
# Re-runs validate-three-box-chain.sh and records pass/fail scorecards.
#
# Usage:
#   ./scripts/observability/stress-campaign-chain.sh [--iterations N] [--siem] [--pivot]
#
# Flags:
#   --iterations N  number of campaign loops (default 3)
#   --siem          enable Wazuh drain + chain rule assertions per iteration
#   --pivot         additionally run the EWS->DC AS-REP pivot harness; pivot_score
#                   (0-7) is recorded in campaign-summary.csv per iteration

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/chain_env.sh
source "${REPO_ROOT}/scripts/lib/chain_env.sh"

ITERATIONS=3
SIEM=0
PIVOT=0
RUN_ID="chain-stress-$(date -u +%Y%m%dT%H%M%SZ)"

while [ $# -gt 0 ]; do
  case "$1" in
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --siem) SIEM=1; shift ;;
    --pivot) PIVOT=1; shift ;;
    -h|--help) sed -n '3,14p' "$0"; exit 0 ;;
    *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
  esac
done

OUT_BASE="${REPO_ROOT}/artifacts/campaign/stress-campaign/${RUN_ID}"
mkdir -p "$OUT_BASE"
LOG="${OUT_BASE}/campaign.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================================="
echo "Three-box chain stress campaign x${ITERATIONS}"
echo "  out-dir: ${OUT_BASE}"
echo "================================================="

if [ "$SIEM" -eq 1 ]; then
  "${REPO_ROOT}/scripts/wazuh-docker-up.sh" || true
  "${REPO_ROOT}/scripts/proxmox/sync-wazuh-rules.sh" 2>/dev/null || true
fi

CSV="${OUT_BASE}/campaign-summary.csv"
echo "iter,chain_ok,pass_count,fail_count,pivot_score" > "$CSV"

for i in $(seq 1 "$ITERATIONS"); do
  ITER_DIR="${OUT_BASE}/iter-${i}"
  mkdir -p "$ITER_DIR"
  echo "----- iter ${i}/${ITERATIONS} -----"
  EXTRA_ARGS=()
  if [ "$SIEM" -eq 1 ]; then EXTRA_ARGS+=(--siem); fi
  if [ "$PIVOT" -eq 1 ]; then
    EXTRA_ARGS+=(--pivot)
    export PIVOT_RUN_ID="pivot-iter-${i}-$(date -u +%H%M%SZ)"
  fi
  if CHAIN_VALIDATION_DIR="${ITER_DIR}" \
     "${REPO_ROOT}/scripts/validate-three-box-chain.sh" "${EXTRA_ARGS[@]}" \
     > "${ITER_DIR}/chain.log" 2>&1; then
    chain_ok=1
  else
    chain_ok=0
  fi
  pass_count=$(grep -c '^\[+\] PASS:' "${ITER_DIR}/chain.log" 2>/dev/null || echo 0)
  fail_count=$(grep -c '^\[!] FAIL:' "${ITER_DIR}/chain.log" 2>/dev/null || echo 0)

  pivot_score=""
  if [ "$PIVOT" -eq 1 ] && [ -n "${PIVOT_RUN_ID:-}" ]; then
    PIVOT_SCORECARD="${ITER_DIR}/pivot/${PIVOT_RUN_ID}/scorecard.json"
    if [ -f "$PIVOT_SCORECARD" ] && command -v jq >/dev/null 2>&1; then
      pivot_score="$(jq -r '.pass // 0' "$PIVOT_SCORECARD" 2>/dev/null || echo "")"
    fi
  fi
  echo "${i},${chain_ok},${pass_count},${fail_count},${pivot_score}" >> "$CSV"
  cat > "${ITER_DIR}/scorecard.json" <<JSON
{"iter":${i},"chain_ok":${chain_ok},"pass_count":${pass_count},"fail_count":${fail_count},"pivot_score":${pivot_score:-null}}
JSON
done

if [ "$PIVOT" -eq 1 ] && command -v awk >/dev/null 2>&1; then
  PIVOT_SEVENS=$(awk -F, 'NR>1 && $5==7 {n++} END {print n+0}' "$CSV")
  echo
  echo "[*] pivot_score == 7 in ${PIVOT_SEVENS}/${ITERATIONS} iterations"
fi

echo "================================================="
echo "Chain stress campaign complete"
echo "  summary: ${CSV}"
echo "================================================="
