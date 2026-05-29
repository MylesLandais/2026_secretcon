"""Unit tests for ansible/roles/ultravnc/files/check_vnc_auth.py helpers."""
from __future__ import annotations

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PROBE_PATH = REPO_ROOT / "ansible/roles/ultravnc/files/check_vnc_auth.py"
CRED_TOOL = REPO_ROOT / "scripts/observability/vnc-cred-tool.py"


def _load_probe():
    spec = importlib.util.spec_from_file_location("check_vnc_auth", PROBE_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def test_classify_result_codes():
    mod = _load_probe()
    assert mod.classify_result(0) == mod.AuthOutcome.OK
    assert mod.classify_result(1) == mod.AuthOutcome.WRONG_PASSWORD


def test_load_wordlist_skips_comments(tmp_path: Path):
    mod = _load_probe()
    wl = tmp_path / "wl.txt"
    wl.write_text("# comment\nabc\n\n", encoding="utf-8")
    assert mod.load_wordlist(wl) == ["abc"]


def test_brute_wordlist_finds_password(tmp_path: Path):
    mod = _load_probe()
    vnc_mod = mod._load_vnc_cred_tool(CRED_TOOL)
    wl = tmp_path / "wl.txt"
    wl.write_text("wrong\nFELDTECH_VNC\n", encoding="utf-8")

    # No live server: mock probe_password to succeed on planted password.
    original = mod.probe_password

    def fake_probe(host, port, password, vnc_mod_):
        if password == "FELDTECH_VNC":
            return mod.AuthOutcome.OK, 0
        return mod.AuthOutcome.WRONG_PASSWORD, 1

    mod.probe_password = fake_probe
    try:
        result = mod.brute_wordlist(
            "127.0.0.1", 5900, wl, vnc_mod, delay_seconds=0
        )
    finally:
        mod.probe_password = original

    assert result["success"] is True
    assert result["found"] == "FELDTECH_VNC"


def test_brute_wordlist_retries_transient_then_succeeds(tmp_path: Path, monkeypatch):
    """The pace limiter trips on the correct password; retry must recover it."""
    mod = _load_probe()
    vnc_mod = mod._load_vnc_cred_tool(CRED_TOOL)
    wl = tmp_path / "wl.txt"
    wl.write_text("123456\nFELDTECH_VNC\n", encoding="utf-8")

    # Don't actually sleep during the test.
    monkeypatch.setattr(mod.time, "sleep", lambda *_a, **_k: None)

    calls: list[str] = []
    # First wrong guess arms the limiter; the correct password then gets
    # NO_VNC_AUTH on its first probe and only succeeds on retry.
    feldtech_attempts = {"n": 0}

    def fake_probe(host, port, password, vnc_mod_):
        calls.append(password)
        if password == "FELDTECH_VNC":
            feldtech_attempts["n"] += 1
            if feldtech_attempts["n"] == 1:
                return mod.AuthOutcome.NO_VNC_AUTH, None
            return mod.AuthOutcome.OK, 0
        return mod.AuthOutcome.WRONG_PASSWORD, 1

    monkeypatch.setattr(mod, "probe_password", fake_probe)

    result = mod.brute_wordlist("127.0.0.1", 5900, wl, vnc_mod, delay_seconds=0)

    assert result["success"] is True
    assert result["found"] == "FELDTECH_VNC"
    # Confirms the same candidate was retried rather than the sweep aborting.
    assert calls.count("FELDTECH_VNC") == 2
    assert result["retries"] == 1
    assert result["last_retry_outcome"] == mod.AuthOutcome.NO_VNC_AUTH.value


def test_brute_wordlist_paces_between_attempts(tmp_path: Path, monkeypatch):
    """A delay must run before every attempt after the first."""
    mod = _load_probe()
    vnc_mod = mod._load_vnc_cred_tool(CRED_TOOL)
    wl = tmp_path / "wl.txt"
    wl.write_text("a\nb\nc\n", encoding="utf-8")

    sleeps: list[float] = []
    monkeypatch.setattr(mod.time, "sleep", lambda s: sleeps.append(s))
    monkeypatch.setattr(
        mod,
        "probe_password",
        lambda *_a, **_k: (mod.AuthOutcome.WRONG_PASSWORD, 1),
    )

    mod.brute_wordlist("127.0.0.1", 5900, wl, vnc_mod, delay_seconds=0.5)

    # Three wrong passwords -> two inter-attempt pacing sleeps of 0.5s.
    assert sleeps == [0.5, 0.5]


def test_brute_wordlist_aborts_after_retry_budget(tmp_path: Path, monkeypatch):
    """Persistent transient rejects exhaust retries and stop the sweep."""
    mod = _load_probe()
    vnc_mod = mod._load_vnc_cred_tool(CRED_TOOL)
    wl = tmp_path / "wl.txt"
    wl.write_text("a\nb\n", encoding="utf-8")

    monkeypatch.setattr(mod.time, "sleep", lambda *_a, **_k: None)
    monkeypatch.setattr(
        mod,
        "probe_password",
        lambda *_a, **_k: (mod.AuthOutcome.NO_VNC_AUTH, None),
    )

    result = mod.brute_wordlist(
        "127.0.0.1", 5900, wl, vnc_mod, delay_seconds=0, max_retries=2
    )

    assert result["success"] is False
    assert result["last_outcome"] == mod.AuthOutcome.NO_VNC_AUTH.value
    assert result["retries"] == 2  # one candidate, retried twice, then abort
