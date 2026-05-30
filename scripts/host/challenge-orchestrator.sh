#!/usr/bin/env bash
# Host-side orchestrator: react to guest unhealthy markers (no secrets on challenge VM).
#
# Polls WinRM for C:\secretcon\watchdog-unhealthy.marker on configured hosts.
# On marker: optional auto-failover (EWS_FAILOVER_AUTO=1) or log for operator.
#
# Usage:
#   ./scripts/host/challenge-orchestrator.sh --once
#   ./scripts/host/challenge-orchestrator.sh --loop --interval 30

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"
if [ -f .env ]; then set -a; source .env; set +a; fi

MARKER='C:\secretcon\watchdog-unhealthy.marker'
HOSTS="${ORCH_HOSTS:-${EWS_HOST:-192.168.61.20}}"
INTERVAL=30
LOOP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --once) shift ;;
    --loop) LOOP=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "[!] unknown: $1" >&2; exit 2 ;;
  esac
done

check_host() {
  local host="$1"
  local out
  out="$(ansible -i "${REPO_ROOT}/ansible/inventory" "${host}" -m ansible.windows.win_stat \
    -a "path=${MARKER}" 2>/dev/null | grep -c '"exists": true' || true)"
  if [ "${out}" -ge 1 ]; then
    echo "[orchestrator] unhealthy marker on ${host}"
    if [ "${EWS_FAILOVER_AUTO:-0}" = "1" ]; then
      "${REPO_ROOT}/scripts/host/challenge-failover.sh" --to standby --auto
    fi
    return 0
  fi
  return 1
}

tick() {
  for h in ${HOSTS}; do
    check_host "${h}" || true
  done
}

if [ "$LOOP" -eq 1 ]; then
  while true; do tick; sleep "${INTERVAL}"; done
else
  tick
fi
