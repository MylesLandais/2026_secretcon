#!/usr/bin/env bash
set -euo pipefail

# Boot the ASREP qcow2, wait for Wazuh agent + Sysmon, stop VM, take baseline snapshot.
#
# Usage:
#   ./scripts/observability/baseline-snapshot-asrep.sh [--qcow PATH] [--name baseline]

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/loop_lib.sh
. "${REPO_ROOT}/scripts/lib/loop_lib.sh"

QCOW="${QCOW:-${REPO_ROOT}/artifacts/asrep/local-qemu/asrep.qcow2}"
SNAP_NAME="${SNAP_NAME:-baseline}"
ENROLL_TIMEOUT=120
SYSMON_TIMEOUT=90
AGENT_IP="${AGENT_IP:-10.0.3.15}"

while [ $# -gt 0 ]; do
    case "$1" in
        --qcow) QCOW="$2"; shift 2 ;;
        --name) SNAP_NAME="$2"; shift 2 ;;
        --enroll-timeout) ENROLL_TIMEOUT="$2"; shift 2 ;;
        --sysmon-timeout) SYSMON_TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '3,8p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f "$QCOW" ]; then
    echo "[!] qcow not found: $QCOW" >&2
    exit 2
fi

export PIDFILE="${ASREP_PIDFILE:-/tmp/asrep-local.pid}"
export WINRM_PORT="${ASREP_WINRM_PORT:-15986}"
export ADMIN_USER="${ADMIN_USER:-Administrator}"
export ADMIN_PW="${ADMIN_PW:-${AD_SAFEMODE_PASSWORD:-PizzaMan123!}}"
export QCOW

if qemu-img snapshot -l "$QCOW" 2>/dev/null | awk '{print $2}' | grep -Fxq "$SNAP_NAME"; then
    echo "[*] Snapshot '${SNAP_NAME}' already exists on ${QCOW}; nothing to do"
    qemu-img snapshot -l "$QCOW"
    exit 0
fi

echo "[*] Booting ASREP VM"
"${REPO_ROOT}/scripts/run-local-asrep.sh" "$QCOW"

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
    echo "[!] Re-run scripts/wazuh-docker-up.sh to resync shared/asrep/agent.conf" >&2
    exit 1
fi

echo "[*] Stopping VM"
loop_stop_vm

echo "[*] Taking qemu-img snapshot '${SNAP_NAME}' on ${QCOW}"
loop_take_snapshot_if_missing "$QCOW" "$SNAP_NAME"
echo "[+] ASREP baseline snapshot created"
