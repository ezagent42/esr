"""Test α-shape send_file directive dispatch (spec §6, T0 §3).

v1.1 blocker fix: constructor is FeishuAdapter(actor_id, config) where
config is a real AdapterConfig (dict-backed attribute wrapper in
py/src/esr/adapter.py:74). Prior plan revision passed a single
SimpleNamespace and one positional arg — TypeError at runtime. Fixed
per the pattern in adapters/feishu/tests/test_envelope_principal.py.
"""
from __future__ import annotations

import base64
import hashlib
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from mock_feishu import MockFeishu  # noqa: E402

from esr.adapter import AdapterConfig  # noqa: E402
from esr_feishu.adapter import FeishuAdapter  # noqa: E402


@pytest.mark.asyncio
async def test_send_file_mock_round_trip() -> None:
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

        payload = b"hello PR-7"
        sha = hashlib.sha256(payload).hexdigest()
        args = {
            "chat_id": "oc_mock_A",
            "file_name": "probe.txt",
            "content_b64": base64.b64encode(payload).decode(),
            "sha256": sha,
        }
        result = await adapter.on_directive("send_file", args)
        assert result["ok"] is True, result

        # Assert mock received file and linked it
        async with aiohttp.ClientSession() as sess:
            async with sess.get(f"{base_url}/sent_files") as resp:
                listing = await resp.json()
        assert len(listing) == 1
        assert listing[0]["chat_id"] == "oc_mock_A"
        assert listing[0]["sha256"] == sha
    finally:
        await mock.stop()


@pytest.mark.asyncio
async def test_send_file_sha_mismatch_rejected() -> None:
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

        args = {
            "chat_id": "oc_mock_A",
            "file_name": "probe.txt",
            "content_b64": base64.b64encode(b"actual").decode(),
            "sha256": "0" * 64,  # wrong
        }
        result = await adapter.on_directive("send_file", args)
        assert result["ok"] is False
        assert "sha256 mismatch" in result["error"]
    finally:
        await mock.stop()
