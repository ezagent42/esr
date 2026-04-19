"""Tests for verify_prd_acceptance.py — LG-3 + LG-5."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_prd_acceptance.py"
FIX = Path(__file__).resolve().parent / "fixtures"


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True, text=True, check=False,
    )


def test_good_manifest_passes() -> None:
    res = run(["--prd-dir", str(FIX / "prds" / "good"),
               "--manifest", str(FIX / "manifest.yaml")])
    assert res.returncode == 0, res.stdout + res.stderr
    assert "Acceptance items ticked" in res.stdout


def test_deleted_row_rejected() -> None:
    res = run(["--prd-dir", str(FIX / "prds" / "bad_deletion"),
               "--manifest", str(FIX / "manifest.yaml")])
    assert res.returncode != 0
    assert "missing" in res.stdout.lower()


def test_deferred_phrase_rejected() -> None:
    res = run(["--prd-dir", str(FIX / "prds" / "bad_deferred"),
               "--regex-scan"])
    assert res.returncode != 0
    assert "deferred" in res.stdout.lower() or "defer" in res.stdout.lower()
