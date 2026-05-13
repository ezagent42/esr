"""Phoenix Channel envelope dispatcher.

Drains the WS recv queue and translates `event="envelope"` frames into
either MCP server-pushed notifications (`notifications/claude/channel`)
or resolutions of pending tool_invoke futures (Task 2.5).

Per spec rev-7 + channel_channel.ex inbound contract, server-pushed
`envelope` events carry a `payload` map; we dispatch on `payload.kind`:

    payload.kind=tool_result              → resolve pending future (Task 2.5)
    payload.kind=session_killed           → graceful shutdown
    payload.kind=cleanup_check_requested  → forward as MCP notification
    payload.kind=notification (or absent) → forward as MCP notification
    other                                 → WARNING + drop

The "kind absent" case matches the historical broadcast shape from
`cc_process.ex broadcast_notification/2` — feishu inbound envelopes
are forwarded verbatim without a top-level kind tag. They're
indistinguishable from kind=notification at the wire level.

This module owns the bridge's stop signal: a `session_killed`
envelope raises `_BridgeShutdown` to bubble out of the recv loop;
`__main__.py` catches it and exits cleanly.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from cc_channel_runner.notification import build_notification_params

if TYPE_CHECKING:
    from cc_channel_runner.mcp_server import BridgeMCPServer
    from cc_channel_runner.phx_client import PhoenixChannelClient

log = logging.getLogger("cc_channel_runner.phx_receive")


class BridgeShutdown(Exception):
    """Signal a graceful bridge shutdown (e.g. session_killed envelope).

    Public (not _-prefixed) because `__main__.py` may catch it; raising
    a SystemExit-alike sentinel keeps the recv loop short-circuit
    behavior local without polluting global state.
    """


async def phx_receive_loop(
    client: PhoenixChannelClient,
    mcp_server: BridgeMCPServer,
) -> None:
    """Drain inbound WS frames and dispatch on `envelope.kind`.

    Iterates `client.receive()` (an async generator of inbound non-
    reply frames). For each `event="envelope"` frame, dispatches on
    payload kind. Non-envelope events (phx_close, phx_error, plus
    anything unrecognized) are logged.

    The phx_client recv loop ends on WS close; `receive()` then yields
    no further items and this coroutine returns. `__main__.py`'s
    asyncio.wait treats either side ending as bridge shutdown.
    """
    log.info("phx_receive_loop started")
    async for frame in client.receive():
        event = frame.get("event")
        payload = frame.get("payload") or {}

        if event == "envelope":
            await _dispatch_envelope(mcp_server, payload)
        elif event in ("phx_close", "phx_error"):
            log.warning("phx_receive_loop: channel terminated event=%s", event)
            raise BridgeShutdown(f"phx channel {event}")
        else:
            log.debug("phx_receive_loop: ignoring event=%r", event)


async def _dispatch_envelope(
    mcp_server: BridgeMCPServer, payload: dict[str, Any]
) -> None:
    """Route a single envelope frame on its `kind`."""
    kind = payload.get("kind")

    if kind == "tool_result":
        _resolve_pending_tool_call(mcp_server, payload)
        return

    if kind == "session_killed":
        log.info("phx_receive_loop: session_killed received; shutting down")
        raise BridgeShutdown("session_killed")

    if kind == "cleanup_check_requested":
        # Forward to CC the same way `mcp_controller.ex sse_loop`
        # does today: through `notifications/claude/channel`. The
        # actual cleanup_check_response is sent by CC via the
        # `session.signal_cleanup` MCP tool (out of scope for the
        # bridge — that's a plugin tool the BEAM peer handles).
        log.info("phx_receive_loop: forwarding cleanup_check_requested")
        params = build_notification_params(payload)
        await mcp_server.send_channel_notification(params)
        return

    if kind == "notification" or kind is None:
        # The cc_process.ex broadcast path doesn't tag with a kind;
        # treat absent-kind envelopes as notifications. Explicit
        # `kind=notification` is supported for symmetry.
        params = build_notification_params(payload)
        await mcp_server.send_channel_notification(params)
        return

    log.warning("phx_receive_loop: dropping unknown envelope kind=%r", kind)


def _resolve_pending_tool_call(
    mcp_server: BridgeMCPServer, payload: dict[str, Any]
) -> None:
    """Resolve a Task-2.5 pending future if its req_id matches."""
    req_id = payload.get("req_id")
    if not isinstance(req_id, str):
        log.warning(
            "phx_receive_loop: tool_result without string req_id: %r", payload
        )
        return

    future = mcp_server.pending_tool_calls.pop(req_id, None)
    if future is None:
        # Late arrival after a tool-call timeout already failed the
        # future, or a stray result from a peer mis-route. Either way,
        # nothing to resolve.
        log.warning(
            "phx_receive_loop: tool_result for unknown req_id=%s", req_id
        )
        return
    if future.done():
        log.warning(
            "phx_receive_loop: tool_result for already-done future req_id=%s",
            req_id,
        )
        return
    future.set_result(payload)
