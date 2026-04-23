"""Task 7 (DI-3): IPC client auto-reconnect with port-file re-read.

Verifies :func:`_adapter_common.runner_core.run_with_reconnect` and
:func:`esr.ipc.handler_worker.run_with_reconnect`:

1. When the WS server closes the connection, the runner attempts a
   second connect within a couple of seconds (exponential backoff
   starts at 200ms).
2. Between attempts, :func:`_ipc_common.url.resolve_url` re-reads
   ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` and substitutes the new
   port into the base URL — so that a launchctl-kickstart restart
   of esrd on a different port is followed seamlessly.
3. If the port file is absent, the CLI-supplied ``--url`` is used
   verbatim as a fallback.

The test server is aiohttp (same stack as ``ChannelClient``): first
connection receives a phx_join, replies ok, then immediately closes
the socket; second connection replies ok and stays open.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import time
from collections.abc import AsyncIterator
from typing import Any

import pytest
from aiohttp import WSMsgType, web


@contextlib.asynccontextmanager
async def _flaky_phoenix_server() -> AsyncIterator[tuple[str, int, list[int]]]:
    """aiohttp WS server that closes the socket on connection #1 and
    stays open on connection #2+.

    Yields ``(base_url, port, connect_counter)`` where ``connect_counter``
    is a list-of-ints (len == number of completed WS lifecycles). We
    return a list rather than a bare int because closures capture by
    reference; tests assert ``len(connect_counter) >= 2`` to see the
    reconnect happen.
    """
    connect_counter: list[int] = []

    async def handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        attempt = len(connect_counter) + 1
        connect_counter.append(attempt)

        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            frame = json.loads(msg.data)
            join_ref, ref, topic, event, _payload = frame
            if event == "phx_join":
                # Reply ok, then: close on attempt #1, stay open on #2+.
                await ws.send_str(json.dumps(
                    [join_ref, ref, topic, "phx_reply",
                     {"status": "ok", "response": {}}]
                ))
                if attempt == 1:
                    await ws.close()
                    return ws
        return ws

    app = web.Application()
    # Match any WS path — runner's resolved URL may include
    # /adapter_hub/socket/websocket?vsn=2.0.0 or similar.
    app.router.add_get("/{tail:.*}", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host="127.0.0.1", port=0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    base_url = f"ws://127.0.0.1:{port}/adapter_hub/socket/websocket?vsn=2.0.0"
    try:
        yield base_url, port, connect_counter
    finally:
        await runner.cleanup()


class _MinimalAdapter:
    """Stand-in adapter for reconnect tests — never emits events, never
    accepts directives. :func:`run_with_client` needs only the symbol."""

    async def on_directive(self, action: str, args: dict[str, Any]) -> dict[str, Any]:
        return {}


@pytest.mark.asyncio
async def test_adapter_runner_reconnects_on_ws_close(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """After the server closes attempt #1, the runner re-connects and
    the second WS lifecycle starts within 3 seconds (backoff base 200ms)."""
    from _adapter_common.runner_core import run_with_reconnect

    async with _flaky_phoenix_server() as (base_url, _port, connect_counter):
        # Make resolve_url() read from tmp_path so we don't depend on a
        # real ~/.esrd layout. Port file absent → fallback to base_url.
        monkeypatch.setenv("ESRD_HOME", str(tmp_path))
        monkeypatch.setenv("ESR_INSTANCE", "test")

        task = asyncio.create_task(
            run_with_reconnect(
                _MinimalAdapter(),
                topic="adapter:noop/inst-1",
                fallback_url=base_url,
                # Fast schedule so the test runs in <3s.
                backoff_schedule=(0.05, 0.1, 0.2, 0.4),
            )
        )

        # Wait up to 3s for the second connection to land.
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            if len(connect_counter) >= 2:
                break
            await asyncio.sleep(0.02)

        task.cancel()
        with contextlib.suppress(asyncio.CancelledError, BaseExceptionGroup):
            await task

        assert len(connect_counter) >= 2, (
            f"expected >=2 connect attempts within 3s, got {len(connect_counter)}"
        )


@pytest.mark.asyncio
async def test_handler_worker_reconnects_on_ws_close(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Symmetric assertion for handler_worker — reconnect kicks in after
    a mid-session close."""
    from esr.ipc import handler_worker

    async with _flaky_phoenix_server() as (base_url, _port, connect_counter):
        monkeypatch.setenv("ESRD_HOME", str(tmp_path))
        monkeypatch.setenv("ESR_INSTANCE", "test")

        task = asyncio.create_task(
            handler_worker.run_with_reconnect(
                topic="handler:noop/w-1",
                fallback_url=base_url,
                backoff_schedule=(0.05, 0.1, 0.2, 0.4),
            )
        )

        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            if len(connect_counter) >= 2:
                break
            await asyncio.sleep(0.02)

        task.cancel()
        with contextlib.suppress(asyncio.CancelledError, BaseExceptionGroup):
            await task

        assert len(connect_counter) >= 2


def test_resolve_url_reads_port_file(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """When ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` exists, the resolver
    rewrites the URL's port — so clients follow an esrd that launchctl
    restarted on a different port."""
    from _ipc_common.url import resolve_url

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("5555\n")

    fallback = "ws://127.0.0.1:4001/adapter_hub/socket/websocket?vsn=2.0.0"
    resolved = resolve_url(fallback)
    assert ":5555/" in resolved
    assert ":4001" not in resolved
    # Path + query preserved
    assert "/adapter_hub/socket/websocket" in resolved
    assert "vsn=2.0.0" in resolved


def test_resolve_url_absent_port_file_returns_fallback(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Missing port file is not an error — fallback URL is returned
    unchanged (dev who runs ``mix phx.server`` by hand still works)."""
    from _ipc_common.url import resolve_url

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "nonexistent")
    fallback = "ws://127.0.0.1:4001/adapter_hub/socket/websocket"
    assert resolve_url(fallback) == fallback


def test_resolve_url_malformed_port_file_returns_fallback(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Garbage in the port file (not a decimal string) is treated as
    absent rather than crashing the runner at boot."""
    from _ipc_common.url import resolve_url

    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    instance_dir = tmp_path / "test"
    instance_dir.mkdir(parents=True, exist_ok=True)
    (instance_dir / "esrd.port").write_text("not-a-port\n")

    fallback = "ws://127.0.0.1:4001/adapter_hub/socket/websocket"
    assert resolve_url(fallback) == fallback
