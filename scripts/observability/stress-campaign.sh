#!/usr/bin/env bash
set -uo pipefail

# Stress campaign orchestrator: 10x snapshot-restored full walkthrough.
#
# Merges scripts/observability-loop.sh (snapshot revert / boot / drain
# bookkeeping) with scripts/observability/run-baseline-tour.sh (phased
# walkthrough + per-phase SIEM drain). Each iteration produces a per-iter
# red-scorecard.json (flag recovery, phase exit codes) and a
# blue-scorecard.json (rule IDs seen, alert counts per phase) so both
# the CTF team and the SOC team can read the same dataset.
#
# Outputs all artifacts under:
#   artifacts/cysvuln/stress-campaign/<RUN_ID>/
#     flags.env
#     campaign-summary.csv
#     iter-{1..N}/phase-*/{alerts,archives,summary}.{json,csv}
#     iter-{1..N}/{red,blue}-scorecard.json
#     campaign.log
#
# Usage:
#   ./scripts/observability/stress-campaign.sh \
#       [--iterations N (default 10)] [--run-id ID] \
#       [--skip-stack] [--skip-rebuild] [--skip-baseline] \
#       [--skip-phases 04a,06b] [--noise-s 30]
#
# Env knobs (mirror observability-loop / baseline-tour):
#   WINRM_PORT, ADMIN_PW, JOE_USER, JOE_PW, WAZUH_API_USER,
#   WAZUH_API_PASSWORD, WAZUH_MANAGER_GW, AGENT_IP, QCOW, SNAP_NAME

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/loop_lib.sh
. "${REPO_ROOT}/scripts/lib/loop_lib.sh"

ITERATIONS=10
RUN_ID=""
SKIP_STACK=0
SKIP_REBUILD=1                # default: reuse current image; campaigns should
                              # be cheap to repeat. --rebuild flips this.
SKIP_BASELINE=1               # same logic: reuse existing baseline snapshot.
SKIP_PHASES=""
NOISE_S=30                    # short noise window keeps 10x wall clock down

while [ $# -gt 0 ]; do
    case "$1" in
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --skip-stack) SKIP_STACK=1; shift ;;
        --skip-rebuild) SKIP_REBUILD=1; shift ;;
        --rebuild) SKIP_REBUILD=0; shift ;;
        --skip-baseline) SKIP_BASELINE=1; shift ;;
        --baseline) SKIP_BASELINE=0; shift ;;
        --skip-phases) SKIP_PHASES="$2"; shift 2 ;;
        --noise-s) NOISE_S="$2"; shift 2 ;;
        -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    RUN_ID="stress-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_BASE="${REPO_ROOT}/artifacts/cysvuln/stress-campaign/${RUN_ID}"
mkdir -p "$OUT_BASE"

LOG="${OUT_BASE}/campaign.log"
exec > >(tee -a "$LOG") 2>&1

# Env consumed by loop_lib.sh helpers + downstream scripts.
export QCOW="${QCOW:-${REPO_ROOT}/artifacts/cysvuln/local-qemu/cysvuln.qcow2}"
SNAP_NAME="${SNAP_NAME:-baseline}"
export WINRM_PORT="${WINRM_PORT:-15985}"
export ADMIN_USER="${ADMIN_USER:-Administrator}"
export ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_USER="${JOE_USER:-User_Joe}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
AGENT_IP="${AGENT_IP:-10.0.2.15}"
WAZUH_MANAGER_GW="${WAZUH_MANAGER_GW:-10.0.2.2}"
export PIDFILE="${CYSVULN_PIDFILE:-/tmp/cysvuln-local.pid}"
DRAIN_TAIL_S="${DRAIN_TAIL_S:-12}"

echo "================================================="
echo "Stress campaign"
echo "  run-id     : ${RUN_ID}"
echo "  iterations : ${ITERATIONS}"
echo "  out-dir    : ${OUT_BASE}"
echo "  qcow       : ${QCOW}"
echo "  snapshot   : ${SNAP_NAME}"
echo "  noise-s    : ${NOISE_S}"
echo "  started    : $(date -u +%FT%TZ)"
echo "================================================="

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v qemu-img >/dev/null 2>&1; then
    echo "[!] jq + qemu-img required" >&2
    exit 2
fi

###############################################################################
# One-time prep (idempotent)
###############################################################################

if [ "$SKIP_STACK" -eq 0 ]; then
    echo
    echo "[prep] wazuh-docker stack"
    "${REPO_ROOT}/scripts/wazuh-docker-up.sh"
else
    echo "[prep] skip-stack: assuming wazuh-docker is already up"
fi

echo
echo "[prep] flags"
if [ "$SKIP_REBUILD" -eq 1 ]; then
    # The QCOW was baked with a previous run's tokens; generating fresh
    # random flags here would make the red scorecard's grep always miss.
    # Probe the live box once the VM is up - we do that lazily inside
    # the first iteration. For now, leave the placeholders empty so the
    # scorecard can detect them.
    SECRETCON_USER_FLAG=""
    SECRETCON_ROOT_FLAG=""
    SECRETCON_RUN_ID="$RUN_ID"
    echo "[*] skip-rebuild active: flag tokens will be sniffed from the running VM during iter 1"
else
    loop_gen_or_reuse_flags "$RUN_ID" "$OUT_BASE" >/dev/null
fi

if [ "$SKIP_REBUILD" -eq 0 ]; then
    echo
    echo "[prep] packer rebuild (WAZUH_MANAGER=${WAZUH_MANAGER_GW})"
    loop_stop_vm
    BUILD_LOG="${OUT_BASE}/build.log" \
    WAZUH_MANAGER="$WAZUH_MANAGER_GW" \
    SECRETCON_USER_FLAG="$SECRETCON_USER_FLAG" \
    SECRETCON_ROOT_FLAG="$SECRETCON_ROOT_FLAG" \
        "${REPO_ROOT}/scripts/build-cysvuln-local.sh"
else
    echo "[prep] skip-rebuild: assuming ${QCOW} already built with current flags + WAZUH_MANAGER=${WAZUH_MANAGER_GW}"
fi

if [ "$SKIP_BASELINE" -eq 0 ]; then
    echo
    echo "[prep] baseline snapshot"
    loop_stop_vm
    "${REPO_ROOT}/scripts/observability/baseline-snapshot.sh" --qcow "$QCOW" --name "$SNAP_NAME"
else
    echo "[prep] skip-baseline: assuming qemu-img snapshot '${SNAP_NAME}' already exists"
fi

###############################################################################
# Per-iteration helpers
###############################################################################

skip_phase() {
    local id="$1"
    [ -n "$SKIP_PHASES" ] && [[ ",${SKIP_PHASES}," == *",${id},"* ]]
}

run_phase() {
    local iter="$1" id="$2" name="$3"; shift 3
    local iter_dir="${OUT_BASE}/iter-${iter}"
    local dir="${iter_dir}/phase-${id}-${name}"

    if skip_phase "$id"; then
        echo
        echo "  >> phase ${id} (${name}): SKIPPED"
        mkdir -p "$dir"
        echo '{"skipped": true}' > "${dir}/summary.json"
        return 0
    fi

    mkdir -p "$dir"
    echo
    echo "  >> phase ${id} (${name})"
    loop_winrm_marker BEGIN "$id" "$iter"
    local start_epoch; start_epoch=$(date +%s)
    local start; start=$(date -u +%FT%TZ)

    ( "$@" ) > "${dir}/stdout.log" 2>&1
    local rc=$?

    local end_epoch; end_epoch=$(date +%s)
    local end; end=$(date -u +%FT%TZ)
    loop_winrm_marker END "$id" "$iter"

    sleep "$DRAIN_TAIL_S"
    local since_ts until_ts
    since_ts=$(date -u -d "@$((start_epoch - 5))" +%FT%TZ 2>/dev/null || echo "$start")
    until_ts=$(date -u -d "@$((end_epoch + DRAIN_TAIL_S))" +%FT%TZ 2>/dev/null || date -u +%FT%TZ)

    "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
        --since "$since_ts" --until "$until_ts" \
        --out-dir "$dir" --include-archives >/dev/null 2>&1 || true

    local cnt arc
    cnt=$(wc -l < "${dir}/alerts.json" 2>/dev/null | tr -d ' ' || echo 0)
    arc=$(wc -l < "${dir}/archives.json" 2>/dev/null | tr -d ' ' || echo 0)

    local secretcon_rules unique_rules
    unique_rules=$(jq -r '.rule.id // empty' "${dir}/alerts.json" 2>/dev/null | sort -u | paste -sd';' || echo "")
    secretcon_rules=$(jq -r '.rule.id // empty' "${dir}/alerts.json" 2>/dev/null \
        | grep -E '^1005[0-3][0-9]$' | sort -u | paste -sd';' || echo "")

    cat > "${dir}/summary.json" <<JSON
{
  "phase_id": "${id}",
  "phase_name": "${name}",
  "start": "${start}",
  "end": "${end}",
  "runtime_s": $((end_epoch - start_epoch)),
  "exit_code": ${rc},
  "alert_count": ${cnt},
  "archive_count": ${arc},
  "unique_rule_ids": "${unique_rules}",
  "secretcon_rule_ids": "${secretcon_rules}"
}
JSON
    echo "     rc=${rc} alerts=${cnt} archives=${arc} secretcon=[${secretcon_rules}]"
    return 0
}

iter_red_scorecard() {
    local iter="$1"
    local iter_dir="${OUT_BASE}/iter-${iter}"

    # Grep stdout for the actual flag tokens to confirm the chain
    # recovered the right values, not just *some* string. Tokens are
    # exported by loop_gen_or_reuse_flags or sniffed in iter 1.
    local user_phase="${iter_dir}/phase-05-user-flag/stdout.log"
    local root_phase="${iter_dir}/phase-08-root-flag/stdout.log"
    local user_flag_ok=false root_flag_ok=false foothold_ok=false aie_ok=false
    if [ -f "$user_phase" ] && [ -n "$SECRETCON_USER_FLAG" ] \
        && grep -Fq "$SECRETCON_USER_FLAG" "$user_phase"; then
        user_flag_ok=true
    fi
    if [ -f "$root_phase" ] && [ -n "$SECRETCON_ROOT_FLAG" ] \
        && grep -Fq "$SECRETCON_ROOT_FLAG" "$root_phase"; then
        root_flag_ok=true
    fi
    local foothold_phase
    for foothold_phase in "${iter_dir}/phase-04a-foothold-callback" "${iter_dir}/phase-04b-foothold-exec"; do
        local fp_summary="${foothold_phase}/summary.json"
        if [ -f "${foothold_phase}/stdout.log" ] && grep -qE 'user_joe|User_Joe' "${foothold_phase}/stdout.log"; then
            foothold_ok=true
            break
        fi
        if [ -f "$fp_summary" ] && [ "$(jq -r '.exit_code // -1' "$fp_summary" 2>/dev/null)" = "0" ] \
            && [ "$(basename "$foothold_phase")" = "phase-04b-foothold-exec" ] \
            && grep -q 'Exec stager sent' "${foothold_phase}/stdout.log" 2>/dev/null; then
            foothold_ok=true
            break
        fi
    done
    if [ -f "${iter_dir}/phase-06-aie-audit/stdout.log" ] && grep -q 'chain response expected: True' "${iter_dir}/phase-06-aie-audit/stdout.log"; then
        aie_ok=true
    fi

    local privesc_rc
    privesc_rc=$(jq -r '.exit_code // -1' "${iter_dir}/phase-07-privesc/summary.json" 2>/dev/null || echo -1)

    cat > "${iter_dir}/red-scorecard.json" <<JSON
{
  "iter": ${iter},
  "user_flag_recovered": ${user_flag_ok},
  "root_flag_recovered": ${root_flag_ok},
  "foothold_as_joe": ${foothold_ok},
  "aie_chain_expected": ${aie_ok},
  "privesc_chain_exit_code": ${privesc_rc},
  "both_flags_recovered": $([ "$user_flag_ok" = true ] && [ "$root_flag_ok" = true ] && echo true || echo false)
}
JSON
}

iter_blue_scorecard() {
    local iter="$1"
    local iter_dir="${OUT_BASE}/iter-${iter}"

    # Aggregate all phase alerts.json into one stream so we can answer:
    # which SecretCon rules fired this iter, total alerts, alerts per phase.
    local agg="${iter_dir}/iter-alerts.jsonl"
    : > "$agg"
    local phase_breakdown="["
    local first_phase=true
    local p
    for p in "${iter_dir}"/phase-*/; do
        [ -d "$p" ] || continue
        local pn pid pcnt prc
        pn=$(jq -r '.phase_name // "-"' "${p}summary.json" 2>/dev/null || echo "-")
        pid=$(jq -r '.phase_id // "-"' "${p}summary.json" 2>/dev/null || echo "-")
        pcnt=$(jq -r '.alert_count // 0' "${p}summary.json" 2>/dev/null || echo 0)
        prc=$(jq -r '.exit_code // -1' "${p}summary.json" 2>/dev/null || echo -1)
        cat "${p}alerts.json" 2>/dev/null >> "$agg" || true
        if [ "$first_phase" = true ]; then
            first_phase=false
        else
            phase_breakdown+=","
        fi
        phase_breakdown+="{\"phase_id\":\"${pid}\",\"phase_name\":\"${pn}\",\"alerts\":${pcnt},\"exit_code\":${prc}}"
    done
    phase_breakdown+="]"

    local total_alerts secretcon_seen rules_seen
    total_alerts=$(wc -l < "$agg" 2>/dev/null | tr -d ' ' || echo 0)
    rules_seen=$(jq -r '.rule.id // empty' "$agg" 2>/dev/null | sort -u | paste -sd';' || echo "")
    secretcon_seen=$(jq -r '.rule.id // empty' "$agg" 2>/dev/null | grep -E '^1005[0-3][0-9]$' | sort -u | paste -sd';' || echo "")

    # Wazuh overrides children with chained parent: when 100530
    # (enum -> msiexec correlation) fires, the underlying 100508/100509
    # is suppressed in alerts.json even though it logically matched.
    # Count 100530 as also-fired-the-enum-rule so the analyst rollup
    # shows the actual coverage of the chain.
    local has_100507 has_100508 has_100509 has_100510 has_100512 has_100520 has_100530
    has_100507=$(echo ";$secretcon_seen;" | grep -q ';100507;' && echo true || echo false)
    has_100508=$(echo ";$secretcon_seen;" | grep -qE ';100508;|;100530;' && echo true || echo false)
    has_100509=$(echo ";$secretcon_seen;" | grep -qE ';100509;|;100530;' && echo true || echo false)
    has_100510=$(echo ";$secretcon_seen;" | grep -q ';100510;' && echo true || echo false)
    has_100512=$(echo ";$secretcon_seen;" | grep -q ';100512;' && echo true || echo false)
    has_100520=$(echo ";$secretcon_seen;" | grep -q ';100520;' && echo true || echo false)
    has_100530=$(echo ";$secretcon_seen;" | grep -q ';100530;' && echo true || echo false)

    cat > "${iter_dir}/blue-scorecard.json" <<JSON
{
  "iter": ${iter},
  "total_alerts": ${total_alerts},
  "unique_rule_ids": "${rules_seen}",
  "secretcon_rule_ids": "${secretcon_seen}",
  "fired_100507_efs_crash": ${has_100507},
  "fired_100508_winpeas": ${has_100508},
  "fired_100509_sharpup": ${has_100509},
  "fired_100510_aie_msiexec": ${has_100510},
  "fired_100512_system_child": ${has_100512},
  "fired_100520_user_flag_access": ${has_100520},
  "fired_100530_enum_to_aie": ${has_100530},
  "phase_breakdown": ${phase_breakdown}
}
JSON
}

###############################################################################
# Iteration loop
###############################################################################

CAMPAIGN_CSV="${OUT_BASE}/campaign-summary.csv"
echo "iter,start,end,wall_s,user_flag,root_flag,both_flags,foothold_joe,aie_expected,total_alerts,r100507,r100508,r100509,r100510,r100512,r100520,r100530,secretcon_rules" > "$CAMPAIGN_CSV"

trap loop_stop_vm EXIT

for i in $(seq 1 "$ITERATIONS"); do
    ITER_DIR="${OUT_BASE}/iter-${i}"
    mkdir -p "$ITER_DIR"

    echo
    echo "=============================================="
    echo "iter ${i}/${ITERATIONS}  ($(date -u +%FT%TZ))"
    echo "=============================================="

    ITER_START_EPOCH=$(date +%s)
    ITER_START=$(date -u +%FT%TZ)

    loop_stop_vm
    echo "[*] revert qcow to snapshot '${SNAP_NAME}'"
    if ! loop_revert_snapshot "$QCOW" "$SNAP_NAME"; then
        echo "[!] snapshot revert failed; aborting" >&2
        break
    fi

    echo "[*] booting VM"
    "${REPO_ROOT}/scripts/run-local-cysvuln.sh" "$QCOW"

    echo "[*] gating on WinRM + agent active"
    WAZUH_AGENT_IP="$AGENT_IP" \
        "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 240 || true

    # First-iter flag sniff when --skip-rebuild: the QCOW carries flags
    # from whatever earlier build baked it, so the scorecard grep needs
    # those exact tokens, not freshly generated ones.
    if [ "$i" = "1" ] && [ -z "$SECRETCON_USER_FLAG" ]; then
        echo "[*] sniffing baked flag tokens from running VM"
        FLAG_SNIFF="${OUT_BASE}/flags.env"
        python3 - "$WINRM_PORT" "$ADMIN_PW" "$FLAG_SNIFF" "$RUN_ID" <<'PY' || true
import sys, winrm
port, pw, out, run_id = sys.argv[1:5]
s = winrm.Session(f"http://127.0.0.1:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
def read(p):
    r = s.run_ps(f"Get-Content '{p}' -Raw -EA SilentlyContinue")
    return (r.std_out or b"").decode(errors="replace").strip()
user = read(r"C:\Users\User_Joe\Desktop\user.txt")
root = read(r"C:\Users\Administrator\Desktop\root.txt")
with open(out, "w") as fh:
    fh.write(f"# Sniffed from baked QCOW at {run_id}\n")
    fh.write(f"SECRETCON_USER_FLAG={user}\n")
    fh.write(f"SECRETCON_ROOT_FLAG={root}\n")
    fh.write(f"SECRETCON_RUN_ID={run_id}\n")
print(f"user={user!r}")
print(f"root={root!r}")
PY
        if [ -f "$FLAG_SNIFF" ]; then
            # shellcheck disable=SC1090
            . "$FLAG_SNIFF"
            export SECRETCON_USER_FLAG SECRETCON_ROOT_FLAG
            echo "    user: ${SECRETCON_USER_FLAG}"
            echo "    root: ${SECRETCON_ROOT_FLAG}"
        fi
    fi

    # Walkthrough phases (mirrors run-baseline-tour.sh, plus a 04a/04b
    # split so the CTF gap between callback and exec paths is visible).
    run_phase "$i" 00 noise sleep "$NOISE_S"

    run_phase "$i" 03 smoke env WINRM_PORT="$WINRM_PORT" \
        "${REPO_ROOT}/scripts/verify-cysvuln.sh" 127.0.0.1

    # 04a (callback) needs --lhost and a reachable listener. QEMU user-net
    # cannot route guest->host without portfwd, so the callback path is
    # effectively unreachable in this lab; only try it when CB_LHOST is
    # explicitly set. Otherwise mark it skipped and capture the CTF gap.
    if [ -n "${CB_LHOST:-}" ]; then
        run_phase "$i" 04a foothold-callback python3 "${REPO_ROOT}/scripts/validate/check_efs69_response.py" \
            --target 127.0.0.1 --port 18080 --service-port 80 \
            --mode callback --lhost "$CB_LHOST" --cmd whoami
    else
        echo "  >> phase 04a (foothold-callback): SKIPPED (CB_LHOST not set; callback unreachable on QEMU user-net)"
        mkdir -p "${ITER_DIR}/phase-04a-foothold-callback"
        cat > "${ITER_DIR}/phase-04a-foothold-callback/summary.json" <<JSON
{"phase_id":"04a","phase_name":"foothold-callback","skipped":true,"reason":"CB_LHOST not set; callback unreachable on QEMU user-net (CTF gap noted)","alert_count":0,"exit_code":-1}
JSON
    fi

    # 04b is the deterministic exec path that runs every iter. The CTF
    # callback gap is documented separately and tracked via the 04a skip.
    run_phase "$i" 04b foothold-exec python3 "${REPO_ROOT}/scripts/validate/check_efs69_response.py" \
        --target 127.0.0.1 --port 18080 --service-port 80 --mode exec --cmd whoami

    run_phase "$i" 05 user-flag "${REPO_ROOT}/scripts/lib/read_flag.sh" user 127.0.0.1

    run_phase "$i" 06 aie-audit python3 "${REPO_ROOT}/scripts/validate/audit_aie.py" \
        --target 127.0.0.1 --port "$WINRM_PORT" \
        --user "$ADMIN_USER" --password "$ADMIN_PW" --profile-user "$JOE_USER" \
        --out-json

    run_phase "$i" 06a winpeas "${REPO_ROOT}/scripts/run-winpeas.sh" 127.0.0.1

    run_phase "$i" 06b sharpup "${REPO_ROOT}/scripts/run-sharpup.sh" 127.0.0.1

    run_phase "$i" 07 privesc "${REPO_ROOT}/scripts/validate-cysvuln-aie-joe.sh" 127.0.0.1

    run_phase "$i" 08 root-flag "${REPO_ROOT}/scripts/lib/read_flag.sh" root 127.0.0.1

    iter_red_scorecard "$i"
    iter_blue_scorecard "$i"

    ITER_END_EPOCH=$(date +%s)
    ITER_END=$(date -u +%FT%TZ)
    WALL_S=$((ITER_END_EPOCH - ITER_START_EPOCH))

    # Push iter scorecard rows into the campaign summary CSV.
    red="${ITER_DIR}/red-scorecard.json"
    blue="${ITER_DIR}/blue-scorecard.json"
    row=$(python3 - "$i" "$ITER_START" "$ITER_END" "$WALL_S" "$red" "$blue" <<'PY'
import json, sys
i, start, end, wall, red_p, blue_p = sys.argv[1:7]
red = json.load(open(red_p)); blue = json.load(open(blue_p))
b = lambda v: "true" if v else "false"
cols = [
    i, start, end, wall,
    b(red["user_flag_recovered"]),
    b(red["root_flag_recovered"]),
    b(red["both_flags_recovered"]),
    b(red["foothold_as_joe"]),
    b(red["aie_chain_expected"]),
    str(blue["total_alerts"]),
    b(blue["fired_100507_efs_crash"]),
    b(blue["fired_100508_winpeas"]),
    b(blue["fired_100509_sharpup"]),
    b(blue["fired_100510_aie_msiexec"]),
    b(blue["fired_100512_system_child"]),
    b(blue["fired_100520_user_flag_access"]),
    b(blue["fired_100530_enum_to_aie"]),
    '"' + blue["secretcon_rule_ids"].replace('"', "'") + '"',
]
print(",".join(cols))
PY
)
    echo "$row" >> "$CAMPAIGN_CSV"

    echo "[*] iter ${i} wall=${WALL_S}s; stopping VM"
    loop_stop_vm
done

trap - EXIT

###############################################################################
# Aggregate
###############################################################################

echo
echo "[aggregate] variance-notes.md"
python3 - "$CAMPAIGN_CSV" "${OUT_BASE}/variance-notes.md" <<'PY'
import csv, statistics, sys
csv_path, out_path = sys.argv[1:3]
rows = list(csv.DictReader(open(csv_path)))
if not rows:
    open(out_path, "w").write("No iterations completed.\n")
    sys.exit(0)
def pct(col):
    n = sum(1 for r in rows if r[col].lower() == "true")
    return f"{n}/{len(rows)} ({100*n/len(rows):.0f}%)"
alerts = [int(r["total_alerts"]) for r in rows if r["total_alerts"].isdigit()]
wall = [int(r["wall_s"]) for r in rows if r["wall_s"].isdigit()]
md = ["# Campaign variance notes\n",
      f"- iterations: {len(rows)}\n",
      f"- both flags recovered: {pct('both_flags')}\n",
      f"- user flag only: {pct('user_flag')}\n",
      f"- root flag only: {pct('root_flag')}\n",
      f"- foothold as User_Joe: {pct('foothold_joe')}\n",
      f"- AIE chain pre-condition met: {pct('aie_expected')}\n",
      "\n## SecretCon rule fire rate\n"]
for col, label in [
    ("r100507", "100507 EFS crash"),
    ("r100508", "100508 winPEAS exec (or chained 100530)"),
    ("r100509", "100509 SharpUp exec (or chained 100530)"),
    ("r100510", "100510 msiexec /quiet /i"),
    ("r100512", "100512 SYSTEM child of msiexec"),
    ("r100520", "100520 user.txt access"),
    ("r100530", "100530 enum -> AIE correlation"),
]:
    md.append(f"- {label}: {pct(col)}\n")
if alerts:
    md.append(f"\n## Alert volume\n- mean: {statistics.mean(alerts):.1f}\n- stdev: {statistics.pstdev(alerts):.1f}\n- min/max: {min(alerts)}/{max(alerts)}\n")
if wall:
    md.append(f"\n## Wall clock per iteration\n- mean: {statistics.mean(wall):.1f}s\n- stdev: {statistics.pstdev(wall):.1f}s\n- min/max: {min(wall)}s/{max(wall)}s\n")
open(out_path, "w").write("".join(md))
PY

echo
echo "================================================="
echo "Stress campaign complete"
echo "  run-id   : ${RUN_ID}"
echo "  out-dir  : ${OUT_BASE}"
echo "  summary  : ${CAMPAIGN_CSV}"
echo "  variance : ${OUT_BASE}/variance-notes.md"
echo "  next     : ./scripts/wazuh-export-dataset.sh --run-id ${RUN_ID} --tarball"
echo "================================================="
