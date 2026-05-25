#!/usr/bin/env bash
# SecretCon 2026 — Domain Controller deploy wrapper.
#
# Usage:
#   ./scripts/proxmox/deploy-dc.sh --dc1
#   ./scripts/proxmox/deploy-dc.sh --dc2
#
# DC1 must be live before DC2 build runs. The script:
#   1. (Re)builds the VM via packer.
#   2. After packer exits, resets the VM to fire the SecretConDcPromote task.
#   3. Polls until LDAP/389 responds on the target IP.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
PROXMOX_SSH="root@${PROXMOX_HOST}"

ROLE=""
case "${1:-}" in
  --dc1) ROLE="dc1"; VMID=120; FINAL_IP="192.168.61.20"; PACKER_ONLY="proxmox-iso.dc-primary";;
  --dc2) ROLE="dc2"; VMID=121; FINAL_IP="192.168.61.21"; PACKER_ONLY="proxmox-iso.dc-replica";;
  *) echo "usage: $0 --dc1 | --dc2" >&2; exit 2;;
esac

: "${AD_SAFEMODE_PASSWORD:?AD_SAFEMODE_PASSWORD must be set in .env}"
: "${PROXMOX_URL:?PROXMOX_URL must be set in .env}"
: "${PROXMOX_USERNAME:?PROXMOX_USERNAME must be set in .env}"
: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"

if [ "$ROLE" = "dc2" ]; then
  : "${AD_ADMIN_PASSWORD:?AD_ADMIN_PASSWORD must be set in .env for DC2}"
fi

step() { echo -e "\n[*] $*"; }

step "Tearing down any existing VMID ${VMID}"
ssh "${PROXMOX_SSH}" "qm stop ${VMID} 2>/dev/null || true; while qm status ${VMID} 2>/dev/null | grep -q running; do sleep 2; done; qm destroy ${VMID} --purge 1 --skiplock 1 2>/dev/null || true"

step "Running packer build for ${ROLE}"
export PKR_VAR_ad_safemode_password="${AD_SAFEMODE_PASSWORD}"
if [ "$ROLE" = "dc2" ]; then
  export PKR_VAR_ad_admin_password="${AD_ADMIN_PASSWORD}"
fi
PACKER_DIR="${REPO_ROOT}/infrastructure/packer/dc"
PACKER_FILE="${PACKER_DIR}/proxmox-vm-dc.pkr.hcl"
packer init "${PACKER_DIR}"
packer build -force -only="${PACKER_ONLY}" "${PACKER_FILE}"

step "Resetting VMID ${VMID} to fire SecretConDcPromote scheduled task"
ssh "${PROXMOX_SSH}" "qm reset ${VMID}"

step "Polling ${FINAL_IP}:389 (LDAP) — promotion in progress, may take 10-20 min"
deadline=$(( $(date +%s) + 1800 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if nc -z -w 3 "${FINAL_IP}" 389 2>/dev/null; then
    echo "    LDAP up on ${FINAL_IP}"
    break
  fi
  sleep 15
done

if ! nc -z -w 3 "${FINAL_IP}" 389 2>/dev/null; then
  echo "[!] LDAP did not respond within 30m. Check VM console + C:\\secretcon\\promote.log" >&2
  exit 1
fi

step "Verifying SOA via dig"
if command -v dig >/dev/null 2>&1; then
  dig +short @"${FINAL_IP}" "${AD_DOMAIN:-heliumsupply.local}" SOA || true
fi

step "Done. ${ROLE^^} is live at ${FINAL_IP}."
if [ "$ROLE" = "dc1" ]; then
  echo "    Next: ./scripts/proxmox/deploy-dc.sh --dc2"
fi
