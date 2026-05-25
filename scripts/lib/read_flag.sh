#!/usr/bin/env bash
set -uo pipefail

# Read user.txt (User_Joe) or root.txt (Administrator) via Administrator WinRM.
#
# Reading user.txt as admin (not as Joe) is intentional: User_Joe is in the
# local Users group only, not Remote Management Users, so direct WinRM as
# Joe fails with 401. The full chain validator stages PsExec to pivot from
# Administrator to Joe for the actual attack; for a baseline SIEM slice we
# only need a deterministic powershell.exe Sysmon EID 1 event with the
# expected file path, so reading as admin produces the same observable
# pattern.
#
# Reading root.txt as admin mirrors the privileged read an AIE-elevated
# attacker would do via the SYSTEM cmd.exe child of msiexec; same logic.
#
# Usage:
#   ./scripts/lib/read_flag.sh <user|root> [target-ip]
#
# Env:
#   WINRM_PORT  default 15985
#   ADMIN_USER  default Administrator
#   ADMIN_PW    default PizzaMan123!

WHICH="${1:-}"
TARGET="${2:-127.0.0.1}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"

case "$WHICH" in
    user) FLAG_PATH='C:\Users\User_Joe\Desktop\user.txt' ;;
    root) FLAG_PATH='C:\Users\Administrator\Desktop\root.txt' ;;
    *)    echo "[!] usage: $0 <user|root> [target-ip]" >&2; exit 2 ;;
esac

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi

FLAG_PATH="$FLAG_PATH" python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_USER" "$ADMIN_PW" <<'PY'
import os, sys, winrm
target, port, user, pw = sys.argv[1:5]
s = winrm.Session(f"http://{target}:{port}/wsman",
                  auth=(user, pw), transport="ntlm")
r = s.run_ps(f"Get-Content {os.environ['FLAG_PATH']}")
sys.stdout.write(r.std_out.decode(errors="replace"))
sys.stderr.write(r.std_err.decode(errors="replace"))
sys.exit(r.status_code)
PY
