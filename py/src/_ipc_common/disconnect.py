"""Cancellable WS disconnect watcher (shared by adapter + handler IPC).

Polls ``client.connected`` every ``poll_interval`` seconds. When the
flag flips False (e.g. aiohttp's read loop exits because the server
closed the socket), raises :class:`ConnectionError` so the enclosing
TaskGroup unwinds and the reconnect loop can attempt a fresh connect.
The wall-clock ceiling on disconnect detection is ~``poll_interval``.

Fake test clients without a ``connected`` attribute are tolerated by
treating ``getattr`` misses as "still connected".
"""
from __future__ import annotations

import asyncio
from typing import Any


async def watch_disconnect(client: Any, poll_interval: float = 0.1) -> None:
    while True:
        if not getattr(client, "connected", True):
            raise ConnectionError("ws disconnected")
        await asyncio.sleep(poll_interval)
