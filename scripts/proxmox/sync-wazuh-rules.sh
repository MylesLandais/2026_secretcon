#!/usr/bin/env bash
# Push the in-tree SecretCon CysVuln rule pack + ews agent.conf to the
# native Wazuh manager VM (VMID 110 / 192.168.61.10).
#
# Mirrors the docker-stack flow in scripts/wazuh-docker-up.sh, minus the
# `docker cp` shortcut: the Proxmox manager is a native install, so we
# scp the files via ProxyJump through root@PROXMOX_HOST, then `sudo
# install` them with the correct wazuh:wazuh ownership.
#
# Usage:
#   ./scripts/proxmox/sync-wazuh-rules.sh [--dry-run] [--no-restart]
#
# Required env (.env auto-sourced):
#   PROXMOX_HOST, PROXMOX_PASSWORD
#
# Optional env:
#   WAZUH_MANAGER_HOST  default 192.168.61.10
#   WAZUH_MANAGER_USER  default dadmin
#   AGENT_GROUP         default ews

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
  set -a; source .env; set +a
fi

DRY_RUN=0
RESTART_MANAGER=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --no-restart)  RESTART_MANAGER=0; shift ;;
    -h|--help)     sed -n '3,21p' "$0"; exit 0 ;;
    *)             echo "[!] unknown flag: $1" >&2; exit 2 ;;
  esac
done

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"

WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
WAZUH_MANAGER_USER="${WAZUH_MANAGER_USER:-dadmin}"
AGENT_GROUP="${AGENT_GROUP:-ews}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"

LOCAL_RULES_SRC="${REPO_ROOT}/infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml"
AGENT_CONF_SRC="${REPO_ROOT}/infrastructure/wazuh-docker/config/wazuh_cluster/shared/${AGENT_GROUP}/agent.conf"

for f in "$LOCAL_RULES_SRC" "$AGENT_CONF_SRC"; do
  [ -f "$f" ] || { echo "[!] missing source: $f" >&2; exit 1; }
done

step() { echo -e "\n[*] $*"; }

# Resolve sshpass binary for the Proxmox jump host (no keys authorized).
SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
if [ -z "$SSHPASS_BIN" ] && command -v nix >/dev/null 2>&1; then
  SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
fi
[ -n "$SSHPASS_BIN" ] || { echo "[!] sshpass not found" >&2; exit 1; }

PROXY_CMD="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"

waz_ssh() {
  ssh -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      -i "$SSH_KEY" \
      -o "ProxyCommand=${PROXY_CMD}" \
      "${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}" "$@"
}

waz_scp() {
  scp -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      -i "$SSH_KEY" \
      -o "ProxyCommand=${PROXY_CMD}" \
      "$1" "${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}:$2"
}

step "Confirming manager reachable @ ${WAZUH_MANAGER_HOST}"
waz_ssh 'hostname; uname -r; sudo /var/ossec/bin/wazuh-control status 2>&1 | head -10' \
  || { echo "[!] cannot reach manager" >&2; exit 1; }

if [ "$DRY_RUN" -eq 1 ]; then
  step "DRY RUN: would push these files"
  echo "    ${LOCAL_RULES_SRC} -> ${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}:/var/ossec/etc/rules/local_rules.xml"
  echo "    ${AGENT_CONF_SRC} -> ${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}:/var/ossec/etc/shared/${AGENT_GROUP}/agent.conf"
  step "DRY RUN: would (re)create agent_groups -a -g ${AGENT_GROUP}"
  [ "$RESTART_MANAGER" -eq 1 ] && step "DRY RUN: would restart wazuh-manager"
  exit 0
fi

step "Ensuring agent group '${AGENT_GROUP}' exists"
# agent_groups -q is "quiet" / no-prompt. -a creates if missing.
waz_ssh "sudo /var/ossec/bin/agent_groups -a -g ${AGENT_GROUP} -q 2>&1 || true"

step "Uploading local_rules.xml"
waz_scp "$LOCAL_RULES_SRC" "/tmp/local_rules.xml.sync"
waz_ssh "sudo install -o wazuh -g wazuh -m 0660 /tmp/local_rules.xml.sync /var/ossec/etc/rules/local_rules.xml && rm -f /tmp/local_rules.xml.sync"

step "Uploading shared/${AGENT_GROUP}/agent.conf"
waz_scp "$AGENT_CONF_SRC" "/tmp/agent.conf.sync"
# Directory must be 0770 (executable) so remoted can read merged.mg; the
# group-bound 0660 we use for files won't traverse a dir without +x.
waz_ssh "sudo install -o wazuh -g wazuh -m 0770 -d /var/ossec/etc/shared/${AGENT_GROUP} && sudo install -o wazuh -g wazuh -m 0660 /tmp/agent.conf.sync /var/ossec/etc/shared/${AGENT_GROUP}/agent.conf && rm -f /tmp/agent.conf.sync"

if [ "$RESTART_MANAGER" -eq 1 ]; then
  step "Restarting wazuh-manager via wazuh-control"
  # systemd's 90s start timeout fires before remoted finishes rebuilding
  # merged.mg on a fresh sync; wazuh-control restarts the daemons
  # directly and matches the project's own restart contract.
  waz_ssh "sudo /var/ossec/bin/wazuh-control restart 2>&1 | tail -20"
  step "Probing rule load (look for clean parse + count)"
  # ossec.log contains lines like 'INFO: (1226): Reloading rules.' and
  # 'INFO: (1245): Rules file '...local_rules.xml' loaded.'
  waz_ssh "sudo tail -n 200 /var/ossec/logs/ossec.log | grep -E 'CRITICAL|rules read|local_rules|loaded.*xml|Started wazuh-analysisd' | tail -20 || true"
fi

step "Manager-side merged.mg for ${AGENT_GROUP} (drives next agent pull)"
waz_ssh "sudo wc -l /var/ossec/etc/shared/${AGENT_GROUP}/merged.mg 2>&1 || true; sudo head -5 /var/ossec/etc/shared/${AGENT_GROUP}/merged.mg 2>&1"

echo
echo "[+] sync complete"
echo "    next: ./scripts/proxmox/baseline-snapshot-cysvuln.sh --vmid 119"
echo "    or:  sudo /var/ossec/bin/agent_control -R <agent-id>   # force agent pull"
