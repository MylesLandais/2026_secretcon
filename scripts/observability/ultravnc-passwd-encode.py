#!/usr/bin/env python3
"""Encode UltraVNC ultravnc.ini passwd= via vnc-cred-tool + Windows struct suffix.

UltraVNC stores the same 8-byte RealVNC/TightVNC DES blob as registry Password.
WritePrivateProfileStruct adds a 1-byte suffix before hex encoding (18 chars).
We mirror setpasswd.exe output by appending 0x00 unless overridden.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def encode_ultravnc_passwd(password: str, cred_tool: Path) -> str:
    proc = subprocess.run(
        ["python3", str(cred_tool), "encode", "--password", password],
        check=True,
        capture_output=True,
        text=True,
    )
    blob_hex = proc.stdout.strip().replace("-", "").upper()
    if len(blob_hex) != 16:
        raise ValueError(f"expected 8-byte blob, got {blob_hex!r}")
    # Match setpasswd / WritePrivateProfileStruct 9-byte encoding (8 + ignored suffix).
    return blob_hex + "00"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--password", required=True)
    parser.add_argument(
        "--cred-tool",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "vnc-cred-tool.py",
    )
    args = parser.parse_args()
    print(encode_ultravnc_passwd(args.password, args.cred_tool))
    return 0


if __name__ == "__main__":
    sys.exit(main())
