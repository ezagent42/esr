"""IPC envelope schema + builders (PRD 03 F01 / F02 / F12; spec §7.2).

All inter-process payloads share a common envelope::

    {id, ts, type, source, payload}

- ``id`` carries a type-hinting prefix (``e-`` event, ``d-`` directive,
  ``h-`` handler_call/reply) so log traces are readable at a glance.
  For *ack* envelopes the id is the ORIGINAL message's id — that is
  how correlation is done across the wire.
- ``ts`` is RFC 3339 UTC (``…+00:00`` or ``…Z``).
- ``type`` is one of five discriminator strings defined below.
- ``source`` is the fully-qualified ``esr://`` URI of the emitter.
- ``payload`` is type-specific.

Elixir-side counterparts live in ``runtime/lib/esr/ipc/envelope.ex``
(PRD 01 F09-F12). Constants and shapes are kept in lock-step.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from esr.actions import Action, Emit, InvokeCommand, Reply, Route, SendInput

# --- F01: envelope-type constants --------------------------------------

TYPE_EVENT = "event"
TYPE_DIRECTIVE = "directive"
TYPE_DIRECTIVE_ACK = "directive_ack"
TYPE_HANDLER_CALL = "handler_call"
TYPE_HANDLER_REPLY = "handler_reply"
# Boot-time handshake carrying the union of permissions declared by
# every handler loaded into this Python process. Pushed once per
# worker on channel join; Elixir AdapterChannel / HandlerChannel
# register each permission name into Esr.Permissions.Registry.
# (capabilities spec §3.1, §4.1)
TYPE_HANDLER_HELLO = "handler_hello"


# --- Internal helpers --------------------------------------------------


def _now_iso() -> str:
    """Return an RFC 3339 UTC timestamp string."""
    return datetime.now(UTC).isoformat()


def _new_id(prefix: str) -> str:
    """Return a fresh id of the form ``<prefix>-<uuid4>``."""
    return f"{prefix}-{uuid.uuid4()}"


def _check_source(source: str) -> None:
    """Reject sources that are not ``esr://`` URIs (wire invariant, §7.5)."""
    if not source.startswith("esr://"):
        raise ValueError(f"source must be an esr:// URI; got {source!r}")


# --- F02: builders -----------------------------------------------------


def make_event(
    *,
    source: str,
    event_type: str,
    args: dict[str, Any],
    principal_id: str | None = None,
    workspace_name: str | None = None,
) -> dict[str, Any]:
    """Build an ``event`` envelope (adapter → runtime).

    Capabilities spec §6.2/§6.3: when the emitter (an adapter or
    colocated worker) knows *who* the event is attributable to and
    *which* workspace the subject chat is bound to, those go on the
    envelope top-level so Lane A / Lane B (Elixir PeerServer +
    capabilities checks) can read them without descending into
    ``payload.args``. Both default to ``None`` for callers (e.g.
    synthetic events, older adapters) that cannot supply them; Lane A
    / Lane B treat missing values as "deny unless bootstrap".
    """
    _check_source(source)
    env: dict[str, Any] = {
        "kind": TYPE_EVENT,
        "id": _new_id("e"),
        "ts": _now_iso(),
        "type": TYPE_EVENT,
        "source": source,
        "principal_id": principal_id,
        "workspace_name": workspace_name,
        "payload": {"event_type": event_type, "args": dict(args)},
    }
    return env


def make_directive_ack(
    *,
    id_: str,
    source: str,
    ok: bool,
    result: dict[str, Any] | None = None,
    error: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a ``directive_ack`` envelope (adapter → runtime).

    ``id_`` MUST be the original directive's id so the runtime can
    correlate ack to directive. Exactly one of ``result``/``error``
    should be supplied depending on ``ok``; the other key is omitted.
    """
    _check_source(source)
    payload: dict[str, Any] = {"ok": ok}
    if ok and result is not None:
        payload["result"] = dict(result)
    if not ok and error is not None:
        payload["error"] = dict(error)
    return {
        "kind": TYPE_DIRECTIVE_ACK,
        "id": id_,
        "ts": _now_iso(),
        "type": TYPE_DIRECTIVE_ACK,
        "source": source,
        "payload": payload,
    }


def make_handler_reply(
    *,
    source: str,
    id_: str,
    new_state: dict[str, Any],
    actions: list[dict[str, Any]],
) -> dict[str, Any]:
    """Build a ``handler_reply`` envelope (handler → runtime).

    ``id_`` MUST be the original ``handler_call``'s id so the runtime
    can match reply → call. ``new_state`` is the pydantic model
    dumped to a dict; ``actions`` is already-serialised Action dicts
    (see ``serialise_action`` in F03).
    """
    _check_source(source)
    return {
        "kind": TYPE_HANDLER_REPLY,
        "id": id_,
        "ts": _now_iso(),
        "type": TYPE_HANDLER_REPLY,
        "source": source,
        "payload": {"new_state": dict(new_state), "actions": list(actions)},
    }


def make_handler_hello(
    *,
    source: str,
    permissions: list[str],
) -> dict[str, Any]:
    """Build a ``handler_hello`` envelope (python worker → runtime).

    Pushed once on channel join so the Elixir runtime can register
    every permission name this Python process declares into
    ``Esr.Permissions.Registry`` (capabilities spec §3.1, §4.1).
    ``permissions`` should already be sorted for wire determinism.
    """
    _check_source(source)
    return {
        "kind": TYPE_HANDLER_HELLO,
        "id": _new_id("hh"),
        "ts": _now_iso(),
        "type": TYPE_HANDLER_HELLO,
        "source": source,
        "payload": {"permissions": list(permissions)},
    }


# --- F03: action serialisation -----------------------------------------


def serialise_action(action: Action) -> dict[str, Any]:
    """Serialise an ``Action`` ADT value to a JSON-ready dict.

    The dict carries a ``type`` discriminator that both sides agree on:
    ``emit`` / ``route`` / ``invoke_command``. Handler replies include
    a list of these.
    """
    if isinstance(action, Emit):
        return {
            "type": "emit",
            "adapter": action.adapter,
            "action": action.action,
            "args": dict(action.args),
        }
    if isinstance(action, Route):
        return {"type": "route", "target": action.target, "msg": action.msg}
    if isinstance(action, InvokeCommand):
        return {
            "type": "invoke_command",
            "name": action.name,
            "params": dict(action.params),
        }
    if isinstance(action, Reply):
        out = {"type": "reply", "text": action.text}
        if action.reply_to_message_id is not None:
            out["reply_to_message_id"] = action.reply_to_message_id
        return out
    if isinstance(action, SendInput):
        return {"type": "send_input", "text": action.text}
    raise TypeError(f"not an Action: {type(action).__name__}")


def deserialise_action(d: dict[str, Any]) -> Action:
    """Inverse of ``serialise_action`` — reconstruct the ``Action`` instance."""
    t = d.get("type")
    if t == "emit":
        return Emit(adapter=d["adapter"], action=d["action"], args=dict(d.get("args", {})))
    if t == "route":
        return Route(target=d["target"], msg=d["msg"])
    if t == "invoke_command":
        return InvokeCommand(name=d["name"], params=dict(d.get("params", {})))
    if t == "reply":
        return Reply(text=d["text"], reply_to_message_id=d.get("reply_to_message_id"))
    if t == "send_input":
        return SendInput(text=d["text"])
    raise ValueError(f"unknown action type {t!r}")
