#!/usr/bin/env bash
set -euo pipefail

# Build ASREP demo DC local QEMU image with Packer (same as flake .#asrep-local).
#
# Usage:
#   ./scripts/stage-cysvuln-iso.sh   # reuses Server 2016 ISO
#   export SECRETCON_ASREP_FLAG='flag{...}'
#   export AD_SAFEMODE_PASSWORD='PizzaMan123!'
#   ./scripts/build-asrep-local.sh
#
# Requires packer (run inside `nix develop`, or this script will re-exec via nix).

if ! command -v packer >/dev/null 2>&1; then
    exec nix develop -c "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${ASREP_ISO:-${CYSVULN_ISO:-${REPO_ROOT}/infrastructure/packer/iso/cysvuln-server-2016.iso}}"
ISO="$(readlink -f "$ISO")"
LOG="${BUILD_LOG:-${REPO_ROOT}/artifacts/asrep/local-qemu/build.log}"

if [ ! -f "$ISO" ]; then
    echo "[!] ISO not found: $ISO" >&2
    echo "    Run: ./scripts/stage-cysvuln-iso.sh" >&2
    exit 2
fi

mkdir -p "$(dirname "$LOG")"
export SECRETCON_ASREP_USER="${SECRETCON_ASREP_USER:-enite}"
export SECRETCON_ASREP_PASSWORD="${SECRETCON_ASREP_PASSWORD:-stud87}"
export SECRETCON_ASREP_FLAG="${SECRETCON_ASREP_FLAG:-asrep-flag-placeholder}"
export SECRETCON_DC_USER_FLAG="${SECRETCON_DC_USER_FLAG:-$SECRETCON_ASREP_FLAG}"
export SECRETCON_DC_ROOT_FLAG="${SECRETCON_DC_ROOT_FLAG:-asrep-root-flag-placeholder}"
export SECRETCON_ASREP_ENITE_DA="${SECRETCON_ASREP_ENITE_DA:-1}"
export AD_SAFEMODE_PASSWORD="${AD_SAFEMODE_PASSWORD:-PizzaMan123!}"
export WAZUH_ENROLLMENT_OPTIONAL="${WAZUH_ENROLLMENT_OPTIONAL:-1}"
WAZUH_MANAGER="${WAZUH_MANAGER:-10.0.3.2}"

echo "[*] Building asrep-local"
echo "    ISO:           $ISO"
echo "    Log:           $LOG"
echo "    WAZUH_MANAGER: $WAZUH_MANAGER"
echo "    ASREP user:    $SECRETCON_ASREP_USER"

cd "${REPO_ROOT}/infrastructure/packer/asrep"
OUTPUT_DIR="${REPO_ROOT}/infrastructure/packer/asrep/packer-output/asrep-local"
export HOME="${PACKER_HOME:-$(mktemp -d)}"
export PACKER_LOG=1

rm -rf "$OUTPUT_DIR"

packer init .
packer build -only=asrep-local.qemu.asrep-local \
    -var "asrep_iso_url=file://${ISO}" \
    -var "asrep_wazuh_manager=${WAZUH_MANAGER}" \
    -var "ad_safemode_password=${AD_SAFEMODE_PASSWORD}" \
    -var "asrep_user=${SECRETCON_ASREP_USER}" \
    -var "asrep_password=${SECRETCON_ASREP_PASSWORD}" \
    -var "asrep_flag=${SECRETCON_ASREP_FLAG}" \
    -var "dc_user_flag=${SECRETCON_DC_USER_FLAG}" \
    -var "dc_root_flag=${SECRETCON_DC_ROOT_FLAG}" \
    -var "asrep_enite_da=${SECRETCON_ASREP_ENITE_DA}" \
    . 2>&1 | tee "$LOG"

QCOW="${OUTPUT_DIR}/asrep.qcow2"
if [ ! -f "$QCOW" ]; then
    echo "[!] Expected output not found: $QCOW" >&2
    exit 1
fi

mkdir -p "${REPO_ROOT}/result" "${REPO_ROOT}/artifacts/asrep/local-qemu"
cp -f "$QCOW" "${REPO_ROOT}/artifacts/asrep/local-qemu/asrep.qcow2"
ln -sf "$(readlink -f "${REPO_ROOT}/artifacts/asrep/local-qemu/asrep.qcow2")" "${REPO_ROOT}/result/asrep.qcow2"

echo "[+] Built: ${REPO_ROOT}/result/asrep.qcow2"
