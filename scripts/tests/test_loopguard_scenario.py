"""Tests for loopguard_scenario.py — LG-1 + reviewer C-P1 + S4."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "loopguard_scenario.py"
FIX = Path(__file__).resolve().parent / "fixtures"


def run(yaml_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT),
         "--scenario", str(yaml_path),
         "--signatures", str(FIX / "signatures.txt")],
        capture_output=True,
        text=True,
        check=False,
    )


def test_good_scenario_passes() -> None:
    res = run(FIX / "scenarios" / "good.yaml")
    assert res.returncode == 0, res.stdout + res.stderr


def test_covered_by_rejected() -> None:
    res = run(FIX / "scenarios" / "bad_covered_by.yaml")
    assert res.returncode != 0
    assert "covered_by" in res.stdout.lower()


def test_weak_signature_rejected() -> None:
    res = run(FIX / "scenarios" / "bad_signature.yaml")
    assert res.returncode != 0
    assert "signature" in res.stdout.lower() or "defang" in res.stdout.lower()


def test_defanging_alternation_rejected(tmp_path: Path) -> None:
    """Reviewer C-P1: step regex like 'actor_id=thread:x|(.*)' must be rejected."""
    y = tmp_path / "defang.yaml"
    y.write_text(
        "name: t\nmode: mock\ndescription: t\nsetup: []\nsteps:\n"
        "  - id: x\n    description: x\n    command: echo hi\n"
        "    expect_stdout_match: 'actor_id=thread:fake|(.*)'\n"
        "    expect_exit: 0\n    timeout_sec: 5\nteardown: []\n"
    )
    res = run(y)
    assert res.returncode != 0
    assert "defang" in res.stdout.lower()


def test_literal_signature_substring_accepted(tmp_path: Path) -> None:
    """Reviewer C-P1: honest author with verbatim signature passes."""
    y = tmp_path / "honest.yaml"
    y.write_text(
        "name: t\nmode: mock\ndescription: t\nsetup: []\nsteps:\n"
        "  - id: x\n    description: x\n    command: esr actors list\n"
        r"    expect_stdout_match: 'before pid=<0\.\d+\.\d+> after'" "\n"
        "    expect_exit: 0\n    timeout_sec: 5\nteardown: []\n"
    )
    res = run(y)
    assert res.returncode == 0, res.stdout + res.stderr
