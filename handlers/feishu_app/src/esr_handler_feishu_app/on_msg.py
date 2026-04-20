"""Feishu app-proxy handler (PRD 05 F07 / F08 / F09).

Recognises ``/new-thread <id>`` — the sole user-facing command that
expands the app into a per-thread actor topology via an
``InvokeCommand`` action — and routes every other well-formed
message into its bound thread actor.

Pure function per spec §4: `(state, event) -> (new_state, actions)`.
No I/O, no module-level mutable state.
"""

from __future__ import annotations

from esr import Action, Event, InvokeCommand, Route, handler

from esr_handler_feishu_app.state import FeishuAppState

_NEW_THREAD_PREFIX = "/new-thread "


@handler(actor_type="feishu_app_proxy", name="on_msg")
def on_msg(
    state: FeishuAppState, event: Event
) -> tuple[FeishuAppState, list[Action]]:
    """Dispatch a Feishu inbound event."""
    if event.event_type != "msg_received":
        return state, []

    content = str(event.args.get("content", ""))

    if content.startswith(_NEW_THREAD_PREFIX):
        thread_id = content[len(_NEW_THREAD_PREFIX):].strip()
        if not thread_id:
            return state, []  # malformed
        if thread_id in state.bound_threads:
            return state, []  # idempotent
        # Pass chat_id through so the spawned feishu_thread_proxy can
        # reply to the same chat without waiting for a subsequent inbound
        # message (final_gate.sh --live's L4 depends on a reply firing
        # from the first /new-thread alone). Empty-string chat_id is
        # OK — feishu_thread.on_msg just no-ops outbound until it
        # learns one.
        chat_id = str(event.args.get("chat_id", ""))
        return state.with_added_thread(thread_id), [
            InvokeCommand(
                name="feishu-thread-session",
                params={"thread_id": thread_id, "chat_id": chat_id},
            ),
        ]

    # F08: route regular messages into their bound thread.
    thread_id = event.args.get("thread_id")
    if thread_id and thread_id in state.bound_threads:
        return state, [Route(target=f"thread:{thread_id}", msg=content)]

    return state, []
