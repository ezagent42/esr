"""Round-trip tests for the CLI → runtime _submit_* helpers — guards
reviewer-C1 (wrong nesting: helpers expected flat, dispatches wrap in
'data'). Each test stands up a fake aiohttp WebSocket that replies
with the exact dispatch shape the real Elixir side returns, then
invokes the helper and asserts the flat handle dict the CLI
command consumer expects.

Named `test_cli_submit_roundtrip.py` so LG-9/LG-10 (scoped to
`test_cli_cmd_*.py`) don't require an esrd_fixture — these are
IPC-layer tests, not CLI click tests.
"""
from __future__ import annotations

import json
from collections.abc import Awaitable, Callable
from typing import Any

import aiohttp
import pytest
from aiohttp import web


async def _start_fake_runtime(
    reply_body: dict[str, Any],
) -> tuple[str, web.AppRunner]:
    """Start a minimal Phoenix-v2 echo WS that replies phx_reply with the
    supplied ``response`` body to any non-join push. Returns (url, runner)."""
    async def handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        async for msg in ws:
            if msg.type != aiohttp.WSMsgType.TEXT:
                continue
            join_ref, ref, topic, event, _payload = json.loads(msg.data)
            if event == "phx_join":
                await ws.send_str(json.dumps(
                    [join_ref, ref, topic, "phx_reply",
                     {"status": "ok", "response": {}}]))
            else:
                await ws.send_str(json.dumps(
                    [join_ref, ref, topic, "phx_reply",
                     {"status": "ok", "response": reply_body}]))
        return ws

    app = web.Application()
    app.router.add_get("/handler_hub/socket/websocket", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    return f"ws://127.0.0.1:{port}/handler_hub/socket/websocket", runner


async def _with_fake_runtime(
    reply_body: dict[str, Any],
    run_helper: Callable[[], Awaitable[Any]],
    monkeypatch: Any,
) -> Any:
    url, runner = await _start_fake_runtime(reply_body)
    monkeypatch.setenv("ESR_HANDLER_HUB_URL", url)
    try:
        return await run_helper()
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_submit_cmd_run_unwraps_data_nesting(monkeypatch: Any) -> None:
    """Reviewer C1: dispatch returns {"data": {"peer_ids": [...]}}; the
    helper must peel 'data' — not resp.get('peer_ids') flat."""
    import asyncio as _asyncio

    from esr.cli.main import _submit_cmd_run

    dispatch_shape = {
        "data": {
            "name": "feishu-thread-session",
            "params": {"thread_id": "a"},
            "peer_ids": ["thread:a", "tmux:a", "cc:a"],
        }
    }

    def run() -> dict[str, Any]:
        return _submit_cmd_run(
            {"name": "feishu-thread-session"},
            {"thread_id": "a"},
        )

    result = await _with_fake_runtime(
        dispatch_shape,
        lambda: _asyncio.to_thread(run),
        monkeypatch,
    )
    assert result == {
        "name": "feishu-thread-session",
        "params": {"thread_id": "a"},
        "peer_ids": ["thread:a", "tmux:a", "cc:a"],
    }


@pytest.mark.asyncio
async def test_submit_cmd_stop_unwraps_data_nesting(monkeypatch: Any) -> None:
    import asyncio as _asyncio

    from esr.cli.main import _submit_cmd_stop

    dispatch_shape = {
        "data": {
            "name": "feishu-thread-session",
            "params": {"thread_id": "a"},
            "stopped_peer_ids": ["thread:a", "tmux:a", "cc:a"],
        }
    }

    def run() -> dict[str, Any]:
        return _submit_cmd_stop("feishu-thread-session", {"thread_id": "a"})

    result = await _with_fake_runtime(
        dispatch_shape,
        lambda: _asyncio.to_thread(run),
        monkeypatch,
    )
    assert result["stopped_peer_ids"] == ["thread:a", "tmux:a", "cc:a"]


@pytest.mark.asyncio
async def test_submit_drain_unwraps_data_nesting(monkeypatch: Any) -> None:
    import asyncio as _asyncio

    from esr.cli.main import _submit_drain

    dispatch_shape = {"data": {"drained": 3, "timeouts": []}}

    def run() -> dict[str, Any]:
        return _submit_drain(timeout=None)

    result = await _with_fake_runtime(
        dispatch_shape,
        lambda: _asyncio.to_thread(run),
        monkeypatch,
    )
    assert result == {"drained": 3, "timeouts": []}
