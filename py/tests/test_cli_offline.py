"""PRD 07 F23 — CLI read-only ops don't require a runtime."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from esr.cli.main import cli

_REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def chdir_repo(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Also redirect HOME so ``esr use`` context doesn't exist."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("ESR_CONTEXT", raising=False)
    monkeypatch.chdir(_REPO_ROOT)


READ_ONLY_OPS = (
    ("adapter", "list"),
    ("handler", "list"),
    ("cmd", "list"),
)


@pytest.mark.parametrize("args", READ_ONLY_OPS)
def test_read_only_ops_succeed_without_context(
    chdir_repo: None, args: tuple[str, ...]
) -> None:
    """PRD 07 F23: list-style ops work with no ~/.esr/context set."""
    runner = CliRunner()
    result = runner.invoke(cli, list(args))
    assert result.exit_code == 0, f"{args} failed: {result.output}"


def test_cmd_compile_is_offline(chdir_repo: None, tmp_path: Path) -> None:
    out = tmp_path / "out.yaml"
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cmd", "compile", "feishu-app-session", "--output", str(out)],
    )
    assert result.exit_code == 0, result.output
    assert out.exists()
