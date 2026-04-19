"""Phoenix Channels v2 client over aiohttp (PRD 03 F04 / F06).

Minimal v2-dialect client for talking to Phoenix Channels from a
Python process. The wire format is a JSON array::

    [join_ref, ref, topic, event, payload]

``join_ref`` is assigned when joining a topic and stays constant for
all subsequent pushes on that topic; ``ref`` auto-increments per
message and is echoed back by the server inside ``phx_reply``
payloads so client-side futures can correlate.

F04 contract:
 - ``connect()`` opens the WS.
 - ``join(topic, on_msg)`` sends ``phx_join`` and awaits ``phx_reply``
   with status ``ok``; rejection raises ``RuntimeError``.
 - ``push(topic, event, payload)`` sends a frame on an already-joined
   topic; push-before-join raises ``ValueError``.
 - ``close()`` tears down the read loop, WS, and aiohttp session.

F05 (reconnect with exponential backoff + pending-push queue) is
intentionally deferred — it will layer on top of this minimum-viable
client without changing its public API.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
from collections.abc import Callable
from typing import Any

import aiohttp

FrameCallback = Callable[[list[Any]], None]


class ChannelClient:
    """Phoenix Channels v2 client with multi-topic multiplexing."""

    def __init__(self, url: str) -> None:
        self._url = url
        self._session: aiohttp.ClientSession | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._reader_task: asyncio.Task[None] | None = None

        self._ref_counter = itertools.count(1)
        self._topic_join_refs: dict[str, str] = {}
        self._topic_handlers: dict[str, FrameCallback] = {}
        self._pending_replies: dict[str, asyncio.Future[dict[str, Any]]] = {}

    @property
    def connected(self) -> bool:
        """True once ``connect()`` has opened the WS and not yet closed."""
        return self._ws is not None and not self._ws.closed

    # --- lifecycle -----------------------------------------------------

    async def connect(self) -> None:
        """Open the WS and start the read loop."""
        self._session = aiohttp.ClientSession()
        self._ws = await self._session.ws_connect(self._url)
        self._reader_task = asyncio.create_task(self._read_loop())

    async def close(self) -> None:
        """Cancel the read loop and close the WS + session."""
        if self._reader_task is not None:
            self._reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._reader_task
            self._reader_task = None
        if self._ws is not None:
            await self._ws.close()
            self._ws = None
        if self._session is not None:
            await self._session.close()
            self._session = None

    # --- channel API ---------------------------------------------------

    async def join(self, topic: str, on_msg: FrameCallback) -> dict[str, Any]:
        """Join ``topic`` and await a phx_reply with ok status.

        ``on_msg`` is invoked with every non-reply frame that arrives on
        the topic. Raises ``RuntimeError`` if the server replies with
        status ``error``.
        """
        if self._ws is None:
            raise RuntimeError("join() called before connect()")
        ref = str(next(self._ref_counter))
        join_ref = ref  # v2: initial ref doubles as the topic's join_ref
        self._topic_join_refs[topic] = join_ref
        self._topic_handlers[topic] = on_msg

        fut: asyncio.Future[dict[str, Any]] = asyncio.get_event_loop().create_future()
        self._pending_replies[ref] = fut
        await self._send_frame([join_ref, ref, topic, "phx_join", {}])
        reply = await fut

        if reply.get("status") != "ok":
            self._topic_join_refs.pop(topic, None)
            self._topic_handlers.pop(topic, None)
            raise RuntimeError(f"join rejected: {reply!r}")
        return reply

    async def push(self, topic: str, event: str, payload: dict[str, Any]) -> None:
        """Send an event on an already-joined topic."""
        join_ref = self._topic_join_refs.get(topic)
        if join_ref is None:
            raise ValueError(f"push to topic {topic!r}: not joined")
        ref = str(next(self._ref_counter))
        await self._send_frame([join_ref, ref, topic, event, payload])

    # --- internals -----------------------------------------------------

    async def _send_frame(self, frame: list[Any]) -> None:
        if self._ws is None:
            raise RuntimeError("ws not connected")
        await self._ws.send_str(json.dumps(frame))

    async def _read_loop(self) -> None:
        assert self._ws is not None
        try:
            async for msg in self._ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    continue
                frame = json.loads(msg.data)
                _join_ref, ref, topic, event, payload = frame
                if event == "phx_reply":
                    fut = self._pending_replies.pop(ref, None)
                    if fut is not None and not fut.done():
                        fut.set_result(payload)
                    continue
                handler = self._topic_handlers.get(topic)
                if handler is not None:
                    handler(frame)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 — protect the read loop, let close() unwind
            return
