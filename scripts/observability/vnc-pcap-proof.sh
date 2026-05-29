#!/usr/bin/env bash
# SecretCon EWS VNC password reveal — PCAP proof orchestrator.
#
# Synthesises a byte-accurate RFB-3.8 authentication handshake PCAP
# from FELDTECH_VNC, dissects it with tshark to extract the captured
# (challenge, response) pair, then dictionary-attacks the pair back
# to plaintext via the same VNC DES math.
#
# Stages the PCAP in the Arkime corpus and (best effort) brings the
# stack up + imports the session so the participant-facing analyst
# path is also exercised.
#
# Artefacts land in artifacts/ews/proof/ews-vnc-pcap-<TS>/:
#   vnc_auth.pcap       - the synthesised RFB auth handshake
#   tshark-summary.txt  - tshark -V dissection of the RFB frames
#   tshark-fields.txt   - extracted vnc.auth_challenge + vnc.auth_response
#   recovered.txt       - plaintext recovered from the captured pair
#   arkime-session-count.json   - (optional) Arkime session count for port==5900
#
# Exit 0 on successful round-trip (recovered.txt == FELDTECH_VNC).
#
# Flags:
#   --arkime         try to bring Arkime up + import the PCAP
#   --no-arkime      skip Arkime staging entirely (default)
#   --challenge HEX  override the 16-byte RFB challenge (default deterministic)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

PASSWORD="${PASSWORD:-FELDTECH_VNC}"
WORDLIST="${WORDLIST:-${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt}"
CHALLENGE_HEX="0123456789abcdef0123456789abcdef"
DO_ARKIME=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arkime) DO_ARKIME=1 ;;
        --no-arkime) DO_ARKIME=0 ;;
        --challenge) CHALLENGE_HEX="$2"; shift ;;
        -h|--help)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

RUN_ID="ews-vnc-pcap-$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${REPO_ROOT}/artifacts/ews/proof/${RUN_ID}"
mkdir -p "${OUT}"

log() { printf '[vnc-pcap-proof] %s\n' "$*"; }
die() { printf '[vnc-pcap-proof] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "${WORDLIST}" ]] || die "wordlist not found at ${WORDLIST}"
command -v python3 >/dev/null || die "python3 not on PATH (are you in 'nix develop'?)"
command -v tshark  >/dev/null || die "tshark not on PATH (are you in 'nix develop'?)"

log "run id: ${RUN_ID}"
log "out dir: ${OUT}"
log "password: ${PASSWORD}"
log "challenge (hex): ${CHALLENGE_HEX}"

# 1. Generate the synth PCAP.
python3 "${REPO_ROOT}/scripts/observability/vnc-cred-tool.py" synth-pcap \
    --password "${PASSWORD}" \
    --challenge "${CHALLENGE_HEX}" \
    --output "${OUT}/vnc_auth.pcap" \
    | tee "${OUT}/synth-pcap.txt"

# 2. tshark dissection (verbose) - human-readable proof the RFB
#    dissector engages.
tshark -r "${OUT}/vnc_auth.pcap" \
    -d tcp.port==5900,vnc \
    -Y "vnc" -O vnc -V 2>&1 | tee "${OUT}/tshark-summary.txt" >/dev/null

# 3. Extract fields independently. tshark -T fields with the
#    decode-as hint guarantees deterministic parsing.
tshark -r "${OUT}/vnc_auth.pcap" \
    -d tcp.port==5900,vnc \
    -Y "vnc" -T fields \
    -e vnc.auth_challenge -e vnc.auth_response 2>&1 \
    | tee "${OUT}/tshark-fields-raw.txt" >/dev/null

# Collapse to one row each. tshark emits a row per RFB frame; only
# the challenge frame populates vnc.auth_challenge, only the
# response frame populates vnc.auth_response.
EXTRACTED_CHAL="$(awk -F'\t' '$1!=""{print $1; exit}' "${OUT}/tshark-fields-raw.txt")"
EXTRACTED_RESP="$(awk -F'\t' '$2!=""{print $2; exit}' "${OUT}/tshark-fields-raw.txt")"
printf 'vnc.auth_challenge\t%s\nvnc.auth_response\t%s\n' \
    "${EXTRACTED_CHAL}" "${EXTRACTED_RESP}" \
    | tee "${OUT}/tshark-fields.txt"

[[ -n "${EXTRACTED_CHAL}" ]] || die "tshark did not extract vnc.auth_challenge"
[[ -n "${EXTRACTED_RESP}" ]] || die "tshark did not extract vnc.auth_response"

# 4. Crack with the wordlist.
log "running dictionary attack via vnc-cred-tool crack ..."
python3 "${REPO_ROOT}/scripts/observability/vnc-cred-tool.py" crack \
    --challenge "${EXTRACTED_CHAL}" \
    --response  "${EXTRACTED_RESP}" \
    --wordlist  "${WORDLIST}" \
    | tee "${OUT}/recovered.txt"

if ! grep -qx "${PASSWORD}" "${OUT}/recovered.txt"; then
    die "round-trip failed: expected '${PASSWORD}', got '$(cat "${OUT}/recovered.txt")'"
fi

# 5. (best effort) stage in Arkime + import.
ARKIME_STAGED_PATH="${REPO_ROOT}/infrastructure/arkime-docker/pcaps/vnc_auth.pcap"
mkdir -p "$(dirname "${ARKIME_STAGED_PATH}")"
cp "${OUT}/vnc_auth.pcap" "${ARKIME_STAGED_PATH}"
log "staged PCAP into Arkime corpus: ${ARKIME_STAGED_PATH}"

if [[ "${DO_ARKIME}" -eq 1 ]]; then
    log "bringing Arkime up + importing ..."
    if "${REPO_ROOT}/scripts/arkime-docker-up.sh" >"${OUT}/arkime-up.log" 2>&1; then
        : "${ARKIME_OS_PORT:=9201}"
        [[ -f "${REPO_ROOT}/infrastructure/arkime-docker/.env" ]] \
            && . "${REPO_ROOT}/infrastructure/arkime-docker/.env"
        : "${ARKIME_OS_PORT:=9201}"
        sleep 6
        curl -sf "http://127.0.0.1:${ARKIME_OS_PORT}/arkime_sessions3-*/_count?q=destination.port:5900" \
            > "${OUT}/arkime-session-count.json" 2>/dev/null \
            && log "arkime session count -> ${OUT}/arkime-session-count.json" \
            || log "could not query Arkime sessions; see ${OUT}/arkime-up.log"
        curl -sf "http://127.0.0.1:${ARKIME_OS_PORT}/arkime_sessions3-*/_search?q=destination.port:5900&pretty" \
            > "${OUT}/arkime-session.json" 2>/dev/null \
            && log "arkime session document -> ${OUT}/arkime-session.json" \
            || true
    else
        log "arkime-docker-up.sh failed; staged PCAP is still present at ${ARKIME_STAGED_PATH}"
        log "(see ${OUT}/arkime-up.log)"
    fi
else
    log "Arkime auto-bring-up skipped (pass --arkime to enable)."
    log "  manually: ./scripts/arkime-docker-up.sh   (re-imports the staged PCAP)"
fi

log "PROOF COMPLETE"
log "  password : ${PASSWORD}"
log "  challenge: ${EXTRACTED_CHAL}"
log "  response : ${EXTRACTED_RESP}"
log "  recovered: $(cat "${OUT}/recovered.txt")"
log "  artefacts:"
for f in vnc_auth.pcap tshark-summary.txt tshark-fields.txt recovered.txt arkime-session-count.json arkime-session.json; do
    if [[ -f "${OUT}/${f}" ]]; then
        log "    - ${OUT}/${f}"
    fi
done
log "  Arkime staged: ${ARKIME_STAGED_PATH}"
