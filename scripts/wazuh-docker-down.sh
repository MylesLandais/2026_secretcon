#!/usr/bin/env bash
set -euo pipefail

# Stop the SecretCon local-lab Wazuh single-node stack.
#
# Usage:
#   ./scripts/wazuh-docker-down.sh           # stop containers, keep volumes
#   ./scripts/wazuh-docker-down.sh --wipe    # also drop named volumes
#                                            # (loses all alerts + index data)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infrastructure/wazuh-docker"
COMPOSE_PROJECT="wazuh-docker"

WIPE=0
for arg in "$@"; do
    case "$arg" in
        --wipe) WIPE=1 ;;
        -h|--help)
            sed -n '3,9p' "$0"
            exit 0
            ;;
    esac
done

# shellcheck source=lib/docker-stack.sh
. "${REPO_ROOT}/scripts/lib/docker-stack.sh"
if [ "$WIPE" -eq 1 ]; then
    docker_stack_down "$STACK_DIR" "$COMPOSE_PROJECT" --wipe
else
    docker_stack_down "$STACK_DIR" "$COMPOSE_PROJECT"
fi

echo "[+] Wazuh local-lab stack stopped"
