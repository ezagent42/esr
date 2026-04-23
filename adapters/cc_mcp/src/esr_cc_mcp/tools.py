"""MCP tool schemas for esr-channel (spec §3.1 / §5.3).

Three user-facing tools + one diagnostic tool gated on the workspace
role. Schema shapes match cc-openclaw's openclaw-channel reply / react /
send_file tools (API-compatible per spec §1.1 point 1) so switching CC
from one channel to the other is drop-in.

Descriptions are channel-agnostic: the CC chain's abstraction boundary
(spec §2) forbids this module from naming any specific channel adapter.
"""
from __future__ import annotations

from mcp.types import Tool

_REPLY = Tool(
    name="reply",
    description=(
        "Send a message to the user's chat channel. The user reads the "
        "channel, not this session — anything you want them to see must go "
        "through this tool. chat_id is from the inbound <channel> tag "
        "(opaque token scoped to the active channel). Pass edit_message_id "
        "to edit an existing message in-place instead of sending a new one "
        "(covers update_title semantics)."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {
                "type": "string",
                "description": "Channel chat ID (opaque token scoped to the active channel)",
            },
            "text": {"type": "string", "description": "Message text"},
            "edit_message_id": {
                "type": "string",
                "description": "Optional message_id to edit in-place",
            },
        },
        "required": ["chat_id", "text"],
    },
)

_REACT = Tool(
    name="react",
    description="Add an emoji reaction to a channel message",
    inputSchema={
        "type": "object",
        "properties": {
            "message_id": {
                "type": "string",
                "description": "Message ID (opaque token scoped to the active channel)",
            },
            "emoji_type": {
                "type": "string",
                "description": (
                    "Emoji code (channel-specific; e.g. THUMBSUP, DONE, OK "
                    "for common chat channels)"
                ),
            },
        },
        "required": ["message_id", "emoji_type"],
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


def list_tool_schemas(*, role: str) -> list[Tool]:
    """Return the tool list CC sees — `_echo` only when role=diagnostic."""
    tools = [_REPLY, _REACT, _SEND_FILE]
    if role == "diagnostic":
        tools.append(_ECHO)
    return tools
