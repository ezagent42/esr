"""Tests for scripts/mock_cc.py — Phase 8d.

Mock CC is a subprocess that reads stdin line-by-line and emits
sentinel-prefixed responses on stdout. The cc_tmux adapter parses
`^[esr-cc] ` prefixed lines as ``cc_output`` events.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "mock_cc.py"


def test_mock_cc_echoes_with_sentinel_prefix() -> None:
    """Every stdin line triggers a '[esr-cc] echo: ...' stdout line."""
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        input="hello\nworld\n",
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert result.returncode == 0, result.stderr
    lines = result.stdout.strip().splitlines()
    # at least one banner + two echoes — mock_cc prints a banner on start.
    echoes = [ln for ln in lines if ln.startswith("[esr-cc] echo:")]
    assert len(echoes) == 2
    assert echoes[0] == "[esr-cc] echo: hello"
    assert echoes[1] == "[esr-cc] echo: world"


def test_mock_cc_emits_startup_sentinel() -> None:
    """Mock_cc announces itself so the cc_tmux adapter's emit_events
    sentinel parser sees a first line immediately on attach."""
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        input="",
        capture_output=True,
        text=True,
        timeout=5,
    )
    first = result.stdout.splitlines()[0]
    assert first.startswith("[esr-cc] ready")
