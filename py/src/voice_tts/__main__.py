"""Entry-point for `python -m voice_tts`.

Reads JSON-line requests from stdin, synthesizes audio via the selected
engine, writes JSON-line replies to stdout. Exits cleanly on stdin EOF.
"""
from __future__ import annotations

import sys

from _voice_common.engine import select_tts
from _voice_common.jsonline import read_requests, write_reply


def main() -> int:
    engine = select_tts()
    for req in read_requests(sys.stdin):
        if req.get("kind") != "request":
            continue
        req_id = req.get("id", "")
        text = (req.get("payload") or {}).get("text", "")
        audio_b64 = engine.synthesize(text)
        write_reply(sys.stdout, req_id, {"audio_b64": audio_b64})
    return 0


if __name__ == "__main__":
    sys.exit(main())
