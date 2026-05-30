#!/usr/bin/env bash
# Proxmox baseline snapshot for EWS challenge VM (default VMID 109).
#
# Usage:
#   ./scripts/proxmox/baseline-snapshot-ews.sh [--vmid 109] [--name ctf-baseline]
#
# Creates primary tag ctf-baseline; also documents legacy `baseline` alias in runbook.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/proxmox-ssh.sh
source "${REPO_ROOT}/scripts/lib/proxmox-ssh.sh"
proxmox_load_env
proxmox_require_sshpass

VMID="${EWS_VM_ID:-109}"
SNAP_NAME="${SNAP_NAME:-ctf-baseline}"
ALSO_LEGACY="${ALSO_LEGACY:-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2 ;;
    --name) SNAP_NAME="$2"; shift 2 ;;
    -h|--help) sed -n '3,8p' "$0"; exit 0 ;;
    *) echo "[!] unknown: $1" >&2; exit 2 ;;
  esac
done

echo "[+] stopping VMID ${VMID}"
pxssh "qm shutdown ${VMID} --timeout 120" || true
sleep 5
pxssh "qm status ${VMID}" || true

echo "[+] snapshot ${SNAP_NAME} on VMID ${VMID}"
pxssh "qm snapshot ${VMID} ${SNAP_NAME} --description 'SecretCon EWS ctf-baseline'"

if [ "$ALSO_LEGACY" = "1" ] && [ "${SNAP_NAME}" != "baseline" ]; then
  echo "[+] alias snapshot baseline (legacy compat)"
  pxssh "qm snapshot ${VMID} baseline --description 'legacy alias of ctf-baseline'" || true
fi

pxssh "qm start ${VMID}"
echo "[+] EWS baseline snapshot complete (VMID ${VMID}, tag ${SNAP_NAME})"
