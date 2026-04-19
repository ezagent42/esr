"""Mock CC (Claude Code) subprocess — Phase 8d.

The cc_tmux adapter launches a real `claude` binary inside a tmux session
and parses sentinel-prefixed stdout lines (``^[esr-cc] ``) as cc_output
events. This mock stands in for the `claude` binary:

- Prints ``[esr-cc] ready`` on startup so the adapter sees an initial
  event immediately after attach.
- Echoes every stdin line back as ``[esr-cc] echo: <line>`` so the
  adapter can verify round-trip: it sent via tmux send-keys, mock received
  on stdin, emitted a sentinel, adapter captured it.
- Exits on EOF.

Usage:
    # Launched by cc_tmux adapter via tmux:
    tmux new-session -d -s smoke-test "uv run --project py python scripts/mock_cc.py"

    # Standalone for manual exercise:
    echo -e "hello\\nworld" | uv run --project py python scripts/mock_cc.py
"""
from __future__ import annotations

import sys


def main() -> int:
    sys.stdout.write("[esr-cc] ready\n")
    sys.stdout.flush()

    for raw in sys.stdin:
        line = raw.rstrip("\n\r")
        sys.stdout.write(f"[esr-cc] echo: {line}\n")
        sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
