"""PRD 07 F08 / PRD 06 F08-F09 — esr cmd install."""

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


def test_install_feishu_app_session_writes_compiled_yaml(
    chdir_repo: None, tmp_path: Path
) -> None:
    """Happy path: install a pattern whose deps are installed."""
    runner = CliRunner()
    out_dir = tmp_path / ".compiled"
    result = runner.invoke(
        cli,
        [
            "cmd", "install",
            "patterns/feishu-app-session.py",
            "--compiled-dir", str(out_dir),
        ],
    )
    assert result.exit_code == 0, result.output

    out = out_dir / "feishu-app-session.yaml"
    assert out.exists()
    data = yaml.safe_load(out.read_text())
    assert data["name"] == "feishu-app-session"


def test_install_fails_with_actionable_message_on_missing_handler(
    chdir_repo: None, tmp_path: Path
) -> None:
    """Reference a non-existent handler → install fails listing it."""
    # Write a throwaway pattern that references a missing handler
    bogus = tmp_path / "bogus-pattern.py"
    bogus.write_text(
        "from esr import command, node\n\n"
        "@command('bogus-pattern')\n"
        "def build() -> None:\n"
        "    node(id='x', actor_type='t', handler='nonexistent_handler.on_msg')\n"
    )
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cmd", "install", str(bogus), "--compiled-dir", str(tmp_path)],
    )
    assert result.exit_code != 0
    assert "nonexistent_handler" in result.output
    assert "missing" in result.output.lower() or "not installed" in result.output.lower()


def test_install_feishu_thread_session_resolves_all_deps(
    chdir_repo: None, tmp_path: Path
) -> None:
    """The 3-node thread session references cc_tmux adapter + 3 handlers."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        [
            "cmd", "install",
            "patterns/feishu-thread-session.py",
            "--compiled-dir", str(tmp_path),
        ],
    )
    assert result.exit_code == 0, result.output
    assert (tmp_path / "feishu-thread-session.yaml").exists()
