#!/usr/bin/env bash
# Fast UltraVNC hot patch — iterate in ~30s, no full ews.yml converge.
#
# Usage:
#   ./scripts/proxmox/hot-patch-ews-vnc.sh [--ews-host IP] [apply|verify|all]
#
# Workflow:
#   1. Hot patch until check_vnc_auth / wordlist passes (this script).
#   2. Promote to declarative: ./scripts/proxmox/converge-ews.sh --ews-host IP --no-discover
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/lib/vnc-lab.sh
source "${REPO_ROOT}/scripts/lib/vnc-lab.sh"
vnc_load_env

EWS_HOST="${EWS_HOST:-192.168.61.158}"
PHASE="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ews-host) EWS_HOST="$2"; shift 2 ;;
        apply|verify|all) PHASE="$1"; shift ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
    esac
done

export ANSIBLE_ADMIN_PASSWORD="${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}}"
export VNC_PW="${VNC_PW:-FELDTECH_VNC}"
WORDLIST="$(vnc_resolve_wordlist)"
CRED_TOOL="${REPO_ROOT}/scripts/observability/vnc-cred-tool.py"
AUTH_PROBE="${REPO_ROOT}/ansible/roles/ultravnc/files/check_vnc_auth.py"
INV="${REPO_ROOT}/ansible/inventory/proxmox.yml"

run_apply() {
    echo "[*] hot-patch apply @ ${EWS_HOST} (tags ultravnc_hot, ~30s)"
    # shellcheck source=scripts/lib/ansible-proxmox-env.sh
    source "${REPO_ROOT}/scripts/lib/ansible-proxmox-env.sh"
    ansible_proxmox_load_env "${REPO_ROOT}"
    (
        cd "${REPO_ROOT}/ansible"
        ansible-playbook playbooks/ews.yml \
            -i "${INV}" \
            --limit ews \
            -e "ansible_host=${EWS_HOST}" \
            --tags ultravnc_hot \
            --skip-tags always
    )
}

run_verify() {
    echo "[*] hot-patch verify @ ${EWS_HOST}"
    if ! python3 "${AUTH_PROBE}" \
        --host "${EWS_HOST}" --password "${VNC_PW}" \
        --cred-tool "${CRED_TOOL}" --json; then
        echo "[!] single-probe failed" >&2
        return 1
    fi
    if ! python3 "${AUTH_PROBE}" \
        --host "${EWS_HOST}" --wordlist "${WORDLIST}" \
        --delay-seconds 0 --max-retries 1 \
        --cred-tool "${CRED_TOOL}" --json; then
        echo "[!] wordlist sweep failed" >&2
        return 1
    fi
    echo "[+] hot-patch verify OK"
}

case "${PHASE}" in
    apply) run_apply ;;
    verify) run_verify ;;
    all)
        run_apply
        run_verify
        ;;
esac

echo "[+] done. Promote when stable: ./scripts/proxmox/converge-ews.sh --ews-host ${EWS_HOST} --no-discover"
