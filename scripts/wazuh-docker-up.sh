#!/usr/bin/env bash
set -euo pipefail

# Bring up the SecretCon local-lab Wazuh single-node stack.
# Idempotent: pre-flights cert generation, brings stack up, waits for
# manager API + indexer green, creates the ews agent group, restarts the
# manager so shared/ews/agent.conf is picked up.
#
# Usage:
#   ./scripts/wazuh-docker-up.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infrastructure/wazuh-docker"
COMPOSE_PROJECT="wazuh-docker"

cd "$STACK_DIR"

if ! command -v docker >/dev/null 2>&1; then
    echo "[!] docker not on PATH" >&2
    exit 2
fi

# Pre-flight: generate indexer certs if missing.
CERT_DIR="${STACK_DIR}/config/wazuh_indexer_ssl_certs"
mkdir -p "$CERT_DIR"
if [ ! -f "${CERT_DIR}/root-ca.pem" ]; then
    echo "[*] Generating indexer SSL certs (one-shot)"
    docker compose -p "${COMPOSE_PROJECT}-certs" -f generate-indexer-certs.yml run --rm generator
    # The upstream generator names the manager CA differently from the
    # filename docker-compose.yml bind-mounts; symlink/copy so the
    # manager finds /etc/ssl/root-ca.pem at the expected path.
    if [ ! -f "${CERT_DIR}/root-ca-manager.pem" ] && [ -f "${CERT_DIR}/root-ca.pem" ]; then
        cp "${CERT_DIR}/root-ca.pem" "${CERT_DIR}/root-ca-manager.pem"
    fi
    if [ ! -f "${CERT_DIR}/root-ca-manager.key" ] && [ -f "${CERT_DIR}/root-ca.key" ]; then
        cp "${CERT_DIR}/root-ca.key" "${CERT_DIR}/root-ca-manager.key"
    fi
    echo "[+] Certs generated under ${CERT_DIR}"
fi

echo "[*] Bringing stack up (project: ${COMPOSE_PROJECT})"
docker compose -p "${COMPOSE_PROJECT}" up -d

# Wait for manager API.
API_USER="${WAZUH_API_USER:-wazuh-wui}"
API_PASS="${WAZUH_API_PASSWORD:-MyS3cr37P450r.*-}"
echo "[*] Waiting for manager API at https://127.0.0.1:55000 ..."
deadline=$(( $(date +%s) + 240 ))
token=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    token=$(curl -sk --max-time 5 -u "${API_USER}:${API_PASS}" -X POST \
        "https://127.0.0.1:55000/security/user/authenticate?raw=true" 2>/dev/null || true)
    if [ -n "$token" ] && [[ "$token" != *"error"* ]] && [[ "$token" != *"Could not"* ]]; then
        echo "[+] Manager API reachable; got auth token"
        break
    fi
    sleep 5
done
if [ -z "$token" ] || [[ "$token" == *"error"* ]]; then
    echo "[!] Manager API never came up; tailing manager logs" >&2
    docker logs --tail 50 wazuh.manager >&2 || true
    exit 1
fi

# Wait for indexer green.
echo "[*] Waiting for indexer to be reachable ..."
deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -sk --max-time 5 -u "admin:${INDEXER_PASSWORD:-SecretPassword}" \
        "https://127.0.0.1:9200/_cluster/health" 2>/dev/null | grep -q '"status"'; then
        echo "[+] Indexer reachable"
        break
    fi
    sleep 5
done

# Create ews agent group (idempotent) and ensure shared/ews/agent.conf
# lands inside the container at the path Wazuh expects.
echo "[*] Pre-creating ews agent group (idempotent)"
docker exec wazuh.manager /var/ossec/bin/agent_groups -a -g ews -q 2>/dev/null || true

for grp in chain8 chain8-dc chain8-edu10; do
    echo "[*] Pre-creating ${grp} agent group (idempotent)"
    docker exec wazuh.manager /var/ossec/bin/agent_groups -a -g "${grp}" -q 2>/dev/null || true
    if [ -f "${STACK_DIR}/config/wazuh_cluster/shared/${grp}/agent.conf" ]; then
        echo "[*] Syncing shared/${grp}/agent.conf"
        docker exec wazuh.manager mkdir -p "/var/ossec/etc/shared/${grp}"
        docker cp "${STACK_DIR}/config/wazuh_cluster/shared/${grp}/agent.conf" \
            "wazuh.manager:/var/ossec/etc/shared/${grp}/agent.conf"
        docker exec wazuh.manager chown -R wazuh:wazuh "/var/ossec/etc/shared/${grp}"
    fi
done

# The bind-mount lands the file under /wazuh-config-mount/etc/shared/ews;
# the entrypoint syncs that into /var/ossec/etc/shared at start. Force a
# resync by copying it directly to the canonical path so a re-run picks
# up edits without a full container restart.
echo "[*] Syncing shared/ews/agent.conf into the manager container"
docker exec wazuh.manager mkdir -p /var/ossec/etc/shared/ews
docker cp "${STACK_DIR}/config/wazuh_cluster/shared/ews/agent.conf" \
    wazuh.manager:/var/ossec/etc/shared/ews/agent.conf
docker exec wazuh.manager chown -R wazuh:wazuh /var/ossec/etc/shared/ews

# Same staging-path problem applies to the manager's ossec.conf and to
# the custom rule file: the bind mount lands them under
# /wazuh-config-mount, which is only consumed by the entrypoint on first
# start. Push them in directly so edits between runs always take effect
# (in particular, <logall_json>yes</logall_json> for fidelity datasets).
echo "[*] Syncing manager ossec.conf + local_rules.xml into the container"
docker cp "${STACK_DIR}/config/wazuh_cluster/wazuh_manager.conf" \
    wazuh.manager:/var/ossec/etc/ossec.conf
docker exec -u root wazuh.manager chown root:wazuh /var/ossec/etc/ossec.conf
docker exec -u root wazuh.manager chmod 0660 /var/ossec/etc/ossec.conf
docker cp "${STACK_DIR}/config/wazuh_cluster/local_rules.xml" \
    wazuh.manager:/var/ossec/etc/rules/local_rules.xml
docker exec -u root wazuh.manager chown wazuh:wazuh /var/ossec/etc/rules/local_rules.xml
docker exec -u root wazuh.manager chmod 0660 /var/ossec/etc/rules/local_rules.xml

docker exec wazuh.manager /var/ossec/bin/wazuh-control restart >/dev/null

echo "[+] Wazuh local-lab stack ready"
echo "    Dashboard: https://127.0.0.1:${WAZUH_DASHBOARD_PORT:-1443}  (admin / ${INDEXER_PASSWORD:-SecretPassword})"
echo "    API:       https://127.0.0.1:55000  (${API_USER} / ${API_PASS})"
echo "    Agent on guest dials: 10.0.2.2:1514 (events), 10.0.2.2:1515 (enrollment)"
