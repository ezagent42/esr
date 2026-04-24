"""PR-9 T11a: cc_adapter_runner placeholder handler contract.

These tests pin the shape that `Esr.Peers.CCProcess.dispatch_action/2`
expects (`{"type": "reply", "text": ...}`) and ensure the handler
increments its internal counter between invocations so the e2e path
is distinguishable.
"""
from __future__ import annotations

from esr import Event, Reply
from esr.ipc.envelope import serialise_action

from esr_handler_cc_adapter_runner.on_msg import on_msg
from esr_handler_cc_adapter_runner.state import CcAdapterRunnerState


def test_text_event_produces_reply_action() -> None:
    state = CcAdapterRunnerState()
    event = Event(source="esr://localhost/x", event_type="text", args={"text": "hello"})

    new_state, actions = on_msg(state, event)

    assert new_state.message_count == 1
    assert actions == [Reply(text="ack: hello")]


def test_reply_action_serialises_to_cc_process_wire_shape() -> None:
    """CCProcess.dispatch_action/2 pattern-matches on {type: "reply", text: _}."""
    state = CcAdapterRunnerState()
    event = Event(source="esr://localhost/x", event_type="text", args={"text": "hi"})

    _, actions = on_msg(state, event)
    wire = [serialise_action(a) for a in actions]

    assert wire == [{"type": "reply", "text": "ack: hi"}]


def test_non_text_event_is_noop() -> None:
    state = CcAdapterRunnerState(message_count=5)
    event = Event(source="esr://localhost/x", event_type="tmux_output", args={"bytes": "x"})

    new_state, actions = on_msg(state, event)

    assert new_state == state  # unchanged
    assert actions == []


def test_message_count_increments_across_invocations() -> None:
    state = CcAdapterRunnerState()
    event = Event(source="esr://localhost/x", event_type="text", args={"text": "one"})

    s1, _ = on_msg(state, event)
    s2, _ = on_msg(s1, event)
    s3, _ = on_msg(s2, event)

    assert (s1.message_count, s2.message_count, s3.message_count) == (1, 2, 3)
