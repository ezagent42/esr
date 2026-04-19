"""PRD 07 F12 — ``esr cmd stop <name> --param k=v`` deactivates a topology."""

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


def test_cmd_stop_submits_deactivate_with_params(ctx_home: Path) -> None:
    """Stop with params → submit helper called, handle echoed on stdout."""
    with patch("esr.cli.main._submit_cmd_stop") as submit:
        submit.return_value = {
            "name": "feishu-thread-session",
            "params": {"thread_id": "foo"},
            "stopped_peer_ids": ["cc:foo", "tmux:foo", "thread:foo"],
        }

        runner = CliRunner()
        result = runner.invoke(
            cli,
            ["cmd", "stop", "feishu-thread-session", "--param", "thread_id=foo"],
        )

    assert result.exit_code == 0, result.output
    submit.assert_called_once()
    assert submit.call_args.args[0] == "feishu-thread-session"
    assert submit.call_args.args[1] == {"thread_id": "foo"}
    assert "stopped" in result.output.lower()
    # Reverse-order stopping (dependents first) is reflected in the handle.
    assert "cc:foo" in result.output


def test_cmd_stop_timeout_prints_helpful_error(ctx_home: Path) -> None:
    """Runtime timeout → non-zero exit; hint references `esr status`."""
    with patch("esr.cli.main._submit_cmd_stop", side_effect=TimeoutError("runtime")):
        runner = CliRunner()
        result = runner.invoke(
            cli,
            ["cmd", "stop", "feishu-thread-session", "--param", "thread_id=foo"],
        )

    assert result.exit_code != 0
    assert "timeout" in result.output.lower() or "esr status" in result.output.lower()


def test_cmd_stop_invalid_param_binding_errors(ctx_home: Path) -> None:
    """`--param foo` without ``=`` → clean error."""
    runner = CliRunner()
    result = runner.invoke(
        cli, ["cmd", "stop", "feishu-thread-session", "--param", "thread_id"]
    )
    assert result.exit_code != 0
    assert "expected key=value" in result.output.lower()
