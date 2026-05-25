#!/usr/bin/env python3
"""
Run SharpUp.exe as User_Joe on the CysVuln VM via the shared
joe_task_runner harness.

SharpUp (GhostPack) is a focused C# privilege-escalation auditor. Unlike
winPEAS it has no upstream prebuilt releases, so the binary is vendored
at infrastructure/artifacts/cysvuln/SharpUp.exe (see
scripts/fetch-cysvuln-artifacts.sh for the build instructions). The
runner will use that vendored copy automatically; --local / SHARPUP_LOCAL
overrides it.

CLI / env-var surface mirrors run_winpeas_as_joe.py (SHARPUP_* env
prefix). See scripts/run-sharpup.sh for the wrapper.
"""
from __future__ import annotations

import pathlib
import sys

from joe_task_runner import ToolSpec, build_common_parser, run_as_joe

SPEC = ToolSpec(
    name="SharpUp",
    victim_bin=r"C:\Users\Public\SharpUp.exe",
    victim_out=r"C:\Users\Public\sharpup-joe-stdout.txt",
    task_name="SecretConSharpUpJoe",
    default_args="audit",
    default_cache=pathlib.Path("artifacts/cysvuln/sharpup/SharpUp.exe"),
    serve_name="SharpUp.exe",
    env_prefix="SHARPUP",
    vendored=pathlib.Path("infrastructure/artifacts/cysvuln/SharpUp.exe"),
    default_url=None,
)


def main() -> int:
    parser = build_common_parser(SPEC)
    args = parser.parse_args()
    return run_as_joe(SPEC, args)


if __name__ == "__main__":
    sys.exit(main())
