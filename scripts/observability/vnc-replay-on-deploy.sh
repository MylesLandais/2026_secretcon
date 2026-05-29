#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper around scripts/wazuh-replay-to-proxmox.sh that replays the
# EWS VNC adversary-emulation dataset captured by
# scripts/observability/vnc-adversary-emulation.sh into a target Wazuh
# manager. Run this post-deploy so participants find the brute-force +
# registry-exfil trail already in the SIEM when the challenge stands up.
#
# Auto-selects the most recent dataset under
# artifacts/ews/vnc-foothold/<run-id>/dataset/ unless --dataset is given.
#
# Usage:
#   ./scripts/observability/vnc-replay-on-deploy.sh
#   ./scripts/observability/vnc-replay-on-deploy.sh --target 192.168.61.10:514
#   ./scripts/observability/vnc-replay-on-deploy.sh \
#       --dataset artifacts/ews/vnc-foothold/<run-id>/dataset --rate 50
#
# Flags (passed through to wazuh-replay-to-proxmox.sh, defaults below):
#   --dataset DIR      dataset to replay (default: latest under artifacts/ews/vnc-foothold/)
#   --target HOST:PORT default 192.168.61.10:514 (production Wazuh manager)
#   --proto tcp|udp    default tcp
#   --source TYPE      alerts | archives (default: auto)
#   --rate EPS         default 50 (low because the EWS dataset is small)
#   --tag TAG          default: derived from dataset run-id

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/artifacts/ews/vnc-foothold"

DATASET=""
TARGET="192.168.61.10:514"
PROTO="tcp"
SOURCE=""
RATE="50"
TAG=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --dataset) DATASET="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --proto) PROTO="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --rate) RATE="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        -h|--help) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

if [ -z "$DATASET" ]; then
    if [ ! -d "$ARTIFACT_ROOT" ]; then
        echo "[!] no datasets under ${ARTIFACT_ROOT}" >&2
        echo "    run: ./scripts/observability/vnc-adversary-emulation.sh first" >&2
        exit 2
    fi
    # Pick the most-recent run with a dataset/ subdir.
    LATEST="$(find "$ARTIFACT_ROOT" -mindepth 2 -maxdepth 2 -type d -name dataset \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | awk '{print $2}')"
    if [ -z "$LATEST" ] || [ ! -d "$LATEST" ]; then
        echo "[!] no dataset/ subdir under ${ARTIFACT_ROOT}/<run-id>/" >&2
        exit 2
    fi
    DATASET="$LATEST"
    echo "[*] auto-selected dataset: ${DATASET}"
fi

if [ -z "$TAG" ]; then
    RUN_ID="$(basename "$(dirname "$(realpath "$DATASET")")")"
    TAG="ews-vnc:${RUN_ID}"
fi

cmd=(
    "${REPO_ROOT}/scripts/wazuh-replay-to-proxmox.sh"
    --dataset "$DATASET"
    --target  "$TARGET"
    --proto   "$PROTO"
    --rate    "$RATE"
    --tag     "$TAG"
)
if [ -n "$SOURCE" ]; then
    cmd+=(--source "$SOURCE")
fi
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
    cmd+=("${EXTRA_ARGS[@]}")
fi

echo "[*] replay command:"
echo "    ${cmd[*]}"
exec "${cmd[@]}"
