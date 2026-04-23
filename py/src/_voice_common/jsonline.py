"""JSON-line stdin/stdout protocol for voice sidecars (spec §8.1).

Each stdin line is a single JSON object with at minimum `id` and `kind`.
Replies and stream frames share the same shape so the Elixir side's
`Esr.PyProcess` can decode uniformly.
"""
from __future__ import annotations

import json
import sys
from collections.abc import Iterable
from typing import IO


def read_requests(stream: IO[str] = sys.stdin) -> Iterable[dict]:
    """Yield parsed request objects from `stream` until EOF.

    Blank lines and lines that don't parse as JSON are skipped silently;
    operators can watch `logger.warning` in stderr for bad frames. The
    sidecar exits cleanly on EOF (stdin closed by Elixir owner).
    """
    for raw in stream:
        line = raw.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            # Spec §8.1: stderr reserved for logs; don't crash on bad
            # JSON — just drop the frame. The Elixir side will notice
            # any missing reply via its `id`-keyed pending-request map.
            sys.stderr.write(f"voice-sidecar: bad JSON line dropped: {line!r}\n")
            sys.stderr.flush()


def _write_frame(stream: IO[str], frame: dict) -> None:
    stream.write(json.dumps(frame) + "\n")
    stream.flush()


def write_reply(stream: IO[str], req_id: str, payload: dict) -> None:
    _write_frame(stream, {"id": req_id, "kind": "reply", "payload": payload})


def write_stream_chunk(stream: IO[str], req_id: str, payload: dict) -> None:
    _write_frame(stream, {"id": req_id, "kind": "stream_chunk", "payload": payload})


def write_stream_end(stream: IO[str], req_id: str) -> None:
    _write_frame(stream, {"id": req_id, "kind": "stream_end"})
