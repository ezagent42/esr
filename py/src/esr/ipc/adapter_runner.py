"""Adapter runner (PRD 03 F09 / F10; spec §5.3).

A Python adapter process runs two concurrent coroutines:

- ``directive_loop`` — consumes directive envelopes from a queue
  (filled by the ChannelClient's receive callback), invokes
  ``adapter.on_directive(action, args)``, and pushes a
  ``directive_ack`` envelope back via the pusher. **Strictly FIFO**:
  the next directive does not start until the previous one has
  produced its ack (F10).
- ``event_loop`` — consumes events from ``adapter.emit_events()``
  (an async generator), wraps each dict as an ``event`` envelope,
  and pushes it. Events may interleave with acks on the wire —
  FIFO applies per-loop, not cross-loop.

The two loops share a ``pusher`` protocol: anything with
``source_uri: str`` and ``async def push_envelope(env)``. That
keeps this module testable without the real ``ChannelClient``.

``run(adapter_name, instance_id, config, url)`` — the full
orchestration entry point that wires both loops to a live
ChannelClient — is deferred to F13 (integration smoke). The pure
dispatch pieces (``process_directive``, ``directive_loop``,
``event_loop``) are the unit-testable surface.
"""

from __future__ import annotations

import asyncio
from typing import Any, Protocol

from esr.ipc.envelope import make_directive_ack, make_event


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
    """Consume ``adapter.emit_events()`` and push each as an event envelope."""
    async for event_dict in adapter.emit_events():
        env = make_event(
            source=pusher.source_uri,
            event_type=event_dict["event_type"],
            args=dict(event_dict.get("args", {})),
        )
        await pusher.push_envelope(env)
