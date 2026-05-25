#!/usr/bin/env python3
"""
Run winPEASx64.exe as User_Joe on the CysVuln VM via the shared
joe_task_runner harness.

The harness fetches the binary, uploads it to the victim, runs it under
User_Joe's token using a one-shot scheduled task, and prints the
captured stdout (ANSI-stripped). See joe_task_runner.py for the full
explanation of why we go through Task Scheduler instead of PsExec or
Start-Process -Credential.

CLI / env-var surface preserved for back-compat with scripts/run-winpeas.sh.
"""
from __future__ import annotations

import pathlib
import sys

from joe_task_runner import ToolSpec, build_common_parser, run_as_joe

SPEC = ToolSpec(
    name="winPEAS",
    victim_bin=r"C:\Users\Public\winPEASx64.exe",
    victim_out=r"C:\Users\Public\winpeas-joe-stdout.txt",
    task_name="SecretConWinPEASJoe",
    default_args=(
        "notcolors quiet "
        "systeminfo userinfo applicationsinfo eventsinfo "
        "servicesinfo processinfo"
    ),
    default_cache=pathlib.Path("artifacts/cysvuln/winpeas/winPEASx64.exe"),
    serve_name="winPEASx64.exe",
    env_prefix="WINPEAS",
    default_url=(
        "https://github.com/peass-ng/PEASS-ng/releases/latest/download/"
        "winPEASx64.exe"
    ),
)


def main() -> int:
    parser = build_common_parser(SPEC)
    args = parser.parse_args()
    return run_as_joe(SPEC, args)


if __name__ == "__main__":
    sys.exit(main())
