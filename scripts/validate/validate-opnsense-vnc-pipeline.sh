#!/usr/bin/env bash
# End-to-end validator for the OPNsense VNC analyst-challenge pipeline.
#
# Pass = every assertion in results.txt is PASS. Fail = exit 1 with a
# results.txt that names the failed assertion(s).
#
# Two operating modes:
#   (A) Standalone: re-run the orchestrator to produce a fresh dataset,
#       then assert on it.
#         ./scripts/validate/validate-opnsense-vnc-pipeline.sh \
#             --run-id ews-opnsense-vnc-$(date -u +%Y%m%dT%H%M%SZ) \
#             --target 192.168.61.20
#
#   (B) Post-hoc: assert on an existing run-id (or explicit pcap +
#       alerts file). Used by --validate inside opnsense-vnc-challenge.sh.
#         ./scripts/validate/validate-opnsense-vnc-pipeline.sh \
#             --run-id <existing>
#         ./scripts/validate/validate-opnsense-vnc-pipeline.sh \
#             --pcap <path> --alerts <path> --wordlist <path>
#
# Assertions:
#   1.  pcap captured >= 40 RFB security_type=2 attempts
#   2.  pcap has exactly 1 SecurityResult=0 (success)
#   3.  pcap has >= 35 SecurityResult=1 (failures)
#   4.  successful (challenge, response) decodes to expected password
#   5.  Arkime indexed the session (>= 1 doc at dest.port=5900 over window)
#   6.  Wazuh rule 100810 fired (Suricata burst SID 2400001)
#   7.  Wazuh rule 100811 fired (Suricata failed-auth SID 2400002)
#   8.  Wazuh rule 100812 fired (velocity correlator)
#   9.  Wazuh rule 100816 fired (Suricata success SID 2400003)
#  10.  Wazuh rule 100813 fired (failed-auth burst then success)
#  11.  Wazuh rule 100815 fired (pf filterlog VNC burst)
#  12.  Wazuh rule 100804 fired (file create vnc-pwd-dump receipt)
#  13.  Wazuh rule 100805 fired (audit registry read on VNC password key)
#  14.  Wazuh rule 100806 fired (hex blob exfil receipt)
#  15.  Wazuh rule 100807 fired (velocity correlator)
#
# Required env (.env auto-sourced):
#   PROXMOX_HOST, PROXMOX_PASSWORD   (alerts pull, Arkime query via jump)
#   OPNSENSE_SSH_PASSWORD            (orchestrator dependency)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

RUN_ID=""
PCAP=""
ALERTS=""
WORDLIST=""
EXPECTED_PASSWORD="FELDTECH_VNC"
TARGET=""
DO_RUN_ORCHESTRATOR=0
declare -a ORCH_PASSTHRU

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id)             RUN_ID="$2"; shift 2 ;;
        --pcap)               PCAP="$2"; shift 2 ;;
        --alerts)             ALERTS="$2"; shift 2 ;;
        --wordlist)           WORDLIST="$2"; shift 2 ;;
        --expected-password)  EXPECTED_PASSWORD="$2"; shift 2 ;;
        --target)             TARGET="$2"; DO_RUN_ORCHESTRATOR=1; ORCH_PASSTHRU+=("$1" "$2"); shift 2 ;;
        --run-orchestrator)   DO_RUN_ORCHESTRATOR=1; shift ;;
        -h|--help)            sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                    ORCH_PASSTHRU+=("$1"); shift ;;
    esac
done

# Default wordlist resolution.
if [ -z "${WORDLIST}" ]; then
    for c in \
        "${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt" \
        /usr/share/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt; do
        if [ -f "$c" ]; then WORDLIST="$c"; break; fi
    done
fi

# Optionally run the orchestrator first.
if [ "${DO_RUN_ORCHESTRATOR}" -eq 1 ]; then
    if [ -z "${RUN_ID}" ]; then
        RUN_ID="opnsense-vnc-validate-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    echo "[*] Running orchestrator: scripts/observability/opnsense-vnc-challenge.sh --run-id ${RUN_ID}"
    "${REPO_ROOT}/scripts/observability/opnsense-vnc-challenge.sh" \
        --run-id "${RUN_ID}" \
        --wordlist "${WORDLIST}" \
        "${ORCH_PASSTHRU[@]}" \
        || { echo "[!] orchestrator failed (rc=$?)" >&2; exit 1; }
fi

if [ -z "${RUN_ID}" ] && [ -n "${PCAP}" ]; then
    RUN_ID="opnsense-vnc-validate-$(date -u +%Y%m%dT%H%M%SZ)"
fi
if [ -z "${RUN_ID}" ]; then
    # Pick the most-recent run dir.
    LATEST="$(find "${REPO_ROOT}/artifacts/opnsense-vnc" -mindepth 1 -maxdepth 1 -type d \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}')"
    [ -n "${LATEST}" ] || { echo "[!] no run-id and no artifacts found" >&2; exit 2; }
    RUN_ID="$(basename "${LATEST}")"
    echo "[*] auto-resolved run-id: ${RUN_ID}"
fi

RUN_DIR="${REPO_ROOT}/artifacts/opnsense-vnc/${RUN_ID}"
OUT_DIR="${REPO_ROOT}/artifacts/opnsense-vnc/validate-${RUN_ID}"
mkdir -p "${OUT_DIR}"

[ -z "${PCAP}" ]   && PCAP="${RUN_DIR}/opnsense-mirror.pcap"
[ -z "${ALERTS}" ] && ALERTS="${RUN_DIR}/alerts-during-window.json"

RESULTS="${OUT_DIR}/results.txt"
SUMMARY="${OUT_DIR}/summary.json"
INDEX="${OUT_DIR}/INDEX.md"
: > "${RESULTS}"

FAILED=0
PASSED=0
declare -a ROWS

record() {
    # record <PASS|FAIL> <id> <description>
    local status="$1"; local id="$2"; shift 2
    local desc="$*"
    printf '%s  #%02d  %s\n' "${status}" "${id}" "${desc}" | tee -a "${RESULTS}"
    if [ "${status}" = "PASS" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    ROWS+=("${status}|${id}|${desc}")
}

step() { printf '\n[*] %s\n' "$*"; }

step "Validating run-id=${RUN_ID}"
echo "    pcap   : ${PCAP}"
echo "    alerts : ${ALERTS}"
echo "    expect : ${EXPECTED_PASSWORD}"
echo "    out    : ${OUT_DIR}"

# ------------------------------------------------------------ PCAP tests
if [ ! -s "${PCAP}" ]; then
    record FAIL 1  "pcap missing/empty at ${PCAP}"
    record FAIL 2  "pcap missing -- skipping security_result==0 check"
    record FAIL 3  "pcap missing -- skipping security_result==1 check"
    record FAIL 4  "pcap missing -- skipping decode"
else
    if ! command -v tshark >/dev/null 2>&1; then
        record FAIL 1  "tshark not on PATH; cannot count RFB attempts"
        record FAIL 2  "tshark not on PATH"
        record FAIL 3  "tshark not on PATH"
        record FAIL 4  "tshark not on PATH"
    else
        ATTEMPTS_FILE="${OUT_DIR}/tshark-attempts.txt"
        RESULTS_FILE="${OUT_DIR}/tshark-results.txt"
        SUCCESS_PAIR_FILE="${OUT_DIR}/tshark-success-pair.txt"

        tshark -r "${PCAP}" -Y 'vnc.security_type == 2' \
            -T fields -e frame.number -e ip.src -e ip.dst -e vnc.security_type \
            > "${ATTEMPTS_FILE}" 2>/dev/null || true
        ATTEMPT_COUNT="$(wc -l < "${ATTEMPTS_FILE}")"
        if [ "${ATTEMPT_COUNT}" -ge 40 ]; then
            record PASS 1  "OPNsense pcap captured ${ATTEMPT_COUNT} RFB security_type=2 attempts (>= 40)"
        else
            record FAIL 1  "OPNsense pcap captured ${ATTEMPT_COUNT} RFB security_type=2 attempts (< 40)"
        fi

        # Pull (frame, challenge, response, security_result) rows.
        tshark -r "${PCAP}" -Y 'vnc' \
            -T fields -e frame.number -e ip.src -e ip.dst \
                       -e vnc.auth_challenge -e vnc.auth_response \
                       -e vnc.security_result \
            > "${RESULTS_FILE}" 2>/dev/null || true

        SUCCESS_COUNT="$(awk -F'\t' '$6=="0"' "${RESULTS_FILE}" | wc -l)"
        FAIL_COUNT="$(awk -F'\t' '$6=="1"' "${RESULTS_FILE}" | wc -l)"

        if [ "${SUCCESS_COUNT}" -eq 1 ]; then
            record PASS 2  "pcap contains exactly 1 SecurityResult=0 (successful auth)"
        else
            record FAIL 2  "pcap has ${SUCCESS_COUNT} SecurityResult=0 frames (expected exactly 1)"
        fi

        if [ "${FAIL_COUNT}" -ge 35 ]; then
            record PASS 3  "pcap contains ${FAIL_COUNT} SecurityResult=1 (>= 35)"
        else
            record FAIL 3  "pcap contains ${FAIL_COUNT} SecurityResult=1 (< 35)"
        fi

        # Successful pair extraction: the SecurityResult==0 row carries
        # vnc.security_result; the (challenge, response) we want is the
        # row IMMEDIATELY BEFORE it in stream order, which is the row
        # that carried vnc.auth_response. Save both rows for evidence.
        awk -F'\t' '$6=="0"{print prev; print $0; exit} {prev=$0}' "${RESULTS_FILE}" \
            > "${SUCCESS_PAIR_FILE}"

        CHAL_HEX="$(awk -F'\t' 'NR==1 {print $4}' "${SUCCESS_PAIR_FILE}")"
        RESP_HEX="$(awk -F'\t' 'NR==1 {print $5}' "${SUCCESS_PAIR_FILE}")"

        # Some tshark versions emit ':' separated hex; cred-tool accepts both.
        if [ -z "${CHAL_HEX}" ] || [ -z "${RESP_HEX}" ]; then
            record FAIL 4  "could not extract (challenge, response) pair of the successful auth"
            : > "${OUT_DIR}/recovered-from-pcap.txt"
        else
            RECOVERED="$(python3 "${REPO_ROOT}/scripts/observability/vnc-cred-tool.py" crack \
                --challenge "${CHAL_HEX}" \
                --response  "${RESP_HEX}" \
                --wordlist  "${WORDLIST}" 2>"${OUT_DIR}/cred-tool.err")"
            echo "${RECOVERED}" > "${OUT_DIR}/recovered-from-pcap.txt"
            if [ "${RECOVERED}" = "${EXPECTED_PASSWORD}" ]; then
                record PASS 4  "successful (chal, resp) decodes to '${EXPECTED_PASSWORD}'"
            else
                record FAIL 4  "decode returned '${RECOVERED}' (expected '${EXPECTED_PASSWORD}')"
            fi
        fi
    fi
fi

# ------------------------------------------------------------ Arkime
ARKIME_HOST="${ARKIME_HOST:-192.168.61.11}"
PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
ARKIME_COUNT_JSON="${OUT_DIR}/arkime-session-count.json"

if [ -n "${PROXMOX_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS_BIN="$(command -v sshpass)"
    # Hit Arkime's OpenSearch through the Proxmox jump.
    if "${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" ssh \
        -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o LogLevel=ERROR \
        "root@${PROXMOX_HOST}" \
        "curl -fsS 'http://${ARKIME_HOST}:9201/arkime_sessions3-*/_count?q=destination.port:5900' || curl -fsS 'http://${ARKIME_HOST}:9201/sessions3-*/_count?q=destination.port:5900'" \
        > "${ARKIME_COUNT_JSON}" 2>"${OUT_DIR}/arkime-query.err"; then
        ARK_COUNT="$(jq -r '.count // 0' "${ARKIME_COUNT_JSON}" 2>/dev/null || echo 0)"
        if [ "${ARK_COUNT}" -ge 1 ]; then
            record PASS 5  "Arkime indexed ${ARK_COUNT} session(s) at destination.port=5900"
        else
            record FAIL 5  "Arkime returned 0 sessions at destination.port=5900"
        fi
    else
        record FAIL 5  "Arkime _count query failed (see ${OUT_DIR}/arkime-query.err)"
    fi
else
    record FAIL 5  "PROXMOX_PASSWORD/sshpass missing; cannot query Arkime"
fi

# ------------------------------------------------------------ Wazuh rules
ALERTS_JSON="${ALERTS}"
if [ ! -s "${ALERTS_JSON}" ]; then
    # No alerts slice was captured (orchestrator may have skipped); rules will all fail.
    cat > "${ALERTS_JSON}" <<EOF
EOF
fi

if ! command -v jq >/dev/null 2>&1; then
    for rid in 100810 100811 100812 100816 100813 100815 100804 100805 100806 100807; do
        record FAIL 0  "jq not installed; cannot count rule ${rid}"
    done
else
    # rule_test <id> <pass-criterion-expr> <description>
    rule_test() {
        local rid="$1"; local pass_expr="$2"; local desc="$3"
        local n
        n="$(jq -c "select(.rule.id==\"${rid}\")" "${ALERTS_JSON}" 2>/dev/null | wc -l)"
        echo "${n}" > "${OUT_DIR}/wazuh-rule-${rid}-count.txt"
        local local_idx=$((6 + COUNTER))
        COUNTER=$((COUNTER + 1))
        if eval "[ ${n} ${pass_expr} ]"; then
            record PASS "${local_idx}" "Wazuh rule ${rid} fired ${n}x -- ${desc}"
        else
            record FAIL "${local_idx}" "Wazuh rule ${rid} fired ${n}x -- ${desc}"
        fi
    }
    COUNTER=0
    rule_test 100810 ">= 1"                    "Suricata SID 2400001 (VNC connection burst)"
    rule_test 100811 ">= 1"                    "Suricata SID 2400002 (failed-auth burst)"
    rule_test 100812 ">= 1"                    "velocity correlator (100810 + 100811 same src)"
    rule_test 100816 ">= 1"                    "Suricata SID 2400003 (successful auth)"
    rule_test 100813 ">= 1"                    "fail-then-success correlator (100811 + 100816 same src)"
    rule_test 100815 ">= 1"                    "pf filterlog (>= 20 pf-pass to 5900 / 60s)"
    rule_test 100804 ">= 1"                    "EID 11 vnc-pwd-dump file create"
    rule_test 100805 ">= 1"                    "EID 4663 audited read on VNC password key"
    rule_test 100806 ">= 1"                    "hex blob exfil receipt"
    rule_test 100807 ">= 1"                    "endpoint chain correlator"
fi

# ------------------------------------------------------------ EVE slice (informational)
EVE_SLICE="${OUT_DIR}/suricata-eve-during-window.json"
if command -v jq >/dev/null 2>&1 && [ -s "${ALERTS_JSON}" ]; then
    jq -c 'select(.decoder.name=="json" and (.full_log // "" | test("\"event_type\":\"alert\""))) | .full_log' \
        "${ALERTS_JSON}" 2>/dev/null > "${EVE_SLICE}" || true
fi

# ------------------------------------------------------------ EVIDENCE PACK + SUMMARY
TOTAL=$((PASSED + FAILED))

cat > "${SUMMARY}" <<JSON
{
  "run_id":           "${RUN_ID}",
  "validate_at_utc":  "$(date -u +%FT%TZ)",
  "pcap":             "${PCAP}",
  "alerts":           "${ALERTS_JSON}",
  "wordlist":         "${WORDLIST}",
  "expected_password":"${EXPECTED_PASSWORD}",
  "passed":           ${PASSED},
  "failed":           ${FAILED},
  "total":            ${TOTAL},
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
# Validate OPNsense VNC pipeline -- ${RUN_ID}

Generated by \`scripts/validate/validate-opnsense-vnc-pipeline.sh\` on
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

## Evidence pack

| File | Purpose |
| --- | --- |
| results.txt              | PASS/FAIL table (above) |
| summary.json             | machine-readable mirror of results.txt |
| INDEX.md                 | this file |
| tshark-attempts.txt      | all vnc.security_type==2 frames |
| tshark-results.txt       | all vnc rows with chal/resp/result |
| tshark-success-pair.txt  | (challenge, response) of the successful auth |
| recovered-from-pcap.txt  | must read \`${EXPECTED_PASSWORD}\` |
| arkime-session-count.json| arkime _count response (dest.port=5900) |
| wazuh-rule-XXXXXX-count.txt | per-rule hit count |
| suricata-eve-during-window.json | EVE slice carried via manager alerts.json |

## Run inputs

| Path | Source |
| --- | --- |
| pcap     | ${PCAP} |
| alerts   | ${ALERTS_JSON} |
| wordlist | ${WORDLIST} |

## Failure-mode advice

If any assertion failed, see the troubleshoot table in
[\`docs/runbooks/opnsense-vnc-brute-analyst-challenge.md\`](../../docs/runbooks/opnsense-vnc-brute-analyst-challenge.md)
"Troubleshoot (failure mode table)".
EOF

step "Result: ${PASSED} PASS, ${FAILED} FAIL, total ${TOTAL}"
echo "    results.txt : ${RESULTS}"
echo "    summary.json: ${SUMMARY}"
echo "    INDEX.md    : ${INDEX}"

if [ "${FAILED}" -ne 0 ]; then
    echo
    echo "[!] VALIDATOR FAILED -- ${FAILED} of ${TOTAL} assertions failed"
    exit 1
fi

echo
echo "[+] VALIDATOR PASSED -- all ${TOTAL} assertions PASS"
exit 0
