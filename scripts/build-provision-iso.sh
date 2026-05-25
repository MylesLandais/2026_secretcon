#!/usr/bin/env bash
set -euo pipefail

# Build the PROVISION ISO that Hyper-V mounts as the secondary CD.
# Hyper-V's packer-plugin-hyperv builder does not accept cd_files directly,
# so we materialize the contents into an ISO here and pass the path via
# the cysvuln_provision_iso variable.
#
# QEMU and VMware sources consume the same file list via Packer manifests.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYSVULN_DIR="${REPO_ROOT}/infrastructure/packer/cysvuln"
OUT="${OUT:-${CYSVULN_DIR}/provision.iso}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Manifest lines match scripts/build-provision-iso.ps1 Read-ManifestLines (strip # comments, skip blanks).
# shellcheck source=scripts/lib/read-provision-manifest.sh
source "${REPO_ROOT}/scripts/lib/read-provision-manifest.sh"

while IFS= read -r src; do
    base="$(basename "$src")"
    cp "$src" "${STAGE}/${base}"
done < <(
    read_provision_manifest "${CYSVULN_DIR}/provision-manifest-cysvuln.txt" "$REPO_ROOT"
    read_provision_manifest "${CYSVULN_DIR}/provision-manifest-shared.txt" "$REPO_ROOT"
)

if command -v genisoimage >/dev/null; then
    genisoimage -quiet -J -r -V PROVISION -o "$OUT" "$STAGE"
elif command -v mkisofs >/dev/null; then
    mkisofs -quiet -J -r -V PROVISION -o "$OUT" "$STAGE"
elif command -v xorrisofs >/dev/null; then
    xorrisofs -quiet -J -r -V PROVISION -o "$OUT" "$STAGE"
else
    echo "[!] need one of: genisoimage, mkisofs, xorrisofs (cdrkit / cdrtools / libisoburn)" >&2
    exit 2
fi

echo "[*] $OUT"
