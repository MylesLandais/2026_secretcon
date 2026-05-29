#!/usr/bin/env bash
# shellcheck shell=bash
# Export Proxmox/Ansible env for playbooks (community.proxmox reads PROXMOX_* / api_* vars).
#
# Usage:
#   source scripts/lib/ansible-proxmox-env.sh
#   ansible-playbook ...

ansible_proxmox_load_env() {
    local repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    # shellcheck source=scripts/lib/load_repo_env.sh
    source "${repo_root}/scripts/lib/load_repo_env.sh"
    load_repo_env "${repo_root}"

    export PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
    export PROXMOX_NODE="${PROXMOX_NODE:-manage}"
    export PROXMOX_USERNAME="${PROXMOX_USERNAME:-root@pam}"
    : "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"

    # community.proxmox module env fallbacks
    export PROXMOX_USER="${PROXMOX_USERNAME}"
}

ansible_proxmox_run_playbook() {
    local repo_root="${1:?repo root required}"
    shift
    ansible_proxmox_load_env "${repo_root}"
    (
        cd "${repo_root}/ansible"
        ansible-galaxy collection install -r requirements.yml 2>/dev/null || true
        ansible-playbook "$@"
    )
}
