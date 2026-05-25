#!/usr/bin/env bash
set -euo pipefail

# Boot a local CysVulnServer qcow2 under QEMU user networking.
#
# Usage:
#   ./scripts/run-local-cysvuln.sh [path/to/cysvuln.qcow2]
#
# Host forwards (override with CYSVULN_HTTP_PORT / CYSVULN_WINRM_PORT):
#   localhost:18080 -> guest:80   (EFS HTTP)
#   localhost:15985 -> guest:5985 (WinRM)
#   localhost:13389 -> guest:3389 (RDP, optional)

DISK="${1:-./result/cysvuln.qcow2}"

if [ ! -f "$DISK" ] && [ -f ./artifacts/cysvuln/local-qemu/cysvuln.qcow2 ]; then
    mkdir -p ./result
    ln -sf "$(readlink -f ./artifacts/cysvuln/local-qemu/cysvuln.qcow2)" "$DISK"
fi

if [ ! -f "$DISK" ]; then
    echo "[!] Disk not found: $DISK"
    echo "    Run: nix build .#cysvuln-local"
    echo "    Or link: ln -sf artifacts/cysvuln/local-qemu/cysvuln.qcow2 result/cysvuln.qcow2"
    exit 1
fi

PIDFILE="${CYSVULN_PIDFILE:-/tmp/cysvuln-local.pid}"
HTTP_HOST_PORT="${CYSVULN_HTTP_PORT:-18080}"
WINRM_HOST_PORT="${CYSVULN_WINRM_PORT:-15985}"
RDP_HOST_PORT="${CYSVULN_RDP_PORT:-13389}"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[*] CysVuln VM already running (pid $(cat "$PIDFILE"))"
    echo "    HTTP:   http://127.0.0.1:${HTTP_HOST_PORT}/"
    echo "    WinRM:  http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
    echo "    RDP:    127.0.0.1:${RDP_HOST_PORT}"
    exit 0
fi

echo "[*] Starting CysVulnServer VM..."
echo "    HTTP:   http://127.0.0.1:${HTTP_HOST_PORT}/"
echo "    WinRM:  http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
echo "    RDP:    127.0.0.1:${RDP_HOST_PORT}"
echo "    Disk:   $DISK"

exec qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 4 \
    -machine pc \
    -drive "file=${DISK},if=ide,format=qcow2" \
    -nic "user,model=e1000,hostfwd=tcp::${HTTP_HOST_PORT}-:80,hostfwd=tcp::${WINRM_HOST_PORT}-:5985,hostfwd=tcp::${RDP_HOST_PORT}-:3389" \
    -display none \
    -daemonize \
    -pidfile "$PIDFILE"
