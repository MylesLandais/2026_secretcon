#!/usr/bin/env bash
set -euo pipefail

# Replay a Wazuh dataset (produced by scripts/wazuh-export-dataset.sh)
# into a remote Wazuh manager's syslog ingestion endpoint. The remote is
# normally the SecretCon production-lab manager at 192.168.61.10 on
# Proxmox, but any Wazuh manager with a TCP <remote><connection>syslog</...>
# block works.
#
# Wire format per event (RFC 5424-ish, but Wazuh's syslog decoder is happy
# with this shape):
#
#   <134>1 <orig_ts> <hostname> wazuh-replay <run_id> [SECRETCON-REPLAY \
#       run_id=<run_id> orig_ts=<orig_ts> source=<alerts|archives>] {json}\n
#
# - Facility 16 (local0) * 8 + severity 6 (info) = 134.
# - The bracketed structured data lets the receiving analyst (or a
#   filter rule) attribute each event to a specific replay run.
# - The trailing JSON object IS the original Wazuh event (the line from
#   alerts.json / archives.json). Wazuh's json_log decoder picks it up
#   and re-decodes win.eventdata.*, so custom rules 100501-100517 fire
#   again on the receiving manager.
#
# Usage:
#   ./scripts/wazuh-replay-to-proxmox.sh \
#       --dataset artifacts/cysvuln/observability-loop/loop-.../dataset \
#       --target 192.168.61.10:514 \
#       --source archives
#
# Flags:
#   --dataset DIR        (required) dataset directory produced by export
#   --target HOST:PORT   (required) Wazuh manager syslog listener
#   --source TYPE        alerts | archives (default: archives if non-empty
#                        else alerts)
#   --proto tcp|udp      transport (default: tcp)
#   --rate EPS           max events per second (default: 200)
#   --tag TAG            structured-data tag (default: derived from dataset
#                        directory name, e.g. loop-20260525T035312Z)
#   --filter JQ          jq expression to pre-filter events (default: '.')
#   --dry-run            print first 3 wire-format lines and exit
#   --since TS / --until TS
#                        ISO-8601 timestamp range (string compare on .timestamp)
#   --limit N            send at most N events

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATASET=""
TARGET=""
SOURCE=""
PROTO="tcp"
RATE=200
TAG=""
FILTER='.'
DRY_RUN=0
SINCE=""
UNTIL=""
LIMIT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dataset) DATASET="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --proto) PROTO="$2"; shift 2 ;;
        --rate) RATE="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --since) SINCE="$2"; shift 2 ;;
        --until) UNTIL="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        -h|--help) sed -n '3,42p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$DATASET" ] || [ -z "$TARGET" ]; then
    echo "[!] --dataset and --target required" >&2
    exit 2
fi
if [ ! -d "$DATASET" ]; then
    echo "[!] dataset directory not found: $DATASET" >&2
    exit 1
fi

HOST="${TARGET%:*}"
PORT="${TARGET##*:}"
if [ -z "$HOST" ] || [ -z "$PORT" ] || [ "$HOST" = "$TARGET" ]; then
    echo "[!] --target must be HOST:PORT (got '${TARGET}')" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[!] jq required (try: nix develop)" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[!] python3 required" >&2
    exit 2
fi

# Pick source file
if [ -z "$SOURCE" ]; then
    if [ -s "${DATASET}/archives/archives.json" ]; then
        SOURCE="archives"
    else
        SOURCE="alerts"
    fi
fi
case "$SOURCE" in
    archives) SRC_FILE="${DATASET}/archives/archives.json" ;;
    alerts)   SRC_FILE="${DATASET}/alerts/alerts.json" ;;
    *) echo "[!] --source must be alerts or archives"; exit 2 ;;
esac
if [ ! -s "$SRC_FILE" ]; then
    echo "[!] source file empty or missing: ${SRC_FILE}" >&2
    exit 1
fi

# Tag defaults to the dataset's run-id (parent of dataset/)
if [ -z "$TAG" ]; then
    PARENT="$(basename "$(dirname "$(realpath "$DATASET")")")"
    TAG="${PARENT}"
fi

HOSTNAME_VAL="${HOSTNAME:-$(hostname)}"
TOTAL_LINES=$(wc -l < "$SRC_FILE" | tr -d ' ')

echo "[*] replay configuration"
echo "    dataset : ${DATASET}"
echo "    source  : ${SOURCE} (${SRC_FILE}, ${TOTAL_LINES} lines)"
echo "    target  : ${HOST}:${PORT}/${PROTO}"
echo "    rate    : ${RATE} eps"
echo "    tag     : ${TAG}"
echo "    filter  : ${FILTER}"
if [ -n "$SINCE" ] || [ -n "$UNTIL" ]; then
    echo "    window  : ${SINCE:-(-inf)} .. ${UNTIL:-(+inf)}"
fi
if [ "$LIMIT" -gt 0 ]; then
    echo "    limit   : ${LIMIT}"
fi

# Build the jq projection: pre-filter by --since/--until and --filter,
# then emit the original event JSON verbatim (compact, one per line).
# Python reads each line, parses the .timestamp for the syslog header,
# and forwards the original JSON text as the message body so the
# receiving manager's json_log decoder sees an untouched event.
JQ_PROG='select(.timestamp // null | tostring as $ts |
            ($since == "" or $ts >= $since) and
            ($until == "" or $ts <= $until))
         | '"${FILTER}"

# Pre-flight: make sure the target is reachable. We do a 3s TCP probe;
# UDP we cannot really probe so we just warn.
if [ "$PROTO" = "tcp" ]; then
    if ! timeout 3 bash -c "</dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
        echo "[!] target ${HOST}:${PORT}/tcp not reachable. Enable a"
        echo "    <remote><connection>syslog</...> block on the target"
        echo "    manager (see docs/runbooks/wazuh-dataset-export-and-replay.md)"
        if [ "$DRY_RUN" -eq 0 ]; then
            exit 1
        fi
    fi
fi

# Stream the events through python3 (which buffers a single socket and
# applies rate limiting) - far simpler than netcat acrobatics.
export REPLAY_HOST="$HOST" REPLAY_PORT="$PORT" REPLAY_PROTO="$PROTO" \
       REPLAY_RATE="$RATE" REPLAY_TAG="$TAG" REPLAY_SOURCE="$SOURCE" \
       REPLAY_HOSTNAME="$HOSTNAME_VAL" REPLAY_DRY_RUN="$DRY_RUN" \
       REPLAY_LIMIT="$LIMIT"

REPLAY_PY=$(cat <<'PY'
import os, sys, socket, time, json
host = os.environ["REPLAY_HOST"]
port = int(os.environ["REPLAY_PORT"])
proto = os.environ["REPLAY_PROTO"]
rate = max(1, int(os.environ["REPLAY_RATE"]))
tag = os.environ["REPLAY_TAG"]
src = os.environ["REPLAY_SOURCE"]
hn = os.environ["REPLAY_HOSTNAME"]
dry = os.environ["REPLAY_DRY_RUN"] == "1"
limit = int(os.environ["REPLAY_LIMIT"])

sock = None
if not dry:
    if proto == "tcp":
        sock = socket.create_connection((host, port), timeout=10)
    else:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

interval = 1.0 / rate
sent = 0
errors = 0
shown = 0
start = time.time()
last_progress = start

for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    # raw is a single compact JSON object per line, as emitted by jq -c.
    try:
        evt = json.loads(raw)
    except Exception:
        errors += 1
        continue
    orig_ts = evt.get("timestamp", "1970-01-01T00:00:00Z")

    sd = f"[SECRETCON-REPLAY run_id={tag} orig_ts={orig_ts} source={src}]"
    msg = f"<134>1 {orig_ts} {hn} wazuh-replay - {tag} {sd} {raw}\n"

    if dry and shown < 3:
        sys.stdout.write(f"--- dry-run sample {shown+1} ---\n{msg}")
        shown += 1
        if shown == 3:
            break
        continue
    if dry:
        break

    try:
        if proto == "tcp":
            sock.sendall(msg.encode("utf-8", errors="replace"))
        else:
            sock.sendto(msg.encode("utf-8", errors="replace"), (host, port))
    except Exception as exc:
        errors += 1
        sys.stderr.write(f"[!] send error after {sent}: {exc}\n")
        break

    sent += 1
    if limit > 0 and sent >= limit:
        break

    time.sleep(interval)
    now = time.time()
    if now - last_progress > 5:
        sys.stderr.write(f"    sent {sent} (errors={errors}, "
                         f"{sent/max(0.001, now-start):.1f} eps)\n")
        last_progress = now

if sock and not dry:
    try:
        sock.close()
    except Exception:
        pass

if dry:
    sys.stdout.flush()
    sys.stderr.write(f"[+] dry-run: rendered {shown} sample(s), no socket opened\n")
else:
    sys.stderr.write(f"[+] replay done: sent={sent}, errors={errors}, "
                     f"elapsed={time.time()-start:.1f}s\n")
PY
)

jq -c --arg since "$SINCE" --arg until "$UNTIL" "$JQ_PROG" "$SRC_FILE" \
    | python3 -c "$REPLAY_PY"

echo "[+] replay finished (target=${HOST}:${PORT}/${PROTO})"
