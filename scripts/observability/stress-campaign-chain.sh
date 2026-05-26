#!/usr/bin/env bash
set -uo pipefail

# Stress campaign wrapper for the three-box Proxmox chain.
# Re-runs validate-three-box-chain.sh and records pass/fail scorecards.
#
# Usage:
#   ./scripts/observability/stress-campaign-chain.sh [--iterations N] [--siem]

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/chain_env.sh
source "${REPO_ROOT}/scripts/lib/chain_env.sh"

ITERATIONS=3
SIEM=0
RUN_ID="chain-stress-$(date -u +%Y%m%dT%H%M%SZ)"

while [ $# -gt 0 ]; do
  case "$1" in
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --siem) SIEM=1; shift ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
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
echo "iter,chain_ok,pass_count,fail_count" > "$CSV"

for i in $(seq 1 "$ITERATIONS"); do
  ITER_DIR="${OUT_BASE}/iter-${i}"
  mkdir -p "$ITER_DIR"
  echo "----- iter ${i}/${ITERATIONS} -----"
  SIEM_ARGS=()
  if [ "$SIEM" -eq 1 ]; then
    SIEM_ARGS=(--siem)
  fi
  if CHAIN_VALIDATION_DIR="${ITER_DIR}" \
     "${REPO_ROOT}/scripts/validate-three-box-chain.sh" "${SIEM_ARGS[@]}" \
     > "${ITER_DIR}/chain.log" 2>&1; then
    chain_ok=1
  else
    chain_ok=0
  fi
  pass_count=$(grep -c '^\[+\] PASS:' "${ITER_DIR}/chain.log" 2>/dev/null || echo 0)
  fail_count=$(grep -c '^\[!] FAIL:' "${ITER_DIR}/chain.log" 2>/dev/null || echo 0)
  echo "${i},${chain_ok},${pass_count},${fail_count}" >> "$CSV"
  cat > "${ITER_DIR}/scorecard.json" <<JSON
{"iter":${i},"chain_ok":${chain_ok},"pass_count":${pass_count},"fail_count":${fail_count}}
JSON
done

echo "================================================="
echo "Chain stress campaign complete"
echo "  summary: ${CSV}"
echo "================================================="
