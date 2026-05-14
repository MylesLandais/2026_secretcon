#!/usr/bin/env bash
set -euo pipefail

QEMU="$(nix-build '<nixpkgs>' -A qemu --no-out-link)/bin/qemu-system-x86_64"
DISK="${1:-./output/win11-ews-local/win11-ews-local.qcow2}"

if [ ! -f "$DISK" ]; then
    echo "[!] Disk not found: $DISK"
    echo "    Run: nix build .#win11-ews-local"
    exit 1
fi

echo "[*] Starting local EWS VM..."
echo "    RDP:    localhost:3389"
echo "    WinRM:  localhost:5985"
echo "    VNC:    localhost:5900"

exec "$QEMU" \
    -enable-kvm \
    -machine q35,smm=off \
    -cpu host,kvm=on \
    -smp 4 \
    -m 8192 \
    -drive file="$DISK",format=qcow2,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::5985-:5985,hostfwd=tcp::5900-:5900 \
    -device virtio-net,netdev=net0 \
    -display gtk \
    -vga virtio
