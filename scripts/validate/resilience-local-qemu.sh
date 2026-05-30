#!/usr/bin/env bash
# Local QEMU resilience gate — crash + clean tests for EWS and CysVuln.
#
# Usage:
#   ./scripts/validate/resilience-local-qemu.sh [--ews-only] [--cysvuln-only] [--skip-build]
#
# Env: RESILIENCE_KEEP_VM=1, WAZUH_VALIDATE=0, ARTIFACTS_DIR

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RUN_EWS=1
RUN_CYS=1
SKIP_BUILD=0
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACTS="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts/resilience-validate/${STAMP}}"
export ARTIFACTS_DIR="${ARTIFACTS}"

while [ $# -gt 0 ]; do
    case "$1" in
        --ews-only) RUN_CYS=0; shift ;;
        --cysvuln-only) RUN_EWS=0; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help)
            sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "${ARTIFACTS}"
SUMMARY="${ARTIFACTS}/summary.json"
FAIL=0

log() { echo "[resilience] $*"; }

log "fast gate (no QEMU)"
./scripts/validate/resilience-gate-fast.sh || exit 1

converge_watchdog_ews() {
    nix develop -c ansible-playbook ansible/playbooks/ews.yml \
        -i "127.0.0.1," \
        -e "ansible_host=127.0.0.1" \
        -e "ansible_port=${EWS_SSH_PORT:-2222}" \
        -e "ansible_user=Administrator" \
        -e "ansible_password=${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}" \
        -e "ansible_connection=ssh" \
        -e "ansible_shell_type=powershell" \
        --tags watchdog_agent \
        --skip-tags always
}

converge_watchdog_cysvuln() {
    nix develop -c ansible-playbook ansible/playbooks/cysvuln.yml \
        -i "127.0.0.1," \
        -e "ansible_host=127.0.0.1" \
        -e "ansible_port=${WINRM_PORT:-15985}" \
        -e "ansible_user=Administrator" \
        -e "ansible_password=${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}" \
        -e "ansible_connection=winrm" \
        -e "ansible_winrm_transport=ntlm" \
        --tags watchdog_agent \
        --skip-tags always
}

ensure_qcow() {
    local flake attr disk hint
    flake="$1"; attr="$2"; disk="$3"; hint="$4"
    if [ -f "$disk" ]; then
        log "reuse disk $disk"
        return 0
    fi
    if [ "$SKIP_BUILD" -eq 1 ]; then
        log "SKIP: $disk missing and --skip-build set ($hint)"
        return 1
    fi
    log "building $flake#$attr ..."
    if nix build "${flake}#${attr}" -o "${ARTIFACTS}/nix-${attr}" 2>"${ARTIFACTS}/nix-build-${attr}.log"; then
        ln -sf "$(readlink -f "${ARTIFACTS}/nix-${attr}")" "$disk" 2>/dev/null || \
            cp -f "$(readlink -f "${ARTIFACTS}/nix-${attr}")" "$disk"
        return 0
    fi
    log "nix build failed — see ${ARTIFACTS}/nix-build-${attr}.log"
    return 1
}

start_cysvuln() {
    local disk="${REPO_ROOT}/result/cysvuln.qcow2"
    mkdir -p "${REPO_ROOT}/result"
    ensure_qcow "." "cysvuln-local" "$disk" "nix build .#cysvuln-local" || return 1
    "${REPO_ROOT}/scripts/run-local-cysvuln.sh" --headless "$disk"
    WINRM_PORT=15985 WAIT_AGENT=0 "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 300
}

start_ews() {
    local disk="${REPO_ROOT}/output/win10-ews-local/win10-ews-local.qcow2"
    mkdir -p "${REPO_ROOT}/output/win10-ews-local"
    if [ ! -f "$disk" ] && [ -f "${REPO_ROOT}/infrastructure/packer/ews/output/win10-ews-local/win10-ews-local.qcow2" ]; then
        disk="${REPO_ROOT}/infrastructure/packer/ews/output/win10-ews-local/win10-ews-local.qcow2"
    fi
    if [ ! -f "$disk" ]; then
        log "EWS disk not found at $disk — run packer local-qemu-ews or place qcow2"
        return 1
    fi
    if ! pgrep -f "win10-ews-local.qcow2" >/dev/null 2>&1; then
        log "starting EWS VM (SPICE daemon) — set RESILIENCE_KEEP_VM=1 to leave running"
        "${REPO_ROOT}/scripts/run-local-vm.sh" --headless "$disk"
    fi
    WINRM_PORT=5985 WAIT_AGENT=0 "${REPO_ROOT}/scripts/lib/wait_for_winrm.sh" 127.0.0.1 360
}

run_test() {
    local name="$1"; shift
    log "=== $name ==="
    if "$@"; then
        echo "\"${name}\": \"pass\"," >> "${ARTIFACTS}/summary-parts.txt"
    else
        echo "\"${name}\": \"fail\"," >> "${ARTIFACTS}/summary-parts.txt"
        FAIL=$((FAIL + 1))
    fi
}

: > "${ARTIFACTS}/summary-parts.txt"

if [ "$RUN_CYS" -eq 1 ]; then
    if start_cysvuln; then
        log "converge watchdog_agent on CysVuln"
        converge_watchdog_cysvuln || true
        run_test cysvuln_watchdog_agent "${REPO_ROOT}/scripts/validate/test-watchdog-agent.sh" --target 127.0.0.1 --winrm-port "${WINRM_PORT:-15985}" --profile cysvuln
        run_test cysvuln_watchdog_supervisor "${REPO_ROOT}/scripts/validate/test-watchdog-supervisor.sh" --target 127.0.0.1 --winrm-port "${WINRM_PORT:-15985}"
        run_test cysvuln_efs_crash "${REPO_ROOT}/scripts/validate/test-cysvuln-efs-crash.sh" 127.0.0.1
        run_test cysvuln_efs_clean "${REPO_ROOT}/scripts/validate/test-cysvuln-efs-clean.sh" 127.0.0.1
    else
        echo "\"cysvuln\": \"skipped\"," >> "${ARTIFACTS}/summary-parts.txt"
        FAIL=$((FAIL + 1))
    fi
fi

if [ "$RUN_EWS" -eq 1 ]; then
    if start_ews; then
        log "converge watchdog_agent on EWS"
        converge_watchdog_ews || true
        run_test ews_watchdog_agent "${REPO_ROOT}/scripts/validate/test-watchdog-agent.sh" --target 127.0.0.1 --winrm-port 5985 --profile ews
        run_test ews_watchdog_supervisor "${REPO_ROOT}/scripts/validate/test-watchdog-supervisor.sh" --target 127.0.0.1 --winrm-port 5985
        run_test ews_lpe_crash "${REPO_ROOT}/scripts/validate/test-ews-lpe-crash.sh" --target 127.0.0.1
        run_test ews_lpe_clean "${REPO_ROOT}/scripts/validate/test-ews-lpe-clean.sh" --target 127.0.0.1 --no-reset
    else
        echo "\"ews\": \"skipped\"," >> "${ARTIFACTS}/summary-parts.txt"
        FAIL=$((FAIL + 1))
    fi
fi

{
    echo "{"
    echo "  \"timestamp\": \"${STAMP}\","
    echo "  \"artifacts\": \"${ARTIFACTS}\","
    echo "  \"results\": {"
    if [ -s "${ARTIFACTS}/summary-parts.txt" ]; then
        sed '$ s/,$//' "${ARTIFACTS}/summary-parts.txt" | sed 's/^/    /'
    fi
    echo "  }"
    echo "}"
} > "${SUMMARY}"

log "summary: ${SUMMARY}"
[ "$FAIL" -eq 0 ]
