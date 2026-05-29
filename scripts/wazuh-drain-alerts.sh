#!/usr/bin/env bash
set -euo pipefail

# Drain Wazuh manager alerts.json (and optionally archives.json) into
# timestamp-windowed JSON-lines suitable for offline analyst review. Also
# emits a curated msiexec-timeline.json - the single file a downstream
# LLM-driven analyst agent should read first.
#
# Usage:
#   ./scripts/wazuh-drain-alerts.sh \
#       --since "2026-05-25T03:00:00Z" \
#       --until "2026-05-25T03:10:00Z" \
#       --out-dir artifacts/cysvuln/observability-loop/<run-id>/iter-1
#
# All flags:
#   --since TS         ISO-8601 lower bound (required)
#   --until TS         ISO-8601 upper bound (required)
#   --out-dir DIR      where to write iter-N/{alerts,archives,msiexec-timeline}.json
#   --include-archives also dump raw archives.json (default: alerts only)
#   --container NAME   manager container name (default: $WAZUH_MANAGER_CONTAINER)
#   --manager-ssh URL  read manager logs via `ssh URL sudo cat`. Format:
#                      user@host or user@host:port. Supports ProxyJump via
#                      MANAGER_SSH_PROXY env (passed as -o ProxyCommand=).
#                      When set, --container is ignored.
#   --manager-ssh-key KEYPATH  identity file for --manager-ssh (default:
#                      provisioning/ssh/packer_ed25519)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/wazuh-common.sh
. "${REPO_ROOT}/scripts/lib/wazuh-common.sh"
wazuh_load_env "$REPO_ROOT"

SINCE=""
UNTIL=""
OUT_DIR=""
INCLUDE_ARCHIVES=0
CONTAINER="${WAZUH_MANAGER_CONTAINER}"
MANAGER_SSH=""
MANAGER_SSH_KEY="${REPO_ROOT}/provisioning/ssh/packer_ed25519"

while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        --until) UNTIL="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --include-archives) INCLUDE_ARCHIVES=1; shift ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --manager-ssh) MANAGER_SSH="$2"; shift 2 ;;
        --manager-ssh-key) MANAGER_SSH_KEY="$2"; shift 2 ;;
        -h|--help) sed -n '3,24p' "$0"; exit 0 ;;
        *) echo "[!] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$SINCE" ] || [ -z "$UNTIL" ] || [ -z "$OUT_DIR" ]; then
    echo "[!] --since, --until, --out-dir are all required" >&2
    exit 2
fi

wazuh_require_cmd jq || exit 2

mkdir -p "$OUT_DIR"

ALERTS_OUT="${OUT_DIR}/alerts.json"
ARCHIVES_OUT="${OUT_DIR}/archives.json"
TIMELINE_OUT="${OUT_DIR}/msiexec-timeline.json"
WIN_FILTER="$(wazuh_window_jq)"

# Per-source `cat` -- docker exec by default, ssh sudo cat when --manager-ssh
# is provided. The ssh form supports a ProxyCommand via MANAGER_SSH_PROXY,
# matching the ProxyJump pattern used by scripts/proxmox/* for the Wazuh
# manager that lives behind the Proxmox host.
manager_cat() {
    local remote_path="$1"
    if [ -n "$MANAGER_SSH" ]; then
        local ssh_user_host="${MANAGER_SSH%%:*}"
        local ssh_port="22"
        case "$MANAGER_SSH" in *:*) ssh_port="${MANAGER_SSH##*:}";; esac
        local ssh_opts=(
            -o ConnectTimeout=15
            -o StrictHostKeyChecking=accept-new
            -o IdentitiesOnly=yes
            -i "$MANAGER_SSH_KEY"
            -p "$ssh_port"
        )
        if [ -n "${MANAGER_SSH_PROXY:-}" ]; then
            ssh_opts+=(-o "ProxyCommand=${MANAGER_SSH_PROXY}")
        fi
        ssh "${ssh_opts[@]}" "$ssh_user_host" "sudo cat ${remote_path}" 2>/dev/null
    else
        docker exec "${CONTAINER}" cat "${remote_path}" 2>/dev/null
    fi
}

if [ -n "$MANAGER_SSH" ]; then
    echo "[*] Draining alerts from ssh:${MANAGER_SSH} between ${SINCE} and ${UNTIL}"
else
    echo "[*] Draining alerts from ${CONTAINER} between ${SINCE} and ${UNTIL}"
fi

# alerts.json (rule hits). Each line is one JSON event with a .timestamp
# field. String compare on ISO-8601 timestamps is sufficient.
manager_cat /var/ossec/logs/alerts/alerts.json \
    | jq -c --arg since "$SINCE" --arg until "$UNTIL" "$WIN_FILTER" \
    > "$ALERTS_OUT" || true

ALERT_COUNT=$(wc -l < "$ALERTS_OUT" | tr -d ' ')
echo "[+] Wrote ${ALERT_COUNT} alerts -> ${ALERTS_OUT}"

if [ "$INCLUDE_ARCHIVES" -eq 1 ]; then
    manager_cat /var/ossec/logs/archives/archives.json \
        | jq -c --arg since "$SINCE" --arg until "$UNTIL" "$WIN_FILTER" \
        > "$ARCHIVES_OUT" || true
    ARCHIVE_COUNT=$(wc -l < "$ARCHIVES_OUT" | tr -d ' ')
    echo "[+] Wrote ${ARCHIVE_COUNT} archive events -> ${ARCHIVES_OUT}"
fi

# Curated msiexec timeline: the analyst-agent priority artifact.
# Per the plan: any alert where data.win.eventdata.image or .parentImage
# (case-insensitive) matches msiexec.exe, plus any alert decoded from
# the aie-*.log syslog stream (rule 100517) or the MSI/Operational
# channel (rule 100516) or MsiInstaller (rule 100515). Sorted by
# data.win.eventdata.utcTime when present, else .timestamp.
jq -c '
    select(
        (
            (.data.win.eventdata.image // "" | test("(?i)msiexec\\.exe$"))
            or (.data.win.eventdata.parentImage // "" | test("(?i)msiexec\\.exe$"))
            or (.data.win.system.channel // "" | test("(?i)Microsoft-Windows-MSI/Operational"))
            or (.data.win.system.providerName // "" | test("^MsiInstaller$"))
            or (.rule.id // "" | tostring | test("^10051[0-7]$"))
        )
    )
    | {
        ts: (.data.win.eventdata.utcTime // .timestamp),
        rule_id: (.rule.id // null),
        rule_description: (.rule.description // null),
        level: (.rule.level // null),
        image: (.data.win.eventdata.image // null),
        parentImage: (.data.win.eventdata.parentImage // null),
        commandLine: (.data.win.eventdata.commandLine // null),
        user: (.data.win.eventdata.user // null),
        integrityLevel: (.data.win.eventdata.integrityLevel // null),
        eventID: (.data.win.system.eventID // null),
        providerName: (.data.win.system.providerName // null),
        channel: (.data.win.system.channel // null),
        full_log: (.full_log // null)
    }
' "$ALERTS_OUT" 2>/dev/null \
    | jq -s 'sort_by(.ts)' \
    > "$TIMELINE_OUT" || echo "[]" > "$TIMELINE_OUT"

TIMELINE_COUNT=$(jq 'length' "$TIMELINE_OUT" 2>/dev/null || echo 0)
echo "[+] Wrote ${TIMELINE_COUNT} msiexec-correlated rows -> ${TIMELINE_OUT}"

echo "[+] Drain complete: ${OUT_DIR}"
