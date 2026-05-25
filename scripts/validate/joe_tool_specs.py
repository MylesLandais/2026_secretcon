"""Registry of `ToolSpec`s consumed by `run_joe_tool.py`.

Adding a new joe-runner tool is one ToolSpec entry here plus a row in
the SPECS dict. The shell dispatcher (`scripts/run-joe-tool.sh`) and the
python CLI (`run_joe_tool.py`) read from this registry, so there is one
source of truth for per-tool defaults (binary path, args, env prefix,
vendored / download URL).
"""
from __future__ import annotations

import pathlib

from joe_task_runner import ToolSpec


WINPEAS = ToolSpec(
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


SHARPUP = ToolSpec(
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


SPECS: dict[str, ToolSpec] = {
    "winpeas": WINPEAS,
    "sharpup": SHARPUP,
}


def lookup(name: str) -> ToolSpec:
    try:
        return SPECS[name.lower()]
    except KeyError as exc:
        known = ", ".join(sorted(SPECS))
        raise SystemExit(
            f"unknown joe tool: {name!r} (known: {known})"
        ) from exc
