"""PRD 07 F05 / F07 / F09 — offline list commands."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from esr.cli.main import cli

_REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def chdir_repo(monkeypatch: pytest.MonkeyPatch) -> None:
    """Most list commands scan relative paths (adapters/, handlers/,
    patterns/). Run from the repo root so those dirs resolve."""
    monkeypatch.chdir(_REPO_ROOT)


def test_adapter_list_shows_installed_types(chdir_repo: None) -> None:
    """`esr adapter list` lists adapters/<name>/ manifests."""
    runner = CliRunner()
    result = runner.invoke(cli, ["adapter", "list"])
    assert result.exit_code == 0, result.output
    assert "feishu" in result.output
    assert "cc_tmux" in result.output


def test_handler_list_shows_installed_handlers(chdir_repo: None) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["handler", "list"])
    assert result.exit_code == 0, result.output
    for name in ("feishu_app", "feishu_thread", "tmux_proxy", "cc_session"):
        assert name in result.output


def test_cmd_list_shows_pattern_files(chdir_repo: None) -> None:
    """`esr cmd list` shows pattern .py files in patterns/."""
    runner = CliRunner()
    result = runner.invoke(cli, ["cmd", "list"])
    assert result.exit_code == 0, result.output
    assert "feishu-app-session" in result.output
    assert "feishu-thread-session" in result.output
