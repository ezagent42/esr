"""Tests for mock_feishu's /files + /sent_files endpoints (T0 §4c-e)."""
from __future__ import annotations

import base64
import hashlib
import json
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

from mock_feishu import MockFeishu  # noqa: E402


@pytest.mark.asyncio
async def test_upload_then_send_file_links_chat_id() -> None:
    import aiohttp

    mock = MockFeishu()
    base = await mock.start(port=0)
    try:
        payload_bytes = b"PR-7 probe bytes\n"
        b64 = base64.b64encode(payload_bytes).decode()

        async with aiohttp.ClientSession() as sess:
            # Step 1: upload (JSON form — plan uses JSON+content_b64 path)
            async with sess.post(
                f"{base}/open-apis/im/v1/files",
                json={
                    "file_type": "stream",
                    "file_name": "probe.txt",
                    "content_b64": b64,
                },
            ) as resp:
                assert resp.status == 200
                upload = await resp.json()
            file_key = upload["data"]["file_key"]
            assert file_key.startswith("file_mock_")

            # Pre-link state: /sent_files is empty (chat_id=="")
            async with sess.get(f"{base}/sent_files") as resp:
                assert resp.status == 200
                pre = await resp.json()
            assert pre == []

            # Step 2: send-as-file-message
            async with sess.post(
                f"{base}/open-apis/im/v1/messages",
                params={"receive_id_type": "chat_id"},
                json={
                    "receive_id": "oc_mock_A",
                    "msg_type": "file",
                    "content": json.dumps({"file_key": file_key}),
                },
            ) as resp:
                assert resp.status == 200
                send_resp = await resp.json()
            assert send_resp["code"] == 0

            # /sent_files now has one linked entry
            async with sess.get(f"{base}/sent_files") as resp:
                assert resp.status == 200
                post = await resp.json()
        assert len(post) == 1
        assert post[0]["chat_id"] == "oc_mock_A"
        assert post[0]["file_key"] == file_key
        assert post[0]["file_name"] == "probe.txt"
        assert post[0]["size"] == len(payload_bytes)
        assert post[0]["sha256"] == hashlib.sha256(payload_bytes).hexdigest()
    finally:
        await mock.stop()
