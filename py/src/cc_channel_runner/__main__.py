#!/usr/bin/env python3
"""ESR CC-channel stdio bridge.

CC spawns this as a subprocess via mcp.json command+args.
Pipes MCP stdio ↔ Phoenix Channel WebSocket on cli:channel/<sid>.
Lifecycle: stdio EOF (CC dies → pipe closes → Python exits). No ppid watchdog.

Spec: docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md (rev-7)
"""

import argparse
import asyncio
import logging
import sys


def _setup_logging(session_id: str):
    """Log to stderr only; stdout is reserved for MCP frames."""
    short = session_id[:8] if len(session_id) >= 8 else session_id
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format=f"[cc_channel_runner sid={short}] %(asctime)s %(levelname)s %(message)s",
    )


async def main():
    parser = argparse.ArgumentParser(prog="cc_channel_runner")
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--esrd-url", required=True)
    args = parser.parse_args()

    _setup_logging(args.session_id)
    log = logging.getLogger("cc_channel_runner")
    log.info("starting esrd_url=%s", args.esrd_url)

    from cc_channel_runner.mcp_server import BridgeMCPServer
    from cc_channel_runner.phx_client import PhoenixChannelClient
    from cc_channel_runner.phx_receive import phx_receive_loop

    client = PhoenixChannelClient(
        f"{args.esrd_url}/channel/socket/websocket?vsn=2.0.0"
    )
    mcp_server = BridgeMCPServer()
    mcp_server.set_phx_client(client)
    mcp_server.set_session_id(args.session_id)

    try:
        await client.connect()
        await client.join(f"cli:channel/{args.session_id}")
        log.info("phx_join acked; starting MCP stdio loop + envelope dispatch")

        # Run both directions concurrently. If either ends (CC closes
        # stdio → mcp_server.start returns; or WS dies → recv loop
        # raises), cancel the other for clean shutdown.
        mcp_task = asyncio.create_task(mcp_server.start())
        recv_task = asyncio.create_task(phx_receive_loop(client, mcp_server))
        done, pending = await asyncio.wait(
            {mcp_task, recv_task},
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
        for task in done:
            # Surface any exception from the completed side.
            exc = task.exception()
            if exc is not None and not isinstance(exc, SystemExit):
                raise exc
    finally:
        await client.close()


if __name__ == "__main__":
    asyncio.run(main())
