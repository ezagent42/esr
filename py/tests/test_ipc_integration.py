"""PRD 03 F13 — live-runtime IPC integration smoke test.

Gated behind ``ESR_E2E_RUNTIME=1`` — skipped in ordinary CI so the
unit-test suite doesn't depend on a running Phoenix endpoint. Run
manually with:

    ESR_E2E_RUNTIME=1 uv run pytest py/tests/test_ipc_integration.py

Prerequisites when the gate is on:

- ``cd runtime && iex -S mix phx.server`` (or ``mix phx.server``)
  is running on ``ws://localhost:4001``.
- A ``noop.on_msg`` handler is registered in the worker process we
  spawn (the test registers one).
"""

from __future__ import annotations

import asyncio
import os
from typing import Any

import pytest
from pydantic import BaseModel

from esr.handler import HANDLER_REGISTRY, STATE_REGISTRY, handler, handler_state
from esr.ipc.channel_client import ChannelClient
from esr.ipc.handler_worker import process_handler_call
from esr.ipc.url import discover_runtime_url

pytestmark = pytest.mark.skipif(
    os.environ.get("ESR_E2E_RUNTIME") != "1",
    reason="live runtime not running; set ESR_E2E_RUNTIME=1 to exercise",
)


@pytest.fixture(autouse=True)
def _clear_registries() -> None:
    HANDLER_REGISTRY.clear()
    STATE_REGISTRY.clear()


def _register_noop() -> None:
    @handler_state(actor_type="noop", schema_version=1)
    class _S(BaseModel):
        model_config = {"frozen": True}
        counter: int = 0

    @handler(actor_type="noop", name="on_msg")
    def _on_msg(state: _S, event: Any) -> tuple[_S, list[Any]]:
        return _S(counter=state.counter + 1), []


async def test_handler_call_round_trip_live() -> None:
    """Worker subscribes to handler:noop/default, test emulates the
    Elixir HandlerRouter by broadcasting handler_call on that topic
    via its own ChannelClient, then waits for handler_reply on
    handler_reply:<id>.

    On a warm path this must return within 2 s (PRD 03 non-functional
    §1).
    """
    _register_noop()

    url = discover_runtime_url(kind="handler")
    worker_client = ChannelClient(url)
    caller_client = ChannelClient(url)

    reply_future: asyncio.Future[dict[str, Any]] = asyncio.get_event_loop().create_future()

    try:
        await worker_client.connect()
        await caller_client.connect()

        async def on_handler_call(frame: list[Any]) -> None:
            # frame = [join_ref, ref, topic, event, payload]
            payload = frame[4]
            reply_payload = process_handler_call(payload)
            reply_topic = f"handler_reply:{payload['id']}"
            await caller_client.push(reply_topic, "handler_reply", reply_payload)

        def _handler_call_sync(frame: list[Any]) -> None:
            # ChannelClient passes frames synchronously; delegate to async task.
            asyncio.create_task(on_handler_call(frame))

        await worker_client.join("handler:noop/default", on_msg=_handler_call_sync)
        await caller_client.join(
            "handler_reply:test-1",
            on_msg=lambda frame: reply_future.set_result(frame[4]),
        )

        await caller_client.push("handler:noop/default", "handler_call", {
            "id": "test-1",
            "ts": "2026-04-20T00:00:00Z",
            "type": "handler_call",
            "source": "esr://localhost/runtime",
            "payload": {
                "handler": "noop.on_msg",
                "state": {"counter": 0},
                "event": {
                    "source": "esr://localhost/adapter/test",
                    "event_type": "tick",
                    "args": {},
                },
            },
        })

        reply = await asyncio.wait_for(reply_future, timeout=2.0)
        assert "error" not in reply
        assert reply["new_state"]["counter"] == 1
        assert reply["new_state"]["_schema_version"] == 1
    finally:
        await worker_client.close()
        await caller_client.close()


