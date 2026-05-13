"""Phoenix Channel envelope dispatcher.

Drains the WS recv queue and translates `event="envelope"` frames into
either MCP server-pushed notifications (`notifications/claude/channel`)
or resolutions of pending tool_invoke futures (Task 2.5).

Per spec rev-7 + channel_channel.ex inbound contract:

    payload.kind=notification             → MCP notification
    payload.kind=tool_result              → resolve pending future
    payload.kind=cleanup_check_requested  → log + (TODO) reply on channel
    payload.kind=session_killed           → graceful shutdown
    other                                 → WARNING + drop

Stub-as-of Task 2.3: the loop signature is final but the body is empty
(returns immediately). Task 2.4 wires the dispatch logic. Wire is split
into its own module rather than living inside __main__.py because it's
going to grow: tool_result handling, cleanup ACKs, and the
shutdown-on-session-killed path all land here.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from cc_channel_runner.mcp_server import BridgeMCPServer
    from cc_channel_runner.phx_client import PhoenixChannelClient

log = logging.getLogger("cc_channel_runner.phx_receive")


async def phx_receive_loop(
    client: PhoenixChannelClient,
    mcp_server: BridgeMCPServer,
) -> None:
    """Drain inbound WS frames and dispatch on `envelope.kind`.

    Task 2.4 fills the body. For Task 2.3 the function exists only so
    `__main__.py` can wire it into the asyncio.gather setup without a
    second commit churn.
    """
    log.info("phx_receive_loop started (stub — Task 2.4 fills dispatch)")
    async for frame in client.receive():
        log.debug("phx_receive_loop: unhandled frame %r", frame)
        # Task 2.4 fills dispatch here. Avoid unused-arg lint by
        # touching mcp_server — phx_receive_loop must hold the
        # reference for Task 2.4 wiring.
        _ = mcp_server
