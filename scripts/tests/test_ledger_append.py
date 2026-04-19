"""Tests for ledger_append.py — S2 enum dispatch."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "ledger_append.py"


def _init_ledger(tmp_path: Path) -> Path:
    ledger = tmp_path / "ledger.md"
    ledger.write_text(
        "| iter | date | phase | FR | commit | evidence-type | evidence-sha |\n"
        "|------|------|-------|-----|--------|---------------|--------------|\n"
    )
    return ledger


def test_append_with_approved_enum(tmp_path: Path) -> None:
    ledger = _init_ledger(tmp_path)
    res = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--ledger", str(ledger),
         "--phase", "8a", "--fr", "F13",
         "--evidence-type", "loopguard",
         "--dry-run"],
        capture_output=True, text=True, check=False,
    )
    assert res.returncode == 0, res.stdout + res.stderr
    content = ledger.read_text()
    assert "| 1 |" in content
    assert "loopguard" in content


def test_rejects_bad_enum(tmp_path: Path) -> None:
    ledger = _init_ledger(tmp_path)
    res = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--ledger", str(ledger),
         "--phase", "8a", "--fr", "F13",
         "--evidence-type", "custom_shell",
         "--dry-run"],
        capture_output=True, text=True, check=False,
    )
    assert res.returncode != 0
    assert "evidence-type" in res.stderr.lower() or "enum" in res.stderr.lower()
