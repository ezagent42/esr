#!/usr/bin/env python3
"""Single-session HTTP poll helper for e2e wait loops.

Background (2026-04-26 — TIME_WAIT storm RCA):
The original wait loops used `for _ in $(seq 1 N); do curl ...; sleep
0.1; done`. Each iteration forked a fresh `curl` subprocess that
opened a new TCP socket to mock_feishu, parsed the response, and
closed. macOS keeps each closed connection in TIME_WAIT for 2*MSL
(default 30s). A single failing wait loop generated ~1200 TIME_WAIT
entries; a full scenario 04 run with 6 such loops generated up to
7200; ~12 retries during PR-A T9 development put 30k+ on the
workstation, exhausting the 127.0.0.1 ephemeral port pool and
breaking proxied HTTPS for the user's other services.

Fix: this helper opens ONE `requests.Session()` (which keeps the TCP
socket alive across HTTP requests via Connection: keep-alive) and
polls until the jq-style filter matches or the deadline expires.
A full scenario run that previously generated 1200 TIME_WAITs now
generates 1.

Usage:
  _wait_url.py URL JQ_FILTER [--iterations N] [--sleep-ms N]
                              [--connect-timeout S] [--max-time S]

Returns 0 on match, 1 on timeout (no match within deadline) or any
other failure. The matched JSON output is written to stdout.

JQ_FILTER syntax: a string passed straight to `jq -e`. Example:
  '.[] | select(.receive_id == "oc_x")'

This is invoked via `subprocess.run` rather than embedded in Python
because we want test prose to keep using familiar jq syntax. The
helper does the HTTP polling; jq does the JSON test.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from typing import Optional

try:
    import requests
except ImportError:
    sys.stderr.write(
        "_wait_url.py: requests not importable. Run via "
        "`uv run --project py python tests/e2e/scenarios/_wait_url.py ...`\n"
    )
    sys.exit(2)


def _jq_eval(filter_expr: str, payload: bytes) -> Optional[bytes]:
    """Run `jq -e FILTER` against payload. Return matched bytes on
    exit 0; None on exit != 0 (no match or jq error)."""
    jq = shutil.which("jq")
    if not jq:
        sys.stderr.write("_wait_url.py: jq not in PATH\n")
        sys.exit(2)
    proc = subprocess.run(
        [jq, "-e", filter_expr],
        input=payload,
        capture_output=True,
        check=False,
    )
    if proc.returncode == 0:
        return proc.stdout
    return None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("url", help="HTTP URL to poll")
    p.add_argument(
        "filter",
        help="jq filter to evaluate against each response. Match (exit 0) "
             "ends the wait; no-match continues polling.",
    )
    p.add_argument("--iterations", type=int, default=1200,
                   help="Max poll attempts (default 1200)")
    p.add_argument("--sleep-ms", type=int, default=100,
                   help="Sleep between attempts (default 100ms)")
    p.add_argument("--connect-timeout", type=float, default=2.0,
                   help="Per-request connect timeout (default 2.0s)")
    p.add_argument("--max-time", type=float, default=5.0,
                   help="Per-request total timeout (default 5.0s)")
    args = p.parse_args()

    sleep_s = args.sleep_ms / 1000.0
    timeout = (args.connect_timeout, args.max_time)

    # ONE session for the whole poll. Connection: keep-alive lets the
    # TCP socket survive across requests — this is the load-bearing
    # change vs the per-iteration `curl` shell loop.
    with requests.Session() as session:
        for _ in range(args.iterations):
            try:
                resp = session.get(args.url, timeout=timeout)
                payload = resp.content
            except requests.RequestException:
                # Server might still be starting; sleep + retry.
                time.sleep(sleep_s)
                continue

            matched = _jq_eval(args.filter, payload)
            if matched is not None:
                sys.stdout.buffer.write(matched)
                sys.stdout.flush()
                return 0

            time.sleep(sleep_s)

    return 1  # timed out without a jq match


if __name__ == "__main__":
    sys.exit(main())
