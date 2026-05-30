#!/usr/bin/env bash
set -uo pipefail

# Proxmox-flavored baseline snapshot for the CysVuln VMID 119 build.
#
# Mirrors scripts/observability/baseline-snapshot.sh:
#   1. Wait for WinRM on the static IP + Wazuh agent active (strict).
#   2. Probe for Sysmon events landing in the Proxmox manager's
#      alerts.json (proves shared/ews/agent.conf is being honored).
#   3. Clean-shutdown the VM via qm.
#   4. Take `qm snapshot 119 baseline` with a descriptive note.
#
# Usage:
#   ./scripts/proxmox/baseline-snapshot-cysvuln.sh \
#       [--vmid 119] [--ip 192.168.60.119] [--name baseline] \
#       [--enroll-timeout 240] [--sysmon-timeout 120]
#
# Required env (.env auto-sourced):
#   PROXMOX_PASSWORD, WAZUH_API_PASSWORD
#
# Optional env:
#   PROXMOX_HOST          default 192.168.60.1
#   WAZUH_MANAGER_HOST    default 192.168.61.10
#   WAZUH_MANAGER_USER    default dadmin

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
  set -a; source .env; set +a
fi

VMID="${VMID:-118}"
VM_IP="${CYSVULN_PROXMOX_IP:-${VM_IP:-192.168.60.57}}"
SNAP_NAME="${SNAP_NAME:-ctf-baseline}"
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
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
  esac
done

: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
: "${WAZUH_API_PASSWORD:?WAZUH_API_PASSWORD must be set in .env}"

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
if [ -z "$SSHPASS_BIN" ] && command -v nix >/dev/null 2>&1; then
  SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
fi
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

# Snapshot existence is an idempotent skip.
if pxssh "qm listsnapshot ${VMID} 2>/dev/null | awk '{print \$2}' | grep -Fxq '${SNAP_NAME}'"; then
  echo "[*] Snapshot '${SNAP_NAME}' already exists on VMID ${VMID}; nothing to do"
  pxssh "qm listsnapshot ${VMID}"
  exit 0
fi

step "VMID ${VMID} (${VM_IP}) status before gating"
pxssh "qm status ${VMID}"

# Ensure the VM is actually running; if it isn't, start it.
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

step "Verifying Sysmon events are flowing to the Proxmox manager"
deadline=$(( $(date +%s) + SYSMON_TIMEOUT ))
sysmon_seen=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if waz_ssh "sudo tail -n 1000 /var/ossec/logs/alerts/alerts.json 2>/dev/null | python3 -c 'import sys,json
seen=False
for ln in sys.stdin:
    try:
        d=json.loads(ln)
    except Exception: continue
    pn=((d.get(\"data\") or {}).get(\"win\") or {}).get(\"system\",{}).get(\"providerName\",\"\")
    if pn==\"Microsoft-Windows-Sysmon\": seen=True; break
sys.exit(0 if seen else 1)'" 2>/dev/null; then
    sysmon_seen=1
    echo "[+] Sysmon events observed in manager alerts.json"
    break
  fi
  sleep 5
done
if [ "$sysmon_seen" -ne 1 ]; then
  echo "[!] No Sysmon events arrived within ${SYSMON_TIMEOUT}s" >&2
  echo "[!] Likely cause: shared/ews/agent.conf not synced or merged.mg" >&2
  echo "    permissions wrong on the manager. Check:" >&2
  echo "      waz_ssh 'sudo cat /var/ossec/etc/shared/ews/merged.mg | head'" >&2
  echo "      waz_ssh 'sudo ls -la /var/ossec/etc/shared/ews/'" >&2
  exit 1
fi

step "Clean-shutting VMID ${VMID} so the snapshot captures a quiescent FS"
pxssh "qm shutdown ${VMID} --timeout 120 || qm stop ${VMID}"
# qm shutdown returns when the guest signals shutdown; give it a moment
# to release the disk before snapshotting.
sleep 5

step "Taking 'qm snapshot ${VMID} ${SNAP_NAME}'"
SNAP_DESC="post-bootstrap, agent active, sysmon flowing ($(date -u +%FT%TZ))"
pxssh "qm snapshot ${VMID} ${SNAP_NAME} --description \"${SNAP_DESC}\""
pxssh "qm listsnapshot ${VMID}"

step "Starting VMID ${VMID} back up (campaign expects a running base box)"
pxssh "qm start ${VMID}"

echo
echo "[+] Baseline snapshot created on VMID ${VMID}"
echo "    revert: qm rollback ${VMID} ${SNAP_NAME} && qm start ${VMID}"
echo "    next:   ./scripts/observability/stress-campaign.sh --platform proxmox"
