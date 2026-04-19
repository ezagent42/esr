"""PRD 07 F16 — ``esr trace`` reads the Telemetry.Buffer ring."""

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


def test_trace_prints_recent_events(ctx_home: Path) -> None:
    """`esr trace` with no filters returns the most recent buffer entries."""
    with patch("esr.cli.main._submit_trace") as submit:
        submit.return_value = [
            {"ts": "2026-04-20T00:00:01Z", "event": "actor.spawned",
             "actor_id": "thread:foo"},
            {"ts": "2026-04-20T00:00:02Z", "event": "handler.invoked",
             "actor_id": "thread:foo", "event_id": "e-1"},
        ]
        runner = CliRunner()
        result = runner.invoke(cli, ["trace"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once()
    # All args passed as keyword/positional in the call
    assert "actor.spawned" in result.output
    assert "handler.invoked" in result.output


def test_trace_forwards_session_filter(ctx_home: Path) -> None:
    """--session forwards to the helper as a filter param."""
    with patch("esr.cli.main._submit_trace") as submit:
        submit.return_value = []
        runner = CliRunner()
        result = runner.invoke(cli, ["trace", "--session", "thread:foo"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once()
    # kwargs include session
    _, kwargs = submit.call_args
    assert kwargs.get("session") == "thread:foo"


def test_trace_forwards_last_window(ctx_home: Path) -> None:
    """--last 5m forwards as the window param."""
    with patch("esr.cli.main._submit_trace") as submit:
        submit.return_value = []
        runner = CliRunner()
        runner.invoke(cli, ["trace", "--last", "5m"])
    submit.assert_called_once()
    _, kwargs = submit.call_args
    assert kwargs.get("last") == "5m"


def test_trace_forwards_filter_pattern(ctx_home: Path) -> None:
    """--filter regex forwards to the helper."""
    with patch("esr.cli.main._submit_trace") as submit:
        submit.return_value = []
        runner = CliRunner()
        runner.invoke(cli, ["trace", "--filter", "handler\\..*"])
    submit.assert_called_once()
    _, kwargs = submit.call_args
    assert kwargs.get("filter") == "handler\\..*"


def test_trace_empty_prints_hint(ctx_home: Path) -> None:
    """Empty buffer / over-filtered → hint, still exit 0."""
    with patch("esr.cli.main._submit_trace", return_value=[]):
        runner = CliRunner()
        result = runner.invoke(cli, ["trace"])
    assert result.exit_code == 0, result.output
    assert "no events" in result.output.lower() or "empty" in result.output.lower()
