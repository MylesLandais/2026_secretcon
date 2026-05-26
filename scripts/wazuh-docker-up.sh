#!/usr/bin/env bash
set -euo pipefail

# Bring up the SecretCon local-lab Wazuh single-node stack.
# Idempotent: pre-flights cert generation, brings stack up, waits for
# manager API + indexer green, creates the ews agent group, restarts the
# manager so shared/ews/agent.conf and shared/asrep/agent.conf are picked up.
#
# Usage:
#   ./scripts/wazuh-docker-up.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/wazuh-common.sh
. "${REPO_ROOT}/scripts/lib/wazuh-common.sh"
# shellcheck source=lib/wazuh-api.sh
. "${REPO_ROOT}/scripts/lib/wazuh-api.sh"
wazuh_load_env "$REPO_ROOT"
wazuh_require_cmd docker || exit 2

STACK_DIR="${REPO_ROOT}/infrastructure/wazuh-docker"
COMPOSE_PROJECT="wazuh-docker"

cd "$STACK_DIR"

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

echo "[*] Waiting for manager API at https://${WAZUH_API_HOST}:${WAZUH_API_PORT} ..."
if ! token=$(wazuh_api_wait_token 240); then
    echo "[!] Manager API never came up; tailing manager logs" >&2
    docker logs --tail 50 "${WAZUH_MANAGER_CONTAINER}" >&2 || true
    exit 1
fi
echo "[+] Manager API reachable; got auth token"

echo "[*] Waiting for indexer to be reachable ..."
deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -sk --max-time 5 -u "${WAZUH_INDEXER_USER}:${WAZUH_INDEXER_PASSWORD}" \
        "https://${WAZUH_INDEXER_HOST}:${WAZUH_INDEXER_PORT}/_cluster/health" 2>/dev/null | grep -q '"status"'; then
        echo "[+] Indexer reachable"
        break
    fi
    sleep 5
done

# Create the ews agent group (idempotent) and ensure shared/ews/agent.conf
# lands inside the container at the path Wazuh expects.
echo "[*] Pre-creating ews agent group (idempotent)"
docker exec "${WAZUH_MANAGER_CONTAINER}" /var/ossec/bin/agent_groups -a -g ews -q 2>/dev/null || true

# The bind-mount lands the file under /wazuh-config-mount/etc/shared/ews;
# the entrypoint syncs that into /var/ossec/etc/shared at start. Force a
# resync by copying it directly to the canonical path so a re-run picks
# up edits without a full container restart.
echo "[*] Syncing shared/ews/agent.conf into the manager container"
docker exec "${WAZUH_MANAGER_CONTAINER}" mkdir -p /var/ossec/etc/shared/ews
docker cp "${STACK_DIR}/config/wazuh_cluster/shared/ews/agent.conf" \
    "${WAZUH_MANAGER_CONTAINER}:/var/ossec/etc/shared/ews/agent.conf"
docker exec "${WAZUH_MANAGER_CONTAINER}" chown -R wazuh:wazuh /var/ossec/etc/shared/ews

echo "[*] Pre-creating asrep agent group (idempotent)"
docker exec "${WAZUH_MANAGER_CONTAINER}" /var/ossec/bin/agent_groups -a -g asrep -q 2>/dev/null || true

echo "[*] Syncing shared/asrep/agent.conf into the manager container"
docker exec "${WAZUH_MANAGER_CONTAINER}" mkdir -p /var/ossec/etc/shared/asrep
docker cp "${STACK_DIR}/config/wazuh_cluster/shared/asrep/agent.conf" \
    "${WAZUH_MANAGER_CONTAINER}:/var/ossec/etc/shared/asrep/agent.conf"
docker exec "${WAZUH_MANAGER_CONTAINER}" chown -R wazuh:wazuh /var/ossec/etc/shared/asrep

# Same staging-path problem applies to the manager's ossec.conf and to
# the custom rule file: the bind mount lands them under
# /wazuh-config-mount, which is only consumed by the entrypoint on first
# start. Push them in directly so edits between runs always take effect
# (in particular, <logall_json>yes</logall_json> for fidelity datasets).
echo "[*] Syncing manager ossec.conf + local_rules.xml into the container"
docker cp "${STACK_DIR}/config/wazuh_cluster/wazuh_manager.conf" \
    "${WAZUH_MANAGER_CONTAINER}:/var/ossec/etc/ossec.conf"
docker exec -u root "${WAZUH_MANAGER_CONTAINER}" chown root:wazuh /var/ossec/etc/ossec.conf
docker exec -u root "${WAZUH_MANAGER_CONTAINER}" chmod 0660 /var/ossec/etc/ossec.conf
docker cp "${STACK_DIR}/config/wazuh_cluster/local_rules.xml" \
    "${WAZUH_MANAGER_CONTAINER}:/var/ossec/etc/rules/local_rules.xml"
docker exec -u root "${WAZUH_MANAGER_CONTAINER}" chown wazuh:wazuh /var/ossec/etc/rules/local_rules.xml
docker exec -u root "${WAZUH_MANAGER_CONTAINER}" chmod 0660 /var/ossec/etc/rules/local_rules.xml

docker exec "${WAZUH_MANAGER_CONTAINER}" /var/ossec/bin/wazuh-control restart >/dev/null

echo "[+] Wazuh local-lab stack ready"
echo "    Dashboard: https://127.0.0.1:${WAZUH_DASHBOARD_PORT}  (admin / ${WAZUH_INDEXER_PASSWORD})"
echo "    API:       https://${WAZUH_API_HOST}:${WAZUH_API_PORT}  (${WAZUH_API_USER} / ${WAZUH_API_PASSWORD})"
echo "    Agent on guest dials: 10.0.3.2:1514 (events), 10.0.3.2:1515 (enrollment) for ASREP QEMU user-net"
echo "    (CysVuln local QEMU still uses 10.0.2.2 on 10.0.2.0/24)"
