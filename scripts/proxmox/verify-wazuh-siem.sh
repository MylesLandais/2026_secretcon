#!/usr/bin/env bash
# Acceptance test for the deployed Wazuh SIEM. Exits non-zero on any failure.
# Run from the workstation, repo root:
#   ./scripts/proxmox/verify-wazuh-siem.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VM_IP="${VM_IP:-192.168.61.10}"
PROXMOX_SSH="${PROXMOX_SSH:-root@192.168.60.1}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"
SSH_OPTS=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o "ProxyJump=${PROXMOX_SSH}" -i "${SSH_KEY}" )

fail() { echo "[FAIL] $*" >&2; exit 1; }
ok()   { echo "[ ok ] $*"; }

echo "[*] Port scan ${VM_IP} (from Proxmox host to bypass WG routing gap)"
ssh "${PROXMOX_SSH}" "for p in 1514 1515 55000 443; do nc -zv -w3 ${VM_IP} \$p 2>&1; done" \
  | tee /tmp/.wazuh-ports.tmp
for p in 1514 1515 55000 443; do
  grep -q "${VM_IP}.*${p}.*\(open\|succeeded\)" /tmp/.wazuh-ports.tmp || fail "port ${p} not open"
done
ok "TCP 1514/1515/55000/443 open"

echo "[*] Dashboard HTTPS check (from Proxmox host)"
ssh "${PROXMOX_SSH}" "curl -kfsS -m 10 https://${VM_IP} -o /dev/null && echo OK" \
  | grep -q OK && ok "dashboard responds 200" || fail "dashboard not reachable"

echo "[*] Manager service health"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" 'systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard' \
  | tee /tmp/.wazuh-svc.tmp
grep -qv inactive /tmp/.wazuh-svc.tmp || fail "one or more services inactive"
grep -c '^active$' /tmp/.wazuh-svc.tmp | grep -q '^3$' || fail "expected 3 active services"
ok "manager/indexer/dashboard active"

echo "[*] Agent group 'ews' present"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" "sudo /var/ossec/bin/agent_groups -l" | grep -qw ews \
  && ok "group ews present" || fail "group ews missing"

echo "[*] Suricata local rules loaded"
ssh "${SSH_OPTS[@]}" "dadmin@${VM_IP}" 'sudo grep -c "rule id=\"866" /var/ossec/etc/rules/local_rules.xml' \
  | grep -qE '^[5-9]$|^[1-9][0-9]+$' && ok "Suricata rules 866xx loaded" || fail "Suricata rules missing"

echo
echo "[+] All checks passed."
