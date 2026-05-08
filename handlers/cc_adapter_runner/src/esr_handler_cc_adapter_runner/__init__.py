"""PR-9 T11a placeholder handler for cc_adapter_runner actor_type.

CCProcess (runtime/lib/esr/peers/cc_process.ex) calls
`HandlerRouter.call("cc_adapter_runner", ...)` with a payload whose
`handler` field is `"cc_adapter_runner.on_msg"`. handler_worker imports
`esr_handler_cc_adapter_runner.on_msg` by convention (see
py/src/esr/ipc/handler_worker.py line ~258), and the `@handler`
decorator in `on_msg.py` registers the function under
`HANDLER_REGISTRY["cc_adapter_runner.on_msg"]`.

This placeholder's job: respond to the `text` event with a `reply`
action so e2e scenario-01 step 2's `sent_messages 'ack'` assertion
passes, proving the full inbound→outbound routing chain. The real CC
pipeline (claude CLI under a PTY, cc_mcp stdio bridge, MCP `reply`
tool → esr-channel WS → FCP downstream) lands in T11b.
"""
__version__ = "0.1.0"
