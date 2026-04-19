"""PRD 06 F10 — esr cmd show <name>."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from esr.cli.main import cli

_REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def chdir_repo(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(_REPO_ROOT)


def test_show_prints_topology_for_installed_pattern(
    chdir_repo: None, tmp_path: Path
) -> None:
    """After install, `esr cmd show` prints the nodes + edges."""
    runner = CliRunner()
    # Install first so a compiled YAML exists in tmp_path
    runner.invoke(
        cli,
        ["cmd", "install", "patterns/feishu-thread-session.py",
         "--compiled-dir", str(tmp_path)],
    )

    result = runner.invoke(
        cli,
        ["cmd", "show", "feishu-thread-session", "--compiled-dir", str(tmp_path)],
    )
    assert result.exit_code == 0, result.output

    output = result.output
    assert "feishu-thread-session" in output
    # Every node id appears
    for node_id in ("thread:{{thread_id}}", "tmux:{{thread_id}}", "cc:{{thread_id}}"):
        assert node_id in output
    # init_directive block for tmux node is surfaced
    assert "init_directive" in output
    assert "new_session" in output


def test_show_unknown_pattern_errors(chdir_repo: None, tmp_path: Path) -> None:
    runner = CliRunner()
    # chdir to a fresh dir so the default compiled-dir is missing
    import os

    os.chdir(tmp_path)
    try:
        result = runner.invoke(cli, ["cmd", "show", "does-not-exist"])
        # Two failure modes: --compiled-dir default doesn't exist (exit 2)
        # or the YAML file doesn't exist (exit 1). Either is acceptable.
        assert result.exit_code != 0
    finally:
        os.chdir(_REPO_ROOT)
