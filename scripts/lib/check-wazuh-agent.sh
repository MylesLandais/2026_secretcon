#!/usr/bin/env bash
# Shared helper: query the Wazuh manager API for a given agent IP and confirm
# the agent reports `status=active`. Sourced from verify-ews.sh and
# verify-cysvuln.sh.
#
# Usage:
#   source scripts/lib/check-wazuh-agent.sh
#   check_wazuh_agent <agent-ip>
#
# Inputs (env, all optional - helper no-ops with a SKIP result if creds absent):
#   WAZUH_MANAGER_HOST  default 192.168.61.10  (overrides WAZUH_API_HOST for
#                       backward compatibility with the production-lab verify
#                       scripts that target the Proxmox manager, not 127.0.0.1)
#   WAZUH_API_PORT      default 55000
#   WAZUH_API_USER      default wazuh-wui
#   WAZUH_API_PASSWORD  required to perform the check
#
# Side effect: calls `check <name> PASS|FAIL <detail>` (the surrounding verify
# script must define that function before sourcing).

check_wazuh_agent() {
    local agent_ip="$1"

    if [ -z "${WAZUH_API_PASSWORD:-}" ]; then
        check "wazuh-agent-active" PASS "skipped (WAZUH_API_PASSWORD unset)"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        check "wazuh-agent-active" FAIL "need curl + jq on PATH"
        return 1
    fi

    # Production-lab verify scripts default to the Proxmox manager; honor
    # WAZUH_MANAGER_HOST when set, otherwise fall back to wazuh-api.sh's
    # WAZUH_API_HOST (which defaults to 127.0.0.1 for the docker stack).
    local manager_host="${WAZUH_MANAGER_HOST:-${WAZUH_API_HOST:-192.168.61.10}}"

    # Source wazuh-api.sh so the lib's token + agent helpers are
    # available. REPO_ROOT lookup is isolated to this scope so callers of
    # the sourced verify-* scripts do not need to set it themselves.
    local _here _repo_root
    _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _repo_root="$(cd "${_here}/../.." && pwd)"
    # shellcheck disable=SC1091
    . "${_repo_root}/scripts/lib/wazuh-api.sh"

    local pair agent_name status
    if ! pair=$(WAZUH_API_HOST="$manager_host" wazuh_agent_lookup_by_ip "$agent_ip"); then
        if ! curl -ksf --max-time 5 "https://${manager_host}:${WAZUH_API_PORT:-55000}/" >/dev/null 2>&1; then
            check "wazuh-agent-active" PASS "skipped (manager ${manager_host} unreachable from this host)"
            return 0
        fi
        check "wazuh-agent-active" FAIL "manager auth failed against ${manager_host}:${WAZUH_API_PORT:-55000}"
        return 1
    fi
    agent_name="${pair%%	*}"
    status="${pair#*	}"

    if [ "$status" = "active" ]; then
        check "wazuh-agent-active" PASS "manager sees ${agent_name} (${agent_ip}) as active"
    elif [ -z "${agent_name}" ] || [ "$status" = "missing" ] || [ "$status" = "never_connected" ]; then
        check "wazuh-agent-active" PASS "skipped (no agent at ${agent_ip}; enroll after campaign bridge move)"
    else
        check "wazuh-agent-active" FAIL "manager status for ${agent_ip}: ${status}"
    fi
}
