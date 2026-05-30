#!/usr/bin/env bash
# Open GUI windows for local SecretCon QEMU lab VMs (SPICE / RDP / VNC / Packer install view).
#
# Does not restart VMs — attaches viewers to whatever is already running.
#
# Usage:
#   ./scripts/open-local-vm-desktops.sh              # RDP preview (default, no cursor grab)
#   ./scripts/open-local-vm-desktops.sh --spice      # also open SPICE consoles
#   ./scripts/open-local-vm-desktops.sh --cysvuln    # CysVuln RDP only
#   ./scripts/open-local-vm-desktops.sh --ews        # EWS SPICE + VNC + RDP
#   ./scripts/open-local-vm-desktops.sh --packer     # Packer build VNC (during bake)
#   ./scripts/open-local-vm-desktops.sh --spice-only # alias for --spice
#
# Env:
#   CYSVULN_SPICE_PORT=5930  EWS_SPICE_PORT=5931
#   CYSVULN_RDP_PORT=13389   EWS_VNC_PORT=5900   EWS_RDP_PORT=3389
#   CYSVULN_ADMIN_PW / EWS admin via SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/qemu-spice.sh
source "${REPO_ROOT}/scripts/lib/qemu-spice.sh"

OPEN_CYS=1
OPEN_EWS=1
OPEN_PACKER=0
USE_SPICE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --cysvuln) OPEN_EWS=0; OPEN_PACKER=0; shift ;;
        --ews) OPEN_CYS=0; OPEN_PACKER=0; shift ;;
        --packer) OPEN_CYS=0; OPEN_EWS=0; OPEN_PACKER=1; shift ;;
        --spice|--spice-only) USE_SPICE=1; shift ;;
        --with-rdp|--preview) shift ;;
        -h|--help)
            sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done

CYSVULN_SPICE_PORT="$(qemu_spice_default_port cysvuln)"
EWS_SPICE_PORT="$(qemu_spice_default_port ews)"
CYSVULN_RDP_PORT="${CYSVULN_RDP_PORT:-13389}"
EWS_VNC_PORT="${EWS_VNC_PORT:-5900}"
EWS_RDP_PORT="${EWS_RDP_PORT:-3389}"
ADMIN_PW="${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}"
PATRICK_PW="${PATRICK_PW:-Changeme123!}"

port_open() {
    nc -z -w1 127.0.0.1 "$1" 2>/dev/null
}

find_packer_vnc_port() {
    local line display port
    line="$(pgrep -af 'qemu-system.*win10-ews-local' 2>/dev/null | head -1 || true)"
    [[ -n "$line" ]] || return 1
    if [[ "$line" =~ -vnc[[:space:]]127\.0\.0\.1:([0-9]+) ]]; then
        display="${BASH_REMATCH[1]}"
        port=$((5900 + display))
        echo "$port"
        return 0
    fi
    return 1
}

launch_rdp() {
    local title="$1" port="$2" user="$3" pass="$4"
    if ! port_open "$port"; then
        echo "[!] ${title}: RDP :${port} not listening yet"
        return 1
    fi
    if command -v xfreerdp >/dev/null 2>&1; then
        echo "[*] ${title}: opening RDP 127.0.0.1:${port} as ${user}"
        xfreerdp /v:127.0.0.1:"${port}" /u:"${user}" /p:"${pass}" /cert:ignore \
            /title:"SecretCon ${title}" /dynamic-resolution +clipboard &
    elif command -v wlfreerdp >/dev/null 2>&1; then
        echo "[*] ${title}: opening RDP 127.0.0.1:${port} as ${user}"
        wlfreerdp /v:127.0.0.1:"${port}" /u:"${user}" /p:"${pass}" /cert:ignore \
            /title:"SecretCon ${title}" /dynamic-resolution +clipboard &
    else
        echo "[!] ${title}: install freerdp (nix develop provides xfreerdp)"
        return 1
    fi
}

launch_vnc() {
    local title="$1" port="$2" pass="${3:-}"
    if ! port_open "$port"; then
        echo "[!] ${title}: VNC :${port} not listening yet"
        return 1
    fi
    if command -v vncviewer >/dev/null 2>&1; then
        echo "[*] ${title}: opening VNC 127.0.0.1:${port}"
        if [ -n "$pass" ]; then
            vncviewer -PasswordFile <(echo -n "$pass") "127.0.0.1:${port}" &
        else
            vncviewer "127.0.0.1:${port}" &
        fi
    else
        echo "[!] ${title}: install tigervnc (nix develop provides vncviewer)"
        return 1
    fi
}

if [ "$OPEN_CYS" -eq 1 ]; then
    if kill -0 "$(cat /tmp/cysvuln-local.pid 2>/dev/null)" 2>/dev/null; then
        if [ "$USE_SPICE" -eq 1 ] && port_open "$CYSVULN_SPICE_PORT"; then
            qemu_launch_spice_viewer "CysVuln (SPICE console)" "$CYSVULN_SPICE_PORT" || true
        fi
        launch_rdp "CysVuln" "$CYSVULN_RDP_PORT" "Administrator" "$ADMIN_PW" || true
    else
        echo "[*] CysVuln QEMU not running — start with: nix develop -c ./scripts/run-local-cysvuln.sh"
    fi
fi

if [ "$OPEN_EWS" -eq 1 ]; then
    if kill -0 "$(cat /tmp/ews-local.pid 2>/dev/null)" 2>/dev/null; then
        if [ "$USE_SPICE" -eq 1 ] && port_open "$EWS_SPICE_PORT"; then
            qemu_launch_spice_viewer "EWS (SPICE console)" "$EWS_SPICE_PORT" || true
        fi
    fi
    launch_rdp "EWS (Administrator)" "$EWS_RDP_PORT" "Administrator" "$ADMIN_PW" || true
    if port_open "$EWS_VNC_PORT"; then
        launch_vnc "EWS (UltraVNC / patrick desktop)" "$EWS_VNC_PORT" "${VNC_PW:-FELDTECH_VNC}" || true
    fi
    if ! port_open "$EWS_SPICE_PORT" && ! port_open "$EWS_VNC_PORT" && ! port_open "$EWS_RDP_PORT"; then
        echo "[*] EWS not on SPICE :${EWS_SPICE_PORT} or :${EWS_VNC_PORT}/:${EWS_RDP_PORT} — start with:"
        echo "    nix develop -c ./scripts/run-local-vm.sh infrastructure/packer/ews/output/win10-ews-local/win10-ews-local.qcow2"
    fi
fi

if [ "$OPEN_PACKER" -eq 1 ] || { [ "$OPEN_EWS" -eq 1 ] && ! port_open "$EWS_VNC_PORT" && ! port_open "$EWS_RDP_PORT"; }; then
    if packer_port="$(find_packer_vnc_port)"; then
        echo "[*] Packer EWS build console: VNC 127.0.0.1:${packer_port} (Windows installer / setup)"
        launch_vnc "EWS Packer build" "$packer_port" "" || true
    fi
fi

echo "[+] Desktop attach launched (viewer windows may take a few seconds)"
