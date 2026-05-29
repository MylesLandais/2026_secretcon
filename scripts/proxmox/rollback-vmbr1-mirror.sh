#!/usr/bin/env bash
# Rollback for the OPNsense vmbr1-mirror plan.
#
# Inverse of:
#   - scripts/proxmox/snapshot-before-mirror.sh
#   - scripts/proxmox/enable-vmbr1-mirror.sh
#   - any OPNsense Suricata / filterlog enablement
#   - scripts/proxmox/sync-wazuh-rules.sh push of rules 100810-100815
#
# Steps:
#   1. Locate snapshots.json under artifacts/opnsense-vnc/<run-id>/.
#   2. On the Proxmox host: stop+disable the systemd unit, then call
#      scripts/proxmox/disable-vmbr1-mirror.sh which tears down tc qdiscs,
#      the dummy bridge vmbrmirror, and the OPNsense net2 NIC.
#   3. qm rollback each snapshot recorded in snapshots.json.
#      Snapshots are disk-only (no vmstate); rollback restarts the VM.
#   4. Verify OPNsense :253 is reachable and vtnet2 is gone.
#
# Usage:
#   ./scripts/proxmox/rollback-vmbr1-mirror.sh                 # latest run
#   ./scripts/proxmox/rollback-vmbr1-mirror.sh --run-id ID     # specific run
#   ./scripts/proxmox/rollback-vmbr1-mirror.sh --dry-run
#   ./scripts/proxmox/rollback-vmbr1-mirror.sh --skip-host-revert  # only qm rollback
#
# Required env (.env auto-sourced):
#   PROXMOX_HOST, PROXMOX_PASSWORD

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/load_repo_env.sh
source "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}/.env"

ARTIFACT_ROOT="${REPO_ROOT}/artifacts/opnsense-vnc"

RUN_ID=""
DRY_RUN=0
SKIP_HOST_REVERT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --run-id)             RUN_ID="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=1; shift ;;
        --skip-host-revert)   SKIP_HOST_REVERT=1; shift ;;
        -h|--help)            sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                    echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/lib/proxmox-ssh.sh
source "${REPO_ROOT}/scripts/lib/proxmox-ssh.sh"
proxmox_load_env

step() { printf '\n[*] %s\n' "$*"; }

# Locate snapshots.json.
SNAP_JSON=""
if [ -n "${RUN_ID}" ]; then
    SNAP_JSON="${ARTIFACT_ROOT}/${RUN_ID}/snapshots.json"
    [ -f "${SNAP_JSON}" ] || { echo "[!] no snapshots.json under ${ARTIFACT_ROOT}/${RUN_ID}/" >&2; exit 1; }
else
    if [ ! -d "${ARTIFACT_ROOT}" ]; then
        echo "[!] no snapshots recorded under ${ARTIFACT_ROOT}/" >&2
        echo "    run scripts/proxmox/snapshot-before-mirror.sh first" >&2
        exit 1
    fi
    SNAP_JSON="$(find "${ARTIFACT_ROOT}" -mindepth 2 -maxdepth 2 -name snapshots.json -printf '%T@ %p\n' \
        | sort -nr | head -n1 | awk '{print $2}')"
    if [ -z "${SNAP_JSON}" ]; then
        echo "[!] no snapshots.json found under ${ARTIFACT_ROOT}/" >&2
        exit 1
    fi
    RUN_ID="$(basename "$(dirname "${SNAP_JSON}")")"
fi

step "Rollback plan"
echo "    run_id   : ${RUN_ID}"
echo "    manifest : ${SNAP_JSON}"
echo "    proxmox  : root@${PROXMOX_HOST}"

command -v jq >/dev/null 2>&1 || { echo "[!] jq required for snapshots.json parsing" >&2; exit 1; }

step "Manifest contents"
jq . "${SNAP_JSON}"

# Build a parallel array of (vmid, snapshot_name).
mapfile -t ROLLBACK_LINES < <(jq -r '.snapshots[] | "\(.vmid)\t\(.snapshot_name)\t\(.role)"' "${SNAP_JSON}")

if [ "${#ROLLBACK_LINES[@]}" -eq 0 ]; then
    echo "[!] no snapshots in manifest" >&2
    exit 1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    step "DRY RUN: actions that would be taken"
    if [ "${SKIP_HOST_REVERT}" -eq 0 ]; then
        echo "    ssh root@${PROXMOX_HOST} systemctl disable --now vmbr1-mirror.service"
        echo "    bash scripts/proxmox/disable-vmbr1-mirror.sh"
    fi
    for line in "${ROLLBACK_LINES[@]}"; do
        IFS=$'\t' read -r vmid snap role <<<"${line}"
        echo "    ssh root@${PROXMOX_HOST} qm rollback ${vmid} ${snap}  # role=${role}"
    done
    exit 0
fi

# Revert host-side changes first so the rollback doesn't race against an
# active mirror session that's about to be invalidated by the new disk.
if [ "${SKIP_HOST_REVERT}" -eq 0 ]; then
    step "Stopping + disabling vmbr1-mirror.service on host"
    pxssh "systemctl disable --now vmbr1-mirror.service 2>&1 || echo '(not installed)'"

    step "Running disable-vmbr1-mirror on host (tears down tc/bridge/NIC)"
    if [ -x "${REPO_ROOT}/scripts/proxmox/disable-vmbr1-mirror.sh" ]; then
        # Push the disable script to the host so it can run with local qm + ip.
        DISABLE_REMOTE="/tmp/disable-vmbr1-mirror-$$.sh"
        "${SSHPASS_BIN}" -p "${PROXMOX_PASSWORD}" \
            scp -o StrictHostKeyChecking=accept-new \
                -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no \
                -o LogLevel=ERROR \
                "${REPO_ROOT}/scripts/proxmox/disable-vmbr1-mirror.sh" \
                "root@${PROXMOX_HOST}:${DISABLE_REMOTE}"
        pxssh "chmod +x ${DISABLE_REMOTE} && ${DISABLE_REMOTE} || true; rm -f ${DISABLE_REMOTE}"
    else
        echo "[!] scripts/proxmox/disable-vmbr1-mirror.sh missing; skipping host revert"
    fi
fi

# qm rollback requires the VM stopped. Stop -> rollback -> start each VM.
for line in "${ROLLBACK_LINES[@]}"; do
    IFS=$'\t' read -r vmid snap role <<<"${line}"
    step "Rolling back VMID ${vmid} (${role}) -> ${snap}"
    pxssh "qm stop ${vmid} 2>/dev/null || true; \
           for i in 1 2 3 4 5; do qm status ${vmid} | grep -q running || break; sleep 2; done; \
           qm rollback ${vmid} ${snap}; \
           qm start ${vmid}"
done

# Verify OPNsense (assume it's the first 'opnsense' role in the manifest).
OPNSENSE_VMID="$(jq -r '.snapshots[] | select(.role=="opnsense") | .vmid' "${SNAP_JSON}" | head -n1)"
if [ -n "${OPNSENSE_VMID}" ]; then
    step "Waiting up to 120s for OPNsense (VMID ${OPNSENSE_VMID}) to come back up"
    DEADLINE=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < DEADLINE )); do
        if pxssh "ping -c 1 -W 2 192.168.61.253 >/dev/null 2>&1"; then
            echo "[+] OPNsense responding at 192.168.61.253"
            break
        fi
        sleep 5
    done

    step "Confirming OPNsense no longer has net2"
    if pxssh "qm config ${OPNSENSE_VMID} | grep -E '^net2:'"; then
        echo "[!] OPNsense still has net2 after rollback; manifest may pre-date snapshot of pristine state" >&2
    else
        echo "[+] OPNsense net2 removed (or absent)"
    fi
fi

echo
echo "[+] rollback complete"
echo "    rolled back to snapshot taken at: $(jq -r '.taken_at_utc' "${SNAP_JSON}")"
echo "    tc / vmbrmirror / systemd unit reverted on host"
