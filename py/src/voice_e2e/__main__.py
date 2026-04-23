"""Entry-point for `python -m voice_e2e`.

Bidirectional voice-to-voice: one request turn produces a stream of
stream_chunk frames followed by stream_end. Stub engine emits 3 fixed
chunks so tests are deterministic.
"""
from __future__ import annotations

import os
import sys

from _voice_common.jsonline import read_requests, write_stream_chunk, write_stream_end


def _stub_chunks(audio_b64: str) -> list[dict]:
    # Fixed 3-chunk reply for the stub engine; real engine streams from
    # a live TTS socket. Shape is stable so the Elixir peer's chunk
    # accumulator test can assert exact frames.
    return [
        {"audio_b64": audio_b64[:2], "seq": 0},
        {"audio_b64": audio_b64[2:4], "seq": 1},
        {"audio_b64": audio_b64[4:], "seq": 2},
    ]


def main() -> int:
    engine = os.environ.get("VOICE_E2E_ENGINE", os.environ.get("VOICE_ENGINE", "stub"))
    for req in read_requests(sys.stdin):
        if req.get("kind") != "request":
            continue
        req_id = req.get("id", "")
        audio = (req.get("payload") or {}).get("audio_b64", "")
        if engine == "stub":
            for chunk in _stub_chunks(audio):
                write_stream_chunk(sys.stdout, req_id, chunk)
            write_stream_end(sys.stdout, req_id)
        else:
            # Real engine lands in PR-5; keep the sidecar crashable so
            # ops knows env was misconfigured.
            sys.stderr.write(f"voice_e2e: unknown engine {engine!r}\n")
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
