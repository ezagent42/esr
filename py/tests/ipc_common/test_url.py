"""resolve_url/1 mirror test — originally exercised via _adapter_common.url.

After the P5-2 move, the canonical home is _ipc_common.url. Keep the
behavioural coverage verbatim so the move is a no-op for callers.
"""
from __future__ import annotations

from _ipc_common.url import resolve_url


def test_fallback_returned_when_port_file_absent(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "nope")
    assert resolve_url("ws://127.0.0.1:4000/x") == "ws://127.0.0.1:4000/x"


def test_port_file_substitutes_authority(tmp_path, monkeypatch) -> None:
    instance = tmp_path / "default"
    instance.mkdir()
    (instance / "esrd.port").write_text("4321\n")
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "default")
    assert resolve_url("ws://127.0.0.1:4000/x") == "ws://127.0.0.1:4321/x"
