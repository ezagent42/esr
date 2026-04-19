"""PRD 07 F21 — ``esr drain [--timeout <duration>]`` graceful shutdown."""

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


def test_drain_reports_per_topology_status(ctx_home: Path) -> None:
    """`esr drain` reports success count + any timeouts."""
    with patch("esr.cli.main._submit_drain") as submit:
        submit.return_value = {
            "drained": [
                {"name": "feishu-thread-session", "params": {"thread_id": "a"}},
                {"name": "feishu-thread-session", "params": {"thread_id": "b"}},
            ],
            "timeouts": [],
            "duration_ms": 850,
        }
        runner = CliRunner()
        result = runner.invoke(cli, ["drain"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once()
    _, kwargs = submit.call_args
    assert kwargs.get("timeout") is None
    assert "2" in result.output
    assert "850" in result.output


def test_drain_forwards_timeout_flag(ctx_home: Path) -> None:
    """`--timeout 30s` forwards to the helper."""
    with patch("esr.cli.main._submit_drain") as submit:
        submit.return_value = {"drained": [], "timeouts": [], "duration_ms": 12}
        runner = CliRunner()
        runner.invoke(cli, ["drain", "--timeout", "30s"])
    submit.assert_called_once()
    _, kwargs = submit.call_args
    assert kwargs.get("timeout") == "30s"


def test_drain_reports_timeouts_with_nonzero_exit(ctx_home: Path) -> None:
    """Any topology that didn't drain within timeout → exit != 0."""
    with patch("esr.cli.main._submit_drain") as submit:
        submit.return_value = {
            "drained": [{"name": "ok", "params": {}}],
            "timeouts": [{"name": "stuck", "params": {"x": "1"}}],
            "duration_ms": 30000,
        }
        runner = CliRunner()
        result = runner.invoke(cli, ["drain", "--timeout", "30s"])
    assert result.exit_code != 0
    assert "timeout" in result.output.lower()
    assert "stuck" in result.output


def test_drain_empty_runtime_exits_clean(ctx_home: Path) -> None:
    """No live topologies → exit 0 with a clean message."""
    with patch("esr.cli.main._submit_drain") as submit:
        submit.return_value = {"drained": [], "timeouts": [], "duration_ms": 5}
        runner = CliRunner()
        result = runner.invoke(cli, ["drain"])
    assert result.exit_code == 0, result.output
    assert "0 topolog" in result.output.lower() or "nothing to drain" in result.output.lower()
