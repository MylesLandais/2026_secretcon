#!/usr/bin/env python3
"""Static audit: documented VNC Kali tools match flake/kali shells and scripts."""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Tool id -> (binary on PATH, flake.nix must mention, kali.nix must mention)
VNC_TOOL_MATRIX = {
    "nmap": {
        "binary": "nmap",
        "flake": True,
        "kali": True,
        "doc_anchor": "vnc-info",
    },
    "hydra": {
        "binary": "hydra",
        "flake": True,
        "kali": False,
        "doc_anchor": "hydra",
    },
    "tshark": {
        "binary": "tshark",
        "flake": True,  # wireshark-cli
        "kali": False,
        "doc_anchor": "tshark",
    },
    "tcpdump": {
        "binary": "tcpdump",
        "flake": True,
        "kali": False,
        "doc_anchor": "tcpdump",
    },
    "vncviewer": {
        "binary": "vncviewer",
        "flake": True,  # tigervnc
        "kali": False,
        "doc_anchor": "vncviewer",
    },
    "msfconsole": {
        "binary": "msfconsole",
        "flake": False,
        "kali": True,  # metasploit package
        "doc_anchor": "vnc_login",
    },
    "check_vnc_auth": {
        "binary": None,
        "flake": False,
        "kali": False,
        "doc_anchor": "check_vnc_auth",
        "path": "ansible/roles/ultravnc/files/check_vnc_auth.py",
    },
    "vnc-cred-tool": {
        "binary": None,
        "flake": False,
        "kali": False,
        "doc_anchor": "vnc-cred-tool",
        "path": "scripts/observability/vnc-cred-tool.py",
    },
}

FLAKE_ALIASES = {
    "tshark": "wireshark-cli",
    "vncviewer": "tigervnc",
    "msfconsole": "metasploit",
}


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def audit_flake() -> list[str]:
    errors: list[str] = []
    flake = _read(REPO_ROOT / "flake.nix")
    for tool_id, meta in VNC_TOOL_MATRIX.items():
        if not meta["flake"]:
            continue
        needle = FLAKE_ALIASES.get(tool_id, tool_id)
        if needle not in flake:
            errors.append(f"flake.nix missing package reference for {tool_id} ({needle})")
    return errors


def audit_kali() -> list[str]:
    errors: list[str] = []
    kali = _read(REPO_ROOT / "kali.nix")
    for tool_id, meta in VNC_TOOL_MATRIX.items():
        if not meta["kali"]:
            continue
        needle = FLAKE_ALIASES.get(tool_id, tool_id)
        if needle not in kali:
            errors.append(f"kali.nix missing package reference for {tool_id} ({needle})")
    return errors


def audit_docs() -> list[str]:
    errors: list[str] = []
    doc = REPO_ROOT / "docs/runbooks/ews-vnc-adversary-emulation.md"
    text = _read(doc)
    if "## Kali tool and package audit matrix" not in text:
        errors.append("ews-vnc-adversary-emulation.md missing Kali tool audit matrix section")
    for tool_id, meta in VNC_TOOL_MATRIX.items():
        if meta["doc_anchor"] not in text:
            errors.append(f"doc matrix missing anchor for {tool_id}: {meta['doc_anchor']}")
    return errors


def audit_scripts() -> list[str]:
    errors: list[str] = []
    verify = _read(REPO_ROOT / "scripts/verify-ews.sh")
    if "check_vnc_auth.py" not in verify:
        errors.append("verify-ews.sh does not reference check_vnc_auth.py")
    if "vnc-cred-tool.py" not in verify:
        errors.append("verify-ews.sh does not reference vnc-cred-tool.py")
    for tool_id, meta in VNC_TOOL_MATRIX.items():
        path_key = meta.get("path")
        if path_key and not (REPO_ROOT / path_key).is_file():
            errors.append(f"missing in-tree tool path: {path_key}")
    return errors


def audit_wordlist_password() -> list[str]:
    errors: list[str] = []
    wl = REPO_ROOT / "provisioning/wordlists/vnc-betterdefaultpasslist.txt"
    if not wl.is_file():
        return [f"missing wordlist: {wl}"]
    lines = [ln.strip() for ln in wl.read_text(encoding="utf-8").splitlines() if ln.strip()]
    if "FELDTECH_VNC" not in lines:
        errors.append("wordlist missing FELDTECH_VNC")
    defaults = _read(REPO_ROOT / "ansible/roles/tightvnc/defaults/main.yml")
    if "FELDTECH_VNC" not in defaults:
        errors.append("tightvnc defaults do not mention FELDTECH_VNC")
    m = re.search(r"tightvnc_blacklist_threshold:\s*(\d+)", defaults)
    if m and int(m.group(1)) <= len(lines):
        errors.append(
            f"tightvnc_blacklist_threshold {m.group(1)} must exceed wordlist size {len(lines)}"
        )
    return errors


def main() -> int:
    errors: list[str] = []
    errors.extend(audit_flake())
    errors.extend(audit_kali())
    errors.extend(audit_docs())
    errors.extend(audit_scripts())
    errors.extend(audit_wordlist_password())

    if errors:
        for err in errors:
            print(f"FAIL  {err}", file=sys.stderr)
        return 1

    print("PASS  vnc kali-tool audit (flake, kali, docs, scripts, wordlist)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
