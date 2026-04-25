"""T-PR-A T7: mock_feishu rejects outbound when caller is not a member
of the target chat. Mirrors real Feishu's behaviour where app-B
trying to send to a chat where app-B's bot isn't a member returns
code != 0.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import aiohttp
import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from mock_feishu import MockFeishu  # type: ignore


@pytest.mark.asyncio
async def test_outbound_rejected_when_app_not_chat_member():
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    # Register only feishu_dev as a member of oc_dev. feishu_kanban is
    # NOT registered for oc_dev.
    mock.register_chat_membership("feishu_dev", "oc_dev")

    async with aiohttp.ClientSession() as session:
        # Allowed: feishu_dev to oc_dev
        async with session.post(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            headers={"X-App-Id": "feishu_dev"},
            json={"receive_id": "oc_dev", "msg_type": "text",
                  "content": json.dumps({"text": "ok"})},
        ) as r:
            body = await r.json()
            assert body["code"] == 0

        # Rejected: feishu_kanban to oc_dev (not a member)
        async with session.post(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            headers={"X-App-Id": "feishu_kanban"},
            json={"receive_id": "oc_dev", "msg_type": "text",
                  "content": json.dumps({"text": "blocked"})},
        ) as r:
            body = await r.json()
            assert body["code"] != 0
            assert "not a member" in body.get("msg", "").lower() \
                or body.get("code") in (230_002, 99_991_400)  # Feishu's typical codes

    # The blocked message must NOT appear in any sent_messages bucket
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{base_url}/sent_messages") as r:
            all_msgs = await r.json()

    contents = [json.loads(m["content"])["text"] for m in all_msgs]
    assert "ok" in contents
    assert "blocked" not in contents

    await mock.stop()


@pytest.mark.asyncio
async def test_outbound_default_app_no_membership_required():
    """Back-compat: when X-App-Id is unset (= 'default'), no membership
    check applies. This is what scenarios 01-03 rely on."""
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            json={"receive_id": "oc_anything", "msg_type": "text",
                  "content": json.dumps({"text": "legacy"})},
        ) as r:
            body = await r.json()
            assert body["code"] == 0

    await mock.stop()
