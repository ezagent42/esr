"""PR-A T5: mock_feishu inbound envelope must match the live-capture
fixture shape field-for-field (extras OK, missing fields not OK).

Reference: adapters/feishu/tests/fixtures/live-capture/text_message.json
captured 2026-04-19 against real Feishu Open Platform.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import aiohttp
import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from mock_feishu import MockFeishu  # noqa: E402


@pytest.mark.asyncio
async def test_inbound_envelope_includes_required_fields() -> None:
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    received: list[dict] = []

    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(base_url.replace("http://", "ws://") + "/ws") as ws:
                # Let connect settle — push_inbound iterates `_ws_clients`
                # synchronously, so the receive task must be parked first.
                await asyncio.sleep(0.05)

                mock.push_inbound(
                    chat_id="oc_test",
                    sender_open_id="ou_test",
                    msg_type="text",
                    content_text="hello",
                )

                msg = await asyncio.wait_for(ws.receive(), timeout=2.0)
                received.append(json.loads(msg.data))
    finally:
        await mock.stop()

    assert len(received) == 1
    env = received[0]

    # --- header ----------------------------------------------------------
    assert env["schema"] == "2.0"
    h = env["header"]
    assert "event_id" in h
    assert h["event_type"] == "im.message.receive_v1"
    assert "create_time" in h
    assert "tenant_key" in h, "header.tenant_key missing — see live-capture/text_message.json"
    assert "app_id" in h

    # --- event.sender ----------------------------------------------------
    s = env["event"]["sender"]
    assert s["sender_type"] == "user"
    assert "tenant_key" in s, "event.sender.tenant_key missing"
    sid = s["sender_id"]
    assert "user_id" in sid, "sender_id.user_id missing"
    assert "open_id" in sid
    assert "union_id" in sid, "sender_id.union_id missing"

    # --- event.message ---------------------------------------------------
    m = env["event"]["message"]
    assert "message_id" in m
    assert m["chat_id"] == "oc_test"
    assert m["chat_type"] == "p2p"
    assert "create_time" in m
    assert "update_time" in m, "message.update_time missing"
    assert "user_agent" in m, "message.user_agent missing"
    assert m["message_type"] == "text"
    # Content is the lark `{"text": "..."}` JSON-string per Open Platform.
    assert m["content"] == json.dumps({"text": "hello"}, ensure_ascii=False)


@pytest.mark.asyncio
async def test_inbound_envelope_app_id_overridable() -> None:
    """PR-A T6: push_inbound accepts an app_id kwarg that lands in
    header.app_id AND selects the per-app routing bucket. The WS
    consumer must subscribe with the matching `?app_id=` query to
    receive."""
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    received: list[dict] = []

    try:
        async with aiohttp.ClientSession() as session:
            ws_url = (
                base_url.replace("http://", "ws://")
                + "/ws?app_id=cli_pr_a_t5"
            )
            async with session.ws_connect(ws_url) as ws:
                await asyncio.sleep(0.05)
                mock.push_inbound(
                    chat_id="oc_x",
                    sender_open_id="ou_x",
                    content_text="x",
                    app_id="cli_pr_a_t5",
                )
                msg = await asyncio.wait_for(ws.receive(), timeout=2.0)
                received.append(json.loads(msg.data))
    finally:
        await mock.stop()

    assert received[0]["header"]["app_id"] == "cli_pr_a_t5"
