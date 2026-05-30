#!/usr/bin/env bash
set -euo pipefail

# Boot a local EWS qcow2 under QEMU user networking.
#
# Usage:
#   ./scripts/run-local-vm.sh [path/to/win10-ews-local.qcow2]
#   ./scripts/run-local-vm.sh --gui [path]          # QEMU GTK window (foreground)
#   ./scripts/run-local-vm.sh --headless [path]     # no display (RDP/WinRM only)
#
# Default display: SPICE on 127.0.0.1:5931 (attach with remote-viewer / open-local-vm-desktops.sh)
#
# Host forwards:
#   localhost:3389 -> guest:3389 (RDP)
#   localhost:5985 -> guest:5985 (WinRM)
#   localhost:5900 -> guest:5900 (UltraVNC)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/qemu-spice.sh
source "${REPO_ROOT}/scripts/lib/qemu-spice.sh"

DISPLAY_MODE="spice"
while [ $# -gt 0 ]; do
    case "$1" in
        --gui) DISPLAY_MODE=gui; shift ;;
        --headless) DISPLAY_MODE=headless; shift ;;
        --spice) DISPLAY_MODE=spice; shift ;;
        -h|--help)
            sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) echo "[!] unknown flag: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

DISK="${1:-./infrastructure/packer/ews/output/win10-ews-local/win10-ews-local.qcow2}"

if [ ! -f "$DISK" ] && [ -f ./result/win10-ews-local.qcow2 ]; then
    DISK="./result/win10-ews-local.qcow2"
fi

if [ ! -f "$DISK" ]; then
    echo "[!] Disk not found: $DISK"
    echo "    Run: nix build .#win10-ews-local"
    exit 1
fi

PIDFILE="${EWS_PIDFILE:-/tmp/ews-local.pid}"
SPICE_PORT="$(qemu_spice_default_port ews)"
SSH_HOST_PORT="${EWS_SSH_PORT:-2222}"
RDP_HOST_PORT="${EWS_RDP_PORT:-3389}"
WINRM_HOST_PORT="${EWS_WINRM_PORT:-5985}"
VNC_HOST_PORT="${EWS_VNC_PORT:-5900}"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[*] EWS VM already running (pid $(cat "$PIDFILE"))"
    echo "    SPICE:  $(qemu_spice_uri "$SPICE_PORT")"
    echo "    SSH:    127.0.0.1:${SSH_HOST_PORT}  (Ansible converge)"
echo "    RDP:    127.0.0.1:${RDP_HOST_PORT}"
    echo "    WinRM:  http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
    echo "    VNC:    127.0.0.1:${VNC_HOST_PORT}"
    echo "    Attach: ./scripts/open-local-vm-desktops.sh --ews"
    exit 0
fi

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
    echo "[!] qemu-system-x86_64 not on PATH — run: nix develop" >&2
    exit 1
fi

echo "[*] Starting local EWS VM..."
echo "    SSH:    127.0.0.1:${SSH_HOST_PORT}  (Ansible converge)"
echo "    RDP:    127.0.0.1:${RDP_HOST_PORT}"
echo "    WinRM:  http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
echo "    VNC:    127.0.0.1:${VNC_HOST_PORT}"
echo "    Disk:   $DISK"

DISPLAY_ARGS=()
case "$DISPLAY_MODE" in
    spice)
        echo "    SPICE:  $(qemu_spice_uri "$SPICE_PORT")"
        echo "    Attach: ./scripts/open-local-vm-desktops.sh --ews"
        qemu_spice_append_display_args DISPLAY_ARGS "$SPICE_PORT"
        DISPLAY_ARGS+=(-daemonize -pidfile "$PIDFILE")
        ;;
    gui)
        echo "    Display: QEMU GTK window (foreground)"
        DISPLAY_ARGS=(-display gtk -vga virtio)
        ;;
    headless)
        echo "    Display: headless (RDP/WinRM/VNC only)"
        DISPLAY_ARGS=(-display none -daemonize -pidfile "$PIDFILE")
        ;;
esac

exec "$QEMU_BIN" \
    -enable-kvm \
    -machine q35,smm=off \
    -cpu host,kvm=on \
    -smp 4 \
    -m 8192 \
    -drive "file=${DISK},format=qcow2,if=virtio" \
    -netdev "user,id=net0,hostfwd=tcp::${RDP_HOST_PORT}-:3389,hostfwd=tcp::${WINRM_HOST_PORT}-:5985,hostfwd=tcp::${VNC_HOST_PORT}-:5900,hostfwd=tcp::${SSH_HOST_PORT}-:22" \
    -device virtio-net,netdev=net0 \
    "${DISPLAY_ARGS[@]}"
