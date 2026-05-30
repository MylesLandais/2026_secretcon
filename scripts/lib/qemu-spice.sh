#!/usr/bin/env bash
# SPICE display helpers for local QEMU runners (Linux mgmt consoles).
# Source from run-local-*.sh — do not execute directly.

qemu_spice_default_port() {
    case "${1:-}" in
        cysvuln) echo "${CYSVULN_SPICE_PORT:-5930}" ;;
        ews) echo "${EWS_SPICE_PORT:-5931}" ;;
        asrep) echo "${ASREP_SPICE_PORT:-5932}" ;;
        *) echo "${QEMU_SPICE_PORT:-5939}" ;;
    esac
}

qemu_spice_uri() {
    echo "spice://127.0.0.1:${1}"
}

# Append SPICE framebuffer args to the named array (headless guest, viewer on host).
qemu_spice_append_display_args() {
    local -n _out=$1
    local port=$2
    _out+=(-device qxl-vga)
    _out+=(-spice "port=${port},disable-ticketing=on,addr=127.0.0.1")
    _out+=(-display none)
}

qemu_launch_spice_viewer() {
    local title="$1" port="$2"
    local uri
    uri="$(qemu_spice_uri "$port")"
    if command -v remote-viewer >/dev/null 2>&1; then
        echo "[*] ${title}: opening SPICE ${uri}"
        remote-viewer --title "SecretCon ${title}" "${uri}" &
    elif command -v virt-viewer >/dev/null 2>&1; then
        echo "[*] ${title}: opening SPICE ${uri}"
        virt-viewer --title "SecretCon ${title}" --connect "${uri}" &
    else
        echo "[!] ${title}: install virt-viewer (nix develop provides remote-viewer)"
        return 1
    fi
}
