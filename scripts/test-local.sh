#!/usr/bin/env bash
set -euo pipefail

# Cheap local checks that do not require Proxmox, ISOs, or a running VM.
# Run after: nix develop
#
# Usage: ./scripts/test-local.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "[*] pytest (request builder unit tests)"
if python3 -m pytest scripts/validate/tests -q; then
    pass "pytest"
else
    fail "pytest"
fi

echo "[*] packer validate (syntax)"
if command -v packer >/dev/null 2>&1; then
    # Dummy Proxmox creds so validate does not require a live cluster or .env.
    PACKER_PROXMOX_VARS=(
        -var 'proxmox_url=https://127.0.0.1:8006/api2/json'
        -var 'proxmox_username=packer@pam'
        -var 'proxmox_password=packer'
    )
    validate_packer_dir() {
        local pdir="$1"
        shift
        local extra_vars=("$@")
        if [ ! -d "$pdir" ] || ! ls "$pdir"/*.pkr.hcl >/dev/null 2>&1; then
            return 0
        fi
        # QEMU local build leaves output/ behind; validate refuses existing output dirs.
        rm -rf "${pdir}/output" 2>/dev/null || true
        if ( cd "$pdir" && packer init . >/dev/null 2>&1 && packer validate "${extra_vars[@]}" . ); then
            pass "packer validate $(basename "$pdir")"
        else
            fail "packer validate $(basename "$pdir")"
        fi
    }
    validate_packer_dir "${REPO_ROOT}/infrastructure/packer" "${PACKER_PROXMOX_VARS[@]}"
    validate_packer_dir "${REPO_ROOT}/infrastructure/packer/cysvuln" \
        "${PACKER_PROXMOX_VARS[@]}" \
        -var 'cysvuln_iso_url=file:///dev/null' \
        -var 'cysvuln_iso_checksum=none'
    validate_packer_dir "${REPO_ROOT}/infrastructure/packer/dc" "${PACKER_PROXMOX_VARS[@]}"
    validate_packer_dir "${REPO_ROOT}/infrastructure/packer/ews" \
        "${PACKER_PROXMOX_VARS[@]}" \
        -var 'iso_url=file:///dev/null'
else
    echo "SKIP  packer not on PATH (run nix develop)"
fi

echo "[*] bash syntax"
while IFS= read -r -d '' sh; do
    if bash -n "$sh"; then
        pass "bash -n $(basename "$sh")"
    else
        fail "bash -n $sh"
    fi
done < <(find scripts -name '*.sh' -print0)

echo "[*] provision manifests"
MANIFEST_SHARED="${REPO_ROOT}/infrastructure/packer/cysvuln/provision-manifest-shared.txt"
MANIFEST_CYSVULN="${REPO_ROOT}/infrastructure/packer/cysvuln/provision-manifest-cysvuln.txt"
# shellcheck source=scripts/lib/read-provision-manifest.sh
source "${REPO_ROOT}/scripts/lib/read-provision-manifest.sh"
while IFS= read -r path; do
    if [ -f "$path" ]; then
        pass "exists $(basename "$path")"
    else
        # binaries may be absent until fetch-cysvuln-artifacts.sh
        case "$path" in
            *.exe|*.msi)
                echo "SKIP  missing binary $(basename "$path") (run fetch-cysvuln-artifacts.sh)"
                ;;
            *)
                fail "missing $path"
                ;;
        esac
    fi
done < <(
    read_provision_manifest "$MANIFEST_CYSVULN" "$REPO_ROOT"
    read_provision_manifest "$MANIFEST_SHARED" "$REPO_ROOT"
)

echo "[*] text cysvuln artifacts"
for f in joe-notes.txt admin-notes.txt option.ini; do
    if [ -f "${REPO_ROOT}/infrastructure/artifacts/cysvuln/${f}" ]; then
        pass "$f"
    else
        fail "$f"
    fi
done

if [ -f "${REPO_ROOT}/.env" ]; then
    echo "WARN  .env present (gitignored; do not commit)"
else
    pass "no .env in tree"
fi

if git status --porcelain 2>/dev/null | grep -qE '(^|/)(\.env|wazuh-creds-.*\.txt|.*\.qcow2|.*\.vhdx)$'; then
    fail "git status shows staged/untracked secrets or VM images"
else
    pass "git status (no obvious secrets/images)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "[*] local checks passed"
    exit 0
fi
echo "[!] $FAIL check(s) failed"
exit 1
