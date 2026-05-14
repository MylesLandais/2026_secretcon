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

step "Tearing down any existing VMID ${VMID}"
ssh "${PROXMOX_SSH}" "qm stop ${VMID} 2>/dev/null || true; sleep 2; qm destroy ${VMID} --purge 1 --skiplock 1 2>/dev/null || true"

step "Uploading cloud-init user-data + ssh pubkey"
scp "${USER_DATA}" "${PROXMOX_SSH}:/var/lib/vz/snippets/wazuh-user.yaml"
scp "${SSH_PUB}"   "${PROXMOX_SSH}:/root/.wazuh-deploy-pub.tmp"

step "Cloning template ${TEMPLATE_VMID} → VMID ${VMID} (${VM_NAME})"
ssh "${PROXMOX_SSH}" "qm clone ${TEMPLATE_VMID} ${VMID} --name ${VM_NAME} --full 1"

step "Clearing inherited NICs from template (avoids Proxmox 9 hotplug-rewrite error)"
ssh "${PROXMOX_SSH}" "qm set ${VMID} --delete net0 2>/dev/null || true; qm set ${VMID} --delete net1 2>/dev/null || true"

step "Configuring VMID ${VMID} (dual NIC: vmbr0 mgmt+egress, vmbr1 service)"
# net0 -> vmbr0 (DHCP) provides default route + internet for build (Wazuh upstream packages).
# net1 -> vmbr1 (static 192.168.61.10/24, no gw) is the agent-facing address.
ssh "${PROXMOX_SSH}" "qm set ${VMID} \
  --memory 8192 \
  --cores 4 \
  --cpu host \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --net1 virtio,bridge=vmbr1,firewall=1 \
  --ipconfig0 ip=dhcp \
  --ipconfig1 ip=${VM_IP}/${VM_CIDR} \
  --nameserver '1.1.1.1 ${VM_DNS}' \
  --searchdomain secret-ctf.com \
  --sshkeys /root/.wazuh-deploy-pub.tmp \
  --cicustom 'user=local:snippets/wazuh-user.yaml' \
  --agent enabled=1 \
  --onboot 1 \
  --tags wazuh,siem,secretcon"

step "Resizing disk to 100G"
ssh "${PROXMOX_SSH}" "qm resize ${VMID} scsi0 100G"

step "Starting VMID ${VMID}"
ssh "${PROXMOX_SSH}" "qm start ${VMID}"

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

step "Copying bootstrap script"
scp "${SSH_OPTS[@]}" "${BOOTSTRAP}" "dadmin@${VM_IP}:/tmp/bootstrap-wazuh-ubuntu.sh"

step "Running Wazuh bootstrap (this takes ~5-10 min)"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" 'sudo bash /tmp/bootstrap-wazuh-ubuntu.sh'

step "Fetching dashboard credentials"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" 'sudo cat /root/wazuh-passwords.txt 2>/dev/null | head -30' || true

echo
echo "[+] Wazuh SIEM deploy complete: https://${VM_IP}"
echo "    Run: ./scripts/proxmox/verify-wazuh-siem.sh"
