"""Feishu thread-proxy handler (v0.2 §3.3).

Primary path switched from inbound-then-fanout (v0.1) to esr-channel
notification (v0.2). The v0.1 `feishu_msg_received` branch was dead
code — adapter emits `msg_received`. This rewrite:

- matches on `msg_received` (correct event name)
- emits `notify_session` to the synthetic `esr-channel` "adapter"
  which PeerServer short-circuits via SessionRegistry
- keeps `cc_output` → `send_message` for the scenario mock path
"""
from __future__ import annotations

from esr import Action, Emit, Event, handler

from esr_handler_feishu_thread.state import FeishuThreadState


@handler(
    actor_type="feishu_thread_proxy",
    name="on_msg",
    permissions=["msg.send", "session.switch"],
)
def on_msg(
    state: FeishuThreadState, event: Event
) -> tuple[FeishuThreadState, list[Action]]:
    if event.event_type == "msg_received":
        return _handle_inbound(state, event)
    if event.event_type == "cc_output":
        return _handle_outbound(state, event)
    return state, []


def _handle_inbound(
    state: FeishuThreadState, event: Event
) -> tuple[FeishuThreadState, list[Action]]:
    msg_id = str(event.args.get("message_id", ""))
    if msg_id and msg_id in state.dedup:
        return state, []

    new_state = state.with_added_dedup(msg_id) if msg_id else state
    chat_id = str(event.args.get("chat_id", ""))
    if chat_id and not new_state.chat_id:
        new_state = new_state.with_chat_id(chat_id)

    return new_state, [
        Emit(
            adapter="esr-channel",
            action="notify_session",
            args={
                "session_id": state.thread_id,
                "source": "feishu",
                "chat_id": chat_id,
                "message_id": msg_id,
                "user": str(event.args.get("sender_id", "")),
                "content": str(event.args.get("content", "")),
            },
        )
    ]


def _handle_outbound(
    state: FeishuThreadState, event: Event
) -> tuple[FeishuThreadState, list[Action]]:
    if not state.chat_id:
        return state, []
    text = str(event.args.get("text", ""))
    return state, [
        Emit(
            adapter="feishu",
            action="send_message",
            args={"chat_id": state.chat_id, "content": text},
        )
    ]
