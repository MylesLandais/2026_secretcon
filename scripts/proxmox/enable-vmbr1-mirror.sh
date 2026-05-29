#!/usr/bin/env bash
# Mirror vmbr1 traffic to OPNsense's third NIC (vtnet2 == MIRROR).
#
# This is the host-side half of the SPAN-to-OPNsense pipeline. After
# this script succeeds, OPNsense sees all vmbr1 ingress+egress on its
# new vtnet2 interface; the OPNsense-side Suricata + filterlog config
# then ships EVE + pf events to the Wazuh manager.
#
# Idempotent. Re-running rebuilds the tc qdiscs without disturbing the
# already-attached NIC.
#
# Steps:
#   1. Auto-resolve OPNsense VMID (or accept --opnsense-vmid).
#   2. Create dummy Linux bridge 'vmbrmirror' if missing.
#   3. Attach net2 (virtio, bridge=vmbrmirror, firewall=0) to OPNsense
#      if not already present.  Requires an OPNsense reboot before
#      tap<vmid>i2 surfaces -- script re-runs cleanly after.
#   4. Install ingress + egress 'mirred egress mirror' tc filters on
#      vmbr1 pointing at tap<vmid>i2.
#   5. Bump tap MTU to vmbr1 MTU and force promisc up.
#   6. Install systemd unit /etc/systemd/system/vmbr1-mirror.service so
#      the tc filters re-apply on Proxmox boot.
#
# Risk: traffic doubles on vmbr1's egress side (one copy to the
# destination port, one copy to the mirror tap). Acceptable in this lab
# (low pps). The lab capture interface is unrelated to production.
#
# Usage (from operator workstation):
#   ./scripts/proxmox/enable-vmbr1-mirror.sh
#   ./scripts/proxmox/enable-vmbr1-mirror.sh --opnsense-vmid 100
#   ./scripts/proxmox/enable-vmbr1-mirror.sh --dry-run
#   ./scripts/proxmox/enable-vmbr1-mirror.sh --no-restart   # don't reboot OPNsense even if net2 was just attached
#
# Required env (.env auto-sourced):
#   PROXMOX_HOST, PROXMOX_PASSWORD

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/load_repo_env.sh
source "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}/.env"

OPNSENSE_VMID=""
DRY_RUN=0
NO_RESTART=0
MIRROR_BRIDGE="${MIRROR_BRIDGE:-vmbrmirror}"
MIRROR_NIC_INDEX=2

while [ $# -gt 0 ]; do
    case "$1" in
        --opnsense-vmid)  OPNSENSE_VMID="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --no-restart)     NO_RESTART=1; shift ;;
        --mirror-bridge)  MIRROR_BRIDGE="$2"; shift 2 ;;
        -h|--help)        sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/lib/proxmox-ssh.sh
source "${REPO_ROOT}/scripts/lib/proxmox-ssh.sh"
proxmox_load_env

step() { printf '\n[*] %s\n' "$*"; }

# Resolve OPNsense VMID if not provided (same logic as snapshot-before-mirror.sh).
if [ -z "${OPNSENSE_VMID}" ]; then
    step "Resolving OPNsense VMID"
    MATCHES="$(pxssh "qm list | awk 'NR>1 && tolower(\$2) ~ /opnsense/ {print \$1}'")"
    COUNT="$(printf '%s\n' "${MATCHES}" | grep -c '^[0-9]')"
    if [ "${COUNT}" -eq 0 ]; then
        echo "[!] no VM with 'opnsense' in name on ${PROXMOX_HOST}" >&2
        echo "    pin with --opnsense-vmid <id>" >&2
        exit 1
    elif [ "${COUNT}" -gt 1 ]; then
        echo "[!] multiple OPNsense candidates; pin with --opnsense-vmid:" >&2
        printf '    %s\n' ${MATCHES} >&2
        exit 1
    fi
    OPNSENSE_VMID="$(printf '%s\n' "${MATCHES}" | head -n1)"
    echo "    OPNsense VMID = ${OPNSENSE_VMID}"
fi

TAP="tap${OPNSENSE_VMID}i${MIRROR_NIC_INDEX}"
SYSTEMD_UNIT="/etc/systemd/system/vmbr1-mirror.service"

step "Plan"
echo "    proxmox       : root@${PROXMOX_HOST}"
echo "    opnsense_vmid : ${OPNSENSE_VMID}"
echo "    mirror_bridge : ${MIRROR_BRIDGE}"
echo "    target_tap    : ${TAP}"
echo "    systemd_unit  : ${SYSTEMD_UNIT}"
echo "    dry_run       : ${DRY_RUN}"

if [ "${DRY_RUN}" -eq 1 ]; then
    step "DRY RUN: not modifying host"
    exit 0
fi

# Build the host-side script as a heredoc, then exec it remotely.
HOST_SCRIPT="$(mktemp /tmp/enable-vmbr1-mirror-host.XXXXXX.sh)"
trap 'rm -f "${HOST_SCRIPT}"' EXIT
cat > "${HOST_SCRIPT}" <<HOST
#!/usr/bin/env bash
set -uo pipefail

OPNSENSE_VMID="${OPNSENSE_VMID}"
MIRROR_BRIDGE="${MIRROR_BRIDGE}"
MIRROR_NIC_INDEX=${MIRROR_NIC_INDEX}
TAP="${TAP}"
NO_RESTART=${NO_RESTART}
SYSTEMD_UNIT="${SYSTEMD_UNIT}"

step() { printf '\n[host] [*] %s\n' "\$*"; }

# 1. Dummy bridge for the mirror tap.
if ! ip link show "\${MIRROR_BRIDGE}" >/dev/null 2>&1; then
    step "Creating dummy bridge \${MIRROR_BRIDGE}"
    ip link add name "\${MIRROR_BRIDGE}" type bridge
    ip link set "\${MIRROR_BRIDGE}" up
    # Persist via /etc/network/interfaces.d for Proxmox.
    if [ ! -f "/etc/network/interfaces.d/\${MIRROR_BRIDGE}" ]; then
        cat > "/etc/network/interfaces.d/\${MIRROR_BRIDGE}" <<IFACE
auto \${MIRROR_BRIDGE}
iface \${MIRROR_BRIDGE} inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # SecretCon: dummy bridge that holds the OPNsense MIRROR tap so the
    # tc mirror has a stable named destination across reboots.
IFACE
    fi
else
    step "Dummy bridge \${MIRROR_BRIDGE} already present"
fi

# 2. Attach net2 NIC to OPNsense if missing.
if ! qm config "\${OPNSENSE_VMID}" | grep -qE "^net\${MIRROR_NIC_INDEX}:"; then
    step "Attaching net\${MIRROR_NIC_INDEX} to OPNsense (bridge=\${MIRROR_BRIDGE})"
    qm set "\${OPNSENSE_VMID}" --net\${MIRROR_NIC_INDEX} \
        "virtio,bridge=\${MIRROR_BRIDGE},firewall=0"
    if [ "\${NO_RESTART}" -eq 0 ]; then
        step "Rebooting OPNsense so the new NIC surfaces (qm reboot)"
        qm reboot "\${OPNSENSE_VMID}"
        # Wait up to 180s for OPNsense to be back (qm status running) and
        # the tap to surface.
        DEADLINE=\$((\$(date +%s) + 180))
        while (( \$(date +%s) < DEADLINE )); do
            sleep 5
            qm status "\${OPNSENSE_VMID}" 2>&1 | grep -q running || continue
            ip link show "\${TAP}" >/dev/null 2>&1 && break
        done
    else
        echo "[host] [!] --no-restart: net\${MIRROR_NIC_INDEX} attached but tap will not surface until OPNsense reboots"
        echo "[host]     re-run this script after rebooting OPNsense"
        exit 0
    fi
else
    step "net\${MIRROR_NIC_INDEX} already attached on OPNsense"
fi

# 3. Tap must exist now.
if ! ip link show "\${TAP}" >/dev/null 2>&1; then
    echo "[host] [!] \${TAP} not present even after attach; is OPNsense running?" >&2
    qm status "\${OPNSENSE_VMID}" >&2 || true
    exit 1
fi

# 4. Install tc qdiscs (clean slate then add).
step "Installing tc ingress+egress mirror on vmbr1 -> \${TAP}"
tc qdisc del dev vmbr1 ingress 2>/dev/null || true
tc qdisc del dev vmbr1 root    2>/dev/null || true

tc qdisc add  dev vmbr1 handle ffff: ingress
tc filter add dev vmbr1 parent ffff: matchall \
    action mirred egress mirror dev "\${TAP}"

tc qdisc replace dev vmbr1 root handle 1: prio
tc filter add dev vmbr1 parent 1: matchall \
    action mirred egress mirror dev "\${TAP}"

# 5. MTU sanity + promisc on the tap.
MTU=\$(ip -o link show vmbr1 | awk '{for(i=1;i<=NF;i++) if (\$i=="mtu") print \$(i+1)}')
ip link set "\${TAP}" mtu "\${MTU}"
ip link set "\${TAP}" promisc on
ip link set "\${TAP}" up

# 6. Persist via systemd unit so the mirror re-applies on boot.
if [ ! -f "\${SYSTEMD_UNIT}" ]; then
    step "Installing systemd unit \${SYSTEMD_UNIT}"
    cat > "\${SYSTEMD_UNIT}" <<UNIT
[Unit]
Description=SecretCon vmbr1 -> OPNsense MIRROR tc mirror
After=network.target qemu-server@\${OPNSENSE_VMID}.service
Wants=qemu-server@\${OPNSENSE_VMID}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/bash -c 'until /usr/sbin/ip link show \${TAP} >/dev/null 2>&1; do sleep 2; done'
ExecStart=/usr/sbin/tc qdisc del dev vmbr1 ingress
ExecStart=-/usr/sbin/tc qdisc del dev vmbr1 root
ExecStart=/usr/sbin/tc qdisc add  dev vmbr1 handle ffff: ingress
ExecStart=/usr/sbin/tc filter add dev vmbr1 parent ffff: matchall action mirred egress mirror dev \${TAP}
ExecStart=/usr/sbin/tc qdisc replace dev vmbr1 root handle 1: prio
ExecStart=/usr/sbin/tc filter add dev vmbr1 parent 1: matchall action mirred egress mirror dev \${TAP}
ExecStart=/usr/sbin/ip link set \${TAP} mtu \${MTU}
ExecStart=/usr/sbin/ip link set \${TAP} promisc on
ExecStart=/usr/sbin/ip link set \${TAP} up
ExecStop=-/usr/sbin/tc qdisc del dev vmbr1 ingress
ExecStop=-/usr/sbin/tc qdisc del dev vmbr1 root

[Install]
WantedBy=multi-user.target
UNIT
    # ExecStart with leading '-' tolerates missing qdiscs on first start.
    # First ExecStart (qdisc del ingress) intentionally fails on a clean
    # boot - leading dash above for the root del isn't enough because
    # systemd needs at least one non-failing ExecStart, hence we follow
    # immediately with the add lines.
    sed -i 's|^ExecStart=/usr/sbin/tc qdisc del dev vmbr1 ingress$|ExecStart=-/usr/sbin/tc qdisc del dev vmbr1 ingress|' "\${SYSTEMD_UNIT}"
    systemctl daemon-reload
    systemctl enable vmbr1-mirror.service
else
    step "systemd unit \${SYSTEMD_UNIT} already present (not overwriting)"
fi

# 7. Verify the mirror is active.
step "Verifying tc mirror"
tc -s filter show dev vmbr1 ingress | head -20
echo "---"
tc -s filter show dev vmbr1 root    | head -20

echo
echo "[host] [+] vmbr1 -> \${TAP} mirror active (MTU \${MTU})"
echo "[host]     systemd: systemctl status vmbr1-mirror.service"
echo "[host]     tear down: scripts/proxmox/disable-vmbr1-mirror.sh"
HOST

REMOTE="/tmp/enable-vmbr1-mirror-$$.sh"
step "Uploading host-side script to root@${PROXMOX_HOST}:${REMOTE}"
"${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" \
    scp -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o LogLevel=ERROR \
        "${HOST_SCRIPT}" "root@${PROXMOX_HOST}:${REMOTE}"

step "Executing host-side script"
pxssh "chmod +x ${REMOTE} && ${REMOTE}; rc=\$?; rm -f ${REMOTE}; exit \$rc"
RC=$?

if [ "${RC}" -ne 0 ]; then
    echo "[!] host-side script failed (rc=${RC})" >&2
    exit "${RC}"
fi

echo
echo "[+] enable-vmbr1-mirror complete"
echo "    OPNsense will see vmbr1 traffic on vtnet2 (MIRROR)."
echo "    next: configure Suricata + filterlog on OPNsense"
echo "          scripts/proxmox/opnsense-export-pcap.sh --probe"
