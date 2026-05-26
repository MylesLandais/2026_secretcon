#!/usr/bin/env bash
set -euo pipefail

# SIEM capture loop for the ASREP demo DC (local QEMU).
#
# Usage:
#   ./scripts/observability-loop-asrep.sh \
#       [--iterations N] [--run-id ID] \
#       [--skip-stack] [--skip-rebuild] [--skip-baseline]

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/loop_lib.sh
. "${REPO_ROOT}/scripts/lib/loop_lib.sh"

ITERATIONS=3
RUN_ID=""
SKIP_STACK=0
SKIP_REBUILD=0
SKIP_BASELINE=0
WAZUH_MANAGER_GW="${WAZUH_MANAGER_GW:-10.0.3.2}"
QCOW="${QCOW:-${REPO_ROOT}/artifacts/asrep/local-qemu/asrep.qcow2}"
SNAP_NAME="${SNAP_NAME:-baseline}"
AGENT_IP="${AGENT_IP:-10.0.3.15}"

while [ $# -gt 0 ]; do
    case "$1" in
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --skip-stack) SKIP_STACK=1; shift ;;
        --skip-rebuild) SKIP_REBUILD=1; shift ;;
        --skip-baseline) SKIP_BASELINE=1; shift ;;
        -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    RUN_ID="asrep-loop-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_BASE="${REPO_ROOT}/artifacts/asrep/observability-loop/${RUN_ID}"
mkdir -p "$OUT_BASE"

LOOP_LOG="${OUT_BASE}/loop.log"
exec > >(tee -a "$LOOP_LOG") 2>&1

export PIDFILE="${ASREP_PIDFILE:-/tmp/asrep-local.pid}"
export WINRM_PORT="${ASREP_WINRM_PORT:-15986}"
export ADMIN_USER="${ADMIN_USER:-Administrator}"
export ADMIN_PW="${ADMIN_PW:-${AD_SAFEMODE_PASSWORD:-PizzaMan123!}}"
export QCOW

echo "================================================="
echo "ASREP SIEM capture loop"
echo "  run-id     : ${RUN_ID}"
echo "  iterations : ${ITERATIONS}"
echo "  out-dir    : ${OUT_BASE}"
echo "================================================="

if [ "$SKIP_STACK" -eq 0 ]; then
    echo "[phase] bring up wazuh-docker stack"
    "${REPO_ROOT}/scripts/wazuh-docker-up.sh"
fi

echo "[phase] generate ASREP flag"
FLAGS_ENV=$(loop_gen_or_reuse_asrep_flags "$RUN_ID" "$OUT_BASE")

loop_stop_vm

if [ "$SKIP_REBUILD" -eq 0 ]; then
    echo "[phase] packer rebuild (WAZUH_MANAGER=${WAZUH_MANAGER_GW})"
    BUILD_LOG="${OUT_BASE}/build.log" \
    WAZUH_MANAGER="$WAZUH_MANAGER_GW" \
    SECRETCON_ASREP_FLAG="$SECRETCON_ASREP_FLAG" \
        "${REPO_ROOT}/scripts/build-asrep-local.sh"
else
    echo "[phase] skip-rebuild"
fi

if [ "$SKIP_BASELINE" -eq 0 ]; then
    echo "[phase] baseline snapshot"
    QCOW="$QCOW" AGENT_IP="$AGENT_IP" \
        "${REPO_ROOT}/scripts/observability/baseline-snapshot-asrep.sh" --qcow "$QCOW" --name "$SNAP_NAME"
else
    echo "[phase] skip-baseline"
fi

SUMMARY_CSV="${OUT_BASE}/summary.csv"
echo "iter,start,end,validate_exit,alert_count,unique_rule_ids,r100700,r100701" > "$SUMMARY_CSV"

trap loop_stop_vm EXIT

for i in $(seq 1 "$ITERATIONS"); do
    ITER_DIR="${OUT_BASE}/iter-${i}"
    mkdir -p "$ITER_DIR"

    echo "----- iter ${i}/${ITERATIONS} -----"
    loop_stop_vm
    loop_revert_snapshot "$QCOW" "$SNAP_NAME"

    "${REPO_ROOT}/scripts/run-local-asrep.sh" "$QCOW"
    WAZUH_AGENT_IP="$AGENT_IP" \
        "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 300 || true

    START_TS="$(date -u +%FT%TZ)"
    VALIDATE_LOG="${ITER_DIR}/validate.log"
    VALIDATE_EXIT=0
    if ! nix develop .#kali -c "${REPO_ROOT}/scripts/validate-asrep.sh" \
        > >(tee "$VALIDATE_LOG") 2>&1; then
        VALIDATE_EXIT=1
    fi
    sleep 30
    END_TS="$(date -u +%FT%TZ)"

    "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
        --since "$START_TS" --until "$END_TS" \
        --out-dir "$ITER_DIR" || true

    ALERT_COUNT=$(wc -l < "${ITER_DIR}/alerts.json" 2>/dev/null | tr -d ' ' || echo 0)
    UNIQUE_RULES=$(jq -r '.rule.id // empty' "${ITER_DIR}/alerts.json" 2>/dev/null | sort -u | paste -sd';' - || echo "")
    R100700=$(echo ";${UNIQUE_RULES};" | grep -q ';100700;' && echo 1 || echo 0)
    R100701=$(echo ";${UNIQUE_RULES};" | grep -q ';100701;' && echo 1 || echo 0)

    echo "${i},${START_TS},${END_TS},${VALIDATE_EXIT},${ALERT_COUNT},${UNIQUE_RULES},${R100700},${R100701}" >> "$SUMMARY_CSV"
    loop_stop_vm
done

trap - EXIT

RAW_NOTES="${OUT_BASE}/raw-notes.md"
cat > "$RAW_NOTES" <<MD
# ASREP SIEM capture loop raw notes

- Run ID: \`${RUN_ID}\`
- Iterations: ${ITERATIONS}
- Flags: see \`flags.env\`

## summary.csv

\`\`\`
$(cat "$SUMMARY_CSV")
\`\`\`
MD

echo "================================================="
echo "ASREP SIEM capture loop complete"
echo "  out-dir : ${OUT_BASE}"
echo "  summary : ${SUMMARY_CSV}"
echo "================================================="
