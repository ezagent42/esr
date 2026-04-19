"""Tests for verify_entry_bodies.py — LG-2 implementation."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_entry_bodies.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "entry_bodies"


def run(target: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--target", target],
        capture_output=True,
        text=True,
        check=False,
    )


def test_detects_pass_body_as_stub() -> None:
    res = run(str(FIXTURES / "stub_run.py") + ":run")
    assert res.returncode != 0
    assert "stub" in res.stdout.lower() or "empty" in res.stdout.lower() or "cheap" in res.stdout.lower()


def test_accepts_real_body() -> None:
    res = run(str(FIXTURES / "real_run.py") + ":run")
    assert res.returncode == 0, res.stdout + res.stderr


def test_detects_not_implemented_sentinel() -> None:
    res = run(str(FIXTURES / "stub_run.py") + ":stub_dict_return")
    assert res.returncode != 0
    assert "stub" in res.stdout.lower()


def test_detects_logger_only_three_stmt_stub() -> None:
    """Reviewer C-P2: body of 3 cheap (logger/print/pass) stmts is a stub."""
    res = run(str(FIXTURES / "cheap_log.py") + ":run")
    assert res.returncode != 0
    assert "cheap" in res.stdout.lower() or "stub" in res.stdout.lower() or "trivial" in res.stdout.lower()
