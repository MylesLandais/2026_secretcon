#!/usr/bin/env bash
set -uo pipefail

# Post-build smoke for the ASREP demo DC (qemu / proxmox).
# Probes domain promotion, enite AS-REP config, flag, decoys, optional Wazuh agent.
#
# Usage:
#   ./scripts/verify-asrep.sh <target-ip> [admin-password]
#
# Environment:
#   ASREP_WINRM_PORT          WinRM port (default 5985; use 15986 for run-local-asrep.sh)
#   SECRETCON_ASREP_USER      default enite
#   SECRETCON_ASREP_FLAG      expected flag content
#   ASREP_AGENT_IP            IP for Wazuh agent lookup (default target-ip)

TARGET="${1:-}"
ADMIN_PW="${2:-${AD_SAFEMODE_PASSWORD:-PizzaMan123!}}"
WINRM_PORT="${ASREP_WINRM_PORT:-5985}"
DOMAIN="${ASREP_DOMAIN:-secretcon.local}"
ASREP_USER="${SECRETCON_ASREP_USER:-enite}"
ASREP_PASS="${SECRETCON_ASREP_PASSWORD:-stud87}"
ASREP_FLAG="${SECRETCON_ASREP_FLAG:-asrep-flag-placeholder}"
DC_USER_FLAG="${SECRETCON_DC_USER_FLAG:-$ASREP_FLAG}"
DC_ROOT_FLAG="${SECRETCON_DC_ROOT_FLAG:-asrep-root-flag-placeholder}"
ENITE_DA="${SECRETCON_ASREP_ENITE_DA:-1}"
AGENT_IP="${ASREP_AGENT_IP:-$TARGET}"

if [ -z "$TARGET" ]; then
    echo "usage: $0 <target-ip> [admin-password]"
    exit 2
fi

if ! python3 -c "import winrm" 2>/dev/null; then
    echo "[!] python3 pywinrm required — run: nix develop" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/check-harness.sh
source "${SCRIPT_DIR}/lib/check-harness.sh"
check_init

winrm_admin() {
    python3 - "$TARGET" "$ADMIN_PW" "$WINRM_PORT" "$1" <<'PY'
import sys, winrm
host, pw, port, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = winrm.Session(f'http://{host}:{port}/wsman', auth=('Administrator', pw), transport='ntlm')
r = s.run_ps(cmd)
sys.stdout.write(r.std_out.decode(errors='replace'))
sys.stderr.write(r.std_err.decode(errors='replace'))
sys.exit(r.status_code)
PY
}

winrm_user() {
    python3 - "$TARGET" "$ASREP_PASS" "$WINRM_PORT" "$DOMAIN" "$ASREP_USER" "$1" <<'PY'
import sys, winrm
host, pw, port, domain, user, cmd = sys.argv[1:7]
s = winrm.Session(f'http://{host}:{port}/wsman', auth=(f'{domain}\\{user}', pw), transport='ntlm')
r = s.run_ps(cmd)
sys.stdout.write(r.std_out.decode(errors='replace'))
sys.stderr.write(r.std_err.decode(errors='replace'))
sys.exit(r.status_code)
PY
}

echo "[*] Target: $TARGET  (Administrator)  WinRM:$WINRM_PORT  domain:$DOMAIN"

if ! nc -z -w 3 "$TARGET" "$WINRM_PORT" 2>/dev/null; then
    check "winrm-port-open" FAIL "tcp/$WINRM_PORT not open"
    echo "FAIL — aborting; WinRM not reachable"
    exit 1
fi
check "winrm-port-open" PASS "tcp/$WINRM_PORT"

DNS_ROOT=$(winrm_admin "(Get-ADDomain -Identity '$DOMAIN' -EA Stop).DNSRoot" | tr -d '\r\n ')
[ "$DNS_ROOT" = "$DOMAIN" ] && check "ad-domain" PASS "$DNS_ROOT" || check "ad-domain" FAIL "got '$DNS_ROOT'"

PREAUTH=$(winrm_admin "(Get-ADUser -Identity '$ASREP_USER' -Properties DoesNotRequirePreAuth).DoesNotRequirePreAuth" | tr -d '\r\n ')
[ "$PREAUTH" = "True" ] && check "enite-preauth-disabled" PASS "DoesNotRequirePreAuth=true" || check "enite-preauth-disabled" FAIL "got '$PREAUTH'"

KERB_ENC=$(winrm_admin "(Get-ADUser -Identity '$ASREP_USER' -Properties KerberosEncryptionType).KerberosEncryptionType" | tr -d '\r\n ')
echo "$KERB_ENC" | grep -qi 'RC4' && check "enite-rc4" PASS "$KERB_ENC" || check "enite-rc4" FAIL "got '$KERB_ENC'"

FLAG=$(winrm_admin "if (Test-Path 'C:\\Users\\Public\\user.txt') { (Get-Content 'C:\\Users\\Public\\user.txt' -Raw).Trim() } elseif (Test-Path 'C:\\Users\\Public\\enite-flag.txt') { (Get-Content 'C:\\Users\\Public\\enite-flag.txt' -Raw).Trim() } else { 'MISSING' }" | tr -d '\r\n')
if [[ "$FLAG" != "MISSING" && -n "$FLAG" ]]; then
    if [ "$FLAG" = "$DC_USER_FLAG" ] || { [ "$DC_USER_FLAG" = "$ASREP_FLAG" ] && [ "$FLAG" = "$ASREP_FLAG" ]; }; then
        check "dc-user-flag" PASS "$FLAG"
    else
        check "dc-user-flag" FAIL "expected '$DC_USER_FLAG' got '$FLAG'"
    fi
else
    check "dc-user-flag" FAIL "missing user.txt"
fi

ROOT=$(winrm_admin "if (Test-Path 'C:\\Users\\Administrator\\Desktop\\root.txt') { (Get-Content 'C:\\Users\\Administrator\\Desktop\\root.txt' -Raw).Trim() } else { 'MISSING' }" | tr -d '\r\n')
if [[ "$ROOT" != "MISSING" && -n "$ROOT" ]]; then
    if [ "$ROOT" = "$DC_ROOT_FLAG" ] || [ "$DC_ROOT_FLAG" = "asrep-root-flag-placeholder" ]; then
        check "dc-root-flag" PASS "$ROOT"
    else
        check "dc-root-flag" FAIL "expected '$DC_ROOT_FLAG' got '$ROOT'"
    fi
else
    check "dc-root-flag" FAIL "missing root.txt"
fi

if [ "$ENITE_DA" != "0" ]; then
    IS_DA=$(winrm_admin "(Get-ADPrincipalGroupMembership -Identity '$ASREP_USER' | Where-Object { \$_.Name -eq 'Domain Admins' }).Name" | tr -d '\r\n')
    [ "$IS_DA" = "Domain Admins" ] && check "enite-domain-admin" PASS "" || check "enite-domain-admin" FAIL "not in Domain Admins"
fi

if winrm_user "try { Get-Content 'C:\\Users\\Public\\user.txt' -ErrorAction Stop | Out-Null; 'READ_OK' } catch { 'DENIED' }" 2>/dev/null | grep -q READ_OK; then
    check "enite-reads-user-flag" PASS ""
else
    check "enite-reads-user-flag" FAIL "cannot read user.txt as $ASREP_USER"
fi

ROOT_AS_ENITE=$(winrm_user "try { Get-Content 'C:\\Users\\Administrator\\Desktop\\root.txt' -ErrorAction Stop; 'READ' } catch { 'DENIED' }" 2>/dev/null | tr -d '\r\n')
if echo "$ROOT_AS_ENITE" | grep -qi DENIED; then
    check "enite-blocked-from-root" PASS "access denied as expected"
elif [ "$ENITE_DA" != "0" ] && echo "$ROOT_AS_ENITE" | grep -q "$DC_ROOT_FLAG"; then
    check "enite-blocked-from-root" PASS "enite is DA and can read root (campaign mode)"
else
    check "enite-blocked-from-root" FAIL "unexpected: $ROOT_AS_ENITE"
fi

# Legacy alias check
LEGACY=$(winrm_admin "if (Test-Path 'C:\\Users\\Public\\enite-flag.txt') { 'yes' } else { 'no' }" | tr -d '\r\n')
[ "$LEGACY" = "yes" ] && check "enite-flag-alias" PASS "" || check "enite-flag-alias" FAIL "missing enite-flag.txt alias"

for decoy in jdoe asmith bwilson clee dpark; do
    present=$(winrm_admin "(Get-ADUser -Identity '$decoy' -EA SilentlyContinue).SamAccountName" | tr -d '\r\n ')
    [ "$present" = "$decoy" ] && check "decoy-$decoy" PASS "" || check "decoy-$decoy" FAIL "missing"
    dpre=$(winrm_admin "(Get-ADUser -Identity '$decoy' -Properties DoesNotRequirePreAuth -EA SilentlyContinue).DoesNotRequirePreAuth" | tr -d '\r\n ')
    [ "$dpre" = "False" ] && check "decoy-${decoy}-no-preauth" PASS "" || check "decoy-${decoy}-no-preauth" FAIL "preauth=$dpre"
done

# shellcheck source=lib/check-wazuh-agent.sh
. "${SCRIPT_DIR}/lib/check-wazuh-agent.sh"
check_wazuh_agent "$AGENT_IP"

check_summary "verify-asrep results"
