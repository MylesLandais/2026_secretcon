#!/usr/bin/env bash
set -uo pipefail

# Read the user flag from C:\Users\User_Joe\Desktop\user.txt via an
# Administrator WinRM session. Rationale: User_Joe is in the local Users
# group only, not Remote Management Users / Administrators, so direct
# WinRM as Joe fails with 401. The chain validator stages PsExec to
# pivot from Administrator -> Joe in an interactive logon for the actual
# attack; for a baseline SIEM phase we just want a deterministic
# "something read user.txt" event, so reading as admin is fine - what
# matters for analyst pivot is the file path in Sysmon EID 11/13 + the
# powershell.exe Sysmon EID 1.
#
# Usage:
#   ./scripts/lib/read_user_flag.sh [target-ip]
#
# Env:
#   WINRM_PORT  default 15985
#   ADMIN_USER  default Administrator
#   ADMIN_PW    default PizzaMan123!

TARGET="${1:-127.0.0.1}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi

python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_USER" "$ADMIN_PW" <<'PY'
import sys, winrm
target, port, user, pw = sys.argv[1:5]
s = winrm.Session(f"http://{target}:{port}/wsman",
                  auth=(user, pw), transport="ntlm")
r = s.run_ps(r"Get-Content C:\Users\User_Joe\Desktop\user.txt")
sys.stdout.write(r.std_out.decode(errors="replace"))
sys.stderr.write(r.std_err.decode(errors="replace"))
sys.exit(r.status_code)
PY
