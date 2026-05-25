#!/usr/bin/env bash
set -uo pipefail

# Walk each step of docs/cysvulnserver/walkthrough.md against an already
# booted CysVuln VM, draining Wazuh alerts + archives per phase. Goal:
# produce a per-phase SIEM footprint matrix - what every action looks
# like to the analyst.
#
# Sequential mode: phases run back-to-back against one boot. Each phase
# is bracketed by SECRETCON-PHASE-<id>-BEGIN / -END sentinel cmd /c echo
# events so slicing in the dataset is unambiguous even with overlap.
#
# Usage:
#   ./scripts/observability/run-baseline-tour.sh \
#       [--target HOST] [--run-id ID] [--skip-phases 04,07]
#
# Env knobs (mirror the rest of the observability tooling):
#   WINRM_PORT, ADMIN_PW, JOE_USER, JOE_PW, WAZUH_API_USER, WAZUH_API_PASSWORD

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="127.0.0.1"
RUN_ID=""
SKIP_PHASES=""
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_USER="${JOE_USER:-User_Joe}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
NOISE_S="${NOISE_S:-60}"
WAIT_AGENT_S="${WAIT_AGENT_S:-180}"
DRAIN_TAIL_S="${DRAIN_TAIL_S:-15}"
MGR_USER="${WAZUH_API_USER:-wazuh-wui}"
MGR_PASS="${WAZUH_API_PASSWORD:-MyS3cr37P450r.*-}"
AGENT_IP="${AGENT_IP:-10.0.2.15}"

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --skip-phases) SKIP_PHASES="$2"; shift 2 ;;
        -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    RUN_ID="baseline-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_BASE="${REPO_ROOT}/artifacts/cysvuln/observability-baseline/${RUN_ID}"
mkdir -p "$OUT_BASE"

LOG="${OUT_BASE}/tour.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================================="
echo "Baseline observability tour"
echo "  run-id   : ${RUN_ID}"
echo "  target   : ${TARGET}:${WINRM_PORT}"
echo "  out-dir  : ${OUT_BASE}"
echo "  started  : $(date -u +%FT%TZ)"
echo "================================================="

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "[!] jq required" >&2
    exit 2
fi

# Wait for WinRM
echo "[*] waiting for WinRM at 127.0.0.1:${WINRM_PORT}"
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if timeout 5 bash -c "</dev/tcp/127.0.0.1/${WINRM_PORT}" 2>/dev/null; then
        echo "    WinRM port open"
        break
    fi
    sleep 5
done

# Wait for Wazuh agent active
echo "[*] waiting for Wazuh agent (${AGENT_IP}) active"
deadline=$(( $(date +%s) + WAIT_AGENT_S ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    token=$(curl -sk --max-time 5 -u "${MGR_USER}:${MGR_PASS}" -X POST \
        "https://127.0.0.1:55000/security/user/authenticate?raw=true" 2>/dev/null || true)
    if [ -n "$token" ] && [[ "$token" != *"error"* ]]; then
        status=$(curl -sk --max-time 5 -H "Authorization: Bearer ${token}" \
            "https://127.0.0.1:55000/agents?ip=${AGENT_IP}" 2>/dev/null \
            | jq -r '.data.affected_items[0].status // "missing"')
        if [ "$status" = "active" ]; then
            echo "    agent active"
            break
        fi
    fi
    sleep 5
done

###############################################################################
# Helpers
###############################################################################

# Emit a SECRETCON-PHASE-<id>-<BEGIN|END> sentinel via Administrator WinRM.
# Shows up as Sysmon EID 1 with a unique commandLine so any dataset
# consumer can slice unambiguously.
marker() {
    local kind="$1" id="$2"
    python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_USER" "$ADMIN_PW" "$kind" "$id" \
        <<'PY' 2>/dev/null || true
import sys, winrm
target, port, user, pw, kind, pid = sys.argv[1:7]
s = winrm.Session(f"http://{target}:{port}/wsman",
                  auth=(user, pw), transport="ntlm")
s.run_cmd("cmd", ["/c", f"echo SECRETCON-PHASE-{pid}-{kind}"])
PY
}

skip_phase() {
    local id="$1"
    [ -n "$SKIP_PHASES" ] && [[ ",${SKIP_PHASES}," == *",${id},"* ]]
}

# Run one phase: bracket sentinels, run the command, drain Wazuh
# between [start - 5s, end + DRAIN_TAIL_S]. Each phase writes to its
# own directory under OUT_BASE/phase-<id>-<name>/.
phase() {
    local id="$1" name="$2"; shift 2
    local dir="${OUT_BASE}/phase-${id}-${name}"

    if skip_phase "$id"; then
        echo
        echo "----- phase ${id} (${name}): SKIPPED -----"
        return 0
    fi

    mkdir -p "$dir"
    echo
    echo "----- phase ${id} (${name}) -----"
    marker BEGIN "$id"
    local start; start=$(date -u +%FT%TZ)
    local start_epoch; start_epoch=$(date +%s)

    ( "$@" ) > "${dir}/stdout.log" 2>&1
    local rc=$?

    local end; end=$(date -u +%FT%TZ)
    local end_epoch; end_epoch=$(date +%s)
    marker END "$id"

    # Give Wazuh a few seconds to ingest the trailing events before draining.
    sleep "$DRAIN_TAIL_S"
    local until_ts
    until_ts=$(date -u -d "@$((end_epoch + DRAIN_TAIL_S))" +%FT%TZ 2>/dev/null \
               || date -u +%FT%TZ)
    local since_ts
    since_ts=$(date -u -d "@$((start_epoch - 5))" +%FT%TZ 2>/dev/null \
               || echo "$start")

    "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
        --since "$since_ts" --until "$until_ts" \
        --out-dir "$dir" --include-archives >/dev/null 2>&1 || true

    local runtime_s=$((end_epoch - start_epoch))
    summarize "$dir" "$id" "$name" "$since_ts" "$until_ts" "$rc" "$runtime_s"

    local cnt
    cnt=$(wc -l < "${dir}/alerts.json" 2>/dev/null | tr -d ' ' || echo 0)
    local arc
    arc=$(wc -l < "${dir}/archives.json" 2>/dev/null | tr -d ' ' || echo 0)
    echo "    rc=${rc} runtime=${runtime_s}s alerts=${cnt} archives=${arc}"
}

# Summarize a phase: top-5 rules, top channels, top images, lookup of
# any SecretCon custom-rule hit (100501-100517) for quick "did our
# detections fire?" review.
summarize() {
    local dir="$1" id="$2" name="$3" start="$4" end="$5" rc="$6" runtime_s="$7"
    local alerts="${dir}/alerts.json"
    local archives="${dir}/archives.json"
    [ -f "$alerts" ] || echo "" > "$alerts"
    [ -f "$archives" ] || echo "" > "$archives"

    local cnt arc unique_rules top_rules secretcon_rules top_channels top_images
    cnt=$(wc -l < "$alerts" 2>/dev/null | tr -d ' ' || echo 0)
    arc=$(wc -l < "$archives" 2>/dev/null | tr -d ' ' || echo 0)

    unique_rules=$(jq -r '.rule.id // empty' "$alerts" 2>/dev/null \
        | sort -u | paste -sd';')
    top_rules=$(jq -rs 'map(.rule.id // "-") | group_by(.) | map({id:.[0], n:length})
                       | sort_by(-.n) | .[:5]' "$alerts" 2>/dev/null \
                || echo "[]")
    secretcon_rules=$(jq -r '.rule.id // empty' "$alerts" 2>/dev/null \
        | grep -E '^1005[01][0-9]$' | sort -u | paste -sd';')
    top_channels=$(jq -rs 'map(.data.win.system.channel // "-") | group_by(.) | map({c:.[0], n:length})
                          | sort_by(-.n) | .[:5]' "$alerts" 2>/dev/null \
                   || echo "[]")
    top_images=$(jq -rs 'map(.data.win.eventdata.image // "-") | group_by(.) | map({i:.[0], n:length})
                        | sort_by(-.n) | .[:5]' "$alerts" 2>/dev/null \
                 || echo "[]")

    cat > "${dir}/summary.json" <<JSON
{
  "phase_id": "${id}",
  "phase_name": "${name}",
  "start": "${start}",
  "end": "${end}",
  "runtime_s": ${runtime_s},
  "exit_code": ${rc},
  "alert_count": ${cnt},
  "archive_count": ${arc},
  "unique_rule_ids": "${unique_rules}",
  "secretcon_rule_ids": "${secretcon_rules}",
  "top_rules": ${top_rules:-[]},
  "top_channels": ${top_channels:-[]},
  "top_images": ${top_images:-[]}
}
JSON
}

# Render the cross-phase matrix CSV + a starter markdown table.
render_matrix() {
    local out="$1"
    local csv="${out}/summary.csv"
    local md="${out}/matrix.md"

    {
        echo "phase_id,phase_name,start,end,runtime_s,exit_code,alert_count,archive_count,secretcon_rules,top_rule_id,top_rule_count"
        for d in "${out}"/phase-*/; do
            [ -d "$d" ] || continue
            local sj="${d}summary.json"
            [ -f "$sj" ] || continue
            jq -r '[
                .phase_id, .phase_name, .start, .end, .runtime_s, .exit_code,
                .alert_count, .archive_count, .secretcon_rule_ids,
                ((.top_rules // [])[0].id // "-"),
                ((.top_rules // [])[0].n  // 0)
            ] | @csv' "$sj"
        done
    } > "$csv"

    {
        echo "# Baseline tour matrix (run ${RUN_ID})"
        echo
        echo "| Phase | Tool | Runtime | Alerts | Archives | SecretCon rules | Top rule (count) | Exit |"
        echo "|---|---|---:|---:|---:|---|---|---:|"
        for d in "${out}"/phase-*/; do
            [ -d "$d" ] || continue
            local sj="${d}summary.json"
            [ -f "$sj" ] || continue
            jq -r '
                "| \(.phase_id) | \(.phase_name) | \(.runtime_s)s | \(.alert_count) | \(.archive_count) | \((.secretcon_rule_ids // "-") | if . == "" then "-" else . end) | \(((.top_rules // [])[0].id) // "-") (\((.top_rules // [])[0].n // 0)) | \(.exit_code) |"
            ' "$sj"
        done
    } > "$md"

    echo
    echo "[+] matrix.md and summary.csv written under ${out}"
}

###############################################################################
# Phase list (mirrors docs/cysvulnserver/walkthrough.md ToC)
###############################################################################

phase 00 noise sleep "$NOISE_S"

phase 03 smoke env WINRM_PORT="$WINRM_PORT" "${REPO_ROOT}/scripts/verify-cysvuln.sh" "$TARGET"

phase 04 foothold python3 "${REPO_ROOT}/scripts/validate/check_efs69_response.py" \
    --target "$TARGET" --port 18080 --service-port 80 --mode exec --cmd whoami

phase 05 user-flag "${REPO_ROOT}/scripts/lib/read_user_flag.sh" "$TARGET"

phase 06 aie-audit python3 "${REPO_ROOT}/scripts/validate/audit_aie.py" \
    --target "$TARGET" --port "$WINRM_PORT" \
    --user "$ADMIN_USER" --password "$ADMIN_PW" --profile-user "$JOE_USER"

phase 06a winpeas "${REPO_ROOT}/scripts/run-winpeas.sh" "$TARGET"

phase 06b sharpup "${REPO_ROOT}/scripts/run-sharpup.sh" "$TARGET"

phase 07 privesc "${REPO_ROOT}/scripts/validate-cysvuln-aie-joe.sh" "$TARGET"

phase 08 root-flag "${REPO_ROOT}/scripts/lib/read_root_flag.sh" "$TARGET"

render_matrix "$OUT_BASE"

echo
echo "================================================="
echo "Baseline tour complete"
echo "  run-id   : ${RUN_ID}"
echo "  out-dir  : ${OUT_BASE}"
echo "  matrix   : ${OUT_BASE}/matrix.md"
echo "  csv      : ${OUT_BASE}/summary.csv"
echo "  next     : hand-author docs/cysvulnserver/baseline-observability.md"
echo "================================================="
