#!/usr/bin/env bash
set -euo pipefail

# Boot Win11 LTSC unattended in QEMU/KVM and capture periodic screendumps
# to prove the desktop comes up. No Packer involvement.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/win11-auto}"
FRAMES_DIR="$WORK_DIR/frames"
WIN_ISO="${WIN_ISO:-$HOME/Downloads/win11-ltsc-24h2-unattended.iso}"
VIRTIO_ISO="${VIRTIO_ISO:-$HOME/Downloads/virtio-win.iso}"
AUTOUNATTEND_XML="$REPO_ROOT/provisioning/autounattend.xml"

OVMF_CODE="/run/libvirt/nix-ovmf/edk2-x86_64-code.fd"
OVMF_VARS_TEMPLATE="/run/libvirt/nix-ovmf/edk2-i386-vars.fd"

VNC_DISPLAY="${VNC_DISPLAY:-0}"        # VNC on 127.0.0.1:5900
WINRM_HOST_PORT="${WINRM_HOST_PORT:-15985}"
RDP_HOST_PORT="${RDP_HOST_PORT:-13389}"
MAX_MINUTES="${MAX_MINUTES:-45}"
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
# xorriso comes from nix-shell on demand

[ -f "$WIN_ISO" ] || { echo "missing Win11 ISO: $WIN_ISO" >&2; exit 1; }
[ -f "$VIRTIO_ISO" ] || { echo "missing virtio-win ISO: $VIRTIO_ISO" >&2; exit 1; }
[ -f "$AUTOUNATTEND_XML" ] || { echo "missing autounattend: $AUTOUNATTEND_XML" >&2; exit 1; }
[ -f "$OVMF_CODE" ] || { echo "missing OVMF code: $OVMF_CODE" >&2; exit 1; }
[ -f "$OVMF_VARS_TEMPLATE" ] || { echo "missing OVMF vars template: $OVMF_VARS_TEMPLATE" >&2; exit 1; }

log "preparing $WORK_DIR"
$SUDO rm -rf "$WORK_DIR"
mkdir -p "$FRAMES_DIR" 2>/dev/null || $SUDO mkdir -p "$FRAMES_DIR"
$SUDO chown -R "$(id -u):$(id -g)" "$WORK_DIR" 2>/dev/null || true

# autounattend.xml is now embedded at the root of $WIN_ISO by
# scripts/build-unattend-iso.sh — no separate unattend media needed.
[ -f "$WIN_ISO" ] || { echo "$WIN_ISO missing; run scripts/build-unattend-iso.sh first" >&2; exit 1; }

log "creating 80G qcow2 disk"
qemu-img create -f qcow2 "$WORK_DIR/disk.qcow2" 80G >/dev/null

log "copying OVMF vars"
cp "$OVMF_VARS_TEMPLATE" "$WORK_DIR/vars.fd"
chmod u+w "$WORK_DIR/vars.fd"

MONITOR_SOCK="$WORK_DIR/monitor.sock"
PIDFILE="$WORK_DIR/qemu.pid"
QEMU_LOG="$WORK_DIR/qemu.log"

log "launching QEMU (VNC :$VNC_DISPLAY, WinRM->$WINRM_HOST_PORT, RDP->$RDP_HOST_PORT)"
$SUDO qemu-system-x86_64 \
    -name win11-auto \
    -enable-kvm \
    -machine q35,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -cpu host \
    -smp 4 \
    -m 8192 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$WORK_DIR/vars.fd" \
    -drive file="$WORK_DIR/disk.qcow2",if=none,id=os,format=qcow2,cache=writeback,discard=unmap \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=os,bus=ahci0.0 \
    -drive file="$WIN_ISO",media=cdrom,index=2 \
    -drive file="$VIRTIO_ISO",media=cdrom,index=3 \
    -netdev user,id=n0,hostfwd=tcp::${WINRM_HOST_PORT}-:5985,hostfwd=tcp::${RDP_HOST_PORT}-:3389 \
    -device virtio-net,netdev=n0 \
    -vga std \
    -display none \
    -vnc 127.0.0.1:${VNC_DISPLAY} \
    -monitor unix:"$MONITOR_SOCK",server,nowait \
    -boot order=dc,menu=off \
    -rtc base=localtime,clock=host \
    -daemonize \
    -pidfile "$PIDFILE" \
    >"$QEMU_LOG" 2>&1

# wait for monitor socket
for _ in $(seq 1 20); do
    [ -S "$MONITOR_SOCK" ] && break
    sleep 0.5
done
[ -S "$MONITOR_SOCK" ] || { echo "monitor socket never appeared; see $QEMU_LOG" >&2; cat "$QEMU_LOG" >&2; exit 1; }

QEMU_PID="$($SUDO cat "$PIDFILE" 2>/dev/null || true)"
log "QEMU started (pid $QEMU_PID). VNC: vnc://127.0.0.1:5900. Logs: $QEMU_LOG"

# Using efisys_noprompt boot image — no "Press any key" required.

log "frames every ${FRAME_INTERVAL}s -> $FRAMES_DIR (max ${MAX_MINUTES} min)"

shot() {
    local name="$1"
    # qemu monitor screendump: write PPM to file (qemu writes as the qemu user — root if sudo'd)
    printf 'screendump %s\n' "$WORK_DIR/frames/$name.ppm" \
        | $SUDO socat - UNIX-CONNECT:"$MONITOR_SOCK" >/dev/null 2>&1 || true
}

is_alive() {
    [ -n "$QEMU_PID" ] && $SUDO kill -0 "$QEMU_PID" 2>/dev/null
}

trap 'log "interrupted"; is_alive && $SUDO kill "$QEMU_PID" 2>/dev/null || true' INT TERM

start_ts=$(date +%s)
deadline=$((start_ts + MAX_MINUTES * 60))
i=0
while is_alive; do
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && { log "max time reached"; break; }
    i=$((i + 1))
    name=$(printf 'frame-%04d-%s' "$i" "$(date +%H%M%S)")
    shot "$name"
    sz=$($SUDO stat -c%s "$FRAMES_DIR/$name.ppm" 2>/dev/null || echo 0)
    elapsed=$(( (now - start_ts) / 60 ))
    log "frame $i (${sz}b) @ ${elapsed}m"
    sleep "$FRAME_INTERVAL"
done

log "loop ended; capturing final frame"
shot "final-$(date +%H%M%S)"
$SUDO chown -R "$(id -u):$(id -g)" "$WORK_DIR" 2>/dev/null || true
log "frames: $FRAMES_DIR"
ls -lh "$FRAMES_DIR" | tail -10
log "view latest: feh \"\$(ls -t $FRAMES_DIR/*.ppm | head -1)\""
log "live VNC:    remmina -c vnc://127.0.0.1:5900"
log "WinRM probe: curl -s -u Administrator:packer -d '<x/>' --header 'Content-Type: application/soap+xml' http://127.0.0.1:${WINRM_HOST_PORT}/wsman"
