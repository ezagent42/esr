"""Verifies 'esr cmd run' prints `actor_id=<peer>` per peer so scenario
steps get the live-signature sig-B (actor_id=(thread|tmux|cc|feishu-app):...)
without shell-pipeline gymnastics."""
from __future__ import annotations

from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest
import yaml
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def compiled_dir(tmp_path: Path) -> Path:
    d = tmp_path / ".compiled"
    d.mkdir()
    (d / "feishu-thread-session.yaml").write_text(yaml.safe_dump({
        "name": "feishu-thread-session",
        "params": ["thread_id"],
        "nodes": [],
    }))
    return d


def test_cmd_run_emits_actor_id_lines_per_peer(
    compiled_dir: Path, monkeypatch: Any
) -> None:
    """After the summary line, one `actor_id=<pid>` line per peer."""
    monkeypatch.setenv("HOME", str(compiled_dir.parent))

    with patch("esr.cli.main._submit_cmd_run",
               return_value={
                   "name": "feishu-thread-session",
                   "params": {"thread_id": "alpha"},
                   "peer_ids": ["thread:alpha", "tmux:alpha", "cc:alpha"],
               }):
        result = CliRunner().invoke(cli, [
            "cmd", "run", "feishu-thread-session",
            "--param", "thread_id=alpha",
            "--compiled-dir", str(compiled_dir),
        ])

    assert result.exit_code == 0, result.output
    assert "instantiated 'feishu-thread-session'" in result.output
    assert "actor_id=thread:alpha" in result.output
    assert "actor_id=tmux:alpha" in result.output
    assert "actor_id=cc:alpha" in result.output
