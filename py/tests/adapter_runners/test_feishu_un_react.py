"""PR-9 T5c: Feishu adapter `un_react` directive against mock_feishu.

Parity with test_feishu_react.py — same ctor shape, same AdapterConfig
wiring, asserts that the adapter's `_un_react` path issues a DELETE
to mock_feishu and the un-reaction is recorded.
"""
from __future__ import annotations

import sys
from pathlib import Path

import aiohttp
import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from mock_feishu import MockFeishu  # noqa: E402

from esr.adapter import AdapterConfig  # noqa: E402
from esr_feishu.adapter import FeishuAdapter  # noqa: E402


@pytest.mark.asyncio
async def test_un_react_mock_records_un_reaction() -> None:
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

        # Seed a react so the un-react has something to remove.
        react_result = await adapter.on_directive(
            "react", {"msg_id": "om_unreact_1", "emoji_type": "EYES"}
        )
        assert react_result["ok"] is True

        # Un-react (v1 shape: msg_id + emoji_type; best-effort by msg_id).
        result = await adapter.on_directive(
            "un_react", {"msg_id": "om_unreact_1", "emoji_type": "EYES"}
        )
        assert result["ok"] is True, result

        async with aiohttp.ClientSession() as sess:
            async with sess.get(f"{base_url}/un_reactions") as resp:
                un_reacts = await resp.json()
            async with sess.get(f"{base_url}/reactions") as resp:
                remaining = await resp.json()

        assert len(un_reacts) == 1
        assert un_reacts[0]["message_id"] == "om_unreact_1"
        # Mock clears the live react on DELETE-by-message_id.
        assert remaining == []
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_un_react_tolerates_no_prior_reaction() -> None:
    """Un-react with no prior react still succeeds at the adapter boundary."""
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

        result = await adapter.on_directive(
            "un_react", {"msg_id": "om_never", "emoji_type": "EYES"}
        )
        assert result["ok"] is True, result

        async with aiohttp.ClientSession() as sess:
            async with sess.get(f"{base_url}/un_reactions") as resp:
                un_reacts = await resp.json()
        assert len(un_reacts) == 1
        assert un_reacts[0]["message_id"] == "om_never"
    finally:
        await mock.stop()
