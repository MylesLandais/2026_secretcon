#!/usr/bin/env bash
# Shared helper: query the Wazuh manager API for a given agent IP and confirm
# the agent reports `status=active`. Sourced from verify-ews.sh and
# verify-cysvuln.sh.
#
# Usage:
#   source scripts/lib/check-wazuh-agent.sh
#   check_wazuh_agent <agent-ip>
#
# Inputs (env, all optional — helper no-ops with a SKIP result if creds absent):
#   WAZUH_MANAGER_HOST  default 192.168.61.10
#   WAZUH_API_PORT      default 55000
#   WAZUH_API_USER      default wazuh-wui
#   WAZUH_API_PASSWORD  required to perform the check
#
# Side effect: calls `check <name> PASS|FAIL <detail>` (the surrounding verify
# script must define that function before sourcing).

check_wazuh_agent() {
    local agent_ip="$1"
    local manager="${WAZUH_MANAGER_HOST:-192.168.61.10}"
    local port="${WAZUH_API_PORT:-55000}"
    local user="${WAZUH_API_USER:-wazuh-wui}"
    local pass="${WAZUH_API_PASSWORD:-}"

    if [ -z "$pass" ]; then
        check "wazuh-agent-active" PASS "skipped (WAZUH_API_PASSWORD unset)"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        check "wazuh-agent-active" FAIL "need curl + jq on PATH"
        return 1
    fi

    local token
    token=$(curl -sk -u "${user}:${pass}" -X POST \
        "https://${manager}:${port}/security/user/authenticate?raw=true" \
        --max-time 10)
    if [ -z "$token" ] || [[ "$token" == *"error"* ]]; then
        check "wazuh-agent-active" FAIL "manager auth failed against ${manager}:${port}"
        return 1
    fi

    local agent_json
    agent_json=$(curl -sk -H "Authorization: Bearer ${token}" \
        "https://${manager}:${port}/agents?ip=${agent_ip}" \
        --max-time 10)
    local status
    status=$(echo "$agent_json" | jq -r '.data.affected_items[0].status // "missing"')
    local agent_name
    agent_name=$(echo "$agent_json" | jq -r '.data.affected_items[0].name // "?"')

    if [ "$status" = "active" ]; then
        check "wazuh-agent-active" PASS "manager sees ${agent_name} (${agent_ip}) as active"
    else
        check "wazuh-agent-active" FAIL "manager status for ${agent_ip}: ${status}"
    fi
}
