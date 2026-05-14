#!/usr/bin/env bash
set -euo pipefail

# Two-phase headless Win11 24H2 LTSC boot.
#
# Phase 1: WinPE install from repacked ISO. winpeshl.ini hijacks setup, our
# startnet.cmd runs diskpart + dism + bcdboot, then `wpeutil shutdown` exits.
# `-no-reboot` makes QEMU exit on guest shutdown so we control the next boot.
#
# Phase 2: Relaunch QEMU pointed at the same disk + vars.fd but with NO
# install ISO attached and -boot order=c. This is the first real Windows boot:
# specialize -> OOBE -> AutoLogon -> bootstrap_win.ps1 (Wazuh + Python + WinRM).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/win11-auto}"
FRAMES_DIR="$WORK_DIR/frames"
WIN_ISO="${WIN_ISO:-$HOME/Downloads/win11-ltsc-24h2-unattended.iso}"
VIRTIO_ISO="${VIRTIO_ISO:-$HOME/Downloads/virtio-win.iso}"

OVMF_CODE="/run/libvirt/nix-ovmf/edk2-x86_64-code.fd"
OVMF_VARS_TEMPLATE="/run/libvirt/nix-ovmf/edk2-i386-vars.fd"

VNC_DISPLAY="${VNC_DISPLAY:-0}"
VNC_PASSWORD="${VNC_PASSWORD:-open123}"
WINRM_HOST_PORT="${WINRM_HOST_PORT:-15985}"
RDP_HOST_PORT="${RDP_HOST_PORT:-13389}"
GUEST_VNC_HOST_PORT="${GUEST_VNC_HOST_PORT:-15900}"
PHASE1_MAX_MIN="${PHASE1_MAX_MIN:-150}"   # WinPE install can take ~75-120 min
PHASE2_MAX_MIN="${PHASE2_MAX_MIN:-60}"    # specialize+OOBE+bootstrap ~15-30 min
FRAME_INTERVAL="${FRAME_INTERVAL:-60}"

SUDO=""
if ! [ -r /dev/kvm ] || ! [ -w /dev/kvm ]; then
    SUDO="sudo"
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

require() {
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 1; }
    done
}
require qemu-system-x86_64 qemu-img socat

[ -f "$WIN_ISO" ] || { echo "missing Win11 ISO: $WIN_ISO" >&2; exit 1; }
[ -f "$VIRTIO_ISO" ] || { echo "missing virtio-win ISO: $VIRTIO_ISO" >&2; exit 1; }
[ -f "$OVMF_CODE" ] || { echo "missing OVMF code: $OVMF_CODE" >&2; exit 1; }
[ -f "$OVMF_VARS_TEMPLATE" ] || { echo "missing OVMF vars template: $OVMF_VARS_TEMPLATE" >&2; exit 1; }

MONITOR_SOCK="$WORK_DIR/monitor.sock"
PIDFILE="$WORK_DIR/qemu.pid"
QEMU_LOG="$WORK_DIR/qemu.log"

# Skip prep if user passed RESUME=1 (e.g. retrying phase 2 only).
if [ "${RESUME:-0}" != "1" ]; then
    log "preparing $WORK_DIR"
    $SUDO rm -rf "$WORK_DIR"
    mkdir -p "$FRAMES_DIR" 2>/dev/null || $SUDO mkdir -p "$FRAMES_DIR"
    $SUDO chown -R "$(id -u):$(id -g)" "$WORK_DIR" 2>/dev/null || true

    log "creating 128G qcow2 disk"
    qemu-img create -f qcow2 "$WORK_DIR/disk.qcow2" 128G >/dev/null

    log "copying OVMF vars"
    cp "$OVMF_VARS_TEMPLATE" "$WORK_DIR/vars.fd"
    chmod u+w "$WORK_DIR/vars.fd"
fi

shot() {
    local name="$1"
    printf 'screendump %s\n' "$FRAMES_DIR/$name.ppm" \
        | $SUDO socat - UNIX-CONNECT:"$MONITOR_SOCK" >/dev/null 2>&1 || true
}

is_alive() {
    local pid
    pid="$($SUDO cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && $SUDO kill -0 "$pid" 2>/dev/null
}

# Common QEMU base args. CDs and boot order vary per phase.
qemu_base() {
    cat <<EOF
-name win11-auto
-enable-kvm
-machine q35,smm=on
-global driver=cfi.pflash01,property=secure,value=on
-cpu host
-smp 4
-m 8192
-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE
-drive if=pflash,format=raw,file=$WORK_DIR/vars.fd
-drive file=$WORK_DIR/disk.qcow2,if=none,id=os,format=qcow2,cache=writeback,discard=unmap
-device ahci,id=ahci0
-device ide-hd,drive=os,bus=ahci0.0
-netdev user,id=n0,hostfwd=tcp::${WINRM_HOST_PORT}-:5985,hostfwd=tcp::${RDP_HOST_PORT}-:3389,hostfwd=tcp::${GUEST_VNC_HOST_PORT}-:5900
-device e1000e,netdev=n0
-vga std
-display none
-object secret,id=vncpass,data=${VNC_PASSWORD}
-vnc 127.0.0.1:${VNC_DISPLAY},password=on,password-secret=vncpass
-monitor unix:${MONITOR_SOCK},server,nowait
-rtc base=localtime,clock=host
-daemonize
-pidfile ${PIDFILE}
EOF
}

run_phase() {
    local label="$1" max_min="$2"
    shift 2
    log "=== PHASE: $label (max ${max_min} min) ==="
    rm -f "$MONITOR_SOCK" "$PIDFILE"

    # shellcheck disable=SC2046
    $SUDO qemu-system-x86_64 $(qemu_base) "$@" >"$QEMU_LOG" 2>&1

    for _ in $(seq 1 20); do
        [ -S "$MONITOR_SOCK" ] && break
        sleep 0.5
    done
    [ -S "$MONITOR_SOCK" ] || { echo "monitor socket never appeared; see $QEMU_LOG" >&2; cat "$QEMU_LOG" >&2; return 1; }

    local pid; pid="$($SUDO cat "$PIDFILE")"
    log "QEMU started ($label, pid $pid)"

    local start_ts now deadline i name sz elapsed
    start_ts=$(date +%s)
    deadline=$((start_ts + max_min * 60))
    i=0
    while is_alive; do
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            log "$label: max time reached, killing QEMU"
            $SUDO kill "$pid" 2>/dev/null || true
            return 2
        fi
        i=$((i + 1))
        name=$(printf '%s-%04d-%s' "$label" "$i" "$(date +%H%M%S)")
        shot "$name"
        sz=$($SUDO stat -c%s "$FRAMES_DIR/$name.ppm" 2>/dev/null || echo 0)
        elapsed=$(( (now - start_ts) / 60 ))
        log "$label frame $i (${sz}b) @ ${elapsed}m"
        sleep "$FRAME_INTERVAL"
    done
    log "$label: QEMU exited cleanly (guest shutdown)"
    return 0
}

# ---------- PHASE 1: WinPE-driven install ----------
if [ "${SKIP_PHASE1:-0}" != "1" ]; then
    run_phase phase1 "$PHASE1_MAX_MIN" \
        -drive file="$WIN_ISO",media=cdrom,index=2 \
        -drive file="$VIRTIO_ISO",media=cdrom,index=3 \
        -no-reboot \
        -boot once=d,menu=off || { log "phase1 failed"; exit 1; }
fi

log "phase1 complete; relaunching from disk only"

# ---------- PHASE 2: First Windows boot from disk ----------
run_phase phase2 "$PHASE2_MAX_MIN" \
    -boot order=c,menu=off || true

log "frames: $FRAMES_DIR"
log "Guest VNC: 127.0.0.1:${GUEST_VNC_HOST_PORT}"
log "WinRM probe: curl -s -u Administrator:packer -d '<x/>' --header 'Content-Type: application/soap+xml' http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
