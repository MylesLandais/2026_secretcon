"""Pytest cases for audit_aie.evaluate()."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from audit_aie import evaluate  # noqa: E402


FULL = {
    "identity": "WIN-X\\User_Joe",
    "aie_hklm": 1,
    "aie_hkcu": 1,
    "consent_prompt_behavior_admin": 0,
    "prompt_on_secure_desktop": 0,
    "msiexec_path": r"C:\Windows\System32\msiexec.exe",
    "msiexec_version": "5.0.14393.0",
    "temp_dir": r"C:\Users\User_Joe\AppData\Local\Temp",
    "temp_writable": True,
}


def test_full_chain_expected():
    r = evaluate(FULL, "1.2.3.4", "User_Joe")
    assert r.chain_response_expected is True
    assert r.aie_hklm == 1 and r.aie_hkcu == 1
    assert "PASS" in r.summary


def test_missing_hkcu_breaks_chain():
    d = dict(FULL, aie_hkcu=None)
    r = evaluate(d, "1.2.3.4", "User_Joe")
    assert r.chain_response_expected is False


def test_uac_consent_nonzero_breaks_chain():
    d = dict(FULL, consent_prompt_behavior_admin=5)
    r = evaluate(d, "1.2.3.4", "User_Joe")
    assert r.chain_response_expected is False


def test_temp_not_writable_breaks_chain():
    d = dict(FULL, temp_writable=False)
    r = evaluate(d, "1.2.3.4", "User_Joe")
    assert r.chain_response_expected is False


def test_no_msiexec_breaks_chain():
    d = dict(FULL, msiexec_path=None)
    r = evaluate(d, "1.2.3.4", "User_Joe")
    assert r.chain_response_expected is False


def test_all_none_returns_false():
    d = {k: None for k in FULL}
    d["temp_writable"] = False
    r = evaluate(d, "1.2.3.4", "User_Joe")
    assert r.chain_response_expected is False
