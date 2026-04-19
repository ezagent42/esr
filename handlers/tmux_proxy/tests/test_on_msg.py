"""PRD 05 F16 — tmux_proxy.on_msg pass-through."""

from __future__ import annotations

from esr import Emit, Event, Route


def test_send_keys_request_forwards_to_cc_tmux() -> None:
    from esr_handler_tmux_proxy.on_msg import on_msg
    from esr_handler_tmux_proxy.state import TmuxProxyState

    s = TmuxProxyState(session_name="sess-A")
    event = Event(
        source="esr://x/actor/feishu_thread.sess-A",
        event_type="send_keys_request",
        args={"session_name": "sess-A", "content": "hi"},
    )
    new_s, actions = on_msg(s, event)
    assert len(actions) == 1
    assert isinstance(actions[0], Emit)
    assert actions[0].adapter == "cc_tmux"
    assert actions[0].action == "send_keys"
    assert actions[0].args == {"session_name": "sess-A", "content": "hi"}


def test_cc_output_routed_to_cc_session() -> None:
    from esr_handler_tmux_proxy.on_msg import on_msg
    from esr_handler_tmux_proxy.state import TmuxProxyState

    s = TmuxProxyState(session_name="sess-A")
    event = Event(
        source="esr://x/adapter/cc_tmux",
        event_type="cc_output",
        args={"session": "sess-A", "text": "hello"},
    )
    new_s, actions = on_msg(s, event)
    assert len(actions) == 1
    assert isinstance(actions[0], Route)
    assert actions[0].target == "cc:sess-A"
    assert actions[0].msg == {"session": "sess-A", "text": "hello"}


def test_unknown_event_ignored() -> None:
    from esr_handler_tmux_proxy.on_msg import on_msg
    from esr_handler_tmux_proxy.state import TmuxProxyState

    s = TmuxProxyState(session_name="s")
    _ = on_msg(s, Event(source="esr://x/y/z", event_type="other", args={}))
