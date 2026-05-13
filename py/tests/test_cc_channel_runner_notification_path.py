"""Unit tests for Task 2.4: envelope → MCP notification dispatch.

Covers both the pure helper `build_notification_params` (Python port
of Elixir helper) and the integration with `phx_receive_loop`'s
envelope dispatcher.
"""

from __future__ import annotations

from typing import Any

import pytest

from cc_channel_runner.mcp_server import BridgeMCPServer
from cc_channel_runner.notification import build_notification_params
from cc_channel_runner.phx_receive import BridgeShutdown, phx_receive_loop


# --- build_notification_params -------------------------------------


def test_text_envelope_default_meta_filled():
    """Plain text envelope: defaults for runtime_mode + source applied."""
    payload = {
        "content": "hello",
        "chat_id": "oc_abc",
        "user": "linyilun",
    }
    out = build_notification_params(payload)
    assert out["content"] == "hello"
    assert out["meta"]["chat_id"] == "oc_abc"
    assert out["meta"]["user"] == "linyilun"
    assert out["meta"]["runtime_mode"] == "discussion"
    assert out["meta"]["source"] == "feishu"


def test_text_envelope_strips_empty_and_internal_fields():
    """Empty values + internal fields don't reach meta."""
    payload = {
        "content": "hi",
        "chat_id": "oc_x",
        "ts": "",
        "msg_type": "text",  # internal; never in meta
        "media_uri": None,  # internal; never in meta
        "extra_field": "ignored",  # not in META_FIELDS allowlist
    }
    out = build_notification_params(payload)
    assert "ts" not in out["meta"]
    assert "msg_type" not in out["meta"]
    assert "media_uri" not in out["meta"]
    assert "extra_field" not in out["meta"]


def test_attachment_envelope_replaces_content_and_surfaces_uri():
    """Image envelope: content becomes stub, media_uri + kind in meta."""
    payload = {
        "content": "ignored on attachment path",
        "chat_id": "oc_x",
        "msg_type": "image",
        "media_uri": "phaser://workspace/abc/img.png",
    }
    out = build_notification_params(payload)
    assert out["content"] == "[image attachment]"
    assert out["meta"]["kind"] == "image"
    assert out["meta"]["media_uri"] == "phaser://workspace/abc/img.png"


def test_missing_content_becomes_empty_string():
    """Envelope without `content` produces content=''."""
    out = build_notification_params({"chat_id": "oc_x"})
    assert out["content"] == ""


# --- phx_receive_loop dispatch -------------------------------------


class _FakeClient:
    """Minimal stand-in for PhoenixChannelClient.

    `receive()` yields the frames passed to the constructor then
    raises StopAsyncIteration. Matches the real client's signature:
    an `async def receive()` returning an async iterator.
    """

    def __init__(self, frames: list[dict[str, Any]]) -> None:
        self._frames = list(frames)

    async def receive(self):
        for frame in self._frames:
            yield frame


@pytest.mark.asyncio
async def test_notification_envelope_calls_send_channel_notification():
    """A single notification envelope reaches send_channel_notification."""
    server = BridgeMCPServer()
    sent: list[dict[str, Any]] = []

    async def _capture(params: dict[str, Any]) -> None:
        sent.append(params)

    # Monkey-patch the bridge's notification push.
    server.send_channel_notification = _capture  # type: ignore[method-assign]

    client = _FakeClient(
        [
            {
                "event": "envelope",
                "payload": {
                    "kind": "notification",
                    "content": "hi from feishu",
                    "chat_id": "oc_abc",
                    "user": "linyilun",
                },
            }
        ]
    )
    await phx_receive_loop(client, server)  # type: ignore[arg-type]

    assert len(sent) == 1
    params = sent[0]
    assert params["content"] == "hi from feishu"
    assert params["meta"]["chat_id"] == "oc_abc"
    assert params["meta"]["user"] == "linyilun"


@pytest.mark.asyncio
async def test_absent_kind_treated_as_notification():
    """Broadcast envelopes from cc_process don't have a kind tag."""
    server = BridgeMCPServer()
    sent: list[dict[str, Any]] = []

    async def _capture(params: dict[str, Any]) -> None:
        sent.append(params)

    server.send_channel_notification = _capture  # type: ignore[method-assign]

    client = _FakeClient(
        [
            {
                "event": "envelope",
                "payload": {
                    # No "kind" key — matches cc_process broadcast shape.
                    "content": "from cc_process",
                    "chat_id": "oc_zzz",
                },
            }
        ]
    )
    await phx_receive_loop(client, server)  # type: ignore[arg-type]
    assert len(sent) == 1
    assert sent[0]["content"] == "from cc_process"


@pytest.mark.asyncio
async def test_session_killed_raises_bridge_shutdown():
    """session_killed envelope ends the bridge cleanly."""
    server = BridgeMCPServer()
    client = _FakeClient(
        [{"event": "envelope", "payload": {"kind": "session_killed"}}]
    )
    with pytest.raises(BridgeShutdown):
        await phx_receive_loop(client, server)  # type: ignore[arg-type]


@pytest.mark.asyncio
async def test_cleanup_check_requested_forwarded_as_notification():
    """cleanup_check_requested envelope is forwarded to MCP."""
    server = BridgeMCPServer()
    sent: list[dict[str, Any]] = []

    async def _capture(params: dict[str, Any]) -> None:
        sent.append(params)

    server.send_channel_notification = _capture  # type: ignore[method-assign]

    client = _FakeClient(
        [
            {
                "event": "envelope",
                "payload": {
                    "kind": "cleanup_check_requested",
                    "session_id": "sid-1",
                    "worktree_path": "/tmp/wt",
                    "instructions": "do the thing",
                },
            }
        ]
    )
    await phx_receive_loop(client, server)  # type: ignore[arg-type]
    assert len(sent) == 1


@pytest.mark.asyncio
async def test_tool_result_resolves_pending_future():
    """tool_result envelope resolves a matching pending future."""
    import asyncio

    server = BridgeMCPServer()
    loop = asyncio.get_running_loop()
    future: asyncio.Future[dict[str, Any]] = loop.create_future()
    server.pending_tool_calls["req-1"] = future

    client = _FakeClient(
        [
            {
                "event": "envelope",
                "payload": {
                    "kind": "tool_result",
                    "req_id": "req-1",
                    "ok": True,
                    "data": {"sent_to": "oc_x"},
                },
            }
        ]
    )
    await phx_receive_loop(client, server)  # type: ignore[arg-type]

    assert future.done()
    result = future.result()
    assert result["ok"] is True
    assert result["data"] == {"sent_to": "oc_x"}


@pytest.mark.asyncio
async def test_unknown_kind_dropped_silently():
    """Unknown envelope kinds don't raise and don't reach MCP."""
    server = BridgeMCPServer()
    sent: list[dict[str, Any]] = []

    async def _capture(params: dict[str, Any]) -> None:
        sent.append(params)

    server.send_channel_notification = _capture  # type: ignore[method-assign]

    client = _FakeClient(
        [{"event": "envelope", "payload": {"kind": "bogus"}}]
    )
    await phx_receive_loop(client, server)  # type: ignore[arg-type]
    assert sent == []
