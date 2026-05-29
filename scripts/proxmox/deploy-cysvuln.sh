#!/usr/bin/env bash
# SecretCon 2026 — Proxmox CysVulnServer deploy (vmbr1 static or DHCP).
#
# Bypasses Packer's all-in-one proxmox-iso builder, which kept timing out
# on SSH because setstatic.ps1 raced the e1000 NIC link state during the
# `specialize` pass. Instead we:
#
#   1. xorriso a PROVISION CD with proxmox-static-ip.txt (static vmbr1 IP
#      when --ip is set, otherwise DHCP) plus shared cysvuln payload files.
#   2. `qm create` VMID 119 directly, attach Windows install ISO +
#      PROVISION CD, `qm start`.
#   3. Poll the Proxmox bridge ARP cache for the VM's MAC; that tells us
#      when Windows has finished installing, hit OOBE, run setup-openssh.ps1,
#      and grabbed a lease.
#   4. SSH in as packer@<dhcp-ip> (packer_ed25519 was authorized by
#      setup-openssh.ps1 from the PROVISION CD), upload + run
#      bootstrap_cysvuln.ps1 with WAZUH_MANAGER / flag env vars.
#   5. Optional smoke via scripts/verify-cysvuln.sh.
#
# Usage:
#   ./scripts/proxmox/deploy-cysvuln.sh \
#       [--vmid 119] [--ip 192.168.61.51] \
#       [--name secretcon-cysvuln-proxmox-119] \
#       [--skip-verify] [--keep-on-failure]
#
# .env vars consumed: PROXMOX_PASSWORD (required), WAZUH_API_PASSWORD,
# SECRETCON_USER_FLAG, SECRETCON_ROOT_FLAG,
# SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD.
# Optional env: PROXMOX_HOST (default 192.168.60.1),
#   WAZUH_MANAGER_HOST (default 192.168.61.10), INSTALL_TIMEOUT_S (default 1800),
#   CHAIN_DC_IP (default 192.168.61.52 — DNS server in static-ip file),
#   CYSVULN_PROXMOX_IP (overrides --ip).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/lib/load_repo_env.sh
. "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}"

# shellcheck source=../lib/chain_env.sh
source "${REPO_ROOT}/scripts/lib/chain_env.sh"

VMID="${VMID:-119}"
VM_NAME=""
VM_IP_HINT="${CYSVULN_PROXMOX_IP:-${CHAIN_CYSVULN_IP:-192.168.61.51}}"
SKIP_VERIFY=0
KEEP_ON_FAILURE=0
PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
CHAIN_DC_IP="${CHAIN_DC_IP:-192.168.61.52}"
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
    -h|--help) sed -n '3,32p' "$0"; exit 0 ;;
    *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
  esac
done

: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
VM_NAME="${VM_NAME:-secretcon-cysvuln-proxmox-${VMID}}"

step() { echo -e "\n[*] $*"; }
die()  { echo "[!] $*" >&2; exit 1; }

# -------------------------------------------------------- helper resolution
SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
if [ -z "$SSHPASS_BIN" ] && command -v nix >/dev/null 2>&1; then
  SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
fi
[ -n "$SSHPASS_BIN" ] || die "sshpass not found; install it or run inside the dev shell"

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

# ---------------------------------------------------------- PROVISION ISO
step "Rendering PROVISION CD payload (chain static IP + 14 files)"
STAGE_DIR="${REPO_ROOT}/.tmp/proxmox-prov-${VMID}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"

"${REPO_ROOT}/scripts/lib/render_autounattend.sh" \
  "${REPO_ROOT}/provisioning/proxmox/autounattend.xml" \
  "${STAGE_DIR}/autounattend.xml"
cp "${REPO_ROOT}/provisioning/proxmox/setstatic.ps1"      "${STAGE_DIR}/"
if [ -n "$VM_IP_HINT" ] && [ "$VM_IP_HINT" != "DHCP" ]; then
  echo "${VM_IP_HINT}|24|${CHAIN_GATEWAY}|${CHAIN_DC_IP},${WAZUH_MANAGER_HOST}" \
    > "${STAGE_DIR}/proxmox-static-ip.txt"
  echo "    static IP: ${VM_IP_HINT}/24 gw=${CHAIN_GATEWAY} dns=${CHAIN_DC_IP},${WAZUH_MANAGER_HOST}"
else
  echo "DHCP" > "${STAGE_DIR}/proxmox-static-ip.txt"
fi

# Read the shared manifest (lines that aren't blank or a # comment) and
# copy each path under the same basename onto the CD root, matching
# Packer's cd_files behaviour.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in '#'*) continue ;; esac
  src="${REPO_ROOT}/${line}"
  if [ ! -f "$src" ]; then
    die "manifest path missing: $src"
  fi
  cp "$src" "${STAGE_DIR}/$(basename "$src")"
done < "${REPO_ROOT}/infrastructure/packer/cysvuln/provision-manifest-shared.txt"

ISO_LOCAL="${REPO_ROOT}/.tmp/provision-${VMID}.iso"
xorriso -as mkisofs \
  -volid PROVISION \
  -joliet -rational-rock \
  -output "${ISO_LOCAL}" \
  "${STAGE_DIR}" >/dev/null 2>&1 || die "xorriso failed"
ISO_BYTES=$(stat -c %s "${ISO_LOCAL}" 2>/dev/null || echo 0)
echo "    -> ${ISO_LOCAL} (${ISO_BYTES} bytes)"

ISO_REMOTE="/var/lib/vz/template/iso/secretcon-prov-${VMID}.iso"
step "Uploading PROVISION ISO -> ${ISO_REMOTE}"
pxscp "${ISO_LOCAL}" "root@${PROXMOX_HOST}:${ISO_REMOTE}" >/dev/null

step "Creating VMID ${VMID} (${VM_NAME}) via Ansible"
# shellcheck source=scripts/lib/ansible-proxmox-env.sh
source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
export VMID VM_NAME CHAIN_BRIDGE
ansible_proxmox_run_playbook "${REPO_ROOT}" playbooks/proxmox/cysvuln.yml

# ------------------------------------------------------ DHCP lookup gating
# We can't passively rely on `ip neigh` because the Proxmox host has no
# reason to ARP its guests until something tries to reach them. So we
# actively sweep the subnet with `arp-scan` (preferred) or a parallel
# `arping` walk, then check the cache for our MAC. WinRM:5985 is up
# from autounattend's default Server 2016 config so we use that as the
# liveness probe (sshd via setup-openssh.ps1 has proved unreliable on
# the Proxmox build window — firewall + drive-letter race).
step "Discovering IP on ${CHAIN_BRIDGE} (timeout ${INSTALL_TIMEOUT_S}s)"
MAC="$(pxssh "qm config ${VMID} | sed -n 's/^net0:[[:space:]]*e1000=\\([0-9A-Fa-f:]*\\).*$/\\1/p'")"
MAC="${MAC,,}"
echo "    tap MAC: ${MAC}"

deadline=$(( $(date +%s) + INSTALL_TIMEOUT_S ))
DISCOVERED_IP=""
sweep_remote="set -e
ip -4 neigh show dev ${CHAIN_BRIDGE} | awk -v m='${MAC}' 'tolower(\$5)==m {print \$1; exit}'
if [ -z \"\$(ip -4 neigh show dev ${CHAIN_BRIDGE} | awk -v m='${MAC}' 'tolower(\$5)==m {print \$1}')\" ]; then
  if command -v arp-scan >/dev/null 2>&1; then
    arp-scan -I ${CHAIN_BRIDGE} 192.168.61.0/24 --timeout=200 --retry=1 2>/dev/null \
      | awk -v m='${MAC}' 'tolower(\$2)==m {print \$1; exit}'
  else
    for i in \$(seq 10 60); do
      arping -c 1 -w 1 -I ${CHAIN_BRIDGE} 192.168.61.\$i >/dev/null 2>&1 &
    done; wait
    ip -4 neigh show dev ${CHAIN_BRIDGE} | awk -v m='${MAC}' 'tolower(\$5)==m {print \$1; exit}'
  fi
fi"
last_status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  candidate="$(pxssh "${sweep_remote}" | tr -d '\r' | head -1)"
  if [ -n "$candidate" ] && [ "$candidate" != "$last_status" ]; then
    echo "    sweep saw ${MAC} -> ${candidate}"
    last_status="$candidate"
  fi
  if [ -n "$candidate" ]; then
    if pxssh "nc -z -w 3 ${candidate} 5985" 2>/dev/null; then
      DISCOVERED_IP="$candidate"
      break
    fi
  fi
  sleep 12
done

if [ -z "$DISCOVERED_IP" ]; then
  [ "$KEEP_ON_FAILURE" -eq 1 ] || pxssh "qm stop ${VMID} || true"
  die "VMID ${VMID} never surfaced a WinRM listener within ${INSTALL_TIMEOUT_S}s; check noVNC console"
fi

if [ -n "$VM_IP_HINT" ] && [ "$VM_IP_HINT" != "$DISCOVERED_IP" ]; then
  echo "[!] hint --ip ${VM_IP_HINT} != discovered ${DISCOVERED_IP}; using discovered"
fi
VM_IP="$DISCOVERED_IP"
echo "[+] VMID ${VMID} reachable on ${VM_IP}:5985"

# ------------------------------------------ persist for downstream scripts
ENV_OUT="${REPO_ROOT}/.tmp/proxmox-cysvuln-${VMID}.env"
cat > "${ENV_OUT}" <<EOF
# Generated by scripts/proxmox/deploy-cysvuln.sh on $(date -u +%FT%TZ)
CYSVULN_PROXMOX_IP=${VM_IP}
CYSVULN_PROXMOX_VMID=${VMID}
CYSVULN_PROXMOX_MAC=${MAC}
EOF
echo "[*] Wrote ${ENV_OUT}"

# ---------------------------------------------------- bootstrap over WinRM
step "Bootstrapping cysvuln over WinRM via SSH tunnel through ${PROXMOX_HOST}"
TUNNEL_PORT="${TUNNEL_PORT:-15985}"
# Drop any stale local listener on the chosen port.
if ss -ltn "( sport = :${TUNNEL_PORT} )" 2>/dev/null | grep -q LISTEN; then
  pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true
  sleep 1
fi
"$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh -fN \
  -o StrictHostKeyChecking=accept-new \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:${TUNNEL_PORT}:${VM_IP}:5985" \
  "root@${PROXMOX_HOST}"
sleep 2
if ! ss -ltn "( sport = :${TUNNEL_PORT} )" 2>/dev/null | grep -q LISTEN; then
  die "could not open WinRM tunnel 127.0.0.1:${TUNNEL_PORT} -> ${VM_IP}:5985"
fi
echo "    tunnel listening on 127.0.0.1:${TUNNEL_PORT}"

WAZUH_OPT_FLAG=""
[ -n "${WAZUH_ENROLLMENT_OPTIONAL:-}" ] && WAZUH_OPT_FLAG="--wazuh-optional"

python "${REPO_ROOT}/scripts/proxmox/winrm_bootstrap.py" \
  --target 127.0.0.1 --port "${TUNNEL_PORT}" \
  --admin-password "${ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD}}" \
  --wazuh-manager "${WAZUH_MANAGER_HOST}" \
  --user-flag "${SECRETCON_USER_FLAG:-cysvuln-user-flag-placeholder}" \
  --root-flag "${SECRETCON_ROOT_FLAG:-cysvuln-root-flag-placeholder}" \
  --shared-local-admin-password "${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD}" \
  ${WAZUH_OPT_FLAG}
RC=$?

# Tear down the tunnel either way.
pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true

if [ $RC -ne 0 ]; then
  echo "[!] bootstrap exited rc=${RC}; see logs above"
  [ "$KEEP_ON_FAILURE" -eq 1 ] || die "bootstrap failed"
fi

# ----------------------------------------------------------------- verify
if [ "$SKIP_VERIFY" -eq 1 ]; then
  echo "[*] --skip-verify requested; deploy complete (no smoke)"
  echo "    VM IP: ${VM_IP}    env: ${ENV_OUT}"
  exit 0
fi

step "Re-opening WinRM tunnel for smoke check"
"$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh -fN \
  -o StrictHostKeyChecking=accept-new \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:${TUNNEL_PORT}:${VM_IP}:5985" \
  "root@${PROXMOX_HOST}"
sleep 2

step "Smoke check via scripts/verify-cysvuln.sh through 127.0.0.1:${TUNNEL_PORT}"
WINRM_PORT="${TUNNEL_PORT}" \
  WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST}" \
  WAZUH_API_PASSWORD="${WAZUH_API_PASSWORD:-}" \
  "${REPO_ROOT}/scripts/verify-cysvuln.sh" 127.0.0.1 "${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD}" || {
    pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true
    [ "$KEEP_ON_FAILURE" -eq 1 ] || die "verify-cysvuln.sh failed"
    echo "[!] verify failed, --keep-on-failure preserves VM"
  }
pkill -f "ssh -fN -L 127.0.0.1:${TUNNEL_PORT}:" 2>/dev/null || true

echo
echo "[+] cysvuln deploy complete: VMID ${VMID} @ ${VM_IP}"
echo "    env: ${ENV_OUT}"
echo "    Next: ./scripts/proxmox/sync-wazuh-rules.sh"
echo "          ./scripts/proxmox/baseline-snapshot-cysvuln.sh --vmid ${VMID} --ip ${VM_IP}"
