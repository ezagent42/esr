"""PRD 03 F04 — Phoenix channel client."""

from __future__ import annotations

import asyncio
import contextlib
import json
from collections.abc import AsyncIterator
from typing import Any

import pytest
from aiohttp import WSMsgType, web

from esr.ipc.channel_client import ChannelClient


@contextlib.asynccontextmanager
async def _phoenix_mock_server(behaviour: str = "ok") -> AsyncIterator[tuple[str, list]]:
    """Run an aiohttp WS server that speaks a minimal Phoenix v2 dialect.

    Yields (ws_url, received) — the URL to connect to and a list that
    accumulates every frame the server sees, in arrival order.
    """
    received: list[list[Any]] = []

    async def handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            frame = json.loads(msg.data)
            received.append(frame)
            join_ref, ref, topic, event, _payload = frame
            if event == "phx_join":
                status = "ok" if behaviour == "ok" else "error"
                reply = [
                    join_ref,
                    ref,
                    topic,
                    "phx_reply",
                    {"status": status, "response": {}},
                ]
                await ws.send_str(json.dumps(reply))
        return ws

    app = web.Application()
    app.router.add_get("/socket/websocket", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host="127.0.0.1", port=0)
    await site.start()
    # Retrieve the bound port — aiohttp exposes it via the site's server
    port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    url = f"ws://127.0.0.1:{port}/socket/websocket"
    try:
        yield url, received
    finally:
        await runner.cleanup()


async def test_channel_client_connect_and_close() -> None:
    """connect() opens WS; close() shuts down cleanly."""
    async with _phoenix_mock_server() as (url, _):
        client = ChannelClient(url)
        await client.connect()
        assert client.connected is True
        await client.close()
        assert client.connected is False


async def test_channel_client_join_gets_phx_reply_ok() -> None:
    """join() sends phx_join and awaits a matching phx_reply with status ok."""
    async with _phoenix_mock_server() as (url, received):
        client = ChannelClient(url)
        await client.connect()
        result = await client.join("handler:noop", on_msg=lambda _: None)
        assert result == {"status": "ok", "response": {}}
        assert received[0][2] == "handler:noop"
        assert received[0][3] == "phx_join"
        await client.close()


async def test_channel_client_push_uses_topic_join_ref() -> None:
    """After joining, push() sends [join_ref, ref, topic, event, payload]."""
    async with _phoenix_mock_server() as (url, received):
        client = ChannelClient(url)
        await client.connect()
        await client.join("handler:noop", on_msg=lambda _: None)
        await client.push("handler:noop", "hello", {"x": 1})
        # Allow the event loop to deliver the send to the mock
        await asyncio.sleep(0.05)
        await client.close()

    # received[0] = phx_join, received[1] = push("hello")
    assert len(received) >= 2
    join_frame = received[0]
    push_frame = received[1]
    assert push_frame[3] == "hello"
    assert push_frame[4] == {"x": 1}
    # join_ref is stable across the join + push for that topic
    assert push_frame[0] == join_frame[0]
    # ref auto-increments (push ref > join ref)
    assert int(push_frame[1]) > int(join_frame[1])


async def test_channel_client_push_to_unjoined_topic_raises() -> None:
    """push() before join() on a topic raises ValueError."""
    async with _phoenix_mock_server() as (url, _):
        client = ChannelClient(url)
        await client.connect()
        with pytest.raises(ValueError, match=r"not joined"):
            await client.push("handler:other", "hello", {})
        await client.close()


async def test_channel_client_join_error_status_raises() -> None:
    """If the server replies {status: 'error'}, join() raises RuntimeError."""
    async with _phoenix_mock_server(behaviour="error") as (url, _):
        client = ChannelClient(url)
        await client.connect()
        with pytest.raises(RuntimeError, match=r"join rejected"):
            await client.join("handler:bad", on_msg=lambda _: None)
        await client.close()


# --- PRD 03 F06: blocking join ------------------------------------------


@contextlib.asynccontextmanager
async def _slow_reply_server(delay_s: float) -> AsyncIterator[str]:
    """Phoenix mock that holds the phx_reply for ``delay_s`` seconds."""

    async def handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            frame = json.loads(msg.data)
            join_ref, ref, topic, event, _payload = frame
            if event == "phx_join":
                await asyncio.sleep(delay_s)
                reply = [
                    join_ref,
                    ref,
                    topic,
                    "phx_reply",
                    {"status": "ok", "response": {}},
                ]
                await ws.send_str(json.dumps(reply))
        return ws

    app = web.Application()
    app.router.add_get("/socket/websocket", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host="127.0.0.1", port=0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    try:
        yield f"ws://127.0.0.1:{port}/socket/websocket"
    finally:
        await runner.cleanup()


async def test_channel_client_join_blocks_until_reply() -> None:
    """join() doesn't return until the server's phx_reply arrives."""
    delay = 0.1
    async with _slow_reply_server(delay) as url:
        client = ChannelClient(url)
        await client.connect()
        start = asyncio.get_event_loop().time()
        await client.join("handler:noop", on_msg=lambda _: None)
        elapsed = asyncio.get_event_loop().time() - start
        await client.close()

    # Within a small tolerance, the full delay must have elapsed
    assert elapsed >= delay * 0.9
