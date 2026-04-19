"""Tests for ChannelPusher — the bridge that adapts ChannelClient to the
AdapterPusher protocol used by directive_loop + event_loop (Phase 8a F13)."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import pytest


@dataclass
class FakeChannelClient:
    """Minimal ChannelClient stand-in that records pushes."""
    pushes: list[tuple[str, str, dict[str, Any]]] = field(default_factory=list)

    async def push(self, topic: str, event: str, payload: dict[str, Any]) -> None:
        self.pushes.append((topic, event, payload))


@pytest.mark.asyncio
async def test_channel_pusher_routes_envelope_to_client_push() -> None:
    from esr.ipc.channel_pusher import ChannelPusher

    client = FakeChannelClient()
    pusher = ChannelPusher(client=client, topic="adapter:feishu/inst1",
                           source_uri="adapter:feishu/inst1")
    envelope = {"kind": "directive_ack", "id": "ref-1", "payload": {"ok": True}}
    await pusher.push_envelope(envelope)

    assert pusher.source_uri == "adapter:feishu/inst1"
    assert len(client.pushes) == 1
    topic, event, payload = client.pushes[0]
    assert topic == "adapter:feishu/inst1"
    assert event == "envelope"
    assert payload == envelope
