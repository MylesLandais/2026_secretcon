#!/usr/bin/env bash
# Day-2 CysVuln convergence — Ansible telemetry + EFS watchdog (no Packer rebake).
#
# Usage:
#   ./scripts/proxmox/converge-cysvuln.sh [--cysvuln-host 192.168.61.51] [--check]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

CYSVULN_HOST_CLI=""
CHECK_MODE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cysvuln-host) CYSVULN_HOST_CLI="$2"; shift 2 ;;
        --check) CHECK_MODE=1; shift ;;
        -h|--help)
            sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -f .env ]]; then
    while IFS='=' read -r k v; do
        [[ -z "${k}" || "${k}" =~ ^# ]] && continue
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        if [[ -z "${!k:-}" ]]; then export "${k}=${v}"; fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env || true)
fi

CYSVULN_HOST="${CYSVULN_HOST_CLI:-${CYSVULN_PROXMOX_IP:-${CHAIN_CYSVULN_IP:-192.168.61.51}}}"
export ANSIBLE_ADMIN_PASSWORD="${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}"

ANSIBLE_ARGS=()
[[ "${CHECK_MODE}" -eq 1 ]] && ANSIBLE_ARGS+=(--check --diff)

echo "[*] Ansible converge cysvuln @ ${CYSVULN_HOST}"
# shellcheck source=scripts/lib/ansible-proxmox-env.sh
source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
ansible_proxmox_load_env "${REPO_ROOT}"
(
    cd ansible
    ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
        playbooks/cysvuln.yml \
        -l cysvuln-proxmox \
        -e "ansible_host=${CYSVULN_HOST}" \
        "${ANSIBLE_ARGS[@]}"
)

echo "[+] converge-cysvuln complete @ ${CYSVULN_HOST}"
