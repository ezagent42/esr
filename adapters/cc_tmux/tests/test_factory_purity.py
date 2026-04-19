"""PRD 04 F02 — factory purity (cc_tmux)."""

from __future__ import annotations

import subprocess

import pytest

from esr.adapter import AdapterConfig


def test_factory_does_not_spawn_subprocess(monkeypatch: pytest.MonkeyPatch) -> None:
    """factory() must not shell out — tmux probe is lazy."""
    from esr_cc_tmux.adapter import CcTmuxAdapter

    def _boom(*_a: object, **_kw: object) -> None:
        raise RuntimeError("factory attempted to spawn a subprocess")

    monkeypatch.setattr(subprocess, "Popen", _boom)
    monkeypatch.setattr(subprocess, "run", _boom)

    cfg = AdapterConfig({"start_cmd": "/bin/echo"})
    instance = CcTmuxAdapter.factory("cc-local", cfg)
    assert instance is not None
