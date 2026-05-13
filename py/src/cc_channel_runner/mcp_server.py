"""MCP stdio server for cc_channel_runner.

Wraps `mcp.server.Server("esr-channel")` and exposes the three tools CC
invokes against the channel: `reply`, `send_file`, `submit_slash`.

The tool handlers in this file are *stubs* for Task 2.3 — they only
return a "not implemented" payload. Tasks 2.4 + 2.5 wire them into the
Phoenix Channel push path and the envelope-driven notification path.

Capability advertised on `initialize`: experimental `claude/channel` —
matches the existing HTTP MCP server (see `runtime/lib/esr_web/
mcp_controller.ex` line 146). When the bridge replaces that controller
in Phase 6, this capability is what Claude Code inspects to decide
whether to listen for `notifications/claude/channel` server-pushes.

Spec: docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from typing import TYPE_CHECKING, Any

from mcp.server import NotificationOptions, Server
from mcp.server.models import InitializationOptions
from mcp.server.stdio import stdio_server
from mcp.shared.session import SessionMessage
from mcp.types import (
    JSONRPCMessage,
    JSONRPCNotification,
    TextContent,
    Tool,
)

if TYPE_CHECKING:
    from cc_channel_runner.phx_client import PhoenixChannelClient

log = logging.getLogger("cc_channel_runner.mcp_server")

# Matches McpController @server_name / @server_version / @protocol_version.
# Bumping requires coordinating with the BEAM side because the HTTP
# controller stays in production until Phase 6 deletes it.
_SERVER_NAME = "esr-channel"
_SERVER_VERSION = "0.3.0"

# Verbatim from `mcp_controller.ex:148-153` — preserves the exact
# wording Claude Code is trained against (the cc plugin treats this
# string as the system-prompt preamble for tool selection).
_INSTRUCTIONS = (
    'Messages from users arrive as <channel source="feishu" '
    'chat_id="..." message_id="..." user="..."> tags. '
    "Reply with the `reply` MCP tool, passing the chat_id from the tag. "
    "For file output, use the `send_file` tool with the same chat_id."
)

# Max wait for a tool_result envelope after pushing a tool_invoke.
# Matches `mcp_controller.ex @tool_call_timeout_ms` so the bridge and
# the HTTP controller fail with the same wall-clock when CC -> peer
# tool execution stalls.
_TOOL_CALL_TIMEOUT_SECS = 30.0

# Tool schemas mirror `Esr.Plugins.ClaudeCode.Mcp.Tools.list/1` (BEAM side).
# Per plan Task 2.5 step 2: Option A — hardcoded for rev-7. The spec
# (§3 non-goals) confirms tool definitions still live in BEAM; the
# bridge proxies invocations but holds its own copy of the schemas so
# `tools/list` can respond without a round-trip.
_TOOL_SCHEMAS: list[Tool] = [
    Tool(
        name="reply",
        description=(
            "Send a message to a chat the channel adapter routes for. "
            "The user reads the channel (Feishu, etc.), not this CC "
            "session — anything the user must see goes through this tool. "
            "chat_id comes from the inbound <channel> tag."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "chat_id": {
                    "type": "string",
                    "description": "Channel chat ID (e.g. Feishu oc_xxx)",
                },
                "text": {"type": "string", "description": "Message text"},
                "current_session_id": {
                    "type": "string",
                    "description": (
                        "Optional. Session id from the inbound notification "
                        "meta — used for multi-session-per-instance routing."
                    ),
                },
            },
            "required": ["chat_id", "text"],
        },
    ),
    Tool(
        name="send_file",
        description=(
            "Send a local file to a channel chat. The adapter uploads it "
            "to the channel (Feishu, etc.) and posts it as an attachment."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "chat_id": {
                    "type": "string",
                    "description": "Channel chat ID",
                },
                "file_path": {
                    "type": "string",
                    "description": "Absolute path to the local file to send",
                },
                "current_session_id": {
                    "type": "string",
                    "description": "Optional. Session id for routing.",
                },
            },
            "required": ["chat_id", "file_path"],
        },
    ),
    Tool(
        name="submit_slash",
        description=(
            "Submit a slash command to the ESR runtime as if the user "
            "had typed it. Output is delivered back via the channel."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "Full slash command including leading '/'",
                },
                "chat_id": {
                    "type": "string",
                    "description": "Channel chat to route the response to",
                },
                "current_session_id": {
                    "type": "string",
                    "description": "Optional. Session id for routing.",
                },
            },
            "required": ["command"],
        },
    ),
]


class BridgeMCPServer:
    """MCP stdio server wrapping `Server("esr-channel")`.

    Holds the bridge state needed by tool handlers and notification
    push: a reference to the Phoenix Channel client (so tool calls can
    be forwarded via `envelope` events) and the active session id (for
    log tagging + topic construction).

    Task 2.3 wires the scaffolding + stubs the three tools. Task 2.4
    fills `send_channel_notification` and the Task 2.5 fills the tool
    handlers with real dispatch.
    """

    def __init__(self) -> None:
        self._server: Server[Any, Any] = Server(
            _SERVER_NAME, instructions=_INSTRUCTIONS
        )
        self._phx_client: PhoenixChannelClient | None = None
        self._session_id: str | None = None
        # Filled by Server.run() once the stdio streams are open.
        # Used by `send_channel_notification` to push server-initiated
        # notifications without going through a request handler.
        self._write_stream: Any | None = None
        # Pending tool_invoke futures keyed by req_id (Task 2.5).
        # Resolved by the phx_receive_loop when a `tool_result`
        # envelope arrives with the matching req_id.
        self._pending_tool_calls: dict[str, asyncio.Future[dict[str, Any]]] = {}
        # Topic format must match `EsrWeb.ChannelChannel.join/3` —
        # `cli:channel/<sid>`. Set when set_session_id is called.
        self._topic: str | None = None

        self._register_handlers()

    # -- configuration ------------------------------------------------

    def set_phx_client(self, client: PhoenixChannelClient) -> None:
        """Inject the Phoenix Channel client for outbound dispatch."""
        self._phx_client = client

    def set_session_id(self, session_id: str) -> None:
        """Set session id (used for log tagging + topic construction)."""
        self._session_id = session_id
        self._topic = f"cli:channel/{session_id}"

    # -- public surface used by phx_receive_loop ----------------------

    @property
    def pending_tool_calls(self) -> dict[str, asyncio.Future[dict[str, Any]]]:
        """Map of req_id → future awaiting a `tool_result` envelope."""
        return self._pending_tool_calls

    async def send_channel_notification(self, params: dict[str, Any]) -> None:
        """Push a server-initiated `notifications/claude/channel` frame.

        Used by the WS-side envelope-dispatch loop when a `notification`
        envelope arrives from BEAM. Writes a raw JSON-RPC notification
        directly to the stdio write stream because the SDK does not
        expose a generic "send server notification" helper for non-
        standard methods.
        """
        if self._write_stream is None:
            log.warning(
                "send_channel_notification: write_stream not ready; "
                "dropping params=%r", params
            )
            return

        notification = JSONRPCNotification(
            jsonrpc="2.0",
            method="notifications/claude/channel",
            params=params,
        )
        message = JSONRPCMessage(notification)
        await self._write_stream.send(SessionMessage(message=message))

    # -- lifecycle ----------------------------------------------------

    async def start(self) -> None:
        """Run the MCP stdio loop.

        Returns when stdin closes (CC died → pipe closed) or when the
        SDK's task group exits. Caller wires this into `asyncio.gather`
        alongside the `phx_receive_loop` so either side dropping shuts
        the bridge down.
        """
        init_opts = InitializationOptions(
            server_name=_SERVER_NAME,
            server_version=_SERVER_VERSION,
            capabilities=self._server.get_capabilities(
                notification_options=NotificationOptions(),
                experimental_capabilities={"claude/channel": {}},
            ),
        )

        async with stdio_server() as (read_stream, write_stream):
            self._write_stream = write_stream
            try:
                await self._server.run(read_stream, write_stream, init_opts)
            finally:
                self._write_stream = None

    # -- handler registration -----------------------------------------

    def _register_handlers(self) -> None:
        """Attach list_tools + call_tool to the underlying Server."""

        @self._server.list_tools()
        async def _list_tools() -> list[Tool]:  # noqa: D401
            return list(_TOOL_SCHEMAS)

        @self._server.call_tool()
        async def _call_tool(
            name: str, arguments: dict[str, Any]
        ) -> list[TextContent]:
            if name == "reply":
                return await self._handle_reply(arguments)
            if name == "send_file":
                return await self._handle_send_file(arguments)
            if name == "submit_slash":
                return await self._handle_submit_slash(arguments)
            return [
                TextContent(
                    type="text",
                    text=f'{{"ok": false, "error": "unknown_tool: {name}"}}',
                )
            ]

    # -- tool handlers (stubs — Task 2.5 fills them) ------------------

    async def _handle_reply(
        self, arguments: dict[str, Any]
    ) -> list[TextContent]:
        return await self._dispatch_tool("reply", arguments)

    async def _handle_send_file(
        self, arguments: dict[str, Any]
    ) -> list[TextContent]:
        return await self._dispatch_tool("send_file", arguments)

    async def _handle_submit_slash(
        self, arguments: dict[str, Any]
    ) -> list[TextContent]:
        return await self._dispatch_tool("submit_slash", arguments)

    async def _dispatch_tool(
        self, tool: str, arguments: dict[str, Any]
    ) -> list[TextContent]:
        """Forward a tool call to BEAM via the Phoenix channel.

        Mirrors `EsrWeb.McpController.invoke_tool_via_peer/3`:

        1. Mint a `req_id` (uuid4 hex — opaque to the peer).
        2. Push `event="envelope"`, kind="tool_invoke" to
           `cli:channel/<sid>`. `EsrWeb.ChannelChannel.handle_in/3`
           looks up `thread:<sid>` and forwards
           `{:tool_invoke, req_id, tool, args, self(), principal_id}`
           to the peer.
        3. Register an `asyncio.Future` keyed by `req_id`. The
           `phx_receive_loop` resolves it when the matching
           `kind="tool_result"` envelope arrives.
        4. Translate the result to MCP's CallToolResult shape:
           `{"ok": true, "data": d}` → text TextContent with
             `json.dumps(d)`.
           `{"ok": false, "error": e}` → text TextContent with
             `json.dumps({"ok": false, "error": e})`. Note: the
           low-level Server.call_tool decorator only takes a list of
           content items; the isError flag from the HTTP controller
           is not exposed at this layer. CC's tool-call parser still
           treats the JSON body as the canonical result and
           surfaces errors from the payload.
        """
        if self._phx_client is None or self._topic is None:
            return _err_content("phx_client_not_configured")

        req_id = uuid.uuid4().hex
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending_tool_calls[req_id] = future

        envelope = {
            "kind": "tool_invoke",
            "req_id": req_id,
            "tool": tool,
            "args": arguments,
        }

        try:
            # phx push returns the phx_reply (ack of receipt). The
            # actual tool result comes in as a separate envelope
            # frame routed to `future` by phx_receive_loop.
            reply_payload = await self._phx_client.push(
                self._topic, "envelope", envelope
            )
            if reply_payload.get("status") == "error":
                self._pending_tool_calls.pop(req_id, None)
                return _err_content(
                    "phx_push_error", reply_payload.get("response")
                )

            try:
                result = await asyncio.wait_for(
                    future, timeout=_TOOL_CALL_TIMEOUT_SECS
                )
            except asyncio.TimeoutError:
                self._pending_tool_calls.pop(req_id, None)
                return _err_content(
                    "tool_result_timeout",
                    {"tool": tool, "timeout_secs": _TOOL_CALL_TIMEOUT_SECS},
                )
        finally:
            # Defensive: ensure no future leaks if we crash above.
            self._pending_tool_calls.pop(req_id, None)

        return _tool_result_to_content(result)


def _tool_result_to_content(envelope: dict[str, Any]) -> list[TextContent]:
    """Mirror `mcp_controller.ex tool_result_to_jsonrpc/1` translation.

    The peer sends `{"kind": "tool_result", "req_id": ..., "ok": bool,
    "data" | "error": ...}`. MCP expects content as a list of
    TextContent objects. We serialize to JSON so CC's tool-call parser
    can re-parse uniformly (the existing HTTP path does the same).
    """
    if envelope.get("ok") is True:
        body = json.dumps(envelope.get("data"))
    elif envelope.get("ok") is False:
        body = json.dumps({"ok": False, "error": envelope.get("error")})
    else:
        # Unexpected shape — pass through verbatim so debugging is easy.
        body = json.dumps(envelope)
    return [TextContent(type="text", text=body)]


def _err_content(code: str, detail: Any = None) -> list[TextContent]:
    """Build the JSON error TextContent payload for bridge-side failures."""
    err: dict[str, Any] = {"ok": False, "error": {"type": code}}
    if detail is not None:
        err["error"]["detail"] = detail
    return [TextContent(type="text", text=json.dumps(err))]
