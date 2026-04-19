"""Tests for runtime_bridge.call_runtime — end-to-end against a fake
Phoenix WS that echoes pushes into phx_reply responses (Phase 8c)."""
from __future__ import annotations

import json
from typing import Any

import aiohttp
import pytest
from aiohttp import web


async def _phoenix_echo_handler(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    async for msg in ws:
        if msg.type != aiohttp.WSMsgType.TEXT:
            continue
        frame = json.loads(msg.data)
        join_ref, ref, topic, event, payload = frame
        if event == "phx_join":
            await ws.send_str(json.dumps(
                [join_ref, ref, topic, "phx_reply",
                 {"status": "ok", "response": {}}]))
        else:
            await ws.send_str(json.dumps(
                [join_ref, ref, topic, "phx_reply",
                 {"status": "ok",
                  "response": {"echoed_topic": topic,
                               "echoed_event": event,
                               "echoed_payload": payload}}]))
    return ws


@pytest.fixture
async def fake_phoenix() -> Any:  # type: ignore[misc]
    app = web.Application()
    app.router.add_get("/handler_hub/socket/websocket", _phoenix_echo_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    yield f"ws://127.0.0.1:{port}/handler_hub/socket/websocket"
    await runner.cleanup()


@pytest.mark.asyncio
async def test_call_runtime_end_to_end(fake_phoenix: str, monkeypatch: Any) -> None:
    """call_runtime() connects, joins, calls, returns reply, closes — all
    in one invocation. Verifies the CLI-facing sync wrapper is functional."""
    from esr.cli import runtime_bridge

    # Point the discover-url helper at our test server.
    monkeypatch.setenv("ESR_HANDLER_HUB_URL", fake_phoenix)

    # call_runtime is synchronous — inside an async test, run it in a thread
    # so the test's running loop isn't nested.
    import asyncio as _asyncio
    reply = await _asyncio.to_thread(
        runtime_bridge.call_runtime,
        topic="cli:probe",
        event="cli_call",
        payload={"hello": "world"},
        timeout_sec=5.0,
    )

    assert reply["status"] == "ok"
    assert reply["response"]["echoed_topic"] == "cli:probe"
    assert reply["response"]["echoed_event"] == "cli_call"
    assert reply["response"]["echoed_payload"] == {"hello": "world"}


def test_runtime_unreachable_surfaces_helpful_error(monkeypatch: Any) -> None:
    """When the runtime isn't reachable, RuntimeUnreachable is raised with
    the endpoint URL so the operator can diagnose."""
    from esr.cli.runtime_bridge import RuntimeUnreachable, call_runtime

    monkeypatch.setenv("ESR_HANDLER_HUB_URL",
                       "ws://127.0.0.1:1/bogus/socket/websocket")

    with pytest.raises(RuntimeUnreachable) as excinfo:
        call_runtime(topic="cli:probe", event="cli_call", payload={},
                     timeout_sec=2.0)
    assert "127.0.0.1:1" in str(excinfo.value)
