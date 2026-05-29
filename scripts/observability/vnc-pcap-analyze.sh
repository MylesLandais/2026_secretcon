#!/usr/bin/env bash
# Read out an adversary-attack VNC pcap.
#
# Takes a pcap path and prints a per-srcip attempt count, success/fail
# split, time span, and the cracked password from the one successful
# RFB auth. Also writes a structured evidence pack alongside the pcap.
#
# Designed to be runnable both standalone and from the
# scripts/observability/vnc-public-attack.sh orchestrator. tshark and
# python3+cryptography (for the offline DES crack) are required; we
# fall back to `nix shell` invocations when the host PATH is bare.
#
# Usage:
#   ./scripts/observability/vnc-pcap-analyze.sh <pcap-path>
#   ./scripts/observability/vnc-pcap-analyze.sh --wordlist PATH <pcap-path>
#   ./scripts/observability/vnc-pcap-analyze.sh --out-dir DIR  <pcap-path>
#   ./scripts/observability/vnc-pcap-analyze.sh --no-crack     <pcap-path>
#
# Defaults:
#   out-dir   = <pcap-dir>/analysis
#   wordlist  = provisioning/wordlists/vnc-betterdefaultpasslist.txt
#               (falls back to common SecLists install paths)
#
# Writes to <out-dir>:
#   attempts.tsv         frame, tcp.stream, srcip, dstip, security_type
#   results.tsv          frame, tcp.stream, srcip, dstip, chal, resp, auth_result
#   per-stream.tsv       tcp.stream, srcip, dstip, chal, resp, auth_result
#   success-pair.tsv     the one stream that resolved (or empty if none)
#   recovered.txt        plaintext from vnc-cred-tool.py crack
#   summary.json         machine-readable counts + decoded password
#   README.md            human-readable readout (mirrors stdout)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PCAP=""
OUT_DIR=""
WORDLIST=""
DO_CRACK=1

while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir)  OUT_DIR="$2"; shift 2 ;;
        --wordlist) WORDLIST="$2"; shift 2 ;;
        --no-crack) DO_CRACK=0; shift ;;
        -h|--help)  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         echo "[!] unknown flag: $1" >&2; exit 2 ;;
        *)          PCAP="$1"; shift ;;
    esac
done

[ -n "${PCAP}" ]  || { echo "[!] usage: $0 [flags] <pcap-path>" >&2; exit 2; }
[ -s "${PCAP}" ]  || { echo "[!] pcap missing/empty: ${PCAP}" >&2; exit 1; }

PCAP_ABS="$(readlink -f "${PCAP}")"
[ -n "${OUT_DIR}" ] || OUT_DIR="$(dirname "${PCAP_ABS}")/analysis"
mkdir -p "${OUT_DIR}"

# Default wordlist resolution (only needed when --no-crack not set).
if [ "${DO_CRACK}" -eq 1 ] && [ -z "${WORDLIST}" ]; then
    for c in \
        "${REPO_ROOT}/provisioning/wordlists/vnc-betterdefaultpasslist.txt" \
        /usr/share/seclists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
        /usr/share/wordlists/SecLists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
        "${HOME}/SecLists/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt"; do
        if [ -f "$c" ]; then WORDLIST="$c"; break; fi
    done
fi

# tshark resolution (nix shell fallback so the script works outside the
# dev shell too).
TSHARK_BIN="$(command -v tshark 2>/dev/null || true)"
tshark_run() {
    if [ -n "${TSHARK_BIN}" ]; then
        "${TSHARK_BIN}" "$@"
    elif command -v nix >/dev/null 2>&1; then
        nix shell nixpkgs#wireshark-cli --command tshark "$@"
    else
        echo "[!] tshark not on PATH and nix not available" >&2
        return 127
    fi
}

step() { printf '\n[*] %s\n' "$*" >&2; }

step "Analyzing $(basename "${PCAP_ABS}")"
echo "    pcap   : ${PCAP_ABS}" >&2
echo "    out    : ${OUT_DIR}" >&2
[ "${DO_CRACK}" -eq 1 ] && echo "    crack  : wordlist=${WORDLIST:-(none-found)}" >&2 \
                       || echo "    crack  : skipped" >&2

# --------------------------------------------------------- 1. RAW FIELDS
RAW_TSV="${OUT_DIR}/.raw-vnc.tsv"
tshark_run -r "${PCAP_ABS}" \
    -Y 'vnc' \
    -T fields \
    -e frame.number -e frame.time_epoch -e tcp.stream \
    -e ip.src -e ip.dst \
    -e vnc.security_type -e vnc.client_security_type \
    -e vnc.auth_challenge -e vnc.auth_response -e vnc.auth_result \
    -E separator=/t \
    > "${RAW_TSV}" 2>/dev/null

if [ ! -s "${RAW_TSV}" ]; then
    echo "[!] tshark produced zero VNC frames from ${PCAP_ABS}" >&2
    echo "    is this really an RFB/VNC capture? try: tshark -r ${PCAP_ABS} -Y vnc" >&2
    exit 1
fi

# --------------------------------------------------------- 2. STRUCTURED VIEW
# Group by tcp.stream and roll up per-attempt fields. python is cleaner
# than awk for this because we need per-stream state.
python3 - "${RAW_TSV}" "${OUT_DIR}" "${PCAP_ABS}" <<'PY'
import sys, json, os
from collections import defaultdict, OrderedDict

raw_path, out_dir, pcap_path = sys.argv[1], sys.argv[2], sys.argv[3]

# Each row: frame, time_epoch, tcp_stream, ip_src, ip_dst,
#           security_type, client_security_type,
#           auth_challenge, auth_response, auth_result
COLS = ["frame", "time_epoch", "stream", "src", "dst",
        "security_type", "client_security_type",
        "challenge", "response", "auth_result"]

rows = []
with open(raw_path) as fh:
    for ln in fh:
        parts = ln.rstrip("\n").split("\t")
        # tshark pads to the requested number of -e fields, so len==10.
        while len(parts) < len(COLS):
            parts.append("")
        rows.append(dict(zip(COLS, parts)))

streams = OrderedDict()                 # stream_id -> dict
src_attempts = defaultdict(int)
attempts = []                           # rows with vnc.security_type present (server offer)
results  = []                           # rows with auth_result populated

for r in rows:
    sid = r["stream"]
    if not sid:
        # very rare; non-tcp vnc would never happen but guard anyway.
        continue
    s = streams.setdefault(sid, {
        "stream": sid, "src": "", "dst": "",
        "challenge": "", "response": "", "auth_result": "",
        "first_epoch": "", "last_epoch": "",
    })
    # The first ip pair seen on this stream is the client/server direction.
    # We want the client (attacker) side recorded as src; in RFB the
    # CHALLENGE is server->client (so ip.src=server) and the RESPONSE is
    # client->server (so ip.src=client). Use the RESPONSE row's ip.src as
    # the authoritative attacker IP.
    if not s["first_epoch"] and r["time_epoch"]:
        s["first_epoch"] = r["time_epoch"]
    if r["time_epoch"]:
        s["last_epoch"] = r["time_epoch"]
    if r["challenge"]:
        s["challenge"] = r["challenge"]
        # During the challenge frame, src is the SERVER (the box being
        # attacked). Capture as dst-from-attacker-view.
        if not s["dst"]:
            s["dst"] = r["src"]
    if r["response"]:
        s["response"] = r["response"]
        s["src"] = r["src"]   # attacker IP
        if not s["dst"]:
            s["dst"] = r["dst"]
        src_attempts[r["src"]] += 1
    if r["auth_result"]:
        # Only capture the FIRST vnc.auth_result frame in each stream as the
        # canonical server reply. Subsequent frames are tshark mis-decoding
        # the failure reason-string bytes that TightVNC sends after a
        # non-zero result; without this guard a failed stream looks like a
        # success (the trailing "False" overwrites the leading "True").
        if not s["auth_result"]:
            s["auth_result"] = r["auth_result"]

    if r["security_type"] or r["client_security_type"]:
        attempts.append(r)
    if r["auth_result"]:
        results.append(r)

# Detect tshark auth_result boolean spelling. RFB code 0 == OK == False
# in tshark display; code 1 == Failed == True.
def is_success(val):
    v = val.strip().lower()
    return v in ("0", "false")
def is_failure(val):
    v = val.strip().lower()
    return v in ("1", "true")

success_streams = [s for s in streams.values() if is_success(s["auth_result"])]
failure_streams = [s for s in streams.values() if is_failure(s["auth_result"])]
all_attempt_streams = [s for s in streams.values() if s.get("response")]
all_response_count = sum(1 for s in streams.values() if s.get("response"))
all_challenge_count = sum(1 for s in streams.values() if s.get("challenge"))

# Write attempts.tsv: every challenge issued (i.e. every stream that
# got far enough to offer/accept VNC auth).
with open(os.path.join(out_dir, "attempts.tsv"), "w") as fh:
    fh.write("frame\tstream\tsrc\tdst\tsecurity_type\n")
    for r in attempts:
        fh.write("\t".join([
            r["frame"], r["stream"], r["src"], r["dst"],
            r["security_type"] or r["client_security_type"]
        ]) + "\n")

# Write results.tsv: every frame that carried a chal/resp/result.
with open(os.path.join(out_dir, "results.tsv"), "w") as fh:
    fh.write("frame\tstream\tsrc\tdst\tchallenge\tresponse\tauth_result\n")
    for r in rows:
        if not (r["challenge"] or r["response"] or r["auth_result"]):
            continue
        fh.write("\t".join([
            r["frame"], r["stream"], r["src"], r["dst"],
            r["challenge"], r["response"], r["auth_result"]
        ]) + "\n")

# Write per-stream rollup.
with open(os.path.join(out_dir, "per-stream.tsv"), "w") as fh:
    fh.write("stream\tsrc\tdst\tchallenge\tresponse\tauth_result\toutcome\n")
    for s in streams.values():
        outcome = "SUCCESS" if is_success(s["auth_result"]) \
            else ("FAILED" if is_failure(s["auth_result"]) \
            else "INCOMPLETE")
        fh.write("\t".join([
            s["stream"], s["src"], s["dst"],
            s["challenge"], s["response"], s["auth_result"], outcome
        ]) + "\n")

# Success pair (if any).
success_pair = success_streams[0] if success_streams else None
with open(os.path.join(out_dir, "success-pair.tsv"), "w") as fh:
    if success_pair:
        fh.write("stream\tsrc\tdst\tchallenge\tresponse\n")
        fh.write("\t".join([
            success_pair["stream"], success_pair["src"], success_pair["dst"],
            success_pair["challenge"], success_pair["response"]
        ]) + "\n")

# Best-effort pair: every stream with BOTH a challenge and a response,
# even when the server FIN'd before sending an auth_result byte (this is
# what TightVNC does when BlackoutPeriod / MaxAuthFailures kicks in).
# The first such pair is enough to attempt a wordlist crack and surface
# whatever password the client tried.
best_effort_pair = None
if not success_pair:
    for s in streams.values():
        if s.get("challenge") and s.get("response"):
            best_effort_pair = s
            break

with open(os.path.join(out_dir, "best-effort-pair.tsv"), "w") as fh:
    if best_effort_pair:
        fh.write("stream\tsrc\tdst\tchallenge\tresponse\n")
        fh.write("\t".join([
            best_effort_pair["stream"], best_effort_pair["src"], best_effort_pair["dst"],
            best_effort_pair["challenge"], best_effort_pair["response"]
        ]) + "\n")

# Time span (UTC).
def fmt_epoch(e):
    if not e:
        return ""
    try:
        from datetime import datetime, timezone
        return datetime.fromtimestamp(float(e), tz=timezone.utc).isoformat()
    except Exception:
        return e

epochs = [float(s["first_epoch"]) for s in streams.values() if s.get("first_epoch")]
epochs += [float(s["last_epoch"]) for s in streams.values() if s.get("last_epoch")]
ts_start = min(epochs) if epochs else 0.0
ts_end   = max(epochs) if epochs else 0.0
span_s   = max(0.0, ts_end - ts_start)

summary = {
    "pcap": pcap_path,
    "tcp_streams_seen":          len(streams),
    "challenges_observed":       all_challenge_count,
    "responses_observed":        all_response_count,
    "rfb_attempt_count":         len(all_attempt_streams),
    "successful_auth_count":     len(success_streams),
    "failed_auth_count":         len(failure_streams),
    "incomplete_streams":        len(streams) - len(success_streams) - len(failure_streams),
    "attacker_srcip_counts":     dict(src_attempts),
    "time_start_utc":            fmt_epoch(ts_start),
    "time_end_utc":              fmt_epoch(ts_end),
    "duration_seconds":          round(span_s, 3),
    "successful_pair":           ({
        "stream":    success_pair["stream"],
        "src":       success_pair["src"],
        "dst":       success_pair["dst"],
        "challenge": success_pair["challenge"],
        "response":  success_pair["response"],
    } if success_pair else None),
    "best_effort_pair":          ({
        "stream":    best_effort_pair["stream"],
        "src":       best_effort_pair["src"],
        "dst":       best_effort_pair["dst"],
        "challenge": best_effort_pair["challenge"],
        "response":  best_effort_pair["response"],
        "note":      "server FIN'd before auth_result byte; offline-decode only",
    } if best_effort_pair else None),
}

with open(os.path.join(out_dir, "summary.json"), "w") as fh:
    json.dump(summary, fh, indent=2)
PY
rc=$?
rm -f "${RAW_TSV}"
if [ "${rc}" -ne 0 ]; then
    echo "[!] python tshark roll-up failed (rc=${rc})" >&2
    exit "${rc}"
fi

SUMMARY_JSON="${OUT_DIR}/summary.json"

# --------------------------------------------------------- 3. CRACK
RECOVERED=""
RECOVERED_TXT="${OUT_DIR}/recovered.txt"
: > "${RECOVERED_TXT}"

if [ "${DO_CRACK}" -eq 1 ]; then
    if [ ! -f "${WORDLIST}" ]; then
        echo "[!] crack requested but no wordlist found; pass --wordlist PATH or --no-crack" >&2
    else
        CHAL="$(python3 -c "import json,sys; d=json.load(open('${SUMMARY_JSON}')); p=d.get('successful_pair') or d.get('best_effort_pair'); print(p['challenge'] if p else '')")"
        RESP="$(python3 -c "import json,sys; d=json.load(open('${SUMMARY_JSON}')); p=d.get('successful_pair') or d.get('best_effort_pair'); print(p['response'] if p else '')")"
        PAIR_SOURCE="$(python3 -c "import json; d=json.load(open('${SUMMARY_JSON}')); print('success' if d.get('successful_pair') else ('best_effort' if d.get('best_effort_pair') else 'none'))")"
        if [ -z "${CHAL}" ] || [ -z "${RESP}" ]; then
            echo "[!] pcap contained no (challenge, response) pair; nothing to crack" >&2
        else
            [ "${PAIR_SOURCE}" = "best_effort" ] && \
                echo "    note: server FIN'd before auth_result byte (TightVNC blackout?); decoding response anyway" >&2
            # vnc-cred-tool.py needs python cryptography; pull from nix
            # shell if it's not already importable.
            CRED_TOOL="${REPO_ROOT}/scripts/observability/vnc-cred-tool.py"
            if python3 -c 'import cryptography' >/dev/null 2>&1; then
                RECOVERED="$(python3 "${CRED_TOOL}" crack \
                    --challenge "${CHAL}" --response "${RESP}" \
                    --wordlist "${WORDLIST}" 2>"${OUT_DIR}/crack.err")"
            elif command -v nix >/dev/null 2>&1; then
                RECOVERED="$(nix develop "${REPO_ROOT}" --command \
                    python3 "${CRED_TOOL}" crack \
                    --challenge "${CHAL}" --response "${RESP}" \
                    --wordlist "${WORDLIST}" 2>"${OUT_DIR}/crack.err" \
                    | grep -v '^\[secretcon\]' | grep -v '^warning:' | tail -n1)"
            else
                echo "[!] python 'cryptography' missing and nix unavailable; cannot crack" >&2
            fi
            if [ -n "${RECOVERED}" ]; then
                printf '%s\n' "${RECOVERED}" > "${RECOVERED_TXT}"
            else
                cat "${OUT_DIR}/crack.err" >&2 2>/dev/null || true
            fi
        fi
    fi
fi

# --------------------------------------------------------- 4. READOUT
# Render the human-facing block to README.md and to stdout.
README="${OUT_DIR}/README.md"

python3 - "${SUMMARY_JSON}" "${README}" "${RECOVERED}" <<'PY'
import json, sys
summary_path, readme_path, recovered = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(summary_path))
pair = d.get('successful_pair') or d.get('best_effort_pair') or {}
chal = pair.get('challenge') or 'CHAL_HEX'
resp = pair.get('response')  or 'RESP_HEX'

def fmt_pair(p):
    if not p:
        return "(no successful auth in pcap)"
    return (
        f"stream {p['stream']}: {p['src']} -> {p['dst']}\n"
        f"  challenge: {p['challenge']}\n"
        f"  response:  {p['response']}"
    )

srcs = d.get("attacker_srcip_counts") or {}
srcs_sorted = sorted(srcs.items(), key=lambda kv: kv[1], reverse=True)
srcs_table = "\n".join(f"  {ip:<18} {n:>4} attempts" for ip, n in srcs_sorted) \
              if srcs_sorted else "  (no client responses observed)"

success_block = fmt_pair(d.get("successful_pair"))
best_effort_block = ""
bep = d.get("best_effort_pair")
if not d.get("successful_pair") and bep:
    best_effort_block = (
        "\n## Best-effort (challenge, response) pair\n\n"
        "Server never sent a `vnc.auth_result` byte (TightVNC blackout-period\n"
        "behavior). The captured client response can still be decoded offline\n"
        "to recover the password it was trying.\n\n"
        "```\n"
        f"stream {bep['stream']}: {bep['src']} -> {bep['dst']}\n"
        f"  challenge: {bep['challenge']}\n"
        f"  response:  {bep['response']}\n"
        "```\n"
    )

md = f"""# VNC adversary attack pcap readout

| Field | Value |
| --- | --- |
| pcap | `{d['pcap']}` |
| tcp streams seen | {d['tcp_streams_seen']} |
| RFB attempts (response frames) | {d['rfb_attempt_count']} |
| successful auths | {d['successful_auth_count']} |
| failed auths | {d['failed_auth_count']} |
| incomplete streams | {d['incomplete_streams']} |
| time start (UTC) | {d['time_start_utc']} |
| time end (UTC) | {d['time_end_utc']} |
| duration (seconds) | {d['duration_seconds']} |

## Attacker source IPs

```
{srcs_table}
```

## Successful (challenge, response) pair

```
{success_block}
```
{best_effort_block}
## Recovered plaintext

```
{recovered or '(crack skipped or did not match wordlist)'}
```

## Reproducer

```bash
# Per-frame VNC dump:
tshark -r {d['pcap']} -Y vnc -V | less

# Per-stream summary (matches per-stream.tsv next to this README):
tshark -r {d['pcap']} -Y vnc \\
  -T fields -e tcp.stream -e ip.src -e ip.dst \\
            -e vnc.auth_challenge -e vnc.auth_response -e vnc.auth_result

# Reproduce the crack:
python3 scripts/observability/vnc-cred-tool.py crack \\
  --challenge {chal} \\
  --response  {resp} \\
  --wordlist  provisioning/wordlists/vnc-betterdefaultpasslist.txt
```
"""

with open(readme_path, "w") as fh:
    fh.write(md)
print(md)
PY

step "Done"
echo "    summary : ${SUMMARY_JSON}" >&2
echo "    readme  : ${README}" >&2
echo "    tsv pack: ${OUT_DIR}/{attempts,results,per-stream,success-pair}.tsv" >&2
