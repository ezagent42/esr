"""Test react directive with corrected msg_id key (spec §5.1).

v1.1 blocker fix: ctor signature is (actor_id, config) with a real
AdapterConfig — same pattern as test_feishu_send_file.py above.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from mock_feishu import MockFeishu  # noqa: E402

from esr.adapter import AdapterConfig  # noqa: E402
from esr_feishu.adapter import FeishuAdapter  # noqa: E402


@pytest.mark.asyncio
async def test_react_mock_emits_reaction() -> None:
    import aiohttp

    mock = MockFeishu()
    base_url = await mock.start(port=0)
    try:
        cfg = AdapterConfig(
            {
                "app_id": "e2e-mock",
                "app_secret": "s",
                "base_url": base_url,
                "uploads_dir": "/tmp",
            }
        )
        adapter = FeishuAdapter(actor_id="feishu-app:test", config=cfg)

        # Note: key is "msg_id" (matches Elixir emit post-D2 fix)
        result = await adapter.on_directive(
            "react", {"msg_id": "om_mock_1", "emoji_type": "THUMBSUP"}
        )
        assert result["ok"] is True, result

        async with aiohttp.ClientSession() as sess:
            async with sess.get(f"{base_url}/reactions") as resp:
                listing = await resp.json()
        assert len(listing) == 1
        assert listing[0]["message_id"] == "om_mock_1"
        assert listing[0]["emoji_type"] == "THUMBSUP"
    finally:
        await mock.stop()
