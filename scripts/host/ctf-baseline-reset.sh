#!/usr/bin/env bash
# Scheduled or manual Proxmox snapshot rollback for challenge VMs.
#
# Usage:
#   ./scripts/host/ctf-baseline-reset.sh --list
#   ./scripts/host/ctf-baseline-reset.sh --dry-run --vmid 109
#   CTF_SCHEDULED_RESET_ENABLED=1 ./scripts/host/ctf-baseline-reset.sh --vmid 109
#
# Env (.env):
#   CTF_SCHEDULED_RESET_ENABLED=0
#   CTF_BASELINE_SNAPSHOT_TAG=ctf-baseline
#   PROXMOX_HOST, PROXMOX_PASSWORD

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/proxmox-ssh.sh
source "${REPO_ROOT}/scripts/lib/proxmox-ssh.sh"
proxmox_load_env

ENABLED="${CTF_SCHEDULED_RESET_ENABLED:-0}"
TAG="${CTF_BASELINE_SNAPSHOT_TAG:-ctf-baseline}"
LEGACY_TAG="baseline"
DRY_RUN=0
LIST=0
VMIDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --vmid) VMIDS+=("$2"); shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[!] unknown: $1" >&2; exit 2 ;;
  esac
done

resolve_snap() {
  local vmid="$1"
  if pxssh "qm listsnapshot ${vmid}" 2>/dev/null | grep -qw "${TAG}"; then
    echo "${TAG}"
  elif pxssh "qm listsnapshot ${vmid}" 2>/dev/null | grep -qw "${LEGACY_TAG}"; then
    echo "${LEGACY_TAG}"
  else
    echo ""
  fi
}

if [ "$LIST" -eq 1 ]; then
  proxmox_require_sshpass
  for vmid in 109 119 118 112; do
    echo "=== VMID ${vmid} ==="
    pxssh "qm listsnapshot ${vmid}" 2>/dev/null || echo "(unavailable)"
  done
  exit 0
fi

if [ "${#VMIDS[@]}" -eq 0 ]; then
  VMIDS=(109 119)
fi

proxmox_require_sshpass

for vmid in "${VMIDS[@]}"; do
  snap="$(resolve_snap "${vmid}")"
  if [ -z "${snap}" ]; then
    echo "[!] VMID ${vmid}: no snapshot ${TAG} or ${LEGACY_TAG}" >&2
    exit 1
  fi
  echo "[reset] VMID ${vmid} -> rollback ${snap}"
  if [ "$DRY_RUN" -eq 1 ]; then
    continue
  fi
  if [ "$ENABLED" != "1" ]; then
    echo "[!] CTF_SCHEDULED_RESET_ENABLED!=1 — refusing rollback" >&2
    exit 1
  fi
  pxssh "qm rollback ${vmid} ${snap} && qm start ${vmid}"
done
echo "[+] done"
