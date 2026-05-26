#!/usr/bin/env bash
set -uo pipefail

# Proxmox baseline snapshot for the ASREP demo DC (VMID 112).
#
# Usage:
#   ./scripts/proxmox/baseline-snapshot-asrep.sh \
#       [--vmid 112] [--ip <vm-ip>] [--name baseline]

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
  set -a; source .env; set +a
fi

VMID="${VMID:-112}"
VM_IP="${ASREP_PROXMOX_IP:-${VM_IP:-192.168.60.112}}"
SNAP_NAME="${SNAP_NAME:-baseline}"
ENROLL_TIMEOUT=240
SYSMON_TIMEOUT=120
PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
WAZUH_MANAGER_USER="${WAZUH_MANAGER_USER:-dadmin}"

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2 ;;
    --ip)   VM_IP="$2"; shift 2 ;;
    --name) SNAP_NAME="$2"; shift 2 ;;
    --enroll-timeout) ENROLL_TIMEOUT="$2"; shift 2 ;;
    --sysmon-timeout) SYSMON_TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
  esac
done

: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
: "${WAZUH_API_PASSWORD:?WAZUH_API_PASSWORD must be set in .env}"

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
[ -n "$SSHPASS_BIN" ] || { echo "[!] sshpass not found" >&2; exit 1; }

SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"
PROXY_CMD="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"

pxssh() {
  "$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o LogLevel=ERROR \
    "root@${PROXMOX_HOST}" "$@"
}

waz_ssh() {
  ssh -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      -i "$SSH_KEY" \
      -o "ProxyCommand=${PROXY_CMD}" \
      "${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}" "$@"
}

step() { echo -e "\n[*] $*"; }

if pxssh "qm listsnapshot ${VMID} 2>/dev/null | awk '{print \$2}' | grep -Fxq '${SNAP_NAME}'"; then
  echo "[*] Snapshot '${SNAP_NAME}' already exists on VMID ${VMID}"
  pxssh "qm listsnapshot ${VMID}"
  exit 0
fi

if ! pxssh "qm status ${VMID} 2>&1" | grep -q running; then
  step "Starting VMID ${VMID}"
  pxssh "qm start ${VMID}"
fi

step "Waiting for WinRM + Wazuh agent ip=${VM_IP} (strict)"
WAZUH_AGENT_IP="$VM_IP" \
  WAIT_AGENT_STRICT=1 \
  WAZUH_API_HOST="$WAZUH_MANAGER_HOST" \
  WINRM_PORT=5985 \
  "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" "$VM_IP" "$ENROLL_TIMEOUT"

step "Verifying Sysmon events on Proxmox manager"
deadline=$(( $(date +%s) + SYSMON_TIMEOUT ))
sysmon_seen=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if waz_ssh "sudo tail -n 1000 /var/ossec/logs/alerts/alerts.json 2>/dev/null" \
      | jq -r '.data.win.system.providerName // empty' 2>/dev/null \
      | grep -Fxq 'Microsoft-Windows-Sysmon'; then
    sysmon_seen=1
    echo "[+] Sysmon events observed"
    break
  fi
  sleep 5
done
[ "$sysmon_seen" -eq 1 ] || { echo "[!] No Sysmon within ${SYSMON_TIMEOUT}s" >&2; exit 1; }

step "Clean-shutting VMID ${VMID}"
pxssh "qm shutdown ${VMID} --timeout 120 || qm stop ${VMID}"
sleep 5

step "Taking qm snapshot ${SNAP_NAME}"
SNAP_DESC="ASREP post-bootstrap, agent active, sysmon flowing ($(date -u +%FT%TZ))"
pxssh "qm snapshot ${VMID} ${SNAP_NAME} --description \"${SNAP_DESC}\""
pxssh "qm listsnapshot ${VMID}"

pxssh "qm start ${VMID}"
echo "[+] ASREP baseline snapshot created on VMID ${VMID}"
