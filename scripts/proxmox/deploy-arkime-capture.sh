#!/usr/bin/env bash
# SecretCon Arkime capture VM deploy (VMID 111 'crit-capture').
#
# Same pattern as scripts/proxmox/deploy-wazuh-siem.sh:
#   1. Tear down any existing VMID 111.
#   2. Clone template VMID 9000 -> 111, set network/disk/cloud-init.
#   3. Wait for cloud-init to finish (docker installed via runcmd).
#   4. scp infrastructure/arkime-docker/{docker-compose.yml,config/,pcaps/}
#      and provisioning/cloud-init/arkime/bootstrap.sh into the VM.
#   5. Run the in-guest bootstrap.sh to bring the stack up, run db.pl init,
#      and create the admin user.
#
# Re-running is safe -- full teardown happens before clone (use --keep to
# skip teardown when iterating on bootstrap.sh).
#
# Usage:
#   ./scripts/proxmox/deploy-arkime-capture.sh \
#       [--run-id ID] [--keep] [--no-bootstrap]
#
# Env:
#   PROXMOX_HOST, PROXMOX_PASSWORD       (.env)
#   ARKIME_VM_ID         (default 111)
#   ARKIME_VM_NAME       (default crit-capture)
#   ARKIME_VM_IP         (default 192.168.61.11)
#   ARKIME_VM_CIDR       (default 24)
#   ARKIME_VM_GW         (default 192.168.61.1)
#   TEMPLATE_VMID        (default 9000)
#   ARKIME_ADMIN_USER    (default admin)
#   ARKIME_ADMIN_PASSWORD (default SecretCon123!)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID=""
KEEP=0
NO_BOOTSTRAP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)       RUN_ID="$2"; shift 2 ;;
        --keep)         KEEP=1; shift ;;
        --no-bootstrap) NO_BOOTSTRAP=1; shift ;;
        -h|--help)      sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              echo "[!] unknown flag: $1" >&2; exit 2 ;;
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

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
VMID="${ARKIME_VM_ID:-111}"
VM_NAME="${ARKIME_VM_NAME:-crit-capture}"
VM_IP="${ARKIME_VM_IP:-192.168.61.11}"
VM_CIDR="${ARKIME_VM_CIDR:-24}"
VM_GW="${ARKIME_VM_GW:-192.168.61.1}"
VM_DNS="${ARKIME_VM_DNS:-1.1.1.1}"
ARKIME_ADMIN_USER="${ARKIME_ADMIN_USER:-admin}"
ARKIME_ADMIN_PASSWORD="${ARKIME_ADMIN_PASSWORD:-SecretCon123!}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"
SSH_PUB="${SSH_PUB:-${SSH_KEY}.pub}"
USER_DATA="${REPO_ROOT}/provisioning/cloud-init/arkime/user-data"
BOOTSTRAP="${REPO_ROOT}/provisioning/cloud-init/arkime/bootstrap.sh"
STACK_DIR="${REPO_ROOT}/infrastructure/arkime-docker"

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="ews-prod-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/prod-proof-${RUN_ID}"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/deploy-arkime.log"
exec > >(tee -a "${LOG}") 2>&1

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
[[ -n "${SSHPASS_BIN}" ]] || { echo "[!] sshpass not on PATH" >&2; exit 1; }

pmx_ssh() {
    ${SSHPASS_BIN} -p "${PROXMOX_PASSWORD}" \
        ssh -o StrictHostKeyChecking=accept-new \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o LogLevel=ERROR \
            "root@${PROXMOX_HOST}" "$@"
}
pmx_scp() {
    ${SSHPASS_BIN} -p "${PROXMOX_PASSWORD}" \
        scp -o StrictHostKeyChecking=accept-new \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o LogLevel=ERROR \
            "$@"
}

# SSH options for reaching the VM via the Proxmox ProxyCommand
VM_PROXY="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"
VM_SSH_OPTS=(
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -i "${SSH_KEY}"
    -o "ProxyCommand=${VM_PROXY}"
)

step() { printf '\n[*] %s\n' "$*"; }

step "Deploy plan"
echo "    run_id          : ${RUN_ID}"
echo "    proxmox         : root@${PROXMOX_HOST}"
echo "    template vmid   : ${TEMPLATE_VMID}"
echo "    vm_id           : ${VMID} (${VM_NAME})"
echo "    vm_ip           : ${VM_IP}/${VM_CIDR} gw=${VM_GW}"

step "Ensuring template VMID ${TEMPLATE_VMID} exists"
if ! pmx_ssh "qm status ${TEMPLATE_VMID}" >/dev/null 2>&1; then
    echo "[!] Template VMID ${TEMPLATE_VMID} missing -- run scripts/proxmox/build-wazuh-template.sh first" >&2
    exit 1
fi

if [[ "${KEEP}" -eq 0 ]] || ! pmx_ssh "qm status ${VMID}" >/dev/null 2>&1; then
    step "Provisioning VMID ${VMID} via Ansible (community.proxmox)"
    # shellcheck source=scripts/lib/ansible-proxmox-env.sh
    source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
    export TEMPLATE_VMID ARKIME_VM_ID="${VMID}" ARKIME_VM_NAME="${VM_NAME}" \
        ARKIME_VM_IP="${VM_IP}" ARKIME_VM_CIDR ARKIME_VM_DNS SSH_PUB
    export ARKIME_KEEP="${KEEP}"
    ansible_proxmox_run_playbook "${REPO_ROOT}" playbooks/proxmox/arkime.yml
else
    step "Keeping existing VMID ${VMID} (--keep)"
fi

step "Waiting for cloud-init to finish (max 15 min)"
DEADLINE=$(( $(date +%s) + 900 ))
until ssh "${VM_SSH_OPTS[@]}" "dadmin@${VM_IP}" "cloud-init status --wait" 2>/dev/null; do
    if (( $(date +%s) > DEADLINE )); then
        echo "[!] timed out waiting for cloud-init on ${VM_IP}" >&2
        exit 1
    fi
    sleep 10
done
echo "    cloud-init complete."

step "Verifying docker installed"
ssh "${VM_SSH_OPTS[@]}" "dadmin@${VM_IP}" 'docker --version && docker compose version'

step "Uploading arkime-docker stack to /opt/arkime-docker/ on VM"
ssh "${VM_SSH_OPTS[@]}" "dadmin@${VM_IP}" 'sudo mkdir -p /opt/arkime-docker && sudo chown -R dadmin:dadmin /opt/arkime-docker'

# Pre-create the pcaps dir locally (might be empty) so the rsync/scp works.
mkdir -p "${STACK_DIR}/pcaps"

# Use ssh+tar for a quick directory transfer (no rsync dependency on the host VM).
TMP_TARBALL="$(mktemp /tmp/arkime-stack.XXXXXX.tar.gz)"
trap 'rm -f "${TMP_TARBALL}"' EXIT
tar -C "${REPO_ROOT}/infrastructure" \
    --exclude='arkime-docker/pcaps/*' \
    -czf "${TMP_TARBALL}" arkime-docker

scp -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -i "${SSH_KEY}" \
    -o "ProxyCommand=${VM_PROXY}" \
    "${TMP_TARBALL}" "dadmin@${VM_IP}:/tmp/arkime-stack.tar.gz"

ssh "${VM_SSH_OPTS[@]}" "dadmin@${VM_IP}" \
    'sudo tar -C /opt -xzf /tmp/arkime-stack.tar.gz && \
     sudo mkdir -p /opt/arkime-docker/pcaps && \
     sudo chown -R dadmin:dadmin /opt/arkime-docker && \
     rm -f /tmp/arkime-stack.tar.gz'

step "Uploading bootstrap.sh"
scp -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -i "${SSH_KEY}" \
    -o "ProxyCommand=${VM_PROXY}" \
    "${BOOTSTRAP}" "dadmin@${VM_IP}:/tmp/arkime-bootstrap.sh"

ssh "${VM_SSH_OPTS[@]}" "dadmin@${VM_IP}" \
    'sudo install -m 0755 /tmp/arkime-bootstrap.sh /opt/arkime-docker/bootstrap.sh && rm -f /tmp/arkime-bootstrap.sh'

if [[ "${NO_BOOTSTRAP}" -eq 0 ]]; then
    step "Running in-guest bootstrap"
    ssh "${VM_SSH_OPTS[@]}" "dadmin@${VM_IP}" \
        "sudo ARKIME_ADMIN_USER='${ARKIME_ADMIN_USER}' \
              ARKIME_ADMIN_PASSWORD='${ARKIME_ADMIN_PASSWORD}' \
              LISTEN_HOST='0.0.0.0' \
              bash /opt/arkime-docker/bootstrap.sh"
fi

step "Saving deploy summary"
cat > "${OUT_DIR}/deploy-arkime-summary.txt" <<EOF
run_id              ${RUN_ID}
deployed_at_utc     $(date -u +%FT%TZ)
vmid                ${VMID}
vm_name             ${VM_NAME}
vm_ip               ${VM_IP}
viewer_url          http://${VM_IP}:8005
opensearch_url      http://${VM_IP}:9201
admin_user          ${ARKIME_ADMIN_USER}
admin_password      ${ARKIME_ADMIN_PASSWORD}
pcap_corpus_in_vm   /opt/arkime-docker/pcaps/
EOF

echo
echo "[+] crit-capture (VMID ${VMID}) deploy complete"
echo "    log:  ${LOG}"
echo "    summary: ${OUT_DIR}/deploy-arkime-summary.txt"
echo "    next:  scripts/proxmox/verify-arkime-capture.sh"
