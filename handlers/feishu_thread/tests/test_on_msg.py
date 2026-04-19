"""PRD 05 F12 / F13 / F14 — feishu_thread.on_msg."""

from __future__ import annotations

from esr import Emit, Event


def _inbound(msg_id: str, content: str = "hi", chat_id: str = "oc_abc") -> Event:
    return Event(
        source="esr://localhost/adapter/feishu",
        event_type="feishu_msg_received",
        args={"msg_id": msg_id, "content": content, "chat_id": chat_id},
    )


def _cc_output(text: str) -> Event:
    return Event(
        source="esr://localhost/adapter/cc_tmux",
        event_type="cc_output",
        args={"text": text, "session": "threadA"},
    )


# --- F12: inbound ack + forward ---------------------------------------


def test_inbound_msg_emits_react_and_send_keys() -> None:
    from esr_handler_feishu_thread.on_msg import on_msg
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState(thread_id="threadA")
    new_s, actions = on_msg(s, _inbound("om_1", content="hi there"))

    assert len(actions) == 2
    react, send_keys = actions
    assert isinstance(react, Emit)
    assert react.adapter == "feishu-shared"
    assert react.action == "react"
    assert react.args["msg_id"] == "om_1"
    assert isinstance(send_keys, Emit)
    assert send_keys.adapter == "cc_tmux"
    assert send_keys.action == "send_keys"
    assert send_keys.args["session_name"] == "threadA"
    assert send_keys.args["content"] == "hi there"

    # dedup + chat_id captured
    assert "om_1" in new_s.dedup
    assert new_s.chat_id == "oc_abc"


def test_duplicate_inbound_produces_no_actions() -> None:
    from esr_handler_feishu_thread.on_msg import on_msg
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState(thread_id="threadA", dedup=frozenset({"om_1"}), dedup_order=("om_1",))
    new_s, actions = on_msg(s, _inbound("om_1"))
    assert actions == []
    # dedup unchanged
    assert new_s.dedup == frozenset({"om_1"})


# --- F13: outbound cc_output → send_message ---------------------------


def test_cc_output_emits_send_message_to_feishu() -> None:
    from esr_handler_feishu_thread.on_msg import on_msg
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState(thread_id="threadA", chat_id="oc_abc")
    new_s, actions = on_msg(s, _cc_output("hello from cc"))

    assert len(actions) == 1
    emit = actions[0]
    assert isinstance(emit, Emit)
    assert emit.adapter == "feishu-shared"
    assert emit.action == "send_message"
    assert emit.args["chat_id"] == "oc_abc"
    assert emit.args["content"] == "hello from cc"


def test_cc_output_without_chat_id_is_silent() -> None:
    """A cc_output arriving before any inbound message (no chat_id yet) → (state, [])."""
    from esr_handler_feishu_thread.on_msg import on_msg
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState(thread_id="threadA")
    new_s, actions = on_msg(s, _cc_output("orphaned"))
    assert actions == []


# --- F14: no on_spawn hook --------------------------------------------


def test_no_on_spawn_symbol_exported() -> None:
    """The pure-function model has no lifecycle callback (PRD 05 F14)."""
    import esr_handler_feishu_thread.on_msg as module

    assert not hasattr(module, "on_spawn")


# --- unknown events ---------------------------------------------------


def test_arbitrary_event_ignored() -> None:
    from esr_handler_feishu_thread.on_msg import on_msg
    from esr_handler_feishu_thread.state import FeishuThreadState

    s = FeishuThreadState(thread_id="t")
    new_s, actions = on_msg(s, Event(source="esr://x/y/z", event_type="whatever", args={}))
    assert actions == []
