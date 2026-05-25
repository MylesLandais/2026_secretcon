#!/usr/bin/env python3
"""Wazuh dataset replay over syslog.

Reads RFC-5424-ish framed messages from stdin (one JSON event per line,
already filtered + windowed by the caller's `jq` pre-pass), opens one
TCP or UDP socket to the target Wazuh manager's syslog listener, and
forwards each event wrapped in:

    <134>1 <orig_ts> <hostname> wazuh-replay - <tag> \\
        [SECRETCON-REPLAY run_id=<tag> orig_ts=<orig_ts> source=<src>] <raw>\\n

- Facility 16 (local0) * 8 + severity 6 (info) = 134.
- The structured-data tag lets a receiving rule attribute every event to
  a specific replay run for analyst pivots.
- The trailing JSON IS the original Wazuh event verbatim; the receiving
  manager's json_log decoder re-decodes win.eventdata.* and refires the
  SecretCon custom rules on the replayed corpus.

Invoked from scripts/wazuh-replay-to-proxmox.sh via env vars:

    REPLAY_HOST, REPLAY_PORT, REPLAY_PROTO (tcp|udp),
    REPLAY_RATE (events per second, integer >= 1),
    REPLAY_TAG, REPLAY_SOURCE (alerts|archives),
    REPLAY_HOSTNAME (host string in the syslog header),
    REPLAY_DRY_RUN (1 to print first 3 framed samples and exit),
    REPLAY_LIMIT (cap on number of events; 0 = unlimited).
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time


def main() -> int:
    host = os.environ["REPLAY_HOST"]
    port = int(os.environ["REPLAY_PORT"])
    proto = os.environ["REPLAY_PROTO"]
    rate = max(1, int(os.environ["REPLAY_RATE"]))
    tag = os.environ["REPLAY_TAG"]
    src = os.environ["REPLAY_SOURCE"]
    hostname = os.environ["REPLAY_HOSTNAME"]
    dry = os.environ.get("REPLAY_DRY_RUN", "0") == "1"
    limit = int(os.environ.get("REPLAY_LIMIT", "0"))

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
        try:
            evt = json.loads(raw)
        except Exception:
            errors += 1
            continue
        orig_ts = evt.get("timestamp", "1970-01-01T00:00:00Z")

        sd = f"[SECRETCON-REPLAY run_id={tag} orig_ts={orig_ts} source={src}]"
        msg = f"<134>1 {orig_ts} {hostname} wazuh-replay - {tag} {sd} {raw}\n"

        if dry:
            if shown < 3:
                sys.stdout.write(f"--- dry-run sample {shown + 1} ---\n{msg}")
                shown += 1
                if shown == 3:
                    break
                continue
            break

        try:
            if proto == "tcp":
                assert sock is not None
                sock.sendall(msg.encode("utf-8", errors="replace"))
            else:
                assert sock is not None
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
            eps = sent / max(0.001, now - start)
            sys.stderr.write(
                f"    sent {sent} (errors={errors}, {eps:.1f} eps)\n"
            )
            last_progress = now

    if sock is not None and not dry:
        try:
            sock.close()
        except Exception:
            pass

    if dry:
        sys.stdout.flush()
        sys.stderr.write(
            f"[+] dry-run: rendered {shown} sample(s), no socket opened\n"
        )
    else:
        sys.stderr.write(
            f"[+] replay done: sent={sent}, errors={errors}, "
            f"elapsed={time.time() - start:.1f}s\n"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
