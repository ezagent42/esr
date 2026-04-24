"""on_msg for the cc_adapter_runner actor_type (PR-9 T11b.7).

Translates a `text` event (user's inbound message forwarded by
FeishuChatProxy → CCProcess) into a `SendInput` action that
`CCProcess.dispatch_action/2` broadcasts on Phoenix pubsub topic
`cli:channel/<session_id>`. `cc_mcp` — the MCP stdio bridge running
as a child of the claude CLI in the session's tmux pane — consumes
the envelope from the WS, emits a `notifications/claude/channel`
JSON-RPC notification into CC's conversation context as a
`<channel>` tag, and CC decides whether/how to respond using its
own `reply` / `react` / `send_file` MCP tools.

Pre-T11b this function returned `[Reply(text=f"ack: {text}")]` as a
placeholder so the routing chain could be exercised without a real
Claude CLI in tmux. Now that T11b.3 / T11b.4 / T11b.6 wire the full
round-trip (claude in tmux + cc_mcp channel + FCP tool_invoke
dispatch), the handler's job simplifies to "push the user's text
into CC's context" — CC itself composes the response.
"""

from __future__ import annotations

from esr import Action, Event, SendInput, handler

from esr_handler_cc_adapter_runner.state import CcAdapterRunnerState


@handler(actor_type="cc_adapter_runner", name="on_msg", permissions=[])
def on_msg(
    state: CcAdapterRunnerState, event: Event
) -> tuple[CcAdapterRunnerState, list[Action]]:
    """Dispatch one user-inbound event."""
    if event.event_type == "text":
        text = event.args.get("text", "") if isinstance(event.args, dict) else ""
        new_state = CcAdapterRunnerState(message_count=state.message_count + 1)
        return new_state, [SendInput(text=text)]

    # tmux_output events — tmux captures CC's TUI chrome (prompts,
    # formatting). Post-T11b the reply path runs through cc_mcp's
    # `reply` MCP tool, not tmux stdout, so this handler has nothing
    # to do here. Drop silently.
    return state, []
