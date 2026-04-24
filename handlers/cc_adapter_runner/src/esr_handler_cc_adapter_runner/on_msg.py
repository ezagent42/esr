"""PR-9 T11a placeholder on_msg for the cc_adapter_runner actor_type.

Translates a `text` event (user's inbound message forwarded by
FeishuChatProxy → CCProcess) into a `Reply` action so the full
inbound→outbound routing chain can be exercised end-to-end without
requiring a real Claude CLI in tmux yet.

Real CC wire-up (claude CLI + cc_mcp stdio bridge + esr-channel WS)
lands in T11b; that version will likely replace this with a
`SendInput` action routing the text into the tmux pane, and let CC's
own MCP `reply` tool produce the outbound reply via a different path.
"""

from __future__ import annotations

from esr import Action, Event, Reply, handler

from esr_handler_cc_adapter_runner.state import CcAdapterRunnerState


@handler(actor_type="cc_adapter_runner", name="on_msg", permissions=[])
def on_msg(
    state: CcAdapterRunnerState, event: Event
) -> tuple[CcAdapterRunnerState, list[Action]]:
    """Dispatch one user-inbound event."""
    if event.event_type == "text":
        text = event.args.get("text", "") if isinstance(event.args, dict) else ""
        new_state = CcAdapterRunnerState(message_count=state.message_count + 1)
        return new_state, [Reply(text=f"ack: {text}")]

    # tmux_output or unknown events — no-op at this layer. TmuxProcess
    # already captured them; downstream (cc_proxy/cc_session handler)
    # closes the loop back to Feishu if routing is wired for that.
    return state, []
