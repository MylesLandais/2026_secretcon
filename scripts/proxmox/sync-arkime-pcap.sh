#!/usr/bin/env bash
# Push a PCAP file to the SecretCon production Arkime VM (VMID 111) and
# import it into the running stack via `docker exec`. Mirrors the local
# scripts/arkime-import-pcap.sh pattern but goes over the WireGuard
# tunnel + Proxmox jump-host.
#
# Usage:
#   ./scripts/proxmox/sync-arkime-pcap.sh [--tag TAG] [--force] <pcap-path>
#
# Flags:
#   --tag TAG       tag the import with TAG (multiple --tag ok)
#   --force         re-import even if Arkime already indexed this file name
#   --host IP       Arkime VM IP (default 192.168.61.11)
#   --run-id ID     artifact subdir for log capture
#
# Env:
#   PROXMOX_HOST, PROXMOX_PASSWORD     (.env)
#   ARKIME_HOST                         (default 192.168.61.11)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

TAGS=()
FORCE=0
HOST_CLI=""
RUN_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)    shift; TAGS+=("$1"); shift ;;
        --force)  FORCE=1; shift ;;
        --host)   HOST_CLI="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --)       shift; break ;;
        -h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)       echo "[!] unknown flag: $1" >&2; exit 2 ;;
        *)        break ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--tag TAG] [--force] <pcap-path>" >&2
    exit 2
fi
PCAP_PATH="$1"
[[ -f "${PCAP_PATH}" ]] || { echo "[!] PCAP not found: ${PCAP_PATH}" >&2; exit 2; }

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
: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"
ARKIME_HOST="${HOST_CLI:-${ARKIME_HOST:-192.168.61.11}}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/provisioning/ssh/packer_ed25519}"

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="ews-prod-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/prod-proof-${RUN_ID}"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/sync-arkime-pcap.log"

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
[[ -n "${SSHPASS_BIN}" ]] || { echo "[!] sshpass not on PATH" >&2; exit 1; }

PROXY="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR -W %h:%p root@${PROXMOX_HOST}"
SSH_OPTS=(
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
    -o IdentitiesOnly=yes
    -o UserKnownHostsFile=/dev/null
    -i "${SSH_KEY}"
    -o "ProxyCommand=${PROXY}"
)
vm_ssh() { ssh "${SSH_OPTS[@]}" "dadmin@${ARKIME_HOST}" "$@"; }
vm_scp() { scp "${SSH_OPTS[@]}" "$@"; }

NAME="$(basename "${PCAP_PATH}")"
CONTAINER_PATH="/opt/arkime/raw/${NAME}"

{
    echo "[*] sync-arkime-pcap"
    echo "    pcap : ${PCAP_PATH}"
    echo "    host : dadmin@${ARKIME_HOST}"
    echo "    tags : ${TAGS[*]:-(none)}"
} | tee -a "${LOG}"

# Idempotency: skip re-import unless --force.
if [[ "${FORCE}" -eq 0 ]]; then
    count="$(curl -sf --max-time 5 \
        "http://${ARKIME_HOST}:9201/arkime_files/_count?q=name:%22${CONTAINER_PATH}%22" 2>/dev/null \
        | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+' || true)"
    if [[ -n "${count}" ]] && [[ "${count}" -gt 0 ]]; then
        echo "[*] ${NAME} already indexed (count=${count}); pass --force to re-ingest" | tee -a "${LOG}"
        echo "    viewer: http://${ARKIME_HOST}:8005/sessions?expression=file%3D%3D%22${CONTAINER_PATH}%22" | tee -a "${LOG}"
        exit 0
    fi
fi

echo "[*] scp ${NAME} -> dadmin@${ARKIME_HOST}:/opt/arkime-docker/pcaps/" | tee -a "${LOG}"
# Stage in /tmp first (dadmin owns it), then sudo-mv into the bind-mount.
vm_scp "${PCAP_PATH}" "dadmin@${ARKIME_HOST}:/tmp/${NAME}"
vm_ssh "sudo install -o root -g root -m 0644 /tmp/${NAME} /opt/arkime-docker/pcaps/${NAME} && rm -f /tmp/${NAME}"

cap_args=(/opt/arkime/bin/capture -c /opt/arkime/etc/config.ini -r "${CONTAINER_PATH}" -n local)
for t in "${TAGS[@]}"; do
    cap_args+=(--tag "$t")
done

echo "[*] Importing ${NAME} via arkime.viewer" | tee -a "${LOG}"
vm_ssh "docker exec arkime.viewer ${cap_args[*]}" 2>&1 | tee -a "${LOG}"

echo "[+] Imported ${NAME}" | tee -a "${LOG}"
echo "    viewer: http://${ARKIME_HOST}:8005/sessions?expression=file%3D%3D%22${CONTAINER_PATH}%22" | tee -a "${LOG}"
