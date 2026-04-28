#!/usr/bin/env bash
set -euo pipefail

# Fido wrapper for downloading official Microsoft Windows ISOs
# https://github.com/pbatard/Fido

FIDO_URL="https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1"
FIDO_SCRIPT="${HOME}/.cache/secretcon/Fido.ps1"
OUTDIR="${HOME}/Downloads"

mkdir -p "$(dirname "$FIDO_SCRIPT")"
mkdir -p "$OUTDIR"

if [ ! -f "$FIDO_SCRIPT" ]; then
    echo "[*] Downloading Fido..."
    curl -L -o "$FIDO_SCRIPT" "$FIDO_URL"
fi

# Default: Windows 11 LTSC (recommended for ICS/OT environments)
WIN_VERSION="${1:-Windows 11}"
WIN_RELEASE="${2:-23H2}"
WIN_EDITION="${3:-Enterprise LTSC}"
WIN_LANG="${4:-English International}"

echo "[*] Fetching ISO via Fido..."
echo "    Version: $WIN_VERSION"
echo "    Release: $WIN_RELEASE"
echo "    Edition: $WIN_EDITION"
echo "    Lang:    $WIN_LANG"
echo "    Out:     $OUTDIR"

pwsh -ExecutionPolicy Bypass -File "$FIDO_SCRIPT" \
    -Win "$WIN_VERSION" \
    -Rel "$WIN_RELEASE" \
    -Ed "$WIN_EDITION" \
    -Lang "$WIN_LANG" \
    -GetUrl \
    | tee /tmp/fido-url.txt

URL=$(tail -1 /tmp/fido-url.txt)
if [ -n "$URL" ] && [[ "$URL" == http* ]]; then
    FILENAME=$(basename "$(echo "$URL" | sed 's/?.*//')")
    [ -z "$FILENAME" ] && FILENAME="win11-ltsc-eval.iso"
    echo "[*] Downloading $FILENAME..."
    curl -L -C - -o "$OUTDIR/$FILENAME" "$URL"
    echo "[*] Saved: $OUTDIR/$FILENAME"
else
    echo "[!] Failed to extract download URL from Fido output"
    echo "    Raw output saved to /tmp/fido-url.txt"
    exit 1
fi
