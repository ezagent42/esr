"""PRD 07 F10 — esr cmd compile <name>."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from click.testing import CliRunner

from esr.cli.main import cli

_REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def chdir_repo(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(_REPO_ROOT)


def test_compile_writes_compiled_yaml(chdir_repo: None, tmp_path: Path) -> None:
    """`esr cmd compile feishu-app-session` writes patterns/.compiled/*.yaml."""
    runner = CliRunner()
    # Compile to a fresh path via --output flag so the test doesn't touch the
    # repo's .compiled/ dir.
    out = tmp_path / "feishu-app-session.yaml"
    result = runner.invoke(
        cli,
        ["cmd", "compile", "feishu-app-session", "--output", str(out)],
    )
    assert result.exit_code == 0, result.output
    assert out.exists()

    data = yaml.safe_load(out.read_text())
    assert data["name"] == "feishu-app-session"
    assert data["schema_version"] == 1


def test_compile_unknown_pattern_fails(chdir_repo: None, tmp_path: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cmd", "compile", "does-not-exist", "--output", str(tmp_path / "x.yaml")],
    )
    assert result.exit_code != 0
    assert "not found" in result.output.lower() or "no such" in result.output.lower()
