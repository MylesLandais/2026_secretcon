#!/usr/bin/env bash
# Render autounattend.xml with campaign secrets substituted.
#
# Usage:
#   ./scripts/lib/render_autounattend.sh <source.xml> <dest.xml>
#
# Substitutes:
#   __SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD__

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=chain_env.sh
source "${REPO_ROOT}/scripts/lib/chain_env.sh"

SRC="${1:-}"
DST="${2:-}"

if [ -z "$SRC" ] || [ -z "$DST" ]; then
    echo "usage: $0 <source.xml> <dest.xml>" >&2
    exit 2
fi

if [ ! -f "$SRC" ]; then
    echo "[!] source not found: $SRC" >&2
    exit 1
fi

python3 - "$SRC" "$DST" "${3:-$SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD}" <<'PY'
import sys
from pathlib import Path

src, dst, password = sys.argv[1:4]
text = Path(src).read_text(encoding="utf-8")
token = "__SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD__"
if token not in text:
    sys.stderr.write(f"warning: {token} not found in {src}\n")
text = text.replace(token, password)
Path(dst).write_text(text, encoding="utf-8")
PY

echo "[+] rendered $DST"
