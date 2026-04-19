"""PRD 07 F18 — ``esr debug {replay, inject, pause, resume}``."""

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


def test_debug_replay_forwards_msg_id(ctx_home: Path) -> None:
    with patch("esr.cli.main._submit_debug") as submit:
        submit.return_value = {"replayed": "msg-123"}
        runner = CliRunner()
        result = runner.invoke(cli, ["debug", "replay", "msg-123"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("replay", {"msg_id": "msg-123"})
    assert "msg-123" in result.output


def test_debug_inject_parses_json_event(ctx_home: Path) -> None:
    with patch("esr.cli.main._submit_debug") as submit:
        submit.return_value = {"injected": True, "actor_id": "thread:foo"}
        runner = CliRunner()
        result = runner.invoke(
            cli,
            [
                "debug",
                "inject",
                "--to",
                "thread:foo",
                "--event",
                '{"event_type": "msg_received", "args": {"content": "hi"}}',
            ],
        )
    assert result.exit_code == 0, result.output
    submit.assert_called_once()
    call_args = submit.call_args.args[1]
    assert call_args["to"] == "thread:foo"
    assert call_args["event"]["event_type"] == "msg_received"


def test_debug_inject_invalid_json_errors(ctx_home: Path) -> None:
    """Malformed --event JSON → clean error, no submit call."""
    with patch("esr.cli.main._submit_debug") as submit:
        runner = CliRunner()
        result = runner.invoke(
            cli, ["debug", "inject", "--to", "thread:foo", "--event", "not json"]
        )
    assert result.exit_code != 0
    assert "json" in result.output.lower() or "invalid" in result.output.lower()
    submit.assert_not_called()


def test_debug_pause_forwards_actor_id(ctx_home: Path) -> None:
    with patch("esr.cli.main._submit_debug") as submit:
        submit.return_value = {"paused": "thread:foo"}
        runner = CliRunner()
        result = runner.invoke(cli, ["debug", "pause", "thread:foo"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("pause", {"actor_id": "thread:foo"})
    assert "paused" in result.output.lower()


def test_debug_resume_forwards_actor_id(ctx_home: Path) -> None:
    with patch("esr.cli.main._submit_debug") as submit:
        submit.return_value = {"resumed": "thread:foo", "drained": 3}
        runner = CliRunner()
        result = runner.invoke(cli, ["debug", "resume", "thread:foo"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("resume", {"actor_id": "thread:foo"})
    assert "resumed" in result.output.lower()
    assert "3" in result.output
