#!/usr/bin/env bash
# shellcheck shell=bash
#
# wazuh-common.sh -- env loader, canonical credential names, and shared
# helpers for the wazuh-* operator scripts.
#
# Source from a caller (REPO_ROOT must already be set):
#
#   REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   . "${REPO_ROOT}/scripts/lib/wazuh-common.sh"
#   wazuh_load_env

# wazuh_load_env [REPO_ROOT]
#
# Source infrastructure/wazuh-docker/.env if present and populate the
# WAZUH_* canonical environment variables used by every wazuh-* script.
# Falls back to upstream-public Wazuh demo defaults that match
# infrastructure/wazuh-docker/.env.template; the local lab stack only
# binds 127.0.0.1, so those demo defaults are safe to ship as fallbacks.
#
# The .env.template uses docker-compose-side names (API_PASSWORD,
# INDEXER_PASSWORD, DASHBOARD_PASSWORD) because those are what the
# upstream Wazuh containers consume. We map them onto the WAZUH_*
# canonical names so shell callers can use one consistent vocabulary.
wazuh_load_env() {
    local repo_root="${1:-${REPO_ROOT:-}}"
    local env_file="${repo_root}/infrastructure/wazuh-docker/.env"
    if [ -f "$env_file" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$env_file"
        set +a
    fi

    # Bridge docker-compose names -> WAZUH_* canonical names. Only sets
    # the canonical var if it is unset; explicit WAZUH_* env always wins.
    : "${WAZUH_API_PASSWORD:=${API_PASSWORD:-MyS3cr37P450r.*-}}"
    : "${WAZUH_INDEXER_PASSWORD:=${INDEXER_PASSWORD:-SecretPassword}}"
    : "${WAZUH_DASHBOARD_PASSWORD:=${DASHBOARD_PASSWORD:-kibanaserver}}"

    : "${WAZUH_API_HOST:=127.0.0.1}"
    : "${WAZUH_API_PORT:=55000}"
    : "${WAZUH_API_USER:=wazuh-wui}"
    : "${WAZUH_INDEXER_HOST:=127.0.0.1}"
    : "${WAZUH_INDEXER_PORT:=9200}"
    : "${WAZUH_INDEXER_USER:=admin}"
    : "${WAZUH_DASHBOARD_PORT:=1443}"
    : "${WAZUH_MANAGER_CONTAINER:=wazuh.manager}"
    : "${WAZUH_INDEXER_CONTAINER:=wazuh.indexer}"

    export WAZUH_API_HOST WAZUH_API_PORT WAZUH_API_USER WAZUH_API_PASSWORD
    export WAZUH_INDEXER_HOST WAZUH_INDEXER_PORT WAZUH_INDEXER_USER \
           WAZUH_INDEXER_PASSWORD
    export WAZUH_DASHBOARD_PORT WAZUH_DASHBOARD_PASSWORD \
           WAZUH_MANAGER_CONTAINER WAZUH_INDEXER_CONTAINER
}

# wazuh_require_cmd CMD [CMD ...]
#
# Verify each command is on PATH. Echoes a consolidated error and returns
# 2 if any are missing (mirrors the existing convention in our scripts).
wazuh_require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "[!] missing required commands: ${missing[*]} (try: nix develop)" >&2
        return 2
    fi
    return 0
}

# wazuh_window_jq -- echoes the canonical jq filter selecting events whose
# .timestamp is within [$since, $until]. Callers pass `--arg since` and
# `--arg until` to jq.
#
# Usage:
#   jq -c --arg since "$since" --arg until "$until" "$(wazuh_window_jq)" file.json
wazuh_window_jq() {
    printf '%s' 'select(.timestamp >= $since and .timestamp <= $until)'
}
