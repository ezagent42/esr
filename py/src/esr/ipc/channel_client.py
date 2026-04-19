"""Phoenix Channels v2 client over aiohttp (PRD 03 F04 / F05 / F06).

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
 - ``close()`` tears down everything cleanly.

F05 contract (``auto_reconnect=True``):
 - On WS disconnect, schedule a reconnect task with exponential
   backoff (default 1s, 2s, 4s, 8s, capped at 30s).
 - ``push()`` calls during the disconnect window queue into a
   bounded deque (``PENDING_PUSH_CAP``, default 1000); overflow drops
   oldest. This matches PRD 03 F05's exact numbers.
 - On reconnect, previously-joined topics are re-joined (fresh refs)
   and the pending-push queue is flushed in FIFO order.
 - ``close()`` disables further reconnection attempts.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
import logging
from collections import deque
from collections.abc import Callable
from typing import Any

import aiohttp

FrameCallback = Callable[[list[Any]], None]

logger = logging.getLogger(__name__)

PENDING_PUSH_CAP: int = 1000
"""Max queued pushes during disconnect (PRD 03 F05). Overflow drops oldest."""

DEFAULT_BACKOFF_SCHEDULE: tuple[float, ...] = (1.0, 2.0, 4.0, 8.0, 16.0, 30.0)
"""Exponential backoff sequence; final value repeats for further attempts."""


class ChannelClient:
    """Phoenix Channels v2 client with multi-topic multiplexing + reconnect."""

    def __init__(
        self,
        url: str,
        *,
        auto_reconnect: bool = False,
        backoff_schedule: tuple[float, ...] | list[float] = DEFAULT_BACKOFF_SCHEDULE,
    ) -> None:
        self._url = url
        self._auto_reconnect = auto_reconnect
        self._backoff_schedule = tuple(backoff_schedule) or DEFAULT_BACKOFF_SCHEDULE

        self._session: aiohttp.ClientSession | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._reconnect_task: asyncio.Task[None] | None = None
        self._shutdown: bool = False

        self._ref_counter = itertools.count(1)
        self._topic_join_refs: dict[str, str] = {}
        self._topic_handlers: dict[str, FrameCallback] = {}
        self._pending_replies: dict[str, asyncio.Future[dict[str, Any]]] = {}

        # F05 state
        self._is_disconnected: bool = False
        self._pending_pushes: deque[tuple[str, str, dict[str, Any]]] = deque(
            maxlen=PENDING_PUSH_CAP
        )

    @property
    def connected(self) -> bool:
        """True once ``connect()`` has opened the WS and not yet closed."""
        return self._ws is not None and not self._ws.closed

    # --- lifecycle -----------------------------------------------------

    async def connect(self) -> None:
        """Open the WS and start the read loop."""
        self._session = aiohttp.ClientSession()
        self._ws = await self._session.ws_connect(self._url)
        self._is_disconnected = False
        self._reader_task = asyncio.create_task(self._read_loop())

    async def close(self) -> None:
        """Cancel all tasks, close the WS + session, stop reconnection."""
        self._shutdown = True
        for task in (self._reader_task, self._reconnect_task):
            if task is not None:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
        self._reader_task = None
        self._reconnect_task = None
        if self._ws is not None:
            await self._ws.close()
            self._ws = None
        if self._session is not None:
            await self._session.close()
            self._session = None

    # --- channel API ---------------------------------------------------

    async def join(self, topic: str, on_msg: FrameCallback) -> dict[str, Any]:
        """Join ``topic`` and await a phx_reply with ok status."""
        if self._ws is None:
            raise RuntimeError("join() called before connect()")
        return await self._join_internal(topic, on_msg)

    async def _join_internal(
        self, topic: str, on_msg: FrameCallback
    ) -> dict[str, Any]:
        """join() body — reused by reconnect to re-join on the new WS."""
        ref = str(next(self._ref_counter))
        join_ref = ref
        self._topic_join_refs[topic] = join_ref
        self._topic_handlers[topic] = on_msg

        fut: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending_replies[ref] = fut
        await self._send_frame([join_ref, ref, topic, "phx_join", {}])
        reply = await fut

        if reply.get("status") != "ok":
            self._topic_join_refs.pop(topic, None)
            self._topic_handlers.pop(topic, None)
            raise RuntimeError(f"join rejected: {reply!r}")
        return reply

    async def push(self, topic: str, event: str, payload: dict[str, Any]) -> None:
        """Send an event on an already-joined topic.

        While disconnected (F05), queue into the bounded pending buffer
        rather than raising or blocking indefinitely. The reconnect
        loop flushes the queue in FIFO order.
        """
        join_ref = self._topic_join_refs.get(topic)
        if join_ref is None:
            raise ValueError(f"push to topic {topic!r}: not joined")
        if self._is_disconnected:
            if len(self._pending_pushes) == PENDING_PUSH_CAP:
                dropped = self._pending_pushes.popleft()
                logger.warning(
                    "pending-push queue full; dropping oldest %r", dropped
                )
            self._pending_pushes.append((topic, event, payload))
            return
        ref = str(next(self._ref_counter))
        await self._send_frame([join_ref, ref, topic, event, payload])

    async def call(
        self,
        topic: str,
        event: str,
        payload: dict[str, Any],
        *,
        timeout: float = 30.0,
    ) -> dict[str, Any]:
        """Push + await matching phx_reply. Returns the reply payload dict
        (keys ``status`` + ``response``). Raises :class:`TimeoutError` on
        timeout; raises :class:`ValueError` on push-before-join.
        """
        join_ref = self._topic_join_refs.get(topic)
        if join_ref is None:
            raise ValueError(f"call on topic {topic!r}: not joined")
        ref = str(next(self._ref_counter))
        fut: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending_replies[ref] = fut
        try:
            await self._send_frame([join_ref, ref, topic, event, payload])
            return await asyncio.wait_for(fut, timeout=timeout)
        finally:
            self._pending_replies.pop(ref, None)

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
                # Per-message recovery (reviewer S7): a single malformed
                # frame must not kill the loop — log and move on. Only
                # genuine socket failures fall through to reconnect.
                try:
                    frame = json.loads(msg.data)
                    _join_ref, ref, topic, event, payload = frame
                except (ValueError, TypeError) as exc:
                    logger.warning("bad frame: %r; continuing", exc)
                    continue

                if event == "phx_reply":
                    fut = self._pending_replies.pop(ref, None)
                    if fut is not None and not fut.done():
                        fut.set_result(payload)
                    continue
                handler = self._topic_handlers.get(topic)
                if handler is not None:
                    try:
                        handler(frame)
                    except Exception as exc:  # noqa: BLE001
                        logger.warning("topic handler error: %r; continuing", exc)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 — protect the read loop
            logger.warning("read loop error: %r", exc)

        # WS closed (cleanly or not). If auto_reconnect and not shutting
        # down, schedule the reconnect task.
        self._is_disconnected = True
        if self._auto_reconnect and not self._shutdown:
            logger.warning("ws closed; scheduling reconnect")
            self._reconnect_task = asyncio.create_task(self._reconnect_loop())

    async def _reconnect_loop(self) -> None:
        """Backoff-and-retry until reconnected, then re-join + flush."""
        attempt = 0
        while not self._shutdown:
            delay = self._backoff_schedule[
                min(attempt, len(self._backoff_schedule) - 1)
            ]
            await asyncio.sleep(delay)
            attempt += 1
            try:
                # Tear down any lingering state
                if self._ws is not None:
                    with contextlib.suppress(Exception):
                        await self._ws.close()
                if self._session is not None:
                    with contextlib.suppress(Exception):
                        await self._session.close()

                # New session + WS
                self._session = aiohttp.ClientSession()
                self._ws = await self._session.ws_connect(self._url)
                self._is_disconnected = False
                self._reader_task = asyncio.create_task(self._read_loop())

                # Re-join previously-joined topics (fresh refs)
                # Iterate over a snapshot to avoid mutation during re-join
                rejoined_handlers = dict(self._topic_handlers)
                self._topic_join_refs.clear()
                self._topic_handlers.clear()
                for topic, on_msg in rejoined_handlers.items():
                    try:
                        await self._join_internal(topic, on_msg)
                    except Exception as exc:  # noqa: BLE001
                        logger.warning("re-join of %r failed: %r", topic, exc)

                # Flush pending pushes in FIFO order
                while self._pending_pushes:
                    topic, event, payload = self._pending_pushes.popleft()
                    try:
                        await self.push(topic, event, payload)
                    except Exception as exc:  # noqa: BLE001
                        logger.warning(
                            "flushing pending push to %r/%r failed: %r",
                            topic,
                            event,
                            exc,
                        )
                return
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "reconnect attempt %d failed: %r; next delay %.1fs",
                    attempt,
                    exc,
                    self._backoff_schedule[
                        min(attempt, len(self._backoff_schedule) - 1)
                    ],
                )
