#!/usr/bin/env bash
set -euo pipefail

# Build CysVulnServer local QEMU image with Packer (same as flake .#cysvuln-local).
#
# Usage:
#   ./scripts/stage-cysvuln-iso.sh
#   export SECRETCON_USER_FLAG='flag{...}'
#   export SECRETCON_ROOT_FLAG='flag{...}'
#   ./scripts/build-cysvuln-local.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${CYSVULN_ISO:-${REPO_ROOT}/infrastructure/packer/iso/cysvuln-server-2016.iso}"
ISO="$(readlink -f "$ISO")"
LOG="${BUILD_LOG:-${REPO_ROOT}/artifacts/cysvuln/local-qemu/build.log}"

if [ ! -f "$ISO" ]; then
    echo "[!] ISO not found: $ISO" >&2
    echo "    Run: ./scripts/stage-cysvuln-iso.sh" >&2
    exit 2
fi

mkdir -p "$(dirname "$LOG")"
export SECRETCON_USER_FLAG="${SECRETCON_USER_FLAG:-cysvuln-user-flag-placeholder}"
export SECRETCON_ROOT_FLAG="${SECRETCON_ROOT_FLAG:-cysvuln-root-flag-placeholder}"
export WAZUH_ENROLLMENT_OPTIONAL="${WAZUH_ENROLLMENT_OPTIONAL:-1}"
# Default to the Proxmox-SIEM IP for normal lab builds; the SIEM-capture
# loop overrides this with 10.0.2.2 (QEMU user-net host gateway) so the
# bootstrapped agent dials the local docker manager.
WAZUH_MANAGER="${WAZUH_MANAGER:-192.168.61.10}"

echo "[*] Building cysvuln-local"
echo "    ISO:           $ISO"
echo "    Log:           $LOG"
echo "    WAZUH_MANAGER: $WAZUH_MANAGER"

cd "${REPO_ROOT}/infrastructure/packer/cysvuln"
OUTPUT_DIR="${REPO_ROOT}/infrastructure/packer/cysvuln/packer-output/cysvuln-local"
export HOME="${PACKER_HOME:-$(mktemp -d)}"
export PACKER_LOG=1

# Packer creates the output dir; stale dirs from failed runs block builds.
rm -rf "$OUTPUT_DIR"

packer init .
packer build -only=cysvuln-local.qemu.cysvuln-local \
    -var "cysvuln_iso_url=file://${ISO}" \
    -var "cysvuln_wazuh_manager=${WAZUH_MANAGER}" \
    . 2>&1 | tee "$LOG"

QCOW="${OUTPUT_DIR}/cysvuln.qcow2"
if [ ! -f "$QCOW" ]; then
    echo "[!] Expected output not found: $QCOW" >&2
    exit 1
fi

mkdir -p "${REPO_ROOT}/result" "${REPO_ROOT}/artifacts/cysvuln/local-qemu"
cp -f "$QCOW" "${REPO_ROOT}/artifacts/cysvuln/local-qemu/cysvuln.qcow2"
ln -sf "$(readlink -f "${REPO_ROOT}/artifacts/cysvuln/local-qemu/cysvuln.qcow2")" "${REPO_ROOT}/result/cysvuln.qcow2"

echo "[+] Built: ${REPO_ROOT}/result/cysvuln.qcow2"
