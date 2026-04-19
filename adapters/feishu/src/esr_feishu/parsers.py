"""Per-msg_type content parsers for Feishu events (PRD 04 F13).

Each Feishu ``P2ImMessageReceiveV1`` event carries a ``msg_type``
discriminator and a JSON-string ``content`` payload whose shape varies
by type. This module dispatches to per-type parsers that normalise
``content`` into a human-readable text representation.

Parser signature::

    (content: dict) -> str

File-bearing types (``image`` / ``file`` / ``audio`` / ``media``)
return a text stub that mentions the ``file_key``; the actual download
is triggered by a separate ``download_file`` directive (PRD 04 F14) so
``emit_events`` can stay side-effect-free.

Ported from ``cc-openclaw/channel_server/adapters/feishu/parsers.py``
with the runtime-fetch branches (merge_forward sub-messages, user name
resolution) stripped — v0.1 parsers are pure.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from typing import Any

log = logging.getLogger(__name__)

Parser = Callable[[dict[str, Any]], str]

_PARSERS: dict[str, Parser] = {}


def register_parser(*msg_types: str) -> Callable[[Parser], Parser]:
    """Register ``fn`` as the parser for every listed msg_type."""

    def decorate(fn: Parser) -> Parser:
        for mt in msg_types:
            _PARSERS[mt] = fn
        return fn

    return decorate


def parse_content(msg_type: str, content: dict[str, Any]) -> str:
    """Return a human-readable text representation of ``content``.

    Falls back to ``f"[{msg_type} message]"`` for unregistered types.
    Parser exceptions are caught and converted to a safe placeholder
    so one bad payload doesn't break event-stream consumers.
    """
    parser = _PARSERS.get(msg_type)
    if parser is None:
        return f"[{msg_type} message]"
    try:
        return parser(content)
    except Exception as exc:  # noqa: BLE001 — parser boundary
        log.warning("parser for %s failed: %s", msg_type, exc)
        return f"[{msg_type} message — parse failed]"


# --- P0 parsers -------------------------------------------------------


@register_parser("text")
def _parse_text(content: dict[str, Any]) -> str:
    return str(content.get("text", ""))


@register_parser("post")
def _parse_post(content: dict[str, Any]) -> str:
    parts: list[str] = [str(content.get("title", ""))]
    for para in content.get("content", []) or []:
        for node in para or []:
            if not isinstance(node, dict):
                continue
            tag = node.get("tag", "")
            if tag == "text" or node.get("text"):
                parts.append(str(node.get("text", "")))
            elif tag == "img":
                parts.append(f"[img: {node.get('image_key', '')}]")
            elif tag == "at":
                parts.append(f"@{node.get('user_name', node.get('user_id', ''))}")
            elif tag == "a":
                parts.append(str(node.get("text", "") or node.get("href", "")))
    return " ".join(p for p in parts if p)


@register_parser("image", "file", "audio", "media")
def _parse_downloadable(content: dict[str, Any]) -> str:
    """Return a stub referencing the file_key — no download in-parser (F14)."""
    file_key = content.get("image_key") or content.get("file_key", "")
    file_name = content.get("file_name") or file_key or "unknown"
    return f"[file: {file_name}]"


@register_parser("sticker")
def _parse_sticker(content: dict[str, Any]) -> str:
    return "[sticker]"


# --- P1 parsers -------------------------------------------------------


@register_parser("share_chat")
def _parse_share_chat(content: dict[str, Any]) -> str:
    return f"[chat card: {content.get('chat_id', '')}]"


@register_parser("share_user")
def _parse_share_user(content: dict[str, Any]) -> str:
    return f"[user card: {content.get('user_id', '')}]"


@register_parser("location")
def _parse_location(content: dict[str, Any]) -> str:
    name = content.get("name", "unknown location")
    lat = content.get("latitude", "")
    lng = content.get("longitude", "")
    coords = f" ({lat}, {lng})" if lat and lng else ""
    return f"[location: {name}{coords}]"


@register_parser("interactive")
def _parse_interactive(content: dict[str, Any]) -> str:
    """Flatten an interactive card's text-bearing elements to one string.

    Skips structure (header/elements tree) beyond text fields; button
    text and markdown/text nodes are preserved so downstream handlers
    can pattern-match on them.
    """
    parts: list[str] = []
    header = content.get("header", {})
    if isinstance(header, dict):
        title = header.get("title", {})
        if isinstance(title, dict):
            parts.append(str(title.get("content", "")))
        elif isinstance(title, str):
            parts.append(title)
    elements = content.get("elements", [])
    if isinstance(elements, list):
        for el in elements:
            if not isinstance(el, dict):
                continue
            tag = el.get("tag", "")
            if tag == "text" or tag == "markdown":
                parts.append(str(el.get("text") or el.get("content", "")))
            elif tag == "div":
                txt = el.get("text", {})
                if isinstance(txt, dict):
                    parts.append(str(txt.get("content", "")))
                elif isinstance(txt, str):
                    parts.append(txt)
            elif tag == "action":
                for action in el.get("actions", []) or []:
                    if not isinstance(action, dict):
                        continue
                    btn = action.get("text", {})
                    label = (
                        btn.get("content", "") if isinstance(btn, dict) else str(btn)
                    )
                    parts.append(f"[button: {label}]")
    return "\n".join(p for p in parts if p) or "[card]"
