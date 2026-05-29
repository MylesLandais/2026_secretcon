#!/usr/bin/env bash
# Add (idempotently) a <remote><connection>syslog</...> :514 block to the
# production Wazuh manager's /var/ossec/etc/ossec.conf, so
# scripts/wazuh-replay-to-proxmox.sh and
# scripts/observability/vnc-replay-on-deploy.sh can feed externally-
# captured datasets in for re-firing rules.
#
# This is OPTIONAL: live agent traffic uses the existing :1514/secure
# block and does not need :514. The replay path only kicks in when
# --enable-replay is passed to reproduce-ews-prod-proof.sh.
#
# Mirrors the snippet documented in
# docs/runbooks/wazuh-dataset-export-and-replay.md (operator-by-hand
# version). We widen allowed-ips to both 192.168.2.0/24 (operator over
# WireGuard) and 192.168.60.0/24 (anything run from a Proxmox-host shell).
#
# Usage:
#   ./scripts/proxmox/enable-wazuh-replay-listener.sh [--dry-run]
#                                                     [--allowed CIDR,...]
#                                                     [--no-restart]
#
# Env:
#   PROXMOX_HOST, PROXMOX_PASSWORD     (Proxmox jump)
#   WAZUH_MANAGER_HOST                  (default 192.168.61.10)
#   WAZUH_MANAGER_USER                  (default dadmin)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

DRY_RUN=0
NO_RESTART=0
ALLOWED_CIDRS="192.168.2.0/24,192.168.60.0/24"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --no-restart) NO_RESTART=1; shift ;;
        --allowed)    ALLOWED_CIDRS="$2"; shift 2 ;;
        -h|--help)    sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -f .env ]]; then
    while IFS='=' read -r k v; do
        [[ -z "${k}" || "${k}" =~ ^# ]] && continue
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        if [[ -z "${!k:-}" ]]; then
            export "${k}=${v}"
        fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env || true)
fi

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
WAZUH_MANAGER_HOST="${WAZUH_MANAGER_HOST:-192.168.61.10}"
WAZUH_MANAGER_USER="${WAZUH_MANAGER_USER:-dadmin}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
[[ -n "${SSHPASS_BIN}" ]] || { echo "[!] sshpass not on PATH" >&2; exit 1; }

PROXY="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"

waz_ssh() {
    ssh -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes \
        -i "${SSH_KEY}" \
        -o "ProxyCommand=${PROXY}" \
        "${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}" "$@"
}

# Build the <remote> block as a single canonical string with one
# <allowed-ips> per CIDR (Wazuh supports multiple <allowed-ips> lines).
ALLOWED_XML=""
IFS=',' read -r -a CIDR_ARR <<< "${ALLOWED_CIDRS}"
for cidr in "${CIDR_ARR[@]}"; do
    cidr="${cidr// /}"
    [[ -n "${cidr}" ]] || continue
    ALLOWED_XML+="    <allowed-ips>${cidr}</allowed-ips>"$'\n'
done

REMOTE_BLOCK=$'  <!-- SecretCon: VNC replay syslog ingest (scripts/proxmox/enable-wazuh-replay-listener.sh) -->\n'
REMOTE_BLOCK+=$'  <remote>\n'
REMOTE_BLOCK+=$'    <connection>syslog</connection>\n'
REMOTE_BLOCK+=$'    <port>514</port>\n'
REMOTE_BLOCK+=$'    <protocol>tcp</protocol>\n'
REMOTE_BLOCK+="${ALLOWED_XML}"
REMOTE_BLOCK+=$'    <local_ip>'"${WAZUH_MANAGER_HOST}"$'</local_ip>\n'
REMOTE_BLOCK+=$'  </remote>'

echo "[*] target manager : ${WAZUH_MANAGER_USER}@${WAZUH_MANAGER_HOST}"
echo "[*] allowed CIDRs  : ${ALLOWED_CIDRS}"
echo "[*] block to insert:"
printf '%s\n' "${REMOTE_BLOCK}" | sed 's/^/    /'

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[*] dry-run: not modifying manager"
    exit 0
fi

# Idempotency: marker comment uniquely identifies our injected block.
MARKER="SecretCon: VNC replay syslog ingest"
echo "[*] Checking whether block already present"
if waz_ssh "sudo grep -q '${MARKER}' /var/ossec/etc/ossec.conf"; then
    echo "    block already present; nothing to do."
    EXISTS=1
else
    EXISTS=0
fi

if [[ "${EXISTS}" -eq 0 ]]; then
    echo "[*] Backing up ossec.conf to /root/ossec.conf.bak.<TS>"
    waz_ssh "sudo cp -a /var/ossec/etc/ossec.conf /root/ossec.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    echo "[*] Injecting block (one shot, before </ossec_config>)"
    # Use python on the manager (already required by bootstrap-wazuh-ubuntu.sh)
    # for safe XML-aware insertion via plain text - inject the block
    # immediately before the LAST </ossec_config>.
    waz_ssh "sudo python3 - <<'PY'
import re, sys
path = '/var/ossec/etc/ossec.conf'
with open(path) as f:
    data = f.read()
block = '''${REMOTE_BLOCK}
'''
# Insert immediately before the final </ossec_config>; if there are
# multiple stanzas wazuh's wazuh-config concatenates them, but the
# canonical install has one closing tag.
m = list(re.finditer(r'</ossec_config>', data))
if not m:
    sys.exit('no </ossec_config> tag found')
ins = m[-1].start()
out = data[:ins] + block + '\n' + data[ins:]
with open(path, 'w') as f:
    f.write(out)
print('inserted before offset %d (final </ossec_config>)' % ins)
PY"
fi

if [[ "${NO_RESTART}" -eq 0 ]]; then
    echo "[*] Restarting wazuh-manager"
    waz_ssh "sudo /var/ossec/bin/wazuh-control restart 2>&1 | tail -10"
fi

echo "[*] Probing :514 listener"
sleep 3
if waz_ssh "sudo ss -tlnp 2>/dev/null | grep -qE ':514\b'"; then
    echo "[+] :514/tcp is listening on ${WAZUH_MANAGER_HOST}"
else
    echo "[!] :514/tcp not bound; check /var/ossec/logs/ossec.log on the manager" >&2
    exit 1
fi

echo
echo "[+] enable-wazuh-replay-listener complete"
echo "    test from operator workstation: nc -zv ${WAZUH_MANAGER_HOST} 514"
