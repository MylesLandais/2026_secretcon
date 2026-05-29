#!/usr/bin/env python3
"""SecretCon EWS VNC credential tool.

Self-contained reference implementation of the TightVNC / RealVNC
password algorithm. Used by the EWS proof scripts to produce
byte-accurate artefacts (stored-blob hashes, RFB auth handshakes) from
the planted FELDTECH_VNC credential without requiring a live EWS image.

Algorithm summary
-----------------
The VNC password scheme uses single DES with two quirks:

  1. The RFB-auth DES key is derived from the password by NUL-padding (or
     truncating) to 8 ASCII bytes and then BIT-REVERSING each byte.
     This is RealVNC's historical workaround for what was, at the
     time, an export-controlled cipher.

  2. The "stored password" in HKLM\\SOFTWARE\\TightVNC\\Server\\Password
     is DES_ECB_encrypt(FIXED_KEY, padded_password) where FIXED_KEY is
     the bit-reversed form of RealVNC's fixed bytes
     {23, 82, 107, 6, 35, 78, 88, 7}. Recovery is a dictionary attack
     on candidate passwords.

  3. The RFB-3.x VNC authentication response is the same DES key
     applied to the server's 16-byte challenge:
       response = DES_ECB(key, challenge[0:8]) ||
                  DES_ECB(key, challenge[8:16]).
     Recovery from a captured (challenge, response) pair is the
     same dictionary attack against the key.

Subcommands
-----------
  encode --password PWD
      Encode plaintext to the 8-byte stored blob. Prints
      AA-BB-CC-DD-EE-FF-GG-HH (TightVNC's canonical hex display).

  decode --hex BLOB --wordlist PATH
      Dictionary attack against a stored blob. Re-encodes each
      candidate; for in-list passwords this completes in microseconds.

  crack --challenge HEX --response HEX --wordlist PATH
      Dictionary attack against a captured RFB auth handshake.

  synth-pcap --password PWD --challenge HEX --output PATH
      Emit a real RFB-3.8 auth handshake PCAP. Server is 192.0.2.20:5900,
      client is 192.0.2.10:53234. Includes the TCP three-way handshake,
      protocol version exchange, security-type negotiation, the
      16-byte challenge, the FELDTECH_VNC-derived response, and the
      SecurityResult OK record.

  synth-wazuh-event --password PWD [--hostname H] [--location PATH] --output PATH
      Emit a JSON-line event compatible with the wazuh_replay
      json_log decoder. The full_log field carries the planted
      "VNC password blob (hex): ..." line that rule 100806
      matches on.

Run with no args for usage. Round-trip self-test runs with --self-test.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, modes

try:
    from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES as _TripleDES
except ImportError:
    from cryptography.hazmat.primitives.ciphers.algorithms import TripleDES as _TripleDES

# Canonical RealVNC / TightVNC fixed key material (vncauth.c).
VNC_FIXED_KEY_BYTES = bytes([23, 82, 107, 6, 35, 78, 88, 7])


def _bit_reverse_byte(b: int) -> int:
    """Reverse the bits of a single byte. RealVNC's historical quirk."""
    b = ((b & 0x55) << 1) | ((b >> 1) & 0x55)
    b = ((b & 0x33) << 2) | ((b >> 2) & 0x33)
    b = ((b & 0x0F) << 4) | ((b >> 4) & 0x0F)
    return b & 0xFF


def _key_from_password(password: str) -> bytes:
    """Derive the 8-byte DES key from a plaintext password."""
    pw = password.encode("latin-1", errors="replace")[:8]
    padded = pw.ljust(8, b"\x00")
    return bytes(_bit_reverse_byte(b) for b in padded)


def _stored_password_plaintext(password: str) -> bytes:
    """Return the 8-byte plaintext encrypted into the stored registry blob."""
    return password.encode("latin-1", errors="replace")[:8].ljust(8, b"\x00")


def _des_encrypt(key: bytes, plaintext: bytes) -> bytes:
    """ECB DES encryption of a single 8-byte block.

    cryptography.hazmat exposes only TripleDES today. Passing an 8-byte
    key makes 3DES degenerate to single DES (K1=K2=K3), which is the
    canonical workaround.
    """
    if len(key) != 8:
        raise ValueError("DES key must be 8 bytes")
    if len(plaintext) % 8 != 0:
        raise ValueError("Plaintext length must be multiple of 8 bytes")
    cipher = Cipher(_TripleDES(key), modes.ECB())
    encryptor = cipher.encryptor()
    return encryptor.update(plaintext) + encryptor.finalize()


def encode_stored_blob(password: str) -> bytes:
    """Compute the 8-byte TightVNC stored-password blob for `password`."""
    fixed_key = bytes(_bit_reverse_byte(b) for b in VNC_FIXED_KEY_BYTES)
    return _des_encrypt(fixed_key, _stored_password_plaintext(password))


def compute_vnc_response(password: str, challenge: bytes) -> bytes:
    """Compute the 16-byte RFB-auth response to a 16-byte challenge."""
    if len(challenge) != 16:
        raise ValueError("Challenge must be 16 bytes")
    key = _key_from_password(password)
    return _des_encrypt(key, challenge[0:8]) + _des_encrypt(key, challenge[8:16])


def _hex_dashed(b: bytes) -> str:
    return "-".join(f"{x:02X}" for x in b)


def _hex_to_bytes(s: str) -> bytes:
    s = s.strip().replace("-", "").replace(":", "").replace(" ", "")
    return bytes.fromhex(s)


def _load_wordlist(path: Path) -> list[str]:
    out: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.rstrip("\r\n")
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


# ---------------------------------------------------------------- subcommands


def cmd_encode(args: argparse.Namespace) -> int:
    blob = encode_stored_blob(args.password)
    print(_hex_dashed(blob))
    return 0


def cmd_decode(args: argparse.Namespace) -> int:
    target = _hex_to_bytes(args.hex)
    if len(target) != 8:
        print(f"[!] expected 8-byte hex blob, got {len(target)} bytes", file=sys.stderr)
        return 2
    wordlist = _load_wordlist(Path(args.wordlist))
    for candidate in wordlist:
        if encode_stored_blob(candidate) == target:
            print(candidate)
            return 0
    print(f"[!] no wordlist entry matched blob {_hex_dashed(target)}", file=sys.stderr)
    return 1


def cmd_crack(args: argparse.Namespace) -> int:
    challenge = _hex_to_bytes(args.challenge)
    response = _hex_to_bytes(args.response)
    if len(challenge) != 16:
        print(f"[!] expected 16-byte challenge, got {len(challenge)} bytes", file=sys.stderr)
        return 2
    if len(response) != 16:
        print(f"[!] expected 16-byte response, got {len(response)} bytes", file=sys.stderr)
        return 2
    wordlist = _load_wordlist(Path(args.wordlist))
    for candidate in wordlist:
        if compute_vnc_response(candidate, challenge) == response:
            print(candidate)
            return 0
    print("[!] no wordlist entry matched the captured response", file=sys.stderr)
    return 1


def cmd_synth_pcap(args: argparse.Namespace) -> int:
    challenge = _hex_to_bytes(args.challenge)
    if len(challenge) != 16:
        print(f"[!] expected 16-byte challenge, got {len(challenge)} bytes", file=sys.stderr)
        return 2
    response = compute_vnc_response(args.password, challenge)

    # scapy is heavy; only import when synthesising.
    from scapy.all import Ether, IP, TCP, Raw, wrpcap  # type: ignore

    server_ip = "192.0.2.20"
    client_ip = "192.0.2.10"
    server_port = 5900
    client_port = 53234

    # Sequence numbers tracked manually so the dissector reassembles
    # the stream and engages the RFB heuristic.
    client_seq = 1_000_000
    server_seq = 2_000_000
    ts = 1_700_000_000

    pkts = []

    def push(pkt, t_offset_us: int = 0):
        nonlocal ts
        ts_sec = ts
        ts_usec = t_offset_us
        pkt.time = ts_sec + ts_usec / 1_000_000.0
        pkts.append(pkt)
        ts += 1

    # TCP three-way handshake.
    syn = Ether() / IP(src=client_ip, dst=server_ip) / TCP(
        sport=client_port, dport=server_port, flags="S", seq=client_seq
    )
    push(syn)
    client_seq += 1
    synack = Ether() / IP(src=server_ip, dst=client_ip) / TCP(
        sport=server_port, dport=client_port, flags="SA",
        seq=server_seq, ack=client_seq,
    )
    push(synack)
    server_seq += 1
    ack = Ether() / IP(src=client_ip, dst=server_ip) / TCP(
        sport=client_port, dport=server_port, flags="A",
        seq=client_seq, ack=server_seq,
    )
    push(ack)

    def srv(payload: bytes) -> None:
        nonlocal server_seq
        pkt = Ether() / IP(src=server_ip, dst=client_ip) / TCP(
            sport=server_port, dport=client_port, flags="PA",
            seq=server_seq, ack=client_seq,
        ) / Raw(load=payload)
        push(pkt)
        server_seq += len(payload)

    def cli(payload: bytes) -> None:
        nonlocal client_seq
        pkt = Ether() / IP(src=client_ip, dst=server_ip) / TCP(
            sport=client_port, dport=server_port, flags="PA",
            seq=client_seq, ack=server_seq,
        ) / Raw(load=payload)
        push(pkt)
        client_seq += len(payload)

    # RFB-3.8 protocol version exchange (12 bytes each).
    srv(b"RFB 003.008\n")
    cli(b"RFB 003.008\n")
    # Server: security-types list, 1 entry = type 2 (VNC auth).
    srv(bytes([1, 2]))
    # Client: picks security type 2.
    cli(bytes([2]))
    # Server: 16-byte challenge.
    srv(challenge)
    # Client: 16-byte response.
    cli(response)
    # Server: SecurityResult OK (4-byte big-endian zero).
    srv(bytes([0, 0, 0, 0]))

    # FIN handshake.
    fin_c = Ether() / IP(src=client_ip, dst=server_ip) / TCP(
        sport=client_port, dport=server_port, flags="FA",
        seq=client_seq, ack=server_seq,
    )
    push(fin_c)
    client_seq += 1
    fin_s = Ether() / IP(src=server_ip, dst=client_ip) / TCP(
        sport=server_port, dport=client_port, flags="FA",
        seq=server_seq, ack=client_seq,
    )
    push(fin_s)
    server_seq += 1

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    wrpcap(str(out), pkts)
    print(f"wrote {out} ({len(pkts)} packets)")
    print(f"challenge: {_hex_dashed(challenge)}")
    print(f"response:  {_hex_dashed(response)}")
    return 0


def cmd_synth_wazuh_event(args: argparse.Namespace) -> int:
    blob = encode_stored_blob(args.password)
    hex_blob = _hex_dashed(blob)
    if args.timestamp:
        ts_iso = args.timestamp
    else:
        ts_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000+0000")

    full_log = (
        f"[{ts_iso}] VNC password blob (hex): {hex_blob} "
        f"(source=HKLM:\\SOFTWARE\\ORL\\WinVNC3, host={args.hostname}, user=patrick)"
    )

    event = {
        "timestamp": ts_iso,
        "agent": {
            "id": args.agent_id,
            "name": args.hostname,
            "ip": args.agent_ip,
        },
        "manager": {"name": "wazuh.manager"},
        "id": f"{int(time.time())}.1",
        "full_log": full_log,
        "decoder": {},
        "location": args.location,
    }

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(event) + "\n", encoding="utf-8")

    # Also emit a syslog-format line (what a real Windows agent would
    # ship to the manager when tailing the file). Some downstream
    # consumers prefer this shape over the alerts.json shape.
    syslog_line = (
        f"<134>1 {ts_iso} {args.hostname} wazuh-agent - - - {full_log}"
    )
    Path(str(out) + ".syslog").write_text(syslog_line + "\n", encoding="utf-8")

    print(f"wrote {out}")
    print(f"hex blob: {hex_blob}")
    print(f"full_log: {full_log}")
    return 0


def cmd_self_test(args: argparse.Namespace) -> int:
    """Validate the implementation against a known round-trip."""
    pw = args.password
    blob = encode_stored_blob(pw)
    print(f"[self-test] password: {pw}")
    print(f"[self-test] blob:     {_hex_dashed(blob)}")

    challenge = bytes.fromhex("0123456789abcdef0123456789abcdef")
    response = compute_vnc_response(pw, challenge)
    print(f"[self-test] challenge: {_hex_dashed(challenge)}")
    print(f"[self-test] response:  {_hex_dashed(response)}")

    # Round trip blob via dictionary attack with a synthetic single-entry list.
    fake_wordlist = Path(args.tmp_wordlist or "/tmp/vnc-self-test-wordlist.txt")
    fake_wordlist.write_text(f"{pw}\nanother_password\n", encoding="utf-8")
    ns = argparse.Namespace(hex=_hex_dashed(blob), wordlist=str(fake_wordlist))
    rc1 = cmd_decode(ns)
    ns2 = argparse.Namespace(
        challenge=_hex_dashed(challenge),
        response=_hex_dashed(response),
        wordlist=str(fake_wordlist),
    )
    rc2 = cmd_crack(ns2)
    return 0 if (rc1 == 0 and rc2 == 0) else 1


# ---------------------------------------------------------------- main


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="vnc-cred-tool",
        description="TightVNC / RealVNC credential math for the SecretCon EWS proofs",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_encode = sub.add_parser("encode", help="encode plaintext -> stored blob hex")
    p_encode.add_argument("--password", required=True)
    p_encode.set_defaults(func=cmd_encode)

    p_decode = sub.add_parser("decode", help="dictionary attack against a stored blob")
    p_decode.add_argument("--hex", required=True, help="8-byte hex blob (dashes/colons/spaces OK)")
    p_decode.add_argument("--wordlist", required=True)
    p_decode.set_defaults(func=cmd_decode)

    p_crack = sub.add_parser("crack", help="dictionary attack against RFB challenge/response")
    p_crack.add_argument("--challenge", required=True, help="16-byte hex (dashes OK)")
    p_crack.add_argument("--response", required=True, help="16-byte hex (dashes OK)")
    p_crack.add_argument("--wordlist", required=True)
    p_crack.set_defaults(func=cmd_crack)

    p_pcap = sub.add_parser("synth-pcap", help="emit an RFB auth handshake PCAP")
    p_pcap.add_argument("--password", required=True)
    p_pcap.add_argument("--challenge", required=True, help="16-byte hex (default: 0123...cdef)")
    p_pcap.add_argument("--output", required=True)
    p_pcap.set_defaults(func=cmd_synth_pcap)

    p_event = sub.add_parser("synth-wazuh-event", help="emit a JSON event matching rule 100806")
    p_event.add_argument("--password", required=True)
    p_event.add_argument("--hostname", default="ews01-replay")
    p_event.add_argument("--agent-id", default="099")
    p_event.add_argument("--agent-ip", default="192.168.61.20")
    p_event.add_argument(
        "--location",
        default="C:\\Users\\Public\\vnc-pwd-dump.txt",
        help="Windows path that rule 100806 <location> matches against",
    )
    p_event.add_argument("--timestamp", default=None)
    p_event.add_argument("--output", required=True)
    p_event.set_defaults(func=cmd_synth_wazuh_event)

    p_self = sub.add_parser("self-test", help="round-trip the algorithm against itself")
    p_self.add_argument("--password", default="FELDTECH_VNC")
    p_self.add_argument("--tmp-wordlist", default=None)
    p_self.set_defaults(func=cmd_self_test)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
