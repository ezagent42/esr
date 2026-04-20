"""MCP tool schemas for esr-channel (spec §3.1 / §5.3).

Three user-facing tools + one diagnostic tool gated on the
workspace role. Schema shapes match cc-openclaw's openclaw-channel
`reply` / `react` / `send_file` tools (API-compatible per spec §1.1
point 1) so switching CC from one channel to the other is drop-in.
"""
from __future__ import annotations

from mcp.types import Tool

_REPLY = Tool(
    name="reply",
    description=(
        "Send a message to a Feishu chat. The user reads Feishu, not this "
        "session — anything you want them to see must go through this tool. "
        "chat_id is from the inbound <channel> tag (oc_xxx format). "
        "Pass edit_message_id to edit an existing message in-place instead of "
        "sending a new one (covers update_title semantics)."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {"type": "string", "description": "Feishu chat ID (oc_xxx)"},
            "text": {"type": "string", "description": "Message text"},
            "edit_message_id": {"type": "string",
                                "description": "Optional message_id (om_xxx) to edit"},
        },
        "required": ["chat_id", "text"],
    },
)

_REACT = Tool(
    name="react",
    description="Add an emoji reaction to a Feishu message",
    inputSchema={
        "type": "object",
        "properties": {
            "message_id": {"type": "string", "description": "Message ID (om_xxx)"},
            "emoji_type": {"type": "string",
                           "description": "Feishu emoji (THUMBSUP, DONE, OK)"},
        },
        "required": ["message_id", "emoji_type"],
    },
)

_SEND_FILE = Tool(
    name="send_file",
    description=(
        "Send a file to a Feishu chat. Uploads the local file to Feishu and "
        "sends it as a file message."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {"type": "string", "description": "Feishu chat ID (oc_xxx)"},
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
