"""tmux-proxy handler (PRD 05 F16).

Pass-through bridge between feishu_thread_proxy (upstream) and
cc_session (downstream). Two directions:

 - ``send_keys_request`` (from upstream) → Emit cc_tmux.send_keys
   with the caller's args verbatim.
 - ``cc_output`` (from cc_tmux adapter) → Route to the bound cc
   session actor so the cc_session handler can reverse-route it
   up to the thread.
"""

from __future__ import annotations

from esr import Action, Emit, Event, Route, handler

from esr_handler_tmux_proxy.state import TmuxProxyState


# Pure pass-through bridge (Emit + Route only) — no user-facing
# actions; declare empty permissions explicitly.
@handler(actor_type="tmux_proxy", name="on_msg", permissions=[])
def on_msg(
    state: TmuxProxyState, event: Event
) -> tuple[TmuxProxyState, list[Action]]:
    if event.event_type == "send_keys_request":
        return state, [
            Emit(adapter="cc_tmux", action="send_keys", args=dict(event.args)),
        ]
    if event.event_type == "cc_output":
        # Route ``msg`` must be a full event-shaped dict (event_type +
        # args) — downstream cc_session.on_msg dispatches on event_type,
        # and handler_worker.process_handler_call requires event_type
        # on the envelope payload. Wrapping keeps the hop transparent.
        return state, [
            Route(
                target=f"cc:{state.session_name}",
                msg={"event_type": "cc_output", "args": dict(event.args)},
            ),
        ]
    return state, []
