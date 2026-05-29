#!/usr/bin/env bash
set -euo pipefail

# Bring up the SecretCon local-lab Arkime single-node stack.
# Idempotent: brings stack up, waits for OpenSearch healthy and the
# Arkime viewer to be reachable, then re-imports any PCAPs already
# staged under infrastructure/arkime-docker/pcaps/ that the indexer
# does not already know about.
#
# Usage:
#   ./scripts/arkime-docker-up.sh           # bring stack up
#   ./scripts/arkime-docker-up.sh --reimport  # force re-import of all PCAPs in pcaps/

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

STACK_DIR="${REPO_ROOT}/infrastructure/arkime-docker"
COMPOSE_PROJECT="arkime-docker"
PCAP_DIR="${STACK_DIR}/pcaps"

REIMPORT=0
if [ "${1:-}" = "--reimport" ]; then
    REIMPORT=1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "[!] docker not on PATH (try: nix develop)" >&2
    exit 2
fi

# Load .env if present so ARKIME_ADMIN_* values propagate to compose.
if [ -f "${STACK_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${STACK_DIR}/.env"
    set +a
fi
: "${ARKIME_ADMIN_USER:=admin}"
: "${ARKIME_ADMIN_PASSWORD:=SecretCon123!}"
: "${ARKIME_VIEWER_PORT:=8005}"
: "${ARKIME_OS_PORT:=9201}"

cd "$STACK_DIR"

mkdir -p "$PCAP_DIR"

echo "[*] Bringing stack up (project: ${COMPOSE_PROJECT})"
# shellcheck source=lib/docker-stack.sh
. "${REPO_ROOT}/scripts/lib/docker-stack.sh"
docker_stack_up "$STACK_DIR" "$COMPOSE_PROJECT"

echo "[*] Waiting for OpenSearch at http://127.0.0.1:${ARKIME_OS_PORT} ..."
if docker_stack_wait_http "http://127.0.0.1:${ARKIME_OS_PORT}/_cluster/health" 90 2; then
    :
else
    echo "[!] OpenSearch did not become ready" >&2
    docker logs --tail 50 arkime-opensearch 2>/dev/null || true
    exit 1
fi
echo "[+] OpenSearch reachable"

# First-run bootstrap: if the Arkime indices don't exist yet (fresh
# install / wiped volume), the viewer crashes on startup with
# "no such index [arkime_users]". Detect that case and run db.pl init
# via a one-shot helper container so the viewer can come up cleanly.
if ! curl -sf "http://127.0.0.1:${ARKIME_OS_PORT}/arkime_files" >/dev/null 2>&1; then
    echo "[*] Arkime indices not present; initialising DB schema"
    docker run --rm \
        --network "${COMPOSE_PROJECT}_default" \
        ghcr.io/arkime/arkime/arkime:v5-latest \
        /opt/arkime/db/db.pl http://arkime.opensearch:9200 init 2>&1 \
        | tail -10 || true
    # The viewer may be in a CrashLoopBackoff while indices were missing;
    # restart it so it picks up the now-initialised DB.
    docker restart arkime.viewer >/dev/null 2>&1 || true
fi

echo "[*] Waiting for Arkime viewer at http://127.0.0.1:${ARKIME_VIEWER_PORT} ..."
deadline=$(( $(date +%s) + 240 ))
viewer_up=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    # The viewer returns 401 on / until you log in -- that means it is up.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:${ARKIME_VIEWER_PORT}/eshealth.json" || true)
    if [ "$code" = "200" ] || [ "$code" = "401" ]; then
        viewer_up=1
        echo "[+] Viewer responding (HTTP ${code})"
        break
    fi
    sleep 5
done
if [ "$viewer_up" -ne 1 ]; then
    echo "[!] Arkime viewer did not come up; tailing logs" >&2
    docker logs --tail 80 arkime.viewer >&2 || true
    exit 1
fi

# Seed an admin user. docker.sh --init creates one if ARKIME_ADMIN_* are
# set, but a follow-up run can drift: ensure the user exists every time.
echo "[*] Ensuring Arkime admin user '${ARKIME_ADMIN_USER}' exists"
docker exec arkime.viewer /opt/arkime/bin/arkime_add_user.sh \
    "${ARKIME_ADMIN_USER}" "SecretCon Operator" "${ARKIME_ADMIN_PASSWORD}" \
    --admin >/dev/null 2>&1 || true

# Auto-import any PCAPs already staged in pcaps/.
shopt -s nullglob
pcap_files=("${PCAP_DIR}"/*.pcap "${PCAP_DIR}"/*.pcapng)
shopt -u nullglob

if [ "${#pcap_files[@]}" -gt 0 ]; then
    echo "[*] Found ${#pcap_files[@]} staged PCAP(s); importing"
    for f in "${pcap_files[@]}"; do
        name="$(basename "$f")"
        if [ "$REIMPORT" -eq 0 ]; then
            # Check if any session already references this file via the
            # 'files' index (Arkime stores ingested file metadata there).
            count=$(curl -sf --max-time 5 \
                "http://127.0.0.1:${ARKIME_OS_PORT}/arkime_files/_count?q=name:%22/opt/arkime/raw/${name}%22" \
                2>/dev/null | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+' || true)
            if [ -n "$count" ] && [ "$count" -gt 0 ]; then
                echo "    skip ${name} (already imported)"
                continue
            fi
        fi
        echo "    import ${name}"
        docker exec arkime.viewer /opt/arkime/bin/capture \
            -c /opt/arkime/etc/config.ini \
            -r "/opt/arkime/raw/${name}" >/dev/null
    done
else
    echo "[*] No PCAPs staged under ${PCAP_DIR}"
fi

echo "[+] Arkime local-lab stack ready"
echo "    Viewer:     http://127.0.0.1:${ARKIME_VIEWER_PORT}  (${ARKIME_ADMIN_USER} / ${ARKIME_ADMIN_PASSWORD})"
echo "    OpenSearch: http://127.0.0.1:${ARKIME_OS_PORT}"
echo "    PCAP dir:   ${PCAP_DIR}"
