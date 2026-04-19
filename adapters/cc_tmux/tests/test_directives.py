"""PRD 04 F17-F20 — cc_tmux adapter directives."""

from __future__ import annotations

import subprocess
from collections.abc import Callable
from typing import Any

import pytest

from esr.adapter import AdapterConfig


# --- F22: tmux availability + F17: new_session ------------------------


def _patch_run(
    monkeypatch: pytest.MonkeyPatch,
    responder: Callable[[list[str]], subprocess.CompletedProcess[str]],
) -> list[list[str]]:
    """Install a subprocess.run replacement that records argv + returns a canned result."""
    calls: list[list[str]] = []

    def _run(
        argv: list[str], capture_output: bool = True, text: bool = True, **_: object
    ) -> subprocess.CompletedProcess[str]:
        calls.append(list(argv))
        return responder(argv)

    monkeypatch.setattr(subprocess, "run", _run)
    return calls


def _ok(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")


def _err(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(argv, 1, stdout="", stderr="boom")


async def test_new_session_invokes_tmux_with_expected_argv(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """new_session shells out to `tmux new-session -d -s <name> <cmd>`."""
    from esr_cc_tmux.adapter import CcTmuxAdapter

    calls = _patch_run(monkeypatch, _ok)
    cfg = AdapterConfig({"start_cmd": "/bin/echo"})
    adapter_inst = CcTmuxAdapter.factory("cc-local", cfg)

    ack = await adapter_inst.on_directive(
        "new_session", {"session_name": "sess-A", "start_cmd": "/usr/bin/claude"}
    )
    assert ack == {"ok": True}

    # First call is tmux --version (availability probe, F22)
    assert calls[0][:2] == ["tmux", "--version"]
    # Second call is the new-session invocation
    assert calls[1] == [
        "tmux",
        "new-session",
        "-d",
        "-s",
        "sess-A",
        "/usr/bin/claude",
    ]


async def test_new_session_reports_tmux_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """Non-zero tmux exit returns {ok: False, error: <stderr>}."""
    from esr_cc_tmux.adapter import CcTmuxAdapter

    def _responder(argv: list[str]) -> subprocess.CompletedProcess[str]:
        # First probe succeeds; new-session itself fails
        if argv[:2] == ["tmux", "--version"]:
            return _ok(argv)
        return _err(argv)

    _patch_run(monkeypatch, _responder)
    adapter_inst = CcTmuxAdapter.factory("cc", AdapterConfig({}))
    ack = await adapter_inst.on_directive(
        "new_session", {"session_name": "sess-A", "start_cmd": "/usr/bin/cmd"}
    )
    assert ack == {"ok": False, "error": "boom"}


async def test_tmux_not_installed_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """When tmux --version raises FileNotFoundError, every directive errors cleanly."""
    from esr_cc_tmux.adapter import CcTmuxAdapter

    def _run(
        argv: list[str], capture_output: bool = True, text: bool = True, **_: Any
    ) -> subprocess.CompletedProcess[str]:
        if argv == ["tmux", "--version"]:
            raise FileNotFoundError("tmux not found")
        raise AssertionError(
            "subsequent directives must not spawn tmux when probe failed"
        )

    monkeypatch.setattr(subprocess, "run", _run)
    adapter_inst = CcTmuxAdapter.factory("cc", AdapterConfig({}))

    ack1 = await adapter_inst.on_directive(
        "new_session", {"session_name": "a", "start_cmd": "/c"}
    )
    ack2 = await adapter_inst.on_directive(
        "new_session", {"session_name": "b", "start_cmd": "/c"}
    )
    assert ack1 == {"ok": False, "error": "tmux not installed"}
    assert ack2 == {"ok": False, "error": "tmux not installed"}


async def test_unknown_directive_returns_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """An action the adapter doesn't handle returns {ok: False, error: ...}."""
    from esr_cc_tmux.adapter import CcTmuxAdapter

    _patch_run(monkeypatch, _ok)
    adapter_inst = CcTmuxAdapter.factory("cc", AdapterConfig({}))

    ack = await adapter_inst.on_directive("teleport", {})
    assert ack["ok"] is False
    assert "unknown action" in ack["error"]
