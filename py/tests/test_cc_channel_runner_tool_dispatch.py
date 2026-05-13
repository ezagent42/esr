"""Unit tests for Task 2.5: tool dispatch (MCP → channel → tool_result)."""

from __future__ import annotations

import asyncio
import json
from typing import Any

import pytest

from cc_channel_runner.mcp_server import BridgeMCPServer


class _FakePhxClient:
    """Stand-in for PhoenixChannelClient.

    `push()` records the call + returns a configurable phx_reply
    payload. Use `inject_tool_result()` to resolve a pending future
    on the bridge (simulating phx_receive_loop's behavior).
    """

    def __init__(self, ok: bool = True) -> None:
        self.pushed: list[tuple[str, str, dict[str, Any]]] = []
        self._ok = ok

    async def push(
        self, topic: str, event: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        self.pushed.append((topic, event, payload))
        if self._ok:
            return {"status": "ok", "response": {}}
        return {"status": "error", "response": {"reason": "test_failure"}}


async def _inject_tool_result_after_push(
    server: BridgeMCPServer,
    fake: _FakePhxClient,
    result_envelope: dict[str, Any],
) -> None:
    """Wait until the bridge pushes a tool_invoke, then resolve its future.

    Mimics what phx_receive_loop does when a tool_result envelope
    arrives over the WS: pulls the req_id from pending_tool_calls and
    sets the future's result.
    """
    # Poll for the push (the dispatch coroutine runs concurrently).
    for _ in range(200):
        if fake.pushed:
            break
        await asyncio.sleep(0.005)
    assert fake.pushed, "tool_invoke was never pushed"
    pushed_payload = fake.pushed[-1][2]
    req_id = pushed_payload["req_id"]
    # Stamp req_id onto the result envelope (consumer of pending future
    # doesn't need it since the key already maps to the future, but
    # tests use it to assert correlation).
    result_envelope = dict(result_envelope)
    result_envelope.setdefault("req_id", req_id)
    future = server.pending_tool_calls.get(req_id)
    assert future is not None, "pending future not registered"
    future.set_result(result_envelope)


@pytest.mark.asyncio
async def test_reply_tool_pushes_envelope_and_returns_result():
    """reply handler: push tool_invoke, await tool_result, return data."""
    server = BridgeMCPServer()
    server.set_session_id("sid-abc")
    fake = _FakePhxClient()
    server.set_phx_client(fake)  # type: ignore[arg-type]

    arguments = {"chat_id": "oc_x", "text": "hi"}

    # Run the dispatch coroutine + the result-injector concurrently.
    dispatch_task = asyncio.create_task(server._handle_reply(arguments))
    inject_task = asyncio.create_task(
        _inject_tool_result_after_push(
            server,
            fake,
            {
                "kind": "tool_result",
                "ok": True,
                "data": {"sent_to": "oc_x"},
            },
        )
    )
    await inject_task
    content = await dispatch_task

    # Assert push happened on the expected topic + event.
    assert len(fake.pushed) == 1
    topic, event, payload = fake.pushed[0]
    assert topic == "cli:channel/sid-abc"
    assert event == "envelope"
    assert payload["kind"] == "tool_invoke"
    assert payload["tool"] == "reply"
    assert payload["args"] == arguments
    assert isinstance(payload["req_id"], str) and len(payload["req_id"]) > 0

    # Assert the MCP CallToolResult content reflects the tool_result data.
    assert len(content) == 1
    parsed = json.loads(content[0].text)
    assert parsed == {"sent_to": "oc_x"}


@pytest.mark.asyncio
async def test_send_file_tool_dispatch():
    """send_file handler uses the same path with tool='send_file'."""
    server = BridgeMCPServer()
    server.set_session_id("sid-2")
    fake = _FakePhxClient()
    server.set_phx_client(fake)  # type: ignore[arg-type]

    arguments = {"chat_id": "oc_y", "file_path": "/tmp/file.txt"}

    dispatch_task = asyncio.create_task(server._handle_send_file(arguments))
    await _inject_tool_result_after_push(
        server,
        fake,
        {"kind": "tool_result", "ok": True, "data": {"uploaded": True}},
    )
    content = await dispatch_task

    _, _, payload = fake.pushed[0]
    assert payload["tool"] == "send_file"
    parsed = json.loads(content[0].text)
    assert parsed == {"uploaded": True}


@pytest.mark.asyncio
async def test_submit_slash_tool_dispatch():
    """submit_slash handler routes the slash command."""
    server = BridgeMCPServer()
    server.set_session_id("sid-3")
    fake = _FakePhxClient()
    server.set_phx_client(fake)  # type: ignore[arg-type]

    arguments = {"command": "/help", "chat_id": "oc_z"}

    dispatch_task = asyncio.create_task(server._handle_submit_slash(arguments))
    await _inject_tool_result_after_push(
        server,
        fake,
        {"kind": "tool_result", "ok": True, "data": {"queued": True}},
    )
    content = await dispatch_task

    _, _, payload = fake.pushed[0]
    assert payload["tool"] == "submit_slash"
    parsed = json.loads(content[0].text)
    assert parsed == {"queued": True}


@pytest.mark.asyncio
async def test_tool_error_result_translates_to_error_text():
    """ok:false tool_result surfaces as ok:false JSON content."""
    server = BridgeMCPServer()
    server.set_session_id("sid-err")
    fake = _FakePhxClient()
    server.set_phx_client(fake)  # type: ignore[arg-type]

    dispatch_task = asyncio.create_task(
        server._handle_reply({"chat_id": "oc_x", "text": "hi"})
    )
    await _inject_tool_result_after_push(
        server,
        fake,
        {
            "kind": "tool_result",
            "ok": False,
            "error": {"type": "rate_limited", "message": "slow down"},
        },
    )
    content = await dispatch_task
    parsed = json.loads(content[0].text)
    assert parsed["ok"] is False
    assert parsed["error"]["type"] == "rate_limited"


@pytest.mark.asyncio
async def test_phx_push_error_returns_error_content_without_waiting():
    """phx_reply with status=error fails fast — doesn't wait for tool_result."""
    server = BridgeMCPServer()
    server.set_session_id("sid-noway")
    fake = _FakePhxClient(ok=False)
    server.set_phx_client(fake)  # type: ignore[arg-type]

    content = await server._handle_reply({"chat_id": "oc_x", "text": "hi"})
    parsed = json.loads(content[0].text)
    assert parsed["ok"] is False
    assert parsed["error"]["type"] == "phx_push_error"
    # No leaked pending futures (cleaned up before return).
    assert server.pending_tool_calls == {}


@pytest.mark.asyncio
async def test_tool_call_timeout_returns_timeout_error(monkeypatch):
    """If no tool_result arrives, the handler returns a timeout error."""
    from cc_channel_runner import mcp_server as ms

    # Compress the timeout so the test is fast.
    monkeypatch.setattr(ms, "_TOOL_CALL_TIMEOUT_SECS", 0.05)

    server = BridgeMCPServer()
    server.set_session_id("sid-timeout")
    fake = _FakePhxClient()
    server.set_phx_client(fake)  # type: ignore[arg-type]

    content = await server._handle_reply({"chat_id": "oc_x", "text": "hi"})
    parsed = json.loads(content[0].text)
    assert parsed["ok"] is False
    assert parsed["error"]["type"] == "tool_result_timeout"
    assert server.pending_tool_calls == {}


@pytest.mark.asyncio
async def test_phx_client_unconfigured_returns_error():
    """No phx_client → fail closed, don't crash."""
    server = BridgeMCPServer()
    # No set_phx_client / set_session_id calls.
    content = await server._handle_reply({"chat_id": "oc_x", "text": "hi"})
    parsed = json.loads(content[0].text)
    assert parsed["error"]["type"] == "phx_client_not_configured"
