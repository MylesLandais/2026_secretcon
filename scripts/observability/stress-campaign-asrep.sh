#!/usr/bin/env bash
set -uo pipefail

# 10x ASREP stress campaign: snapshot revert -> GetNPUsers -> SIEM drain.
#
# Usage:
#   ./scripts/observability/stress-campaign-asrep.sh \
#       [--iterations N] [--run-id ID] [--skip-stack] [--skip-baseline]

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/loop_lib.sh
. "${REPO_ROOT}/scripts/lib/loop_lib.sh"

ITERATIONS=10
RUN_ID=""
SKIP_STACK=0
SKIP_BASELINE=0
QCOW="${QCOW:-${REPO_ROOT}/artifacts/asrep/local-qemu/asrep.qcow2}"
SNAP_NAME="${SNAP_NAME:-baseline}"
AGENT_IP="${AGENT_IP:-10.0.3.15}"

while [ $# -gt 0 ]; do
    case "$1" in
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --skip-stack) SKIP_STACK=1; shift ;;
        --skip-baseline) SKIP_BASELINE=1; shift ;;
        --baseline) SKIP_BASELINE=0; shift ;;
        -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    RUN_ID="asrep-stress-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_BASE="${REPO_ROOT}/artifacts/asrep/stress-campaign/${RUN_ID}"
mkdir -p "$OUT_BASE"

LOG="${OUT_BASE}/campaign.log"
exec > >(tee -a "$LOG") 2>&1

export PIDFILE="${ASREP_PIDFILE:-/tmp/asrep-local.pid}"
export WINRM_PORT="${ASREP_WINRM_PORT:-15986}"
export ADMIN_PW="${ADMIN_PW:-${AD_SAFEMODE_PASSWORD:-PizzaMan123!}}"
export QCOW

echo "================================================="
echo "ASREP stress campaign x${ITERATIONS}"
echo "  out-dir: ${OUT_BASE}"
echo "================================================="

if [ "$SKIP_STACK" -eq 0 ]; then
    "${REPO_ROOT}/scripts/wazuh-docker-up.sh"
fi

loop_gen_or_reuse_asrep_flags "$RUN_ID" "$OUT_BASE" >/dev/null

if [ "$SKIP_BASELINE" -eq 0 ]; then
    if ! qemu-img snapshot -l "$QCOW" 2>/dev/null | awk '{print $2}' | grep -Fxq "$SNAP_NAME"; then
        QCOW="$QCOW" AGENT_IP="$AGENT_IP" \
            "${REPO_ROOT}/scripts/observability/baseline-snapshot-asrep.sh" --qcow "$QCOW"
    fi
fi

CAMPAIGN_CSV="${OUT_BASE}/campaign-summary.csv"
echo "iter,hash_ok,crack_ok,fired_100700,fired_100701,alert_count,secretcon_rules" > "$CAMPAIGN_CSV"

trap loop_stop_vm EXIT

for i in $(seq 1 "$ITERATIONS"); do
    ITER_DIR="${OUT_BASE}/iter-${i}"
    mkdir -p "$ITER_DIR"

    echo "----- iter ${i}/${ITERATIONS} -----"
    loop_stop_vm
    loop_revert_snapshot "$QCOW" "$SNAP_NAME"
    "${REPO_ROOT}/scripts/run-local-asrep.sh" "$QCOW"
    WAZUH_AGENT_IP="$AGENT_IP" \
        "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 240 || true

    START_TS="$(date -u +%FT%TZ)"
    RED_LOG="${ITER_DIR}/red.log"
    hash_ok=0
    crack_ok=0
    if nix develop .#kali -c "${REPO_ROOT}/scripts/validate-asrep.sh" \
        > >(tee "$RED_LOG") 2>&1; then
        hash_ok=1
        if grep -q "hashcat cracked password" "$RED_LOG" 2>/dev/null; then
            crack_ok=1
        fi
    fi
    sleep 30
    END_TS="$(date -u +%FT%TZ)"

    "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
        --since "$START_TS" --until "$END_TS" \
        --out-dir "$ITER_DIR" || true

    secretcon_rules=$(jq -r '.rule.id // empty' "${ITER_DIR}/alerts.json" 2>/dev/null \
        | grep -E '^10070[0-2]$' | sort -u | paste -sd';' - || echo "")
    alert_count=$(wc -l < "${ITER_DIR}/alerts.json" 2>/dev/null | tr -d ' ' || echo 0)
    f700=$(echo ";${secretcon_rules};" | grep -q ';100700;' && echo 1 || echo 0)
    f701=$(echo ";${secretcon_rules};" | grep -q ';100701;' && echo 1 || echo 0)

    cat > "${ITER_DIR}/red-scorecard.json" <<JSON
{"iter":${i},"hash_ok":${hash_ok},"crack_ok":${crack_ok}}
JSON
    cat > "${ITER_DIR}/blue-scorecard.json" <<JSON
{"iter":${i},"fired_100700_asrep":$([ "$f700" -eq 1 ] && echo true || echo false),"fired_100701_tgs_rc4":$([ "$f701" -eq 1 ] && echo true || echo false),"alert_count":${alert_count},"secretcon_rule_ids":"${secretcon_rules}"}
JSON

    echo "${i},${hash_ok},${crack_ok},${f700},${f701},${alert_count},\"${secretcon_rules}\"" >> "$CAMPAIGN_CSV"
    loop_stop_vm
done

trap - EXIT

echo "================================================="
echo "ASREP stress campaign complete"
echo "  csv: ${CAMPAIGN_CSV}"
echo "================================================="
