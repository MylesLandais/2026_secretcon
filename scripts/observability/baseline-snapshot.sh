#!/usr/bin/env bash
set -euo pipefail

# Boot the freshly-built CysVuln qcow2, wait for the Wazuh agent inside
# the guest to enroll with the docker manager at 10.0.2.2, sanity-check
# that Sysmon events are flowing (not just heartbeats), clean-stop the
# VM, then take a qemu-img internal snapshot named `baseline` so the
# observability loop can revert to it between iterations.
#
# Usage:
#   ./scripts/observability/baseline-snapshot.sh \
#       [--qcow PATH] [--name baseline] [--enroll-timeout 90] \
#       [--sysmon-timeout 60]
#
# Aborts (non-zero) if the agent never enrolls or Sysmon events never
# arrive within the configured timeouts - snapshotting a silent baseline
# would make every iteration useless.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/loop_lib.sh
. "${REPO_ROOT}/scripts/lib/loop_lib.sh"

QCOW="${QCOW:-${REPO_ROOT}/artifacts/cysvuln/local-qemu/cysvuln.qcow2}"
SNAP_NAME="${SNAP_NAME:-baseline}"
ENROLL_TIMEOUT=90
SYSMON_TIMEOUT=60
AGENT_IP="${AGENT_IP:-10.0.2.15}"   # QEMU user-net default DHCP lease

while [ $# -gt 0 ]; do
    case "$1" in
        --qcow) QCOW="$2"; shift 2 ;;
        --name) SNAP_NAME="$2"; shift 2 ;;
        --enroll-timeout) ENROLL_TIMEOUT="$2"; shift 2 ;;
        --sysmon-timeout) SYSMON_TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '3,17p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f "$QCOW" ]; then
    echo "[!] qcow not found: $QCOW" >&2
    exit 2
fi

# Env consumed by loop_lib.sh helpers.
export PIDFILE="${CYSVULN_PIDFILE:-/tmp/cysvuln-local.pid}"
export WINRM_PORT="${WINRM_PORT:-15985}"
export ADMIN_USER="${ADMIN_USER:-Administrator}"
export ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
export QCOW

# If a snapshot with this name already exists, bail (idempotent skip).
if qemu-img snapshot -l "$QCOW" 2>/dev/null | awk '{print $2}' | grep -Fxq "$SNAP_NAME"; then
    echo "[*] Snapshot '${SNAP_NAME}' already exists on ${QCOW}; nothing to do"
    qemu-img snapshot -l "$QCOW"
    exit 0
fi

echo "[*] Booting fresh VM via run-local-cysvuln.sh"
"${REPO_ROOT}/scripts/run-local-cysvuln.sh" "$QCOW"

# Strict mode: refuse to snapshot a silent baseline.
echo "[*] Waiting for WinRM + Wazuh agent ip=${AGENT_IP} (strict)"
WAZUH_AGENT_IP="$AGENT_IP" \
WAIT_AGENT_STRICT=1 \
    "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 "$ENROLL_TIMEOUT"

echo "[*] Verifying Sysmon events are flowing to the manager"
deadline=$(( $(date +%s) + SYSMON_TIMEOUT ))
sysmon_seen=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec wazuh.manager tail -n 500 /var/ossec/logs/alerts/alerts.json 2>/dev/null \
        | jq -r '.data.win.system.providerName // empty' 2>/dev/null \
        | grep -Fxq 'Microsoft-Windows-Sysmon'; then
        sysmon_seen=1
        echo "[+] Sysmon events observed in alerts.json"
        break
    fi
    sleep 5
done
if [ "$sysmon_seen" -ne 1 ]; then
    echo "[!] No Sysmon events arrived within ${SYSMON_TIMEOUT}s" >&2
    echo "[!] Likely cause: shared/ews/agent.conf not synced to manager," >&2
    echo "    or the agent failed to push its merged config. Check:" >&2
    echo "      docker exec wazuh.manager ls /var/ossec/etc/shared/ews/" >&2
    echo "    then re-run scripts/wazuh-docker-up.sh to resync." >&2
    exit 1
fi

# Clean-stop the VM so the snapshot captures a quiescent filesystem.
echo "[*] Stopping VM"
loop_stop_vm

echo "[*] Taking qemu-img snapshot '${SNAP_NAME}' on ${QCOW}"
loop_take_snapshot_if_missing "$QCOW" "$SNAP_NAME"
echo "[+] Baseline snapshot created"
