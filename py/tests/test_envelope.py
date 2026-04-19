"""PRD 03 F01 / F02 / F12 — envelope constants + builders + source field."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from esr.ipc import envelope as env

# --- F01: envelope-type constants --------------------------------------


def test_envelope_type_constants_exist() -> None:
    """All five envelope-type strings are defined as module constants."""
    assert env.TYPE_EVENT == "event"
    assert env.TYPE_DIRECTIVE == "directive"
    assert env.TYPE_DIRECTIVE_ACK == "directive_ack"
    assert env.TYPE_HANDLER_CALL == "handler_call"
    assert env.TYPE_HANDLER_REPLY == "handler_reply"


# --- F02: envelope builders --------------------------------------------


def _parse_rfc3339(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def test_make_event_structure() -> None:
    """make_event produces a full envelope with 'e-' prefixed id."""
    e = env.make_event(
        source="esr://localhost/adapter/feishu-shared",
        event_type="msg_received",
        args={"chat_id": "oc_abc", "content": "hi"},
    )
    assert e["type"] == env.TYPE_EVENT
    assert e["source"] == "esr://localhost/adapter/feishu-shared"
    assert e["id"].startswith("e-")
    assert e["payload"] == {
        "event_type": "msg_received",
        "args": {"chat_id": "oc_abc", "content": "hi"},
    }
    ts = _parse_rfc3339(e["ts"])
    assert ts.tzinfo is not None  # RFC 3339 requires tz


def test_make_event_ids_are_unique() -> None:
    """Two envelopes built back-to-back have distinct ids."""
    a = env.make_event(source="esr://localhost/adapter/x", event_type="e", args={})
    b = env.make_event(source="esr://localhost/adapter/x", event_type="e", args={})
    assert a["id"] != b["id"]


def test_make_directive_ack_preserves_directive_id() -> None:
    """directive_ack reuses the original directive's id (for correlation)."""
    ack = env.make_directive_ack(
        id_="d-abc-123",
        source="esr://localhost/adapter/feishu-shared",
        ok=True,
        result={"msg_id": "m_1"},
    )
    assert ack["id"] == "d-abc-123"
    assert ack["type"] == env.TYPE_DIRECTIVE_ACK
    assert ack["source"] == "esr://localhost/adapter/feishu-shared"
    assert ack["payload"] == {"ok": True, "result": {"msg_id": "m_1"}}


def test_make_directive_ack_error_shape() -> None:
    """On failure, ack carries an error dict; result is omitted."""
    ack = env.make_directive_ack(
        id_="d-xyz",
        source="esr://localhost/adapter/feishu-shared",
        ok=False,
        error={"type": "RateLimited", "message": "429 too many"},
    )
    assert ack["payload"] == {
        "ok": False,
        "error": {"type": "RateLimited", "message": "429 too many"},
    }


def test_make_handler_reply_preserves_call_id() -> None:
    """handler_reply reuses the handler_call's id (for correlation)."""
    reply = env.make_handler_reply(
        source="esr://localhost/handler/cc_session.on_msg",
        id_="h-call-1",
        new_state={"counter": 5},
        actions=[{"type": "emit", "adapter": "f", "action": "send", "args": {}}],
    )
    assert reply["id"] == "h-call-1"
    assert reply["type"] == env.TYPE_HANDLER_REPLY
    assert reply["source"] == "esr://localhost/handler/cc_session.on_msg"
    assert reply["payload"] == {
        "new_state": {"counter": 5},
        "actions": [{"type": "emit", "adapter": "f", "action": "send", "args": {}}],
    }


def test_builder_ts_is_utc() -> None:
    """Every builder stamps ts in UTC (RFC 3339 Z suffix or +00:00)."""
    e = env.make_event(source="esr://localhost/adapter/x", event_type="e", args={})
    ts = _parse_rfc3339(e["ts"])
    assert ts.utcoffset() == UTC.utcoffset(datetime.now(UTC))


# --- F12: source field correctness -------------------------------------


def test_every_builder_requires_source() -> None:
    """source is mandatory on every builder — no default."""
    with pytest.raises(TypeError):
        env.make_event(event_type="e", args={})  # type: ignore[call-arg]
    with pytest.raises(TypeError):
        env.make_directive_ack(id_="x", ok=True)  # type: ignore[call-arg]
    with pytest.raises(TypeError):
        env.make_handler_reply(id_="x", new_state={}, actions=[])  # type: ignore[call-arg]


def test_source_field_must_be_esr_uri() -> None:
    """Builders reject non-esr:// sources — wire-level invariant."""
    with pytest.raises(ValueError, match=r"source must be an esr:// URI"):
        env.make_event(
            source="http://example.com/adapter/x", event_type="e", args={}
        )


# --- F03: action serialisation -----------------------------------------


def test_serialise_emit() -> None:
    """Emit → dict with 'emit' discriminator."""
    from esr.actions import Emit

    d = env.serialise_action(Emit(adapter="feishu", action="send", args={"x": 1}))
    assert d == {"type": "emit", "adapter": "feishu", "action": "send", "args": {"x": 1}}


def test_serialise_route() -> None:
    """Route → dict with 'route' discriminator."""
    from esr.actions import Route

    d = env.serialise_action(Route(target="cc:sess-A", msg="hello"))
    assert d == {"type": "route", "target": "cc:sess-A", "msg": "hello"}


def test_serialise_invoke_command() -> None:
    """InvokeCommand → dict with 'invoke_command' discriminator."""
    from esr.actions import InvokeCommand

    d = env.serialise_action(InvokeCommand(name="feishu-thread-session", params={"t": "x"}))
    assert d == {
        "type": "invoke_command",
        "name": "feishu-thread-session",
        "params": {"t": "x"},
    }


def test_action_round_trip_emit() -> None:
    """Serialise + deserialise Emit reproduces the original."""
    from esr.actions import Emit

    a = Emit(adapter="feishu", action="send", args={"x": 1})
    assert env.deserialise_action(env.serialise_action(a)) == a


def test_action_round_trip_route() -> None:
    from esr.actions import Route

    a = Route(target="cc:sess-A", msg={"nested": True})
    assert env.deserialise_action(env.serialise_action(a)) == a


def test_action_round_trip_invoke_command() -> None:
    from esr.actions import InvokeCommand

    a = InvokeCommand(name="foo", params={"p": 1})
    assert env.deserialise_action(env.serialise_action(a)) == a


def test_deserialise_action_unknown_type_raises() -> None:
    """Unknown discriminator raises ValueError."""
    with pytest.raises(ValueError, match=r"unknown action type"):
        env.deserialise_action({"type": "bogus"})


def test_serialise_action_rejects_unknown_object() -> None:
    """Non-Action inputs raise TypeError (preserves ADT closure)."""
    with pytest.raises(TypeError, match=r"not an Action"):
        env.serialise_action("not-an-action")  # type: ignore[arg-type]
