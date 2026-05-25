#!/usr/bin/env bash
set -euo pipefail

# Export the raw Wazuh manager state of a SIEM-capture-loop run as a
# self-contained analyst dataset. The result is a directory tree (and an
# optional .tar.zst) that can be:
#
#   * grep-ed locally for proof artefacts (flag tokens, aie-flag.txt
#     creations, msiexec children, etc.),
#   * replayed into another Wazuh manager via
#     scripts/wazuh-replay-to-proxmox.sh, or
#   * archived alongside docs/cysvulnserver/blue-team-report.md as the
#     evidence pack for a given run.
#
# What we copy out of the live wazuh.manager container:
#
#   /var/ossec/logs/alerts/alerts.json    -> alerts/alerts.json
#   /var/ossec/logs/alerts/alerts.log     -> alerts/alerts.log
#   /var/ossec/logs/archives/archives.json-> archives/archives.json   (if non-empty)
#   /var/ossec/logs/archives/archives.log -> archives/archives.log    (if non-empty)
#   /var/ossec/etc/ossec.conf             -> manager/ossec.conf
#   /var/ossec/etc/rules/local_rules.xml  -> manager/local_rules.xml
#   /var/ossec/etc/shared/<group>/agent.conf for ews -> agent/agent.conf
#   wazuh API /agents listing             -> agent/agents.json
#   wazuh API /agents/<id>/group          -> agent/agent-groups.json
#   wazuh-indexer _cat/indices            -> indexer/indices.txt
#   wazuh-indexer _cluster/health         -> indexer/health.json
#
# We also write a MANIFEST.md and a sha256sums.txt so the dataset is
# self-describing and tamper-evident.
#
# Usage:
#   ./scripts/wazuh-export-dataset.sh --run-id loop-20260525T035312Z
#   ./scripts/wazuh-export-dataset.sh --run-id loop-... --tarball
#   ./scripts/wazuh-export-dataset.sh --run-id loop-... --window-from-loop
#
# Flags:
#   --run-id ID            (required) maps to artifacts/cysvuln/observability-loop/<ID>/
#   --out-dir DIR          override output dir (default: <run-id>/dataset/)
#   --container NAME       manager container (default: wazuh.manager)
#   --indexer-container N  indexer container (default: wazuh.indexer)
#   --indexer-user U       indexer basic-auth user (default: admin)
#   --indexer-pass P       indexer basic-auth password (default: SecretPassword,
#                          override via WAZUH_INDEXER_PASS env)
#   --api-user U           manager API user (default: wazuh-wui)
#   --api-pass P           manager API password (default: MyS3cr37P450r.*-)
#   --window-from-loop     trim alerts.json/archives.json to the union of
#                          iter-*/summary.json time windows. Default: full file.
#   --tarball              additionally write <out-dir>.tar.zst (requires zstd)
#   --no-archives          skip archives/* even if present

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID=""
OUT_DIR=""
SOURCE_DIR=""
CONTAINER="${WAZUH_MANAGER_CONTAINER:-wazuh.manager}"
INDEXER_CONTAINER="${WAZUH_INDEXER_CONTAINER:-wazuh.indexer}"
INDEXER_USER="${WAZUH_INDEXER_USER:-admin}"
INDEXER_PASS="${WAZUH_INDEXER_PASS:-SecretPassword}"
API_USER="${WAZUH_API_USER:-wazuh-wui}"
API_PASS="${WAZUH_API_PASS:-MyS3cr37P450r.*-}"
WINDOW_FROM_LOOP=0
TARBALL=0
NO_ARCHIVES=0
AGENT_GROUP="${WAZUH_AGENT_GROUP:-ews}"

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --source-dir) SOURCE_DIR="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --indexer-container) INDEXER_CONTAINER="$2"; shift 2 ;;
        --indexer-user) INDEXER_USER="$2"; shift 2 ;;
        --indexer-pass) INDEXER_PASS="$2"; shift 2 ;;
        --api-user) API_USER="$2"; shift 2 ;;
        --api-pass) API_PASS="$2"; shift 2 ;;
        --window-from-loop) WINDOW_FROM_LOOP=1; shift ;;
        --tarball) TARBALL=1; shift ;;
        --no-archives) NO_ARCHIVES=1; shift ;;
        -h|--help) sed -n '3,55p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    echo "[!] --run-id required" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[!] jq required (try: nix develop)" >&2
    exit 2
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[!] container ${CONTAINER} is not running" >&2
    exit 1
fi

if [ -n "$SOURCE_DIR" ]; then
    RUN_DIR="$SOURCE_DIR"
else
    RUN_DIR="${REPO_ROOT}/artifacts/cysvuln/observability-loop/${RUN_ID}"
fi
if [ ! -d "$RUN_DIR" ]; then
    echo "[!] no such run dir: ${RUN_DIR}" >&2
    exit 1
fi
if [ -z "$OUT_DIR" ]; then
    OUT_DIR="${RUN_DIR}/dataset"
fi

mkdir -p "$OUT_DIR"/{alerts,archives,manager,agent,indexer}

echo "[*] exporting dataset for ${RUN_ID}"
echo "    manager container : ${CONTAINER}"
echo "    indexer container : ${INDEXER_CONTAINER}"
echo "    out dir           : ${OUT_DIR}"

###############################################################################
# 1) Manager raw logs (alerts + archives)
###############################################################################

copy_file() {
    local src="$1" dst="$2"
    if docker exec "$CONTAINER" test -f "$src" 2>/dev/null; then
        docker cp "${CONTAINER}:${src}" "$dst"
        return 0
    fi
    return 1
}

copy_file /var/ossec/logs/alerts/alerts.json "${OUT_DIR}/alerts/alerts.json" \
    || echo "[!] alerts.json missing in container"
copy_file /var/ossec/logs/alerts/alerts.log "${OUT_DIR}/alerts/alerts.log" \
    || echo "[!] alerts.log missing in container"

if [ "$NO_ARCHIVES" -eq 0 ]; then
    copy_file /var/ossec/logs/archives/archives.json "${OUT_DIR}/archives/archives.json" \
        || echo "[i] archives.json missing or empty (logall_json=no?)"
    copy_file /var/ossec/logs/archives/archives.log "${OUT_DIR}/archives/archives.log" \
        || echo "[i] archives.log missing or empty"
fi

###############################################################################
# 2) Optional: trim to the union of iter time windows
###############################################################################

if [ "$WINDOW_FROM_LOOP" -eq 1 ]; then
    # observability-loop has iter-N/summary.json; stress-campaign has
    # per-phase summaries under iter-N/phase-*/summary.json. Pick whichever
    # exists. Both shapes contain {start, end, ...}.
    SUMMARIES=()
    # Portable glob-existence check; nix-develop's sh may not have compgen.
    shopt -s nullglob 2>/dev/null || true
    iter_top=("${RUN_DIR}"/iter-*/summary.json)
    iter_phase=("${RUN_DIR}"/iter-*/phase-*/summary.json)
    shopt -u nullglob 2>/dev/null || true
    if [ "${#iter_top[@]}" -gt 0 ] && [ -f "${iter_top[0]}" ]; then
        SUMMARIES=("${iter_top[@]}")
    elif [ "${#iter_phase[@]}" -gt 0 ] && [ -f "${iter_phase[0]}" ]; then
        SUMMARIES=("${iter_phase[@]}")
    fi
    if [ "${#SUMMARIES[@]}" -eq 0 ]; then
        echo "[!] --window-from-loop but no summary.json files exist"
    else
        WIN_START=$(jq -s 'map(.start // empty) | min' "${SUMMARIES[@]}" | tr -d '"')
        WIN_END=$(jq -s 'map(.end // empty) | max' "${SUMMARIES[@]}" | tr -d '"')
        echo "[*] trimming alerts/archives to ${WIN_START} .. ${WIN_END}"

        for f in "${OUT_DIR}/alerts/alerts.json" "${OUT_DIR}/archives/archives.json"; do
            [ -f "$f" ] && [ -s "$f" ] || continue
            tmp="${f}.win"
            jq -c --arg since "$WIN_START" --arg until "$WIN_END" \
                'select(.timestamp >= $since and .timestamp <= $until)' \
                "$f" > "$tmp" 2>/dev/null || true
            [ -s "$tmp" ] && mv "$tmp" "$f" || rm -f "$tmp"
        done
    fi
fi

###############################################################################
# 3) Manager config (ossec.conf + custom rules)
###############################################################################

copy_file /var/ossec/etc/ossec.conf "${OUT_DIR}/manager/ossec.conf" \
    || echo "[!] ossec.conf missing"
copy_file /var/ossec/etc/rules/local_rules.xml "${OUT_DIR}/manager/local_rules.xml" \
    || echo "[!] local_rules.xml missing"

###############################################################################
# 4) Agent metadata (group, agents.json, agent.conf)
###############################################################################

# agent group shared config
copy_file "/var/ossec/etc/shared/${AGENT_GROUP}/agent.conf" \
    "${OUT_DIR}/agent/agent.conf" \
    || echo "[i] shared/${AGENT_GROUP}/agent.conf not present"

# manager API: token + agents list
TOKEN=$(curl -sk --max-time 10 -u "${API_USER}:${API_PASS}" -X POST \
    "https://127.0.0.1:55000/security/user/authenticate?raw=true" 2>/dev/null || true)
if [ -n "$TOKEN" ] && [[ "$TOKEN" != *"error"* ]]; then
    curl -sk --max-time 10 -H "Authorization: Bearer ${TOKEN}" \
        "https://127.0.0.1:55000/agents" \
        | jq '.' > "${OUT_DIR}/agent/agents.json" 2>/dev/null || true
    curl -sk --max-time 10 -H "Authorization: Bearer ${TOKEN}" \
        "https://127.0.0.1:55000/agents/groups" \
        | jq '.' > "${OUT_DIR}/agent/groups.json" 2>/dev/null || true
else
    echo "[i] manager API not reachable; skipping agents.json"
fi

###############################################################################
# 5) Indexer state (index list + health). The actual docs are already in
#    alerts.json/archives.json, so we only capture the cluster snapshot.
###############################################################################

if docker ps --format '{{.Names}}' | grep -qx "$INDEXER_CONTAINER"; then
    docker exec "$INDEXER_CONTAINER" curl -sk \
        -u "${INDEXER_USER}:${INDEXER_PASS}" \
        'https://wazuh.indexer:9200/_cat/indices?v' \
        > "${OUT_DIR}/indexer/indices.txt" 2>/dev/null || true
    docker exec "$INDEXER_CONTAINER" curl -sk \
        -u "${INDEXER_USER}:${INDEXER_PASS}" \
        'https://wazuh.indexer:9200/_cluster/health?pretty' \
        > "${OUT_DIR}/indexer/health.json" 2>/dev/null || true
else
    echo "[i] indexer container ${INDEXER_CONTAINER} not running; skipping"
fi

###############################################################################
# 6) Copy loop-side context (flags.env, summary.csv, raw-notes.md, per-iter
#    summary.json + chain.log + msiexec-timeline.json) so the dataset travels
#    with its provenance.
###############################################################################

mkdir -p "${OUT_DIR}/loop"
# Generic context (works for both observability-loop and stress-campaign).
for ctx in summary.csv raw-notes.md loop.log \
           campaign-summary.csv variance-notes.md campaign.log; do
    [ -f "${RUN_DIR}/${ctx}" ] && cp "${RUN_DIR}/${ctx}" "${OUT_DIR}/loop/"
done
# flags.env intentionally NOT copied: it contains the solution; the dataset
# is supposed to be the analyst's challenge corpus. They prove it by finding
# the token strings in alerts/archives.

for iter in "${RUN_DIR}"/iter-*; do
    [ -d "$iter" ] || continue
    name=$(basename "$iter")
    mkdir -p "${OUT_DIR}/loop/${name}"
    # observability-loop shape
    for keep in summary.json msiexec-timeline.json chain.log ossec.log.tail; do
        [ -f "${iter}/${keep}" ] && cp "${iter}/${keep}" "${OUT_DIR}/loop/${name}/"
    done
    # stress-campaign shape: red/blue scorecards + per-phase summary.json
    for keep in red-scorecard.json blue-scorecard.json iter-alerts.jsonl; do
        [ -f "${iter}/${keep}" ] && cp "${iter}/${keep}" "${OUT_DIR}/loop/${name}/"
    done
    for phase in "$iter"/phase-*; do
        [ -d "$phase" ] || continue
        pname=$(basename "$phase")
        mkdir -p "${OUT_DIR}/loop/${name}/${pname}"
        for keep in summary.json stdout.log; do
            [ -f "${phase}/${keep}" ] && cp "${phase}/${keep}" "${OUT_DIR}/loop/${name}/${pname}/"
        done
    done
done

###############################################################################
# 7) Manifest + sha256sums
###############################################################################

EXPORT_TS="$(date -u +%FT%TZ)"
ALERTS_LINES=$(wc -l < "${OUT_DIR}/alerts/alerts.json" 2>/dev/null | tr -d ' ' || echo 0)
ARCH_LINES=$(wc -l < "${OUT_DIR}/archives/archives.json" 2>/dev/null | tr -d ' ' || echo 0)

cat > "${OUT_DIR}/MANIFEST.md" <<MD
# Wazuh dataset: ${RUN_ID}

- Exported: ${EXPORT_TS}
- Source manager: container \`${CONTAINER}\` (local lab,
  \`infrastructure/wazuh-docker\`)
- Source loop: \`artifacts/cysvuln/observability-loop/${RUN_ID}/\`
- Alerts lines: ${ALERTS_LINES}
- Archives lines: ${ARCH_LINES}
- logall_json was: $(grep -E '<logall_json>' "${OUT_DIR}/manager/ossec.conf" 2>/dev/null | head -1 | tr -d ' ')

## Layout

| Path | Contents |
| --- | --- |
| \`alerts/alerts.json\` | newline-delimited JSON of every Wazuh alert at level >= log_alert_level |
| \`alerts/alerts.log\`  | human-readable mirror of the same alerts |
| \`archives/archives.json\` | every decoded event (logall_json=yes), even sub-threshold |
| \`archives/archives.log\`  | text mirror of all decoded events |
| \`manager/ossec.conf\` | full manager config in effect at export time |
| \`manager/local_rules.xml\` | SecretCon custom rules (100501-100517) |
| \`agent/agent.conf\` | shared agent.conf for group \`${AGENT_GROUP}\` |
| \`agent/agents.json\` | manager API \`/agents\` listing |
| \`agent/groups.json\` | manager API \`/agents/groups\` listing |
| \`indexer/indices.txt\` | _cat/indices snapshot at export time |
| \`indexer/health.json\` | _cluster/health snapshot |
| \`loop/summary.csv\` | per-iteration summary from the capture loop |
| \`loop/raw-notes.md\` | aggregated unique rule IDs per iteration |
| \`loop/iter-N/\` | per-iter summary.json + msiexec-timeline.json + chain.log + ossec.log.tail |

## Analyst quickstart

Find every event that references the AIE flag drop file:

\`\`\`
jq -c 'select((.data.win.eventdata.commandLine // "" | test("aie-flag")) or (.data.win.eventdata.targetFilename // "" | test("aie-flag")))' \\
    alerts/alerts.json archives/archives.json | head
\`\`\`

Pull every msiexec spawn:

\`\`\`
jq -c 'select((.data.win.eventdata.image // "" | test("(?i)msiexec\\\\.exe$")) or (.data.win.eventdata.parentImage // "" | test("(?i)msiexec\\\\.exe$")))' \\
    archives/archives.json | head -50
\`\`\`

Find any line that contains a known flag prefix (\`flag{user-\` /
\`flag{root-\`):

\`\`\`
grep -E 'flag\\{(user|root)-' alerts/alerts.log archives/archives.log || true
\`\`\`

If grep returns nothing, the flag token never crossed a process arg or a
file path Sysmon was watching - that is the realistic SIEM finding: you
*see the act of accessing the flag*, you do not *see the flag value
itself* unless it surfaces in commandLine, scriptBlockText, or a watched
file path.

## Replay

To re-ingest this dataset into another Wazuh manager (e.g. the Proxmox
production lab at 192.168.61.10), see:

\`\`\`
scripts/wazuh-replay-to-proxmox.sh --dataset $(realpath --relative-to="${REPO_ROOT}" "${OUT_DIR}") \\
    --target 192.168.61.10:514 --source alerts
\`\`\`

and the runbook \`docs/runbooks/wazuh-dataset-export-and-replay.md\`.
MD

# sha256sums for tamper-evidence
( cd "$OUT_DIR" && find . -type f -not -name 'sha256sums.txt' \
    -exec sha256sum {} \; | sort > sha256sums.txt )

echo "[+] manifest written: ${OUT_DIR}/MANIFEST.md"
echo "[+] checksums written: ${OUT_DIR}/sha256sums.txt"

###############################################################################
# 8) Optional tarball
###############################################################################

if [ "$TARBALL" -eq 1 ]; then
    if ! command -v zstd >/dev/null 2>&1; then
        echo "[!] zstd not in PATH; falling back to gzip"
        TAR_OUT="${OUT_DIR}.tar.gz"
        tar -C "$(dirname "$OUT_DIR")" -czf "$TAR_OUT" "$(basename "$OUT_DIR")"
    else
        TAR_OUT="${OUT_DIR}.tar.zst"
        tar -C "$(dirname "$OUT_DIR")" -cf - "$(basename "$OUT_DIR")" \
            | zstd -19 -T0 -o "$TAR_OUT" -f
    fi
    sha256sum "$TAR_OUT" > "${TAR_OUT}.sha256"
    echo "[+] tarball : $(du -h "$TAR_OUT" | cut -f1)  ${TAR_OUT}"
fi

echo
echo "[+] export complete: ${OUT_DIR}"
