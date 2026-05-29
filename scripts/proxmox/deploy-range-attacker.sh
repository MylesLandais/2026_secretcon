#!/usr/bin/env bash
# Deploy cloud-init range attacker (VMID 112) — hydra on vmbr1 @ 192.168.61.50.
#
# Usage:
#   ./scripts/proxmox/deploy-range-attacker.sh
#   ./scripts/proxmox/deploy-range-attacker.sh --verify-hydra --ews-host 192.168.61.158
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

VERIFY_HYDRA=0
EWS_HOST="${EWS_HOST:-192.168.61.158}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-hydra) VERIFY_HYDRA=1; shift ;;
    --ews-host) EWS_HOST="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
  esac
done

RANGE_ATTACKER_IP="${RANGE_ATTACKER_IP:-192.168.61.50}"
PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"

# shellcheck source=scripts/lib/ansible-proxmox-env.sh
source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
ansible_proxmox_load_env "${REPO_ROOT}"

echo "[*] Ansible deploy range attacker (VMID ${RANGE_ATTACKER_VMID:-112})"
ansible_proxmox_run_playbook "${REPO_ROOT}" playbooks/proxmox/range-attacker.yml \
  -e "proxmox_api_password=${PROXMOX_PASSWORD}"

echo "[*] waiting for cloud-init on ${RANGE_ATTACKER_IP} (ProxyJump ${PROXMOX_HOST})"
DEADLINE=$(( $(date +%s) + 900 ))
SSHPASS_BIN="$(command -v sshpass)"
SSH_OPTS=(
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8
  -o BatchMode=yes
  -o "ProxyCommand=${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=no -W %h:%p root@${PROXMOX_HOST}"
  -i "${SSH_KEY}"
)
until ssh "${SSH_OPTS[@]}" "dadmin@${RANGE_ATTACKER_IP}" "cloud-init status --wait" 2>/dev/null; do
  if (( $(date +%s) > DEADLINE )); then
    echo "[!] timed out — try: ssh -J root@${PROXMOX_HOST} dadmin@${RANGE_ATTACKER_IP}" >&2
    exit 1
  fi
  sleep 10
done
echo "[+] cloud-init complete on ${RANGE_ATTACKER_IP}"

WORDLIST="${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt"
scp "${SSH_OPTS[@]}" "${WORDLIST}" "dadmin@${RANGE_ATTACKER_IP}:/opt/secretcon/vnc-better.txt" 2>/dev/null \
  || ssh "${SSH_OPTS[@]}" "dadmin@${RANGE_ATTACKER_IP}" "sudo mkdir -p /opt/secretcon && sudo chown dadmin:dadmin /opt/secretcon" \
  && scp "${SSH_OPTS[@]}" "${WORDLIST}" "dadmin@${RANGE_ATTACKER_IP}:/opt/secretcon/vnc-better.txt"

if [[ "${VERIFY_HYDRA}" -eq 1 ]]; then
  echo "[*] hydra from range attacker → ${EWS_HOST}:5900"
  ssh "${SSH_OPTS[@]}" "dadmin@${RANGE_ATTACKER_IP}" \
    "hydra -t 1 -V -f -P /opt/secretcon/vnc-better.txt -s 5900 ${EWS_HOST} vnc"
fi

echo "[+] range attacker ready: dadmin@${RANGE_ATTACKER_IP} (ssh -J root@${PROXMOX_HOST})"
