"""Phoenix Channel v2 WebSocket client for cc_channel_runner.

Connects to BEAM's `EsrWeb.ChannelChannel` (topic `cli:channel/<sid>`) and
provides a typed push/receive API. Smaller and more focused than the
cc-openclaw `ChannelClient` reference (no port-change reconnect, no
register-action protocol) — we speak the standard Phoenix Channels
serializer v2 wire format: a JSON array of
`[join_ref, ref, topic, event, payload]`.

Spec: docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, AsyncIterator

import websockets
from websockets.asyncio.client import ClientConnection

log = logging.getLogger("cc_channel_runner.phx_client")

# Heartbeat cadence. Phoenix's default server-side heartbeat timeout
# is 60s; 30s keeps us comfortably inside that window. Task 2.3 may
# wire actual heartbeat sending; for now we keep the structure so
# subsequent phases can flip it on without touching the public API.
_HEARTBEAT_INTERVAL_SECS = 30.0

# Retry cadence for the connect loop. Spec says 3 attempts with 1s/2s/4s
# backoff before surfacing an error.
_RECONNECT_BACKOFF_SECS = (1.0, 2.0, 4.0)


class PhoenixChannelClient:
    """Minimal Phoenix Channels v2 client.

    Wire format (Phoenix.Socket.V2.JSONSerializer):
        [join_ref, ref, topic, event, payload]

    Both `join_ref` and `ref` are monotonically increasing integers
    (stringified) minted by the client. Server replies preserve `ref`
    in `phx_reply` frames so callers can correlate responses to pushes.
    """

    def __init__(self, url: str) -> None:
        self.url = url
        self._ws: ClientConnection | None = None
        # Monotonic counter for ref/join_ref. Phoenix accepts string refs.
        self._ref_counter = 0
        # Topic → join_ref string (assigned at first phx_join).
        self._join_refs: dict[str, str] = {}
        # ref string → asyncio.Future awaiting matching phx_reply.
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        # Queue of inbound non-reply frames; receive() drains this.
        self._inbox: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        # Background tasks (recv loop, heartbeat).
        self._recv_task: asyncio.Task[None] | None = None
        self._heartbeat_task: asyncio.Task[None] | None = None
        self._closed = asyncio.Event()

    # -- public API ----------------------------------------------------

    async def connect(self) -> None:
        """Open the WebSocket with backoff retry.

        Three attempts at 1s / 2s / 4s; if all fail, re-raises the last
        exception. On success starts the recv loop + heartbeat loop.
        """
        last_exc: Exception | None = None
        for attempt, backoff in enumerate(_RECONNECT_BACKOFF_SECS):
            try:
                self._ws = await websockets.connect(self.url)
                log.info("connected url=%s (attempt %d)", self.url, attempt + 1)
                self._recv_task = asyncio.create_task(self._recv_loop())
                self._heartbeat_task = asyncio.create_task(self._heartbeat_loop())
                return
            except Exception as e:  # noqa: BLE001 — last_exc re-raised below
                last_exc = e
                log.warning(
                    "connect attempt %d failed (%s); sleeping %.1fs",
                    attempt + 1, e, backoff,
                )
                await asyncio.sleep(backoff)
        assert last_exc is not None
        raise last_exc

    async def join(self, topic: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        """Send `phx_join` on `topic` and await server's `phx_reply` ok.

        Returns the server's `response` map. Raises RuntimeError if the
        server replies with status != "ok".
        """
        if self._ws is None:
            raise RuntimeError("join() called before connect()")
        ref = self._next_ref()
        join_ref = ref  # Phoenix v2: join_ref == first ref for the topic.
        self._join_refs[topic] = join_ref
        reply = await self._push_and_await(
            join_ref=join_ref,
            ref=ref,
            topic=topic,
            event="phx_join",
            payload=payload or {},
        )
        status = reply.get("payload", {}).get("status")
        if status != "ok":
            raise RuntimeError(f"phx_join failed for {topic!r}: {reply!r}")
        log.info("phx_join ok topic=%s", topic)
        return reply.get("payload", {}).get("response", {})

    async def push(
        self,
        topic: str,
        event: str,
        payload: dict[str, Any],
    ) -> dict[str, Any]:
        """Push a frame and await its `phx_reply`.

        Returns the full server reply frame's payload (which is
        `{"status": "ok"|"error", "response": {...}}`).
        """
        if self._ws is None:
            raise RuntimeError("push() called before connect()")
        join_ref = self._join_refs.get(topic)
        if join_ref is None:
            raise RuntimeError(f"push() to topic {topic!r} before join()")
        ref = self._next_ref()
        reply = await self._push_and_await(
            join_ref=join_ref,
            ref=ref,
            topic=topic,
            event=event,
            payload=payload,
        )
        return reply.get("payload", {})

    async def receive(self) -> AsyncIterator[dict[str, Any]]:
        """Async iterator yielding inbound non-reply frames.

        Each item is a dict: `{join_ref, ref, topic, event, payload}`.
        Use this for server-pushed frames (e.g., `envelope` events on
        `cli:channel/<sid>`). `phx_reply` frames are routed to push()
        callers via their refs and never reach this iterator.
        """
        while not self._closed.is_set():
            frame = await self._inbox.get()
            yield frame

    async def close(self) -> None:
        """Clean shutdown: cancel background tasks, close WS."""
        self._closed.set()
        for task in (self._heartbeat_task, self._recv_task):
            if task is not None and not task.done():
                task.cancel()
                try:
                    await task
                except (asyncio.CancelledError, Exception):  # noqa: BLE001
                    pass
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:  # noqa: BLE001
                pass
            self._ws = None
        # Fail any pending futures so awaiters don't hang.
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(RuntimeError("phx_client closed"))
        self._pending.clear()

    # -- internals -----------------------------------------------------

    def _next_ref(self) -> str:
        self._ref_counter += 1
        return str(self._ref_counter)

    async def _push_and_await(
        self,
        *,
        join_ref: str,
        ref: str,
        topic: str,
        event: str,
        payload: dict[str, Any],
    ) -> dict[str, Any]:
        """Send a frame and await its matching phx_reply.

        The returned dict has shape `{join_ref, ref, topic, event,
        payload}` — the full inbound reply frame.
        """
        assert self._ws is not None
        frame: list[Any] = [join_ref, ref, topic, event, payload]
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[ref] = future
        try:
            await self._ws.send(json.dumps(frame))
            return await future
        finally:
            self._pending.pop(ref, None)

    async def _recv_loop(self) -> None:
        """Read frames, route phx_reply to futures, enqueue rest."""
        assert self._ws is not None
        try:
            async for raw in self._ws:
                try:
                    arr = json.loads(raw)
                except json.JSONDecodeError as e:
                    log.warning("phx recv: invalid JSON: %s", e)
                    continue
                if not isinstance(arr, list) or len(arr) != 5:
                    log.warning("phx recv: unexpected frame shape: %r", arr)
                    continue
                join_ref, ref, topic, event, payload = arr
                frame = {
                    "join_ref": join_ref,
                    "ref": ref,
                    "topic": topic,
                    "event": event,
                    "payload": payload,
                }
                if event == "phx_reply" and ref in self._pending:
                    fut = self._pending[ref]
                    if not fut.done():
                        fut.set_result(frame)
                else:
                    await self._inbox.put(frame)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            log.warning("phx recv loop ended: %s", e)

    async def _heartbeat_loop(self) -> None:
        """Send phoenix-topic heartbeats every _HEARTBEAT_INTERVAL_SECS.

        Phoenix's serializer v2 expects topic="phoenix" event="heartbeat"
        with `ref` set; `join_ref` is null for the synthetic phoenix
        topic. Task 2.3 may extend this; for now we send heartbeats
        only if the WS is up, swallowing any send errors (the recv loop
        will surface a real disconnect by exiting).
        """
        try:
            while not self._closed.is_set():
                await asyncio.sleep(_HEARTBEAT_INTERVAL_SECS)
                if self._ws is None or self._closed.is_set():
                    return
                ref = self._next_ref()
                frame = [None, ref, "phoenix", "heartbeat", {}]
                try:
                    await self._ws.send(json.dumps(frame))
                except Exception as e:  # noqa: BLE001
                    log.debug("heartbeat send failed: %s", e)
                    return
        except asyncio.CancelledError:
            raise
