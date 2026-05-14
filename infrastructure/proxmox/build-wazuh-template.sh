#!/usr/bin/env bash
# Build the Proxmox Ubuntu 22.04 cloud-image template (VMID 9000) used as the
# clone source for the Wazuh SIEM and any future Linux service VMs.
#
# Idempotent: re-running rebuilds the template from the pinned image.
# Runs on the Proxmox host. From the workstation:
#   ssh root@192.168.60.1 'bash -s' < infrastructure/proxmox/build-wazuh-template.sh

set -euo pipefail

TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-2204-cloud-tmpl}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr1}"
IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
IMG_PATH="/var/lib/vz/template/iso/jammy-server-cloudimg-amd64.img"

echo "[*] Ensuring snippets storage is enabled on 'local'"
if ! pvesm status -storage local | awk 'NR>1 {print $1}' | grep -q '^local$'; then
  echo "    'local' storage missing — aborting" >&2
  exit 1
fi
pvesm set local --content iso,backup,vztmpl,snippets >/dev/null 2>&1 || true
mkdir -p /var/lib/vz/snippets

if [[ ! -f "${IMG_PATH}" ]]; then
  echo "[*] Downloading Ubuntu 22.04 cloud image"
  curl -fsSL -o "${IMG_PATH}" "${IMG_URL}"
else
  echo "[*] Using cached image at ${IMG_PATH}"
fi

if qm status "${TEMPLATE_VMID}" >/dev/null 2>&1; then
  echo "[*] Destroying existing template VM ${TEMPLATE_VMID}"
  qm stop "${TEMPLATE_VMID}" 2>/dev/null || true
  sleep 2
  qm destroy "${TEMPLATE_VMID}" --purge 1 --skiplock 1
fi

echo "[*] Creating template VM ${TEMPLATE_VMID} (${TEMPLATE_NAME})"
qm create "${TEMPLATE_VMID}" \
  --name "${TEMPLATE_NAME}" \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26 \
  --machine q35 \
  --agent enabled=1 \
  --scsihw virtio-scsi-single \
  --serial0 socket \
  --vga std

echo "[*] Importing disk into ${STORAGE}"
qm importdisk "${TEMPLATE_VMID}" "${IMG_PATH}" "${STORAGE}" --format raw >/dev/null

qm set "${TEMPLATE_VMID}" \
  --scsi0 "${STORAGE}:vm-${TEMPLATE_VMID}-disk-0,discard=on,ssd=1" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot "order=scsi0"

echo "[*] Converting VM ${TEMPLATE_VMID} to template"
qm template "${TEMPLATE_VMID}"

echo "[+] Template ${TEMPLATE_NAME} (VMID ${TEMPLATE_VMID}) ready."
