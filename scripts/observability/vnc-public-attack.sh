#!/usr/bin/env bash
# Capture, archive, and read out an adversary VNC brute-force pcap
# against the SecretCon EWS public VNC server (192.168.61.20:5900).
#
# Thin orchestrator over three already-in-tree scripts:
#   1. scripts/observability/vnc-adversary-emulation.sh
#         --push-to-crit-capture
#      -> generates traffic, captures pcap, copies trimmed pcap to
#         crit-capture (.11):/opt/arkime-docker/pcaps/ AND ingests it
#         into Arkime, also stages to local arkime-docker/pcaps/.
#   2. scripts/observability/vnc-pcap-analyze.sh
#      -> per-stream rollup, recovers FELDTECH_VNC, writes evidence pack.
#   3. scripts/validate/validate-vnc-public-attack.sh
#      -> 5 PASS/FAIL assertions.
#
# Writes a single INDEX.md under
# artifacts/ews/vnc-public-attack/<run-id>/ that links the underlying
# vnc-foothold/<run-id>/ dataset, the analysis/ evidence pack, the
# validator results, and the Arkime viewer URL.
#
# Usage:
#   ./scripts/observability/vnc-public-attack.sh
#   ./scripts/observability/vnc-public-attack.sh --run-id <id>
#   ./scripts/observability/vnc-public-attack.sh --capture-iface vmbr1
#   ./scripts/observability/vnc-public-attack.sh --no-validate
#   ./scripts/observability/vnc-public-attack.sh --skip-emulation \
#       --reuse-pcap artifacts/ews/proof/ews-vnc-pcap-XXXX/vnc_auth.pcap
#
# Required env (.env auto-sourced):
#   PROXMOX_HOST, PROXMOX_PASSWORD     (sync-arkime-pcap + alerts/arkime queries)
#   ADMIN_PW                           (EWS Administrator for the WinRM payload;
#                                       emulation step uses it)
#
# Optional env:
#   EWS_TARGET            default 192.168.61.20
#   VNC_PORT              default 5900
#   WINRM_PORT            default 5985
#   CAPTURE_IFACE         default wg-ctf
#   ARKIME_HOST           default 192.168.61.11

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/lib/load_repo_env.sh
. "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}"

RUN_ID=""
TARGET="${EWS_TARGET:-192.168.61.20}"
VNC_PORT="${VNC_PORT:-5900}"
WINRM_PORT="${WINRM_PORT:-5985}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
CAPTURE_IFACE="${CAPTURE_IFACE:-wg-ctf}"
WORDLIST=""
SKIP_EMULATION=0
REUSE_PCAP=""
DO_VALIDATE=1
SKIP_PREFLIGHT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id)         RUN_ID="$2"; shift 2 ;;
        --target)         TARGET="$2"; shift 2 ;;
        --vnc-port)       VNC_PORT="$2"; shift 2 ;;
        --winrm-port)     WINRM_PORT="$2"; shift 2 ;;
        --admin-user)     ADMIN_USER="$2"; shift 2 ;;
        --capture-iface)  CAPTURE_IFACE="$2"; shift 2 ;;
        --wordlist)       WORDLIST="$2"; shift 2 ;;
        --skip-emulation) SKIP_EMULATION=1; shift ;;
        --reuse-pcap)     REUSE_PCAP="$2"; SKIP_EMULATION=1; shift 2 ;;
        --no-validate)    DO_VALIDATE=0; shift ;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
        -h|--help)        sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "${RUN_ID}" ]; then
    RUN_ID="vnc-public-attack-$(date -u +%Y%m%dT%H%M%SZ)"
fi

OUT_DIR="${REPO_ROOT}/artifacts/ews/vnc-public-attack/${RUN_ID}"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/orchestrator.log"
exec > >(tee -a "${LOG}") 2>&1

ARKIME_HOST="${ARKIME_HOST:-192.168.61.11}"

step() { printf '\n[*] %s\n' "$*"; }

step "VNC public-attack orchestrator"
echo "    run_id        : ${RUN_ID}"
echo "    out_dir       : ${OUT_DIR}"
echo "    target        : ${TARGET}:${VNC_PORT}"
echo "    capture iface : ${CAPTURE_IFACE}"
echo "    arkime host   : ${ARKIME_HOST}"
echo "    skip_emulation: ${SKIP_EMULATION}  reuse_pcap: ${REUSE_PCAP:-(none)}"
echo "    validate      : ${DO_VALIDATE}"

WINDOW_START_EPOCH="$(date -u +%s)"
WINDOW_START_ISO="$(date -u -d "@${WINDOW_START_EPOCH}" +%FT%TZ)"
echo "    window_start  : ${WINDOW_START_ISO}"

# --------------------------------------------------------- 1. PREFLIGHT
if [ "${SKIP_PREFLIGHT}" -eq 0 ]; then
    step "Preflight"
    PRE_OK=1

    if [ "${SKIP_EMULATION}" -eq 0 ]; then
        if timeout 5 bash -c "</dev/tcp/${TARGET}/${VNC_PORT}" 2>/dev/null; then
            echo "    OK   ${TARGET}:${VNC_PORT} open (VNC)"
        else
            echo "    FAIL ${TARGET}:${VNC_PORT} closed (VNC)"; PRE_OK=0
        fi
        if timeout 5 bash -c "</dev/tcp/${TARGET}/${WINRM_PORT}" 2>/dev/null; then
            echo "    OK   ${TARGET}:${WINRM_PORT} open (WinRM)"
        else
            # WinRM is only used by the optional post-foothold registry-dump
            # payload; the pcap deliverable does not depend on it.
            echo "    WARN ${TARGET}:${WINRM_PORT} closed (WinRM exfil step will skip)"
        fi
        if [ -z "${ADMIN_PW:-}" ]; then
            echo "    FAIL ADMIN_PW not set in env/.env (needed for WinRM payload)"; PRE_OK=0
        else
            echo "    OK   ADMIN_PW set"
        fi
        if ip link show "${CAPTURE_IFACE}" >/dev/null 2>&1; then
            echo "    OK   capture iface ${CAPTURE_IFACE} present"
        else
            echo "    FAIL capture iface ${CAPTURE_IFACE} missing (try --capture-iface)"; PRE_OK=0
        fi
        if [ -z "${PROXMOX_PASSWORD:-}" ]; then
            echo "    FAIL PROXMOX_PASSWORD not set (needed for crit-capture push)"; PRE_OK=0
        else
            echo "    OK   PROXMOX_PASSWORD set"
        fi
    fi

    if timeout 5 bash -c "</dev/tcp/${ARKIME_HOST}/8005" 2>/dev/null; then
        echo "    OK   ${ARKIME_HOST}:8005 open (Arkime viewer)"
    else
        echo "    WARN ${ARKIME_HOST}:8005 closed (validator step 5 will FAIL)"
    fi

    if [ "${PRE_OK}" -ne 1 ]; then
        echo "[!] preflight failed; abort (override with --skip-preflight)"
        exit 1
    fi
fi

# --------------------------------------------------------- 2. EMULATION
EMU_DIR="${REPO_ROOT}/artifacts/ews/vnc-foothold/${RUN_ID}"
EMU_PCAP="${EMU_DIR}/vnc_auth.pcap"

if [ "${SKIP_EMULATION}" -eq 0 ]; then
    step "Running vnc-adversary-emulation.sh against ${TARGET}:${VNC_PORT}"

    EMU_ARGS=(
        --target "${TARGET}"
        --vnc-port "${VNC_PORT}"
        --winrm-port "${WINRM_PORT}"
        --admin-user "${ADMIN_USER}"
        --admin-pass "${ADMIN_PW}"
        --capture-iface "${CAPTURE_IFACE}"
        --run-id "${RUN_ID}"
        --skip-export
    )
    [ -n "${WORDLIST}" ] && EMU_ARGS+=(--wordlist "${WORDLIST}")

    "${REPO_ROOT}/scripts/observability/vnc-adversary-emulation.sh" \
        "${EMU_ARGS[@]}" \
        || { echo "[!] emulation step failed; see ${EMU_DIR}/run.log"; }
elif [ -n "${REUSE_PCAP}" ]; then
    step "--reuse-pcap given; copying ${REUSE_PCAP} into ${EMU_DIR}/"
    mkdir -p "${EMU_DIR}"
    cp -f "${REUSE_PCAP}" "${EMU_PCAP}"
fi

if [ ! -s "${EMU_PCAP}" ]; then
    echo "[!] no pcap at ${EMU_PCAP} -- nothing to analyze"
    exit 1
fi

WINDOW_END_EPOCH="$(date -u +%s)"
WINDOW_END_ISO="$(date -u -d "@${WINDOW_END_EPOCH}" +%FT%TZ)"

# --------------------------------------------------------- 2b. PUSH TO CRIT-CAPTURE
# Always push (idempotent on remote) so both fresh-capture and
# --reuse-pcap paths land the pcap in prod Arkime.
step "Pushing pcap to crit-capture (.11) Arkime"
SYNC_LOG="${OUT_DIR}/sync-arkime-prod.log"
SYNC_SCRIPT="${REPO_ROOT}/scripts/proxmox/sync-arkime-pcap.sh"
if [ -x "${SYNC_SCRIPT}" ]; then
    "${SYNC_SCRIPT}" \
        --tag "vnc-public-attack" \
        --tag "run:${RUN_ID}" \
        "${EMU_PCAP}" \
        2>&1 | tee "${SYNC_LOG}" \
        || echo "[!] sync-arkime-pcap.sh exited non-zero (see ${SYNC_LOG})"
else
    echo "[!] ${SYNC_SCRIPT} missing/not executable; skipping push"
fi

# --------------------------------------------------------- 3. ANALYZER
step "Analyzing pcap"
ANALYSIS_DIR="${EMU_DIR}/analysis"
ANALYZE_ARGS=("${EMU_PCAP}")
[ -n "${WORDLIST}" ] && ANALYZE_ARGS=(--wordlist "${WORDLIST}" "${EMU_PCAP}")

# Print the readout to stdout (and tee into our orchestrator.log via exec above).
"${REPO_ROOT}/scripts/observability/vnc-pcap-analyze.sh" "${ANALYZE_ARGS[@]}" \
    | tee "${OUT_DIR}/readout.md"

# --------------------------------------------------------- 4. VALIDATE
VALIDATE_RC=0
RESULTS_FILE=""
if [ "${DO_VALIDATE}" -eq 1 ]; then
    step "Running validate-vnc-public-attack.sh"
    VAL="${REPO_ROOT}/scripts/validate/validate-vnc-public-attack.sh"
    if [ -x "${VAL}" ]; then
        VAL_ARGS=(
            --run-id "${RUN_ID}"
            --pcap "${EMU_PCAP}"
        )
        [ -n "${WORDLIST}" ] && VAL_ARGS+=(--wordlist "${WORDLIST}")
        "${VAL}" "${VAL_ARGS[@]}" || VALIDATE_RC=$?
        RESULTS_FILE="${REPO_ROOT}/artifacts/ews/vnc-public-attack/validate-${RUN_ID}/results.txt"
    else
        echo "[!] ${VAL} missing/not executable; skipping validation"
        VALIDATE_RC=2
    fi
fi

# --------------------------------------------------------- 5. INDEX.md
ARKIME_BASENAME="$(basename "${EMU_PCAP}")"
ARKIME_URL="http://${ARKIME_HOST}:8005/sessions?expression=tags%3D%3D%22vnc-public-attack%22%20%26%26%20destination.port%3D%3D${VNC_PORT}"

# Pull a few headline numbers out of analysis/summary.json if it exists.
RFB_ATTEMPTS="?"
SUCCESS_COUNT="?"
FAIL_COUNT="?"
RECOVERED_PW="?"
if [ -s "${ANALYSIS_DIR}/summary.json" ] && command -v jq >/dev/null 2>&1; then
    RFB_ATTEMPTS="$(jq -r '.rfb_attempt_count'      "${ANALYSIS_DIR}/summary.json")"
    SUCCESS_COUNT="$(jq -r '.successful_auth_count' "${ANALYSIS_DIR}/summary.json")"
    FAIL_COUNT="$(jq -r '.failed_auth_count'        "${ANALYSIS_DIR}/summary.json")"
fi
if [ -s "${ANALYSIS_DIR}/recovered.txt" ]; then
    RECOVERED_PW="$(head -n1 "${ANALYSIS_DIR}/recovered.txt")"
fi

cat > "${OUT_DIR}/INDEX.md" <<EOF
# VNC public-attack -- ${RUN_ID}

Generated by \`scripts/observability/vnc-public-attack.sh\` on
$(date -u +%FT%TZ).

## Headline

| Field | Value |
| --- | --- |
| target          | ${TARGET}:${VNC_PORT} |
| RFB attempts    | ${RFB_ATTEMPTS} |
| successful auth | ${SUCCESS_COUNT} |
| failed auths    | ${FAIL_COUNT} |
| recovered pw    | \`${RECOVERED_PW}\` |
| window start    | ${WINDOW_START_ISO} |
| window end      | ${WINDOW_END_ISO} |

## Where the pcap lives

| Location | Path |
| --- | --- |
| operator workstation (raw)     | \`${EMU_DIR}/vnc-attack-raw.pcap\` |
| operator workstation (trimmed) | \`${EMU_PCAP}\` |
| crit-capture (.11) host        | \`/opt/arkime-docker/pcaps/${ARKIME_BASENAME}\` |
| arkime container raw           | \`/opt/arkime/raw/${ARKIME_BASENAME}\` |
| local-lab arkime               | \`infrastructure/arkime-docker/pcaps/vnc_auth.pcap\` |

## Analyst entry points

- Arkime UI (filter \`tags == vnc-public-attack && destination.port == ${VNC_PORT}\`):
  ${ARKIME_URL}
- Local readout: \`${OUT_DIR}/readout.md\` (mirror of stdout block)
- Per-stream table: \`${ANALYSIS_DIR}/per-stream.tsv\`
- Full evidence pack: \`${ANALYSIS_DIR}/\`

## Reproducer

\`\`\`bash
# Re-run the whole flow (capture + archive + readout + validate):
./scripts/observability/vnc-public-attack.sh --run-id <new-id>

# Re-analyze an existing pcap (no traffic generation):
./scripts/observability/vnc-pcap-analyze.sh ${EMU_PCAP}

# Open the trimmed pcap in tshark:
tshark -r ${EMU_PCAP} -Y vnc -V | less

# Re-run only the crit-capture archival of an existing pcap:
./scripts/proxmox/sync-arkime-pcap.sh \\
    --tag vnc-public-attack --tag run:${RUN_ID} \\
    ${EMU_PCAP}

# Re-run the offline DES crack:
nix develop --command python3 scripts/observability/vnc-cred-tool.py crack \\
    --challenge "\$(awk 'NR==2 {print \$4}' ${ANALYSIS_DIR}/success-pair.tsv)" \\
    --response  "\$(awk 'NR==2 {print \$5}' ${ANALYSIS_DIR}/success-pair.tsv)" \\
    --wordlist  provisioning/wordlists/vnc-betterdefaultpasslist.txt
\`\`\`

## Validation

EOF

if [ "${DO_VALIDATE}" -eq 1 ] && [ -n "${RESULTS_FILE}" ] && [ -s "${RESULTS_FILE}" ]; then
    {
        echo "Results from validate-vnc-public-attack.sh:"
        echo
        echo '```'
        cat "${RESULTS_FILE}"
        echo '```'
        echo
        echo "Exit code: ${VALIDATE_RC} ($([ "${VALIDATE_RC}" -eq 0 ] && echo PASS || echo FAIL))"
    } >> "${OUT_DIR}/INDEX.md"
elif [ "${DO_VALIDATE}" -eq 0 ]; then
    echo "Skipped (--no-validate)." >> "${OUT_DIR}/INDEX.md"
else
    echo "No results.txt produced (validator failed early; rc=${VALIDATE_RC})." >> "${OUT_DIR}/INDEX.md"
fi

echo
echo "[+] vnc-public-attack complete"
echo "    INDEX : ${OUT_DIR}/INDEX.md"
echo "    pcap  : ${EMU_PCAP}"
echo "    arkime: ${ARKIME_URL}"
echo "    rc    : validate=${VALIDATE_RC}"

exit "${VALIDATE_RC}"
