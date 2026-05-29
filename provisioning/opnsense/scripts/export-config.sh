#!/usr/bin/env bash
# Pull /conf/config.xml from the SecretCon OPNsense VM, sanitize secrets,
# and write to provisioning/opnsense/config.xml ready for commit.
#
# Auth path: SSH (configd is more reliable than the API for raw config
# pulls). Requires either OPNSENSE_SSH_KEY or OPNSENSE_SSH_PASSWORD in
# .env. OPNSENSE_SSH_USER defaults to 'root'.
#
# Sanitization is deterministic XPath stripping via python3 + lxml
# (lxml is in nix develop? falls back to ElementTree). Each stripped
# value is replaced with `__SECRETCON_STRIPPED__` so a re-import asks
# the operator to re-enter the value rather than silently restoring
# stale credentials.
#
# Usage:
#   ./provisioning/opnsense/scripts/export-config.sh
#   ./provisioning/opnsense/scripts/export-config.sh --dry-run
#   ./provisioning/opnsense/scripts/export-config.sh --out /tmp/config.xml

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

DRY_RUN=0
OUT_PATH="${REPO_ROOT}/provisioning/opnsense/config.xml"
OPNSENSE_HOST="${OPNSENSE_HOST:-192.168.61.253}"
OPNSENSE_SSH_USER="${OPNSENSE_SSH_USER:-root}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --out)     OUT_PATH="$2"; shift 2 ;;
        --host)    OPNSENSE_HOST="$2"; shift 2 ;;
        -h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\n[*] %s\n' "$*"; }

SSH_OPTS=(
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
    -o LogLevel=ERROR
)

SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
if [ -z "${SSHPASS_BIN}" ] && command -v nix >/dev/null 2>&1; then
    SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
fi

ssh_with_auth() {
    if [ -n "${OPNSENSE_SSH_KEY:-}" ] && [ -f "${OPNSENSE_SSH_KEY}" ]; then
        ssh -i "${OPNSENSE_SSH_KEY}" -o IdentitiesOnly=yes \
            -o PreferredAuthentications=publickey "${SSH_OPTS[@]}" \
            "${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}" "$@"
    elif [ -n "${OPNSENSE_SSH_PASSWORD:-}" ]; then
        [ -n "${SSHPASS_BIN}" ] || { echo "[!] sshpass required for password auth" >&2; exit 1; }
        "${SSHPASS_BIN}" -p "${OPNSENSE_SSH_PASSWORD}" \
            ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${SSH_OPTS[@]}" "${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}" "$@"
    else
        echo "[!] need OPNSENSE_SSH_KEY or OPNSENSE_SSH_PASSWORD in .env" >&2
        exit 1
    fi
}

step "Pulling /conf/config.xml from ${OPNSENSE_SSH_USER}@${OPNSENSE_HOST}"
RAW_TMP="$(mktemp /tmp/opnsense-config-raw.XXXXXX.xml)"
trap 'rm -f "${RAW_TMP}"' EXIT
ssh_with_auth 'cat /conf/config.xml' > "${RAW_TMP}"

# Sanity check the XML before we sanitize.
if ! head -c 256 "${RAW_TMP}" | grep -q '<opnsense>'; then
    echo "[!] pulled file does not look like OPNsense config.xml" >&2
    head -20 "${RAW_TMP}" >&2
    exit 1
fi

step "Sanitizing secrets"
SAN_TMP="$(mktemp /tmp/opnsense-config-san.XXXXXX.xml)"
trap 'rm -f "${RAW_TMP}" "${SAN_TMP}"' EXIT

python3 - "${RAW_TMP}" "${SAN_TMP}" "${DRY_RUN}" <<'PY'
import sys, re
import xml.etree.ElementTree as ET

src, dst, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
PLACEHOLDER = "__SECRETCON_STRIPPED__"

tree = ET.parse(src)
root = tree.getroot()

# XPaths to strip (ElementTree XPath subset: relative to root).
# Each entry: (xpath, tag_label) -- we walk and replace .text with PLACEHOLDER.
STRIP_RULES = [
    (".//apikeys/item/key",            "apikeys/key"),
    (".//apikeys/item/secret",         "apikeys/secret"),
    (".//cert/prv",                    "cert/prv (TLS private key)"),
    (".//openvpn/openvpn-server//tls", "openvpn/tls"),
    (".//system/user/password",        "system/user/password"),
    (".//system/user/email",           "system/user/email"),
    (".//ipsec//pre-shared-key",       "ipsec/pre-shared-key"),
    (".//snmpd//rocommunity",          "snmpd/rocommunity"),
]

changes = []
for xp, label in STRIP_RULES:
    for elem in root.iterfind(xp):
        if elem.text and elem.text.strip():
            changes.append((label, elem.text[:24] + ("..." if len(elem.text) > 24 else "")))
            if not dry:
                elem.text = PLACEHOLDER

print(f"  {len(changes)} secret(s) to be stripped:")
for label, preview in changes:
    print(f"    {label}  ({preview})")

if not dry:
    tree.write(dst, encoding="utf-8", xml_declaration=True)
    print(f"  written: {dst}")
PY
RC=$?
if [ "${RC}" -ne 0 ]; then
    echo "[!] sanitization failed (rc=${RC})" >&2
    exit "${RC}"
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    step "DRY RUN: not writing ${OUT_PATH}"
    exit 0
fi

step "Writing sanitized config to ${OUT_PATH}"
install -m 0644 "${SAN_TMP}" "${OUT_PATH}"

if command -v git >/dev/null 2>&1; then
    step "Diff vs index"
    git -C "${REPO_ROOT}" diff --stat -- "${OUT_PATH}" || true
    echo
    echo "[+] If the diff is intentional, commit with:"
    echo "    git add ${OUT_PATH}"
    echo "    git commit -m 'feat(opnsense): refresh sanitized config.xml export'"
fi
