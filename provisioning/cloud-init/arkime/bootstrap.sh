#!/usr/bin/env bash
# In-guest bootstrap for the SecretCon production Arkime VM (VMID 111).
#
# Run inside the VM via `ssh ... sudo bash -s` AFTER cloud-init has
# completed and after scripts/proxmox/deploy-arkime-capture.sh has
# scp'd /opt/arkime-docker/ in. The deploy script sources $ARKIME_ADMIN_PASSWORD
# from .env so the admin user is created with the same credentials the
# operator uses for the local-lab stack.
#
# Idempotent: re-running rolls over volumes only if --force was passed.
set -euo pipefail

STACK_DIR="/opt/arkime-docker"
COMPOSE="${STACK_DIR}/docker-compose.yml"
OVERRIDE="${STACK_DIR}/docker-compose.override.yml"
PROJECT="arkime-prod"

FORCE=0
ARKIME_ADMIN_USER="${ARKIME_ADMIN_USER:-admin}"
ARKIME_ADMIN_PASSWORD="${ARKIME_ADMIN_PASSWORD:-SecretCon123!}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --admin-user)     ARKIME_ADMIN_USER="$2"; shift 2 ;;
        --admin-password) ARKIME_ADMIN_PASSWORD="$2"; shift 2 ;;
        --listen)         LISTEN_HOST="$2"; shift 2 ;;
        *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
    esac
done

cd "${STACK_DIR}"

if [[ "${FORCE}" -eq 1 ]]; then
    echo "[*] --force: tearing down existing stack"
    docker compose -p "${PROJECT}" down -v || true
fi

# Production override: only override admin creds + viewer name; the
# host-bind for both viewer and opensearch is parameterised in the base
# compose file via ARKIME_BIND_HOST. We export ARKIME_BIND_HOST so the
# base file substitutes it. Compose merges `ports:` lists additively;
# rewriting the host:container binding in an override would publish the
# port TWICE and the second bind would crash with EADDRINUSE.
cat > "${OVERRIDE}" <<YAML
services:
  arkime.viewer:
    environment:
      - ARKIME_ADMIN_USER=${ARKIME_ADMIN_USER}
      - ARKIME_ADMIN_PASSWORD=${ARKIME_ADMIN_PASSWORD}
      - ARKIME__viewerName=secretcon-prod
YAML

mkdir -p "${STACK_DIR}/pcaps"

echo "[*] Bringing Arkime stack up (project=${PROJECT}, bind=${LISTEN_HOST})"
ARKIME_BIND_HOST="${LISTEN_HOST}" docker compose -p "${PROJECT}" up -d

echo "[*] Waiting for OpenSearch healthy"
DEADLINE=$(( $(date +%s) + 180 ))
while ! curl -sf --max-time 5 "http://127.0.0.1:9201/_cluster/health" 2>/dev/null \
        | grep -qE '"status":"(green|yellow)"'; do
    if (( $(date +%s) > DEADLINE )); then
        echo "[!] OpenSearch did not come up in time" >&2
        exit 1
    fi
    sleep 5
done
echo "    OpenSearch reachable."

# First-run DB init -- viewer can't start cleanly until arkime_files
# index exists. Mirrors the trick we added to scripts/arkime-docker-up.sh.
if ! curl -sf "http://127.0.0.1:9201/arkime_files" >/dev/null 2>&1; then
    echo "[*] Initialising Arkime DB schema (first run)"
    docker run --rm \
        --network "${PROJECT}_default" \
        ghcr.io/arkime/arkime/arkime:v5-latest \
        /opt/arkime/db/db.pl http://arkime.opensearch:9200 init 2>&1 | tail -10
    echo "[*] Restarting viewer post-init"
    docker restart arkime.viewer >/dev/null 2>&1 || true
fi

echo "[*] Waiting for viewer"
DEADLINE=$(( $(date +%s) + 240 ))
while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:8005/eshealth.json" 2>/dev/null || true)
    if [[ "${code}" == "200" || "${code}" == "401" ]]; then
        echo "    viewer responding (HTTP ${code})"
        break
    fi
    if (( $(date +%s) > DEADLINE )); then
        echo "[!] viewer did not come up; recent logs:" >&2
        docker logs --tail 60 arkime.viewer >&2 || true
        exit 1
    fi
    sleep 5
done

echo "[*] Ensuring admin user '${ARKIME_ADMIN_USER}' exists"
docker exec arkime.viewer /opt/arkime/bin/arkime_add_user.sh \
    "${ARKIME_ADMIN_USER}" "SecretCon Operator" "${ARKIME_ADMIN_PASSWORD}" \
    --admin >/dev/null 2>&1 || true

echo "[+] Arkime production stack ready"
echo "    Viewer:     http://$(hostname -I | awk '{print $1}'):8005  (${ARKIME_ADMIN_USER} / ${ARKIME_ADMIN_PASSWORD})"
echo "    OpenSearch: http://$(hostname -I | awk '{print $1}'):9201"
echo "    PCAP corpus: ${STACK_DIR}/pcaps"
