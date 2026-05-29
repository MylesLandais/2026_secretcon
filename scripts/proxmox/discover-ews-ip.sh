#!/usr/bin/env bash
# Print the current EWS guest IPv4 (for nmap / hydra). Wrapper around discovery.
#
# Usage:
#   ./scripts/proxmox/discover-ews-ip.sh
#   nmap -Pn "$(./scripts/proxmox/discover-ews-ip.sh)" -p 5900,22
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IP="$("${REPO_ROOT}/scripts/proxmox/discover-proxmox-inventory.sh" --stdout \
    | awk -F'"' '/ansible_host:/ {print $2; exit}')"
if [[ -z "${IP}" ]]; then
    echo "[!] discovery failed" >&2
    exit 1
fi
echo "${IP}"
