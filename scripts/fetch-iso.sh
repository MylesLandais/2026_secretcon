#!/usr/bin/env bash
set -euo pipefail

# Fetch a Windows installer ISO for a SecretCon build target and verify sha256.
#
# Usage:
#   ./scripts/fetch-iso.sh <target> [<url>]
#   ISO_URL=<url> ./scripts/fetch-iso.sh <target>
#
# Targets:
#   win10-ltsc    Windows 10 Enterprise LTSC 2021 x64 en-us (Win10 EWS build)
#   server-2016   Windows Server 2016 Standard eval x64 en-us (CysVulnServer build)
#
# Default target stays win10-ltsc for backwards compatibility with existing callers.
#
# Fido is unreliable for LTSC variants; resolve a direct CDN URL from a mirror
# index and re-run. Mirror starting points:
#   - https://massgrave.dev/windows_ltsc_links
#   - https://www.microsoft.com/en-us/evalcenter/    (Server 2016 eval)
#   - https://archive.org/details/Windows10EnterpriseLTSC202164Bit

TARGET="${1:-win10-ltsc}"
URL="${2:-${ISO_URL:-}}"

case "$TARGET" in
    win10-ltsc)
        ISO_NAME="en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso"
        ISO_SHA256="c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d"
        HINTS="https://massgrave.dev/windows_ltsc_links  (en-us x64 LTSC 2021)"
        ;;
    server-2016)
        ISO_NAME="cysvuln-server-2016.iso"
        ISO_SHA256="1ce702a578a3cb1ac3d14873980838590f06d5b7101c5daaccbac9d73f1fb50f"
        HINTS="https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2016  or  ./scripts/stage-cysvuln-iso.sh"
        ;;
    -h|--help|help)
        sed -n '1,30p' "$0"
        exit 0
        ;;
    *)
        echo "[!] Unknown target: $TARGET" >&2
        echo "    Valid targets: win10-ltsc, server-2016" >&2
        exit 2
        ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${OUTDIR:-${REPO_ROOT}/infrastructure/packer/iso}"
mkdir -p "$OUTDIR"
OUT="${OUTDIR}/${ISO_NAME}"

if [ -z "$URL" ] && [ ! -f "$OUT" ]; then
    STAGE_SCRIPT="${REPO_ROOT}/scripts/stage-cysvuln-iso.sh"
    if [ "$TARGET" = "server-2016" ] && [ -x "$STAGE_SCRIPT" ]; then
        echo "[*] No ISO at $OUT — trying stage-cysvuln-iso.sh"
        "$STAGE_SCRIPT" || true
    fi
fi

if [ -z "$URL" ] && [ ! -f "$OUT" ]; then
    cat <<EOF
[!] No source URL given and no cached ISO at $OUT.
    Resolve a direct download URL from:
        $HINTS
    Then re-run: $0 $TARGET <url>
    Or:         ISO_URL=<url> $0 $TARGET
EOF
    exit 2
fi

if [ -f "$OUT" ]; then
    echo "[*] Existing ISO at $OUT — verifying sha256..."
else
    echo "[*] Downloading $ISO_NAME"
    echo "    From: $URL"
    echo "    To:   $OUT"
    curl -L -C - --fail -o "$OUT" "$URL"
fi

ACTUAL=$(sha256sum "$OUT" | awk '{print $1}')

if [ "$ISO_SHA256" = "none" ]; then
    echo "[!] No sha256 pinned for $TARGET yet. Observed sha256:"
    echo "    $ACTUAL"
    echo "    Record this in scripts/fetch-iso.sh under the '$TARGET' case to lock it in."
else
    if [ "$ACTUAL" != "$ISO_SHA256" ]; then
        echo "[!] sha256 mismatch — refusing to proceed."
        echo "    expected: $ISO_SHA256"
        echo "    actual:   $ACTUAL"
        echo "    File:     $OUT"
        exit 3
    fi
    echo "[*] sha256 OK"
fi

echo "[*] $OUT"
echo
case "$TARGET" in
    win10-ltsc)
        echo "Next:"
        echo "  - Local QEMU:  cd ${REPO_ROOT}/infrastructure/packer/ews && packer build -only=qemu.win10-ews-local ."
        echo "  - Proxmox:     scp \"$OUT\" root@<proxmox>:/var/lib/vz/template/iso/"
        ;;
    server-2016)
        echo "Next:"
        echo "  - Local QEMU:  CYSVULN_ISO=\$(readlink -f $OUT) nix build --impure .#cysvuln-local"
        echo "                 or: packer build -var cysvuln_iso_url=file://$OUT \\"
        echo "                                   ${REPO_ROOT}/infrastructure/packer/cysvuln/local-qemu-cysvuln.pkr.hcl"
        echo "  - Hyper-V:     copy ISO to the Windows build host; see docs/runbooks/deploy-cysvuln-multi-hypervisor.md"
        echo "  - VMware:      same; pass -var cysvuln_iso_url=file://$OUT to packer"
        ;;
esac
