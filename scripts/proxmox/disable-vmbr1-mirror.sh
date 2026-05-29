#!/usr/bin/env bash
# Tear down the vmbr1 -> OPNsense MIRROR tc mirror.
#
# Inverse of scripts/proxmox/enable-vmbr1-mirror.sh.
#
# Removes (in order):
#   1. systemd unit /etc/systemd/system/vmbr1-mirror.service (disable + remove)
#   2. tc qdisc del dev vmbr1 ingress / root
#   3. Detaches OPNsense net2 NIC (qm set --delete net2)
#   4. Removes dummy bridge 'vmbrmirror' and its /etc/network/interfaces.d entry
#
# Designed to be safe to run if some / all of the above are already absent.
#
# Usage (from operator workstation, default) -- same pattern as enable-vmbr1-mirror.sh:
#   ./scripts/proxmox/disable-vmbr1-mirror.sh
#   ./scripts/proxmox/disable-vmbr1-mirror.sh --opnsense-vmid 100
#   ./scripts/proxmox/disable-vmbr1-mirror.sh --dry-run
#   ./scripts/proxmox/disable-vmbr1-mirror.sh --keep-nic     # leave net2 attached
#
# Usage (when invoked DIRECTLY on the Proxmox host by rollback script):
#   bash disable-vmbr1-mirror.sh --local             # skip ssh wrapper
#
# Required env (.env auto-sourced; only used in non-local mode):
#   PROXMOX_HOST, PROXMOX_PASSWORD

set -uo pipefail

LOCAL_MODE=0
OPNSENSE_VMID=""
DRY_RUN=0
KEEP_NIC=0
MIRROR_BRIDGE="${MIRROR_BRIDGE:-vmbrmirror}"
MIRROR_NIC_INDEX=2

while [ $# -gt 0 ]; do
    case "$1" in
        --opnsense-vmid)  OPNSENSE_VMID="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --keep-nic)       KEEP_NIC=1; shift ;;
        --mirror-bridge)  MIRROR_BRIDGE="$2"; shift 2 ;;
        --local)          LOCAL_MODE=1; shift ;;
        -h|--help)        sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

SYSTEMD_UNIT="/etc/systemd/system/vmbr1-mirror.service"

# ---------------------------------------------------------- LOCAL MODE
if [ "${LOCAL_MODE}" -eq 1 ]; then
    step() { printf '\n[host] [*] %s\n' "$*"; }

    # If OPNSENSE_VMID not set, try to discover from existing tap names.
    # We look for any tapNiM under the dummy bridge.
    if [ -z "${OPNSENSE_VMID}" ]; then
        if ip link show "${MIRROR_BRIDGE}" >/dev/null 2>&1; then
            # First interface enslaved to vmbrmirror that looks like tap<id>i<n>
            CAND="$(bridge link show 2>/dev/null \
                | awk -v b="${MIRROR_BRIDGE}" '$0 ~ "master "b" " {print $2}' \
                | sed 's/://;s/@.*//' \
                | grep -E '^tap[0-9]+i[0-9]+$' | head -n1)"
            if [ -n "${CAND}" ]; then
                OPNSENSE_VMID="$(echo "${CAND}" | sed -E 's/^tap([0-9]+)i.*/\1/')"
            fi
        fi
        if [ -z "${OPNSENSE_VMID}" ]; then
            # Fallback: scan qm config files for net2 with bridge=vmbrmirror.
            for c in /etc/pve/qemu-server/*.conf; do
                [ -f "$c" ] || continue
                if grep -qE "^net${MIRROR_NIC_INDEX}:.*bridge=${MIRROR_BRIDGE}\\b" "$c"; then
                    OPNSENSE_VMID="$(basename "$c" .conf)"
                    break
                fi
            done
        fi
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        step "DRY RUN: would tear down vmbr1 mirror"
        echo "    systemctl disable --now vmbr1-mirror.service"
        echo "    rm -f ${SYSTEMD_UNIT}"
        echo "    tc qdisc del dev vmbr1 ingress"
        echo "    tc qdisc del dev vmbr1 root"
        [ "${KEEP_NIC}" -eq 0 ] && [ -n "${OPNSENSE_VMID}" ] \
            && echo "    qm set ${OPNSENSE_VMID} --delete net${MIRROR_NIC_INDEX}"
        echo "    ip link delete ${MIRROR_BRIDGE} (after NIC detach)"
        exit 0
    fi

    step "Disabling + removing systemd unit"
    if systemctl is-enabled vmbr1-mirror.service >/dev/null 2>&1 \
        || systemctl is-active vmbr1-mirror.service >/dev/null 2>&1; then
        systemctl disable --now vmbr1-mirror.service 2>&1 || true
    fi
    if [ -f "${SYSTEMD_UNIT}" ]; then
        rm -f "${SYSTEMD_UNIT}"
        systemctl daemon-reload
    fi

    step "Removing tc qdiscs on vmbr1"
    tc qdisc del dev vmbr1 ingress 2>&1 || true
    tc qdisc del dev vmbr1 root    2>&1 || true

    if [ "${KEEP_NIC}" -eq 0 ] && [ -n "${OPNSENSE_VMID}" ]; then
        step "Detaching net${MIRROR_NIC_INDEX} from OPNsense (VMID ${OPNSENSE_VMID})"
        qm set "${OPNSENSE_VMID}" --delete "net${MIRROR_NIC_INDEX}" 2>&1 || true
    elif [ -z "${OPNSENSE_VMID}" ]; then
        echo "[host] [!] OPNsense VMID unresolved; skipping NIC detach"
        echo "[host]     pass --opnsense-vmid <id> to detach explicitly"
    fi

    step "Removing dummy bridge ${MIRROR_BRIDGE}"
    # If the bridge still has slaves (e.g. NIC kept), don't delete it.
    SLAVES="$(bridge link show 2>/dev/null \
        | awk -v b="${MIRROR_BRIDGE}" '$0 ~ "master "b" "' | wc -l)"
    if [ "${SLAVES}" -gt 0 ]; then
        echo "[host] [!] ${MIRROR_BRIDGE} still has ${SLAVES} slave(s); leaving it"
    else
        if ip link show "${MIRROR_BRIDGE}" >/dev/null 2>&1; then
            ip link set "${MIRROR_BRIDGE}" down 2>&1 || true
            ip link delete "${MIRROR_BRIDGE}" 2>&1 || true
        fi
        rm -f "/etc/network/interfaces.d/${MIRROR_BRIDGE}" 2>&1 || true
    fi

    echo
    echo "[host] [+] vmbr1 mirror torn down"
    exit 0
fi

# ---------------------------------------------------------- WRAPPER MODE
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/load_repo_env.sh
source "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}/.env"

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
if [ -z "${SSHPASS_BIN}" ] && command -v nix >/dev/null 2>&1; then
    SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
fi
[ -n "${SSHPASS_BIN}" ] || { echo "[!] sshpass not found" >&2; exit 1; }

step() { printf '\n[*] %s\n' "$*"; }

step "Plan"
echo "    proxmox       : root@${PROXMOX_HOST}"
echo "    opnsense_vmid : ${OPNSENSE_VMID:-(auto-resolve on host)}"
echo "    keep_nic      : ${KEEP_NIC}"
echo "    dry_run       : ${DRY_RUN}"

REMOTE="/tmp/disable-vmbr1-mirror-$$.sh"
"${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" \
    scp -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o LogLevel=ERROR \
        "${BASH_SOURCE[0]}" "root@${PROXMOX_HOST}:${REMOTE}"

ARGS=("--local" "--mirror-bridge" "${MIRROR_BRIDGE}")
[ -n "${OPNSENSE_VMID}" ] && ARGS+=("--opnsense-vmid" "${OPNSENSE_VMID}")
[ "${DRY_RUN}" -eq 1 ] && ARGS+=("--dry-run")
[ "${KEEP_NIC}" -eq 1 ] && ARGS+=("--keep-nic")

"${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" ssh \
    -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o LogLevel=ERROR \
    "root@${PROXMOX_HOST}" "chmod +x ${REMOTE} && ${REMOTE} ${ARGS[*]}; rc=\$?; rm -f ${REMOTE}; exit \$rc"
RC=$?

if [ "${RC}" -ne 0 ]; then
    echo "[!] tear-down failed (rc=${RC})" >&2
    exit "${RC}"
fi

echo
echo "[+] vmbr1 mirror tear-down complete"
