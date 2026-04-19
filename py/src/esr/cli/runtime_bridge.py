"""CLI → runtime Phoenix-channel bridge (Phase 8c base).

The eight ``_submit_*`` helpers in ``esr.cli.main`` funnel through ``call``
below. Phase 8c iterates to: real ChannelClient setup, per-op topic
mapping, timeout + retry policy, structured error surfacing.
"""
from __future__ import annotations

from typing import Any

from esr.ipc.url import discover_runtime_url


class RuntimeUnreachable(RuntimeError):
    """Raised when the CLI cannot reach a running esrd. The message always
    includes the endpoint it tried so operators can diagnose.
    """


def connect(*, override: str | None = None) -> Any:
    """Open a ChannelClient joined to the ``cli:<op>`` control socket."""
    url = discover_runtime_url(override=override, kind="handler")
    from esr.ipc.channel_client import ChannelClient
    client = ChannelClient(url, source_uri="cli")
    import asyncio
    asyncio.run(client.connect())
    return client


def call(client: Any, *, topic: str, payload: dict[str, Any],
         timeout_sec: float = 30.0) -> dict[str, Any]:
    """Send a CLI control envelope and await the reply."""
    import asyncio
    envelope = {"kind": "cli_call", "topic": topic, "payload": payload}
    future = asyncio.run(client.call(envelope, timeout=timeout_sec))
    if isinstance(future, dict) and future.get("error"):
        raise RuntimeUnreachable(str(future["error"]))
    return future if isinstance(future, dict) else {}


def push_event(client: Any, *, topic: str, event: dict[str, Any]) -> None:
    """Fire-and-forget push on a CLI control topic."""
    import asyncio
    asyncio.run(client.push_envelope({
        "kind": "cli_event",
        "topic": topic,
        "payload": event,
    }))
