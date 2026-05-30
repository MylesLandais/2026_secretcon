#!/usr/bin/env bash
set -euo pipefail

# Boot a local CysVulnServer qcow2 under QEMU user networking.
#
# Usage:
#   ./scripts/run-local-cysvuln.sh [path/to/cysvuln.qcow2]
#   ./scripts/run-local-cysvuln.sh --gui [path]       # QEMU GTK window (foreground)
#   ./scripts/run-local-cysvuln.sh --headless [path]  # no display (RDP/WinRM only)
#
# Default display: SPICE on 127.0.0.1:5930 (attach with remote-viewer / open-local-vm-desktops.sh)
#
# Host forwards (override with CYSVULN_HTTP_PORT / CYSVULN_WINRM_PORT):
#   localhost:18080 -> guest:80   (EFS HTTP)
#   localhost:15985 -> guest:5985 (WinRM)
#   localhost:13389 -> guest:3389 (RDP)

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
SPICE_PORT="$(qemu_spice_default_port cysvuln)"
HTTP_HOST_PORT="${CYSVULN_HTTP_PORT:-18080}"
WINRM_HOST_PORT="${CYSVULN_WINRM_PORT:-15985}"
RDP_HOST_PORT="${CYSVULN_RDP_PORT:-13389}"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[*] CysVuln VM already running (pid $(cat "$PIDFILE"))"
    echo "    SPICE:  $(qemu_spice_uri "$SPICE_PORT")"
    echo "    HTTP:   http://127.0.0.1:${HTTP_HOST_PORT}/"
    echo "    WinRM:  http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
    echo "    RDP:    127.0.0.1:${RDP_HOST_PORT}"
    echo "    Attach: ./scripts/open-local-vm-desktops.sh --cysvuln"
    exit 0
fi

echo "[*] Starting CysVulnServer VM..."
echo "    HTTP:   http://127.0.0.1:${HTTP_HOST_PORT}/"
echo "    WinRM:  http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
echo "    RDP:    127.0.0.1:${RDP_HOST_PORT}"
echo "    Disk:   $DISK"

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
    echo "[!] qemu-system-x86_64 not on PATH — run: nix develop" >&2
    exit 1
fi

DISPLAY_ARGS=()
case "$DISPLAY_MODE" in
    spice)
        echo "    SPICE:  $(qemu_spice_uri "$SPICE_PORT")"
        echo "    Attach: ./scripts/open-local-vm-desktops.sh --cysvuln"
        qemu_spice_append_display_args DISPLAY_ARGS "$SPICE_PORT"
        DISPLAY_ARGS+=(-daemonize -pidfile "$PIDFILE")
        ;;
    gui)
        echo "    Display: QEMU GTK window (foreground)"
        DISPLAY_ARGS=(-display gtk -vga std)
        ;;
    headless)
        echo "    Display: headless (RDP/WinRM only)"
        DISPLAY_ARGS=(-display none -daemonize -pidfile "$PIDFILE")
        ;;
esac

exec "$QEMU_BIN" \
    -enable-kvm \
    -m 4096 \
    -smp 4 \
    -machine pc \
    -drive "file=${DISK},if=ide,format=qcow2" \
    -nic "user,model=e1000,hostfwd=tcp::${HTTP_HOST_PORT}-:80,hostfwd=tcp::${WINRM_HOST_PORT}-:5985,hostfwd=tcp::${RDP_HOST_PORT}-:3389" \
    "${DISPLAY_ARGS[@]}"
