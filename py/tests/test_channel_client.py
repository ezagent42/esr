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


async def test_channel_client_starts_heartbeat_task_on_connect() -> None:
    """PR-21l: connect() spawns a background heartbeat task that must
    survive close() without leaking exceptions.

    The full 30-second heartbeat interval is too long for a unit test;
    we just assert the task exists post-connect and is cancelled cleanly
    by close(). The on-wire heartbeat frame shape
    `[null, ref, "phoenix", "heartbeat", {}]` is verified by integration
    tests against esrd.
    """
    async with _phoenix_mock_server() as (url, _):
        client = ChannelClient(url)
        await client.connect()
        assert client._heartbeat_task is not None
        assert not client._heartbeat_task.done()

        await client.close()
        assert client._heartbeat_task is None


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


# --- PRD 03 F05: reconnect + pending-push queue ------------------------


async def test_push_queued_during_disconnect() -> None:
    """While disconnected, push() queues rather than raising."""
    client = ChannelClient("ws://127.0.0.1:1/does-not-exist")
    # Simulate post-join state + mid-disconnect without a live server
    client._topic_join_refs["handler:noop"] = "1"
    client._topic_handlers["handler:noop"] = lambda _: None
    client._is_disconnected = True

    await client.push("handler:noop", "hello", {"x": 1})
    await client.push("handler:noop", "hello", {"x": 2})

    pending = list(client._pending_pushes)
    assert len(pending) == 2
    assert pending[0][0] == "handler:noop"
    assert pending[0][1] == "hello"
    assert pending[1][2] == {"x": 2}


async def test_pending_queue_drops_oldest_on_overflow() -> None:
    """1001st pending push drops the oldest to stay bounded at 1000."""
    client = ChannelClient("ws://127.0.0.1:1/does-not-exist")
    client._topic_join_refs["t"] = "1"
    client._topic_handlers["t"] = lambda _: None
    client._is_disconnected = True

    for i in range(1001):
        await client.push("t", "e", {"i": i})

    pending = list(client._pending_pushes)
    assert len(pending) == 1000
    # The oldest (i=0) was dropped; the newest (i=1000) is kept
    assert pending[0][2] == {"i": 1}
    assert pending[-1][2] == {"i": 1000}


@contextlib.asynccontextmanager
async def _killswitch_server() -> AsyncIterator[tuple[str, list, asyncio.Event]]:
    """Phoenix mock whose WS is closed when the external event fires.

    The server accepts subsequent reconnections normally; ``received`` is
    shared across connections so tests can assert the flow end-to-end.
    """
    received: list[list[Any]] = []
    kill = asyncio.Event()

    async def handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        # Serve frames until kill fires; then close the WS.
        reader_task = asyncio.create_task(_serve_frames(ws, received))
        kill_task = asyncio.create_task(kill.wait())
        done, pending = await asyncio.wait(
            [reader_task, kill_task],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for t in pending:
            t.cancel()
        if kill_task in done:
            await ws.close()
            kill.clear()  # reset for subsequent connections
        return ws

    async def _serve_frames(
        ws: web.WebSocketResponse, acc: list[list[Any]]
    ) -> None:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            frame = json.loads(msg.data)
            acc.append(frame)
            join_ref, ref, topic, event, _payload = frame
            if event == "phx_join":
                reply = [
                    join_ref,
                    ref,
                    topic,
                    "phx_reply",
                    {"status": "ok", "response": {}},
                ]
                await ws.send_str(json.dumps(reply))

    app = web.Application()
    app.router.add_get("/socket/websocket", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host="127.0.0.1", port=0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    url = f"ws://127.0.0.1:{port}/socket/websocket"
    try:
        yield url, received, kill
    finally:
        await runner.cleanup()


@contextlib.asynccontextmanager
async def _noisy_server() -> AsyncIterator[str]:
    """Server that emits a garbage frame to the client BEFORE the phx_reply.

    Used to verify the client's read loop recovers from a single bad
    frame instead of closing the socket and reconnecting (reviewer S7).
    """

    async def handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            frame = json.loads(msg.data)
            join_ref, ref, topic, event, _payload = frame
            if event == "phx_join":
                # First: garbage — invalid JSON. Client must discard.
                await ws.send_str("{not-valid-json]")
                # Second: wrong-arity but valid JSON.
                await ws.send_str(json.dumps(["too", "short"]))
                # Finally: the legitimate phx_reply.
                await ws.send_str(
                    json.dumps([join_ref, ref, topic, "phx_reply",
                                {"status": "ok", "response": {}}])
                )
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


async def test_channel_client_tolerates_malformed_frames(caplog: Any) -> None:
    """Reviewer S7: a garbage frame must not kill the read loop."""
    async with _noisy_server() as url:
        client = ChannelClient(url, auto_reconnect=False)
        await client.connect()
        # The join completes even though the client saw two bad frames
        # before the real reply. If the read loop tore down the socket
        # on the first exception, join() would time out.
        result = await asyncio.wait_for(
            client.join("handler:noisy", on_msg=lambda _: None),
            timeout=2.0,
        )
        assert result["status"] == "ok"
        assert client.connected is True  # still connected, not reconnected
        await client.close()


async def test_reconnect_rejoins_and_flushes_pending() -> None:
    """Server close → client reconnects, re-joins topics, flushes pending pushes."""
    async with _killswitch_server() as (url, received, kill):
        client = ChannelClient(
            url, auto_reconnect=True, backoff_schedule=[0.05, 0.1]
        )
        await client.connect()
        await client.join("handler:noop", on_msg=lambda _: None)

        # Kill the first WS; the client should detect and start reconnecting.
        kill.set()
        # Give the client a moment to notice the close
        await asyncio.sleep(0.05)
        assert client._is_disconnected is True

        # Push while disconnected → queued, not raised
        await client.push("handler:noop", "late", {"x": 42})

        # Wait for reconnect to complete (with a generous cap)
        deadline = asyncio.get_event_loop().time() + 2.0
        while (
            client._is_disconnected
            and asyncio.get_event_loop().time() < deadline
        ):
            await asyncio.sleep(0.02)
        assert client._is_disconnected is False, "client never reconnected"

        # Let the queued push flush
        await asyncio.sleep(0.1)
        await client.close()

    # Second connection must have seen a phx_join + the queued push
    second_conn_frames = [f for f in received if f[3] in ("phx_join", "late")]
    events = [f[3] for f in second_conn_frames]
    # The original connection's phx_join is the first; the reconnect's is later.
    assert events.count("phx_join") >= 2
    assert "late" in events
