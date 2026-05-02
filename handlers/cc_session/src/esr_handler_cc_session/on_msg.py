"""cc_session handler (PRD 05 F18 / F19).

Lives at the CC session end of the proxy bridge. When the cc_mcp
adapter yields a ``cc_output`` event, this handler reverse-routes
it up to the feishu_thread actor that owns this session — closing
the loop back to Feishu.
"""

from __future__ import annotations

from esr import Action, Event, Route, handler

from esr_handler_cc_session.state import CcSessionState


# Pure internal bridge (reverse-routing cc_output → feishu_thread) —
# no user-facing actions; declare empty permissions explicitly.
@handler(actor_type="cc_proxy", name="on_msg", permissions=[])
def on_msg(
    state: CcSessionState, event: Event
) -> tuple[CcSessionState, list[Action]]:
    """Dispatch a cc_proxy event."""
    if event.event_type == "cc_output":
        if not state.parent_thread:
            return state, []
        return state, [
            Route(
                target=f"thread:{state.parent_thread}",
                msg={"event_type": "cc_output", "args": dict(event.args)},
            )
        ]
    return state, []
