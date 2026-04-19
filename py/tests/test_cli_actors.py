"""PRD 07 F15 — ``esr actors {list, tree, inspect <id>, logs <id>}``."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def ctx_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("ESR_CONTEXT", raising=False)
    CliRunner().invoke(cli, ["use", "localhost:4001"])
    return tmp_path


def test_actors_list_prints_each_actor(ctx_home: Path) -> None:
    """`esr actors list` enumerates every live actor_id + its actor_type."""
    with patch("esr.cli.main._submit_actors") as submit:
        submit.return_value = [
            {"actor_id": "thread:foo", "actor_type": "feishu_thread_proxy"},
            {"actor_id": "cc:foo", "actor_type": "cc_proxy"},
        ]
        runner = CliRunner()
        result = runner.invoke(cli, ["actors", "list"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("list", None)
    assert "thread:foo" in result.output
    assert "cc:foo" in result.output
    assert "feishu_thread_proxy" in result.output


def test_actors_tree_renders_depends_on_hierarchy(ctx_home: Path) -> None:
    """`esr actors tree` renders parent → children based on depends_on."""
    with patch("esr.cli.main._submit_actors") as submit:
        submit.return_value = {
            "roots": ["thread:foo"],
            "edges": [
                ("thread:foo", "tmux:foo"),
                ("tmux:foo", "cc:foo"),
            ],
        }
        runner = CliRunner()
        result = runner.invoke(cli, ["actors", "tree"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("tree", None)
    assert "thread:foo" in result.output
    assert "tmux:foo" in result.output
    assert "cc:foo" in result.output


def test_actors_inspect_dumps_state(ctx_home: Path) -> None:
    """`esr actors inspect <id>` prints the actor's state + metadata."""
    with patch("esr.cli.main._submit_actors") as submit:
        submit.return_value = {
            "actor_id": "thread:foo",
            "actor_type": "feishu_thread_proxy",
            "state": {"counter": 3, "_schema_version": 1},
            "paused": False,
        }
        runner = CliRunner()
        result = runner.invoke(cli, ["actors", "inspect", "thread:foo"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("inspect", "thread:foo")
    assert "thread:foo" in result.output
    assert "counter" in result.output


def test_actors_logs_emits_recent_entries(ctx_home: Path) -> None:
    """`esr actors logs <id>` prints recent telemetry lines for the actor."""
    with patch("esr.cli.main._submit_actors") as submit:
        submit.return_value = [
            {"ts": "2026-04-20T00:00:01Z", "event": "inbound_event", "msg": "m1"},
            {"ts": "2026-04-20T00:00:02Z", "event": "handler_invoked", "msg": "m2"},
        ]
        runner = CliRunner()
        result = runner.invoke(cli, ["actors", "logs", "thread:foo"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("logs", "thread:foo")
    assert "inbound_event" in result.output
    assert "handler_invoked" in result.output
