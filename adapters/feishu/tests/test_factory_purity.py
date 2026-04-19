"""PRD 04 F02 — factory purity (feishu)."""

from __future__ import annotations

import socket

import pytest

from esr.adapter import AdapterConfig


def test_factory_does_not_open_sockets(monkeypatch: pytest.MonkeyPatch) -> None:
    """factory() must not connect or resolve — lark client is lazy-initialised."""
    from esr_feishu.adapter import FeishuAdapter

    def _boom(*_a: object, **_kw: object) -> None:
        raise RuntimeError("factory attempted a socket operation")

    monkeypatch.setattr(socket, "create_connection", _boom)
    monkeypatch.setattr(socket.socket, "connect", _boom)

    cfg = AdapterConfig({"app_id": "cli_test", "app_secret": "s"})
    instance = FeishuAdapter.factory("feishu-shared", cfg)

    # Factory ran without the monkeypatched bombs firing
    assert instance is not None
