#!/usr/bin/env bash
set -euo pipefail

# Stage a local Server 2016 ISO for CysVuln Packer / nix build.
#
# Usage:
#   ./scripts/stage-cysvuln-iso.sh [path-to-iso]
#
# Default source: ~/Downloads/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO
# Output: infrastructure/packer/iso/cysvuln-server-2016.iso (symlink)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${REPO_ROOT}/infrastructure/packer/iso"
CANONICAL="${OUTDIR}/cysvuln-server-2016.iso"
SRC="${1:-${HOME}/Downloads/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO}"

if [ ! -f "$SRC" ]; then
    echo "[!] ISO not found: $SRC" >&2
    echo "    Pass the path explicitly: $0 /path/to/server-2016.iso" >&2
    exit 2
fi

mkdir -p "$OUTDIR"
ln -sf "$(readlink -f "$SRC")" "$CANONICAL"

ACTUAL=$(sha256sum "$CANONICAL" | awk '{print $1}')
echo "[+] Staged: $CANONICAL -> $(readlink -f "$CANONICAL")"
echo "[*] sha256: $ACTUAL"
echo
echo "Next:"
echo "  export CYSVULN_ISO=\$(readlink -f \"$CANONICAL\")"
echo "  nix build --impure .#cysvuln-local"
