#!/usr/bin/env bash
# shellcheck shell=bash
#
# wazuh-api.sh -- shared Wazuh manager API helpers (token fetch + Bearer
# GET + agent status query). Source AFTER wazuh-common.sh so the
# WAZUH_API_* env vars are populated:
#
#   . "${REPO_ROOT}/scripts/lib/wazuh-common.sh"
#   . "${REPO_ROOT}/scripts/lib/wazuh-api.sh"
#   wazuh_load_env
#
# All helpers reach the manager at https://${WAZUH_API_HOST}:${WAZUH_API_PORT}
# with NTLM-style basic auth on /security/user/authenticate, then Bearer
# on subsequent calls.

# wazuh_api_token
#
# Fetch a single Bearer token. Echoes the token on stdout; returns 1 on
# auth failure with a diagnostic to stderr.
wazuh_api_token() {
    local host="${WAZUH_API_HOST:-127.0.0.1}"
    local port="${WAZUH_API_PORT:-55000}"
    local user="${WAZUH_API_USER:-wazuh-wui}"
    local pass="${WAZUH_API_PASSWORD:-MyS3cr37P450r.*-}"
    local token
    token=$(curl -sk --max-time 10 -u "${user}:${pass}" -X POST \
        "https://${host}:${port}/security/user/authenticate?raw=true" 2>/dev/null || true)
    if [ -z "$token" ] \
        || [[ "$token" == *"error"* ]] \
        || [[ "$token" == *"Could not"* ]]; then
        echo "[!] wazuh API auth failed against ${host}:${port}" >&2
        return 1
    fi
    printf '%s' "$token"
}

# wazuh_api_wait_token [TIMEOUT_SEC]
#
# Poll wazuh_api_token until success or timeout (default 240s). Echoes
# the token on success, exits non-zero on timeout.
wazuh_api_wait_token() {
    local timeout="${1:-240}"
    local deadline token=""
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if token=$(wazuh_api_token 2>/dev/null); then
            printf '%s' "$token"
            return 0
        fi
        sleep 5
    done
    return 1
}

# wazuh_api_get PATH [TOKEN]
#
# GET against the manager API with Bearer auth. PATH is relative to the
# API root, e.g. "/agents?ip=10.0.2.15". Echoes the response body on
# stdout. If TOKEN is omitted, fetches a fresh one.
wazuh_api_get() {
    local path="$1"
    local token="${2:-}"
    if [ -z "$token" ]; then
        token=$(wazuh_api_token) || return 1
    fi
    local host="${WAZUH_API_HOST:-127.0.0.1}"
    local port="${WAZUH_API_PORT:-55000}"
    curl -sk --max-time 10 -H "Authorization: Bearer ${token}" \
        "https://${host}:${port}${path}" 2>/dev/null || true
}

# wazuh_agent_status_by_ip IP [TOKEN]
#
# Echoes the status string (e.g. "active", "disconnected", "missing") of
# the first agent matching ip=IP. Requires jq.
wazuh_agent_status_by_ip() {
    local ip="$1"
    local token="${2:-}"
    wazuh_api_get "/agents?ip=${ip}" "$token" \
        | jq -r '.data.affected_items[0].status // "missing"' 2>/dev/null
}

# wazuh_agent_lookup_by_ip IP [TOKEN]
#
# Echoes a "name\tstatus" pair for the first agent matching ip=IP, or
# "?\tmissing" if none. Tab-separated so `read` can parse it.
wazuh_agent_lookup_by_ip() {
    local ip="$1"
    local token="${2:-}"
    wazuh_api_get "/agents?ip=${ip}" "$token" \
        | jq -r '"\(.data.affected_items[0].name // "?")\t\(.data.affected_items[0].status // "missing")"' 2>/dev/null
}
