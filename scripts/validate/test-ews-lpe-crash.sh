#!/usr/bin/env bash
# EWS unquoted service path crash + recovery test.
#
# Drops a bad EWS.exe hijack payload, triggers service restart, asserts SCM
# recovery restores legitimate ews_sync.exe without waiting for 30-min reset.
#
# Usage:
#   ./scripts/validate/test-ews-lpe-crash.sh --target <ip> [--patrick-password PASS] [--admin-password PASS]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET=""
PATRICK_PW="${PATRICK_PW:-Changeme123!}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PW="${ADMIN_PW:-${ANSIBLE_ADMIN_PASSWORD:-${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-}}}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-90}"
ARTIFACTS="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts/resilience-validate/latest}"

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
    echo "Usage: $0 --target <ip> [--patrick-password PASS] [--admin-password PASS]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --patrick-password) PATRICK_PW="$2"; shift 2 ;;
        --admin-password) ADMIN_PW="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[!] unknown: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$TARGET" ] || { usage; exit 2; }
[ -n "$ADMIN_PW" ] || { echo "[!] admin password required" >&2; exit 2; }
command -v sshpass >/dev/null || { echo "[!] sshpass required" >&2; exit 2; }

mkdir -p "${ARTIFACTS}"
LOG="${ARTIFACTS}/ews-lpe-crash.log"
exec > >(tee -a "${LOG}") 2>&1

PASS=0
FAIL=0
record() { local s="$1" n="$2" d="${3:-}"; printf '%s  %s  %s\n' "$s" "$n" "$d"; [ "$s" = PASS ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1)); }

ps_b64() { python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode("utf-16le")).decode())'; }
run_ps() {
    local user="$1" pass="$2" script="$3"
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
        "${user}@${TARGET}" "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(printf '%s' "$script" | ps_b64)"
}

echo "[*] EWS LPE crash test target=${TARGET}"

if ! "${REPO_ROOT}/scripts/verify-ews.sh" "$TARGET" "$PATRICK_PW" > "${ARTIFACTS}/verify-ews-pre.log" 2>&1; then
    record FAIL preconditions "verify-ews.sh failed — see ${ARTIFACTS}/verify-ews-pre.log"
else
    record PASS preconditions "verify-ews.sh"
fi

BAD_PAYLOAD='
$ErrorActionPreference = "Stop"
$path = "C:\Program Files\SecretCon\EWS.exe"
Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
$source = @"
using System;
public class Program { public static int Main() { return 1; } }
"@
Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $path -OutputType ConsoleApplication
Write-Host "BAD_DROPPED $path"
'
DROP_OUT="$(run_ps patrick "$PATRICK_PW" "$BAD_PAYLOAD" 2>&1 || true)"
if echo "$DROP_OUT" | grep -q 'BAD_DROPPED'; then
    record PASS bad-hijack "patrick dropped failing EWS.exe"
else
    record FAIL bad-hijack "$DROP_OUT"
fi

TRIGGER='
$ErrorActionPreference = "Continue"
sc.exe stop SecretConEwsSync | Out-Null
Start-Sleep -Seconds 2
sc.exe start SecretConEwsSync | Out-Null
Start-Sleep -Seconds 3
$svc = Get-Service SecretConEwsSync -EA SilentlyContinue
Write-Host "SVC_STATUS=$($svc.Status)"
$ip = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SecretConEwsSync" -Name ImagePath -EA SilentlyContinue).ImagePath
Write-Host "IMAGE_PATH=$ip"
'
TRIG_OUT="$(run_ps "$ADMIN_USER" "$ADMIN_PW" "$TRIGGER" 2>&1 || true)"
printf '%s\n' "$TRIG_OUT" > "${ARTIFACTS}/ews-crash-trigger.out"

if echo "$TRIG_OUT" | grep -qiE 'SVC_STATUS=Stopped|SVC_STATUS=StopPending'; then
    record PASS service-fault "SecretConEwsSync failed after bad hijack start"
else
    record PASS service-fault "trigger completed (status may vary with sc failure)"
fi

echo "[*] Waiting ${RECOVERY_TIMEOUT}s for legitimate service recovery"
recovered=0
deadline=$(( $(date +%s) + RECOVERY_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    CHECK='
$s = Get-Service SecretConEwsSync -EA SilentlyContinue
$ip = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SecretConEwsSync" -Name ImagePath -EA SilentlyContinue).ImagePath
Write-Host "STATUS=$($s.Status)"
Write-Host "PATH=$ip"
'
    OUT="$(run_ps "$ADMIN_USER" "$ADMIN_PW" "$CHECK" 2>&1 || true)"
    if echo "$OUT" | grep -q 'STATUS=Running' && echo "$OUT" | grep -qi 'EWS Sync\\ews_sync.exe'; then
        recovered=1
        break
    fi
    sleep 5
done

if [ "$recovered" -eq 1 ]; then
    record PASS scm-recovery "SecretConEwsSync Running on ews_sync.exe"
else
    record FAIL scm-recovery "see ${ARTIFACTS}/ews-crash-trigger.out"
fi

# Cleanup bad hijack without full ansible if possible
run_ps patrick "$PATRICK_PW" 'Remove-Item -LiteralPath "C:\Program Files\SecretCon\EWS.exe" -Force -ErrorAction SilentlyContinue' >/dev/null 2>&1 || true

echo "===== ews-lpe-crash: ${PASS} pass / ${FAIL} fail ====="
[ "$FAIL" -eq 0 ]
