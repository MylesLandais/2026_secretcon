#!/usr/bin/env bash
set -euo pipefail

# End-to-end ASREP validation with Wazuh rule assertion (100700+).
#
# Usage:
#   ./scripts/validate-asrep-siem.sh [--skip-stack] [--skip-boot]
#
# Requires WAZUH_API_PASSWORD (from .env) and a booted ASREP VM.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_STACK=0
SKIP_BOOT=0
INGEST_WAIT="${ASREP_SIEM_INGEST_WAIT:-45}"
AGENT_IP="${ASREP_AGENT_IP:-10.0.3.15}"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-stack) SKIP_STACK=1; shift ;;
        --skip-boot) SKIP_BOOT=1; shift ;;
        -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -f "${REPO_ROOT}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
fi

if [ "$SKIP_STACK" -eq 0 ]; then
    echo "[*] bringing up wazuh-docker stack"
    "${REPO_ROOT}/scripts/wazuh-docker-up.sh"
else
    echo "[*] skip-stack: assuming wazuh-docker is already up"
fi

if [ "$SKIP_BOOT" -eq 0 ]; then
    echo "[*] booting ASREP VM"
    nix develop -c "${REPO_ROOT}/scripts/run-local-asrep.sh"
    sleep 30
else
    echo "[*] skip-boot: assuming ASREP VM is already running"
fi

export WINRM_PORT="${ASREP_WINRM_PORT:-15986}"
export WAZUH_AGENT_IP="$AGENT_IP"
"${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 300

SINCE="$(date -u +%FT%TZ)"
echo "[*] roast window start: ${SINCE}"

if ! nix develop .#kali -c "${REPO_ROOT}/scripts/validate-asrep.sh"; then
    echo "[!] validate-asrep.sh failed" >&2
    exit 1
fi

echo "[*] waiting ${INGEST_WAIT}s for SIEM ingestion"
sleep "$INGEST_WAIT"
UNTIL="$(date -u +%FT%TZ)"

SIEM_DIR="${REPO_ROOT}/artifacts/asrep/validation/siem-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SIEM_DIR"

"${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
    --since "$SINCE" --until "$UNTIL" \
    --out-dir "$SIEM_DIR"

has_100700=false
has_100701=false
if [ -f "${SIEM_DIR}/alerts.json" ]; then
    if jq -e 'select(.rule.id == "100700")' "${SIEM_DIR}/alerts.json" >/dev/null 2>&1; then
        has_100700=true
    fi
    if jq -e 'select(.rule.id == "100701")' "${SIEM_DIR}/alerts.json" >/dev/null 2>&1; then
        has_100701=true
    fi
fi

RULES=$(jq -r '.rule.id // empty' "${SIEM_DIR}/alerts.json" 2>/dev/null | sort -u | paste -sd';' - || echo "")

cat > "${SIEM_DIR}/siem-summary.json" <<JSON
{
  "since": "${SINCE}",
  "until": "${UNTIL}",
  "fired_100700_asrep": ${has_100700},
  "fired_100701_tgs_rc4": ${has_100701},
  "secretcon_rule_ids": "${RULES}"
}
JSON

echo "[*] siem-summary: ${SIEM_DIR}/siem-summary.json"
jq . "${SIEM_DIR}/siem-summary.json"

if [ "$has_100700" != true ]; then
    echo "[!] rule 100700 did not fire in window ${SINCE} -> ${UNTIL}" >&2
    exit 1
fi

echo "[+] ASREP SIEM validation passed (rule 100700 observed)"
