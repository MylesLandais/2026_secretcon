"""CI-safe tests for scripts/observability/vnc-cred-tool.py."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPO_ROOT / "scripts/observability/vnc-cred-tool.py"


def _load_tool():
    spec = importlib.util.spec_from_file_location("vnc_cred_tool", TOOL_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def test_encode_feldtech_vnc_blob():
    mod = _load_tool()
    blob = mod.encode_stored_blob("FELDTECH_VNC")
    assert len(blob) == 8
    # Known-good blob from registry docs / verify-ews.sh
    assert mod._hex_dashed(blob) == "52-E6-65-4C-7A-A1-88-5F"


def test_decode_wordlist_roundtrip(tmp_path: Path):
    mod = _load_tool()
    wl = tmp_path / "wl.txt"
    wl.write_text("wrong\nFELDTECH_VNC\n", encoding="utf-8")
    blob_hex = mod._hex_dashed(mod.encode_stored_blob("FELDTECH_VNC"))
    ns = type("NS", (), {"hex": blob_hex, "wordlist": str(wl)})()
    assert mod.cmd_decode(ns) == 0


def test_rfb_response_roundtrip():
    mod = _load_tool()
    challenge = bytes.fromhex("0123456789abcdef0123456789abcdef")
    response = mod.compute_vnc_response("FELDTECH_VNC", challenge)
    assert len(response) == 16
    wl_path = REPO_ROOT / "provisioning/wordlists/vnc-betterdefaultpasslist.txt"
    ns = type(
        "NS",
        (),
        {
            "challenge": mod._hex_dashed(challenge),
            "response": mod._hex_dashed(response),
            "wordlist": str(wl_path),
        },
    )()
    assert mod.cmd_crack(ns) == 0


def test_self_test_subcommand():
    mod = _load_tool()
    ns = type("NS", (), {"password": "FELDTECH_VNC", "tmp_wordlist": None})()
    assert mod.cmd_self_test(ns) == 0
