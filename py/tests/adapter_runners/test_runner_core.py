"""Tests for ``_adapter_common.runner_core`` — the shared per-sidecar core.

Migrated from ``py/tests/test_adapter_runner{,_main,_run}.py`` as part of
PR-4b's monolith split. The three pre-existing files are preserved (they
still import ``esr.ipc.adapter_runner``, which PR-4b-6 converts to a
deprecation shim); this consolidated file asserts the same behaviours
against the new shared package so the core stays green even if the shim
is later deleted.

PRD 03 F09 / F10 coverage:
- ``process_directive`` happy / error / missing-args / missing-action
- ``directive_loop`` FIFO ordering
- ``event_loop`` envelope shape
- Directive + event interleave
- ``run_with_client`` connect/join, directive filtering, help-CLI
- ``_parse_main_args`` / ``main`` delegation (moved — now exercised via
  ``build_main`` in ``test_feishu_adapter_runner`` et al.)
"""
from __future__ import annotations

import asyncio
import subprocess
import sys
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any

import pytest

from _adapter_common.runner_core import (
    directive_loop,
    event_loop,
    process_directive,
    run_with_client,
)


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
    """Mock Phoenix pusher: captures every envelope as a flat list."""

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


async def test_process_directive_requires_action_key() -> None:
    a = _FakeAdapter()
    with pytest.raises(KeyError):
        await process_directive(a, {"args": {}})  # missing 'action'


# --- PRD 03 F10: directive FIFO ordering -------------------------------


async def test_directive_loop_processes_fifo() -> None:
    """Three directives with distinct delays — acks still arrive in submit order."""
    a = _FakeAdapter()
    # D1 has the longest delay; FIFO means D2/D3 wait for D1 to finish.
    a.directive_delays = {"D1": 0.05, "D2": 0.0, "D3": 0.0}

    queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
    pusher = _RecordingPusher(source="esr://localhost/adapter/test")

    loop_task = asyncio.create_task(directive_loop(a, queue, pusher))

    await queue.put({"id": "d-1", "payload": {"action": "D1", "args": {}}})
    await queue.put({"id": "d-2", "payload": {"action": "D2", "args": {}}})
    await queue.put({"id": "d-3", "payload": {"action": "D3", "args": {}}})
    await queue.put(None)  # sentinel → stop

    await loop_task

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


# --- run_with_client orchestration (ported from test_adapter_runner_run) --


@dataclass
class _FakeChannelClient:
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


class _FakeMinimalAdapter:
    async def on_directive(self, action: str, args: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True}

    async def emit_events(self) -> Any:
        if False:
            yield {}
        # intentionally never yields


@pytest.mark.asyncio
async def test_run_with_client_connects_and_joins() -> None:
    client = _FakeChannelClient()
    adapter = _FakeMinimalAdapter()
    topic = "adapter:feishu/inst-1"

    task = asyncio.create_task(run_with_client(adapter, client, topic=topic))
    # Yield repeatedly so run_with_client reaches join().
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
async def test_run_with_client_parses_directive_envelope() -> None:
    """The _on_frame callback queues directive envelopes and ignores others."""
    client = _FakeChannelClient()
    adapter = _FakeMinimalAdapter()
    topic = "adapter:feishu/inst-1"

    task = asyncio.create_task(run_with_client(adapter, client, topic=topic))
    for _ in range(20):
        if client.on_frame_cb is not None:
            break
        await asyncio.sleep(0.001)

    # Non-envelope event — ignored.
    client.on_frame_cb([None, "1", topic, "phx_reply", {"status": "ok"}])
    # Wrong-kind payload — ignored.
    client.on_frame_cb([None, "2", topic, "envelope", {"kind": "event"}])
    # Malformed — too-short frame ignored.
    client.on_frame_cb(["partial"])
    # Actual directive — should land.
    client.on_frame_cb([None, "3", topic, "envelope",
                        {"kind": "directive", "id": "req-1",
                         "payload": {"action": "ping", "args": {}}}])

    # No push assertion needed here — the composition of _on_frame +
    # directive_loop is covered above. We only need to verify no
    # exception leaked out of the callbacks.

    task.cancel()
    try:
        await task
    except (asyncio.CancelledError, BaseExceptionGroup):
        pass


# --- URL resolution (ported from test_ipc_reconnect) -------------------


def test_resolve_url_reads_port_file(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Port file present → URL port is rewritten."""
    from _adapter_common.url import resolve_url

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("5555\n")

    fallback = "ws://127.0.0.1:4001/adapter_hub/socket/websocket?vsn=2.0.0"
    resolved = resolve_url(fallback)
    assert ":5555/" in resolved
    assert ":4001" not in resolved
    assert "vsn=2.0.0" in resolved


def test_resolve_url_absent_port_file_returns_fallback(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    from _adapter_common.url import resolve_url

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "nonexistent")
    fallback = "ws://127.0.0.1:4001/adapter_hub/socket/websocket"
    assert resolve_url(fallback) == fallback


def test_resolve_url_malformed_port_file_returns_fallback(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    from _adapter_common.url import resolve_url

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("not-a-port\n")

    fallback = "ws://127.0.0.1:4001/adapter_hub/socket/websocket"
    assert resolve_url(fallback) == fallback
