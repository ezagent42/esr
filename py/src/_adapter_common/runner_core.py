"""Core adapter-runner dispatch machinery (extracted from ``esr.ipc.adapter_runner``).

PRD 03 F09 / F10; spec §5.3. A Python adapter process runs two
concurrent coroutines:

- :func:`directive_loop` — consumes directive envelopes from a queue
  (filled by the ChannelClient's receive callback), invokes
  ``adapter.on_directive(action, args)``, and pushes a
  ``directive_ack`` envelope back via the pusher. **Strictly FIFO**:
  the next directive does not start until the previous one has
  produced its ack (F10).
- :func:`event_loop` — consumes events from ``adapter.emit_events()``
  (an async generator), wraps each dict as an ``event`` envelope,
  and pushes it. Events may interleave with acks on the wire —
  FIFO applies per-loop, not cross-loop.

The two loops share a pusher protocol: anything with ``source_uri: str``
and ``async def push_envelope(env)``. That keeps this module testable
without the real :class:`ChannelClient`.

:func:`run` is the full orchestration entry point — loads an adapter
factory via :func:`esr.adapters.load_adapter_factory`, constructs a
:class:`ChannelClient`, and delegates to :func:`run_with_reconnect`
(spec §5.3 F13 + §5.4 reconnect).
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
from typing import Any, Protocol

from esr.handler import all_permissions
from esr.ipc.envelope import make_directive_ack, make_event, make_handler_hello

from _ipc_common.reconnect import RECONNECT_BACKOFF_SCHEDULE
from _ipc_common.url import resolve_url

logger = logging.getLogger(__name__)


class AdapterPusher(Protocol):
    """Minimum surface an adapter runner needs from its channel."""

    source_uri: str

    async def push_envelope(self, envelope: dict[str, Any]) -> None: ...


async def process_directive(
    adapter: Any, payload: dict[str, Any]
) -> dict[str, Any]:
    """Invoke ``adapter.on_directive(action, args)`` and wrap into an ack payload.

    Returns ``{"ok": True, "result": <dict>}`` on success or
    ``{"ok": False, "error": {"type": ..., "message": ...}}`` if the
    adapter raises. Exceptions from missing required keys (e.g.
    ``"action"``) propagate up — the wire-level envelope schema
    guarantees their presence, so a KeyError here indicates a bug
    upstream, not a recoverable error.
    """
    action = payload["action"]  # required
    args = payload.get("args", {})
    try:
        result = await adapter.on_directive(action, args)
    except Exception as exc:  # noqa: BLE001 — adapter boundary
        return {
            "ok": False,
            "error": {"type": type(exc).__name__, "message": str(exc)},
        }
    return {"ok": True, "result": result}


async def directive_loop(
    adapter: Any,
    queue: asyncio.Queue[dict[str, Any] | None],
    pusher: AdapterPusher,
) -> None:
    """Drain ``queue`` of directive envelopes, FIFO-process, push acks.

    A ``None`` value is a sentinel that cleanly stops the loop — used by
    tests and by the runner's shutdown path.
    """
    while True:
        envelope = await queue.get()
        if envelope is None:
            return
        ack_payload = await process_directive(adapter, envelope["payload"])
        ack = make_directive_ack(
            id_=envelope["id"],
            source=pusher.source_uri,
            ok=ack_payload["ok"],
            result=ack_payload.get("result"),
            error=ack_payload.get("error"),
        )
        await pusher.push_envelope(ack)


async def event_loop(adapter: Any, pusher: AdapterPusher) -> None:
    """Consume ``adapter.emit_events()`` and push each as an event envelope.

    Not every adapter emits events proactively (e.g. cc_tmux drives itself
    via directives; feishu's WS listener is optional in mock mode). If the
    adapter does not implement ``emit_events``, the loop exits immediately.
    """
    emit = getattr(adapter, "emit_events", None)
    if emit is None:
        return
    async for event_dict in emit():
        # Adapters may set principal_id / workspace_name at the top
        # level of the yielded dict (capabilities spec §6.2/§6.3). For
        # adapters that don't, the fields default to None — Lane A and
        # Lane B in the Elixir runtime treat that as "deny unless
        # bootstrap principal".
        env = make_event(
            source=pusher.source_uri,
            event_type=event_dict["event_type"],
            args=dict(event_dict.get("args", {})),
            principal_id=event_dict.get("principal_id"),
            workspace_name=event_dict.get("workspace_name"),
        )
        await pusher.push_envelope(env)


async def watch_disconnect(
    client: Any, poll_interval: float = 0.1
) -> None:
    """Task 7 (DI-3): raise :class:`ConnectionError` when the WS drops.

    Polls ``client.connected`` every ``poll_interval`` seconds. When the
    flag flips False (e.g. aiohttp's read loop exits because the server
    closed the socket), raises :class:`ConnectionError` so the enclosing
    TaskGroup unwinds and :func:`run_with_reconnect` can attempt a
    fresh connection. The wall-clock ceiling on disconnect detection is
    ~``poll_interval``.

    Fake test clients without a ``connected`` attribute are tolerated by
    treating ``getattr`` misses as "still connected".
    """
    while True:
        if not getattr(client, "connected", True):
            raise ConnectionError("ws disconnected")
        await asyncio.sleep(poll_interval)


async def run_with_client(
    adapter: Any,
    client: Any,
    *,
    topic: str,
) -> None:
    """TDD-friendly entry: given an already-constructed ``client`` and
    ``adapter``, connect, join, and run the directive + event loops.

    The Phoenix v2 frame shape — ``[join_ref, ref, topic, event, payload]`` —
    is parsed inside the on_msg callback; envelopes are pushed onto a queue
    that :func:`directive_loop` drains.

    Returns normally only if directive_loop / event_loop both complete
    (they typically don't — they're driven off infinite queues/generators).
    If the underlying WS disconnects, the disconnect watcher raises
    :class:`ConnectionError` which unwinds through the TaskGroup as an
    :class:`ExceptionGroup`; :func:`run_with_reconnect` catches it and
    reconnects.
    """
    from esr.ipc.channel_pusher import ChannelPusher

    await client.connect()
    queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()

    def _on_frame(frame: list[Any]) -> None:
        # frame is [join_ref, ref, topic, event, payload]
        if len(frame) < 5:
            return
        event, payload = frame[3], frame[4]
        if event != "envelope" or not isinstance(payload, dict):
            return
        if payload.get("kind") != "directive":
            return
        queue.put_nowait(payload)

    await client.join(topic, _on_frame)
    # The envelope builders require an ``esr://`` source (spec §7.5). The
    # channel topic (``adapter:<name>/<id>``) is not a valid URI; derive
    # the source by mapping topic → ``esr://localhost/<topic>`` so acks
    # carry a provenance string that parses.
    source_uri = "esr://localhost/" + topic
    pusher = ChannelPusher(client=client, topic=topic, source_uri=source_uri)

    # Announce this process's permission declarations (capabilities
    # spec §3.1, §4.1). Adapter processes rarely import handler modules
    # (handler workers do), so all_permissions() is usually empty — but
    # registering an empty set is a no-op, so emitting unconditionally
    # keeps the handshake shape symmetric across worker types.
    hello = make_handler_hello(
        source=source_uri,
        permissions=sorted(all_permissions()),
    )
    await client.push(topic, "envelope", hello)

    # Run directive_loop + event_loop alongside a disconnect watcher. When
    # the watcher raises (WS dropped) or either loop returns/raises, we
    # cancel the survivors and propagate the first exception so
    # :func:`run_with_reconnect` can attempt a fresh connection.
    directive_task = asyncio.create_task(directive_loop(adapter, queue, pusher))
    event_task = asyncio.create_task(event_loop(adapter, pusher))
    watch_task = asyncio.create_task(watch_disconnect(client))
    all_tasks = (directive_task, event_task, watch_task)
    try:
        done, _ = await asyncio.wait(
            set(all_tasks), return_when=asyncio.FIRST_COMPLETED
        )
        for t in all_tasks:
            if not t.done():
                t.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await t
        for t in done:
            exc = t.exception()
            if exc is not None:
                raise exc
    finally:
        await client.close()


async def run_with_reconnect(
    adapter: Any,
    *,
    topic: str,
    fallback_url: str,
    client_factory: Any = None,
    backoff_schedule: tuple[float, ...] = RECONNECT_BACKOFF_SCHEDULE,
) -> None:
    """Task 7 (DI-3): wrap :func:`run_with_client` in an exponential-backoff
    reconnect loop that re-reads the port file on every attempt.

    Each iteration:
    1. Re-resolve the URL via :func:`_adapter_common.url.resolve_url`
       (follows launchctl kickstart when ``esrd.port`` changes).
    2. Construct a fresh :class:`ChannelClient` (new WS session).
    3. Delegate to :func:`run_with_client`; a clean return resets the
       backoff schedule.
    4. On :class:`ConnectionError` (raised by the disconnect watcher)
       or :class:`OSError` (WS dial failure), sleep per the backoff
       schedule and retry.

    ``client_factory`` is injection-friendly for tests — defaults to
    :class:`ChannelClient` construction, but a test can pass a lambda
    that returns fakes. The factory receives the resolved URL as its
    only argument.
    """
    from esr.ipc.channel_client import ChannelClient

    factory_fn: Any = client_factory or (lambda u: ChannelClient(u))

    attempt = 0
    while True:
        url = resolve_url(fallback_url)
        client = factory_fn(url)
        try:
            await run_with_client(adapter, client, topic=topic)
            # Clean return (rare: all loops exited) → reset & retry.
            attempt = 0
        except asyncio.CancelledError:
            raise
        except (ConnectionError, OSError) as exc:
            logger.warning(
                "run_with_client disconnected (%s); reconnecting", exc
            )
        except Exception as exc:  # noqa: BLE001 — protect the outer loop
            logger.warning(
                "run_with_client raised unexpected error (%s); reconnecting",
                exc,
            )

        delay = backoff_schedule[min(attempt, len(backoff_schedule) - 1)]
        await asyncio.sleep(delay)
        attempt += 1


async def run(
    adapter_name: str,
    instance_id: str,
    config: dict[str, Any],
    url: str,
) -> None:
    """Full-orchestration entry point — loads an adapter factory, constructs
    a :class:`ChannelClient`, and delegates to :func:`run_with_reconnect`
    (spec §5.3 F13 + §5.4 reconnect). Phase 8b supplies the factory-loading
    logic; Task 7 (DI-3) wraps it in the auto-reconnect loop.
    """
    from esr.adapter import AdapterConfig
    from esr.adapters import load_adapter_factory  # type: ignore[import-not-found]

    factory: Any = load_adapter_factory(adapter_name)
    # Factories declare ``config: AdapterConfig`` — wrap the raw JSON dict
    # so read-only attribute access (``cfg.app_id``) works in adapters like
    # feishu. Tests that pass an AdapterConfig directly stay compatible
    # because AdapterConfig's constructor copies the dict defensively.
    adapter_config = (
        config if isinstance(config, AdapterConfig) else AdapterConfig(config)
    )
    adapter = factory(instance_id, adapter_config)
    topic = f"adapter:{adapter_name}/{instance_id}"
    await run_with_reconnect(adapter, topic=topic, fallback_url=url)
