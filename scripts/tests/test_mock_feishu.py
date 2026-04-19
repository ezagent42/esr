"""Tests for scripts/mock_feishu.py — Phase 8d HTTP endpoint.

First bite: im.v1.message.create POST returns Lark-shaped
``{"code": 0, "data": {"message_id": ...}}`` and records the call
so tests can assert the payload the CLI/runtime actually sent.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

from mock_feishu import MockFeishu  # noqa: E402


@pytest.mark.asyncio
async def test_create_message_returns_lark_shape() -> None:
    import aiohttp

    mock = MockFeishu()
    url = await mock.start()
    try:
        async with aiohttp.ClientSession() as sess:
            async with sess.post(
                f"{url}/open-apis/im/v1/messages",
                params={"receive_id_type": "chat_id"},
                json={
                    "receive_id": "oc_test",
                    "msg_type": "text",
                    "content": json.dumps({"text": "/new-thread smoke-1"}),
                },
            ) as resp:
                assert resp.status == 200
                body = await resp.json()

        assert body["code"] == 0
        assert body["msg"] == ""
        message_id = body["data"]["message_id"]
        assert message_id.startswith("om_mock_")

        # Mock recorded the call for test assertions.
        sent = mock.sent_messages
        assert len(sent) == 1
        assert sent[0]["receive_id"] == "oc_test"
        assert sent[0]["msg_type"] == "text"
        assert sent[0]["message_id"] == message_id
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_ws_inbound_event_pushed_to_connected_client() -> None:
    """Mock's /ws endpoint is where the feishu adapter connects; mock
    pushes P2ImMessageReceiveV1-shaped envelopes when push_inbound() is
    called."""
    import aiohttp

    mock = MockFeishu()
    url = await mock.start()
    try:
        ws_url = url.replace("http://", "ws://") + "/ws"
        async with aiohttp.ClientSession() as sess:
            async with sess.ws_connect(ws_url) as ws:
                # Drive an inbound event from the test.
                mock.push_inbound(
                    chat_id="oc_test",
                    sender_open_id="ou_user_1",
                    msg_type="text",
                    content_text="/new-thread smoke-1",
                )

                raw = await asyncio.wait_for(ws.receive(), timeout=2.0)
                assert raw.type == aiohttp.WSMsgType.TEXT
                envelope = json.loads(raw.data)

        assert envelope["schema"] == "2.0"
        assert envelope["header"]["event_type"] == "im.message.receive_v1"
        evt = envelope["event"]
        assert evt["message"]["chat_id"] == "oc_test"
        assert evt["message"]["message_type"] == "text"
        content = json.loads(evt["message"]["content"])
        assert content["text"] == "/new-thread smoke-1"
        assert evt["sender"]["sender_id"]["open_id"] == "ou_user_1"
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_messages_list_returns_sent_plus_seeded() -> None:
    """im.v1.chat.messages.list surfaces every message sent into a chat
    (from the mock's POST endpoint) + any test-seeded inbound messages."""
    import aiohttp

    mock = MockFeishu()
    url = await mock.start()
    try:
        # Seed a user-inbound message (as if the user posted it in Feishu).
        mock.seed_inbound_message(
            chat_id="oc_test",
            sender_type="user",
            msg_type="text",
            content_text="hello from user",
        )

        async with aiohttp.ClientSession() as sess:
            # The bot posts a reply.
            async with sess.post(
                f"{url}/open-apis/im/v1/messages",
                params={"receive_id_type": "chat_id"},
                json={"receive_id": "oc_test", "msg_type": "text",
                      "content": json.dumps({"text": "hello from bot"})},
            ) as resp:
                bot_id = (await resp.json())["data"]["message_id"]

            # Now query the chat list.
            async with sess.get(
                f"{url}/open-apis/im/v1/messages",
                params={"container_id_type": "chat", "container_id": "oc_test",
                        "sort_type": "ByCreateTimeDesc", "page_size": "20"},
            ) as resp:
                listing = await resp.json()

        assert listing["code"] == 0
        items = listing["data"]["items"]
        # Newest first: bot message then user seed.
        assert items[0]["message_id"] == bot_id
        assert items[0]["sender"]["sender_type"] == "app"
        assert items[1]["sender"]["sender_type"] == "user"
    finally:
        await mock.stop()
