#!/usr/bin/env python3
"""Test fixture: echo each JSON-line request as a reply with the same id.

Exits cleanly when stdin hits EOF (BEAM closes the Port). The standard
``for line in sys.stdin`` loop terminates on EOF, which is the intended
cleanup signal for this sidecar — see Esr.OSProcess wrapper: :none
docstring.
"""
import json
import sys


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        reply = {
            "id": req.get("id"),
            "kind": "reply",
            "payload": req.get("payload"),
        }
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()
    # stdin EOF reached — exit cleanly so BEAM receives exit_status 0.
    return 0


if __name__ == "__main__":
    sys.exit(main())
