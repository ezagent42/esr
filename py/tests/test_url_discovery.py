"""PRD 03 F11 — IPC URL discovery."""

from __future__ import annotations

import pytest

from esr.ipc.url import DEFAULT_RUNTIME_URL, discover_runtime_url


def test_discover_defaults_when_no_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """With no env var, returns the documented default."""
    monkeypatch.delenv("ESR_RUNTIME_URL", raising=False)
    assert discover_runtime_url() == DEFAULT_RUNTIME_URL
    assert DEFAULT_RUNTIME_URL == "ws://localhost:4001/adapter_hub/socket/websocket"


def test_discover_uses_env_override(monkeypatch: pytest.MonkeyPatch) -> None:
    """ESR_RUNTIME_URL env var overrides the default."""
    monkeypatch.setenv("ESR_RUNTIME_URL", "ws://prod.internal:4000/socket/websocket")
    assert discover_runtime_url() == "ws://prod.internal:4000/socket/websocket"


def test_discover_rejects_empty_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Empty ESR_RUNTIME_URL is treated as unset (use default)."""
    monkeypatch.setenv("ESR_RUNTIME_URL", "")
    assert discover_runtime_url() == DEFAULT_RUNTIME_URL


def test_discover_explicit_override_argument(monkeypatch: pytest.MonkeyPatch) -> None:
    """Caller-provided override beats both env and default."""
    monkeypatch.setenv("ESR_RUNTIME_URL", "ws://from-env/socket")
    assert (
        discover_runtime_url(override="ws://from-arg/socket")
        == "ws://from-arg/socket"
    )
