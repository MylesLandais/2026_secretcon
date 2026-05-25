#!/usr/bin/env bash
set -euo pipefail

# Block until a Windows WinRM endpoint can execute `whoami` over NTLM.
#
# Used by the stress-campaign orchestrator after a `qemu-img snapshot -a`
# revert + VM boot. Even with a healthy snapshot the WSMan listener can
# take 30-90s post-boot to bind, and the agent's connection to the manager
# takes another 10-20s after that. This helper waits on both.
#
# Usage:
#   ./scripts/lib/wait_for_winrm.sh [HOST] [TIMEOUT_SEC]
#
# Env:
#   WINRM_PORT     default 15985
#   ADMIN_USER     default Administrator
#   ADMIN_PW       default PizzaMan123!
#   WAIT_AGENT        1 to also poll Wazuh manager for agent=active (default 1)
#   WAIT_AGENT_STRICT 1 to exit non-zero when the agent never reaches active
#                     (default 0; baseline-snapshot.sh sets this so it
#                     refuses to snapshot a silent baseline)
#   WAZUH_AGENT_ID    id to poll (default 001)
#   WAZUH_AGENT_IP    optional ip filter (preferred when set; defaults to
#                     agent-id query for backward compatibility)

TARGET="${1:-127.0.0.1}"
TIMEOUT_SEC="${2:-240}"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_USER="${ADMIN_USER:-Administrator}"
ADMIN_PW="${ADMIN_PW:-PizzaMan123!}"
WAIT_AGENT="${WAIT_AGENT:-1}"
WAIT_AGENT_STRICT="${WAIT_AGENT_STRICT:-0}"
WAZUH_AGENT_ID="${WAZUH_AGENT_ID:-001}"
WAZUH_AGENT_IP="${WAZUH_AGENT_IP:-}"

deadline=$(( $(date +%s) + TIMEOUT_SEC ))

echo "[*] Waiting for WinRM on ${TARGET}:${WINRM_PORT} (timeout ${TIMEOUT_SEC}s)..."
while [ "$(date +%s)" -lt "$deadline" ]; do
  if python3 - "$TARGET" "$WINRM_PORT" "$ADMIN_USER" "$ADMIN_PW" >/dev/null 2>&1 <<'PY'
import sys, winrm
host, port, user, pw = sys.argv[1:5]
s = winrm.Session(f"http://{host}:{port}/wsman", auth=(user, pw), transport="ntlm")
r = s.run_ps("whoami")
sys.exit(0 if r.status_code == 0 else 1)
PY
  then
    echo "[+] WinRM ready"
    break
  fi
  sleep 4
done
if [ "$(date +%s)" -ge "$deadline" ]; then
  echo "[!] WinRM never came up at ${TARGET}:${WINRM_PORT}" >&2
  exit 1
fi

if [ "$WAIT_AGENT" = "1" ]; then
  api_user="${WAZUH_API_USER:-wazuh-wui}"
  api_pass="${WAZUH_API_PASSWORD:-MyS3cr37P450r.*-}"
  if [ -n "$WAZUH_AGENT_IP" ]; then
    label="ip=${WAZUH_AGENT_IP}"
    query="ip=${WAZUH_AGENT_IP}"
  else
    label="id=${WAZUH_AGENT_ID}"
    query="agents_list=${WAZUH_AGENT_ID}"
  fi
  echo "[*] Waiting for Wazuh agent ${label}=active..."
  agent_deadline=$(( $(date +%s) + 120 ))
  status=""
  token="$(curl -sk --max-time 5 -u "${api_user}:${api_pass}" -X POST \
    "https://127.0.0.1:55000/security/user/authenticate?raw=true" 2>/dev/null || true)"
  if [ -z "$token" ] || [[ "$token" == *"error"* ]]; then
    echo "[*] Wazuh API auth failed; skipping agent gate" >&2
  else
    while [ "$(date +%s)" -lt "$agent_deadline" ]; do
      status=$(curl -sk --max-time 5 -H "Authorization: Bearer $token" \
        "https://127.0.0.1:55000/agents?${query}" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); a=d.get("data",{}).get("affected_items",[]); print(a[0].get("status","") if a else "")' 2>/dev/null \
        || true)
      if [ "$status" = "active" ]; then
        echo "[+] agent ${label} active"
        break
      fi
      sleep 3
    done
    if [ "$status" != "active" ]; then
      echo "[!] agent did not reach active state (last: ${status:-unknown})" >&2
      if [ "$WAIT_AGENT_STRICT" = "1" ]; then
        exit 1
      fi
    fi
  fi
fi
