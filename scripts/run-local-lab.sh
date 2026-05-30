#!/usr/bin/env bash
# Autonomous local SecretCon lab: boot QEMU VMs, attach RDP preview.
#
# Convergence priority (do NOT default to Packer):
#   1. hotfix / hot-patch   scripts/hotfix-cysvuln-prompts.sh, converge-local-ews.sh --hot-vnc
#   2. Ansible converge     scripts/converge-local-ews.sh, scripts/proxmox/converge-cysvuln.sh
#   3. Packer rebake        nix build .#win10-ews-local  (last resort only)
#
# Usage:
#   ./scripts/run-local-lab.sh                 # CysVuln up + RDP preview
#   ./scripts/run-local-lab.sh --preview       # re-attach RDP only (VMs already running)
#   ./scripts/run-local-lab.sh --packer-wait   # also wait for / start EWS after Packer
#   ./scripts/run-local-lab.sh --headless      # no viewers

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

WAIT_PACKER=-1
ATTACH=1
PREVIEW_ONLY=0
DISPLAY_MODE="headless"
START_CYS=1
START_EWS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --wait-packer|--packer-wait) WAIT_PACKER=1; START_EWS=1; shift ;;
        --no-wait-packer) WAIT_PACKER=-1; shift ;;
        --no-attach) ATTACH=0; shift ;;
        --preview) PREVIEW_ONLY=1; ATTACH=1; shift ;;
        --headless) DISPLAY_MODE=headless; ATTACH=0; shift ;;
        --cysvuln-only) START_EWS=0; shift ;;
        --ews-only) START_CYS=0; START_EWS=1; shift ;;
        -h|--help)
            sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done

log() { echo "[lab] $*"; }

packer_build_running() {
    pgrep -f 'packer build.*win10-ews-local' >/dev/null 2>&1
}

ews_disk_path() {
    local candidates=(
        "${REPO_ROOT}/infrastructure/packer/ews/output/win10-ews-local/win10-ews-local.qcow2"
        "${REPO_ROOT}/result/win10-ews-local.qcow2"
        "${REPO_ROOT}/output/win10-ews-local/win10-ews-local.qcow2"
    )
    local p
    for p in "${candidates[@]}"; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

wait_for_packer() {
    local logfile="${REPO_ROOT}/artifacts/ews/packer-build/build.log"
    log "waiting for win10-ews-local Packer build..."
    while packer_build_running; do
        if [ -f "$logfile" ]; then
            tail -1 "$logfile" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/[packer] /' || true
        fi
        sleep 30
    done
    if tail -20 "$logfile" 2>/dev/null | grep -q "Build 'win10-ews-local.qemu.win10-ews-local' finished after"; then
        log "Packer build succeeded"
        return 0
    fi
    if tail -20 "$logfile" 2>/dev/null | grep -q "Build 'win10-ews-local.qemu.win10-ews-local' errored after"; then
        log "Packer build failed — see ${logfile}"
        log "next: fix ansible/hot-patch, then ./scripts/converge-local-ews.sh (not another blind rebake)"
        return 1
    fi
    log "Packer not running and no finish line in log (disk may already exist)"
    return 0
}

start_cysvuln() {
    log "starting CysVuln (${DISPLAY_MODE})"
    nix develop -c "${REPO_ROOT}/scripts/run-local-cysvuln.sh" --"${DISPLAY_MODE}"
}

start_ews() {
    local disk
    disk="$(ews_disk_path)" || {
        log "EWS qcow2 not found — use converge/hot-patch on existing VM or: nix build .#win10-ews-local"
        return 1
    }
    log "starting EWS from ${disk} (${DISPLAY_MODE})"
    nix develop -c "${REPO_ROOT}/scripts/run-local-vm.sh" --"${DISPLAY_MODE}" "$disk"
}

attach_preview() {
    [ "$ATTACH" -eq 1 ] || return 0
    log "opening RDP preview (pass --spice to also open SPICE)"
    nix develop -c "${REPO_ROOT}/scripts/open-local-vm-desktops.sh" --cysvuln || true
    if packer_build_running; then
        nix develop -c "${REPO_ROOT}/scripts/open-local-vm-desktops.sh" --packer || true
    fi
}

if [ "$PREVIEW_ONLY" -eq 1 ]; then
    attach_preview
    exit 0
fi

if [ "$START_CYS" -eq 1 ]; then
    start_cysvuln
fi

if [ "$START_EWS" -eq 1 ]; then
    if packer_build_running; then
        if [ "$WAIT_PACKER" -eq 1 ]; then
            wait_for_packer || exit 1
            start_ews || true
        else
            log "Packer build running — use --packer-wait to auto-start EWS, or watch: open-local-vm-desktops.sh --packer"
        fi
    elif ews_disk_path >/dev/null; then
        if [ -f /tmp/ews-local.pid ] && kill -0 "$(cat /tmp/ews-local.pid)" 2>/dev/null; then
            log "EWS already running (pid $(cat /tmp/ews-local.pid))"
        else
            start_ews || true
        fi
    fi
fi

sleep 1
attach_preview

log "done"
log "  CysVuln RDP 127.0.0.1:${CYSVULN_RDP_PORT:-13389}"
log "  drift fix: ./scripts/hotfix-cysvuln-prompts.sh  |  ./scripts/converge-local-ews.sh --hot-vnc"
