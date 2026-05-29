#!/usr/bin/env bash
set -euo pipefail

# Stop the SecretCon local-lab Arkime stack.
#
# Usage:
#   ./scripts/arkime-docker-down.sh         # docker compose down
#   ./scripts/arkime-docker-down.sh --wipe  # also delete named volumes
#                                           # (OpenSearch index + viewer state)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infrastructure/arkime-docker"
COMPOSE_PROJECT="arkime-docker"

WIPE=0
if [ "${1:-}" = "--wipe" ]; then
    WIPE=1
fi

# shellcheck source=lib/docker-stack.sh
. "${REPO_ROOT}/scripts/lib/docker-stack.sh"
if [ "$WIPE" -eq 1 ]; then
    docker_stack_down "$STACK_DIR" "$COMPOSE_PROJECT" --wipe
else
    docker_stack_down "$STACK_DIR" "$COMPOSE_PROJECT"
fi

echo "[+] Arkime local-lab stack stopped"
