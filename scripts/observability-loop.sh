#!/usr/bin/env bash
set -euo pipefail

# Top-level SIEM capture loop orchestrator.
#
# 1. Bring up the wazuh-docker single-node stack (--skip-stack to skip)
# 2. Randomize flags and persist them under
#    artifacts/cysvuln/observability-loop/<RUN_ID>/flags.env
# 3. Packer-rebuild cysvuln.qcow2 with the new flags + WAZUH_MANAGER set
#    to 10.0.2.2 so the agent dials the docker stack (--skip-rebuild)
# 4. Take a `baseline` qemu-img snapshot once the agent is enrolled and
#    Sysmon events are flowing (--skip-baseline)
# 5. Loop N (default 3) times: revert -> boot -> wait-active -> chain ->
#    drain alerts -> stop. Each iteration writes its own iter-N/ dir
#    with alerts.json, msiexec-timeline.json, summary.json, chain.log,
#    and an ossec.log tail.
# 6. Emit summary.csv + raw-notes.md across all iterations, ready for
#    folding findings into docs/cysvulnserver/defend-faq-walkthrough.md.
#
# Usage:
#   ./scripts/observability-loop.sh \
#       [--iterations N] [--run-id ID] \
#       [--skip-stack] [--skip-rebuild] [--skip-baseline]
#
# All artifacts under artifacts/cysvuln/observability-loop/<RUN_ID>/.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/loop_lib.sh
. "${REPO_ROOT}/scripts/lib/loop_lib.sh"

ITERATIONS=3
RUN_ID=""
SKIP_STACK=0
SKIP_REBUILD=0
SKIP_BASELINE=0
WAZUH_MANAGER_GW="${WAZUH_MANAGER_GW:-10.0.2.2}"
QCOW="${QCOW:-${REPO_ROOT}/artifacts/cysvuln/local-qemu/cysvuln.qcow2}"
SNAP_NAME="${SNAP_NAME:-baseline}"

while [ $# -gt 0 ]; do
    case "$1" in
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --skip-stack) SKIP_STACK=1; shift ;;
        --skip-rebuild) SKIP_REBUILD=1; shift ;;
        --skip-baseline) SKIP_BASELINE=1; shift ;;
        -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    RUN_ID="loop-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_BASE="${REPO_ROOT}/artifacts/cysvuln/observability-loop/${RUN_ID}"
mkdir -p "$OUT_BASE"

LOOP_LOG="${OUT_BASE}/loop.log"
exec > >(tee -a "$LOOP_LOG") 2>&1

# Env consumed by loop_lib.sh helpers.
export PIDFILE="${CYSVULN_PIDFILE:-/tmp/cysvuln-local.pid}"
export WINRM_PORT="${WINRM_PORT:-15985}"
export ADMIN_USER="${ADMIN_USER:-Administrator}"
export ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
export QCOW

AGENT_IP="${AGENT_IP:-10.0.2.15}"

echo "================================================="
echo "SIEM capture loop"
echo "  run-id     : ${RUN_ID}"
echo "  iterations : ${ITERATIONS}"
echo "  out-dir    : ${OUT_BASE}"
echo "  started    : $(date -u +%FT%TZ)"
echo "================================================="

# Phase 1: stack
if [ "$SKIP_STACK" -eq 0 ]; then
    echo
    echo "[phase] bring up wazuh-docker stack"
    "${REPO_ROOT}/scripts/wazuh-docker-up.sh"
else
    echo "[phase] skip-stack: assuming wazuh-docker is already up"
fi

# Phase 2: flags
echo
echo "[phase] generate flags"
FLAGS_ENV=$(loop_gen_or_reuse_flags "$RUN_ID" "$OUT_BASE")
# loop_gen_or_reuse_flags already exported SECRETCON_USER_FLAG / _ROOT_FLAG.

# Phase 3: packer rebuild
# Kill any pre-existing run-local QEMU first; cp -f on a running qcow2
# from build-cysvuln-local.sh would corrupt the freshly-built image.
loop_stop_vm

if [ "$SKIP_REBUILD" -eq 0 ]; then
    echo
    echo "[phase] packer rebuild (WAZUH_MANAGER=${WAZUH_MANAGER_GW})"
    BUILD_LOG="${OUT_BASE}/build.log" \
    WAZUH_MANAGER="$WAZUH_MANAGER_GW" \
    SECRETCON_USER_FLAG="$SECRETCON_USER_FLAG" \
    SECRETCON_ROOT_FLAG="$SECRETCON_ROOT_FLAG" \
        "${REPO_ROOT}/scripts/build-cysvuln-local.sh"
else
    echo "[phase] skip-rebuild: assuming ${QCOW} is already built with run-id flags + WAZUH_MANAGER=${WAZUH_MANAGER_GW}"
fi

# Phase 4: baseline snapshot
if [ "$SKIP_BASELINE" -eq 0 ]; then
    echo
    echo "[phase] baseline snapshot"
    "${REPO_ROOT}/scripts/observability/baseline-snapshot.sh" --qcow "$QCOW" --name "$SNAP_NAME"
else
    echo "[phase] skip-baseline: assuming qemu-img snapshot '${SNAP_NAME}' already exists"
fi

# Phase 5: iteration loop
echo
echo "[phase] iteration loop x${ITERATIONS}"

SUMMARY_CSV="${OUT_BASE}/summary.csv"
echo "iter,start,end,chain_exit,alert_count,unique_rule_ids,msiexec_rows" > "$SUMMARY_CSV"

trap loop_stop_vm EXIT

for i in $(seq 1 "$ITERATIONS"); do
    ITER_DIR="${OUT_BASE}/iter-${i}"
    mkdir -p "$ITER_DIR"

    echo
    echo "----- iter ${i}/${ITERATIONS} -----"
    echo "[*] reverting qcow to baseline"
    loop_stop_vm
    loop_revert_snapshot "$QCOW" "$SNAP_NAME"

    echo "[*] booting VM"
    "${REPO_ROOT}/scripts/run-local-cysvuln.sh" "$QCOW"

    echo "[*] waiting for WinRM + Wazuh agent (ip=${AGENT_IP})"
    WAZUH_AGENT_IP="$AGENT_IP" \
        "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 300 || true

    START_TS="$(date -u +%FT%TZ)"
    echo "[*] running validate-cysvuln-chain.sh (start=${START_TS})"
    CHAIN_LOG="${ITER_DIR}/chain.log"
    VALIDATION_LOG="$CHAIN_LOG" \
        "${REPO_ROOT}/scripts/validate-cysvuln-chain.sh" 127.0.0.1 || CHAIN_EXIT=$? || true
    CHAIN_EXIT=${CHAIN_EXIT:-0}
    sleep 30
    END_TS="$(date -u +%FT%TZ)"

    echo "[*] draining alerts ${START_TS} -> ${END_TS}"
    "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
        --since "$START_TS" --until "$END_TS" \
        --out-dir "$ITER_DIR" --include-archives || true

    ALERT_COUNT=$(wc -l < "${ITER_DIR}/alerts.json" 2>/dev/null | tr -d ' ' || echo 0)
    UNIQUE_RULES=$(jq -r '.rule.id // empty' "${ITER_DIR}/alerts.json" 2>/dev/null | sort -u | paste -sd';' || echo "")
    MSIEXEC_ROWS=$(jq 'length' "${ITER_DIR}/msiexec-timeline.json" 2>/dev/null || echo 0)

    cat > "${ITER_DIR}/summary.json" <<JSON
{
  "iter": ${i},
  "start": "${START_TS}",
  "end": "${END_TS}",
  "chain_exit": ${CHAIN_EXIT},
  "alert_count": ${ALERT_COUNT},
  "unique_rule_ids": "${UNIQUE_RULES}",
  "msiexec_rows": ${MSIEXEC_ROWS}
}
JSON

    echo "${i},${START_TS},${END_TS},${CHAIN_EXIT},${ALERT_COUNT},${UNIQUE_RULES},${MSIEXEC_ROWS}" >> "$SUMMARY_CSV"

    # Capture ossec.log tail from inside the guest for traceability.
    python3 - "$WINRM_PORT" "$ADMIN_PW" "${ITER_DIR}/ossec.log.tail" <<'PY' || true
import sys, winrm
port, pw, out = sys.argv[1:4]
s = winrm.Session(f"http://127.0.0.1:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
try:
    r = s.run_ps("Get-Content 'C:\\Program Files (x86)\\ossec-agent\\ossec.log' -Tail 80 -EA SilentlyContinue")
    with open(out, 'wb') as fh:
        fh.write(r.std_out or b"")
except Exception as exc:
    with open(out, 'w') as fh:
        fh.write(f"[!] ossec.log tail failed: {exc}\n")
PY

    echo "[*] stopping VM (end of iter ${i})"
    loop_stop_vm
done

trap - EXIT

# Phase 6: aggregate summary
echo
echo "[phase] aggregate summary"
RAW_NOTES="${OUT_BASE}/raw-notes.md"
cat > "$RAW_NOTES" <<MD
# SIEM capture loop raw notes

- Run ID: \`${RUN_ID}\`
- Iterations: ${ITERATIONS}
- Started: $(head -n 1 "$LOOP_LOG" 2>/dev/null || date -u +%FT%TZ)
- Finished: $(date -u +%FT%TZ)
- Flags: see \`flags.env\` (gitignored)

## summary.csv

\`\`\`
$(cat "$SUMMARY_CSV")
\`\`\`

## per-iteration unique rule IDs

MD
for i in $(seq 1 "$ITERATIONS"); do
    ITER_DIR="${OUT_BASE}/iter-${i}"
    if [ -f "${ITER_DIR}/alerts.json" ]; then
        echo "### iter ${i}" >> "$RAW_NOTES"
        echo >> "$RAW_NOTES"
        echo '```' >> "$RAW_NOTES"
        jq -r '"\(.rule.id // "-")\t\(.rule.description // "")"' "${ITER_DIR}/alerts.json" 2>/dev/null \
            | sort -u >> "$RAW_NOTES" || true
        echo '```' >> "$RAW_NOTES"
        echo >> "$RAW_NOTES"
    fi
done

echo
echo "================================================="
echo "SIEM capture loop complete"
echo "  run-id  : ${RUN_ID}"
echo "  out-dir : ${OUT_BASE}"
echo "  summary : ${SUMMARY_CSV}"
echo "  notes   : ${RAW_NOTES}"
echo "  next    : fold findings into docs/cysvulnserver/defend-faq-walkthrough.md"
echo "================================================="
