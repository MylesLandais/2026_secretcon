#!/usr/bin/env bash
# shellcheck shell=bash
#
# proxmox-ssh.sh -- shared Proxmox host SSH helpers (sshpass + pxssh/pxscp).
#
# Usage:
#   source scripts/lib/proxmox-ssh.sh
#   proxmox_load_env
#   proxmox_require_sshpass
#   pxssh "qm list"
#   pxscp local.txt /tmp/local.txt

proxmox_load_env() {
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    # shellcheck source=scripts/lib/load_repo_env.sh
    source "${repo_root}/scripts/lib/load_repo_env.sh"
    load_repo_env "${repo_root}"
    PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
    : "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
}

proxmox_require_sshpass() {
    SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
    if [ -z "${SSHPASS_BIN}" ] && command -v nix >/dev/null 2>&1; then
        SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
    fi
    if [ -z "${SSHPASS_BIN}" ]; then
        echo "[!] sshpass not found (try: nix develop)" >&2
        return 1
    fi
}

pxssh() {
    proxmox_require_sshpass || return 1
    "${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" ssh \
        -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o LogLevel=ERROR \
        "root@${PROXMOX_HOST}" "$@"
}

pxscp() {
    local src="$1"
    local dst="$2"
    proxmox_require_sshpass || return 1
    "${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" scp \
        -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o LogLevel=ERROR \
        "${src}" "root@${PROXMOX_HOST}:${dst}"
}
