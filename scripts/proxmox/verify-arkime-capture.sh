#!/usr/bin/env bash
# Health check for the SecretCon production Arkime VM (VMID 111).
#
# All probes run from the operator workstation over the WireGuard
# tunnel. No SSH to the VM is required for a green run.
#
# Checks:
#   - TCP 8005 (viewer) and 9201 (opensearch) listening on $ARKIME_HOST
#   - GET http://$ARKIME_HOST:9201/_cluster/health is green/yellow
#   - The arkime_files OpenSearch index exists (db.pl init has completed)
#   - GET http://$ARKIME_HOST:8005/eshealth.json returns 200 (or 401 when
#     viewer auth is enabled -- both indicate "viewer is up")
#
# Exit 0 if all checks pass.
#
# Usage:
#   ./scripts/proxmox/verify-arkime-capture.sh [--run-id ID] [--host IP]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID=""
HOST_CLI=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        --host)   HOST_CLI="$2"; shift 2 ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -f .env ]]; then
    while IFS='=' read -r k v; do
        [[ -z "${k}" || "${k}" =~ ^# ]] && continue
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        if [[ -z "${!k:-}" ]]; then
            export "${k}=${v}"
        fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env || true)
fi

ARKIME_HOST="${HOST_CLI:-${ARKIME_HOST:-192.168.61.11}}"
if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="ews-prod-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/prod-proof-${RUN_ID}"
mkdir -p "${OUT_DIR}"
EVIDENCE="${OUT_DIR}/verify-arkime.txt"
: > "${EVIDENCE}"

PASS=0
FAIL=0
record() {
    local status="$1" name="$2" detail="${3:-}"
    local line="${status}  ${name}  ${detail}"
    printf '%s\n' "${line}" >> "${EVIDENCE}"
    printf '  %s\n' "${line}"
    if [[ "${status}" == "PASS" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

echo "[*] verify-arkime host=${ARKIME_HOST}  run_id=${RUN_ID}"

# 1. ICMP
if ping -c 1 -W 2 "${ARKIME_HOST}" >/dev/null 2>&1; then
    record PASS "ping" "${ARKIME_HOST}"
else
    record FAIL "ping" "${ARKIME_HOST} unreachable"
fi

# 2. TCP 8005 + 9201
for port in 8005 9201; do
    if timeout 3 bash -c "</dev/tcp/${ARKIME_HOST}/${port}" 2>/dev/null; then
        record PASS "tcp-${port}" "open"
    else
        record FAIL "tcp-${port}" "${ARKIME_HOST}:${port} closed"
    fi
done

# 3. OpenSearch cluster health
HEALTH_JSON="$(curl -sf --max-time 10 \
    "http://${ARKIME_HOST}:9201/_cluster/health" 2>/dev/null || true)"
if [[ -n "${HEALTH_JSON}" ]]; then
    printf '%s\n' "${HEALTH_JSON}" > "${OUT_DIR}/arkime-cluster-health.json"
    status="$(printf '%s' "${HEALTH_JSON}" | jq -r '.status' 2>/dev/null || echo unknown)"
    if [[ "${status}" == "green" || "${status}" == "yellow" ]]; then
        record PASS "opensearch-health" "status=${status}"
    else
        record FAIL "opensearch-health" "status=${status}"
    fi
else
    record FAIL "opensearch-health" "cluster/health unreachable"
fi

# 4. arkime_files index exists
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://${ARKIME_HOST}:9201/arkime_files" 2>/dev/null || echo 000)"
if [[ "${HTTP_CODE}" == "200" ]]; then
    record PASS "arkime-files-index" "exists (HTTP ${HTTP_CODE})"
else
    record FAIL "arkime-files-index" "HTTP ${HTTP_CODE} (db.pl init incomplete?)"
fi

# 5. Viewer eshealth.json
VIEWER_CODE="$(curl -s -o "${OUT_DIR}/arkime-viewer-eshealth.json" \
    -w '%{http_code}' --max-time 5 \
    "http://${ARKIME_HOST}:8005/eshealth.json" 2>/dev/null || echo 000)"
case "${VIEWER_CODE}" in
    200) record PASS "viewer-eshealth" "HTTP 200 (no auth)" ;;
    401) record PASS "viewer-eshealth" "HTTP 401 (viewer up; auth required)" ;;
    *)   record FAIL "viewer-eshealth" "HTTP ${VIEWER_CODE}" ;;
esac

{
    echo
    echo "===== verify-arkime summary ====="
    echo "  host    : ${ARKIME_HOST}"
    echo "  passed  : ${PASS}"
    echo "  failed  : ${FAIL}"
    echo "  evidence: ${EVIDENCE}"
    echo "================================="
} | tee -a "${EVIDENCE}"

[[ "${FAIL}" -eq 0 ]]
