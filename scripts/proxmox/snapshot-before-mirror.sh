#!/usr/bin/env bash
# Pre-change snapshot for the OPNsense vmbr1-mirror plan.
#
# Snapshots OPNsense (auto-resolved VMID) and the Wazuh manager VMID 110
# on the SecretCon Proxmox host before any of the following plan steps
# touch them:
#   - scripts/proxmox/enable-vmbr1-mirror.sh (adds net2 NIC to OPNsense)
#   - OPNsense Suricata + filterlog enablement
#   - scripts/proxmox/sync-wazuh-rules.sh push of rules 100810-100815
#
# Per user choice we take DISK-ONLY snapshots (no --vmstate). Rollback
# via scripts/proxmox/rollback-vmbr1-mirror.sh will restart the VMs and
# lose live pf/ARP state but otherwise restore the disk image cleanly.
#
# Records the snapshot names + UTC timestamp + git HEAD into
# artifacts/opnsense-vnc/pre-change-<RUN_ID>/snapshots.json so the
# rollback script can find them later.
#
# Usage:
#   ./scripts/proxmox/snapshot-before-mirror.sh
#   ./scripts/proxmox/snapshot-before-mirror.sh --opnsense-vmid 100
#   ./scripts/proxmox/snapshot-before-mirror.sh --run-id my-rollout
#   ./scripts/proxmox/snapshot-before-mirror.sh --dry-run
#
# Required env (.env auto-sourced):
#   PROXMOX_HOST, PROXMOX_PASSWORD
#
# Optional env:
#   WAZUH_VMID            default 110

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/load_repo_env.sh
source "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}/.env"

OPNSENSE_VMID=""
WAZUH_VMID="${WAZUH_VMID:-110}"
RUN_ID=""
DRY_RUN=0
SKIP_WAZUH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --opnsense-vmid) OPNSENSE_VMID="$2"; shift 2 ;;
        --wazuh-vmid)    WAZUH_VMID="$2"; shift 2 ;;
        --run-id)        RUN_ID="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --skip-wazuh)    SKIP_WAZUH=1; shift ;;
        -h|--help)       sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/lib/proxmox-ssh.sh
source "${REPO_ROOT}/scripts/lib/proxmox-ssh.sh"
proxmox_load_env

step() { printf '\n[*] %s\n' "$*"; }

if [ -z "${RUN_ID}" ]; then
    RUN_ID="pre-vmbr1-mirror-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/opnsense-vnc/${RUN_ID}"
mkdir -p "${OUT_DIR}"
SNAP_JSON="${OUT_DIR}/snapshots.json"
LOG="${OUT_DIR}/snapshot.log"
exec > >(tee -a "${LOG}") 2>&1

step "Snapshot plan"
echo "    run_id        : ${RUN_ID}"
echo "    proxmox       : root@${PROXMOX_HOST}"
echo "    out_dir       : ${OUT_DIR}"

# Resolve OPNsense VMID if not provided.
if [ -z "${OPNSENSE_VMID}" ]; then
    step "Resolving OPNsense VMID via 'qm list | grep -i opnsense'"
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
    echo "    resolved      : OPNsense VMID = ${OPNSENSE_VMID}"
fi

echo "    opnsense_vmid : ${OPNSENSE_VMID}"
echo "    wazuh_vmid    : ${WAZUH_VMID}"

# Pre-snapshot sanity check.
step "Pre-snapshot sanity check"
pxssh "qm config ${OPNSENSE_VMID} | grep -E '^(name|net[0-9]+|memory|cores):'"
echo
pxssh "pvesm status"
echo
step "Existing snapshots on OPNsense (${OPNSENSE_VMID})"
pxssh "qm listsnapshot ${OPNSENSE_VMID} 2>/dev/null || echo '(none)'"
if [ "${SKIP_WAZUH}" -eq 0 ]; then
    step "Existing snapshots on Wazuh (${WAZUH_VMID})"
    pxssh "qm listsnapshot ${WAZUH_VMID} 2>/dev/null || echo '(none)'"
fi

# Snapshot names embed the RUN_ID so multiple runs don't collide.
# Proxmox snapshot names must match ^[a-zA-Z0-9][a-zA-Z0-9_\-]*$ and are
# capped at 40 characters. Strip the RUN_ID prefix to keep the snapshot
# name itself stable (matches the plan's wording).
SNAP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OPNSENSE_SNAP="pre_vmbr1_mirror_${SNAP_STAMP}"
WAZUH_SNAP="pre_vnc_brute_rules_${SNAP_STAMP}"

if [ "${DRY_RUN}" -eq 1 ]; then
    step "DRY RUN: would take snapshots"
    echo "    qm snapshot ${OPNSENSE_VMID} ${OPNSENSE_SNAP}"
    [ "${SKIP_WAZUH}" -eq 0 ] && echo "    qm snapshot ${WAZUH_VMID} ${WAZUH_SNAP}"
    exit 0
fi

step "Snapshotting OPNsense (VMID ${OPNSENSE_VMID}) -> ${OPNSENSE_SNAP}"
pxssh "qm snapshot ${OPNSENSE_VMID} ${OPNSENSE_SNAP} \
        --description 'pre OPNsense net2/Suricata/filterlog changes; rollback target for vmbr1 mirror plan; run=${RUN_ID}'"

WAZUH_SNAP_TAKEN=0
if [ "${SKIP_WAZUH}" -eq 0 ]; then
    step "Snapshotting Wazuh manager (VMID ${WAZUH_VMID}) -> ${WAZUH_SNAP}"
    pxssh "qm snapshot ${WAZUH_VMID} ${WAZUH_SNAP} \
            --description 'pre rules 100810-100815 push; run=${RUN_ID}'"
    WAZUH_SNAP_TAKEN=1
fi

step "Verifying snapshots"
pxssh "qm listsnapshot ${OPNSENSE_VMID}"
if [ "${WAZUH_SNAP_TAKEN}" -eq 1 ]; then
    pxssh "qm listsnapshot ${WAZUH_VMID}"
fi

step "Recording ${SNAP_JSON}"
GIT_HEAD="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
cat > "${SNAP_JSON}" <<JSON
{
  "run_id":          "${RUN_ID}",
  "taken_at_utc":    "$(date -u +%FT%TZ)",
  "git_head":        "${GIT_HEAD}",
  "git_branch":      "${GIT_BRANCH}",
  "proxmox_host":    "${PROXMOX_HOST}",
  "vmstate":         false,
  "snapshots": [
    {
      "vmid":          ${OPNSENSE_VMID},
      "role":          "opnsense",
      "snapshot_name": "${OPNSENSE_SNAP}",
      "rollback_cmd":  "qm rollback ${OPNSENSE_VMID} ${OPNSENSE_SNAP}"
    }$( [ "${WAZUH_SNAP_TAKEN}" -eq 1 ] && cat <<INNER
,
    {
      "vmid":          ${WAZUH_VMID},
      "role":          "wazuh-manager",
      "snapshot_name": "${WAZUH_SNAP}",
      "rollback_cmd":  "qm rollback ${WAZUH_VMID} ${WAZUH_SNAP}"
    }
INNER
)
  ]
}
JSON

echo
echo "[+] snapshots taken"
echo "    artefact: ${SNAP_JSON}"
echo "    rollback: ./scripts/proxmox/rollback-vmbr1-mirror.sh --run-id ${RUN_ID}"
