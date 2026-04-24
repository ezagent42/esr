"""PR-9 T5c: mock_feishu DELETE-reaction endpoints.

Covers both the Lark-shaped DELETE by (message_id, reaction_id) and
FeishuChatProxy's v1 best-effort DELETE by message_id alone — which is
what the Elixir side uses today since it tracks reacts by message_id,
not reaction_id. The adapter's _un_react_mock hits the second form.
"""
from __future__ import annotations

import sys
from pathlib import Path

import aiohttp
import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from mock_feishu import MockFeishu  # noqa: E402


@pytest.mark.asyncio
async def test_delete_reaction_by_message_id_removes_react() -> None:
    """FeishuChatProxy v1 path: DELETE by message_id removes ALL reacts on it."""
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        async with aiohttp.ClientSession() as sess:
            # React twice on the same message with different emojis.
            for emoji in ("EYES", "THUMBSUP"):
                async with sess.post(
                    f"{base_url}/open-apis/im/v1/messages/om_1/reactions",
                    json={"reaction_type": {"emoji_type": emoji}},
                ) as resp:
                    body = await resp.json()
                    assert body["code"] == 0

            async with sess.get(f"{base_url}/reactions") as resp:
                assert len(await resp.json()) == 2

            # DELETE by message_id (FeishuChatProxy v1 shape).
            async with sess.delete(
                f"{base_url}/open-apis/im/v1/messages/om_1/reactions",
                json={"reaction_type": {"emoji_type": "EYES"}},
            ) as resp:
                assert resp.status == 200
                body = await resp.json()
                assert body["code"] == 0

            # All reacts on om_1 gone.
            async with sess.get(f"{base_url}/reactions") as resp:
                assert await resp.json() == []

            # Un-react recorded for test assertion.
            async with sess.get(f"{base_url}/un_reactions") as resp:
                un_reacts = await resp.json()
                assert len(un_reacts) == 2
                assert all(u["message_id"] == "om_1" for u in un_reacts)
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_delete_reaction_by_id_mirrors_lark_shape() -> None:
    """Lark-shaped DELETE by (message_id, reaction_id) records un-react."""
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        async with aiohttp.ClientSession() as sess:
            async with sess.post(
                f"{base_url}/open-apis/im/v1/messages/om_2/reactions",
                json={"reaction_type": {"emoji_type": "EYES"}},
            ) as resp:
                body = await resp.json()
                reaction_id = body["data"]["reaction_id"]

            # Lark shape: DELETE .../reactions/<reaction_id>
            async with sess.delete(
                f"{base_url}/open-apis/im/v1/messages/om_2/reactions/{reaction_id}"
            ) as resp:
                assert resp.status == 200

            async with sess.get(f"{base_url}/un_reactions") as resp:
                un_reacts = await resp.json()
                assert len(un_reacts) == 1
                assert un_reacts[0]["message_id"] == "om_2"
                assert un_reacts[0]["reaction_id"] == reaction_id
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_delete_on_empty_records_un_react_attempt() -> None:
    """DELETE on a message with no reactions still records the un-react.

    Rationale: FeishuChatProxy fires un_react best-effort after a race
    in which the inbound react may not have landed yet. Tests assert
    the directive fired; a silent 404-equivalent would mask regressions.
    """
    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        async with aiohttp.ClientSession() as sess:
            async with sess.delete(
                f"{base_url}/open-apis/im/v1/messages/om_never_reacted/reactions",
                json={"reaction_type": {"emoji_type": "EYES"}},
            ) as resp:
                assert resp.status == 200

            async with sess.get(f"{base_url}/un_reactions") as resp:
                un_reacts = await resp.json()
                assert len(un_reacts) == 1
                assert un_reacts[0]["message_id"] == "om_never_reacted"
    finally:
        await mock.stop()
