#!/usr/bin/env bash
# Acceptance test for the vnc-public-attack pipeline.
#
# Five assertions, all of which must PASS for exit 0:
#   1. pcap file exists and is non-trivial (> 24 bytes, the empty header)
#   2. >= 40 RFB attempts (auth_response frames) in the pcap
#   3. exactly 1 successful auth (vnc.auth_result == 0 / False)
#   4. successful (challenge, response) pair decodes to FELDTECH_VNC
#   5. crit-capture Arkime indexed the session (>= 1 doc at dest.port=5900)
#
# Writes evidence under artifacts/ews/vnc-public-attack/validate-<run-id>/:
#   results.txt              PASS/FAIL table (line per assertion)
#   summary.json             machine-readable mirror
#   INDEX.md                 human-readable summary
#   recovered-from-pcap.txt  what the crack actually returned
#   arkime-session-count.json  raw arkime _count response
#
# Usage:
#   ./scripts/validate/validate-vnc-public-attack.sh --run-id <id>
#   ./scripts/validate/validate-vnc-public-attack.sh --pcap PATH [--wordlist PATH]
#   ./scripts/validate/validate-vnc-public-attack.sh
#       # auto-picks the most recent run-id under
#       # artifacts/ews/vnc-public-attack/

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/lib/load_repo_env.sh
. "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}"

RUN_ID=""
PCAP=""
WORDLIST=""
EXPECTED_PASSWORD="FELDTECH_VNC"
EXPECTED_MIN_ATTEMPTS=40
EXPECTED_SUCCESS=1
ARKIME_HOST="${ARKIME_HOST:-192.168.61.11}"
PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id)              RUN_ID="$2"; shift 2 ;;
        --pcap)                PCAP="$2"; shift 2 ;;
        --wordlist)            WORDLIST="$2"; shift 2 ;;
        --expected-password)   EXPECTED_PASSWORD="$2"; shift 2 ;;
        --expected-min-attempts) EXPECTED_MIN_ATTEMPTS="$2"; shift 2 ;;
        --arkime-host)         ARKIME_HOST="$2"; shift 2 ;;
        -h|--help)             sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                     echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Resolve pcap: explicit --pcap wins; else --run-id wins; else latest run-id.
if [ -z "${PCAP}" ]; then
    if [ -z "${RUN_ID}" ]; then
        ROOT="${REPO_ROOT}/artifacts/ews/vnc-public-attack"
        if [ -d "${ROOT}" ]; then
            RUN_ID="$(find "${ROOT}" -mindepth 1 -maxdepth 1 -type d \
                -not -name 'validate-*' \
                -printf '%T@ %f\n' 2>/dev/null \
                | sort -nr | head -n1 | awk '{print $2}')"
        fi
    fi
    [ -n "${RUN_ID}" ] || { echo "[!] no run-id and no --pcap; nothing to validate" >&2; exit 2; }
    PCAP="${REPO_ROOT}/artifacts/ews/vnc-foothold/${RUN_ID}/vnc_auth.pcap"
fi

if [ -z "${RUN_ID}" ]; then
    RUN_ID="vnc-public-attack-validate-$(date -u +%Y%m%dT%H%M%SZ)"
fi

if [ -z "${WORDLIST}" ]; then
    for c in \
        "${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt" \
        /usr/share/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt; do
        if [ -f "$c" ]; then WORDLIST="$c"; break; fi
    done
fi

OUT_DIR="${REPO_ROOT}/artifacts/ews/vnc-public-attack/validate-${RUN_ID}"
mkdir -p "${OUT_DIR}"
RESULTS="${OUT_DIR}/results.txt"
SUMMARY="${OUT_DIR}/summary.json"
INDEX="${OUT_DIR}/INDEX.md"
: > "${RESULTS}"

PASSED=0
FAILED=0
declare -a ROWS

record() {
    # record <PASS|FAIL> <id> <description>
    local status="$1"; local id="$2"; shift 2
    local desc="$*"
    printf '%s  #%d  %s\n' "${status}" "${id}" "${desc}" | tee -a "${RESULTS}"
    if [ "${status}" = "PASS" ]; then PASSED=$((PASSED + 1)); else FAILED=$((FAILED + 1)); fi
    ROWS+=("${status}|${id}|${desc}")
}

step() { printf '\n[*] %s\n' "$*"; }

step "Validating vnc-public-attack"
echo "    run_id  : ${RUN_ID}"
echo "    pcap    : ${PCAP}"
echo "    wordlist: ${WORDLIST:-(none)}"
echo "    out_dir : ${OUT_DIR}"

# ------------------------------------------------------------ TSHARK BIN
TSHARK_BIN="$(command -v tshark 2>/dev/null || true)"
tshark_run() {
    if [ -n "${TSHARK_BIN}" ]; then
        "${TSHARK_BIN}" "$@"
    elif command -v nix >/dev/null 2>&1; then
        nix shell nixpkgs#wireshark-cli --command tshark "$@"
    else
        return 127
    fi
}

# ------------------------------------------------------------ ASSERTION 1
if [ -s "${PCAP}" ]; then
    bytes="$(stat -c '%s' "${PCAP}" 2>/dev/null || stat -f '%z' "${PCAP}" 2>/dev/null || echo 0)"
    if [ "${bytes}" -gt 24 ]; then
        record PASS 1  "pcap exists, ${bytes} bytes (> 24 = file header only) at ${PCAP}"
    else
        record FAIL 1  "pcap exists but is only ${bytes} bytes (looks like an empty pcap header)"
    fi
else
    record FAIL 1  "pcap missing/empty at ${PCAP}"
fi

# ------------------------------------------------------------ ASSERTION 2
ATTEMPT_COUNT=0
if [ -s "${PCAP}" ]; then
    ATTEMPT_COUNT="$(tshark_run -r "${PCAP}" -Y 'vnc.auth_response' \
        -T fields -e frame.number 2>/dev/null | wc -l)"
fi
echo "${ATTEMPT_COUNT}" > "${OUT_DIR}/attempt-count.txt"
if [ "${ATTEMPT_COUNT}" -ge "${EXPECTED_MIN_ATTEMPTS}" ]; then
    record PASS 2  "pcap has ${ATTEMPT_COUNT} RFB auth_response frames (>= ${EXPECTED_MIN_ATTEMPTS})"
else
    record FAIL 2  "pcap has ${ATTEMPT_COUNT} RFB auth_response frames (< ${EXPECTED_MIN_ATTEMPTS})"
fi

# ------------------------------------------------------------ ASSERTION 3
# Use the FIRST vnc.auth_result frame per stream as the canonical server reply.
# (TightVNC sends a reason-string after the 4-byte result on failure; tshark
# re-parses parts of that string as additional vnc.auth_result frames, so a
# naive `vnc.auth_result == 0` filter double-counts failed streams. Counting
# the first frame per stream sidesteps this dissector quirk and works for
# RealVNC, TightVNC, TigerVNC, and TurboVNC pcaps alike.)
SUCCESS_COUNT=0
FAIL_AUTH_COUNT=0
if [ -s "${PCAP}" ]; then
    AR_TSV="${OUT_DIR}/.auth-results.tsv"
    tshark_run -r "${PCAP}" -Y 'vnc.auth_result' \
        -T fields -e tcp.stream -e vnc.auth_result \
        -E separator=/t 2>/dev/null > "${AR_TSV}"
    read -r SUCCESS_COUNT FAIL_AUTH_COUNT < <(python3 - "${AR_TSV}" <<'PY'
import sys
seen = {}
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 2:
        continue
    sid, res = parts[0].strip(), parts[1].strip().lower()
    if not sid:
        continue
    seen.setdefault(sid, res)
s = sum(1 for v in seen.values() if v in ("0", "false"))
f = sum(1 for v in seen.values() if v in ("1", "true"))
print(s, f)
PY
)
    SUCCESS_COUNT=${SUCCESS_COUNT:-0}
    FAIL_AUTH_COUNT=${FAIL_AUTH_COUNT:-0}
fi
if [ "${SUCCESS_COUNT}" -eq "${EXPECTED_SUCCESS}" ]; then
    record PASS 3  "pcap has exactly ${SUCCESS_COUNT} successful auth (auth_result==0), ${FAIL_AUTH_COUNT} failures"
else
    record FAIL 3  "pcap has ${SUCCESS_COUNT} successful auths (expected ${EXPECTED_SUCCESS}); ${FAIL_AUTH_COUNT} failures"
fi

# ------------------------------------------------------------ ASSERTION 4
RECOVERED=""
RECOVERED_FILE="${OUT_DIR}/recovered-from-pcap.txt"
: > "${RECOVERED_FILE}"

if [ "${SUCCESS_COUNT}" -ge 1 ] && [ -s "${PCAP}" ] && [ -n "${WORDLIST}" ] && [ -f "${WORDLIST}" ]; then
    # Build a per-stream rollup just like vnc-pcap-analyze does, isolated
    # to find the chal+resp of the successful stream.
    RAW="${OUT_DIR}/.raw.tsv"
    tshark_run -r "${PCAP}" -Y vnc \
        -T fields -e tcp.stream -e vnc.auth_challenge \
                  -e vnc.auth_response -e vnc.auth_result \
        -E separator=/t \
        > "${RAW}" 2>/dev/null

    read -r CHAL RESP < <(python3 - "${RAW}" <<'PY'
import sys
rows = [ln.rstrip("\n").split("\t") for ln in open(sys.argv[1])]
streams = {}
first_result_per_stream = {}
for r in rows:
    while len(r) < 4: r.append("")
    sid, chal, resp, result = r
    if not sid: continue
    s = streams.setdefault(sid, {"chal": "", "resp": ""})
    if chal: s["chal"] = chal
    if resp: s["resp"] = resp
    # Only the FIRST vnc.auth_result frame in each stream is the actual server
    # reply; subsequent ones are tshark mis-decoding the reason string.
    if result and sid not in first_result_per_stream:
        first_result_per_stream[sid] = result.strip().lower()
success_stream = next(
    (sid for sid, res in first_result_per_stream.items() if res in ("0", "false")),
    None,
)
if success_stream and streams.get(success_stream, {}).get("chal") and streams[success_stream].get("resp"):
    print(streams[success_stream]["chal"], streams[success_stream]["resp"])
PY
)
    rm -f "${RAW}"

    if [ -z "${CHAL}" ] || [ -z "${RESP}" ]; then
        record FAIL 4  "could not extract (challenge, response) pair of the successful auth"
    else
        echo "${CHAL} ${RESP}" > "${OUT_DIR}/success-pair.txt"
        CRED_TOOL="${REPO_ROOT}/scripts/observability/vnc-cred-tool.py"
        if python3 -c 'import cryptography' >/dev/null 2>&1; then
            RECOVERED="$(python3 "${CRED_TOOL}" crack \
                --challenge "${CHAL}" --response "${RESP}" \
                --wordlist "${WORDLIST}" 2>"${OUT_DIR}/crack.err")"
        elif command -v nix >/dev/null 2>&1; then
            RECOVERED="$(nix develop "${REPO_ROOT}" --command \
                python3 "${CRED_TOOL}" crack \
                --challenge "${CHAL}" --response "${RESP}" \
                --wordlist "${WORDLIST}" 2>"${OUT_DIR}/crack.err" \
                | grep -v '^\[secretcon\]' | grep -v '^warning:' | tail -n1)"
        fi
        printf '%s\n' "${RECOVERED}" > "${RECOVERED_FILE}"
        if [ "${RECOVERED}" = "${EXPECTED_PASSWORD}" ]; then
            record PASS 4  "successful (chal, resp) decodes to '${EXPECTED_PASSWORD}'"
        else
            record FAIL 4  "decode returned '${RECOVERED:-<empty>}' (expected '${EXPECTED_PASSWORD}')"
        fi
    fi
else
    if [ "${SUCCESS_COUNT}" -eq 0 ]; then
        record FAIL 4  "no successful auth in pcap; nothing to crack"
    elif [ -z "${WORDLIST}" ] || [ ! -f "${WORDLIST}" ]; then
        record FAIL 4  "wordlist not found; pass --wordlist"
    fi
fi

# ------------------------------------------------------------ ASSERTION 5
ARKIME_COUNT_JSON="${OUT_DIR}/arkime-session-count.json"
ARK_COUNT=0
if [ -n "${PROXMOX_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS_BIN="$(command -v sshpass)"
    # Use the Proxmox host as a jump so the bare-network ARKIME_HOST is
    # reachable even without wg-ctf up.
    if "${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" ssh \
        -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o LogLevel=ERROR \
        "root@${PROXMOX_HOST}" \
        "curl -fsS 'http://${ARKIME_HOST}:9201/arkime_sessions3-*/_count?q=destination.port:5900' \
            || curl -fsS 'http://${ARKIME_HOST}:9201/sessions3-*/_count?q=destination.port:5900' \
            || curl -fsS 'http://${ARKIME_HOST}:9200/arkime_sessions3-*/_count?q=destination.port:5900'" \
        > "${ARKIME_COUNT_JSON}" 2>"${OUT_DIR}/arkime-query.err"; then
        ARK_COUNT="$(jq -r '.count // 0' "${ARKIME_COUNT_JSON}" 2>/dev/null || echo 0)"
        if [ "${ARK_COUNT}" -ge 1 ]; then
            record PASS 5  "crit-capture Arkime indexed ${ARK_COUNT} session(s) at destination.port=5900"
        else
            record FAIL 5  "crit-capture Arkime returned 0 sessions at destination.port=5900"
        fi
    else
        record FAIL 5  "arkime _count query failed (see ${OUT_DIR}/arkime-query.err)"
    fi
else
    record FAIL 5  "PROXMOX_PASSWORD or sshpass missing; cannot query crit-capture Arkime"
fi

# ------------------------------------------------------------ WRITE SUMMARY
TOTAL=$((PASSED + FAILED))
cat > "${SUMMARY}" <<JSON
{
  "run_id":             "${RUN_ID}",
  "validate_at_utc":    "$(date -u +%FT%TZ)",
  "pcap":               "${PCAP}",
  "wordlist":           "${WORDLIST}",
  "expected_password":  "${EXPECTED_PASSWORD}",
  "attempt_count":      ${ATTEMPT_COUNT},
  "successful_count":   ${SUCCESS_COUNT},
  "failed_count":       ${FAIL_AUTH_COUNT},
  "recovered_password": "${RECOVERED}",
  "arkime_session_count": ${ARK_COUNT},
  "passed":             ${PASSED},
  "failed":             ${FAILED},
  "total":              ${TOTAL},
  "assertions": [
$(for i in "${!ROWS[@]}"; do
    IFS='|' read -r status id desc <<< "${ROWS[$i]}"
    sep=","; [ "$i" -eq $((${#ROWS[@]} - 1)) ] && sep=""
    printf '    {"id": %d, "status": "%s", "description": "%s"}%s\n' \
        "${id}" "${status}" "$(printf '%s' "${desc}" | sed 's/"/\\"/g')" "${sep}"
done)
  ]
}
JSON

cat > "${INDEX}" <<EOF
# Validate vnc-public-attack -- ${RUN_ID}

Generated by \`scripts/validate/validate-vnc-public-attack.sh\` on
$(date -u +%FT%TZ).

## Result

| | |
| --- | --- |
| PASS  | ${PASSED} |
| FAIL  | ${FAILED} |
| TOTAL | ${TOTAL} |

Overall: $([ "${FAILED}" -eq 0 ] && echo PASS || echo FAIL)

## Assertions

\`\`\`
$(cat "${RESULTS}")
\`\`\`

## Evidence

| File | Purpose |
| --- | --- |
| results.txt              | PASS/FAIL table (above) |
| summary.json             | machine-readable mirror |
| INDEX.md                 | this file |
| attempt-count.txt        | tshark count of vnc.auth_response frames |
| success-pair.txt         | \`<challenge_hex> <response_hex>\` of the success |
| recovered-from-pcap.txt  | must read \`${EXPECTED_PASSWORD}\` |
| arkime-session-count.json| arkime _count response (dest.port=5900) |

## Inputs

| Path | Source |
| --- | --- |
| pcap     | ${PCAP} |
| wordlist | ${WORDLIST:-(none)} |
EOF

step "Result: ${PASSED} PASS, ${FAILED} FAIL"
echo "    results : ${RESULTS}"
echo "    summary : ${SUMMARY}"
echo "    INDEX   : ${INDEX}"

if [ "${FAILED}" -ne 0 ]; then
    echo
    echo "[!] VALIDATOR FAILED -- ${FAILED} of ${TOTAL} assertions failed"
    exit 1
fi

echo
echo "[+] VALIDATOR PASSED -- all ${TOTAL} assertions PASS"
exit 0
