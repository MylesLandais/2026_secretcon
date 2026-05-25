#!/usr/bin/env bash
set -euo pipefail

# Fetch or verify CysVuln challenge artifacts under infrastructure/artifacts/cysvuln/.
# Binaries are not committed to git; text scenario files are tracked after redaction.
#
# Usage:
#   ./scripts/fetch-cysvuln-artifacts.sh              # verify only
#   ./scripts/fetch-cysvuln-artifacts.sh --generate-msi
#   CYSVULN_INSTALLER_URL=<url> ./scripts/fetch-cysvuln-artifacts.sh
#
# See infrastructure/artifacts/cysvuln/readme.md for the full supply chain.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART_DIR="${REPO_ROOT}/infrastructure/artifacts/cysvuln"
EFS_NAME="60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe"
EFS_PATH="${ART_DIR}/${EFS_NAME}"
EFS_SHA256="${CYSVULN_INSTALLER_HASH:-60ea3256cd272797675e2ec6ea8e02d8ad51209f1cbf9083bc909284b5331d79}"
MSI_NAME="aie-validation-payload.msi"
MSI_PATH="${ART_DIR}/${MSI_NAME}"
GENERATE_MSI=0

for arg in "$@"; do
    case "$arg" in
        --generate-msi) GENERATE_MSI=1 ;;
        -h|--help)
            sed -n '1,20p' "$0"
            exit 0
            ;;
    esac
done

mkdir -p "$ART_DIR"

verify_sha256() {
    local file="$1" expected="$2"
    if [ ! -f "$file" ]; then
        echo "[!] missing: $file" >&2
        return 1
    fi
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "[!] sha256 mismatch for $(basename "$file")" >&2
        echo "    expected: $expected" >&2
        echo "    actual:   $actual" >&2
        return 3
    fi
    echo "[*] sha256 OK: $(basename "$file")"
}

# Text artifacts (tracked in git)
for f in joe-notes.txt admin-notes.txt option.ini; do
    if [ ! -f "${ART_DIR}/${f}" ]; then
        echo "[!] missing tracked artifact: ${ART_DIR}/${f}" >&2
        exit 2
    fi
done
echo "[*] text artifacts present"

# EFS installer
if [ -f "$EFS_PATH" ]; then
    verify_sha256 "$EFS_PATH" "$EFS_SHA256"
elif [ -n "${CYSVULN_INSTALLER_URL:-}" ]; then
    echo "[*] downloading ${EFS_NAME}"
    curl -L --fail -o "$EFS_PATH" "$CYSVULN_INSTALLER_URL"
    verify_sha256 "$EFS_PATH" "$EFS_SHA256"
else
    cat <<EOF
[!] EFS installer not found at:
    $EFS_PATH

    Obtain Easy File Sharing Web Server 6.9 installer (EFS Software) and place it
    at that path, or set CYSVULN_INSTALLER_URL to a direct download URL.

    Expected SHA-256: $EFS_SHA256
    Size: 3,877,866 bytes

    The bootstrap validates this hash before silent install.
EOF
    exit 2
fi

# AIE validation MSI (generated locally, not redistributed)
if [ -f "$MSI_PATH" ]; then
    echo "[*] $(basename "$MSI_PATH") present ($(wc -c < "$MSI_PATH") bytes)"
elif [ "$GENERATE_MSI" -eq 1 ]; then
    echo "[*] generating ${MSI_NAME} via WiX (check_aie_response.py)"
    if ! command -v wixl >/dev/null 2>&1; then
        echo "[!] wixl not on PATH; run: nix develop" >&2
        exit 2
    fi
    python3 "${REPO_ROOT}/scripts/validate/check_aie_response.py" \
        --command 'copy C:\Users\Administrator\Desktop\root.txt C:\Users\Public\aie-flag.txt' \
        --out "$MSI_PATH"
    echo "[*] wrote $MSI_PATH"
else
    cat <<EOF
[!] ${MSI_NAME} not found.

    Generate with:
      nix develop
      ./scripts/fetch-cysvuln-artifacts.sh --generate-msi

    Or copy a previously built MSI to:
      $MSI_PATH
EOF
    exit 2
fi

# OpenSSH zip (vendored, gitignored)
OPENSSH_ZIP="${REPO_ROOT}/provisioning/openssh/OpenSSH-Win64.zip"
if [ ! -f "$OPENSSH_ZIP" ]; then
    echo "[!] missing ${OPENSSH_ZIP} (download OpenSSH-Win64 portable and place there)" >&2
    exit 2
fi
echo "[*] OpenSSH-Win64.zip present"

echo "[*] CysVuln artifacts ready under ${ART_DIR}"
