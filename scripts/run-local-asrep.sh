#!/usr/bin/env bash
set -euo pipefail

# Boot the local ASREP demo DC qcow2 under QEMU user networking.
#
# Usage:
#   ./scripts/run-local-asrep.sh [path/to/asrep.qcow2]
#
# Host forwards (override with ASREP_* env vars):
#   localhost:18088 -> guest:88    (Kerberos)
#   localhost:15986 -> guest:5985  (WinRM)
#   localhost:13390 -> guest:3389  (RDP)

DISK="${1:-./result/asrep.qcow2}"

if [ ! -f "$DISK" ] && [ -f ./artifacts/asrep/local-qemu/asrep.qcow2 ]; then
    mkdir -p ./result
    ln -sf "$(readlink -f ./artifacts/asrep/local-qemu/asrep.qcow2)" "$DISK"
fi

if [ ! -f "$DISK" ]; then
    echo "[!] Disk not found: $DISK"
    echo "    Run: ./scripts/build-asrep-local.sh"
    exit 1
fi

PIDFILE="${ASREP_PIDFILE:-/tmp/asrep-local.pid}"
KERB_HOST_PORT="${ASREP_KERBEROS_PORT:-18088}"
WINRM_HOST_PORT="${ASREP_WINRM_PORT:-15986}"
RDP_HOST_PORT="${ASREP_RDP_PORT:-13390}"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[*] ASREP DC already running (pid $(cat "$PIDFILE"))"
    echo "    Kerberos: 127.0.0.1:${KERB_HOST_PORT}"
    echo "    WinRM:    http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
    echo "    RDP:      127.0.0.1:${RDP_HOST_PORT}"
    exit 0
fi

echo "[*] Starting ASREP demo DC..."
echo "    Kerberos: 10.0.3.15:88 (restrict=off) or 127.0.0.1:${KERB_HOST_PORT} forwarded"
echo "    WinRM:    http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
echo "    RDP:      127.0.0.1:${RDP_HOST_PORT}"
echo "    Disk:     $DISK"
echo ""
echo "    Note: GetNPUsers uses guest IP 10.0.3.15 from QEMU user-net; pass -dc-ip 10.0.3.15"

exec qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 4 \
    -machine pc \
    -drive "file=${DISK},if=ide,format=qcow2" \
    -netdev "user,id=net0,net=10.0.3.0/24,host=10.0.3.2,dhcpstart=10.0.3.15,restrict=off,hostfwd=tcp::${KERB_HOST_PORT}-:88,hostfwd=tcp::${WINRM_HOST_PORT}-:5985,hostfwd=tcp::${RDP_HOST_PORT}-:3389" \
    -device e1000,netdev=net0 \
    -display none \
    -daemonize \
    -pidfile "$PIDFILE"
