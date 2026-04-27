"""MCP tool schemas for esr-channel (spec §3.1 / §5.3).

Two user-facing tools + one diagnostic tool gated on the workspace
role. Schema shapes match cc-openclaw's openclaw-channel reply /
send_file tools (API-compatible per spec §1.1 point 1) so switching CC
from one channel to the other is drop-in.

Descriptions are channel-agnostic: the CC chain's abstraction boundary
(spec §2) forbids this module from naming any specific channel adapter.

PR-9 T5 note: `react` was removed from the CC-facing tool list. The
delivery-ack react (and its un-react on reply) is now a per-IM-proxy
concern — emitted by FeishuChatProxy inside the Elixir runtime when
an inbound message is successfully forwarded to CC, and un-reacted
when CC's reply carries `reply_to_message_id`. A hypothetical
SlackChatProxy would implement its own analogous behaviour without
touching CC or the MCP tool surface.
"""
from __future__ import annotations

from mcp.types import Tool

_REPLY = Tool(
    name="reply",
    description=(
        "Send a message to the user's chat channel. The user reads the "
        "channel, not this session — anything you want them to see must go "
        "through this tool. chat_id is from the inbound <channel> tag "
        "(opaque token scoped to the active channel). app_id MUST be "
        "specified explicitly on every call (no default) — take it from "
        "the inbound <channel> tag's app_id, or from a forward request's "
        "target app. This is an ESR routing identifier (instance_id), not "
        "a channel-native app token. Pass edit_message_id to edit an "
        "existing message in-place instead of sending a new one. "
        "Production callers should always include reply_to_message_id "
        "when the reply is in response to a specific inbound message — "
        "the runtime uses it to clean up any delivery-ack reaction the "
        "per-IM proxy emitted on receive. (Note: edit_message_id and "
        "reply_to_message_id are scoped to the source app's message "
        "space — they're stripped on cross-app reply where target "
        "app_id != source app_id.)"
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {
                "type": "string",
                "description": "Channel chat ID (opaque token scoped to the active channel)",
            },
            "app_id": {
                "type": "string",
                "description": (
                    "ESR routing identifier (instance_id from adapters.yaml). "
                    "Required on every call — take it from the inbound "
                    "<channel> tag's app_id attribute. To forward to a "
                    "different app, set this to the target app's instance_id."
                ),
            },
            "text": {"type": "string", "description": "Message text"},
            "edit_message_id": {
                "type": "string",
                "description": "Optional message_id to edit in-place",
            },
            "reply_to_message_id": {
                "type": "string",
                "description": (
                    "Optional message_id of the inbound message this reply "
                    "responds to. When present, the runtime un-reacts any "
                    "delivery-ack emoji the per-IM proxy added on inbound "
                    "receive. Stripped automatically on cross-app reply."
                ),
            },
        },
        "required": ["chat_id", "app_id", "text"],
    },
)

_SEND_FILE = Tool(
    name="send_file",
    description=(
        "Send a file to the user's chat channel. Uploads the local file "
        "and sends it as a file message."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {
                "type": "string",
                "description": "Channel chat ID (opaque token scoped to the active channel)",
            },
            "file_path": {"type": "string", "description": "Absolute path to local file"},
        },
        "required": ["chat_id", "file_path"],
    },
)

_ECHO = Tool(
    name="_echo",
    description=(
        "DIAGNOSTIC ONLY. Echo a nonce back as a reply to ESR_SELF_CHAT_ID. "
        "Gated on workspace role='diagnostic'. Used by final_gate --live v2 "
        "to make L2/L6 deterministic without LLM judgement."
    ),
    inputSchema={
        "type": "object",
        "properties": {"nonce": {"type": "string"}},
        "required": ["nonce"],
    },
)

# PR-F 2026-04-28: business-topology MCP tool (spec
# `docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`).
# Returns the current session's workspace + 1-hop neighbour metadata,
# letting the LLM understand its role in a multi-stage pipeline.
# Parameter-less: `workspace_name` is injected by the cc_mcp tool
# handler from the `ESR_WORKSPACE` env var, so the LLM doesn't need
# to know which workspace it's in.
_DESCRIBE_TOPOLOGY = Tool(
    name="describe_topology",
    description=(
        "Returns metadata about the current session's workspace and its "
        "direct (1-hop) neighbours. Call this when:\n"
        "- The user mentions another workspace/team you don't recognize.\n"
        "- You need pipeline context (your role, downstream stages, "
        "expected output format).\n"
        "- You're unsure which workspace's chat to route a reply to.\n\n"
        "Returns JSON with `current_workspace` (you are here) and "
        "`neighbor_workspaces` (1-hop reachable). Each workspace exposes "
        "a free-form `metadata` map populated by operators in "
        "workspaces.yaml — fields like `purpose`, `pipeline_position`, "
        "`hand_off_to` are common, but the structure is open. "
        "Operational fields (cwd, env, start_cmd) are filtered out."
    ),
    inputSchema={
        "type": "object",
        "properties": {},
        "required": [],
    },
)


def list_tool_schemas(*, role: str) -> list[Tool]:
    """Return the tool list CC sees — `_echo` only when role=diagnostic."""
    tools = [_REPLY, _SEND_FILE, _DESCRIBE_TOPOLOGY]
    if role == "diagnostic":
        tools.append(_ECHO)
    return tools
