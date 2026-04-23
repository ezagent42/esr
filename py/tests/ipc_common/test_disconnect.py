"""watch_disconnect raises ConnectionError when client.connected flips False.

The function is a 3-line loop with an ``await asyncio.sleep`` — we verify
its observable contract: (a) it keeps running while client.connected is
True or missing, (b) it raises ConnectionError promptly once the flag
flips False.
"""
from __future__ import annotations

import asyncio

import pytest

from _ipc_common.disconnect import watch_disconnect


class _FakeClient:
    def __init__(self) -> None:
        self.connected = True


@pytest.mark.asyncio
async def test_raises_connection_error_on_flip() -> None:
    client = _FakeClient()
    task = asyncio.create_task(watch_disconnect(client, poll_interval=0.01))
    await asyncio.sleep(0.02)
    assert not task.done()
    client.connected = False
    with pytest.raises(ConnectionError):
        await asyncio.wait_for(task, timeout=0.1)


@pytest.mark.asyncio
async def test_tolerates_client_without_connected_attr() -> None:
    """Real test clients may not set ``connected``. Treat absence as alive."""
    class Bare:
        pass

    task = asyncio.create_task(watch_disconnect(Bare(), poll_interval=0.01))
    await asyncio.sleep(0.03)
    assert not task.done()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
