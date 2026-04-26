"""T-PR-A T6: mock_feishu per-app namespacing.

push_inbound routes to ws_clients of a SPECIFIC app_id;
sent_messages partitioned by caller's app_id (X-App-Id header);
ws_clients partitioned per app.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import aiohttp
import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from mock_feishu import MockFeishu  # type: ignore


@pytest.mark.asyncio
async def test_push_inbound_routes_only_to_target_app_clients():
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    dev_received: list[dict] = []
    kanban_received: list[dict] = []

    async def consume(app_id: str, sink: list[dict]):
        ws_url = base_url.replace("http://", "ws://") + f"/ws?app_id={app_id}"
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(ws_url) as ws:
                while True:
                    try:
                        msg = await asyncio.wait_for(ws.receive(), timeout=1.5)
                    except asyncio.TimeoutError:
                        return
                    if msg.type == aiohttp.WSMsgType.TEXT:
                        sink.append(json.loads(msg.data))

    async def driver():
        # Wait for both consumers to subscribe
        await asyncio.sleep(0.2)
        mock.push_inbound(chat_id="oc_dev", sender_open_id="ou_a",
                          content_text="for-dev", app_id="feishu_dev")
        mock.push_inbound(chat_id="oc_kanban", sender_open_id="ou_a",
                          content_text="for-kanban", app_id="feishu_kanban")

    try:
        await asyncio.wait_for(asyncio.gather(
            consume("feishu_dev", dev_received),
            consume("feishu_kanban", kanban_received),
            driver(),
        ), timeout=5.0)
    except asyncio.TimeoutError:
        pass  # consumers exit on their own timeout
    finally:
        await mock.stop()

    assert any("for-dev" in env["event"]["message"]["content"] for env in dev_received)
    assert all("for-kanban" not in env["event"]["message"]["content"] for env in dev_received)

    assert any("for-kanban" in env["event"]["message"]["content"] for env in kanban_received)
    assert all("for-dev" not in env["event"]["message"]["content"] for env in kanban_received)


@pytest.mark.asyncio
async def test_outbound_partitioned_by_x_app_id_header():
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    # Pre-register chat membership so the membership check (T7) doesn't
    # reject these. T6 alone may allow without membership; once T7 lands,
    # this test still works because we explicitly register both pairs.
    mock.register_chat_membership("feishu_dev", "oc_dev")
    mock.register_chat_membership("feishu_kanban", "oc_kanban")

    async with aiohttp.ClientSession() as session:
        for app_id, chat, text in [
            ("feishu_dev", "oc_dev", "from-dev"),
            ("feishu_kanban", "oc_kanban", "from-kanban"),
        ]:
            async with session.post(
                f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
                headers={"X-App-Id": app_id},
                json={"receive_id": chat, "msg_type": "text",
                      "content": json.dumps({"text": text})},
            ) as resp:
                assert resp.status == 200
                body = await resp.json()
                assert body["code"] == 0

    # GET /sent_messages?app_id=...
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{base_url}/sent_messages?app_id=feishu_dev") as r:
            dev_msgs = await r.json()
        async with session.get(f"{base_url}/sent_messages?app_id=feishu_kanban") as r:
            kanban_msgs = await r.json()
        async with session.get(f"{base_url}/sent_messages") as r:
            all_msgs = await r.json()  # unscoped — returns union (back-compat)

    await mock.stop()

    dev_contents = [json.loads(m["content"])["text"] for m in dev_msgs]
    kanban_contents = [json.loads(m["content"])["text"] for m in kanban_msgs]
    assert "from-dev" in dev_contents and "from-kanban" not in dev_contents
    assert "from-kanban" in kanban_contents and "from-dev" not in kanban_contents
    assert len(all_msgs) == 2  # union
