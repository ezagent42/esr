"""Tests for verify_ledger_append_only.py — LG-7 + S2."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify_ledger_append_only.py"
HEADER = (
    "| iter | date | phase | FR | commit | evidence-type | evidence-sha |\n"
    "|------|------|-------|-----|--------|---------------|--------------|\n"
)


def _init_repo(tmp_path: Path) -> Path:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "t@x"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "t"], check=True)
    return tmp_path


def _commit(repo: Path, body: str, msg: str) -> None:
    (repo / "docs").mkdir(exist_ok=True)
    (repo / "docs" / "ralph-loop-ledger.md").write_text(body)
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "commit.gpgsign=false",
                    "commit", "-q", "-m", msg], check=True)


def _run(repo: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--repo", str(repo),
         "--ledger", "docs/ralph-loop-ledger.md"],
        capture_output=True, text=True, check=False,
    )


def test_pure_append_passes(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, HEADER, "init")
    _commit(repo, HEADER + "| 1 | 2026-04-20 | 8a | F13 | abc123 | unit_tests | sha256:aa |\n", "iter 1")
    _commit(repo, HEADER
            + "| 1 | 2026-04-20 | 8a | F13 | abc123 | unit_tests | sha256:aa |\n"
            + "| 2 | 2026-04-20 | 8a | F14 | def456 | scenario_mock | sha256:bb |\n",
            "iter 2")
    res = _run(repo)
    assert res.returncode == 0, res.stdout + res.stderr


def test_row_deletion_rejected(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, HEADER, "init")
    _commit(repo, HEADER + "| 1 | 2026-04-20 | 8a | F13 | abc123 | unit_tests | sha256:aa |\n", "iter 1")
    _commit(repo, HEADER, "iter 2 — deleted row 1")
    res = _run(repo)
    assert res.returncode != 0
    assert "deletion" in res.stdout.lower() or "removed" in res.stdout.lower()


def test_bad_evidence_type_rejected(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _commit(repo, HEADER, "init")
    _commit(repo, HEADER + "| 1 | 2026-04-20 | 8a | F13 | abc123 | custom_shell | sha256:aa |\n", "iter 1")
    res = _run(repo)
    assert res.returncode != 0
    assert "evidence-type" in res.stdout.lower() or "enum" in res.stdout.lower()
