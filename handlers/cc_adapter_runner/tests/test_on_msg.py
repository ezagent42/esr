"""PR-9 T11b.7: cc_adapter_runner handler returns SendInput.

These tests pin the wire contract between the Elixir `CCProcess` and
this handler. Post-T11b the handler no longer composes replies — it
just pushes the user's inbound text onto CC's context via SendInput,
and CC itself decides the reply through its own `reply` MCP tool.
"""
from __future__ import annotations

from esr import Event, SendInput
from esr.ipc.envelope import serialise_action

from esr_handler_cc_adapter_runner.on_msg import on_msg
from esr_handler_cc_adapter_runner.state import CcAdapterRunnerState


def test_text_event_produces_send_input_action() -> None:
    state = CcAdapterRunnerState()
    event = Event(source="esr://localhost/x", event_type="text", args={"text": "hello"})

    new_state, actions = on_msg(state, event)

    assert new_state.message_count == 1
    assert actions == [SendInput(text="hello")]


def test_send_input_serialises_to_cc_process_wire_shape() -> None:
    """CCProcess.dispatch_action/2 pattern-matches on
    `%{"type" => "send_input", "text" => _}` (runtime/lib/esr/peers/cc_process.ex)."""
    state = CcAdapterRunnerState()
    event = Event(source="esr://localhost/x", event_type="text", args={"text": "hi"})

    _, actions = on_msg(state, event)
    wire = [serialise_action(a) for a in actions]

    assert wire == [{"type": "send_input", "text": "hi"}]


def test_non_text_event_is_noop() -> None:
    state = CcAdapterRunnerState(message_count=5)
    event = Event(source="esr://localhost/x", event_type="other_event", args={"bytes": "x"})

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
