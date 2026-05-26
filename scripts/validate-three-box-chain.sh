#!/usr/bin/env bash
set -uo pipefail

# End-to-end three-box campaign validation (CysVuln -> EWS -> ASREP DC).
#
# Usage:
#   ./scripts/validate-three-box-chain.sh [--siem]
#
# Environment (defaults for Proxmox vmbr1 campaign):
#   CHAIN_CYSVULN_IP   192.168.61.51
#   CHAIN_EWS_IP       192.168.61.20
#   CHAIN_DC_IP        192.168.61.52
#   SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/chain_env.sh
source "${REPO_ROOT}/scripts/lib/chain_env.sh"

SIEM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --siem) SIEM=1; shift ;;
    -h|--help) sed -n '3,18p' "$0"; exit 0 ;;
    *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
  esac
done

OUT_DIR="${CHAIN_VALIDATION_DIR:-artifacts/campaign/validation}"
mkdir -p "$OUT_DIR"
LOG="${OUT_DIR}/validate-three-box-chain.log"
exec > >(tee -a "$LOG") 2>&1

echo "[*] three-box chain validation"
echo "[*] CysVuln=${CHAIN_CYSVULN_IP} EWS=${CHAIN_EWS_IP} DC=${CHAIN_DC_IP}"
echo "[*] log: $LOG"

PASS=0
FAIL=0
ok() { echo "[+] PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "[!] FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
step() { echo; echo "===== $1 ====="; }

step "per-box smoke (chain mode)"
if "${REPO_ROOT}/scripts/verify-cysvuln.sh" --chain "$CHAIN_CYSVULN_IP" "$SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD"; then
  ok "verify-cysvuln --chain"
else
  bad "verify-cysvuln --chain"
fi

if "${REPO_ROOT}/scripts/verify-ews.sh" --chain "$CHAIN_EWS_IP"; then
  ok "verify-ews --chain"
else
  bad "verify-ews --chain"
fi

if ASREP_DC_IP="$CHAIN_DC_IP" \
   SECRETCON_ASREP_PASSWORD="${SECRETCON_ASREP_PASSWORD:-stud87}" \
   "${REPO_ROOT}/scripts/verify-asrep.sh" "$CHAIN_DC_IP" "${AD_SAFEMODE_PASSWORD:-PizzaMan123!}"; then
  ok "verify-asrep"
else
  bad "verify-asrep"
fi

step "shared local Administrator (WinRM on both workgroup boxes)"
if python3 -c "import winrm" 2>/dev/null; then
  for ip in "$CHAIN_CYSVULN_IP" "$CHAIN_EWS_IP"; do
    if python3 - "$ip" "$SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD" <<'PY'
import sys, winrm
host, pw = sys.argv[1:3]
s = winrm.Session(f"http://{host}:5985/wsman", auth=("Administrator", pw), transport="ntlm")
r = s.run_ps("hostname")
sys.exit(0 if r.status_code == 0 else 1)
PY
    then
      ok "shared-admin-winrm@${ip}"
    else
      bad "shared-admin-winrm@${ip}"
    fi
  done
else
  echo "[~] SKIP shared-admin WinRM (pywinrm missing)"
fi

step "AS-REP roast against DC"
if ASREP_DC_IP="$CHAIN_DC_IP" nix develop .#kali -c "${REPO_ROOT}/scripts/validate-asrep.sh" "$CHAIN_DC_IP"; then
  ok "validate-asrep"
else
  bad "validate-asrep"
fi

step "optional PtH probe (nxc smb)"
if command -v nxc >/dev/null 2>&1 || nix develop .#kali -c command -v nxc >/dev/null 2>&1; then
  NXC=(nxc)
  if ! command -v nxc >/dev/null 2>&1; then
    NXC=(nix develop .#kali -c nxc)
  fi
  if "${NXC[@]}" smb "$CHAIN_EWS_IP" -u Administrator -p "$SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD" --local-auth 2>&1 | tee "${OUT_DIR}/pth-nxc.log" | grep -qiE 'Pwn3d|\(+\)'; then
    ok "pth-nxc-ews-local-admin"
  elif "${NXC[@]}" smb "$CHAIN_EWS_IP" -u Administrator -p "$SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD" --local-auth 2>&1 | grep -qi 'STATUS_LOGON_FAILURE'; then
    bad "pth-nxc-ews-local-admin (logon failure — rebuild EWS with shared admin password)"
  else
    echo "[~] nxc output inconclusive; see ${OUT_DIR}/pth-nxc.log"
  fi
else
  echo "[~] SKIP nxc PtH probe"
fi

if [ "$SIEM" -eq 1 ]; then
  step "SIEM drain (rules 100510 100710 100711 100700 100715)"
  START_TS="$(date -u -d '2 hours ago' +%FT%TZ 2>/dev/null || date -u +%FT%TZ)"
  END_TS="$(date -u +%FT%TZ)"
  SIEM_DIR="${OUT_DIR}/siem"
  mkdir -p "$SIEM_DIR"
  if "${REPO_ROOT}/scripts/wazuh-drain-alerts.sh" \
      --since "$START_TS" --until "$END_TS" --out-dir "$SIEM_DIR"; then
    for rid in 100510 100710 100711 100700 100715; do
      if jq -r '.rule.id // empty' "${SIEM_DIR}/alerts.json" 2>/dev/null | grep -qx "$rid"; then
        ok "wazuh-rule-${rid}"
      else
        bad "wazuh-rule-${rid} not in drain window (run after live chain execution)"
      fi
    done
  else
    bad "wazuh-drain-alerts"
  fi
fi

echo
echo "===== validate-three-box-chain ====="
echo "  $PASS pass / $FAIL fail"
echo "  finished: $(date -Is)"
echo "===================================="
[ "$FAIL" -eq 0 ]
