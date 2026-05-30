#!/usr/bin/env bash
# Fast resilience gate — no QEMU required. Run before every commit on Tier A work.
#
# Usage: ./scripts/validate/resilience-gate-fast.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"
FAIL=0

check() {
    local name="$1"
    shift
    printf '[gate] %-40s ' "$name"
    if "$@"; then
        echo OK
    else
        echo FAIL
        FAIL=$((FAIL + 1))
    fi
}

check "watchdog go build" "${REPO_ROOT}/scripts/build-watchdog.sh"
check "watchdog binary in role" test -x "${REPO_ROOT}/ansible/roles/watchdog_agent/files/secretcon-watchdog.exe"
check "go vet" bash -c "cd tools/watchdog && go vet ./..."
check "go test config" bash -c "cd tools/watchdog && go test ./config/..."
check "ansible role watchdog_agent" test -f ansible/roles/watchdog_agent/tasks/main.yml
check "host ctf-baseline-reset --help" "${REPO_ROOT}/scripts/host/ctf-baseline-reset.sh" --help
check "host challenge-failover --help" "${REPO_ROOT}/scripts/host/challenge-failover.sh" --help
check "webservice stub compose" docker compose -f infrastructure/webservice/docker-compose.yml config --quiet
check "ews playbook syntax" bash -c "cd \"${REPO_ROOT}/ansible\" && nix develop -c ansible-playbook playbooks/ews.yml --syntax-check -i inventory/proxmox.yml"
check "cysvuln playbook syntax" bash -c "cd \"${REPO_ROOT}/ansible\" && nix develop -c ansible-playbook playbooks/cysvuln.yml --syntax-check -i inventory/proxmox.yml"

if [ "$FAIL" -ne 0 ]; then
    echo "[gate] ${FAIL} check(s) failed"
    exit 1
fi
echo "[gate] all fast checks passed"
