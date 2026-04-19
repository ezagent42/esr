"""Tests for ChannelClient.call() — push + await phx_reply."""
from __future__ import annotations

import json
from typing import Any

import aiohttp
import pytest
from aiohttp import web


async def _phoenix_echo(ws: web.WebSocketResponse) -> None:
    """Test Phoenix handler: replies to phx_join OK; to any push, replies with
    phx_reply status=ok + echoed payload."""
    async for msg in ws:
        if msg.type != aiohttp.WSMsgType.TEXT:
            continue
        frame = json.loads(msg.data)
        join_ref, ref, topic, event, payload = frame
        if event == "phx_join":
            reply = [join_ref, ref, topic, "phx_reply",
                     {"status": "ok", "response": {}}]
        else:
            reply = [join_ref, ref, topic, "phx_reply",
                     {"status": "ok", "response": {"echoed": payload}}]
        await ws.send_str(json.dumps(reply))


async def _app() -> web.Application:
    async def handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        await _phoenix_echo(ws)
        return ws

    app = web.Application()
    app.router.add_get("/ws", handler)
    return app


@pytest.mark.asyncio
async def test_channel_client_call_returns_phx_reply_response() -> None:
    from esr.ipc.channel_client import ChannelClient

    app = await _app()
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    url = f"ws://127.0.0.1:{port}/ws"

    try:
        client = ChannelClient(url)
        await client.connect()
        received_frames: list[list[Any]] = []
        await client.join("cli:test", received_frames.append)

        resp = await client.call("cli:test", "probe",
                                 {"hello": "world"})

        assert resp.get("status") == "ok"
        assert resp.get("response") == {"echoed": {"hello": "world"}}

        await client.close()
    finally:
        await runner.cleanup()
