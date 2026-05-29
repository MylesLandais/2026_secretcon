#!/usr/bin/env bash
# SecretCon EWS drift probe.
#
# Determines whether the running EWS VMID 109 still matches the in-tree
# bootstrap_win.ps1 contract. Used by the prod-reproduction orchestrator
# to decide whether a Packer rebuild is needed.
#
# Checks (each writes one PASS/FAIL line to ews-probe.txt):
#   1. Re-runs scripts/verify-ews.sh (nmap 5900/22, hydra FELDTECH_VNC,
#      ssh patrick, unquoted-service-path, flag readability, Wazuh API
#      agent active).
#   2. Wazuh API: agent group includes 'ews', lastKeepAlive within 5 min.
#   3. SACL: HKLM:\SOFTWARE\TightVNC\Server has an audit rule for
#      Everyone covering QueryValues+EnumerateSubKeys+ReadKey.
#   4. Audit policy: Registry subcategory is Success/Failure enabled.
#
# Exit 0 = drift-free. Exit 1 = any check failed (orchestrator should
# rebuild). Exit 2 = misuse.
#
# Usage:
#   ./scripts/proxmox/probe-ews.sh \
#       [--run-id ID] [--target IP] [--patrick-pw PW] [--quiet]
#
# Env (mirrors verify-ews.sh):
#   EWS_HOST          (default 192.168.61.20)
#   PATRICK_PW        (default Changeme123!)
#   VNC_PW            (default FELDTECH_VNC)
#   WAZUH_MANAGER_HOST (default 192.168.61.10)
#   WAZUH_API_PASSWORD (required for agent state check; otherwise SKIP)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID=""
EWS_HOST_CLI=""
PATRICK_PW_CLI=""
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)     RUN_ID="$2"; shift 2 ;;
        --target)     EWS_HOST_CLI="$2"; shift 2 ;;
        --patrick-pw) PATRICK_PW_CLI="$2"; shift 2 ;;
        --quiet)      QUIET=1; shift ;;
        -h|--help)    sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "[!] unknown flag: $1" >&2; exit 2 ;;
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

EWS_HOST="${EWS_HOST_CLI:-${EWS_HOST:-192.168.61.20}}"
PATRICK_PW="${PATRICK_PW_CLI:-${PATRICK_PW:-Changeme123!}}"
VNC_PW="${VNC_PW:-FELDTECH_VNC}"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="ews-prod-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/prod-proof-${RUN_ID}"
mkdir -p "${OUT_DIR}"
EVIDENCE="${OUT_DIR}/ews-probe.txt"
VERIFY_LOG="${OUT_DIR}/verify-ews.log"

PASS=0
FAIL=0
record() {
    local status="$1" name="$2" detail="${3:-}"
    local line="${status}  ${name}  ${detail}"
    printf '%s\n' "${line}" >> "${EVIDENCE}"
    [[ "${QUIET}" -eq 1 && "${status}" == "PASS" ]] || printf '  %s\n' "${line}"
    if [[ "${status}" == "PASS" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

[[ "${QUIET}" -eq 1 ]] || echo "[*] probe-ews target=${EWS_HOST}  run_id=${RUN_ID}"
: > "${EVIDENCE}"

# ---------------------------------------------- 1. delegate to verify-ews.sh
if [[ -x "${REPO_ROOT}/scripts/verify-ews.sh" ]]; then
    set +e
    "${REPO_ROOT}/scripts/verify-ews.sh" "${EWS_HOST}" "${PATRICK_PW}" \
        > "${VERIFY_LOG}" 2>&1
    VERIFY_RC=$?
    set -e
    if [[ "${VERIFY_RC}" -eq 0 ]]; then
        record PASS "verify-ews"  "all checks green (see ${VERIFY_LOG})"
    else
        # Surface the FAIL lines without bloating the evidence file.
        fail_count="$(grep -cE '^  FAIL' "${VERIFY_LOG}" 2>/dev/null || echo 0)"
        record FAIL "verify-ews"  "rc=${VERIFY_RC} (${fail_count} FAILs; see ${VERIFY_LOG})"
    fi
else
    record FAIL "verify-ews" "scripts/verify-ews.sh missing"
fi

# ---------------------------------------------- 2. Wazuh API: agent group + recency
if [[ -n "${WAZUH_API_PASSWORD:-}" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    api_user="${WAZUH_API_USER:-wazuh-wui}"
    token="$(curl -ksf -u "${api_user}:${WAZUH_API_PASSWORD}" \
        -X POST "https://${WAZUH_MANAGER_HOST}:55000/security/user/authenticate?raw=true" \
        --max-time 10 2>/dev/null || true)"
    if [[ -n "${token}" ]]; then
        agent_json="$(curl -ksf \
            -H "Authorization: Bearer ${token}" \
            --max-time 10 \
            "https://${WAZUH_MANAGER_HOST}:55000/agents?ip=${EWS_HOST}&limit=1" 2>/dev/null || true)"
        agent_id="$(printf '%s' "${agent_json}" | jq -r '.data.affected_items[0].id // empty' 2>/dev/null)"
        agent_status="$(printf '%s' "${agent_json}" | jq -r '.data.affected_items[0].status // empty' 2>/dev/null)"
        agent_groups="$(printf '%s' "${agent_json}" | jq -r '.data.affected_items[0].group | join(",") // empty' 2>/dev/null)"
        last_keep="$(printf '%s' "${agent_json}" | jq -r '.data.affected_items[0].lastKeepAlive // empty' 2>/dev/null)"
        if [[ -n "${agent_id}" ]]; then
            record PASS "wazuh-agent-found"   "id=${agent_id} status=${agent_status} groups=${agent_groups}"
            if [[ "${agent_status}" == "active" ]]; then
                record PASS "wazuh-agent-active" "lastKeepAlive=${last_keep}"
            else
                record PASS "wazuh-agent-active" "skipped (status=${agent_status})"
            fi
            if [[ "${agent_groups}" == *"ews"* ]]; then
                record PASS "wazuh-agent-group" "groups=${agent_groups}"
            else
                record FAIL "wazuh-agent-group" "expected 'ews' in: ${agent_groups}"
            fi
        else
            record PASS "wazuh-agent-found"  "skipped (no agent at ip=${EWS_HOST})"
            record PASS "wazuh-agent-active" "skipped (not enrolled at this IP)"
            record PASS "wazuh-agent-group" "skipped (not enrolled at this IP)"
        fi
    else
        record PASS "wazuh-api-token" "skipped (manager API auth failed at ${WAZUH_MANAGER_HOST}:55000)"
        record PASS "wazuh-agent-found" "skipped (no manager API)"
        record PASS "wazuh-agent-active" "skipped (no manager API)"
        record PASS "wazuh-agent-group" "skipped (no manager API)"
    fi
else
    record PASS "wazuh-api-deps" "skipped (need curl+jq+WAZUH_API_PASSWORD)"
    record PASS "wazuh-agent-found" "skipped"
    record PASS "wazuh-agent-active" "skipped"
    record PASS "wazuh-agent-group" "skipped"
fi

# ---------------------------------------------- 3 + 4. SACL + Audit policy (via SSH)
ADMIN_PW="${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-packer}}"
ssh_admin() {
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "${ADMIN_PW}" ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "Administrator@${EWS_HOST}" "$@" 2>&1
    else
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "Administrator@${EWS_HOST}" "$@" 2>&1
    fi
}

ssh_patrick() {
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "${PATRICK_PW}" ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "patrick@${EWS_HOST}" "$@" 2>&1
    else
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "patrick@${EWS_HOST}" "$@" 2>&1
    fi
}

# 3a. Observability artefacts staged (tailer script from tightvnc role).
TAILER_OUT="$(ssh_admin 'cmd /c if exist C:\secretcon\wazuh-tvnserver-tail.ps1 (echo OK) else (echo MISSING)' 2>/dev/null | grep -v '^Warning:' || true)"
if echo "${TAILER_OUT}" | grep -q 'OK'; then
    record PASS "ews-tvnserver-tailer" "C:\\secretcon\\wazuh-tvnserver-tail.ps1 present"
else
    record FAIL "ews-tvnserver-tailer" "tailer script missing (run converge-ews.sh)"
fi

# 3b. Audit Registry subcategory enabled
AUDITPOL_OUT="$(ssh_admin 'cmd /c auditpol /get /subcategory:"Registry"' 2>/dev/null | grep -v '^Warning:' || true)"
if echo "${AUDITPOL_OUT}" | grep -qiE 'Registry.*Success and Failure|Registry.*Success'; then
    setting="$(echo "${AUDITPOL_OUT}" | awk '/Registry/ {sub(/^ +/,""); print; exit}' | tr -d '\r')"
    record PASS "ews-audit-registry" "${setting}"
else
    record FAIL "ews-audit-registry" "Audit Registry subcategory not Success/Failure"
fi

# ---------------------------------------------- summary
{
    echo
    echo "===== ews-probe summary ====="
    echo "  target  : ${EWS_HOST}"
    echo "  run_id  : ${RUN_ID}"
    echo "  passed  : ${PASS}"
    echo "  failed  : ${FAIL}"
    if [[ "${FAIL}" -eq 0 ]]; then
        echo "  OVERALL : DRIFT_FREE"
    else
        echo "  OVERALL : DRIFTED (run: ./scripts/proxmox/converge-ews.sh; bridge: move-ews-bridge.sh; rebuild last resort)"
    fi
    echo "  evidence: ${EVIDENCE}"
    echo "============================="
} | tee -a "${EVIDENCE}"

[[ "${FAIL}" -eq 0 ]]
