#!/usr/bin/env bash
# End-to-end orchestrator for the OPNsense VNC brute-force analyst
# challenge.
#
# Runs the full pipeline in one shot:
#   1. Preflight: vmbr1 tc-mirror up, OPNsense reachable + Suricata
#      service running, Wazuh manager reachable + listening on :1514,
#      crit-capture Arkime VM healthy.
#   2. Start an OPNsense packet capture on the MIRROR interface
#      (scripts/proxmox/opnsense-export-pcap.sh, BG-bounded).
#   3. Run the existing live VNC brute force against EWS .20:5900
#      (scripts/observability/vnc-adversary-emulation.sh, --skip-arkime
#      because Arkime ingestion happens through the OPNsense pcap, not
#      the operator-workstation tcpdump).
#   4. Stop / download the OPNsense pcap and push to crit-capture Arkime.
#   5. Pull a manager-side alerts.json slice over the run window,
#      jq-filter to the NSM + endpoint rule IDs for this challenge.
#   6. Write artifacts/opnsense-vnc/<run-id>/INDEX.md (participant
#      facing) and summary.json (machine readable).
#   7. Optionally invoke scripts/validate/validate-opnsense-vnc-pipeline.sh
#      (--validate; default off so the orchestrator can be used to
#      generate datasets without the strict assertions).
#
# Usage:
#   ./scripts/observability/opnsense-vnc-challenge.sh
#   ./scripts/observability/opnsense-vnc-challenge.sh --validate
#   ./scripts/observability/opnsense-vnc-challenge.sh --run-id my-run
#   ./scripts/observability/opnsense-vnc-challenge.sh --target 192.168.61.20 --vnc-port 5900
#   ./scripts/observability/opnsense-vnc-challenge.sh --no-emulation     # capture only
#
# Required env (.env auto-sourced):
#   PROXMOX_HOST, PROXMOX_PASSWORD
#   OPNSENSE_SSH_PASSWORD     (used by opnsense-export-pcap.sh)
#   ADMIN_PW                  (or --admin-pass; EWS Administrator pw for WinRM payload)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

RUN_ID=""
TARGET="${EWS_HOST:-192.168.61.20}"
VNC_PORT="5900"
WINRM_PORT="5985"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PW="${ADMIN_PW:-packer}"
WORDLIST=""
DURATION=180
MAX_PACKETS=50000
DO_VALIDATE=0
NO_EMULATION=0
SKIP_PREFLIGHT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id)        RUN_ID="$2"; shift 2 ;;
        --target)        TARGET="$2"; shift 2 ;;
        --vnc-port)      VNC_PORT="$2"; shift 2 ;;
        --winrm-port)    WINRM_PORT="$2"; shift 2 ;;
        --admin-user)    ADMIN_USER="$2"; shift 2 ;;
        --admin-pass)    ADMIN_PW="$2"; shift 2 ;;
        --wordlist)      WORDLIST="$2"; shift 2 ;;
        --duration)      DURATION="$2"; shift 2 ;;
        --max-packets)   MAX_PACKETS="$2"; shift 2 ;;
        --validate)      DO_VALIDATE=1; shift ;;
        --no-emulation)  NO_EMULATION=1; shift ;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
        -h|--help)       sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "${RUN_ID}" ]; then
    RUN_ID="opnsense-vnc-$(date -u +%Y%m%dT%H%M%SZ)"
fi

OUT_DIR="${REPO_ROOT}/artifacts/opnsense-vnc/${RUN_ID}"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/orchestrator.log"
exec > >(tee -a "${LOG}") 2>&1

step() { printf '\n[*] %s\n' "$*"; }

# Default wordlist resolution mirrors vnc-adversary-emulation.sh.
if [ -z "${WORDLIST}" ]; then
    for candidate in \
        "${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt" \
        /usr/share/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
        /usr/share/wordlists/SecLists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
        "${HOME}/SecLists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt"; do
        if [ -f "$candidate" ]; then WORDLIST="$candidate"; break; fi
    done
fi
[ -f "${WORDLIST}" ] || { echo "[!] could not locate VNC wordlist; pass --wordlist" >&2; exit 2; }

step "OPNsense VNC analyst-challenge orchestrator"
echo "    run_id    : ${RUN_ID}"
echo "    out_dir   : ${OUT_DIR}"
echo "    target    : ${TARGET}:${VNC_PORT} (WinRM ${WINRM_PORT})"
echo "    wordlist  : ${WORDLIST}  ($(wc -l < "${WORDLIST}") entries)"
echo "    capture   : ${DURATION}s OR ${MAX_PACKETS} packets, BPF 'tcp port ${VNC_PORT}'"
echo "    validate  : ${DO_VALIDATE}"

# Window-start in epoch + ISO; recorded so the alerts.json slice can be
# filtered to the run window.
WINDOW_START_EPOCH="$(date -u +%s)"
WINDOW_START_ISO="$(date -u -d "@${WINDOW_START_EPOCH}" +%FT%TZ)"
echo "    window    : ${WINDOW_START_ISO} (epoch ${WINDOW_START_EPOCH})"

# --------------------------------------------------------- 1. PREFLIGHT
if [ "${SKIP_PREFLIGHT}" -eq 0 ]; then
    step "Preflight"
    PRE_OK=1

    # OPNsense reachable + tc mirror is producing frames on vtnet2.
    if "${REPO_ROOT}/scripts/proxmox/opnsense-export-pcap.sh" --probe > "${OUT_DIR}/preflight-opnsense.txt" 2>&1; then
        echo "    OK  opnsense MIRROR has frames"
    else
        echo "    FAIL opnsense MIRROR probe failed (see ${OUT_DIR}/preflight-opnsense.txt)"
        PRE_OK=0
    fi

    # Wazuh manager reachable on :1514.
    if timeout 5 bash -c "</dev/tcp/${WAZUH_MANAGER_HOST:-192.168.61.10}/1514" 2>/dev/null; then
        echo "    OK  wazuh.manager:1514 open"
    else
        echo "    FAIL wazuh.manager:1514 closed"
        PRE_OK=0
    fi

    # Arkime viewer reachable on :8005.
    if timeout 5 bash -c "</dev/tcp/${ARKIME_HOST:-192.168.61.11}/8005" 2>/dev/null; then
        echo "    OK  arkime.viewer:8005 open"
    else
        echo "    FAIL arkime.viewer:8005 closed"
        PRE_OK=0
    fi

    # EWS WinRM (skip if --no-emulation).
    if [ "${NO_EMULATION}" -eq 0 ]; then
        if timeout 5 bash -c "</dev/tcp/${TARGET}/${WINRM_PORT}" 2>/dev/null; then
            echo "    OK  ${TARGET}:${WINRM_PORT} open"
        else
            echo "    FAIL ${TARGET}:${WINRM_PORT} closed (WinRM)"
            PRE_OK=0
        fi
        if timeout 5 bash -c "</dev/tcp/${TARGET}/${VNC_PORT}" 2>/dev/null; then
            echo "    OK  ${TARGET}:${VNC_PORT} open (VNC)"
        else
            echo "    FAIL ${TARGET}:${VNC_PORT} closed (VNC)"
            PRE_OK=0
        fi
    fi

    if [ "${PRE_OK}" -ne 1 ]; then
        echo "[!] preflight failed; abort. (Pass --skip-preflight to override.)"
        exit 1
    fi
fi

# --------------------------------------------------------- 2. START CAPTURE (BG)
PCAP_OUT="${OUT_DIR}/opnsense-mirror.pcap"
step "Starting OPNsense capture in background"
"${REPO_ROOT}/scripts/proxmox/opnsense-export-pcap.sh" \
    --duration "${DURATION}" \
    --max-packets "${MAX_PACKETS}" \
    --bpf "tcp port ${VNC_PORT}" \
    --out "${PCAP_OUT}" \
    --no-arkime \
    --run-id "${RUN_ID}" \
    --tag "challenge:${RUN_ID}" \
    > "${OUT_DIR}/capture.log" 2>&1 &
CAP_PID=$!
echo "    capture pid=${CAP_PID}; log=${OUT_DIR}/capture.log"

# Give tcpdump a 3s head-start so it definitely has the BPF up before
# the first hydra probe lands.
sleep 3

cleanup() {
    if kill -0 "${CAP_PID}" 2>/dev/null; then
        echo "[*] cleanup: capture still running (pid=${CAP_PID}); waiting up to 30s"
        # Don't SIGINT -- tcpdump on the OPNsense side has its own -G/-c
        # bound. Let it finish naturally so the file is complete.
        for _ in $(seq 1 30); do
            kill -0 "${CAP_PID}" 2>/dev/null || break
            sleep 1
        done
        kill -0 "${CAP_PID}" 2>/dev/null && kill "${CAP_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --------------------------------------------------------- 3. EMULATION (FG)
if [ "${NO_EMULATION}" -eq 0 ]; then
    step "Running live VNC brute force (vnc-adversary-emulation.sh)"
    # --skip-arkime because the Arkime ingestion is fed by the OPNsense
    # capture above, not the operator-workstation tcpdump in the
    # emulation script. --skip-export keeps the orchestrator's
    # write of the alerts dataset below (we want the prod manager's
    # alerts, not just the local-lab one).
    ADMIN_PW="${ADMIN_PW}" "${REPO_ROOT}/scripts/observability/vnc-adversary-emulation.sh" \
        --target "${TARGET}" \
        --vnc-port "${VNC_PORT}" \
        --winrm-port "${WINRM_PORT}" \
        --admin-user "${ADMIN_USER}" \
        --admin-pass "${ADMIN_PW}" \
        --wordlist "${WORDLIST}" \
        --run-id "${RUN_ID}" \
        --skip-arkime \
        --skip-export \
        > "${OUT_DIR}/emulation.log" 2>&1 \
        || echo "[!] emulation script exited non-zero (continuing; check ${OUT_DIR}/emulation.log)"
    # The emulation script writes its own artifacts under
    # artifacts/ews/vnc-foothold/<run-id>/; copy the recovered password
    # marker for the INDEX.md if present.
    EMU_DIR="${REPO_ROOT}/artifacts/ews/vnc-foothold/${RUN_ID}"
    if [ -f "${EMU_DIR}/summary.json" ]; then
        cp "${EMU_DIR}/summary.json" "${OUT_DIR}/emulation-summary.json"
    fi
else
    step "Skipping emulation (--no-emulation); capture-only mode"
fi

# --------------------------------------------------------- 4. WAIT FOR CAPTURE
step "Waiting for OPNsense capture to finish (pid=${CAP_PID})"
wait "${CAP_PID}" 2>/dev/null || true
trap - EXIT
if [ ! -s "${PCAP_OUT}" ]; then
    echo "[!] pcap empty/missing at ${PCAP_OUT}" >&2
    echo "    see ${OUT_DIR}/capture.log"
    cat "${OUT_DIR}/capture.log" >&2 || true
    exit 1
fi
echo "    pcap: $(du -h "${PCAP_OUT}" | awk '{print $1}') ${PCAP_OUT}"

WINDOW_END_EPOCH="$(date -u +%s)"
WINDOW_END_ISO="$(date -u -d "@${WINDOW_END_EPOCH}" +%FT%TZ)"

# --------------------------------------------------------- 5. PUSH TO ARKIME
step "Pushing pcap into crit-capture Arkime"
"${REPO_ROOT}/scripts/proxmox/sync-arkime-pcap.sh" \
    --tag "opnsense-mirror" \
    --tag "challenge:${RUN_ID}" \
    "${PCAP_OUT}" \
    > "${OUT_DIR}/sync-arkime.log" 2>&1 \
    || echo "[!] sync-arkime-pcap exited non-zero (see ${OUT_DIR}/sync-arkime.log)"

# --------------------------------------------------------- 6. WAZUH SLICE
step "Pulling Wazuh alerts.json slice over run window"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
WAZUH_MANAGER_USER="${WAZUH_MANAGER_USER:-dadmin}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"
SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
PROXY_CMD="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST:-192.168.60.1}"
ALERTS_JSON="${OUT_DIR}/alerts-during-window.json"

if [ -n "${SSHPASS_BIN}" ]; then
    ssh -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes \
        -i "${SSH_KEY}" \
        -o "ProxyCommand=${PROXY_CMD}" \
        "${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}" \
        "sudo awk -v s='${WINDOW_START_ISO}' -v e='${WINDOW_END_ISO}' '
          BEGIN { gsub(\"[TZ:.-]\",\"\",s); gsub(\"[TZ:.-]\",\"\",e) }
          {
            if (match(\$0, /\"timestamp\":\"([^\"]+)\"/, m)) {
              t = m[1]; gsub(\"[TZ:.+-]\",\"\",t)
              if (t >= s && t <= e) print
            }
          }' /var/ossec/logs/alerts/alerts.json" \
        > "${ALERTS_JSON}" 2>"${OUT_DIR}/alerts-pull.err" \
        || echo "[!] alerts pull failed; see ${OUT_DIR}/alerts-pull.err"
else
    echo "[!] sshpass not present; cannot pull alerts.json from manager"
fi

# Per-rule slices.
if [ -s "${ALERTS_JSON}" ] && command -v jq >/dev/null 2>&1; then
    for rid in 100810 100811 100812 100816 100813 100815 100804 100805 100806 100807; do
        jq -c "select(.rule.id==\"${rid}\")" "${ALERTS_JSON}" 2>/dev/null \
            > "${OUT_DIR}/alerts-rule-${rid}.json" || true
        cnt="$(wc -l < "${OUT_DIR}/alerts-rule-${rid}.json" 2>/dev/null || echo 0)"
        printf '    rule %s : %s hits\n' "${rid}" "${cnt}"
    done
fi

# --------------------------------------------------------- 7. SUMMARY + INDEX
RECOVERED_PW=""
if [ -f "${OUT_DIR}/emulation-summary.json" ] && command -v jq >/dev/null 2>&1; then
    RECOVERED_PW="$(jq -r '.recovered_password // empty' "${OUT_DIR}/emulation-summary.json" 2>/dev/null || true)"
fi

cat > "${OUT_DIR}/summary.json" <<JSON
{
  "run_id":               "${RUN_ID}",
  "window_start_utc":     "${WINDOW_START_ISO}",
  "window_end_utc":       "${WINDOW_END_ISO}",
  "target":               "${TARGET}:${VNC_PORT}",
  "wordlist":             "${WORDLIST}",
  "wordlist_entries":     $(wc -l < "${WORDLIST}"),
  "pcap":                 "${PCAP_OUT}",
  "pcap_bytes":           $(stat -c '%s' "${PCAP_OUT}" 2>/dev/null || echo 0),
  "alerts_slice":         "${ALERTS_JSON}",
  "recovered_password":   "${RECOVERED_PW}",
  "emulation_skipped":    $([ "${NO_EMULATION}" -eq 1 ] && echo true || echo false)
}
JSON

cat > "${OUT_DIR}/INDEX.md" <<EOF
# OPNsense VNC Brute Force Analyst Challenge -- ${RUN_ID}

Generated by \`scripts/observability/opnsense-vnc-challenge.sh\` on
$(date -u +%FT%TZ).

## Three analyst tracks (all land on the same plaintext, \`FELDTECH_VNC\`)

### A. PCAP track (network capture)

Open the SPAN'd pcap from OPNsense in Arkime:

\`\`\`
http://${ARKIME_HOST:-192.168.61.11}:8005/sessions?expression=tags%3D%3D%22challenge%3A${RUN_ID}%22%20%26%26%20destination.port%3D%3D${VNC_PORT}
\`\`\`

Extract the (challenge, response) pair of the SUCCESSFUL auth and decode:

\`\`\`bash
tshark -r ${PCAP_OUT} -Y 'vnc' \\
    -T fields -e frame.number -e vnc.auth_challenge -e vnc.auth_response -e vnc.security_result \\
    | awk -F'\\t' '\$4=="0" { print prev; exit } { prev=\$0 }'

python3 scripts/observability/vnc-cred-tool.py crack \\
    --challenge <CHAL_HEX> --response <RESP_HEX> \\
    --wordlist ${WORDLIST}
# -> FELDTECH_VNC
\`\`\`

### B. SIEM track (endpoint exfil receipt)

Wazuh rule 100806 (level 12) fired on the planted exfil receipt
\`C:\\Users\\Public\\vnc-pwd-dump.txt\`. The hex blob is in \`full_log\`.

\`\`\`bash
ssh dadmin@${WAZUH_MANAGER_HOST:-192.168.61.10} \\
    'sudo grep "\\"id\\":\\"100806\\"" /var/ossec/logs/alerts/alerts.json | tail -1' \\
    | jq -r .full_log
# -> "VNC password blob (hex): XX-XX-XX-XX-XX-XX-XX-XX ..."

python3 scripts/observability/vnc-cred-tool.py decode --hex <HEX> --wordlist ${WORDLIST}
# -> FELDTECH_VNC
\`\`\`

### C. NSM track (new) -- detection only

OPNsense Suricata fired SID 2400001 (probe burst, Wazuh 100810),
SID 2400002 (server-side failed-auth burst, Wazuh 100811), and SID
2400003 (server-side success, Wazuh 100816). Wazuh's velocity
correlator 100812 fires when probe+failure arrive within 5 minutes from
the same source; 100813 fires when failed auths are followed by a
successful login. \`filterlog\` fires Wazuh 100815 as a Suricata-down
fallback.

This track does NOT recover the password by itself (VNC RFB is
challenge-response; the wire never carries plaintext). It tells the
analyst WHO and WHEN; pivot from there to track A or B for plaintext.

## Run window

| Field | Value |
| --- | --- |
| Start (UTC) | ${WINDOW_START_ISO} |
| End (UTC)   | ${WINDOW_END_ISO} |
| Target      | ${TARGET}:${VNC_PORT} |
| Wordlist    | ${WORDLIST} ($(wc -l < "${WORDLIST}") entries) |
| Recovered   | ${RECOVERED_PW:-(emulation skipped or did not produce a summary)} |

## Artifacts in this directory

| File | Purpose |
| --- | --- |
| INDEX.md | this file |
| summary.json | machine-readable summary |
| orchestrator.log | full run log |
| opnsense-mirror.pcap | OPNsense SPAN capture of the BF |
| capture.log | tcpdump-on-OPNsense output |
| sync-arkime.log | Arkime ingest result |
| emulation.log | (if emulation ran) hydra + WinRM payload output |
| emulation-summary.json | (if emulation ran) cred-tool summary |
| alerts-during-window.json | full alerts.json slice over the run window |
| alerts-rule-1008XX.json | per-rule jq-filtered slices (one file per rule) |
EOF

# --------------------------------------------------------- 8. OPTIONAL VALIDATE
if [ "${DO_VALIDATE}" -eq 1 ]; then
    step "Running end-to-end validator (--validate)"
    VAL="${REPO_ROOT}/scripts/validate/validate-opnsense-vnc-pipeline.sh"
    if [ -x "${VAL}" ]; then
        "${VAL}" \
            --run-id "${RUN_ID}" \
            --pcap "${PCAP_OUT}" \
            --alerts "${ALERTS_JSON}" \
            --wordlist "${WORDLIST}" \
            --expected-password "${RECOVERED_PW:-FELDTECH_VNC}" \
            || { echo "[!] VALIDATOR FAILED -- see ${OUT_DIR}/results.txt"; exit 1; }
    else
        echo "[!] ${VAL} not found / not executable; skipping"
    fi
fi

echo
echo "[+] opnsense-vnc-challenge complete"
echo "    INDEX: ${OUT_DIR}/INDEX.md"
echo "    summary: ${OUT_DIR}/summary.json"
echo "    next:  ./scripts/validate/validate-opnsense-vnc-pipeline.sh --run-id ${RUN_ID}"
