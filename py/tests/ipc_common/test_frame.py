"""make_envelope_filter emits payloads only for matching `kind`."""
from __future__ import annotations

import asyncio

import pytest

from _ipc_common.frame import make_envelope_filter


@pytest.mark.asyncio
async def test_matches_kind_and_enqueues() -> None:
    queue: asyncio.Queue = asyncio.Queue()
    on_frame = make_envelope_filter("directive", queue)
    on_frame([None, None, "topic", "envelope", {"kind": "directive", "id": 1}])
    assert queue.get_nowait() == {"kind": "directive", "id": 1}


@pytest.mark.asyncio
async def test_drops_wrong_kind() -> None:
    queue: asyncio.Queue = asyncio.Queue()
    on_frame = make_envelope_filter("directive", queue)
    on_frame([None, None, "topic", "envelope", {"kind": "event"}])
    assert queue.empty()


@pytest.mark.asyncio
async def test_ignores_non_envelope_event() -> None:
    queue: asyncio.Queue = asyncio.Queue()
    on_frame = make_envelope_filter("directive", queue)
    on_frame([None, None, "topic", "phx_reply", {"kind": "directive"}])
    assert queue.empty()


@pytest.mark.asyncio
async def test_ignores_short_frame() -> None:
    queue: asyncio.Queue = asyncio.Queue()
    on_frame = make_envelope_filter("directive", queue)
    on_frame([None, None, "topic"])  # len 3
    assert queue.empty()
