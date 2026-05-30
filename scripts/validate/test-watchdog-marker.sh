#!/usr/bin/env bash
# Assert guest unhealthy marker exists (after induced failures).
# Usage: ./scripts/validate/test-watchdog-marker.sh <winrm-host>
set -euo pipefail
HOST="${1:-127.0.0.1}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MARKER='C:\\secretcon\\watchdog-unhealthy.marker'
ansible -i "${REPO_ROOT}/ansible/inventory" "${HOST}" -m ansible.windows.win_stat \
  -a "path=${MARKER}" "$@" | grep -q '"exists": true'
