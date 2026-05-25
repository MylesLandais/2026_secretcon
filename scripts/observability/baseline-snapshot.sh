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
#       [--qcow PATH] [--name baseline] [--manager-host 127.0.0.1] \
#       [--manager-port 55000] [--enroll-timeout 90] \
#       [--sysmon-timeout 60]
#
# Aborts (non-zero) if the agent never enrolls or Sysmon events never
# arrive within the configured timeouts - snapshotting a silent baseline
# would make every iteration useless.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QCOW="${REPO_ROOT}/artifacts/cysvuln/local-qemu/cysvuln.qcow2"
SNAP_NAME="baseline"
WINRM_PORT="${WINRM_PORT:-15985}"
MGR_HOST="${WAZUH_MANAGER_HOST:-127.0.0.1}"
MGR_PORT="${WAZUH_API_PORT:-55000}"
MGR_USER="${WAZUH_API_USER:-wazuh-wui}"
MGR_PASS="${WAZUH_API_PASSWORD:-MyS3cr37P450r.*-}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
ENROLL_TIMEOUT=90
SYSMON_TIMEOUT=60
AGENT_IP="${AGENT_IP:-10.0.2.15}"   # QEMU user-net default DHCP lease

while [ $# -gt 0 ]; do
    case "$1" in
        --qcow) QCOW="$2"; shift 2 ;;
        --name) SNAP_NAME="$2"; shift 2 ;;
        --manager-host) MGR_HOST="$2"; shift 2 ;;
        --manager-port) MGR_PORT="$2"; shift 2 ;;
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

# If a snapshot with this name already exists, bail (idempotent skip).
if qemu-img snapshot -l "$QCOW" 2>/dev/null | awk '{print $2}' | grep -Fxq "$SNAP_NAME"; then
    echo "[*] Snapshot '${SNAP_NAME}' already exists on ${QCOW}; nothing to do"
    qemu-img snapshot -l "$QCOW"
    exit 0
fi

echo "[*] Booting fresh VM via run-local-cysvuln.sh"
"${REPO_ROOT}/scripts/run-local-cysvuln.sh" "$QCOW"

# Wait for WinRM, then for agent enrollment.
echo "[*] Waiting for WinRM on 127.0.0.1:${WINRM_PORT}"
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if timeout 5 bash -c "</dev/tcp/127.0.0.1/${WINRM_PORT}" 2>/dev/null; then
        echo "[+] WinRM port open"
        break
    fi
    sleep 5
done

echo "[*] Waiting for Wazuh agent to report 'active' (timeout ${ENROLL_TIMEOUT}s)"
deadline=$(( $(date +%s) + ENROLL_TIMEOUT ))
token=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    token=$(curl -sk --max-time 5 -u "${MGR_USER}:${MGR_PASS}" -X POST \
        "https://${MGR_HOST}:${MGR_PORT}/security/user/authenticate?raw=true" 2>/dev/null || true)
    if [ -n "$token" ] && [[ "$token" != *"error"* ]]; then
        status=$(curl -sk --max-time 5 -H "Authorization: Bearer ${token}" \
            "https://${MGR_HOST}:${MGR_PORT}/agents?ip=${AGENT_IP}" 2>/dev/null \
            | jq -r '.data.affected_items[0].status // "missing"')
        if [ "$status" = "active" ]; then
            echo "[+] Agent active (ip=${AGENT_IP})"
            break
        fi
        echo "    agent status: ${status}"
    fi
    sleep 5
done
if [ "$status" != "active" ]; then
    echo "[!] Agent never reported active; dumping recent manager logs" >&2
    docker logs --tail 30 wazuh.manager >&2 || true
    echo "[!] aborting baseline (silent agent means silent iterations)" >&2
    exit 1
fi

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

# Clean-stop the VM via admin WinRM so the snapshot captures a quiescent
# filesystem (qemu-img snapshot on a running VM also works, but a clean
# shutdown gives the iteration loop a deterministic boot path).
echo "[*] Issuing Stop-Computer via admin WinRM"
python3 - "$WINRM_PORT" "$ADMIN_PW" <<'PY' || true
import sys, winrm
port, pw = sys.argv[1:3]
s = winrm.Session(f"http://127.0.0.1:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
try:
    s.run_ps("Stop-Computer -Force")
except Exception as exc:
    # WinRM channel often drops mid-shutdown; that's expected.
    print(f"[*] WinRM channel closed: {exc}")
PY

PIDFILE="${CYSVULN_PIDFILE:-/tmp/cysvuln-local.pid}"
echo "[*] Waiting for QEMU to exit"
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        break
    fi
    sleep 2
done
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    echo "[*] VM still running; forcing qemu kill"
    kill "$(cat "$PIDFILE")" || true
    sleep 3
fi
rm -f "$PIDFILE"

echo "[*] Taking qemu-img snapshot '${SNAP_NAME}' on ${QCOW}"
qemu-img snapshot -c "$SNAP_NAME" "$QCOW"
qemu-img snapshot -l "$QCOW"
echo "[+] Baseline snapshot created"
