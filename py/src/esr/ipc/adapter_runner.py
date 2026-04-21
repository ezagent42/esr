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

from esr.handler import all_permissions
from esr.ipc.envelope import make_directive_ack, make_event, make_handler_hello


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
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(directive_loop(adapter, queue, pusher))
            tg.create_task(event_loop(adapter, pusher))
    finally:
        await client.close()


async def run(
    adapter_name: str,
    instance_id: str,
    config: dict[str, Any],
    url: str,
) -> None:
    """Full-orchestration entry point — loads an adapter factory, constructs
    a :class:`ChannelClient`, and delegates to :func:`run_with_client`
    (spec §5.3 F13). Phase 8b supplies the factory-loading logic.
    """
    from esr.adapter import AdapterConfig
    from esr.adapters import load_adapter_factory  # type: ignore[import-not-found]
    from esr.ipc.channel_client import ChannelClient

    factory = load_adapter_factory(adapter_name)
    # Factories declare ``config: AdapterConfig`` — wrap the raw JSON dict
    # so read-only attribute access (``cfg.app_id``) works in adapters like
    # feishu. Tests that pass an AdapterConfig directly stay compatible
    # because AdapterConfig's constructor copies the dict defensively.
    adapter_config = (
        config if isinstance(config, AdapterConfig) else AdapterConfig(config)
    )
    adapter = factory(instance_id, adapter_config)
    topic = f"adapter:{adapter_name}/{instance_id}"
    client = ChannelClient(url)
    await run_with_client(adapter, client, topic=topic)


def _parse_main_args(argv: list[str]) -> Any:
    """Parse `python -m esr.ipc.adapter_runner ...` CLI args."""
    import argparse
    import json as _json

    p = argparse.ArgumentParser(
        prog="esr.ipc.adapter_runner",
        description="Run an ESR adapter worker against a live esrd.",
    )
    p.add_argument("--adapter", required=True, help="Adapter name, e.g. 'feishu'.")
    p.add_argument("--instance-id", required=True, help="Instance id in actor namespace.")
    p.add_argument("--url", required=True, help="esrd adapter_hub WebSocket URL.")
    p.add_argument(
        "--config-json", required=True,
        help="JSON blob passed to the adapter factory as config.",
    )
    ns = p.parse_args(argv)
    ns.config = _json.loads(ns.config_json)
    return ns


def main(argv: list[str] | None = None) -> int:
    """Python -m entry: parse args, run the adapter worker until cancelled.

    Phase 8d's scenario setup spawns this as a subprocess per adapter
    instance, so it runs indefinitely (event loop never returns under
    normal operation). KeyboardInterrupt / cancellation → clean exit.
    """
    import logging

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

    ns = _parse_main_args(argv if argv is not None else [])
    try:
        asyncio.run(run(ns.adapter, ns.instance_id, ns.config, ns.url))
    except KeyboardInterrupt:
        return 0
    except BaseException as exc:  # noqa: BLE001 — ExceptionGroup is BaseException
        import sys
        import traceback
        print(f"esr.ipc.adapter_runner FAIL: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv[1:]))
