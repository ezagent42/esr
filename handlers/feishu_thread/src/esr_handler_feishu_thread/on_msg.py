"""Feishu thread-proxy handler (PRD 05 F12 / F13 / F14).

Bi-directional mediator between one Feishu thread and one CC session:

 - F12 inbound ``feishu_msg_received``: dedup-check the msg_id;
   if fresh, emit an ``ack`` reaction back to Feishu + a ``send_keys``
   directive to cc_tmux so CC sees the user's input. The state
   stores the originating chat_id on the first message so F13 can
   route replies back to the right Feishu chat.
 - F13 outbound ``cc_output``: if we have a chat_id, emit
   ``send_message`` back to Feishu with the CC output as the body.
 - F14: there is no ``on_spawn`` hook — initial state comes from the
   pattern's ``init_directive`` (thread_id param). Asserting here
   by not defining an ``on_spawn`` symbol in the module.

Pure function per spec §4.
"""

from __future__ import annotations

from esr import Action, Emit, Event, handler

from esr_handler_feishu_thread.state import FeishuThreadState


@handler(actor_type="feishu_thread_proxy", name="on_msg")
def on_msg(
    state: FeishuThreadState, event: Event
) -> tuple[FeishuThreadState, list[Action]]:
    """Dispatch inbound + outbound events on a Feishu thread proxy."""
    if event.event_type == "feishu_msg_received":
        return _handle_inbound(state, event)
    if event.event_type == "cc_output":
        return _handle_outbound(state, event)
    return state, []


def _handle_inbound(
    state: FeishuThreadState, event: Event
) -> tuple[FeishuThreadState, list[Action]]:
    msg_id = str(event.args.get("msg_id", ""))
    if msg_id and msg_id in state.dedup:
        return state, []

    new_state = state.with_added_dedup(msg_id)
    # Capture chat_id on first message so outbound F13 can reply.
    chat_id = str(event.args.get("chat_id", ""))
    if chat_id and not new_state.chat_id:
        new_state = new_state.with_chat_id(chat_id)

    actions: list[Action] = [
        Emit(adapter="feishu", action="react", args={"msg_id": msg_id, "emoji": "ack"}),
        Emit(
            adapter="cc_tmux",
            action="send_keys",
            args={
                "session_name": state.thread_id,
                "content": str(event.args.get("content", "")),
            },
        ),
    ]
    return new_state, actions


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
