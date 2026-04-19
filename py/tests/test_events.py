"""PRD 02 F03 — Event + Directive dataclasses."""

from __future__ import annotations

import pytest

from esr.events import Directive, Event


def test_event_fields() -> None:
    e = Event(
        source="esr://localhost/adapter/feishu-shared",
        event_type="msg_received",
        args={"content": "hi", "msg_id": "m1"},
    )
    assert e.event_type == "msg_received"
    assert e.args["content"] == "hi"
    assert e.source.startswith("esr://")


def test_directive_fields() -> None:
    d = Directive(adapter="cc_tmux", action="send_keys", args={"session": "a", "content": "h"})
    assert d.adapter == "cc_tmux"
    assert d.action == "send_keys"
    assert d.args["session"] == "a"


def test_event_is_frozen() -> None:
    e = Event(source="s", event_type="e", args={})
    with pytest.raises(Exception):  # noqa: B017
        e.event_type = "other"  # type: ignore[misc]


def test_directive_is_frozen() -> None:
    d = Directive(adapter="a", action="b", args={})
    with pytest.raises(Exception):  # noqa: B017
        d.action = "other"  # type: ignore[misc]


def test_event_from_envelope() -> None:
    """Deserialise an event from an IPC envelope dict."""
    envelope = {
        "source": "esr://localhost/adapter/feishu",
        "event_type": "msg_received",
        "args": {"chat_id": "oc_abc"},
    }
    e = Event.from_envelope(envelope)
    assert e.source == "esr://localhost/adapter/feishu"
    assert e.event_type == "msg_received"
    assert e.args == {"chat_id": "oc_abc"}
