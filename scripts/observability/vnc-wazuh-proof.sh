#!/usr/bin/env bash
# SecretCon EWS VNC password reveal — Wazuh proof orchestrator.
#
# Generates a synthetic-but-cryptographically-real exfil-receipt line
# for the planted FELDTECH_VNC credential, feeds it through the running
# wazuh.manager's full analysis pipeline via wazuh-logtest, captures
# the matched rule (expected 100806/level 12), then dictionary-attacks
# the hex blob from the logtest output back to FELDTECH_VNC.
#
# Artefacts land in artifacts/ews/proof/ews-vnc-proof-<TS>/:
#   event.json     - the synth Wazuh event (JSON; archive shape)
#   full_log.txt   - the single line passed to wazuh-logtest
#   logtest.txt    - raw wazuh-logtest -v output (rule trace + match)
#   alert.json     - JSON-serialised "Alert" block extracted from logtest
#   recovered.txt  - plaintext recovered from the hex blob (FELDTECH_VNC)
#
# wazuh-logtest is the contract-correct primary path here because:
#   1. The in-tree wazuh_manager.conf does not enable the syslog
#      <remote><connection>syslog</...> block, so external injection
#      over port 514 is not available.
#   2. Rule 100806 binds <location> to the Windows path
#      \Users\Public\vnc-pwd-dump.txt -- any manager-side localfile
#      tail would produce a Linux location and the rule would not
#      fire. Only a real Windows agent (the EWS) can produce a
#      location-matching event that lands in alerts.json organically.
#
# The exfil-receipt line, the matched rule (100806 / level 12), the
# decoded full_log, and the round-trip back to FELDTECH_VNC together
# constitute the cryptographic proof requested by the planning step.
#
# Exit 0 on a successful round-trip (recovered.txt == FELDTECH_VNC).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

PASSWORD="${PASSWORD:-FELDTECH_VNC}"
WORDLIST="${WORDLIST:-${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt}"
MANAGER_CONTAINER="${MANAGER_CONTAINER:-wazuh.manager}"
HOSTNAME_TAG="${HOSTNAME_TAG:-ews01-replay}"
EVENT_LOCATION='C:\Users\Public\vnc-pwd-dump.txt'

RUN_ID="ews-vnc-proof-$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${REPO_ROOT}/artifacts/ews/proof/${RUN_ID}"
mkdir -p "${OUT}"

log() { printf '[vnc-wazuh-proof] %s\n' "$*"; }
die() { printf '[vnc-wazuh-proof] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "${WORDLIST}" ]] \
    || die "wordlist not found at ${WORDLIST}"
command -v python3 >/dev/null \
    || die "python3 not on PATH (are you in 'nix develop'?)"
docker ps --format '{{.Names}}' | grep -qx "${MANAGER_CONTAINER}" \
    || die "container '${MANAGER_CONTAINER}' is not running"
docker exec "${MANAGER_CONTAINER}" test -x /var/ossec/bin/wazuh-logtest \
    || die "wazuh-logtest missing inside ${MANAGER_CONTAINER}"

log "run id: ${RUN_ID}"
log "out dir: ${OUT}"

# Build the synth event.
python3 "${REPO_ROOT}/scripts/observability/vnc-cred-tool.py" \
    synth-wazuh-event \
    --password "${PASSWORD}" \
    --hostname "${HOSTNAME_TAG}" \
    --location "${EVENT_LOCATION}" \
    --output "${OUT}/event.json"

FULL_LOG="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['full_log'])" "${OUT}/event.json")"
printf '%s\n' "${FULL_LOG}" > "${OUT}/full_log.txt"
log "full_log: ${FULL_LOG}"

log "feeding event to wazuh-logtest in ${MANAGER_CONTAINER}..."
LOGTEST_RAW="$(printf '%s\n' "${FULL_LOG}" \
    | docker exec -i "${MANAGER_CONTAINER}" \
        /var/ossec/bin/wazuh-logtest -l "${EVENT_LOCATION}" 2>&1)"
printf '%s\n' "${LOGTEST_RAW}" > "${OUT}/logtest.txt"

# Confirm rule 100806 fired.
if ! grep -qE "id:\s*'100806'" "${OUT}/logtest.txt"; then
    log "logtest output:"
    cat "${OUT}/logtest.txt" >&2
    die "rule 100806 did not match the synth event"
fi
log "wazuh-logtest matched rule 100806 (level 12)"

# Distil the matched rule block into a structured JSON snapshot.
python3 - "${OUT}/logtest.txt" "${OUT}/alert.json" <<'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8', errors='replace').read()
alert = {}
m = re.search(r"\*\*Phase 1: Completed pre-decoding.\s*\n\s*full event: '(.+)'", text)
if m:
    alert["full_log"] = m.group(1)
phase3 = re.search(r"\*\*Phase 3: Completed filtering \(rules\).\n((?:\s+\S.*\n?)+)", text)
if phase3:
    for line in phase3.group(1).splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        k, _, v = line.partition(":")
        alert[k.strip()] = v.strip().strip("'")
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(alert, f, indent=2, sort_keys=True)
print(json.dumps(alert, indent=2, sort_keys=True))
PY

# Extract hex from the alert and crack it.
HEX="$(grep -oE '([0-9A-Fa-f]{2}-){7}[0-9A-Fa-f]{2}' "${OUT}/full_log.txt" | head -n1)"
[[ -n "${HEX}" ]] || die "could not extract hex blob from full_log"
log "extracted hex blob: ${HEX}"

log "running dictionary attack via vnc-cred-tool decode ..."
python3 "${REPO_ROOT}/scripts/observability/vnc-cred-tool.py" \
    decode --hex "${HEX}" --wordlist "${WORDLIST}" \
    | tee "${OUT}/recovered.txt"

if ! grep -qx "${PASSWORD}" "${OUT}/recovered.txt"; then
    die "round-trip failed: expected '${PASSWORD}', got '$(cat "${OUT}/recovered.txt")'"
fi

log "Note: alerts.json injection from manager-side requires a real EWS"
log "agent ship event with location='C:\\Users\\Public\\vnc-pwd-dump.txt'."
log "wazuh-logtest exercises the same decoder + rule chain and is the"
log "authoritative offline proof here."

log "PROOF COMPLETE"
log "  password : ${PASSWORD}"
log "  hex blob : ${HEX}"
log "  rule     : 100806 (level 12)"
log "  recovered: $(cat "${OUT}/recovered.txt")"
log "  artefacts:"
for f in event.json full_log.txt logtest.txt alert.json recovered.txt; do
    if [[ -f "${OUT}/${f}" ]]; then
        log "    - ${OUT}/${f}"
    fi
done
