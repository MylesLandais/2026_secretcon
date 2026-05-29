#!/usr/bin/env bash
# SecretCon EWS rebuild orchestrator (Proxmox).
#
# Packer (thin bootstrap + Ansible ews.yml) -> Ansible hypervisor (bridge/agent) ->
# optional Ansible converge -> verify-ews.sh
#
# Usage:
#   ./scripts/proxmox/rebuild-ews.sh \
#       [--run-id ID] [--ews-host 192.168.61.20] \
#       [--skip-verify] [--no-bridge-move] \
#       [--skip-packer] [--skip-hypervisor] [--skip-ansible]
#
# Env:
#   PROXMOX_HOST, PROXMOX_PASSWORD, PROXMOX_URL, PROXMOX_USERNAME
#   EWS_VM_ID (109), EWS_FINAL_BRIDGE (vmbr1), EWS_HOST (192.168.61.20)
#   SECRETCON_USER_FLAG, SECRETCON_ROOT_FLAG (required for packer bake)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RUN_ID=""
EWS_HOST_CLI=""
SKIP_VERIFY=0
NO_BRIDGE_MOVE=0
SKIP_PACKER=0
SKIP_HYPERVISOR=0
SKIP_ANSIBLE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)         RUN_ID="$2"; shift 2 ;;
        --ews-host)       EWS_HOST_CLI="$2"; shift 2 ;;
        --skip-verify)    SKIP_VERIFY=1; shift ;;
        --no-bridge-move) NO_BRIDGE_MOVE=1; shift ;;
        --skip-packer)    SKIP_PACKER=1; shift ;;
        --skip-hypervisor) SKIP_HYPERVISOR=1; shift ;;
        --skip-tofu)      SKIP_HYPERVISOR=1; shift ;;
        --skip-ansible)   SKIP_ANSIBLE=1; shift ;;
        -h|--help)        sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                echo "[!] unknown flag: $1" >&2; exit 2 ;;
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

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
PROXMOX_NODE="${PROXMOX_NODE:-manage}"
: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
EWS_VM_ID="${EWS_VM_ID:-109}"
EWS_FINAL_BRIDGE="${EWS_FINAL_BRIDGE:-vmbr1}"
EWS_HOST="${EWS_HOST_CLI:-${EWS_HOST:-192.168.61.20}}"
PATRICK_PW="${PATRICK_PW:-Changeme123!}"

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="ews-prod-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/prod-proof-${RUN_ID}"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/rebuild-ews.log"
exec > >(tee -a "${LOG}") 2>&1

echo "[*] rebuild-ews run_id=${RUN_ID}"
echo "    proxmox    : root@${PROXMOX_HOST}"
echo "    vm_id      : ${EWS_VM_ID}"
echo "    final_iface: ${EWS_FINAL_BRIDGE}"
echo "    final_ip   : ${EWS_HOST}"

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
[[ -n "${SSHPASS_BIN}" ]] || { echo "[!] sshpass not on PATH (try: nix develop)" >&2; exit 1; }

pmx_ssh() {
    ${SSHPASS_BIN} -p "${PROXMOX_PASSWORD}" \
        ssh -o StrictHostKeyChecking=accept-new \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o LogLevel=ERROR \
            "root@${PROXMOX_HOST}" "$@"
}

run_ansible_hypervisor() {
    echo
    echo "[*] Ansible hypervisor (campaign bridge ${EWS_FINAL_BRIDGE})"
    # shellcheck source=scripts/lib/ansible-proxmox-env.sh
    source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
    export EWS_FORCE_BRIDGE=1
    export EWS_FINAL_BRIDGE
    export EWS_VM_ID
    ansible_proxmox_run_playbook "${REPO_ROOT}" \
        playbooks/proxmox/ews-hypervisor.yml \
        -e "proxmox_guest_agent_converged=true" \
        -e "ews_reboot_on_bridge_change=true"
}

run_ansible_converge() {
    echo
    echo "[*] Ansible converge (playbooks/ews.yml)"
    export ANSIBLE_ADMIN_PASSWORD="${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}"
    (
        cd "${REPO_ROOT}/ansible"
        ansible-galaxy collection install -r requirements.yml --force-with-deps 2>/dev/null || \
            ansible-galaxy collection install -r requirements.yml
        ansible-playbook playbooks/ews.yml \
            -i inventory/proxmox.yml \
            --limit ews \
            -e "ansible_host=${EWS_HOST}"
    )
}

if [[ "${SKIP_PACKER}" -eq 0 ]]; then
    : "${SECRETCON_USER_FLAG:?SECRETCON_USER_FLAG must be set (Packer var)}"
    : "${SECRETCON_ROOT_FLAG:?SECRETCON_ROOT_FLAG must be set (Packer var)}"

    echo
    echo "[*] Tearing down VMID ${EWS_VM_ID} (if present)"
    pmx_ssh "if qm status ${EWS_VM_ID} >/dev/null 2>&1; then \
                qm stop ${EWS_VM_ID} 2>/dev/null || true; \
                for i in 1 2 3 4 5 6 7 8 9 10; do \
                    qm status ${EWS_VM_ID} 2>/dev/null | grep -q running || break; \
                    sleep 2; \
                done; \
                qm destroy ${EWS_VM_ID} --purge 1 --skiplock 1; \
             else echo '    no VMID ${EWS_VM_ID} present'; fi" \
        || { echo "[!] teardown failed"; exit 1; }

    echo
    echo "[*] Packer build (thin bootstrap + Ansible provisioner)"
    PACKER_DIR="${REPO_ROOT}/infrastructure/packer/ews"
    ( cd "${PACKER_DIR}" && packer init . )
    ( cd "${PACKER_DIR}" && PACKER_LOG=0 packer build -only='proxmox-iso.win10-ews' . )
else
    echo "[*] Skipping Packer (--skip-packer)"
fi

if [[ "${NO_BRIDGE_MOVE}" -eq 0 && "${SKIP_HYPERVISOR}" -eq 0 ]]; then
    run_ansible_hypervisor
elif [[ "${NO_BRIDGE_MOVE}" -eq 0 ]]; then
    echo
    echo "[*] Moving VMID ${EWS_VM_ID} to bridge ${EWS_FINAL_BRIDGE} (qm set fallback)"
    pmx_ssh "qm set ${EWS_VM_ID} --net0 e1000,bridge=${EWS_FINAL_BRIDGE},firewall=1"
    pmx_ssh "qm reboot ${EWS_VM_ID} || qm start ${EWS_VM_ID}"
else
    echo "[*] Skipping bridge move (--no-bridge-move)"
fi

echo
echo "[*] Waiting for ${EWS_HOST}:5900 (max 5 min)"
DEADLINE=$(( $(date +%s) + 300 ))
while ! timeout 3 bash -c "</dev/tcp/${EWS_HOST}/5900" 2>/dev/null; do
    if (( $(date +%s) > DEADLINE )); then
        echo "[!] ${EWS_HOST}:5900 did not come up within 5 min" >&2
        exit 1
    fi
    sleep 5
done
echo "    ${EWS_HOST}:5900 reachable."

if [[ "${SKIP_ANSIBLE}" -eq 0 ]]; then
    run_ansible_converge
else
    echo "[*] Skipping post-build Ansible (--skip-ansible)"
fi

if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
    echo
    echo "[*] verify-ews.sh"
    if "${REPO_ROOT}/scripts/verify-ews.sh" "${EWS_HOST}" "${PATRICK_PW}"; then
        echo "[+] verify-ews PASSED on VMID ${EWS_VM_ID}"
    else
        echo "[!] verify-ews FAILED on VMID ${EWS_VM_ID}" >&2
        exit 1
    fi
fi

echo
echo "[+] rebuild-ews complete (log: ${LOG})"
echo "    day-2 converge: scripts/proxmox/converge-ews.sh --ews-host ${EWS_HOST}"
