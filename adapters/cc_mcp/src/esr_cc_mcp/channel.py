"""esr-channel MCP stdio bridge (spec §3.1, §6).

Run as: python -m esr_cc_mcp.channel

Reads env vars for identity:
  ESR_ESRD_URL    default ws://127.0.0.1:4001
  ESR_SESSION_ID  required
  ESR_WORKSPACE   required
  ESR_CHAT_IDS    JSON-encoded list of {chat_id, app_id, kind}
  ESR_ROLE        optional (default "dev") — gates _echo tool

Bridges:
  CC stdio ↔ MCP JSON-RPC ↔ EsrWSClient ↔ esrd WS
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import uuid
from typing import Any

import anyio
import mcp.server.stdio
from mcp.server.lowlevel import NotificationOptions, Server
from mcp.server.models import InitializationOptions
from mcp.types import TextContent, Tool

from esr_cc_mcp.tools import list_tool_schemas
from esr_cc_mcp.ws_client import EsrWSClient

logging.basicConfig(level=logging.INFO,
                    format="[esr-channel] %(asctime)s %(levelname)s %(message)s",
                    stream=sys.stderr)
log = logging.getLogger("esr-channel")

_pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
_ws: EsrWSClient | None = None
_mcp_server: Server | None = None


async def _handle_inbound(envelope: dict[str, Any]) -> None:
    """Route inbound frames by kind (spec §5.3)."""
    kind = envelope.get("kind")
    if kind == "tool_result":
        req_id = envelope.get("req_id")
        fut = _pending.pop(req_id, None) if req_id else None
        if fut and not fut.done():
            fut.set_result(envelope)
    elif kind == "notification":
        # Injection landed in P2-5.
        log.info("notification from %s: %r", envelope.get("source"),
                 envelope.get("content", "")[:80])
    elif kind == "session_killed":
        log.warning("session_killed: %s", envelope.get("reason"))
        await asyncio.sleep(0.5)
        sys.exit(0)


async def _invoke_tool(tool: str, args: dict[str, Any]) -> list[TextContent]:
    """Fire tool_invoke to esrd, await tool_result up to 30s."""
    if _ws is None:
        return [TextContent(type="text", text=json.dumps(
            {"ok": False, "error": {"type": "esrd_disconnect",
                                    "message": "WS not yet connected"}}))]

    req_id = str(uuid.uuid4())
    fut: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
    _pending[req_id] = fut

    try:
        await _ws.push({"kind": "tool_invoke", "req_id": req_id,
                        "tool": tool, "args": args})
        result = await asyncio.wait_for(fut, timeout=30.0)
    except asyncio.TimeoutError:
        _pending.pop(req_id, None)
        return [TextContent(type="text", text=json.dumps(
            {"ok": False, "error": {"type": "esrd_disconnect",
                                    "message": "tool_result timeout"}}))]
    except Exception as exc:  # noqa: BLE001
        _pending.pop(req_id, None)
        return [TextContent(type="text", text=json.dumps(
            {"ok": False, "error": {"type": "esrd_disconnect",
                                    "message": str(exc)}}))]

    return [TextContent(type="text", text=json.dumps(
        {"ok": result.get("ok", False),
         "data": result.get("data"),
         "error": result.get("error")}))]


def _build_server() -> Server:
    global _mcp_server
    role = os.environ.get("ESR_ROLE", "dev")
    server = Server("esr-channel")
    _mcp_server = server

    @server.list_tools()
    async def handle_list_tools() -> list[Tool]:
        return list_tool_schemas(role=role)

    @server.call_tool()
    async def handle_call_tool(name: str, args: dict[str, Any]) -> list[TextContent]:
        return await _invoke_tool(name, args)

    return server


async def _main() -> None:
    global _ws

    url = os.environ.get("ESR_ESRD_URL", "ws://127.0.0.1:4001")
    sid = os.environ["ESR_SESSION_ID"]
    ws_name = os.environ["ESR_WORKSPACE"]
    chats_json = os.environ.get("ESR_CHAT_IDS", "[]")
    try:
        chats = json.loads(chats_json)
    except (ValueError, TypeError):
        chats = []

    _ws = EsrWSClient(url=url, session_id=sid, workspace=ws_name, chats=chats)
    server = _build_server()

    async with anyio.create_task_group() as tg:
        tg.start_soon(_ws.connect_and_run, _handle_inbound)
        tg.start_soon(_run_stdio, server)


async def _run_stdio(server: Server) -> None:
    init_opts = InitializationOptions(
        server_name="esr-channel",
        server_version="0.2.0",
        capabilities=server.get_capabilities(
            notification_options=NotificationOptions(),
            experimental_capabilities={},
        ),
    )
    async with mcp.server.stdio.stdio_server() as (read, write):
        await server.run(read, write, init_opts)


def main() -> int:
    try:
        anyio.run(_main)
        return 0
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
