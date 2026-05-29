#!/usr/bin/env bash
set -euo pipefail

# Import a PCAP into the running SecretCon local-lab Arkime stack.
# Copies the file into infrastructure/arkime-docker/pcaps/ (if not
# already there), then runs arkime-capture inside the viewer container.
#
# Usage:
#   ./scripts/arkime-import-pcap.sh <pcap-path>
#   ./scripts/arkime-import-pcap.sh --tag vnc-foothold <pcap-path>
#
# Flags:
#   --tag TAG      tag the imported sessions with TAG (multiple --tag ok)
#   --force        re-import even if the file is already known to Arkime
#   --node NODE    node name to attribute the import to (default: local)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infrastructure/arkime-docker"
PCAP_DIR="${STACK_DIR}/pcaps"

TAGS=()
FORCE=0
NODE="local"

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            shift
            TAGS+=("$1")
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --node)
            shift
            NODE="$1"
            shift
            ;;
        --)
            shift
            break
            ;;
        -h|--help)
            sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "Usage: $0 [--tag TAG] [--force] [--node NODE] <pcap-path>" >&2
    exit 2
fi

PCAP_PATH="$1"
if [ ! -f "$PCAP_PATH" ]; then
    echo "[!] PCAP not found: $PCAP_PATH" >&2
    exit 2
fi

if ! docker ps --format '{{.Names}}' | grep -q '^arkime\.viewer$'; then
    echo "[!] arkime.viewer container is not running. Bring stack up first:" >&2
    echo "    ./scripts/arkime-docker-up.sh" >&2
    exit 2
fi

# Copy into pcaps/ if outside that directory.
ABS_PCAP="$(cd "$(dirname "$PCAP_PATH")" && pwd)/$(basename "$PCAP_PATH")"
if [[ "$ABS_PCAP" != "$PCAP_DIR/"* ]]; then
    echo "[*] Staging $(basename "$PCAP_PATH") into ${PCAP_DIR}"
    mkdir -p "$PCAP_DIR"
    cp -f "$PCAP_PATH" "${PCAP_DIR}/"
    PCAP_PATH="${PCAP_DIR}/$(basename "$PCAP_PATH")"
fi

NAME="$(basename "$PCAP_PATH")"
CONTAINER_PATH="/opt/arkime/raw/${NAME}"

if [ "$FORCE" -eq 0 ]; then
    : "${ARKIME_OS_PORT:=9201}"
    count=$(curl -sf --max-time 5 \
        "http://127.0.0.1:${ARKIME_OS_PORT}/arkime_files/_count?q=name:%22${CONTAINER_PATH}%22" \
        2>/dev/null | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+' || true)
    if [ -n "$count" ] && [ "$count" -gt 0 ]; then
        echo "[*] ${NAME} already imported; pass --force to re-ingest"
        echo "    Viewer: http://127.0.0.1:8005/sessions?expression=file%3D%3D%22${CONTAINER_PATH}%22"
        exit 0
    fi
fi

cap_args=(/opt/arkime/bin/capture -c /opt/arkime/etc/config.ini -r "${CONTAINER_PATH}" -n "${NODE}")
for t in "${TAGS[@]}"; do
    cap_args+=(--tag "$t")
done

echo "[*] Importing ${NAME} (node=${NODE}, tags=${TAGS[*]:-none})"
docker exec arkime.viewer "${cap_args[@]}"

echo "[+] Imported. Search in viewer:"
echo "    http://127.0.0.1:8005/sessions?expression=file%3D%3D%22${CONTAINER_PATH}%22"
