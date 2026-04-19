"""PRD 03 F11 — IPC URL discovery."""

from __future__ import annotations

import pytest

from esr.ipc.url import (
    DEFAULT_ADAPTER_HUB_URL,
    DEFAULT_HANDLER_HUB_URL,
    DEFAULT_RUNTIME_URL,
    discover_runtime_url,
)


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


def test_discover_kind_adapter_uses_adapter_hub_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Reviewer C1: kind='adapter' returns /adapter_hub/socket path."""
    monkeypatch.delenv("ESR_RUNTIME_URL", raising=False)
    monkeypatch.delenv("ESR_ADAPTER_HUB_URL", raising=False)
    monkeypatch.delenv("ESR_HANDLER_HUB_URL", raising=False)

    assert discover_runtime_url(kind="adapter") == DEFAULT_ADAPTER_HUB_URL
    assert "/adapter_hub/socket/" in DEFAULT_ADAPTER_HUB_URL


def test_discover_kind_handler_uses_handler_hub_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Reviewer C1: kind='handler' returns /handler_hub/socket path —
    without this split, handler workers connect to the adapter socket
    and the runtime never routes their joins.
    """
    monkeypatch.delenv("ESR_RUNTIME_URL", raising=False)
    monkeypatch.delenv("ESR_ADAPTER_HUB_URL", raising=False)
    monkeypatch.delenv("ESR_HANDLER_HUB_URL", raising=False)

    assert discover_runtime_url(kind="handler") == DEFAULT_HANDLER_HUB_URL
    assert "/handler_hub/socket/" in DEFAULT_HANDLER_HUB_URL
    # And distinct from the adapter URL
    assert DEFAULT_HANDLER_HUB_URL != DEFAULT_ADAPTER_HUB_URL


def test_discover_kind_specific_env_vars(monkeypatch: pytest.MonkeyPatch) -> None:
    """ESR_HANDLER_HUB_URL overrides the handler default; same for adapter."""
    monkeypatch.setenv("ESR_ADAPTER_HUB_URL", "ws://adapt.internal:4000/a/websocket")
    monkeypatch.setenv("ESR_HANDLER_HUB_URL", "ws://hand.internal:4000/h/websocket")

    assert discover_runtime_url(kind="adapter") == "ws://adapt.internal:4000/a/websocket"
    assert discover_runtime_url(kind="handler") == "ws://hand.internal:4000/h/websocket"
