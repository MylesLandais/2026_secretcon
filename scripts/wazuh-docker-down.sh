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

cd "$STACK_DIR"

if [ "$WIPE" -eq 1 ]; then
    echo "[*] Stopping stack and removing volumes (--wipe)"
    docker compose -p "${COMPOSE_PROJECT}" down -v --remove-orphans
else
    echo "[*] Stopping stack (volumes preserved)"
    docker compose -p "${COMPOSE_PROJECT}" down --remove-orphans
fi

echo "[+] Wazuh local-lab stack stopped"
