#!/usr/bin/env bash
# Fix Kali VM 104 dual-NIC layout offline (Proxmox host).
#
# Problem: 192.168.60.x was bound to the vmbr1 NIC inside the guest, so Proxmox
# cannot reach SSH on vmbr0 and the box cannot reach EWS on vmbr1.
#
# Writes NetworkManager profiles (eth0 DHCP on vmbr0, eth1 static on vmbr1).
#
# Usage (repo root, .env with PROXMOX_PASSWORD):
#   ./scripts/proxmox/fix-kali-104-network.sh [--no-start]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/lib/proxmox-ssh.sh
source "${REPO_ROOT}/scripts/lib/proxmox-ssh.sh"
proxmox_load_env
proxmox_require_sshpass

VMID="${KALI_VMID:-104}"
RANGE_IP="${KALI_RANGE_IP:-192.168.61.50}"
RANGE_GW="${KALI_RANGE_GW:-192.168.61.1}"
START_AFTER=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) START_AFTER=0; shift ;;
    -h|--help)
      sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
  esac
done

echo "[*] fix-kali-104-network VMID=${VMID} range=${RANGE_IP}/24"

pxssh "bash -s" <<REMOTE
set -euo pipefail
VMID=${VMID}
DISK=/dev/pve/vm-\${VMID}-disk-0
MNT=/mnt/secretcon-kali-fix
RANGE_IP=${RANGE_IP}
RANGE_GW=${RANGE_GW}

losetup -D 2>/dev/null || true

if ! qm status "\${VMID}" | grep -q stopped; then
  echo "[*] stopping VM \${VMID}"
  qm stop "\${VMID}" || true
  for _ in \$(seq 1 45); do
    qm status "\${VMID}" | grep -q stopped && break
    sleep 2
  done
fi

mkdir -p "\${MNT}"
LOOP=\$(losetup -f --show -P "\${DISK}")
PART="\${LOOP}p1"
if [ ! -b "\${PART}" ]; then
  echo "[!] expected \${PART} on Kali disk; lsblk:"
  lsblk "\${LOOP}"
  losetup -d "\${LOOP}"
  exit 1
fi

# Journal may be dirty after unclean shutdown; quick repair then mount
timeout 180 e2fsck -p "\${PART}" || timeout 180 e2fsck -y "\${PART}" || true
mount "\${PART}" "\${MNT}"

NM_DIR="\${MNT}/etc/NetworkManager/system-connections"
mkdir -p "\${NM_DIR}"
chmod 700 "\${NM_DIR}"

cat > "\${NM_DIR}/secretcon-vmbr0.nmconnection" <<'EOF'
[connection]
id=secretcon-vmbr0
type=ethernet
autoconnect=true
[ethernet]
mac-address=BC:24:11:62:3E:15
[ipv4]
method=auto
dns-search=secret-ctf.com;
[ipv6]
method=ignore
EOF

cat > "\${NM_DIR}/secretcon-vmbr1.nmconnection" <<EOF
[connection]
id=secretcon-vmbr1
type=ethernet
autoconnect=true
[ethernet]
mac-address=BC:24:11:36:1E:BE
[ipv4]
method=manual
addresses=${RANGE_IP}/24
gateway=${RANGE_GW}
dns=192.168.61.52;192.168.61.10;
dns-search=secret-ctf.com;
[ipv6]
method=ignore
EOF

chmod 600 "\${NM_DIR}"/*.nmconnection
rm -f "\${MNT}/var/lib/NetworkManager/"*.lease 2>/dev/null || true

sync
umount "\${MNT}"
losetup -d "\${LOOP}"
echo "[+] network profiles written"
REMOTE

if [[ "${START_AFTER}" -eq 1 ]]; then
  echo "[*] starting VM ${VMID}"
  pxssh "qm start ${VMID}"
  echo "[*] after boot (~45s):"
  echo "    sshpass -p 'PizzaMan123!' ssh dadmin@${RANGE_IP}   # vmbr1"
  echo "    hydra -t 1 -V -f -P tmp/vnc-better.txt -s 5900 192.168.61.158 vnc"
fi

echo "[+] fix-kali-104-network complete"
