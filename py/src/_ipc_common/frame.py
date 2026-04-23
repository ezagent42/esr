"""Phoenix v2 channel frame filter (shared by adapter + handler IPC).

Phoenix v2 frames arrive as `[join_ref, ref, topic, event, payload]`.
Both the adapter dispatcher and the handler worker care only about
envelopes (event == "envelope") whose payload has a specific `kind`.
This module factors the filter closure so the two callers pass only
their `kind` string and an `asyncio.Queue` to receive the matching
payloads.
"""
from __future__ import annotations

import asyncio
from collections.abc import Callable
from typing import Any


def make_envelope_filter(
    kind: str, queue: asyncio.Queue[dict[str, Any] | None]
) -> Callable[[list[Any]], None]:
    """Return an on-frame callback that enqueues payloads matching `kind`."""
    def _on_frame(frame: list[Any]) -> None:
        if len(frame) < 5:
            return
        event, payload = frame[3], frame[4]
        if event != "envelope" or not isinstance(payload, dict):
            return
        if payload.get("kind") != kind:
            return
        queue.put_nowait(payload)

    return _on_frame
