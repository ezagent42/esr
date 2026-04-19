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

    try:
        state = state_entry.model(**state_dict)
    except Exception as exc:  # noqa: BLE001 — pydantic ValidationError + any ctor errors
        return _error(type(exc).__name__, str(exc))

    event = Event(source=event_source, event_type=event_type, args=event_args)

    try:
        new_state, actions = handler_entry.fn(state, event)
    except Exception as exc:  # noqa: BLE001 — handler boundary; see F08
        return _error(type(exc).__name__, str(exc))

    return {
        "new_state": _dump_state(new_state),
        "actions": [serialise_action(a) for a in actions],
    }


def _error(type_: str, message: str) -> dict[str, Any]:
    return {"error": {"type": type_, "message": message}}


def _dump_state(state: Any) -> dict[str, Any]:
    """Serialise a pydantic state instance back to a plain dict."""
    # Handlers MUST return a pydantic model (per §4.5); defensive branch.
    if hasattr(state, "model_dump"):
        return dict(state.model_dump())
    if isinstance(state, dict):
        return dict(state)
    raise TypeError(f"handler returned non-state value: {type(state).__name__}")
