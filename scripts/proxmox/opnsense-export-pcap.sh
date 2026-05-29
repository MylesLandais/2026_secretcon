#!/usr/bin/env bash
# Run a time/count bounded packet capture on the OPNsense MIRROR
# interface (vtnet2, vmbr1 SPAN) and push the resulting pcap into the
# crit-capture Arkime VM via scripts/proxmox/sync-arkime-pcap.sh.
#
# We use tcpdump over SSH rather than the OPNsense
# /api/diagnostics/packet_capture endpoints because the discovery doc
# (docs/notes/opnsense-discovery-2026-05-14.md) flagged the API path
# layout as version-dependent (many endpoints return 404). The Saved
# Profile in the OPNsense UI is a UI convenience only; the on-disk
# tcpdump is identical either way.
#
# Default capture: BPF 'tcp port 5900', 50000 packets max, 120s max,
# snaplen 16384. Override via flags.
#
# Usage:
#   ./scripts/proxmox/opnsense-export-pcap.sh
#   ./scripts/proxmox/opnsense-export-pcap.sh --duration 60 --max-packets 20000
#   ./scripts/proxmox/opnsense-export-pcap.sh --bpf 'tcp port 5900 or tcp port 5985'
#   ./scripts/proxmox/opnsense-export-pcap.sh --no-arkime --out /tmp/foo.pcap
#   ./scripts/proxmox/opnsense-export-pcap.sh --probe   # just verify the interface is alive
#
# Required env (.env auto-sourced):
#   OPNSENSE_SSH_PASSWORD       root@opnsense ssh password
#   PROXMOX_HOST, PROXMOX_PASSWORD  (when pushing to Arkime via the jump)
#
# Optional env:
#   OPNSENSE_HOST               default 192.168.61.253
#   OPNSENSE_SSH_USER           default root
#   OPNSENSE_MIRROR_IFACE       default vtnet2
#   ARKIME_HOST                 default 192.168.61.11 (consumed by sync-arkime-pcap.sh)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/load_repo_env.sh
source "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}/.env"

DURATION=120
MAX_PACKETS=50000
SNAPLEN=16384
BPF="tcp port 5900"
OUT_PATH=""
NO_ARKIME=0
PROBE_ONLY=0
RUN_ID=""
declare -a ARKIME_TAGS

while [ $# -gt 0 ]; do
    case "$1" in
        --duration)     DURATION="$2"; shift 2 ;;
        --max-packets)  MAX_PACKETS="$2"; shift 2 ;;
        --snaplen)      SNAPLEN="$2"; shift 2 ;;
        --bpf)          BPF="$2"; shift 2 ;;
        --out)          OUT_PATH="$2"; shift 2 ;;
        --no-arkime)    NO_ARKIME=1; shift ;;
        --probe)        PROBE_ONLY=1; shift ;;
        --tag)          ARKIME_TAGS+=("$2"); shift 2 ;;
        --run-id)       RUN_ID="$2"; shift 2 ;;
        -h|--help)      sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

OPNSENSE_HOST="${OPNSENSE_HOST:-192.168.61.253}"
OPNSENSE_SSH_USER="${OPNSENSE_SSH_USER:-root}"
OPNSENSE_MIRROR_IFACE="${OPNSENSE_MIRROR_IFACE:-vtnet2}"
: "${OPNSENSE_SSH_PASSWORD:?OPNSENSE_SSH_PASSWORD must be set in .env}"

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
if [ -z "${SSHPASS_BIN}" ] && command -v nix >/dev/null 2>&1; then
    SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
fi
[ -n "${SSHPASS_BIN}" ] || { echo "[!] sshpass not found" >&2; exit 1; }

OPN_SSH_OPTS=(
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o LogLevel=ERROR
)

opn_ssh() {
    "${SSHPASS_BIN}" -p "${OPNSENSE_SSH_PASSWORD}" \
        ssh "${OPN_SSH_OPTS[@]}" "${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}" "$@"
}
opn_scp_from() {
    "${SSHPASS_BIN}" -p "${OPNSENSE_SSH_PASSWORD}" \
        scp "${OPN_SSH_OPTS[@]}" "${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}:$1" "$2"
}

step() { printf '\n[*] %s\n' "$*"; }

if [ -z "${RUN_ID}" ]; then
    RUN_ID="opnsense-vnc-$(date -u +%Y%m%dT%H%M%SZ)"
fi

if [ -z "${OUT_PATH}" ]; then
    OUT_DIR="${REPO_ROOT}/artifacts/opnsense-vnc/${RUN_ID}"
    mkdir -p "${OUT_DIR}"
    OUT_PATH="${OUT_DIR}/opnsense-mirror.pcap"
fi

step "Plan"
echo "    opnsense host     : ${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}"
echo "    mirror iface      : ${OPNSENSE_MIRROR_IFACE}"
echo "    bpf               : ${BPF}"
echo "    duration (max)    : ${DURATION}s"
echo "    max packets       : ${MAX_PACKETS}"
echo "    snaplen           : ${SNAPLEN}"
echo "    out (local)       : ${OUT_PATH}"
echo "    push to arkime    : $([ "${NO_ARKIME}" -eq 0 ] && echo yes || echo no)"

# 1. Probe the interface so the operator catches misconfig fast.
step "Probe: ${OPNSENSE_MIRROR_IFACE} exists + has frames"
PROBE_OUT="$(opn_ssh "ifconfig ${OPNSENSE_MIRROR_IFACE} 2>/dev/null | head -5; \
                       echo '---'; \
                       netstat -inb 2>/dev/null | grep -E '^(${OPNSENSE_MIRROR_IFACE}|Name)' | head -5; \
                       echo '---'; \
                       tcpdump -nni ${OPNSENSE_MIRROR_IFACE} -c 1 -w /dev/null -W 1 -G 2 2>&1 | tail -3" || true)"
echo "${PROBE_OUT}"
if ! printf '%s' "${PROBE_OUT}" | grep -qE "(packets captured|received by filter)"; then
    echo "[!] ${OPNSENSE_MIRROR_IFACE} did not see any packets in the probe window." >&2
    echo "    is the host-side tc mirror up?  scripts/proxmox/enable-vmbr1-mirror.sh" >&2
    if [ "${PROBE_ONLY}" -eq 1 ]; then
        exit 1
    fi
fi

if [ "${PROBE_ONLY}" -eq 1 ]; then
    echo "[+] probe complete; capture interface is live"
    exit 0
fi

# 2. Capture.
REMOTE_PCAP="/tmp/opnsense-mirror-${RUN_ID}.pcap"
step "Starting tcpdump on OPNsense (max ${DURATION}s OR ${MAX_PACKETS} packets)"
opn_ssh "tcpdump -nni ${OPNSENSE_MIRROR_IFACE} \
            -s ${SNAPLEN} \
            -c ${MAX_PACKETS} \
            -w ${REMOTE_PCAP} \
            -G ${DURATION} -W 1 \
            '${BPF}' 2>&1 | tail -5" \
    || { echo "[!] tcpdump on OPNsense failed" >&2; opn_ssh "ls -la ${REMOTE_PCAP} 2>&1 || true"; exit 1; }

# tcpdump -G with -W 1 rotates AT MOST 1 file then exits at -G seconds.
# But -c <N> exits immediately at N packets without waiting for the
# rotation. The actual file produced is REMOTE_PCAP.

step "Verifying remote pcap"
REMOTE_BYTES="$(opn_ssh "stat -f '%z' ${REMOTE_PCAP} 2>/dev/null || stat -c '%s' ${REMOTE_PCAP} 2>/dev/null || echo 0")"
echo "    ${REMOTE_PCAP} = ${REMOTE_BYTES} bytes"
if [ "${REMOTE_BYTES}" -le 24 ]; then
    echo "[!] pcap is empty (24 bytes is just the pcap file header)" >&2
    echo "    no frames were captured -- mirror or BPF is wrong" >&2
    opn_ssh "rm -f ${REMOTE_PCAP}" || true
    exit 1
fi

step "Downloading ${REMOTE_PCAP} -> ${OUT_PATH}"
mkdir -p "$(dirname "${OUT_PATH}")"
opn_scp_from "${REMOTE_PCAP}" "${OUT_PATH}"
opn_ssh "rm -f ${REMOTE_PCAP}" || true

step "Local pcap summary"
ls -la "${OUT_PATH}"
if command -v tshark >/dev/null 2>&1; then
    echo
    tshark -r "${OUT_PATH}" -q -z io,phs 2>/dev/null | head -30 || true
fi

# 3. Optional Arkime push.
if [ "${NO_ARKIME}" -eq 0 ]; then
    step "Pushing pcap into crit-capture Arkime"
    ARKIME_CMD=("${REPO_ROOT}/scripts/proxmox/sync-arkime-pcap.sh"
                "--tag" "opnsense-mirror"
                "--tag" "${RUN_ID}")
    for t in "${ARKIME_TAGS[@]}"; do
        ARKIME_CMD+=("--tag" "${t}")
    done
    ARKIME_CMD+=("${OUT_PATH}")
    echo "    ${ARKIME_CMD[*]}"
    "${ARKIME_CMD[@]}"
fi

echo
echo "[+] opnsense-export-pcap complete"
echo "    pcap : ${OUT_PATH}"
echo "    next : tshark -r ${OUT_PATH} -Y vnc -V | less   # local decode"
echo "           OR open Arkime: http://${ARKIME_HOST:-192.168.61.11}:8005"
