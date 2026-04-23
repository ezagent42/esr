"""Entry-point for `python -m voice_asr`.

Reads JSON-line requests from stdin, transcribes via the selected
engine, writes JSON-line replies to stdout. Exits cleanly on stdin EOF.
"""
from __future__ import annotations

import sys

from _voice_common.engine import select_asr
from _voice_common.jsonline import read_requests, write_reply


def main() -> int:
    engine = select_asr()
    for req in read_requests(sys.stdin):
        if req.get("kind") != "request":
            continue
        req_id = req.get("id", "")
        payload = req.get("payload") or {}
        audio = payload.get("audio_b64", "")
        text = engine.transcribe(audio)
        write_reply(sys.stdout, req_id, {"text": text})
    return 0


if __name__ == "__main__":
    sys.exit(main())
