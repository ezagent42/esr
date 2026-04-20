"""Verify _handle_inbound formats notifications as <channel>-tagged
text content that CC's MCP client renders in conversation."""

import asyncio

import pytest

from esr_cc_mcp.channel import _format_channel_tag


def test_channel_tag_includes_all_identity_fields() -> None:
    tag = _format_channel_tag({
        "source": "feishu",
        "chat_id": "oc_5c21b0eec28ad69efa0a5acf47eeaf55",
        "message_id": "om_x100",
        "user": "linyilun",
        "ts": "2026-04-20T04:00:00+00:00",
        "content": "hello",
    })
    assert "<channel" in tag
    assert 'source="feishu"' in tag
    assert 'chat_id="oc_5c21b0eec28ad69efa0a5acf47eeaf55"' in tag
    assert "hello" in tag
    assert "</channel>" in tag
