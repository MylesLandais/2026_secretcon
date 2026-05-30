#!/usr/bin/env bash
# Prove EWS LPE Wazuh rules fire after validate-ews-lpe-chain (optional docker stack).
#
# Usage:
#   ./scripts/observability/ews-lpe-wazuh-proof.sh [--target IP] [--since-minutes 15]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET=""
SINCE_MIN=15
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --since-minutes) SINCE_MIN="$2"; shift 2 ;;
        -h|--help) sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/lib/wazuh-api.sh
. "${REPO_ROOT}/scripts/lib/wazuh-api.sh"
wazuh_load_env "$REPO_ROOT"

WANT_RULES=(100808 100809 100818 100819)
token="$(wazuh_api_wait_token 30)" || { echo "[!] Wazuh API unavailable"; exit 1; }

found=0
missing=()
for rid in "${WANT_RULES[@]}"; do
    q="rule.id=${rid}"
    [[ -n "$TARGET" ]] && q="${q}&q=agent.ip=${TARGET}"
    count="$(curl -sk --max-time 10 -H "Authorization: Bearer ${token}" \
        "https://${WAZUH_API_HOST}:${WAZUH_API_PORT}/alerts?${q}&limit=1&sort=-timestamp" \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("data",{}).get("total_affected_items",0))' 2>/dev/null || echo 0)"
    if [[ "${count:-0}" -gt 0 ]]; then
        echo "[+] rule ${rid}: ${count} alert(s)"
        found=$((found + 1))
    else
        echo "[!] rule ${rid}: no alerts in window"
        missing+=("$rid")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "[+] EWS LPE Wazuh proof OK"
    exit 0
fi
echo "[!] missing rules: ${missing[*]}"
exit 1
