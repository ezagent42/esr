"""Tests for FeishuAdapter.emit_events (PRD 04 F12).

The adapter's async generator must yield inbound Feishu messages as
``{"event_type": "msg_received", "args": {...}}`` envelopes — the
same shape live-Lark and mock-Feishu both produce, so downstream
handlers stay adapter-symmetric.

These tests drive the mock path (config.base_url ∈ {http://127.0.0.1,
http://localhost}) against a live MockFeishu harness. The live-Lark
path requires real credentials and is covered by the --live gate.

Capabilities: Lane A (§7.1) now gates every emit site, so this test
supplies a workspaces.yaml binding the test chat to a workspace and a
capabilities.yaml granting ``*`` to the synthetic sender. Lane A
enforcement itself is exercised in ``test_lane_a.py``.
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

from esr.adapter import AdapterConfig
from esr.workspaces import Workspace, write_workspace
from esr_feishu.adapter import FeishuAdapter

# Import MockFeishu from scripts/
_SCRIPTS = Path(__file__).resolve().parents[3] / "scripts"
sys.path.insert(0, str(_SCRIPTS))
from mock_feishu import MockFeishu  # noqa: E402


@pytest.mark.asyncio
async def test_emit_events_mock_yields_msg_received(
    tmp_path: Path,
) -> None:
    """When base_url points at a mock, emit_events relays /ws frames.

    Seeds the mock with an inbound message, then awaits one envelope
    from the adapter's generator. Verifies the flattened shape matches
    what the feishu_app / feishu_thread handlers expect.
    """
    workspaces_path = tmp_path / "workspaces.yaml"
    write_workspace(
        workspaces_path,
        Workspace(
            name="proj-t",
            cwd="/tmp",
            start_cmd="x",
            role="dev",
            chats=[
                {"chat_id": "oc_unit_test", "app_id": "mock_app", "kind": "dm"}
            ],
        ),
    )
    mock = MockFeishu()
    url = await mock.start()
    try:
        adapter = FeishuAdapter(
            actor_id="feishu-app:test",
            config=AdapterConfig({
                "app_id": "mock_app",
                "app_secret": "mock_secret",
                "base_url": url,
                "workspaces_path": str(workspaces_path),
            }),
        )

        # Drive the generator in a task and nudge the mock after a short
        # startup delay — the WS has to connect before push_inbound fires
        # or the frame goes to an empty client list.
        gen = adapter.emit_events()

        async def _seed_soon() -> None:
            await asyncio.sleep(0.2)
            # PR-A T6: mock_feishu fans push_inbound out per-app
            # (`app_id` keys `_ws_clients`). The adapter connects with
            # `?app_id=<self.actor_id>`, so push_inbound must target
            # the same app_id or the frame goes to the empty "default"
            # bucket. (Pre-PR-A this test passed because there was
            # only one bucket; pre-Lane-A-drop the failure was masked
            # by Lane A's `_is_authorized` rejection happening before
            # the test could observe the routing miss.)
            mock.push_inbound(
                chat_id="oc_unit_test",
                sender_open_id="ou_sender_1",
                content_text="hello from mock",
                app_id="feishu-app:test",
            )

        seed = asyncio.create_task(_seed_soon())
        try:
            envelope = await asyncio.wait_for(gen.__anext__(), timeout=5.0)
        finally:
            seed.cancel()
            await gen.aclose()

        assert envelope["event_type"] == "msg_received"
        args = envelope["args"]
        assert args["chat_id"] == "oc_unit_test"
        assert args["sender_id"] == "ou_sender_1"
        # content is plain text, NOT the wrapping JSON the Lark API uses
        # on the wire — handlers (feishu_app.on_msg) compare against
        # literal prefixes like "/new-thread" so the adapter does the
        # one-time JSON unwrap at the boundary.
        assert args["content"] == "hello from mock"
        assert "hello from mock" in args["raw_content"]
        assert args["msg_type"] == "text"
    finally:
        await mock.stop()
