"""Tests for loopguard_scenarios_allowlist.py — LG-6."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "loopguard_scenarios_allowlist.py"


def run(scenarios_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--dir", str(scenarios_dir)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_exactly_one_allowed_file_passes(tmp_path: Path) -> None:
    (tmp_path / "e2e-feishu-cc.yaml").write_text("name: e2e-feishu-cc\n")
    res = run(tmp_path)
    assert res.returncode == 0, res.stdout + res.stderr


def test_extra_file_rejected(tmp_path: Path) -> None:
    (tmp_path / "e2e-feishu-cc.yaml").write_text("name: e2e-feishu-cc\n")
    (tmp_path / "e2e-smoke.yaml").write_text("name: smoke\n")
    res = run(tmp_path)
    assert res.returncode != 0
    assert "e2e-smoke" in res.stdout


def test_missing_allowed_file_rejected(tmp_path: Path) -> None:
    res = run(tmp_path)
    assert res.returncode != 0
    assert "e2e-feishu-cc.yaml" in res.stdout


def test_subdirectory_rejected(tmp_path: Path) -> None:
    """Reviewer C-P4: scenarios/extra/bypass.yaml must be detected."""
    (tmp_path / "e2e-feishu-cc.yaml").write_text("name: x\n")
    (tmp_path / "extra").mkdir()
    (tmp_path / "extra" / "bypass.yaml").write_text("name: y\n")
    res = run(tmp_path)
    assert res.returncode != 0
    assert "extra" in res.stdout or "subdirectory" in res.stdout.lower()
