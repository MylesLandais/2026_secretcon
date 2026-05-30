#!/usr/bin/env bash
# Operator-triggered EWS challenge failover via HAProxy backend swap.
#
# Usage:
#   ./scripts/host/challenge-failover.sh --status
#   ./scripts/host/challenge-failover.sh --to standby
#   ./scripts/host/challenge-failover.sh --to primary
#
# Env:
#   EWS_FAILOVER_AUTO=0          # auto from orchestrator requires 1
#   EWS_HAPROXY_CFG=/etc/haproxy/haproxy.cfg
#   EWS_BACKEND_PRIMARY=192.168.61.20:5985
#   EWS_BACKEND_STANDBY=192.168.61.21:5985

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "${REPO_ROOT}/.env" ]; then set -a; source "${REPO_ROOT}/.env"; set +a; fi

CFG="${EWS_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
PRIMARY="${EWS_BACKEND_PRIMARY:-192.168.61.20:5985}"
STANDBY="${EWS_BACKEND_STANDBY:-192.168.61.21:5985}"
AUTO="${EWS_FAILOVER_AUTO:-0}"
STATE_FILE="${REPO_ROOT}/.tmp/ews-failover-state"
TO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --status) echo "active=$(cat "${STATE_FILE}" 2>/dev/null || echo primary)"; exit 0 ;;
    --to) TO="$2"; shift 2 ;;
    --auto) AUTO=1; shift ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "[!] unknown: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "${REPO_ROOT}/.tmp"
[ -n "${TO}" ] || { echo "[!] --to primary|standby required" >&2; exit 2; }

if [ "$AUTO" != "1" ] && [ "${EWS_FAILOVER_AUTO:-0}" != "1" ]; then
  echo "[failover] operator mode (set EWS_FAILOVER_AUTO=1 for orchestrator)"
fi

case "${TO}" in
  primary) ACTIVE="${PRIMARY}" ;;
  standby) ACTIVE="${STANDBY}" ;;
  *) echo "[!] --to must be primary or standby" >&2; exit 2 ;;
esac

TEMPLATE="${REPO_ROOT}/infrastructure/failover/haproxy.cfg"
if [ -f "${TEMPLATE}" ]; then
  sed -e "s|@EWS_ACTIVE_BACKEND@|${ACTIVE}|g" "${TEMPLATE}" | sudo tee "${CFG}" >/dev/null
  sudo systemctl reload haproxy 2>/dev/null || sudo systemctl restart haproxy 2>/dev/null || true
fi

echo "${TO}" > "${STATE_FILE}"
echo "[+] failover active backend: ${TO} (${ACTIVE})"
echo "[notify] post to Discord/Maya bot: EWS challenge traffic -> ${TO}"
