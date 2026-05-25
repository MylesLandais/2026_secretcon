#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/winrm-fetch.sh <target> <ps-command>
# Thin wrapper over pywinrm for quick WinRM-as-Admin command execution.

TARGET="${1:-}"
CMD="${2:-}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"

if [ -z "$TARGET" ] || [ -z "$CMD" ]; then
    echo "usage: $0 <target-ip> <ps-command>" >&2
    exit 2
fi

python3 - "$TARGET" "$ADMIN_PW" "$CMD" <<'PY'
import sys, winrm
host, pw, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
s = winrm.Session(f'http://{host}:5985/wsman', auth=('Administrator', pw), transport='ntlm')
r = s.run_ps(cmd)
sys.stdout.write(r.std_out.decode(errors='replace'))
sys.stderr.write(r.std_err.decode(errors='replace'))
sys.exit(r.status_code)
PY
