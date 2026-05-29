#!/usr/bin/env bash
# Deterministic Wazuh SIEM deploy: tears down VMID 110, clones the Ubuntu
# cloud-init template, applies cloud-init, waits for SSH, runs Wazuh bootstrap.
#
# Run from the workstation, repo root:
#   ./scripts/proxmox/deploy-wazuh-siem.sh
#
# Re-running is safe — full teardown happens before clone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# Load environment for Wazuh credentials
if [ -f .env ]; then
  source .env
  echo "[*] Loaded credentials from .env"
else
  echo "[!] WARNING: .env not found — Wazuh passwords will be randomly generated"
fi

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
PROXMOX_SSH="root@${PROXMOX_HOST}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
VMID="${VMID:-110}"
VM_NAME="${VM_NAME:-wazuh-siem}"
VM_IP="${VM_IP:-192.168.61.10}"
VM_CIDR="${VM_CIDR:-24}"
VM_GW="${VM_GW:-192.168.61.1}"
VM_DNS="${VM_DNS:-172.16.130.2}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"
SSH_PUB="${SSH_PUB:-${SSH_KEY}.pub}"
USER_DATA="${REPO_ROOT}/provisioning/cloud-init/wazuh/user-data"
BOOTSTRAP="${REPO_ROOT}/provisioning/bash/bootstrap-wazuh-ubuntu.sh"

step() { echo -e "\n[*] $*"; }

step "Ensuring template VMID ${TEMPLATE_VMID} exists"
if ! ssh "${PROXMOX_SSH}" "qm status ${TEMPLATE_VMID}" >/dev/null 2>&1; then
  echo "    Template missing — run build-wazuh-template.sh first" >&2
  exit 1
fi

step "Provisioning VMID ${VMID} via Ansible (community.proxmox)"
# shellcheck source=scripts/lib/ansible-proxmox-env.sh
source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
export TEMPLATE_VMID VMID VM_NAME VM_IP VM_CIDR VM_DNS SSH_PUB
ansible_proxmox_run_playbook "${REPO_ROOT}" playbooks/proxmox/wazuh-siem.yml

step "Waiting for cloud-init to finish (max 15 min, via Proxmox jump host)"
DEADLINE=$(( $(date +%s) + 900 ))
SSH_OPTS=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o "ProxyJump=${PROXMOX_SSH}" -i "${SSH_KEY}" )
until ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" "cloud-init status --wait" 2>/dev/null; do
  if (( $(date +%s) > DEADLINE )); then
    echo "    Timed out waiting for cloud-init on ${VM_IP}" >&2
    exit 1
  fi
  sleep 10
done
echo "    cloud-init complete."

step "Sanity: confirm disk is full size"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" 'df -h / | tail -1'

step "Running Wazuh bootstrap (this takes ~5-10 min, piped over SSH)"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" 'sudo bash -s' < "${BOOTSTRAP}"

step "Fetching and saving dashboard credentials"
CREDS_FILE="${REPO_ROOT}/wazuh-creds-$(date +%Y%m%d-%H%M%S).txt"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" 'sudo cat /root/wazuh-passwords.txt' > "${CREDS_FILE}" 2>/dev/null || {
  echo "WARNING: Failed to retrieve Wazuh credentials" >&2
}
if [ -f "${CREDS_FILE}" ]; then
  chmod 600 "${CREDS_FILE}"
  echo "[+] Credentials saved to: ${CREDS_FILE}"
  grep -iE "admin|password" "${CREDS_FILE}" | head -5
fi

echo
echo "[+] Wazuh SIEM deploy complete: https://${VM_IP}"
echo "    Run: ./scripts/proxmox/verify-wazuh-siem.sh"
