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

    # TODO Task 2.3-2.5: MCP stdio server, notification dispatch, tool dispatch
    # For now Task 2.2 wires phx_client so we can smoke-test WS connection.
    from cc_channel_runner.phx_client import PhoenixChannelClient

    client = PhoenixChannelClient(
        f"{args.esrd_url}/channel/socket/websocket?vsn=2.0.0"
    )
    try:
        await client.connect()
        await client.join(f"cli:channel/{args.session_id}")
        log.info("phx_join acked; idling")
        # Hold connection open until interrupted
        await asyncio.Event().wait()
    finally:
        await client.close()


if __name__ == "__main__":
    asyncio.run(main())
