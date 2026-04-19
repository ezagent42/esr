"""Handler worker (PRD 03 F07 / F08; spec §3.4).

A handler worker is the Python process that executes a single handler
module. The Elixir HandlerRouter assigns one worker per module (per
instance); the worker joins ``handler:<module>/<worker_id>`` over
Phoenix Channels and loops:

1. Receive ``handler_call`` envelope
2. Reconstruct the handler's state pydantic model
3. Reconstruct the ``Event`` from the call payload
4. Invoke the registered handler fn
5. Return a ``handler_reply`` payload with serialised actions

Any exception from the handler body is caught and surfaced in the
reply as ``{"error": {"type": "<cls>", "message": "<msg>"}}`` —
**the worker never dies from a handler error**. Elixir side reserves
the "worker crashed" channel notification for truly unexpected exits
(segfault, OOM).

This module exposes ``process_handler_call`` as a pure function so
the dispatch logic can be unit-tested without a live channel. The
``run`` entry point that wires it to a Phoenix ChannelClient is F07's
orchestration half — deferred until F13 (integration smoke).
"""

from __future__ import annotations

from typing import Any

from esr.events import Event
from esr.handler import HANDLER_REGISTRY, STATE_REGISTRY
from esr.ipc.envelope import serialise_action


def process_handler_call(payload: dict[str, Any]) -> dict[str, Any]:
    """Execute a ``handler_call`` payload and return the ``handler_reply`` payload.

    Never raises — any error encountered (missing registration, state
    validation, handler body) is encoded as ``{"error": {...}}`` in the
    returned dict. Callers must treat ``"error" in reply`` as the
    exhaustive failure signal.
    """
    try:
        handler_key = payload["handler"]
        state_dict = payload.get("state", {})
        event_dict = payload.get("event", {})
        event_type = event_dict["event_type"]
        event_source = event_dict.get("source", "")
        event_args = dict(event_dict.get("args", {}))
    except (KeyError, TypeError, AttributeError) as exc:
        return _error("MalformedEnvelope", str(exc))

    handler_entry = HANDLER_REGISTRY.get(handler_key)
    if handler_entry is None:
        return _error("HandlerNotRegistered", f"{handler_key} not registered")

    state_entry = STATE_REGISTRY.get(handler_entry.actor_type)
    if state_entry is None:
        return _error(
            "StateNotRegistered",
            f"state model for actor_type {handler_entry.actor_type} not registered",
        )

    # PRD 02 F05 / reviewer C2: reject state dicts carrying a
    # _schema_version that doesn't match the registered model.
    incoming_schema = state_dict.get("_schema_version")
    if incoming_schema is not None and incoming_schema != state_entry.schema_version:
        return _error(
            "SchemaVersionMismatch",
            f"state for {handler_entry.actor_type} is at schema_version "
            f"{incoming_schema}; this worker expects "
            f"{state_entry.schema_version}",
        )

    # Strip the meta field before passing to pydantic (the model's
    # schema doesn't declare it).
    clean_state_dict = {k: v for k, v in state_dict.items() if k != "_schema_version"}

    try:
        state = state_entry.model(**clean_state_dict)
    except Exception as exc:  # noqa: BLE001 — pydantic ValidationError + any ctor errors
        return _error(type(exc).__name__, str(exc))

    event = Event(source=event_source, event_type=event_type, args=event_args)

    try:
        new_state, actions = handler_entry.fn(state, event)
    except Exception as exc:  # noqa: BLE001 — handler boundary; see F08
        return _error(type(exc).__name__, str(exc))

    # Tag the outgoing state with the registered schema_version so the
    # runtime can persist it alongside the payload and detect drift on
    # reload.
    dumped = _dump_state(new_state)
    dumped["_schema_version"] = state_entry.schema_version

    return {
        "new_state": dumped,
        "actions": [serialise_action(a) for a in actions],
    }


def _error(type_: str, message: str) -> dict[str, Any]:
    return {"error": {"type": type_, "message": message}}


def _dump_state(state: Any) -> dict[str, Any]:
    """Serialise a pydantic state instance back to a plain dict."""
    if hasattr(state, "model_dump"):
        return dict(state.model_dump())
    if isinstance(state, dict):
        return dict(state)
    raise TypeError(f"handler returned non-state value: {type(state).__name__}")


async def run_with_client(client: Any, *, topic: str) -> None:
    """TDD-friendly entry: given a ChannelClient, connect, join the handler
    topic, and process handler_call envelopes by routing to
    :func:`process_handler_call` and pushing handler_reply back on the same
    topic.
    """
    import asyncio as _asyncio

    await client.connect()
    queue: _asyncio.Queue[dict[str, Any] | None] = _asyncio.Queue()

    def _on_frame(frame: list[Any]) -> None:
        if len(frame) < 5:
            return
        event, payload = frame[3], frame[4]
        if event != "envelope" or not isinstance(payload, dict):
            return
        if payload.get("kind") != "handler_call":
            return
        queue.put_nowait(payload)

    await client.join(topic, _on_frame)
    try:
        while True:
            envelope = await queue.get()
            if envelope is None:
                return
            reply_payload = process_handler_call(envelope["payload"])
            await client.push(topic, "envelope", {
                "kind": "handler_reply",
                "id": envelope["id"],
                "source": topic,
                "payload": reply_payload,
            })
    finally:
        await client.close()


async def run(handler_module: str, worker_id: str, url: str) -> None:
    """Full-orchestration entry point — constructs a :class:`ChannelClient`
    and delegates to :func:`run_with_client` (spec §3.4 F07). Phase 8b
    passes handler_module/worker_id via the daemon spawning this worker.
    """
    from esr.handler import HANDLER_REGISTRY as _reg  # noqa: F811
    from esr.ipc.channel_client import ChannelClient

    _ = _reg  # ensure registry is imported (decorators fire)
    topic = f"handler:{handler_module}/{worker_id}"
    client = ChannelClient(url)
    await run_with_client(client, topic=topic)
