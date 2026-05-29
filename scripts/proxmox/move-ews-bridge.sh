#!/usr/bin/env bash
# Move EWS VMID to the campaign bridge without a Packer rebake (~2 min).
#
# Usage:
#   ./scripts/proxmox/move-ews-bridge.sh [--ews-host 192.168.61.20]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

EWS_HOST_CLI=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ews-host) EWS_HOST_CLI="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/lib/ansible-proxmox-env.sh
source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
ansible_proxmox_load_env "${REPO_ROOT}"

EWS_VM_ID="${EWS_VM_ID:-109}"
EWS_FINAL_BRIDGE="${EWS_FINAL_BRIDGE:-vmbr1}"
EWS_HOST="${EWS_HOST_CLI:-${EWS_HOST:-192.168.61.20}}"

export EWS_FORCE_BRIDGE=1
export EWS_FINAL_BRIDGE
export EWS_VM_ID

echo "[*] Moving VMID ${EWS_VM_ID} net0 -> bridge=${EWS_FINAL_BRIDGE} (Ansible)"
ansible_proxmox_run_playbook "${REPO_ROOT}" \
    playbooks/proxmox/ews-hypervisor.yml \
    -e "proxmox_guest_agent_converged=true" \
    -e "ews_reboot_on_bridge_change=true"

echo "[*] Waiting for ${EWS_HOST}:5900 (max 5 min)"
DEADLINE=$(( $(date +%s) + 300 ))
while ! timeout 3 bash -c "</dev/tcp/${EWS_HOST}/5900" 2>/dev/null; do
    if (( $(date +%s) > DEADLINE )); then
        echo "[!] ${EWS_HOST}:5900 did not come up within 5 min" >&2
        exit 1
    fi
    sleep 5
done

echo "[+] ${EWS_HOST}:5900 reachable on ${EWS_FINAL_BRIDGE}"
echo "    Re-run: ./scripts/proxmox/discover-proxmox-inventory.sh"
echo ""
echo "[i] If ${EWS_HOST} never answers after bridge move, the guest may still hold"
echo "    a static address on the build subnet (192.168.60.x). Run converge on the"
echo "    build IP first, or configure in-guest IP before expecting ${EWS_HOST}."
