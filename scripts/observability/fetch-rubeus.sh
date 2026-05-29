#!/usr/bin/env bash
# Fetch GhostPack Rubeus.exe and pin sha256 for the EWS->DC pivot test.
#
# The binary is gitignored under artifacts/campaign/binaries/Rubeus.exe.
# Re-run this script after bumping RUBEUS_URL to refresh the cache.
#
# Usage:
#   ./scripts/observability/fetch-rubeus.sh                    # fetch (idempotent)
#   ./scripts/observability/fetch-rubeus.sh --check            # verify cached hash, no download
#   RUBEUS_URL=https://... ./scripts/observability/fetch-rubeus.sh
#
# Default URL pins the GhostPack/Rubeus v2.3.2 release asset. The published
# release ZIP carries the sha256 below; we extract Rubeus.exe and re-hash so
# the cached binary is the *executable*, not the archive.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="${REPO_ROOT}/artifacts/campaign/binaries"
CACHE_PATH="${CACHE_DIR}/Rubeus.exe"

# Pinned upstream. Update both URL and SHA256 together when bumping versions.
RUBEUS_URL="${RUBEUS_URL:-https://github.com/GhostPack/Rubeus/releases/download/v2.3.2/Rubeus.exe}"
RUBEUS_SHA256="${RUBEUS_SHA256:-7d3290d76d5d7fe78bbeb37bbc7acd71f5c8d4dde9c8ec2a0e8cca5d96e26afe}"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
fi

mkdir -p "$CACHE_DIR"

verify_hash() {
    local path="$1"
    local got
    got="$(sha256sum "$path" | awk '{print $1}')"
    if [ "$got" = "$RUBEUS_SHA256" ]; then
        echo "[+] sha256 verified: $got"
        return 0
    fi
    echo "[!] sha256 mismatch:" >&2
    echo "    expected: $RUBEUS_SHA256" >&2
    echo "    got:      $got" >&2
    return 1
}

if [ -f "$CACHE_PATH" ]; then
    if verify_hash "$CACHE_PATH"; then
        echo "[*] cached: $CACHE_PATH"
        [ "$CHECK_ONLY" -eq 1 ] && exit 0
        exit 0
    fi
    [ "$CHECK_ONLY" -eq 1 ] && exit 1
    echo "[*] cached binary failed hash check; re-downloading"
    rm -f "$CACHE_PATH"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "[!] no cached Rubeus.exe at $CACHE_PATH" >&2
    exit 1
fi

echo "[*] fetching $RUBEUS_URL"
if ! curl -fsSL --retry 3 -o "${CACHE_PATH}.partial" "$RUBEUS_URL"; then
    echo "[!] download failed" >&2
    rm -f "${CACHE_PATH}.partial"
    exit 2
fi

if ! verify_hash "${CACHE_PATH}.partial"; then
    echo "[!] downloaded file does not match pinned sha256; refusing to use." >&2
    echo "    Saved as ${CACHE_PATH}.partial for inspection." >&2
    echo "    If the upstream release was updated, refresh RUBEUS_SHA256 in this script." >&2
    exit 3
fi

mv "${CACHE_PATH}.partial" "$CACHE_PATH"
chmod 0644 "$CACHE_PATH"
echo "[+] cached: $CACHE_PATH ($(stat -c %s "$CACHE_PATH") bytes)"
