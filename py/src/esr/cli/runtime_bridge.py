"""CLI → runtime Phoenix-channel bridge (Phase 8c).

The CLI is short-lived, so each ``cli:<op>`` RPC is one-shot: connect +
join + :meth:`ChannelClient.call` + close. Presents a synchronous
interface to the 8 ``_submit_*`` helpers in :mod:`esr.cli.main`.
"""
from __future__ import annotations

import asyncio
from typing import Any

from esr.ipc.url import discover_runtime_url


class RuntimeUnreachable(RuntimeError):
    """Raised when the CLI cannot reach a running esrd. Always carries
    the endpoint URL that was tried.
    """


async def _call_runtime_async(
    *,
    topic: str,
    event: str,
    payload: dict[str, Any],
    url: str,
    timeout_sec: float,
) -> dict[str, Any]:
    from esr.ipc.channel_client import ChannelClient

    client = ChannelClient(url)
    try:
        await client.connect()
    except Exception as exc:
        raise RuntimeUnreachable(
            f"could not connect to esrd at {url}: {exc}"
        ) from exc
    try:
        await client.join(topic, lambda frame: None)
        return await client.call(topic, event, payload, timeout=timeout_sec)
    finally:
        await client.close()


def call_runtime(
    *,
    topic: str,
    event: str = "cli_call",
    payload: dict[str, Any] | None = None,
    override_url: str | None = None,
    timeout_sec: float = 30.0,
) -> dict[str, Any]:
    """One-shot RPC to esrd. Synchronous wrapper around the async path.

    ``topic`` — e.g. ``cli:run/feishu-thread-session``
    ``event`` — defaults to ``cli_call`` (Phoenix "event" field)
    ``payload`` — RPC body (arbitrary JSON-encodable dict)

    Returns the phx_reply payload dict (``{"status": "ok", "response": {...}}``).
    Raises :class:`RuntimeUnreachable` if the runtime is not responsive.
    """
    url = discover_runtime_url(override=override_url, kind="handler")
    try:
        return asyncio.run(_call_runtime_async(
            topic=topic, event=event, payload=(payload or {}),
            url=url, timeout_sec=timeout_sec,
        ))
    except RuntimeUnreachable:
        raise
    except TimeoutError as exc:
        raise RuntimeUnreachable(
            f"esrd at {url} did not reply within {timeout_sec}s: {exc}"
        ) from exc
    except OSError as exc:
        raise RuntimeUnreachable(
            f"could not reach esrd at {url}: {exc}"
        ) from exc
