"""Task 8 (DI-3): channel.py URL resolution via port file.

The MCP bridge needs to discover esrd's current port from
``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` so it survives ``launchctl
kickstart`` restarting esrd on a new port. When the port file is
absent (dev launched ``mix phx.server`` by hand on a fixed port) or
the env var ``ESR_ESRD_URL`` is set explicitly, the resolver must fall
back gracefully.
"""
from __future__ import annotations

from pathlib import Path

import pytest


def test_resolve_from_port_file_reads_port(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """When ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` exists, the resolver
    returns ``ws://127.0.0.1:<port>`` using the file contents."""
    from esr_cc_mcp.channel import _resolve_from_port_file

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("5555\n")

    assert _resolve_from_port_file() == "ws://127.0.0.1:5555"


def test_resolve_from_port_file_absent_returns_4001_fallback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Missing port file returns the legacy ``ws://127.0.0.1:4001``
    fallback so dev mode (manual ``mix phx.server``) keeps working."""
    from esr_cc_mcp.channel import _resolve_from_port_file

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "nonexistent")

    assert _resolve_from_port_file() == "ws://127.0.0.1:4001"


def test_resolve_from_port_file_malformed_returns_fallback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Garbage content in the port file is treated as absent —
    the resolver returns the fallback rather than synthesising
    a malformed URL."""
    from esr_cc_mcp.channel import _resolve_from_port_file

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("not-a-port\n")

    assert _resolve_from_port_file() == "ws://127.0.0.1:4001"


def test_resolve_from_port_file_defaults_to_home_and_default_instance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """When ``ESRD_HOME`` unset, falls back to ``~/.esrd``; when
    ``ESR_INSTANCE`` unset, defaults to ``default``."""
    from esr_cc_mcp.channel import _resolve_from_port_file

    fake_home = tmp_path / "fake_home"
    (fake_home / ".esrd" / "default").mkdir(parents=True)
    (fake_home / ".esrd" / "default" / "esrd.port").write_text("6060")

    monkeypatch.delenv("ESRD_HOME", raising=False)
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    monkeypatch.setenv("HOME", str(fake_home))

    # expanduser relies on HOME on POSIX
    assert _resolve_from_port_file() == "ws://127.0.0.1:6060"


def test_main_url_prefers_explicit_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``ESR_ESRD_URL`` takes precedence over the port file — this
    preserves explicit override semantics (e.g. pointing at a remote
    esrd for e2e)."""
    from esr_cc_mcp import channel as ch

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("5555")
    monkeypatch.setenv("ESR_ESRD_URL", "ws://esrd.example.com:9999")

    # Resolution logic: explicit env wins over port file.
    import os
    url = os.environ.get("ESR_ESRD_URL") or ch._resolve_from_port_file()
    assert url == "ws://esrd.example.com:9999"


def test_main_url_without_env_uses_port_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Without ``ESR_ESRD_URL``, the bridge picks up esrd's port from
    the port file — this is the launchctl-managed path."""
    from esr_cc_mcp import channel as ch

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    monkeypatch.delenv("ESR_ESRD_URL", raising=False)
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("7070")

    import os
    url = os.environ.get("ESR_ESRD_URL") or ch._resolve_from_port_file()
    assert url == "ws://127.0.0.1:7070"
