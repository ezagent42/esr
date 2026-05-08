"""PRD 05 F18 / F19 — cc_session.on_msg reverse route + ignores."""

from __future__ import annotations

from esr import Event, Route


def test_cc_output_reverse_routes_to_parent_thread() -> None:
    from esr_handler_cc_session.on_msg import on_msg
    from esr_handler_cc_session.state import CcSessionState

    s = CcSessionState(session_name="sess-A", parent_thread="threadA")
    event = Event(
        source="esr://x/actor/cc_proxy.sess-A",
        event_type="cc_output",
        args={"text": "claude output", "session": "sess-A"},
    )
    new_s, actions = on_msg(s, event)
    assert len(actions) == 1
    assert isinstance(actions[0], Route)
    assert actions[0].target == "thread:threadA"
    assert actions[0].msg == {
        "event_type": "cc_output",
        "args": {"text": "claude output", "session": "sess-A"},
    }


def test_cc_output_without_parent_thread_is_silent() -> None:
    from esr_handler_cc_session.on_msg import on_msg
    from esr_handler_cc_session.state import CcSessionState

    s = CcSessionState(session_name="sess-A")  # no parent_thread
    event = Event(source="esr://x/y/z", event_type="cc_output", args={"text": "x"})
    new_s, actions = on_msg(s, event)
    assert actions == []


def test_unknown_event_ignored() -> None:
    from esr_handler_cc_session.on_msg import on_msg
    from esr_handler_cc_session.state import CcSessionState

    s = CcSessionState(session_name="sess-A", parent_thread="threadA")
    event = Event(source="esr://x/y/z", event_type="other", args={})
    new_s, actions = on_msg(s, event)
    assert actions == []
