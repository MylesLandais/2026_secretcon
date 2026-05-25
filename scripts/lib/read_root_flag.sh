#!/usr/bin/env bash
set -uo pipefail

# Read the root flag from C:\Users\Administrator\Desktop\root.txt by
# opening a WinRM session as Administrator (NTLM). Phase-08 of the
# baseline tour: a clean SYSTEM-privileged read so Wazuh sees a
# deterministic powershell EID 1 by an admin user. After AIE the
# attacker would typically use the SYSTEM cmd.exe child of msiexec to
# read this file; we use direct admin WinRM here to keep the per-phase
# slice atomic.
#
# Usage:
#   ./scripts/lib/read_root_flag.sh [target-ip]
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
r = s.run_ps(r"Get-Content C:\Users\Administrator\Desktop\root.txt")
sys.stdout.write(r.std_out.decode(errors="replace"))
sys.stderr.write(r.std_err.decode(errors="replace"))
sys.exit(r.status_code)
PY
