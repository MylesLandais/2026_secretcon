#!/usr/bin/env bash
# Day-2 EWS convergence — Ansible guest + Proxmox hypervisor (no Packer rebake).
#
# Usage:
#   ./scripts/proxmox/converge-ews.sh [--ews-host 192.168.61.20] [--hot-vnc] [--check] [--no-discover] [--no-hypervisor] [--skip-verify]
#
# Env: same as rebuild-ews.sh for SSH/Ansible credentials.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

EWS_HOST_CLI=""
CHECK_MODE=0
NO_DISCOVER=0
SKIP_HYPERVISOR=0
SKIP_VERIFY=0
HOT_VNC=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ews-host)       EWS_HOST_CLI="$2"; shift 2 ;;
        --hot-vnc)        HOT_VNC=1; shift ;;
        --check)          CHECK_MODE=1; shift ;;
        --no-discover)    NO_DISCOVER=1; shift ;;
        --no-hypervisor)  SKIP_HYPERVISOR=1; shift ;;
        --skip-verify)    SKIP_VERIFY=1; shift ;;
        --tofu)           echo "[!] --tofu removed; hypervisor uses Ansible (drop --no-hypervisor to run)" >&2; shift ;;
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
        if [[ -z "${!k:-}" ]]; then
            export "${k}=${v}"
        fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env || true)
fi

EWS_HOST="${EWS_HOST_CLI:-${EWS_HOST:-192.168.61.20}}"
export ANSIBLE_ADMIN_PASSWORD="${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}"

if [[ "${HOT_VNC}" -eq 1 ]]; then
    exec "${REPO_ROOT}/scripts/proxmox/hot-patch-ews-vnc.sh" --ews-host "${EWS_HOST}" all
fi

DISCOVERED_INV="${REPO_ROOT}/ansible/inventory/proxmox.discovered.yml"
ANSIBLE_INVENTORY="${REPO_ROOT}/ansible/inventory/proxmox.yml"
if [[ "${NO_DISCOVER}" -eq 0 ]]; then
    if ! "${REPO_ROOT}/scripts/proxmox/discover-proxmox-inventory.sh"; then
        echo "[!] discovery failed — using static inventory and EWS_HOST=${EWS_HOST}" >&2
    fi
fi
if [[ -f "${DISCOVERED_INV}" ]]; then
    ANSIBLE_INVENTORY="${DISCOVERED_INV}"
    if [[ -z "${EWS_HOST_CLI}" ]]; then
        DISCOVERED_HOST="$(grep 'ansible_host:' "${ANSIBLE_INVENTORY}" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
        if [[ -n "${DISCOVERED_HOST}" ]]; then
            EWS_HOST="${DISCOVERED_HOST}"
        fi
    fi
fi

ANSIBLE_ARGS=()
if [[ "${CHECK_MODE}" -eq 1 ]]; then
    ANSIBLE_ARGS+=(--check --diff)
fi

echo "[*] Ansible converge ews @ ${EWS_HOST} (inventory: ${ANSIBLE_INVENTORY##*/})"
# shellcheck source=scripts/lib/ansible-proxmox-env.sh
source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
ansible_proxmox_load_env "${REPO_ROOT}"
(
    cd "${REPO_ROOT}/ansible"
    ansible-galaxy collection install -r requirements.yml 2>/dev/null || true
    ansible-playbook playbooks/ews.yml \
        -i "${ANSIBLE_INVENTORY}" \
        --limit ews \
        -e "ansible_host=${EWS_HOST}" \
        "${ANSIBLE_ARGS[@]}"
)

if [[ "${SKIP_HYPERVISOR}" -eq 0 && "${CHECK_MODE}" -eq 0 ]]; then
    echo
    echo "[*] Ansible hypervisor converge (playbooks/proxmox/ews-hypervisor.yml)"
    ansible_proxmox_run_playbook "${REPO_ROOT}" \
        playbooks/proxmox/ews-hypervisor.yml \
        -e "proxmox_guest_agent_converged=true"
fi

if [[ "${CHECK_MODE}" -eq 0 && "${SKIP_VERIFY}" -eq 0 ]]; then
    echo
    echo "[*] verify-ews (nmap + RFB probe + SSH preconditions)"
    if ! "${REPO_ROOT}/scripts/verify-ews.sh" "${EWS_HOST}"; then
        echo "[!] verify-ews failed — registry may show FELDTECH_VNC while runtime auth is wrong;" >&2
        echo "    hot iterate: ./scripts/proxmox/converge-ews.sh --ews-host ${EWS_HOST} --hot-vnc" >&2
        echo "    full converge: ./scripts/proxmox/converge-ews.sh --ews-host ${EWS_HOST} --no-discover" >&2
        exit 1
    fi
fi

echo "[+] converge-ews complete"
echo "    probe: ./scripts/proxmox/probe-ews.sh --target ${EWS_HOST}"
