#!/usr/bin/env bash
set -euo pipefail

# Build the PROVISION ISO that Hyper-V mounts as the secondary CD.
# Hyper-V's packer-plugin-hyperv builder does not accept cd_files directly,
# so we materialize the contents into an ISO here and pass the path via
# the cysvuln_provision_iso variable.
#
# QEMU and VMware sources do not need this; they consume cd_files natively.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-${REPO_ROOT}/infrastructure/packer/cysvuln/provision.iso}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$REPO_ROOT/provisioning/cysvuln/autounattend.xml"                                       "$STAGE/"
cp "$REPO_ROOT/provisioning/openssh/setup-openssh.ps1"                                      "$STAGE/"
cp "$REPO_ROOT/provisioning/openssh/OpenSSH-Win64.zip"                                      "$STAGE/"
cp "$REPO_ROOT/provisioning/ssh/packer_ed25519.pub"                                         "$STAGE/"
cp "$REPO_ROOT/infrastructure/artifacts/cysvuln/60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe" "$STAGE/"
cp "$REPO_ROOT/infrastructure/artifacts/cysvuln/joe-notes.txt"                              "$STAGE/"
cp "$REPO_ROOT/infrastructure/artifacts/cysvuln/admin-notes.txt"                            "$STAGE/"
cp "$REPO_ROOT/infrastructure/artifacts/cysvuln/option.ini"                                 "$STAGE/"

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
