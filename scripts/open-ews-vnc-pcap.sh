#!/usr/bin/env bash
# Open an EWS VNC PCAP in Wireshark (GUI).
#
# Usage:
#   ./scripts/open-ews-vnc-pcap.sh [path-to.pcap]
#
# Default: targets/ews-vnc-pcap-forensics/vnc_auth.pcap
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PCAP="${1:-${REPO_ROOT}/targets/ews-vnc-pcap-forensics/vnc_auth.pcap}"

if [[ ! -f "${PCAP}" ]]; then
    echo "[!] PCAP not found: ${PCAP}" >&2
    echo "    Generate one: ./scripts/observability/vnc-public-attack.sh --target <ews-ip>" >&2
    exit 1
fi

launch() {
    local bin="$1"
    echo "[*] Opening ${PCAP} with ${bin}"
    exec "${bin}" "${PCAP}"
}

if command -v wireshark >/dev/null 2>&1; then
    launch wireshark
fi

if command -v nix >/dev/null 2>&1; then
    exec nix shell nixpkgs#wireshark --command wireshark "${PCAP}"
fi

echo "[!] wireshark not found. Install Wireshark or run: nix shell nixpkgs#wireshark" >&2
exit 1
