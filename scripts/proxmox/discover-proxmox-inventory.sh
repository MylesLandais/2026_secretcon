#!/usr/bin/env bash
# Discover live Proxmox EWS VM and render Ansible inventory fragment.
#
# Resolves ansible_host by (in order):
#   1. Proxmox bridge ARP/neighbor table (VM net0 MAC -> IPv4)
#   2. VNC probe on configured candidates (EWS_HOST, EWS_PROD_HOST)
#   3. Optional arp-scan sweep on the VM's bridge subnet
#
# Usage:
#   ./scripts/proxmox/discover-proxmox-inventory.sh [--stdout] [--vm-id 109]
#
# Exit 0 when a reachable EWS host is found; exit 1 otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

STDOUT_ONLY=0
EWS_VM_ID_CLI=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stdout)   STDOUT_ONLY=1; shift ;;
        --vm-id)    EWS_VM_ID_CLI="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/lib/proxmox-ssh.sh
source "${REPO_ROOT}/scripts/lib/proxmox-ssh.sh"
proxmox_load_env

EWS_VM_ID="${EWS_VM_ID_CLI:-${EWS_VM_ID:-109}}"
EWS_PROD_HOST="${EWS_PROD_HOST:-192.168.60.109}"
EWS_HOST="${EWS_HOST:-192.168.61.20}"
EWS_FINAL_BRIDGE="${EWS_FINAL_BRIDGE:-vmbr1}"
OUT_FILE="${REPO_ROOT}/ansible/inventory/proxmox.discovered.yml"

probe_vnc() {
    local ip="$1"
    timeout 3 bash -c "</dev/tcp/${ip}/5900" 2>/dev/null
}

qm_status="$(pxssh "qm status ${EWS_VM_ID} 2>/dev/null" || true)"
if [[ -z "${qm_status}" ]]; then
    echo "[!] VMID ${EWS_VM_ID} not found on ${PROXMOX_HOST}" >&2
    exit 1
fi

qm_config="$(pxssh "qm config ${EWS_VM_ID}" 2>/dev/null || true)"
proxmox_bridge=""
net_mac=""
if [[ -n "${qm_config}" ]]; then
    proxmox_bridge="$(printf '%s\n' "${qm_config}" | sed -n 's/^net0:.*bridge=\([^,]*\).*/\1/p' | head -1)"
    net_mac="$(printf '%s\n' "${qm_config}" | sed -n 's/^net0:[[:space:]]*[^=]*=\([0-9A-Fa-f:]*\).*/\1/p' | head -1 | tr '[:upper:]' '[:lower:]')"
fi
proxmox_bridge="${proxmox_bridge:-unknown}"

echo "[*] Proxmox VMID ${EWS_VM_ID}: ${qm_status%%$'\n'*}"
echo "    net0 bridge: ${proxmox_bridge}"
[[ -n "${net_mac}" ]] && echo "    net0 MAC:    ${net_mac}"

DISCOVERED_IP=""
ARP_IP=""

if [[ -n "${net_mac}" && "${proxmox_bridge}" != "unknown" ]]; then
    ARP_IP="$(pxssh "ip -4 neigh show dev ${proxmox_bridge} 2>/dev/null | awk -v m='${net_mac}' 'tolower(\$5)==m {print \$1; exit}'" | tr -d '\r' | head -1)"
    if [[ -n "${ARP_IP}" ]]; then
        echo "[+] ARP on ${proxmox_bridge}: ${net_mac} -> ${ARP_IP}"
        if probe_vnc "${ARP_IP}"; then
            DISCOVERED_IP="${ARP_IP}"
            echo "[+] VNC reachable at ${ARP_IP}:5900"
        else
            echo "[.] ${ARP_IP}:5900 not open (ARP hit but VNC closed — guest may still be booting)"
        fi
    else
        echo "[.] No ARP entry for ${net_mac} on ${proxmox_bridge} (run arp-scan from Proxmox or wait for guest DHCP)"
    fi
fi

if [[ -z "${DISCOVERED_IP}" ]]; then
    for candidate in "${EWS_HOST}" "${EWS_PROD_HOST}"; do
        [[ -z "${candidate}" ]] && continue
        if probe_vnc "${candidate}"; then
            DISCOVERED_IP="${candidate}"
            echo "[+] VNC reachable at ${candidate}:5900"
            break
        fi
        echo "[.] ${candidate}:5900 not open"
    done
fi

# Use ARP IP for inventory even when VNC is not up yet (Ansible SSH may still work)
if [[ -z "${DISCOVERED_IP}" && -n "${ARP_IP}" ]]; then
    DISCOVERED_IP="${ARP_IP}"
    echo "[i] Using ARP IP ${ARP_IP} (VNC not confirmed — try: nmap -Pn ${ARP_IP} -p 5900)"
fi

if [[ -z "${DISCOVERED_IP}" && -n "${proxmox_bridge}" && "${proxmox_bridge}" != "unknown" ]]; then
  case "${proxmox_bridge}" in
    vmbr1)
      SUBNET_CIDR="192.168.61.0/24"
      ;;
    vmbr0)
      SUBNET_CIDR="192.168.60.0/24"
      ;;
    *)
      SUBNET_CIDR=""
      ;;
  esac
  if [[ -n "${SUBNET_CIDR}" && -n "${net_mac}" ]]; then
    echo "[*] arp-scan on ${proxmox_bridge} (${SUBNET_CIDR}) for ${net_mac}"
    SCAN_IP="$(pxssh "command -v arp-scan >/dev/null && arp-scan -I ${proxmox_bridge} ${SUBNET_CIDR} --timeout=200 --retry=1 2>/dev/null | awk -v m='${net_mac}' 'tolower(\$2)==m {print \$1; exit}'" | tr -d '\r' | head -1)"
    if [[ -n "${SCAN_IP}" ]]; then
      echo "[+] arp-scan: ${net_mac} -> ${SCAN_IP}"
      if probe_vnc "${SCAN_IP}"; then
        DISCOVERED_IP="${SCAN_IP}"
        echo "[+] VNC reachable at ${SCAN_IP}:5900"
      else
        DISCOVERED_IP="${SCAN_IP}"
        echo "[i] Using ${SCAN_IP} from arp-scan (VNC not open yet)"
      fi
    fi
  fi
fi

if [[ -z "${DISCOVERED_IP}" ]]; then
    echo "[!] Could not resolve EWS IP (tried ARP, ${EWS_HOST}, ${EWS_PROD_HOST})" >&2
    echo "    From console: note the guest IPv4, then:" >&2
    echo "      nmap -Pn <that-ip> -p 5900" >&2
    echo "      ./scripts/proxmox/converge-ews.sh --ews-host <that-ip> --no-discover" >&2
    echo "    Pin campaign IP: set EWS_STATIC_IP=192.168.61.20 in .env and converge" >&2
    exit 1
fi

if [[ "${proxmox_bridge}" == "vmbr0" && "${DISCOVERED_IP}" == "${EWS_HOST}" ]]; then
    echo "[i] VM reports vmbr0 but campaign IP ${EWS_HOST} is up — bridge metadata may be stale"
elif [[ "${proxmox_bridge}" == "vmbr0" ]]; then
    echo "[i] On vmbr0 at ${DISCOVERED_IP}; move-ews-bridge.sh for campaign ${EWS_HOST}"
elif [[ "${DISCOVERED_IP}" != "${EWS_HOST}" ]]; then
    echo "[i] Guest is ${DISCOVERED_IP} (expected campaign ${EWS_HOST}). Set EWS_STATIC_IP=${EWS_HOST} and converge to pin."
fi

INV_CONTENT="# Generated by scripts/proxmox/discover-proxmox-inventory.sh — do not edit.
all:
  children:
    windows:
      children:
        ews:
          hosts:
            ews-prod:
              ansible_host: \"${DISCOVERED_IP}\"
              proxmox_vmid: ${EWS_VM_ID}
              proxmox_bridge: \"${proxmox_bridge}\"
              proxmox_mac: \"${net_mac}\"
"

if [[ "${STDOUT_ONLY}" -eq 1 ]]; then
    printf '%s' "${INV_CONTENT}"
else
    mkdir -p "$(dirname "${OUT_FILE}")"
    printf '%s' "${INV_CONTENT}" > "${OUT_FILE}"
    echo "[+] Wrote ${OUT_FILE}"
    echo "    ansible_host=${DISCOVERED_IP}"
    echo "    nmap: nmap -Pn ${DISCOVERED_IP} -p 5900,22"
fi

exit 0
