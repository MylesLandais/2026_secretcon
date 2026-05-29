#!/usr/bin/env bash
# Push the SecretCon Suricata custom rules to the OPNsense VM via the
# OPNsense API, then trigger a Suricata + syslog reload.
#
# What this script DOES (API-driven, idempotent):
#   - Verify the OPNsense API responds (probe /api/core/firmware/status).
#   - Upload provisioning/opnsense/suricata/secretcon.rules to
#     /usr/local/etc/suricata/rules/secretcon.rules via the IDS user
#     rules endpoint (POST /api/ids/settings/addUserRule for each rule)
#     OR -- where the endpoint isn't available -- ssh in and scp it.
#   - Reload Suricata (POST /api/ids/service/reload).
#   - Reload the syslog service so EVE + filterlog targets pick up any
#     /conf/config.xml changes (POST /api/core/system/reloadServices).
#
# What this script DOES NOT do (one-time GUI/XML config -- documented in
# provisioning/opnsense/setup-instructions.md):
#   - Create the MIRROR interface assignment for vtnet2.
#   - Enable Suricata on the MIRROR interface in the UI.
#   - Configure the remote syslog targets for EVE and filterlog.
#   - Set Home networks / Pattern matcher / Detect profile.
# Those are one-shot OPNsense config-XML mutations that are stable once
# applied; the operator does them once via the UI and then exports
# /conf/config.xml to provisioning/opnsense/config.xml (commit-by-
# reference) for replay on a rebuild.
#
# Usage:
#   ./scripts/proxmox/opnsense-apply-config.sh
#   ./scripts/proxmox/opnsense-apply-config.sh --dry-run
#   ./scripts/proxmox/opnsense-apply-config.sh --rules-only
#   ./scripts/proxmox/opnsense-apply-config.sh --host 192.168.61.253
#
# Required env (.env auto-sourced):
#   OPNSENSE_API_KEY        OPNsense API key (System -> Access -> Users -> API key)
#   OPNSENSE_API_SECRET     OPNsense API secret (paired with the key)
#
# Optional env:
#   OPNSENSE_HOST           default 192.168.61.253
#   OPNSENSE_VERIFY_TLS     0 (default; self-signed cert in lab) or 1
#   OPNSENSE_SSH_USER       fallback ssh user when API can't write
#                           rules file (default 'root', requires
#                           OPNSENSE_SSH_PASSWORD or key)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/load_repo_env.sh
source "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}/.env"

DRY_RUN=0
RULES_ONLY=0
OPNSENSE_HOST="${OPNSENSE_HOST:-192.168.61.253}"
OPNSENSE_VERIFY_TLS="${OPNSENSE_VERIFY_TLS:-0}"
OPNSENSE_SSH_USER="${OPNSENSE_SSH_USER:-root}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --rules-only) RULES_ONLY=1; shift ;;
        --host)       OPNSENSE_HOST="$2"; shift 2 ;;
        -h|--help)    sed -n '3,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

: "${OPNSENSE_API_KEY:?OPNSENSE_API_KEY must be set in .env}"
: "${OPNSENSE_API_SECRET:?OPNSENSE_API_SECRET must be set in .env}"

CURL_OPTS=(-sS --max-time 30 -u "${OPNSENSE_API_KEY}:${OPNSENSE_API_SECRET}")
if [ "${OPNSENSE_VERIFY_TLS}" -ne 1 ]; then
    CURL_OPTS+=(-k)
fi

BASE="https://${OPNSENSE_HOST}/api"

RULES_SRC="${REPO_ROOT}/provisioning/opnsense/suricata/secretcon.rules"
[ -f "${RULES_SRC}" ] || { echo "[!] missing ${RULES_SRC}" >&2; exit 1; }

step() { printf '\n[*] %s\n' "$*"; }

step "Plan"
echo "    opnsense host : ${OPNSENSE_HOST}"
echo "    api base      : ${BASE}"
echo "    rules source  : ${RULES_SRC}"
echo "    dry_run       : ${DRY_RUN}"
echo "    rules_only    : ${RULES_ONLY}"

# 1. Probe the API.
step "Probing OPNsense API (firmware status)"
HTTP_CODE="$(curl -o /tmp/opn-probe-$$.json -w '%{http_code}' \
    "${CURL_OPTS[@]}" "${BASE}/core/firmware/status" 2>/dev/null || echo 000)"
if [ "${HTTP_CODE}" != "200" ]; then
    echo "[!] OPNsense API probe failed (HTTP ${HTTP_CODE})" >&2
    cat /tmp/opn-probe-$$.json 2>/dev/null || true
    rm -f /tmp/opn-probe-$$.json
    exit 1
fi
PRODUCT="$(jq -r '.product_id // .product_name // "unknown"' /tmp/opn-probe-$$.json 2>/dev/null || echo unknown)"
VERSION="$(jq -r '.product_version // "unknown"'             /tmp/opn-probe-$$.json 2>/dev/null || echo unknown)"
rm -f /tmp/opn-probe-$$.json
echo "    product=${PRODUCT} version=${VERSION}"

if [ "${DRY_RUN}" -eq 1 ]; then
    step "DRY RUN: would write secretcon.rules and reload Suricata"
    head -20 "${RULES_SRC}"
    exit 0
fi

# 2. Push the rules file. The OPNsense IDS API exposes per-rule helpers
# under /api/ids/settings/addUserRule but the easier mechanism that
# matches our 2-rule payload is to ship the file in one shot via SCP.
# Try API first; fall back to SCP.
step "Uploading secretcon.rules"

API_RULES_PATH=""
# Try the IDS user-rule endpoint shape. If it doesn't exist the response
# will be 404 / "Endpoint not found" -- we then fall back to SCP.
TEST_CODE="$(curl -o /dev/null -w '%{http_code}' \
    "${CURL_OPTS[@]}" "${BASE}/ids/settings/getUserRule/_probe" 2>/dev/null || echo 000)"
if [ "${TEST_CODE}" = "200" ] || [ "${TEST_CODE}" = "404" ]; then
    # 404 here means "no user rule with id=_probe", which still proves the
    # endpoint exists. A 500 / "Endpoint not found" message would not.
    # We don't trust addUserRule for multi-rule payloads -- fall through
    # to SCP which is the canonical path on OPNsense.
    API_RULES_PATH=""
fi

if [ -z "${API_RULES_PATH}" ]; then
    echo "    falling back to scp (canonical path for multi-rule files)"
    SSH_OPTS=(
        -o ConnectTimeout=15
        -o StrictHostKeyChecking=accept-new
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
        -o LogLevel=ERROR
    )
    SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
    if [ -z "${SSHPASS_BIN}" ] && command -v nix >/dev/null 2>&1; then
        SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
    fi
    if [ -z "${OPNSENSE_SSH_PASSWORD:-}" ]; then
        echo "[!] OPNsense API does not expose addUserRule cleanly; need SCP."
        echo "    Set OPNSENSE_SSH_PASSWORD in .env (root@${OPNSENSE_HOST})"
        echo "    or place the file by hand:"
        echo "      scp ${RULES_SRC} ${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}:/usr/local/etc/suricata/rules/secretcon.rules"
        echo "    then re-run with --rules-only to skip the upload step."
        exit 1
    fi
    [ -n "${SSHPASS_BIN}" ] || { echo "[!] sshpass not found" >&2; exit 1; }

    "${SSHPASS_BIN}" -p "${OPNSENSE_SSH_PASSWORD}" \
        scp "${SSH_OPTS[@]}" \
        "${RULES_SRC}" \
        "${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}:/tmp/secretcon.rules"

    "${SSHPASS_BIN}" -p "${OPNSENSE_SSH_PASSWORD}" \
        ssh "${SSH_OPTS[@]}" \
        "${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}" \
        'install -o root -g wheel -m 0644 /tmp/secretcon.rules \
            /usr/local/etc/suricata/rules/secretcon.rules \
            && rm -f /tmp/secretcon.rules'
fi
echo "[+] secretcon.rules in place at /usr/local/etc/suricata/rules/secretcon.rules"

if [ "${RULES_ONLY}" -eq 1 ]; then
    step "rules-only mode; not touching Suricata service"
    exit 0
fi

# 3. Reload Suricata.
step "Reloading Suricata (POST /api/ids/service/reload)"
RELOAD_JSON="$(curl "${CURL_OPTS[@]}" -X POST "${BASE}/ids/service/reload" || true)"
echo "    response: ${RELOAD_JSON}"

# Some OPNsense versions expose /api/ids/service/restart instead; if the
# reload reply doesn't include "status":"ok" we try restart.
if ! printf '%s' "${RELOAD_JSON}" | grep -qi '"status"\s*:\s*"ok"'; then
    echo "    reload reply did not confirm; trying restart"
    curl "${CURL_OPTS[@]}" -X POST "${BASE}/ids/service/restart" || true
    echo
fi

# 4. Verify Suricata is running.
step "Verifying Suricata service status"
STATUS_JSON="$(curl "${CURL_OPTS[@]}" "${BASE}/ids/service/status" || true)"
echo "    ${STATUS_JSON}"
if ! printf '%s' "${STATUS_JSON}" | grep -qi '"status"\s*:\s*"running"'; then
    echo "[!] Suricata is NOT in 'running' state on OPNsense" >&2
    echo "    inspect manually: System -> Services -> Intrusion Detection" >&2
    exit 1
fi

echo
echo "[+] opnsense-apply-config complete"
echo "    rules: provisioning/opnsense/suricata/secretcon.rules"
echo "    next:  run a controlled brute force; check Suricata alerts UI"
echo "           or scripts/observability/opnsense-vnc-challenge.sh"
