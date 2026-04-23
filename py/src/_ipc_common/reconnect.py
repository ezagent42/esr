"""Exponential backoff schedule + generic reconnect loop for IPC (shared).

This module provides the backoff schedule and a reusable reconnect loop that
both the adapter dispatcher and handler worker can use to wrap their
single-connection ``run_with_client`` functions. The loop handles URL
re-resolution, client factory creation, and exponential backoff on
ConnectionError/OSError while protecting against unexpected exceptions.
"""
from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from typing import Any

logger = logging.getLogger(__name__)

#: Seconds between successive ``run_with_client`` attempts. Indexed by
#: attempt count with ``min(attempt, len-1)`` (the last entry is the
#: sustained ceiling).
RECONNECT_BACKOFF_SCHEDULE: tuple[float, ...] = (0.2, 0.4, 0.8, 1.6, 3.2, 5.0)


async def reconnect_loop(
    run_one: Callable[[Any], Awaitable[None]],
    *,
    fallback_url: str,
    client_factory: Callable[[str], Any] | None = None,
    backoff_schedule: tuple[float, ...] = RECONNECT_BACKOFF_SCHEDULE,
) -> None:
    """Generic exponential-backoff reconnect loop.

    ``run_one(client)`` is invoked per attempt; a clean return resets
    the backoff; ConnectionError/OSError triggers a backoff sleep and
    retry; any other exception is also caught to protect the loop.
    Use this from adapter_runner and handler_worker wrappers that
    construct their own client and provide their run_one callable.

    Args:
        run_one: Async callable that receives a client and runs one connection cycle.
        fallback_url: Default URL to resolve; passed to resolve_url() on each attempt.
        client_factory: Optional factory fn(url) -> client. Defaults to ChannelClient.
        backoff_schedule: Tuple of delays; last entry is sustained ceiling.
    """
    from _ipc_common.url import resolve_url

    # Lazy import keeps _ipc_common.reconnect free of circular imports
    # with the channel client module tree.
    if client_factory is None:
        from esr.ipc.channel_client import ChannelClient
        client_factory = lambda u: ChannelClient(u)

    attempt = 0
    while True:
        url = resolve_url(fallback_url)
        client = client_factory(url)
        try:
            await run_one(client)
            attempt = 0
        except asyncio.CancelledError:
            raise
        except (ConnectionError, OSError) as exc:
            logger.warning("run_one disconnected (%s); reconnecting", exc)
        except Exception as exc:  # noqa: BLE001
            logger.warning("run_one raised unexpected error (%s); reconnecting", exc)

        delay = backoff_schedule[min(attempt, len(backoff_schedule) - 1)]
        await asyncio.sleep(delay)
        attempt += 1
