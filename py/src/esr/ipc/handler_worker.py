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

import asyncio
import contextlib
import logging
from typing import Any

from _ipc_common.disconnect import watch_disconnect
from _ipc_common.frame import make_envelope_filter
from _ipc_common.reconnect import RECONNECT_BACKOFF_SCHEDULE, reconnect_loop
from esr.events import Event
from esr.handler import HANDLER_REGISTRY, STATE_REGISTRY, all_permissions
from esr.ipc.envelope import make_handler_hello, serialise_action

logger = logging.getLogger(__name__)


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
    """Serialise a pydantic state instance back to a JSON-compatible dict.

    Frozen state models use ``frozenset`` for dedup-style fields (e.g.
    FeishuAppState.bound_threads) — pydantic's ``model_dump`` returns
    them as-is, but the caller serialises the reply via Phoenix's
    JSON encoder which does not accept sets. Coerce every
    non-JSON-native container we encounter into list/dict/tuple
    equivalents.
    """
    if hasattr(state, "model_dump"):
        return _to_json_native(dict(state.model_dump()))
    if isinstance(state, dict):
        return _to_json_native(dict(state))
    raise TypeError(f"handler returned non-state value: {type(state).__name__}")


def _to_json_native(value: Any) -> Any:
    """Recursively convert frozenset/set into sorted lists for JSON."""
    if isinstance(value, (frozenset, set)):
        return sorted(value, key=str)
    if isinstance(value, dict):
        return {k: _to_json_native(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_json_native(v) for v in value]
    if isinstance(value, tuple):
        return [_to_json_native(v) for v in value]
    return value


async def _handler_call_loop(
    client: Any, queue: asyncio.Queue[dict[str, Any] | None], topic: str
) -> None:
    """Drain ``queue`` of handler_call envelopes; push each reply back.

    Extracted from the inline body of :func:`run_with_client` so the
    disconnect-watcher task (Task 7 DI-3) can sit alongside it inside a
    TaskGroup — a ``while True`` + ``finally`` body doesn't compose with
    sibling tasks the way a coroutine does.
    """
    while True:
        envelope = await queue.get()
        if envelope is None:
            return
        reply_payload = process_handler_call(envelope["payload"])
        # source is an esr:// URI (wire invariant §7.5) — mirror the
        # adapter_runner convention of "esr://localhost/" + topic.
        await client.push(topic, "envelope", {
            "kind": "handler_reply",
            "id": envelope["id"],
            "source": "esr://localhost/" + topic,
            "payload": reply_payload,
        })


async def run_with_client(client: Any, *, topic: str) -> None:
    """TDD-friendly entry: given a ChannelClient, connect, join the handler
    topic, and process handler_call envelopes by routing to
    :func:`process_handler_call` and pushing handler_reply back on the same
    topic.

    Returns normally when the handler_call queue drains with a ``None``
    sentinel. If the underlying WS disconnects, the disconnect watcher
    raises ConnectionError which unwinds through the TaskGroup as an
    ExceptionGroup; :func:`run_with_reconnect` catches and reconnects.
    """
    await client.connect()
    queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
    await client.join(topic, make_envelope_filter("handler_call", queue))

    # Emit the capabilities handler_hello so the Elixir runtime can
    # register the permissions this process declares into
    # Esr.Permissions.Registry (spec §3.1, §4.1). Sorted for wire
    # determinism; absent/empty is fine — registry tolerates reruns.
    hello = make_handler_hello(
        source="esr://localhost/" + topic,
        permissions=sorted(all_permissions()),
    )
    await client.push(topic, "envelope", hello)

    # Run the call loop and disconnect watcher concurrently. First one
    # to finish drives teardown: clean drain (None sentinel on queue)
    # returns normally; WS drop raises ConnectionError that propagates
    # out to :func:`run_with_reconnect`.
    call_task = asyncio.create_task(_handler_call_loop(client, queue, topic))
    watch_task = asyncio.create_task(watch_disconnect(client))
    try:
        done, _ = await asyncio.wait(
            {call_task, watch_task}, return_when=asyncio.FIRST_COMPLETED
        )
        # Cancel the survivor, then surface the completer's outcome.
        for t in (call_task, watch_task):
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
    *,
    topic: str,
    fallback_url: str,
    client_factory: Any = None,
    backoff_schedule: tuple[float, ...] = RECONNECT_BACKOFF_SCHEDULE,
) -> None:
    """Task 7 (DI-3): wrap :func:`run_with_client` in an exponential-backoff
    reconnect loop that re-reads the port file on every attempt.

    Delegates to :func:`_ipc_common.reconnect.reconnect_loop` which
    handles URL re-resolution, backoff, and exception protection.
    Handler workers don't carry an adapter instance, so the signature
    differs from the adapter_runner version.
    """
    async def run_one(client: Any) -> None:
        await run_with_client(client, topic=topic)

    await reconnect_loop(
        run_one,
        fallback_url=fallback_url,
        client_factory=client_factory,
        backoff_schedule=backoff_schedule,
    )


async def run(handler_module: str, worker_id: str, url: str) -> None:
    """Full-orchestration entry point — loads the handler module so its
    ``@handler`` decorators register, then delegates to
    :func:`run_with_reconnect` (spec §3.4 F07 + §5.4 reconnect). Task 7
    (DI-3) wraps the single-connection ``run_with_client`` in an
    auto-reconnect loop with port-file-based URL re-resolution.
    """
    import importlib

    # Import the handler module so its @handler decorators register into
    # HANDLER_REGISTRY. handler_module looks like "feishu_thread.on_msg";
    # for a package layout (esr_handler_feishu_thread.on_msg), the loader
    # uses the dotted name directly.
    pkg = "esr_handler_" + handler_module.split(".")[0]
    try:
        importlib.import_module(f"{pkg}.on_msg")
    except ImportError:
        # Fall back to the raw module path (useful for tests with shim packages).
        importlib.import_module(handler_module)
    topic = f"handler:{handler_module}/{worker_id}"
    await run_with_reconnect(topic=topic, fallback_url=url)


def _parse_main_args(argv: list[str]) -> Any:
    """Parse `python -m esr.ipc.handler_worker ...` CLI args."""
    import argparse

    p = argparse.ArgumentParser(
        prog="esr.ipc.handler_worker",
        description="Run an ESR handler worker against a live esrd.",
    )
    p.add_argument("--module", required=True, help="Handler module, e.g. 'feishu_thread.on_msg'.")
    p.add_argument("--worker-id", required=True, help="Worker id in actor namespace.")
    p.add_argument("--url", required=True, help="esrd handler_hub WebSocket URL.")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Python -m entry: parse args, run the handler worker until cancelled."""
    import asyncio

    ns = _parse_main_args(argv if argv is not None else [])
    try:
        asyncio.run(run(ns.module, ns.worker_id, ns.url))
    except KeyboardInterrupt:
        return 0
    except Exception as exc:  # noqa: BLE001
        import sys
        print(f"esr.ipc.handler_worker FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    import os
    import sys

    # PR-21β 2026-04-30 — see feishu_adapter_runner.__main__ for rationale.
    if not os.environ.get("ESR_SPAWN_TOKEN"):
        sys.stderr.write(
            "esr.ipc.handler_worker: must be spawned by esrd via erlexec; "
            "manual `uv run` invocation is unsupported.\n"
            "To debug locally:\n"
            "  esr daemon stop\n"
            "  ESR_SPAWN_TOKEN=__debug__ uv run --project py python -m "
            "esr.ipc.handler_worker ...\n"
        )
        sys.exit(2)

    sys.exit(main(sys.argv[1:]))
