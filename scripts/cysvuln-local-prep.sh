#!/usr/bin/env bash
set -euo pipefail

# Post-boot prep for local CysVuln QEMU (user networking).
#
# Usage:
#   WINRM_PORT=15985 ./scripts/cysvuln-local-prep.sh 127.0.0.1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-127.0.0.1}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
USER_FLAG="${USER_FLAG:-cysvuln-user-flag-placeholder}"
OPTION_INI="${OPTION_INI:-${REPO_ROOT}/infrastructure/artifacts/cysvuln/option.ini}"
PSEXEC_CACHE="${PSEXEC_CACHE:-/tmp/PsExec.exe}"
PREP_SERVE_PORT="${PREP_SERVE_PORT:-8877}"

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] run inside: nix develop" >&2
    exit 2
fi

if [ ! -f "$OPTION_INI" ]; then
    echo "[!] option.ini not found: $OPTION_INI" >&2
    exit 1
fi

if [ ! -f "$PSEXEC_CACHE" ]; then
    echo "[*] Downloading PsExec to $PSEXEC_CACHE ..."
    curl -fsSL -o "$PSEXEC_CACHE" "https://live.sysinternals.com/PsExec.exe"
fi

STAGE_DIR="$(mktemp -d /tmp/cysvuln-prep.XXXXXX)"
python3 "$REPO_ROOT/scripts/validate/check_aie_response.py" \
    --command 'copy C:\Users\Administrator\Desktop\root.txt C:\Users\Public\aie-flag.txt' \
    --out "$STAGE_DIR/aie-validation-payload.msi"
cp "$OPTION_INI" "$STAGE_DIR/option.ini"
cp "$PSEXEC_CACHE" "$STAGE_DIR/PsExec.exe"
cp "${REPO_ROOT}/provisioning/cysvuln/validate-aie.ps1" "$STAGE_DIR/validate-aie.ps1"
python3 -m http.server "$PREP_SERVE_PORT" --directory "$STAGE_DIR" &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null || true; rm -rf "$STAGE_DIR"' EXIT
sleep 1

python3 "$REPO_ROOT/scripts/cysvuln_local_prep.py" \
    --target "$TARGET" \
    --port "$WINRM_PORT" \
    --admin-password "$ADMIN_PW" \
    --user-flag "$USER_FLAG" \
    --serve-port "$PREP_SERVE_PORT"

echo "[+] local prep WinRM steps complete for $TARGET"

HTTP_PORT="${CYSVULN_HTTP_PORT:-18080}"
echo "[*] Waiting for EFS HTTP on ${TARGET}:${HTTP_PORT}..."
for attempt in $(seq 1 60); do
  if curl -sf --max-time 8 -I "http://${TARGET}:${HTTP_PORT}/" | grep -qi "Easy File Sharing"; then
    echo "[+] EFS HTTP ready"
    break
  fi
  if [ "$attempt" -eq 10 ]; then
    echo "[*] EFS HTTP slow; restarting fswsService via WinRM..."
    WINRM_PORT="$WINRM_PORT" python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_PW" <<'PY' || true
import sys, winrm
host, port, pw = sys.argv[1:4]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=("Administrator", pw), transport="ntlm")
s.run_ps("Get-Process fsws,fswsService -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; sc.exe stop fswsService | Out-Null; Start-Sleep 2; sc.exe start fswsService | Out-Null; Start-Sleep 3")
PY
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "[!] EFS HTTP did not become ready" >&2
    exit 1
  fi
  sleep 2
done

echo "[*] Probing /vfolder.ghp (BOF endpoint may not return quickly) ..."
VFOLDER_CODE="$(curl -sI --max-time 3 "http://${TARGET}:${HTTP_PORT}/vfolder.ghp" | head -1 || true)"
if [ -n "$VFOLDER_CODE" ]; then
    echo "[+] /vfolder.ghp: $VFOLDER_CODE"
else
    echo "[*] /vfolder.ghp: no response within 3s (normal for USERID overflow path)"
fi
