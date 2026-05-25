"""Pytest cases for check_aie_response.build()."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from check_aie_response import build, render  # noqa: E402


WIXL = shutil.which("wixl")


def test_render_rejects_empty(tmp_path: Path):
    with pytest.raises(ValueError):
        render("", tmp_path)


def test_render_rejects_newline(tmp_path: Path):
    with pytest.raises(ValueError):
        render("cmd /c whoami\n", tmp_path)


def test_render_rejects_nul(tmp_path: Path):
    with pytest.raises(ValueError):
        render("cmd /c whoami\x00", tmp_path)


def test_render_escapes_xml_metachars(tmp_path: Path):
    wxs = render('cmd /c echo "<a&b>" > C:\\Windows\\Temp\\x.txt', tmp_path)
    content = wxs.read_text()
    assert "&lt;a&amp;b&gt;" in content
    assert "&quot;" in content


@pytest.mark.skipif(WIXL is None, reason="wixl not on PATH")
def test_build_emits_ole_compound_document(tmp_path: Path):
    out = tmp_path / "probe.msi"
    build("cmd /c whoami > C:\\Windows\\Temp\\probe.txt", out)
    assert out.stat().st_size > 1024
    # MSI is an OLE compound document — magic is D0 CF 11 E0 A1 B1 1A E1
    magic = out.read_bytes()[:8]
    assert magic == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


@pytest.mark.skipif(WIXL is None, reason="wixl not on PATH")
def test_build_embeds_command_in_msi(tmp_path: Path):
    out = tmp_path / "probe.msi"
    unique = "AIE_TEST_TOKEN_4d8f3a91"
    build(f"cmd /c echo {unique} > C:\\Windows\\Temp\\probe.txt", out)
    # CustomAction ExeCommand lives in the CustomAction table; wixl stores
    # strings UTF-16-LE in the streams. Search both encodings.
    blob = out.read_bytes()
    assert unique.encode("utf-8") in blob or unique.encode("utf-16-le") in blob
