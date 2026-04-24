"""PR-9 T9: mock_feishu exposes /ws_clients count for sidecar-ready probe.

E2E RCA: scenario 01 step 2 calls `POST /push_inbound` right after esrd
boot. The Python feishu_adapter_runner subprocess hasn't finished its
`connect → join adapter:feishu/<id> → handler_hello → ws_connect(/ws)`
dance yet, so mock_feishu.push_inbound pushes to an empty _ws_clients
list and the message is lost — step 2's sent_messages 'ack' assertion
then times out.

The bash-side `wait_for_sidecar_ready` helper polls this endpoint until
the adapter is observed connected. `_ws_clients >= 1` is the strongest
single readiness signal: the adapter's event_loop (which opens the
mock_feishu WS) only runs after Phoenix join + handler_hello succeed,
so a non-zero count implies the full chain is up.
"""
from __future__ import annotations

import sys
from pathlib import Path

import aiohttp
import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from mock_feishu import MockFeishu  # noqa: E402


@pytest.mark.asyncio
async def test_ws_clients_count_zero_before_any_connection() -> None:
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        async with aiohttp.ClientSession() as sess:
            async with sess.get(f"{base_url}/ws_clients") as resp:
                assert resp.status == 200
                body = await resp.json()
                assert body == {"count": 0}
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_ws_clients_count_reflects_connected_clients() -> None:
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    ws_url = base_url.replace("http://", "ws://") + "/ws"
    try:
        async with aiohttp.ClientSession() as sess:
            async with sess.ws_connect(ws_url):
                # Give the server a moment to register the client in the
                # _ws_clients list — same pattern as the adapter's event_loop.
                import asyncio

                await asyncio.sleep(0.05)

                async with sess.get(f"{base_url}/ws_clients") as resp:
                    body = await resp.json()
                    assert body == {"count": 1}

            # After the `async with` exits, the WS is closed; the server
            # removes it from _ws_clients on its read loop termination.
            import asyncio

            for _ in range(50):
                async with sess.get(f"{base_url}/ws_clients") as resp:
                    body = await resp.json()
                    if body["count"] == 0:
                        break
                await asyncio.sleep(0.02)
            else:
                pytest.fail(f"client never removed; final count={body['count']}")
    finally:
        await mock.stop()
