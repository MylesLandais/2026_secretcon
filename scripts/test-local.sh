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
skip() { echo "SKIP  $1"; }

echo "[*] pytest (request builder + VNC crypto unit tests)"
if python3 -m pytest scripts/validate/tests -q; then
    pass "pytest"
else
    fail "pytest"
fi

echo "[*] vnc kali-tool static audit"
if python3 scripts/validate/audit-vnc-kali-tools.py; then
    pass "audit-vnc-kali-tools"
else
    fail "audit-vnc-kali-tools"
fi

echo "[*] vnc-cred-tool self-test"
if python3 scripts/observability/vnc-cred-tool.py self-test; then
    pass "vnc-cred-tool self-test"
else
    fail "vnc-cred-tool self-test"
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
        local label="$1"
        local pdir="$2"
        shift 2
        local extra_vars=("$@")
        if [ ! -d "$pdir" ] || ! ls "$pdir"/*.pkr.hcl >/dev/null 2>&1; then
            return 0
        fi
        rm -rf "${pdir}/output" "${pdir}/packer-output" 2>/dev/null || true
        if ( cd "$pdir" && packer init . >/dev/null 2>&1 && packer validate "${extra_vars[@]}" . ); then
            pass "packer validate ${label}"
            return 0
        fi
        return 1
    }
    validate_packer_dir packer "${REPO_ROOT}/infrastructure/packer" "${PACKER_PROXMOX_VARS[@]}" \
        || fail "packer validate packer"
    validate_packer_dir cysvuln "${REPO_ROOT}/infrastructure/packer/cysvuln" \
        "${PACKER_PROXMOX_VARS[@]}" \
        -var 'cysvuln_iso_url=file:///dev/null' \
        -var 'cysvuln_iso_checksum=none' \
        || fail "packer validate cysvuln"
    if ! validate_packer_dir asrep "${REPO_ROOT}/infrastructure/packer/asrep" \
        "${PACKER_PROXMOX_VARS[@]}" \
        -var 'asrep_iso_url=file:///dev/null' \
        -var 'asrep_iso_checksum=none'; then
        fail "packer validate asrep"
    fi
    validate_packer_dir dc "${REPO_ROOT}/infrastructure/packer/dc" "${PACKER_PROXMOX_VARS[@]}" \
        || fail "packer validate dc"
    validate_packer_dir ews "${REPO_ROOT}/infrastructure/packer/ews" \
        "${PACKER_PROXMOX_VARS[@]}" \
        -var 'iso_url=file:///dev/null' \
        || fail "packer validate ews"
else
    skip "packer not on PATH (run nix develop)"
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
                skip "missing binary $(basename "$path") (run fetch-cysvuln-artifacts.sh)"
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

validate_manifest_pair() {
    local label="$1"
    local prox_manifest="$2"
    local qemu_manifest="$3"
    local prox_list qemu_list path
    prox_list="$(mktemp)"
    qemu_list="$(mktemp)"
    read_provision_manifest "$prox_manifest" "$REPO_ROOT" > "$prox_list"
    read_provision_manifest "$qemu_manifest" "$REPO_ROOT" > "$qemu_list"
    while IFS= read -r path; do
        if [ -f "$path" ]; then
            pass "${label} proxmox $(basename "$path")"
        else
            case "$path" in
                *.exe|*.msi|*.zip) skip "${label} missing binary $(basename "$path")" ;;
                *) fail "${label} missing $path" ;;
            esac
        fi
    done < "$prox_list"
    while IFS= read -r path; do
        if grep -Fxq "$path" "$prox_list"; then
            pass "${label} qemu subset $(basename "$path")"
        else
            fail "${label} qemu-only path not in proxmox manifest: $path"
        fi
    done < "$qemu_list"
    rm -f "$prox_list" "$qemu_list"
}

echo "[*] EWS provision manifests"
validate_manifest_pair ews \
    "${REPO_ROOT}/infrastructure/packer/ews/provision-manifest-proxmox.txt" \
    "${REPO_ROOT}/infrastructure/packer/ews/provision-manifest-qemu.txt"

echo "[*] ASREP provision manifests"
while IFS= read -r path; do
    if [ -f "$path" ]; then
        pass "asrep exists $(basename "$path")"
    else
        case "$path" in
            *.exe|*.msi|*.zip) skip "asrep missing binary $(basename "$path")" ;;
            *) fail "asrep missing $path" ;;
        esac
    fi
done < <(
    read_provision_manifest "${REPO_ROOT}/infrastructure/packer/asrep/provision-manifest-asrep.txt" "$REPO_ROOT"
    read_provision_manifest "${REPO_ROOT}/infrastructure/packer/asrep/provision-manifest-shared.txt" "$REPO_ROOT"
)

echo "[*] ansible syntax-check (all playbooks)"
if command -v ansible-playbook >/dev/null 2>&1; then
    for pb in ews cysvuln asrep dc; do
        if ( cd ansible && ansible-playbook --syntax-check "playbooks/${pb}.yml" >/dev/null 2>&1 ); then
            pass "ansible syntax-check ${pb}.yml"
        else
            fail "ansible syntax-check ${pb}.yml"
        fi
    done
else
    skip "ansible-playbook not on PATH (run nix develop)"
fi

echo "[*] repo-audit env-coverage (non-blocking)"
if python3 "${REPO_ROOT}/.claude/skills/repo-audit/audit.py" env-coverage >/dev/null 2>&1; then
    pass "repo-audit env-coverage"
else
    skip "repo-audit env-coverage (warning only)"
fi

echo "[*] text cysvuln artifacts"
for f in joe-notes.txt admin-notes.txt option.ini; do
    if [ -f "${REPO_ROOT}/infrastructure/artifacts/cysvuln/${f}" ]; then
        pass "$f"
    else
        skip "$f (run ./scripts/fetch-cysvuln-artifacts.sh)"
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
