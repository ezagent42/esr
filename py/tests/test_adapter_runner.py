"""PRD 03 F09 / F10 — adapter runner dispatch + FIFO ordering."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from typing import Any

import pytest

from esr.ipc.adapter_runner import directive_loop, event_loop, process_directive


class _FakeAdapter:
    """In-memory adapter stub for unit testing."""

    def __init__(self) -> None:
        self.directive_calls: list[tuple[str, dict[str, Any]]] = []
        self.event_stream: list[dict[str, Any]] = []
        self.directive_delays: dict[str, float] = {}  # action → delay seconds
        self.directive_errors: set[str] = set()  # actions that should raise

    async def on_directive(
        self, action: str, args: dict[str, Any]
    ) -> dict[str, Any]:
        if action in self.directive_errors:
            raise RuntimeError(f"{action} failed")
        delay = self.directive_delays.get(action, 0)
        if delay:
            await asyncio.sleep(delay)
        self.directive_calls.append((action, args))
        return {"processed": action}

    async def emit_events(self) -> AsyncIterator[dict[str, Any]]:
        for e in self.event_stream:
            yield e
            await asyncio.sleep(0)  # let the scheduler interleave


class _RecordingPusher:
    """Mock Phoenix pusher: captures every envelope as (topic, event, payload)."""

    def __init__(self, source: str) -> None:
        self.source_uri = source
        self.pushed: list[dict[str, Any]] = []

    async def push_envelope(self, envelope: dict[str, Any]) -> None:
        self.pushed.append(envelope)


# --- PRD 03 F09: process_directive -------------------------------------


async def test_process_directive_happy_path() -> None:
    a = _FakeAdapter()
    ack = await process_directive(a, {"action": "send", "args": {"x": 1}})
    assert ack == {"ok": True, "result": {"processed": "send"}}
    assert a.directive_calls == [("send", {"x": 1})]


async def test_process_directive_error_path() -> None:
    a = _FakeAdapter()
    a.directive_errors.add("broken")
    ack = await process_directive(a, {"action": "broken", "args": {}})
    assert ack["ok"] is False
    assert ack["error"]["type"] == "RuntimeError"
    assert ack["error"]["message"] == "broken failed"


async def test_process_directive_missing_args_defaults_to_empty() -> None:
    a = _FakeAdapter()
    ack = await process_directive(a, {"action": "send"})  # no 'args'
    assert ack["ok"] is True
    assert a.directive_calls == [("send", {})]


# --- PRD 03 F10: directive FIFO ordering -------------------------------


async def test_directive_loop_processes_fifo() -> None:
    """Three directives with distinct delays — acks still arrive in submit order."""
    a = _FakeAdapter()
    # D1 has the longest delay; FIFO means D2/D3 wait for D1 to finish.
    a.directive_delays = {"D1": 0.05, "D2": 0.0, "D3": 0.0}

    queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
    pusher = _RecordingPusher(source="esr://localhost/adapter/test")

    loop_task = asyncio.create_task(
        directive_loop(a, queue, pusher)
    )

    await queue.put({"id": "d-1", "payload": {"action": "D1", "args": {}}})
    await queue.put({"id": "d-2", "payload": {"action": "D2", "args": {}}})
    await queue.put({"id": "d-3", "payload": {"action": "D3", "args": {}}})
    await queue.put(None)  # sentinel → stop

    await loop_task

    # FIFO on both dispatch order and ack order
    assert [c[0] for c in a.directive_calls] == ["D1", "D2", "D3"]
    assert [ack["id"] for ack in pusher.pushed] == ["d-1", "d-2", "d-3"]
    for ack in pusher.pushed:
        assert ack["type"] == "directive_ack"


# --- PRD 03 F09: event loop --------------------------------------------


async def test_event_loop_pushes_envelopes() -> None:
    """Events from emit_events() are wrapped in envelopes and pushed."""
    a = _FakeAdapter()
    a.event_stream = [
        {"event_type": "msg_received", "args": {"chat_id": "oc_1"}},
        {"event_type": "reaction_added", "args": {"emoji": "thumbs_up"}},
    ]
    pusher = _RecordingPusher(source="esr://localhost/adapter/feishu")

    await event_loop(a, pusher)

    assert len(pusher.pushed) == 2
    assert pusher.pushed[0]["type"] == "event"
    assert pusher.pushed[0]["source"] == "esr://localhost/adapter/feishu"
    assert pusher.pushed[0]["payload"]["event_type"] == "msg_received"
    assert pusher.pushed[0]["payload"]["args"] == {"chat_id": "oc_1"}


async def test_directive_and_event_loops_can_interleave() -> None:
    """When both loops run concurrently, events can arrive while directives process."""
    a = _FakeAdapter()
    a.event_stream = [
        {"event_type": "e1", "args": {}},
        {"event_type": "e2", "args": {}},
    ]
    a.directive_delays = {"slow": 0.02}

    queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
    pusher = _RecordingPusher(source="esr://localhost/adapter/t")

    dtask = asyncio.create_task(directive_loop(a, queue, pusher))
    etask = asyncio.create_task(event_loop(a, pusher))

    await queue.put({"id": "d-1", "payload": {"action": "slow"}})
    await queue.put(None)

    await asyncio.gather(dtask, etask)

    types = [env["type"] for env in pusher.pushed]
    assert "directive_ack" in types
    assert types.count("event") == 2


async def test_process_directive_requires_action_key() -> None:
    a = _FakeAdapter()
    with pytest.raises(KeyError):
        await process_directive(a, {"args": {}})  # missing 'action'
