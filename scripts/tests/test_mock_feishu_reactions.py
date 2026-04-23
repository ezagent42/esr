"""Tests for mock_feishu's /reactions endpoints (T0 §4a, §4b)."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

from mock_feishu import MockFeishu  # noqa: E402


@pytest.mark.asyncio
async def test_post_reaction_appends_and_get_lists() -> None:
    import aiohttp

    mock = MockFeishu()
    base = await mock.start(port=0)
    try:
        async with aiohttp.ClientSession() as sess:
            # POST a reaction
            async with sess.post(
                f"{base}/open-apis/im/v1/messages/om_test_1/reactions",
                json={"reaction_type": {"emoji_type": "THUMBSUP"}},
            ) as resp:
                assert resp.status == 200
                payload = await resp.json()
            assert payload["code"] == 0
            assert payload["data"]["message_id"] == "om_test_1"
            assert payload["data"]["reaction_id"].startswith("rc_mock_")

            # GET /reactions
            async with sess.get(f"{base}/reactions") as resp:
                assert resp.status == 200
                listing = await resp.json()
        assert len(listing) == 1
        assert listing[0]["message_id"] == "om_test_1"
        assert listing[0]["emoji_type"] == "THUMBSUP"
        assert "ts_unix_ms" in listing[0]
    finally:
        await mock.stop()
