"""Tests for handler_worker.run_with_client() — Phase 8a F07 wiring.

Fake ChannelClient verifies run_with_client calls connect+join, installs
an _on_frame callback that filters handler_call envelopes from Phoenix
v2 frames, and pushes replies on the same topic with event="envelope".
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any

import pytest


@dataclass
class FakeChannelClient:
    pushes: list[tuple[str, str, dict[str, Any]]] = field(default_factory=list)
    connected: bool = False
    closed: bool = False
    on_frame_cb: Any = None
    joined_topic: str | None = None

    async def connect(self) -> None:
        self.connected = True

    async def join(self, topic: str, on_msg: Any) -> dict[str, Any]:
        self.joined_topic = topic
        self.on_frame_cb = on_msg
        return {"status": "ok"}

    async def push(self, topic: str, event: str, payload: dict[str, Any]) -> None:
        self.pushes.append((topic, event, payload))

    async def close(self) -> None:
        self.closed = True


@pytest.mark.asyncio
async def test_handler_worker_run_with_client_connects_and_joins() -> None:
    from esr.ipc.handler_worker import run_with_client

    client = FakeChannelClient()
    topic = "handler:noop/worker-1"

    task = asyncio.create_task(run_with_client(client, topic=topic))
    for _ in range(20):
        if client.on_frame_cb is not None:
            break
        await asyncio.sleep(0.001)

    assert client.connected is True
    assert client.joined_topic == topic
    assert client.on_frame_cb is not None

    task.cancel()
    try:
        await task
    except (asyncio.CancelledError, BaseExceptionGroup):
        pass
    assert client.closed is True


@pytest.mark.asyncio
async def test_handler_worker_filters_handler_call_envelopes() -> None:
    """_on_frame queues handler_call envelopes; ignores other kinds/events."""
    from esr.ipc.handler_worker import run_with_client

    client = FakeChannelClient()
    topic = "handler:noop/worker-1"

    task = asyncio.create_task(run_with_client(client, topic=topic))
    for _ in range(20):
        if client.on_frame_cb is not None:
            break
        await asyncio.sleep(0.001)

    # ignored
    client.on_frame_cb([None, "1", topic, "phx_reply", {"status": "ok"}])
    client.on_frame_cb([None, "2", topic, "envelope", {"kind": "event"}])
    client.on_frame_cb(["short"])
    # accepted — handler_call with unknown module so process_handler_call
    # returns {"error": ...}; we only verify the push happens.
    client.on_frame_cb([None, "3", topic, "envelope",
                        {"kind": "handler_call", "id": "req-1",
                         "payload": {"module": "nonexistent",
                                     "state": {},
                                     "event": {"event_type": "x", "args": {}}}}])

    # give the inner worker loop ticks to process — we wait for the
    # handler_reply specifically because run_with_client also pushes a
    # handler_hello on join (capabilities spec §3.1), which lands in
    # client.pushes before the reply.
    replies = []
    for _ in range(200):
        replies = [p for p in client.pushes if p[2].get("kind") == "handler_reply"]
        if replies:
            break
        await asyncio.sleep(0.001)

    task.cancel()
    try:
        await task
    except (asyncio.CancelledError, BaseExceptionGroup):
        pass

    # The first push is the boot handler_hello handshake; the second is
    # the reply produced by routing through process_handler_call.
    assert len(client.pushes) == 2
    hello_t, hello_event, hello_payload = client.pushes[0]
    assert hello_event == "envelope"
    assert hello_payload["kind"] == "handler_hello"
    assert "permissions" in hello_payload["payload"]

    t, event, payload = client.pushes[1]
    assert t == topic
    assert event == "envelope"
    assert payload["kind"] == "handler_reply"
    assert payload["id"] == "req-1"
    # The reply payload contains an error because module is not registered —
    # confirms we routed through process_handler_call, not a stub.
    assert "error" in payload["payload"]
