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


# --- F18: send_keys ---------------------------------------------------


async def test_send_keys_passes_content_and_enter(monkeypatch: pytest.MonkeyPatch) -> None:
    """send_keys invokes tmux send-keys with content + Enter."""
    from esr_cc_tmux.adapter import CcTmuxAdapter

    calls = _patch_run(monkeypatch, _ok)
    adapter_inst = CcTmuxAdapter.factory("cc", AdapterConfig({}))

    ack = await adapter_inst.on_directive(
        "send_keys", {"session_name": "sess-A", "content": "hello world"}
    )
    assert ack == {"ok": True}

    # skip the tmux --version probe call
    sk_call = calls[1]
    assert sk_call == [
        "tmux",
        "send-keys",
        "-t",
        "sess-A",
        "hello world",
        "Enter",
    ]


async def test_send_keys_handles_shell_special_chars_without_reinterpretation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Content with $var / backticks / quotes reaches tmux verbatim (no shell)."""
    from esr_cc_tmux.adapter import CcTmuxAdapter

    calls = _patch_run(monkeypatch, _ok)
    adapter_inst = CcTmuxAdapter.factory("cc", AdapterConfig({}))

    tricky = "echo $HOME `uname` 'hi \"there\"'"
    await adapter_inst.on_directive(
        "send_keys", {"session_name": "s", "content": tricky}
    )
    # subprocess.run argv-mode does not re-interpret; content arrives verbatim
    assert calls[1] == ["tmux", "send-keys", "-t", "s", tricky, "Enter"]


# --- F19: kill_session ------------------------------------------------


async def test_kill_session_calls_tmux_kill(monkeypatch: pytest.MonkeyPatch) -> None:
    from esr_cc_tmux.adapter import CcTmuxAdapter

    calls = _patch_run(monkeypatch, _ok)
    adapter_inst = CcTmuxAdapter.factory("cc", AdapterConfig({}))

    ack = await adapter_inst.on_directive("kill_session", {"session_name": "sess-A"})
    assert ack == {"ok": True}
    assert calls[1] == ["tmux", "kill-session", "-t", "sess-A"]


# --- F20: capture_pane ------------------------------------------------


async def test_capture_pane_returns_pane_text(monkeypatch: pytest.MonkeyPatch) -> None:
    from esr_cc_tmux.adapter import CcTmuxAdapter

    def _responder(argv: list[str]) -> subprocess.CompletedProcess[str]:
        if argv[:2] == ["tmux", "--version"]:
            return _ok(argv)
        return subprocess.CompletedProcess(argv, 0, stdout="pane text\nline2\n", stderr="")

    _patch_run(monkeypatch, _responder)
    adapter_inst = CcTmuxAdapter.factory("cc", AdapterConfig({}))

    ack = await adapter_inst.on_directive("capture_pane", {"session_name": "sess-A"})
    assert ack == {"ok": True, "result": {"content": "pane text\nline2\n"}}
