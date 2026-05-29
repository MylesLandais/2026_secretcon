#!/usr/bin/env bash
# Top-level driver for "EWS prod reproduction": run the full chain
# end-to-end against the live Proxmox lab over WireGuard.
#
# Steps (each one writes evidence into the same RUN_ID dir):
#   1. preflight       -> preflight.txt
#   2. probe EWS       -> ews-probe.txt        (drift detector)
#   3. rebuild EWS     -> rebuild-ews.log      (only when probe failed
#                                                or --rebuild was passed)
#   4. sync Wazuh rules + wazuh-logtest smoke for 100806
#   5. (optional) enable :514 replay listener  (--enable-replay)
#   6. deploy Arkime VMID 111                  (skipped with --skip-arkime
#                                                or if verify-arkime already
#                                                green and --no-redeploy)
#   7. verify Arkime VMID 111
#   8. live adversary emulation against EWS
#   9. verify_wazuh_path  -> recovered-from-wazuh.txt == FELDTECH_VNC
#  10. verify_arkime_path -> recovered-from-pcap.txt  == FELDTECH_VNC
#  11. (optional) replay path
#  12. final summary -> summary.json + INDEX.md
#
# Usage:
#   ./scripts/proxmox/reproduce-ews-prod-proof.sh \
#       [--run-id ID] [--rebuild] [--enable-replay] \
#       [--skip-arkime] [--skip-rebuild] [--no-emulation] \
#       [--target-ews IP] [--capture-iface IF]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID=""
FORCE_REBUILD=0
SKIP_REBUILD=0
ENABLE_REPLAY=0
SKIP_ARKIME=0
NO_REDEPLOY_ARKIME=1   # default: don't redeploy if verify-arkime is green
FORCE_REDEPLOY_ARKIME=0
NO_EMULATION=0
TARGET_EWS_CLI=""
CAPTURE_IFACE_CLI=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)         RUN_ID="$2"; shift 2 ;;
        --rebuild)        FORCE_REBUILD=1; shift ;;
        --skip-rebuild)   SKIP_REBUILD=1; shift ;;
        --enable-replay)  ENABLE_REPLAY=1; shift ;;
        --skip-arkime)    SKIP_ARKIME=1; shift ;;
        --redeploy-arkime) FORCE_REDEPLOY_ARKIME=1; shift ;;
        --no-emulation)   NO_EMULATION=1; shift ;;
        --target-ews)     TARGET_EWS_CLI="$2"; shift 2 ;;
        --capture-iface)  CAPTURE_IFACE_CLI="$2"; shift 2 ;;
        -h|--help)        sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -f .env ]]; then
    while IFS='=' read -r k v; do
        [[ -z "${k}" || "${k}" =~ ^# ]] && continue
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        if [[ -z "${!k:-}" ]]; then
            export "${k}=${v}"
        fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env || true)
fi

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="ews-prod-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/prod-proof-${RUN_ID}"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/orchestrator.log"
exec > >(tee -a "${LOG}") 2>&1

EWS_HOST="${TARGET_EWS_CLI:-${EWS_HOST:-192.168.61.20}}"
ARKIME_HOST="${ARKIME_HOST:-192.168.61.11}"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
CAPTURE_IFACE="${CAPTURE_IFACE_CLI:-${EWS_PROD_CAPTURE_IFACE:-wg-ctf}}"
WORDLIST="${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt"
CRED_TOOL="${REPO_ROOT}/scripts/observability/vnc-cred-tool.py"

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"
SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"

# Marker file so the live adversary-emulation block can find its output
# subdir without re-deriving the path.
EMU_OUT_DIR=""

banner() {
    printf '\n=========================================================\n'
    printf '  %s\n' "$*"
    printf '=========================================================\n'
}

require_pmx_creds() {
    : "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
    [[ -n "${SSHPASS_BIN}" ]] || { echo "[!] sshpass not on PATH" >&2; exit 1; }
}

waz_ssh() {
    # ssh into the production manager (used here for the wazuh-logtest smoke test)
    require_pmx_creds
    local proxy="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"
    ssh -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes \
        -i "${SSH_KEY}" \
        -o "ProxyCommand=${proxy}" \
        "${WAZUH_MANAGER_USER:-dadmin}@${WAZUH_MANAGER_HOST}" "$@"
}

waz_ssh_stdin() {
    # Like waz_ssh but feeds stdin to `bash -s` on the manager so piped
    # commands work (e.g. printf line | sudo wazuh-logtest -l "...").
    require_pmx_creds
    local proxy="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"
    ssh -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes \
        -i "${SSH_KEY}" \
        -o "ProxyCommand=${proxy}" \
        "${WAZUH_MANAGER_USER:-dadmin}@${WAZUH_MANAGER_HOST}" "bash -s"
}

# Aggregate step results into summary.json
SUMMARY="${OUT_DIR}/summary.json"
declare -A STEP_RC
record_step() {
    STEP_RC["$1"]="$2"
}

# ---------------------------------------------------------- 1. preflight
banner "1/12  preflight"
set +e
"${REPO_ROOT}/scripts/proxmox/preflight-ews-prod.sh" --run-id "${RUN_ID}"
RC_PRE=$?
set -e
record_step preflight "${RC_PRE}"
if [[ "${RC_PRE}" -ne 0 ]]; then
    echo "[!] preflight failed -- aborting" >&2
    exit 1
fi

# ---------------------------------------------------------- 2. probe EWS
banner "2/12  probe-ews"
set +e
"${REPO_ROOT}/scripts/proxmox/probe-ews.sh" --run-id "${RUN_ID}" --target "${EWS_HOST}"
RC_PROBE=$?
set -e
record_step probe_ews "${RC_PROBE}"

# ---------------------------------------------------------- 3. converge / rebuild EWS
banner "3/12  converge-ews (conditional)"
if [[ "${SKIP_REBUILD}" -eq 1 ]]; then
    echo "[i] --skip-rebuild: bypassing converge and rebuild even if drift detected"
    record_step converge_ews 0
    record_step rebuild_ews 0
elif [[ "${FORCE_REBUILD}" -eq 1 ]]; then
    echo "[*] --rebuild: skipping Ansible converge; forced Packer rebuild"
    record_step converge_ews 0
    banner "3b/12  rebuild-ews (forced)"
    set +e
    "${REPO_ROOT}/scripts/proxmox/rebuild-ews.sh" --run-id "${RUN_ID}" --ews-host "${EWS_HOST}"
    RC_REBUILD=$?
    set -e
    record_step rebuild_ews "${RC_REBUILD}"
    if [[ "${RC_REBUILD}" -ne 0 ]]; then
        echo "[!] rebuild failed -- aborting" >&2
        exit 1
    fi
elif [[ "${RC_PROBE}" -ne 0 ]]; then
    echo "[*] probe-ews detected drift -- Ansible converge (no Packer unless this fails)"
    set +e
    "${REPO_ROOT}/scripts/proxmox/discover-proxmox-inventory.sh" || true
    DISC="${REPO_ROOT}/ansible/inventory/proxmox.discovered.yml"
    if [[ -f "${DISC}" ]]; then
        BRIDGE="$(grep 'proxmox_bridge:' "${DISC}" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
        if [[ "${BRIDGE}" == "vmbr0" ]]; then
            echo "[*] EWS still on vmbr0 -- moving to campaign bridge"
            "${REPO_ROOT}/scripts/proxmox/move-ews-bridge.sh" --ews-host "${EWS_HOST}" || true
            "${REPO_ROOT}/scripts/proxmox/discover-proxmox-inventory.sh" || true
        fi
    fi
    "${REPO_ROOT}/scripts/proxmox/converge-ews.sh" --ews-host "${EWS_HOST}" --no-discover
    RC_CONVERGE=$?
    set -e
    record_step converge_ews "${RC_CONVERGE}"
    if [[ "${RC_CONVERGE}" -ne 0 ]]; then
        echo "[!] converge-ews failed -- aborting (use --rebuild for Packer path)" >&2
        exit 1
    fi
    banner "3b/12  re-probe after converge"
    set +e
    "${REPO_ROOT}/scripts/proxmox/probe-ews.sh" --run-id "${RUN_ID}" --target "${EWS_HOST}" --quiet
    RC_PROBE2=$?
    set -e
    if [[ "${RC_PROBE2}" -ne 0 ]]; then
        echo "[!] still drifted after converge -- run rebuild-ews.sh manually or pass --rebuild" >&2
        record_step rebuild_ews 1
        exit 1
    fi
    echo "[+] converge cleared drift"
    record_step rebuild_ews 0
else
    echo "[+] probe-ews PASSED (drift-free) -- skipping converge"
    record_step converge_ews 0
    record_step rebuild_ews 0
fi

# ---------------------------------------------------------- 4. sync rules + logtest
banner "4/12  sync-wazuh-rules + wazuh-logtest smoke"
set +e
"${REPO_ROOT}/scripts/proxmox/sync-wazuh-rules.sh" \
    2>&1 | tee "${OUT_DIR}/sync-wazuh-rules.log"
RC_SYNC=${PIPESTATUS[0]}
set -e
record_step sync_rules "${RC_SYNC}"
if [[ "${RC_SYNC}" -ne 0 ]]; then
    echo "[!] sync-wazuh-rules failed -- aborting before destructive emulation" >&2
    exit 1
fi

# Smoke test: feed a synthetic blob into wazuh-logtest on the live
# manager and assert rule 100806 fires. This is exactly the proof
# scripts/observability/vnc-wazuh-proof.sh runs locally, but here
# we run it against the production manager via ssh stdin.
set +e
waz_ssh_stdin > "${OUT_DIR}/prod-wazuh-logtest.txt" 2>&1 <<'REMOTE'
LINE="[$(date -u +%FT%TZ)] VNC password blob (hex): 01-02-03-04-05-06-07-08 (source=HKLM:\\SOFTWARE\\ORL\\WinVNC3, host=ews01, user=patrick)"
LOC="C:\\Users\\Public\\vnc-pwd-dump.txt"
printf "%s\n" "$LINE" | sudo /var/ossec/bin/wazuh-logtest -l "$LOC"
REMOTE
RC_LOGTEST=$?
set -e
if grep -qE 'id: .*100806' "${OUT_DIR}/prod-wazuh-logtest.txt"; then
    echo "[+] wazuh-logtest matched rule 100806 on production manager"
    record_step rule_100806_loaded 0
else
    echo "[!] wazuh-logtest did NOT match rule 100806 on production manager (rc=${RC_LOGTEST})" >&2
    echo "    see ${OUT_DIR}/prod-wazuh-logtest.txt" >&2
    record_step rule_100806_loaded 1
    exit 1
fi

# ---------------------------------------------------------- 5. replay listener
if [[ "${ENABLE_REPLAY}" -eq 1 ]]; then
    banner "5/12  enable-wazuh-replay-listener (--enable-replay)"
    set +e
    "${REPO_ROOT}/scripts/proxmox/enable-wazuh-replay-listener.sh" \
        2>&1 | tee "${OUT_DIR}/enable-replay-listener.log"
    RC_REPLAY=${PIPESTATUS[0]}
    set -e
    record_step enable_replay "${RC_REPLAY}"
    if [[ "${RC_REPLAY}" -ne 0 ]]; then
        echo "[!] enable-replay failed; continuing without replay path" >&2
    fi
else
    banner "5/12  replay listener (skipped, no --enable-replay)"
    record_step enable_replay 0
fi

# ---------------------------------------------------------- 6+7. Arkime deploy / verify
banner "6+7/12  Arkime crit-capture deploy + verify"
if [[ "${SKIP_ARKIME}" -eq 1 ]]; then
    echo "[i] --skip-arkime: assuming VMID 111 is already deployed and healthy"
    record_step deploy_arkime 0
    set +e
    "${REPO_ROOT}/scripts/proxmox/verify-arkime-capture.sh" --run-id "${RUN_ID}" --host "${ARKIME_HOST}"
    RC_VARK=$?
    set -e
    record_step verify_arkime "${RC_VARK}"
else
    # First probe whether it's already there + green.
    set +e
    "${REPO_ROOT}/scripts/proxmox/verify-arkime-capture.sh" --run-id "${RUN_ID}" --host "${ARKIME_HOST}" >"${OUT_DIR}/verify-arkime-precheck.txt" 2>&1
    RC_PRECHECK=$?
    set -e
    if [[ "${RC_PRECHECK}" -eq 0 ]] && [[ "${FORCE_REDEPLOY_ARKIME}" -eq 0 ]]; then
        echo "[+] Arkime already healthy; skipping redeploy (pass --redeploy-arkime to force)"
        record_step deploy_arkime 0
        record_step verify_arkime 0
        cp -f "${OUT_DIR}/verify-arkime-precheck.txt" "${OUT_DIR}/verify-arkime.txt"
    else
        echo "[*] Arkime not healthy or --redeploy-arkime set; deploying VMID 111"
        set +e
        "${REPO_ROOT}/scripts/proxmox/deploy-arkime-capture.sh" --run-id "${RUN_ID}"
        RC_DARK=$?
        set -e
        record_step deploy_arkime "${RC_DARK}"
        if [[ "${RC_DARK}" -ne 0 ]]; then
            echo "[!] deploy-arkime failed -- aborting" >&2
            exit 1
        fi
        set +e
        "${REPO_ROOT}/scripts/proxmox/verify-arkime-capture.sh" --run-id "${RUN_ID}" --host "${ARKIME_HOST}"
        RC_VARK=$?
        set -e
        record_step verify_arkime "${RC_VARK}"
        if [[ "${RC_VARK}" -ne 0 ]]; then
            echo "[!] verify-arkime failed after deploy -- aborting" >&2
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------- 8. live adversary emulation
if [[ "${NO_EMULATION}" -eq 1 ]]; then
    banner "8/12  live adversary emulation (skipped, --no-emulation)"
    record_step emulation 0
else
    banner "8/12  live adversary emulation against ${EWS_HOST}"
    EMU_RUN_ID="emu-${RUN_ID}"
    EMU_OUT_DIR="${REPO_ROOT}/artifacts/ews/vnc-foothold/${EMU_RUN_ID}"
    set +e
    "${REPO_ROOT}/scripts/observability/vnc-adversary-emulation.sh" \
        --target "${EWS_HOST}" \
        --vnc-port 5900 \
        --winrm-port 5985 \
        --capture-iface "${CAPTURE_IFACE}" \
        --wordlist "${WORDLIST}" \
        --run-id "${EMU_RUN_ID}" \
        --skip-arkime    # we use the prod stack on VMID 111, not the local docker one
    RC_EMU=$?
    set -e
    record_step emulation "${RC_EMU}"
    if [[ "${RC_EMU}" -ne 0 ]]; then
        echo "[!] adversary emulation exited ${RC_EMU}; continuing to verify what we got" >&2
    fi
    # Mirror canonical artefacts into prod-proof-<RUN_ID>/
    if [[ -f "${EMU_OUT_DIR}/vnc_auth.pcap" ]]; then
        cp -f "${EMU_OUT_DIR}/vnc_auth.pcap" "${OUT_DIR}/vnc_auth.pcap"
    fi
    if [[ -d "${EMU_OUT_DIR}/dataset" ]]; then
        cp -a "${EMU_OUT_DIR}/dataset" "${OUT_DIR}/dataset"
    fi
fi

# ---------------------------------------------------------- 9. verify Wazuh path
banner "9/12  verify Wazuh path (recover password from live alerts.json)"
ALERTS_JSON="${OUT_DIR}/dataset/alerts/alerts.json"
WAZUH_OK=0
if [[ -s "${ALERTS_JSON}" ]]; then
    jq -c 'select(.rule.id == "100806")' "${ALERTS_JSON}" \
        > "${OUT_DIR}/prod-wazuh-alert.json" 2>/dev/null || true
    if [[ -s "${OUT_DIR}/prod-wazuh-alert.json" ]]; then
        # Take the first matching line + extract the hex blob.
        HEX_BLOB="$(head -n1 "${OUT_DIR}/prod-wazuh-alert.json" \
            | jq -r '.full_log' 2>/dev/null \
            | grep -oE '([0-9A-Fa-f]{2}-){7}[0-9A-Fa-f]{2}' \
            | head -n1)"
        if [[ -n "${HEX_BLOB}" ]]; then
            echo "[*] extracted blob: ${HEX_BLOB}"
            set +e
            RECOVERED="$(python3 "${CRED_TOOL}" decode \
                --hex "${HEX_BLOB}" \
                --wordlist "${WORDLIST}" 2>"${OUT_DIR}/wazuh-decode.err")"
            RC_DEC=$?
            set -e
            printf '%s\n' "${RECOVERED}" > "${OUT_DIR}/recovered-from-wazuh.txt"
            if [[ "${RC_DEC}" -eq 0 ]] && [[ "${RECOVERED}" == "FELDTECH_VNC" ]]; then
                echo "[+] Wazuh path: recovered password = ${RECOVERED}"
                WAZUH_OK=1
            else
                echo "[!] Wazuh path: decode produced '${RECOVERED}' (rc=${RC_DEC})" >&2
            fi
        else
            echo "[!] Wazuh path: rule 100806 alert had no 8-byte hex blob in full_log" >&2
        fi
    else
        echo "[!] Wazuh path: no rule 100806 entries in ${ALERTS_JSON}" >&2
    fi
else
    echo "[!] Wazuh path: alerts.json missing or empty (${ALERTS_JSON})" >&2
fi
record_step verify_wazuh_path "$([[ "${WAZUH_OK}" -eq 1 ]] && echo 0 || echo 1)"

# ---------------------------------------------------------- 10. verify Arkime path
banner "10/12  verify Arkime path (recover password from live PCAP)"
PCAP="${OUT_DIR}/vnc_auth.pcap"
ARKIME_OK=0
if [[ -s "${PCAP}" ]]; then
    if [[ "${SKIP_ARKIME}" -eq 0 ]] || timeout 3 bash -c "</dev/tcp/${ARKIME_HOST}/8005" 2>/dev/null; then
        set +e
        "${REPO_ROOT}/scripts/proxmox/sync-arkime-pcap.sh" \
            --run-id "${RUN_ID}" \
            --host "${ARKIME_HOST}" \
            --tag "ews-prod-${RUN_ID}" \
            "${PCAP}"
        RC_SYNCP=$?
        set -e
        record_step sync_arkime_pcap "${RC_SYNCP}"

        # Session count + first-session dump
        curl -sf --max-time 10 \
            "http://${ARKIME_HOST}:9201/arkime_sessions3-*/_count?q=destination.port:5900" \
            > "${OUT_DIR}/prod-arkime-session-count.json" 2>/dev/null || true
        curl -sf --max-time 10 \
            "http://${ARKIME_HOST}:9201/arkime_sessions3-*/_search?q=destination.port:5900&size=1&pretty" \
            > "${OUT_DIR}/prod-arkime-session.json" 2>/dev/null || true
        SESS_COUNT="$(jq -r '.count // 0' "${OUT_DIR}/prod-arkime-session-count.json" 2>/dev/null || echo 0)"
        echo "[*] Arkime sessions with destination.port:5900 = ${SESS_COUNT}"
    else
        echo "[i] Arkime host unreachable; skipping VMID 111 import"
    fi

    # tshark extraction + offline crack. RFB emits challenge and response
    # in separate VNC layer events (one per packet), so they typically
    # appear on DIFFERENT rows in the tshark fields output. We pick the
    # first non-empty of each column independently.
    set +e
    tshark -r "${PCAP}" -d tcp.port==5900,vnc -Y "vnc" \
        -T fields -e vnc.auth_challenge -e vnc.auth_response \
        > "${OUT_DIR}/prod-tshark-fields.txt" 2>"${OUT_DIR}/prod-tshark.err"
    set -e
    challenge_hex="$(awk -F'\t' 'NF >= 1 && $1 != "" {print $1; exit}' \
        "${OUT_DIR}/prod-tshark-fields.txt" | tr -d ':')"
    response_hex="$(awk -F'\t' 'NF >= 2 && $2 != "" {print $2; exit}' \
        "${OUT_DIR}/prod-tshark-fields.txt" | tr -d ':')"
    if [[ -n "${challenge_hex}" && -n "${response_hex}" ]]; then
        set +e
        RECOVERED="$(python3 "${CRED_TOOL}" crack \
            --challenge "${challenge_hex}" \
            --response  "${response_hex}" \
            --wordlist  "${WORDLIST}" 2>"${OUT_DIR}/pcap-crack.err")"
        RC_CRACK=$?
        set -e
        printf '%s\n' "${RECOVERED}" > "${OUT_DIR}/recovered-from-pcap.txt"
        if [[ "${RC_CRACK}" -eq 0 ]] && [[ "${RECOVERED}" == "FELDTECH_VNC" ]]; then
            echo "[+] Arkime/PCAP path: recovered password = ${RECOVERED}"
            ARKIME_OK=1
        else
            echo "[!] Arkime/PCAP path: crack produced '${RECOVERED}' (rc=${RC_CRACK})" >&2
        fi
    else
        echo "[!] Arkime/PCAP path: tshark did not extract challenge=${challenge_hex:-(empty)} response=${response_hex:-(empty)}" >&2
    fi
else
    echo "[!] Arkime path: no PCAP at ${PCAP}" >&2
fi
record_step verify_arkime_path "$([[ "${ARKIME_OK}" -eq 1 ]] && echo 0 || echo 1)"

# ---------------------------------------------------------- 11. replay path
if [[ "${ENABLE_REPLAY}" -eq 1 ]]; then
    banner "11/12  verify replay path (--enable-replay)"
    if [[ -d "${OUT_DIR}/dataset" ]]; then
        set +e
        "${REPO_ROOT}/scripts/observability/vnc-replay-on-deploy.sh" \
            --dataset "${OUT_DIR}/dataset" \
            --target  "${WAZUH_MANAGER_HOST}:514" \
            2>&1 | tee "${OUT_DIR}/replay-on-deploy.log"
        RC_REPLAY_RUN=${PIPESTATUS[0]}
        set -e
        record_step verify_replay_path "${RC_REPLAY_RUN}"
    else
        echo "[!] no dataset available; replay path skipped"
        record_step verify_replay_path 1
    fi
else
    banner "11/12  replay path (skipped)"
    record_step verify_replay_path 0
fi

# ---------------------------------------------------------- 12. summary
banner "12/12  summary"

# Build summary.json. Keep it pure JSON so downstream tooling can parse.
python3 - "${SUMMARY}" "${RUN_ID}" <<PY
import json, os, sys
out_path = sys.argv[1]
run_id   = sys.argv[2]
rc = ${#STEP_RC[@]}
data = {
    "run_id": run_id,
    "exported_at_utc": __import__('datetime').datetime.utcnow().isoformat() + 'Z',
    "ews_host": "${EWS_HOST}",
    "wazuh_manager_host": "${WAZUH_MANAGER_HOST}",
    "arkime_host": "${ARKIME_HOST}",
    "enable_replay": ${ENABLE_REPLAY},
    "force_rebuild": ${FORCE_REBUILD},
    "skip_arkime":   ${SKIP_ARKIME},
    "steps": {
$(for k in "${!STEP_RC[@]}"; do printf '        "%s": %s,\n' "$k" "${STEP_RC[$k]}"; done)
    },
}
with open(out_path, "w") as f:
    json.dump(data, f, indent=2)
print("wrote", out_path)
PY

# INDEX.md: human-readable evidence pack
INDEX="${OUT_DIR}/INDEX.md"
{
    echo "# EWS prod-reproduction evidence pack"
    echo
    echo "- run_id : \`${RUN_ID}\`"
    echo "- exported_at_utc : $(date -u +%FT%TZ)"
    echo "- ews_host : \`${EWS_HOST}\`"
    echo "- wazuh_manager_host : \`${WAZUH_MANAGER_HOST}\`"
    echo "- arkime_host : \`${ARKIME_HOST}\`"
    echo
    echo "## Step results"
    echo
    echo "| step | rc |"
    echo "| --- | --- |"
    for k in preflight probe_ews rebuild_ews sync_rules rule_100806_loaded \
             enable_replay deploy_arkime verify_arkime emulation \
             sync_arkime_pcap verify_wazuh_path verify_arkime_path \
             verify_replay_path; do
        v="${STEP_RC[$k]:-skipped}"
        echo "| ${k} | ${v} |"
    done
    echo
    echo "## Key artefacts"
    echo
    for f in preflight.txt ews-probe.txt rebuild-ews.log sync-wazuh-rules.log \
             prod-wazuh-logtest.txt enable-replay-listener.log \
             deploy-arkime-summary.txt verify-arkime.txt \
             vnc_auth.pcap dataset/alerts/alerts.json \
             prod-wazuh-alert.json recovered-from-wazuh.txt \
             prod-arkime-session-count.json prod-arkime-session.json \
             prod-tshark-fields.txt recovered-from-pcap.txt \
             replay-on-deploy.log summary.json; do
        if [[ -e "${OUT_DIR}/${f}" ]]; then
            size="$(du -h "${OUT_DIR}/${f}" 2>/dev/null | awk '{print $1}')"
            echo "- \`${f}\` (${size})"
        fi
    done
    echo
    echo "## Quick verifications"
    echo
    echo '```bash'
    echo "diff <(echo FELDTECH_VNC) ${OUT_DIR}/recovered-from-wazuh.txt && echo 'WAZUH path OK'"
    echo "diff <(echo FELDTECH_VNC) ${OUT_DIR}/recovered-from-pcap.txt  && echo 'ARKIME path OK'"
    echo '```'
} > "${INDEX}"

echo
echo "[+] Evidence pack written to: ${OUT_DIR}"
echo "    INDEX: ${INDEX}"
echo "    SUMMARY: ${SUMMARY}"

# Final overall exit: 0 only if BOTH verification paths succeeded.
if [[ "${WAZUH_OK}" -eq 1 ]] && [[ "${ARKIME_OK}" -eq 1 ]]; then
    echo "[+] Both proof paths green."
    exit 0
fi
echo "[!] At least one proof path did not recover FELDTECH_VNC." >&2
exit 1
