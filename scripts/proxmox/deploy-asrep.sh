#!/usr/bin/env bash
# SecretCon 2026 — Proxmox ASREP demo DC deploy (DHCP + lookup flow).
#
# Usage:
#   ./scripts/proxmox/deploy-asrep.sh \
#       [--vmid 112] [--ip <override>] \
#       [--name secretcon-asrep-proxmox-112] \
#       [--skip-verify] [--keep-on-failure]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
  set -a; source .env; set +a
fi

# shellcheck source=../lib/chain_env.sh
source "${REPO_ROOT}/scripts/lib/chain_env.sh"

VMID="${VMID:-112}"
VM_NAME=""
VM_IP_HINT="${ASREP_PROXMOX_IP:-${CHAIN_DC_IP:-192.168.61.52}}"
SKIP_VERIFY=0
KEEP_ON_FAILURE=0
PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
CHAIN_BRIDGE="${CHAIN_BRIDGE:-vmbr1}"
CHAIN_GATEWAY="${CHAIN_GATEWAY:-192.168.61.1}"
INSTALL_TIMEOUT_S="${INSTALL_TIMEOUT_S:-3600}"

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2 ;;
    --ip)   VM_IP_HINT="$2"; shift 2 ;;
    --name) VM_NAME="$2"; shift 2 ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
  esac
done

: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
VM_NAME="${VM_NAME:-secretcon-asrep-proxmox-${VMID}}"

step() { echo -e "\n[*] $*"; }
die()  { echo "[!] $*" >&2; exit 1; }

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
[ -n "$SSHPASS_BIN" ] || die "sshpass not found"
command -v xorriso >/dev/null 2>&1 || die "xorriso required; run inside: nix develop"

pxssh() {
  "$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o LogLevel=ERROR \
    "root@${PROXMOX_HOST}" "$@"
}

pxscp() {
  "$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" scp \
    -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o LogLevel=ERROR \
    "$@"
}

step "Rendering PROVISION CD payload (ASREP autounattend + manifests)"
STAGE_DIR="${REPO_ROOT}/.tmp/proxmox-asrep-prov-${VMID}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"

cp "${REPO_ROOT}/provisioning/asrep/autounattend.xml"     "${STAGE_DIR}/autounattend.xml"
"${REPO_ROOT}/scripts/lib/render_autounattend.sh" \
  "${STAGE_DIR}/autounattend.xml" \
  "${STAGE_DIR}/autounattend.xml" \
  "${AD_SAFEMODE_PASSWORD:-PizzaMan123!}"
cp "${REPO_ROOT}/provisioning/proxmox/setstatic.ps1"      "${STAGE_DIR}/"
if [ -n "$VM_IP_HINT" ] && [ "$VM_IP_HINT" != "DHCP" ]; then
  echo "${VM_IP_HINT}|24|${CHAIN_GATEWAY}|${VM_IP_HINT},${WAZUH_MANAGER_HOST}" \
    > "${STAGE_DIR}/proxmox-static-ip.txt"
  echo "    static IP: ${VM_IP_HINT}/24 gw=${CHAIN_GATEWAY} dns=${VM_IP_HINT},${WAZUH_MANAGER_HOST}"
else
  echo "DHCP" > "${STAGE_DIR}/proxmox-static-ip.txt"
fi

for manifest in \
  "${REPO_ROOT}/infrastructure/packer/asrep/provision-manifest-asrep.txt" \
  "${REPO_ROOT}/infrastructure/packer/asrep/provision-manifest-shared.txt"; do
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac
    src="${REPO_ROOT}/${line}"
    [ -f "$src" ] || die "manifest path missing: $src"
    cp "$src" "${STAGE_DIR}/$(basename "$src")"
  done < "$manifest"
done

ISO_LOCAL="${REPO_ROOT}/.tmp/provision-asrep-${VMID}.iso"
xorriso -as mkisofs -volid PROVISION -joliet -rational-rock \
  -output "${ISO_LOCAL}" "${STAGE_DIR}" >/dev/null 2>&1 || die "xorriso failed"

ISO_REMOTE="/var/lib/vz/template/iso/secretcon-asrep-prov-${VMID}.iso"
step "Uploading PROVISION ISO -> ${ISO_REMOTE}"
pxscp "${ISO_LOCAL}" "root@${PROXMOX_HOST}:${ISO_REMOTE}" >/dev/null

step "Tearing down any existing VMID ${VMID}"
if pxssh "qm status ${VMID}" >/dev/null 2>&1; then
  pxssh "qm stop ${VMID} 2>/dev/null || true; \
         while qm status ${VMID} 2>/dev/null | grep -q running; do sleep 2; done; \
         qm destroy ${VMID} --purge 1 --skiplock 1 2>/dev/null || true"
fi

step "Creating VMID ${VMID} (${VM_NAME})"
pxssh "qm create ${VMID} \
  --name ${VM_NAME} \
  --memory 8192 --cores 2 --sockets 1 --cpu x86-64-v2-AES \
  --machine pc-i440fx-10.1 --bios seabios --ostype win10 \
  --scsihw virtio-scsi-single \
  --boot 'order=ide0;ide2;net0' \
  --net0 e1000,bridge=vmbr1,firewall=1 \
  --ide2 local:iso/windows-server-2016.iso,media=cdrom \
  --ide3 local:iso/secretcon-asrep-prov-${VMID}.iso,media=cdrom \
  --ide0 local-lvm:40,backup=0,cache=writeback,discard=on"

step "Starting VMID ${VMID}"
pxssh "qm start ${VMID}"

step "Discovering DHCP-assigned IP (timeout ${INSTALL_TIMEOUT_S}s)"
MAC="$(pxssh "qm config ${VMID} | sed -n 's/^net0:[[:space:]]*e1000=\\([0-9A-Fa-f:]*\\).*$/\\1/p'")"
MAC="${MAC,,}"
echo "    tap MAC: ${MAC}"

deadline=$(( $(date +%s) + INSTALL_TIMEOUT_S ))
DISCOVERED_IP=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  candidate="$(pxssh "ip -4 neigh show dev vmbr1 | awk -v m='${MAC}' 'tolower(\$5)==m {print \$1; exit}'" | tr -d '\r' | head -1)"
  if [ -n "$candidate" ] && pxssh "nc -z -w 3 ${candidate} 5985" 2>/dev/null; then
    DISCOVERED_IP="$candidate"
    break
  fi
  sleep 12
done

[ -n "$DISCOVERED_IP" ] || die "VMID ${VMID} never surfaced WinRM within ${INSTALL_TIMEOUT_S}s"
VM_IP="$DISCOVERED_IP"
echo "[+] VMID ${VMID} reachable on ${VM_IP}:5985"

ENV_OUT="${REPO_ROOT}/.tmp/proxmox-asrep-${VMID}.env"
cat > "${ENV_OUT}" <<EOF
ASREP_PROXMOX_IP=${VM_IP}
ASREP_PROXMOX_VMID=${VMID}
ASREP_PROXMOX_MAC=${MAC}
EOF

TUNNEL_PORT="${TUNNEL_PORT:-15986}"
pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true
"$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh -fN \
  -o StrictHostKeyChecking=accept-new \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:${TUNNEL_PORT}:${VM_IP}:5985" \
  "root@${PROXMOX_HOST}"
sleep 2

step "Bootstrapping ASREP over WinRM"
WAZUH_OPT=""
[ -n "${WAZUH_ENROLLMENT_OPTIONAL:-}" ] && WAZUH_OPT="--wazuh-optional"
python3 "${REPO_ROOT}/scripts/proxmox/winrm_bootstrap_asrep.py" \
  --target 127.0.0.1 --port "${TUNNEL_PORT}" \
  --admin-password "${ADMIN_PASSWORD:-${AD_SAFEMODE_PASSWORD:-PizzaMan123!}}" \
  --wazuh-manager "${WAZUH_MANAGER_HOST}" \
  --asrep-flag "${SECRETCON_ASREP_FLAG:-asrep-flag-placeholder}" \
  --dc-user-flag "${SECRETCON_DC_USER_FLAG:-${SECRETCON_ASREP_FLAG:-asrep-flag-placeholder}}" \
  --dc-root-flag "${SECRETCON_DC_ROOT_FLAG:-asrep-root-flag-placeholder}" \
  --enite-da "${SECRETCON_ASREP_ENITE_DA:-1}" \
  ${WAZUH_OPT} || RC=$?
RC=${RC:-0}
pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true
[ "$RC" -eq 0 ] || { [ "$KEEP_ON_FAILURE" -eq 1 ] || die "bootstrap failed rc=${RC}"; }

if [ "$SKIP_VERIFY" -eq 1 ]; then
  echo "[+] deploy complete (skip-verify); VM @ ${VM_IP}"
  exit 0
fi

"$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh -fN \
  -o StrictHostKeyChecking=accept-new \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:${TUNNEL_PORT}:${VM_IP}:5985" \
  "root@${PROXMOX_HOST}"
sleep 2

step "Smoke check via verify-asrep.sh"
ASREP_WINRM_PORT="${TUNNEL_PORT}" \
ASREP_AGENT_IP="${VM_IP}" \
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST}" \
  "${REPO_ROOT}/scripts/verify-asrep.sh" 127.0.0.1 "${AD_SAFEMODE_PASSWORD:-PizzaMan123!}" || {
    pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true
    [ "$KEEP_ON_FAILURE" -eq 1 ] || die "verify-asrep.sh failed"
  }
pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true

echo
echo "[+] ASREP deploy complete: VMID ${VMID} @ ${VM_IP}"
echo "    env: ${ENV_OUT}"
echo "    Next: ./scripts/proxmox/baseline-snapshot-asrep.sh --vmid ${VMID} --ip ${VM_IP}"
