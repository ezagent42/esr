"""Unit tests for cc_channel_runner.phx_client."""

import asyncio
import json

import pytest
import websockets

from cc_channel_runner.phx_client import PhoenixChannelClient


@pytest.mark.asyncio
async def test_phx_join_acked():
    """Bridge sends phx_join and receives phx_reply ok."""
    received: list[list] = []

    async def handler(ws):
        async for msg in ws:
            frame = json.loads(msg)
            received.append(frame)
            join_ref, ref, topic, event, _payload = frame
            if event == "phx_join":
                reply = [
                    join_ref,
                    ref,
                    topic,
                    "phx_reply",
                    {"status": "ok", "response": {}},
                ]
                await ws.send(json.dumps(reply))

    async with websockets.serve(handler, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        client = PhoenixChannelClient(
            f"ws://127.0.0.1:{port}/channel/socket/websocket?vsn=2.0.0"
        )
        await client.connect()
        try:
            await client.join("cli:channel/test-sid")
            # Give the server handler a tick to flush its receive list.
            await asyncio.sleep(0.05)
            assert any(f[3] == "phx_join" for f in received), (
                "phx_join frame should have been sent"
            )
            # Verify wire format: [join_ref, ref, topic, event, payload]
            join_frame = next(f for f in received if f[3] == "phx_join")
            assert len(join_frame) == 5
            assert join_frame[2] == "cli:channel/test-sid"
            assert join_frame[4] == {}
        finally:
            await client.close()
