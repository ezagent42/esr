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

# --- F01: envelope-type constants --------------------------------------

TYPE_EVENT = "event"
TYPE_DIRECTIVE = "directive"
TYPE_DIRECTIVE_ACK = "directive_ack"
TYPE_HANDLER_CALL = "handler_call"
TYPE_HANDLER_REPLY = "handler_reply"


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
) -> dict[str, Any]:
    """Build an ``event`` envelope (adapter → runtime)."""
    _check_source(source)
    return {
        "id": _new_id("e"),
        "ts": _now_iso(),
        "type": TYPE_EVENT,
        "source": source,
        "payload": {"event_type": event_type, "args": dict(args)},
    }


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
        "id": id_,
        "ts": _now_iso(),
        "type": TYPE_HANDLER_REPLY,
        "source": source,
        "payload": {"new_state": dict(new_state), "actions": list(actions)},
    }
