"""Tests for verify_cli_tests_live.py — LG-9 + LG-10 + C-P3."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_cli_tests_live.py"
FIX = Path(__file__).resolve().parent / "fixtures" / "cli_tests"


def run(target: Path, no_monkeypatch: bool = False) -> subprocess.CompletedProcess[str]:
    args = [sys.executable, str(SCRIPT), "--target", str(target)]
    if no_monkeypatch:
        args.append("--no-monkeypatch")
    return subprocess.run(args, capture_output=True, text=True, check=False)


def test_good_test_file_passes() -> None:
    res = run(FIX / "good.py")
    assert res.returncode == 0, res.stdout + res.stderr


def test_missing_fixture_rejected() -> None:
    res = run(FIX / "bad_no_fixture.py")
    assert res.returncode != 0
    assert "esrd_fixture" in res.stdout


def test_monkeypatch_rejected() -> None:
    res = run(FIX / "bad_monkeypatch.py", no_monkeypatch=True)
    assert res.returncode != 0
    assert "monkeypatch" in res.stdout.lower() or "_submit" in res.stdout


def test_decorator_patch_rejected() -> None:
    """Reviewer C-P3: @patch('..._submit_cmd_run') must be caught."""
    res = run(FIX / "bad_decorator_patch.py", no_monkeypatch=True)
    assert res.returncode != 0
    assert "_submit" in res.stdout


def test_patch_object_rejected() -> None:
    """Reviewer C-P3: mocker.patch.object(..., '_submit_*') must be caught."""
    res = run(FIX / "bad_patch_object.py", no_monkeypatch=True)
    assert res.returncode != 0
    assert "_submit" in res.stdout
