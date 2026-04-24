"""esr-channel MCP stdio bridge (spec §3.1, §6).

Run as: python -m esr_cc_mcp.channel

Reads env vars for identity:
  ESR_ESRD_URL    explicit override; when unset the bridge reads
                  $ESRD_HOME/$ESR_INSTANCE/esrd.port (see
                  _resolve_from_port_file below) and falls back to
                  ws://127.0.0.1:4001 if the port file is absent.
  ESRD_HOME       default ~/.esrd
  ESR_INSTANCE    default "default"
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
from pathlib import Path
from typing import Any

import anyio
import mcp.server.stdio
from mcp.server.lowlevel import NotificationOptions, Server
from mcp.server.models import InitializationOptions
from mcp.shared.message import SessionMessage
from mcp.types import JSONRPCMessage, JSONRPCNotification, TextContent, Tool

from esr_cc_mcp.tools import list_tool_schemas
from esr_cc_mcp.ws_client import EsrWSClient

logging.basicConfig(level=logging.INFO,
                    format="[esr-channel] %(asctime)s %(levelname)s %(message)s",
                    stream=sys.stderr)
log = logging.getLogger("esr-channel")

_pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
_ws: EsrWSClient | None = None
_mcp_server: Server | None = None
# PR-9 T11b.4b: write_stream captured in _run_stdio so _handle_inbound can
# emit the raw `notifications/claude/channel` JSON-RPC notification that
# Claude Code's channel registration listens for. Matches the cc-openclaw
# reference's `inject_message` pattern.
_stdio_write_stream: Any = None


def _resolve_from_port_file() -> str:
    """Task 8 (DI-3): discover esrd's WS URL from the port file.

    Reads ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` (defaults ``~/.esrd`` /
    ``default``) and returns ``ws://127.0.0.1:<port>``. Falls back to
    ``ws://127.0.0.1:4001`` if the file is absent or contains non-decimal
    content — keeps the dev path (``mix phx.server`` on 4001) working.

    ``launchctl kickstart`` can restart esrd on any free port, so this
    helper is re-invoked by the reconnect loop (via the URL callable
    passed to :class:`EsrWSClient`) to follow port changes.
    """
    home = os.environ.get("ESRD_HOME") or os.path.expanduser("~/.esrd")
    instance = os.environ.get("ESR_INSTANCE", "default")
    port_file = Path(home) / instance / "esrd.port"
    try:
        port_txt = port_file.read_text().strip()
    except (FileNotFoundError, OSError):
        return "ws://127.0.0.1:4001"
    if not port_txt.isdigit():
        return "ws://127.0.0.1:4001"
    return f"ws://127.0.0.1:{port_txt}"


def _resolve_url() -> str:
    """Top-level URL discovery: ``ESR_ESRD_URL`` wins (explicit
    override for e2e / remote esrd), else fall back to the port file.
    Invoked once at startup and once per reconnect attempt so the
    bridge follows ``launchctl kickstart``.
    """
    return os.environ.get("ESR_ESRD_URL") or _resolve_from_port_file()


async def _handle_inbound(envelope: dict[str, Any]) -> None:
    """Route inbound frames by kind (spec §5.3)."""
    kind = envelope.get("kind")
    if kind == "tool_result":
        req_id = envelope.get("req_id")
        fut = _pending.pop(req_id, None) if req_id else None
        if fut and not fut.done():
            fut.set_result(envelope)
    elif kind == "notification":
        # PR-9 T11b.4b: emit a `notifications/claude/channel` JSON-RPC
        # notification — the exact shape Claude Code listens for when a
        # server declares the `claude/channel` experimental capability
        # (see `docs/notes/claude-code-channels-reference.md`). The
        # frame becomes a `<channel source="..." ...>` tag in CC's
        # conversation context.
        #
        # content = the inbound message body (becomes the tag's inner text)
        # meta    = tag attributes (keys must be [A-Za-z0-9_]+ — other
        #           characters are silently dropped by Claude Code)
        log.info("inbound notification from %s", envelope.get("source", ""))
        if _stdio_write_stream is None:
            log.warning("dropping notification: stdio write stream not ready")
            return

        meta = {
            k: str(v)
            for k, v in {
                "chat_id": envelope.get("chat_id"),
                "message_id": envelope.get("message_id"),
                "user": envelope.get("user"),
                "ts": envelope.get("ts"),
                "thread_id": envelope.get("thread_id"),
                "runtime_mode": envelope.get("runtime_mode", "discussion"),
                "source": envelope.get("source", "feishu"),
            }.items()
            if v
        }
        params = {
            "content": envelope.get("content", ""),
            "meta": meta,
        }

        try:
            notification = JSONRPCNotification(
                jsonrpc="2.0",
                method="notifications/claude/channel",
                params=params,
            )
            session_msg = SessionMessage(message=JSONRPCMessage(notification))
            await _stdio_write_stream.send(session_msg)
        except Exception as exc:  # noqa: BLE001 — stdio write boundary
            log.warning("failed to inject channel notification: %s", exc)
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

    # Task 8 (DI-3): URL discovery reads env first (explicit override)
    # then the port file. Pass the resolver as a callable so EsrWSClient
    # re-reads on every reconnect — the bridge follows launchctl
    # kickstart onto a fresh port.
    sid = os.environ["ESR_SESSION_ID"]
    ws_name = os.environ["ESR_WORKSPACE"]
    chats_json = os.environ.get("ESR_CHAT_IDS", "[]")
    try:
        chats = json.loads(chats_json)
    except (ValueError, TypeError):
        chats = []

    _ws = EsrWSClient(
        url=_resolve_url,
        session_id=sid,
        workspace=ws_name,
        chats=chats,
    )
    server = _build_server()

    async with anyio.create_task_group() as tg:
        tg.start_soon(_ws.connect_and_run, _handle_inbound)
        tg.start_soon(_run_stdio, server)


async def _run_stdio(server: Server) -> None:
    global _stdio_write_stream

    # PR-9 T11b.4b: declare the `claude/channel` experimental capability
    # so Claude Code registers a listener for `notifications/claude/channel`
    # frames we push from `_handle_inbound`. Without this, CC Code treats
    # us as a plain MCP tools server and silently drops the notifications
    # — users' Feishu inbound messages never reach the conversation.
    # See docs/notes/claude-code-channels-reference.md for the contract.
    #
    # Instructions string goes into CC's system prompt so it knows the
    # meta-field semantics + how to route replies back via tools.
    instructions = (
        "Messages from users arrive as <channel source=\"feishu\" "
        "chat_id=\"...\" message_id=\"...\" user=\"...\"> tags. "
        "Reply with the `reply` MCP tool, passing the chat_id from the tag. "
        "For file output, use the `send_file` tool with the same chat_id."
    )

    init_opts = InitializationOptions(
        server_name="esr-channel",
        server_version="0.2.0",
        capabilities=server.get_capabilities(
            notification_options=NotificationOptions(),
            experimental_capabilities={"claude/channel": {}},
        ),
        instructions=instructions,
    )
    async with mcp.server.stdio.stdio_server() as (read, write):
        _stdio_write_stream = write
        try:
            await server.run(read, write, init_opts)
        finally:
            _stdio_write_stream = None


def main() -> int:
    try:
        anyio.run(_main)
        return 0
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
