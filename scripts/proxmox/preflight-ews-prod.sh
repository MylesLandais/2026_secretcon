#!/usr/bin/env bash
# SecretCon EWS prod-reproduction preflight.
#
# Reach-test the lab over the WireGuard tunnel, confirm the operator
# environment has every tool the downstream scripts depend on, and
# materialise a one-line-per-check evidence file under
# artifacts/ews/prod-proof-<RUN_ID>/preflight.txt.
#
# Exit 0 only if every blocking check passes. The probe of VMID 111
# (Arkime) is NON-blocking: a fresh first-run does not have it yet,
# and that becomes the trigger for the orchestrator to call
# deploy-arkime-capture.sh.
#
# Usage:
#   ./scripts/proxmox/preflight-ews-prod.sh \
#       [--run-id ID] [--no-arkime] [--quiet]
#
# Flags:
#   --run-id ID    artifact subdir (default: ews-prod-<UTC>)
#   --no-arkime    skip the VMID 111 reachability probe
#   --quiet        only print FAIL lines + final summary
#
# Env:
#   PROXMOX_HOST           (default 192.168.60.1)
#   WAZUH_MANAGER_HOST     (default 192.168.61.10)
#   EWS_HOST               (default 192.168.61.20)
#   ARKIME_HOST            (default 192.168.61.11)
#   WG_INTERFACE           (default wg-ctf; auto-detected if absent)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID=""
SKIP_ARKIME=0
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)    RUN_ID="$2"; shift 2 ;;
        --no-arkime) SKIP_ARKIME=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        -h|--help)   sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="ews-prod-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/prod-proof-${RUN_ID}"
mkdir -p "${OUT_DIR}"
EVIDENCE="${OUT_DIR}/preflight.txt"

# shellcheck source=scripts/lib/load_repo_env.sh
. "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}"

# shellcheck source=scripts/lib/evidence-harness.sh
. "${REPO_ROOT}/scripts/lib/evidence-harness.sh"
EVIDENCE_QUIET="${QUIET}"
evidence_init "${EVIDENCE}"
record() { evidence_record "$@"; }

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
EWS_HOST="${EWS_HOST:-192.168.61.20}"
ARKIME_HOST="${ARKIME_HOST:-192.168.61.11}"
WG_INTERFACE="${WG_INTERFACE:-wg-ctf}"

[[ "${QUIET}" -eq 1 ]] || echo "[*] preflight run_id=${RUN_ID}  out=${OUT_DIR}"

# ---------------------------------------------- 1. WireGuard interface
if command -v ip >/dev/null 2>&1; then
    if ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
        record PASS "wg-iface-up" "${WG_INTERFACE}"
    else
        # Some setups name the iface wg0 or similar; surface a guess.
        guess="$(ip -o link show type wireguard 2>/dev/null | awk -F': ' 'NR==1{print $2}' | awk -F'@' '{print $1}')"
        if [[ -n "${guess}" ]]; then
            record WARN "wg-iface-up" "${WG_INTERFACE} missing; found ${guess}; set WG_INTERFACE=${guess}"
        else
            record FAIL "wg-iface-up" "no WireGuard interface up (looked for ${WG_INTERFACE})"
        fi
    fi
else
    record WARN "wg-iface-up" "iproute2 'ip' not on PATH; skipping"
fi

# ---------------------------------------------- 2. ICMP reachability
ping_target() {
    local host="$1" name="$2" blocking="${3:-yes}"
    if ping -c 1 -W 2 "${host}" >/dev/null 2>&1; then
        record PASS "${name}" "${host}"
    elif [[ "${blocking}" == "no" ]]; then
        record WARN "${name}" "${host} unreachable (non-blocking)"
    else
        record FAIL "${name}" "${host} unreachable"
    fi
}
ping_target "${PROXMOX_HOST}"        "ping-proxmox"     "yes"
ping_target "${WAZUH_MANAGER_HOST}"  "ping-wazuh-mgr"   "yes"
ping_target "${EWS_HOST}"            "ping-ews"         "yes"
if [[ "${SKIP_ARKIME}" -eq 0 ]]; then
    ping_target "${ARKIME_HOST}"     "ping-arkime"      "no"
fi

# ---------------------------------------------- 3. TCP service ports on Wazuh
tcp_open() {
    local host="$1" port="$2" name="$3" blocking="${4:-yes}"
    if timeout 3 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
        record PASS "${name}" "${host}:${port}"
    elif [[ "${blocking}" == "no" ]]; then
        record WARN "${name}" "${host}:${port} closed (non-blocking)"
    else
        record FAIL "${name}" "${host}:${port} not reachable"
    fi
}
tcp_open "${WAZUH_MANAGER_HOST}" 1514  "tcp-wazuh-agent"     "yes"
tcp_open "${WAZUH_MANAGER_HOST}" 55000 "tcp-wazuh-api"       "yes"
tcp_open "${WAZUH_MANAGER_HOST}" 443   "tcp-wazuh-dashboard" "yes"

# ---------------------------------------------- 4. .env sanity
env_required() {
    local var="$1"
    if [[ -n "${!var:-}" ]]; then
        record PASS "env-${var}" "set (${#var} chars in name)"
    else
        record FAIL "env-${var}" "not set in .env"
    fi
}
env_required PROXMOX_PASSWORD
env_required WAZUH_API_PASSWORD

# ---------------------------------------------- 5. SSH key for the manager
SSH_KEY="${REPO_ROOT}/provisioning/ssh/packer_ed25519"
if [[ -f "${SSH_KEY}" ]]; then
    perms="$(stat -c '%a' "${SSH_KEY}" 2>/dev/null || stat -f '%Lp' "${SSH_KEY}" 2>/dev/null)"
    if [[ "${perms}" == "600" || "${perms}" == "400" ]]; then
        record PASS "ssh-key-perms" "${SSH_KEY} (${perms})"
    else
        record FAIL "ssh-key-perms" "${SSH_KEY} is ${perms}; expected 600"
    fi
else
    record FAIL "ssh-key-perms" "${SSH_KEY} missing"
fi

# ---------------------------------------------- 6. Tool dependencies
DEPS=(nmap hydra tshark tcpdump sshpass jq curl python3 vncpasswd)
for cmd in "${DEPS[@]}"; do
    if command -v "${cmd}" >/dev/null 2>&1; then
        record PASS "dep-${cmd}" "$(command -v "${cmd}")"
    else
        record FAIL "dep-${cmd}" "not on PATH (try: nix develop)"
    fi
done

# ---------------------------------------------- 7. python winrm (used by adversary-emulation)
if python3 -c 'import winrm' 2>/dev/null; then
    record PASS "py-winrm" "pywinrm importable"
else
    record FAIL "py-winrm" "pywinrm not importable (try: nix develop)"
fi

# ---------------------------------------------- 8. VNC cred tool in tree
CRED_TOOL="${REPO_ROOT}/scripts/observability/vnc-cred-tool.py"
WORDLIST="${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt"
[[ -x "${CRED_TOOL}" ]] && record PASS "cred-tool"   "${CRED_TOOL}" || record FAIL "cred-tool" "missing or not executable"
[[ -f "${WORDLIST}"  ]] && record PASS "wordlist"    "${WORDLIST}" || record FAIL "wordlist"  "missing"

# ---------------------------------------------- 9. Proxmox SSH (via sshpass)
if [[ -n "${PROXMOX_PASSWORD:-}" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
        if sshpass -p "${PROXMOX_PASSWORD}" \
               ssh -o StrictHostKeyChecking=accept-new \
                   -o PreferredAuthentications=password \
                   -o PubkeyAuthentication=no \
                   -o ConnectTimeout=10 \
                   -o LogLevel=ERROR \
                   "root@${PROXMOX_HOST}" 'hostname' >/dev/null 2>&1; then
            record PASS "ssh-proxmox" "root@${PROXMOX_HOST}"
        else
            record FAIL "ssh-proxmox" "root@${PROXMOX_HOST} auth failed"
        fi
    else
        record FAIL "ssh-proxmox" "sshpass not on PATH"
    fi
fi

# ---------------------------------------------- 10. Wazuh manager SSH (via ProxyJump)
if [[ -n "${PROXMOX_PASSWORD:-}" ]] && [[ -f "${SSH_KEY}" ]] && command -v sshpass >/dev/null 2>&1; then
    PROXY="sshpass -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"
    if ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes \
           -o ConnectTimeout=15 \
           -i "${SSH_KEY}" \
           -o "ProxyCommand=${PROXY}" \
           "dadmin@${WAZUH_MANAGER_HOST}" 'sudo whoami' 2>/dev/null | grep -qx root; then
        record PASS "ssh-wazuh-mgr" "dadmin@${WAZUH_MANAGER_HOST} (sudo)"
    else
        record FAIL "ssh-wazuh-mgr" "dadmin@${WAZUH_MANAGER_HOST} unreachable or no sudo"
    fi
fi

# ---------------------------------------------- 11. Wazuh API token
if [[ -n "${WAZUH_API_PASSWORD:-}" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    api_user="${WAZUH_API_USER:-wazuh-wui}"
    token_json="$(curl -ksf -u "${api_user}:${WAZUH_API_PASSWORD}" \
        -X POST "https://${WAZUH_MANAGER_HOST}:55000/security/user/authenticate?raw=true" \
        --max-time 10 2>/dev/null || true)"
    if [[ -n "${token_json}" && "${token_json}" != *"error"* ]]; then
        record PASS "wazuh-api-auth" "${api_user}@${WAZUH_MANAGER_HOST}:55000"
    else
        record FAIL "wazuh-api-auth" "${api_user}@${WAZUH_MANAGER_HOST}:55000 auth failed"
    fi
fi

# ---------------------------------------------- summary
{
    echo
    echo "===== preflight summary ====="
    echo "  run_id : ${RUN_ID}"
    echo "  passed : ${EVIDENCE_PASS}"
    echo "  warned : ${EVIDENCE_WARN}"
    echo "  failed : ${EVIDENCE_FAIL}"
    echo "  evidence: ${EVIDENCE}"
    echo "============================="
} | tee -a "${EVIDENCE}"

if [[ "${EVIDENCE_FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
