#!/usr/bin/env bash
# Local QEMU EWS — day-2 converge without Packer rebake.
#
# Priority ladder (same as Proxmox):
#   1. hot-patch  (~30s)  ./scripts/converge-local-ews.sh --hot-vnc
#   2. full ansible       ./scripts/converge-local-ews.sh
#   3. packer rebake      nix build .#win10-ews-local  (last resort)
#
# Requires EWS VM running: ./scripts/run-local-vm.sh
#
# Usage:
#   ./scripts/converge-local-ews.sh [--hot-vnc] [--check]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

EWS_HOST="127.0.0.1"
EWS_SSH_PORT="${EWS_SSH_PORT:-2222}"
EWS_VNC_PORT="${EWS_VNC_PORT:-5900}"
CHECK_MODE=0
HOT_VNC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hot-vnc) HOT_VNC=1; shift ;;
        --check) CHECK_MODE=1; shift ;;
        -h|--help)
            sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown: $1" >&2; exit 2 ;;
    esac
done

if ! nc -z -w1 "${EWS_HOST}" "${EWS_SSH_PORT}" 2>/dev/null; then
    echo "[!] EWS SSH not on ${EWS_HOST}:${EWS_SSH_PORT} — start VM first:" >&2
    echo "    nix develop -c ./scripts/run-local-vm.sh" >&2
    exit 1
fi

export ANSIBLE_ADMIN_PASSWORD="${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}"
export VNC_PW="${VNC_PW:-FELDTECH_VNC}"

if [[ "${HOT_VNC}" -eq 1 ]]; then
    echo "[*] local hot-patch VNC @ ${EWS_HOST}:${EWS_VNC_PORT}"
    nix develop -c ansible-playbook ansible/playbooks/ews.yml \
        -i "${EWS_HOST}," \
        -e "ansible_host=${EWS_HOST}" \
        -e "ansible_port=${EWS_SSH_PORT}" \
        -e "ansible_user=Administrator" \
        -e "ansible_password=${ANSIBLE_ADMIN_PASSWORD}" \
        -e "ansible_connection=ssh" \
        -e "ansible_shell_type=powershell" \
        --tags ultravnc_hot \
        --skip-tags always
    python3 ansible/roles/ultravnc/files/check_vnc_auth.py \
        --host "${EWS_HOST}" --port "${EWS_VNC_PORT}" \
        --password "${VNC_PW}" \
        --cred-tool scripts/observability/vnc-cred-tool.py
    echo "[+] hot-vnc OK — promote with: ./scripts/converge-local-ews.sh"
    exit 0
fi

ANSIBLE_ARGS=()
[[ "${CHECK_MODE}" -eq 1 ]] && ANSIBLE_ARGS+=(--check --diff)

echo "[*] Ansible converge EWS @ ${EWS_HOST}:${EWS_SSH_PORT}"
nix develop -c ansible-playbook ansible/playbooks/ews.yml \
    -i "${EWS_HOST}," \
    -e "ansible_host=${EWS_HOST}" \
    -e "ansible_port=${EWS_SSH_PORT}" \
    -e "ansible_user=Administrator" \
    -e "ansible_password=${ANSIBLE_ADMIN_PASSWORD}" \
    -e "ansible_connection=ssh" \
    -e "ansible_shell_type=powershell" \
    "${ANSIBLE_ARGS[@]}"

python3 ansible/roles/ultravnc/files/check_vnc_auth.py \
    --host "${EWS_HOST}" --port "${EWS_VNC_PORT}" \
    --password "${VNC_PW}" \
    --cred-tool scripts/observability/vnc-cred-tool.py || {
    echo "[!] RFB verify failed — try: ./scripts/converge-local-ews.sh --hot-vnc" >&2
    exit 1
}

echo "[+] converge-local-ews complete"
