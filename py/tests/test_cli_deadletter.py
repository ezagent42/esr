"""PRD 07 F19 — ``esr deadletter {list, retry, flush}``."""

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


def test_deadletter_list_prints_entries(ctx_home: Path) -> None:
    """`esr deadletter list` prints one row per entry."""
    with patch("esr.cli.main._submit_deadletter") as submit:
        submit.return_value = [
            {
                "id": "dl-a1b2",
                "reason": "handler_retry_exhausted",
                "source": "thread:foo",
                "ts_unix_ms": 1_700_000_000_000,
            },
            {
                "id": "dl-c3d4",
                "reason": "unknown_target",
                "source": "feishu-app",
                "ts_unix_ms": 1_700_000_001_000,
            },
        ]

        runner = CliRunner()
        result = runner.invoke(cli, ["deadletter", "list"])

    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("list", None)
    assert "dl-a1b2" in result.output
    assert "dl-c3d4" in result.output
    assert "handler_retry_exhausted" in result.output


def test_deadletter_list_empty_prints_hint(ctx_home: Path) -> None:
    """Empty queue → helpful message, still exit 0."""
    with patch("esr.cli.main._submit_deadletter", return_value=[]):
        runner = CliRunner()
        result = runner.invoke(cli, ["deadletter", "list"])
    assert result.exit_code == 0, result.output
    assert "empty" in result.output.lower() or "no entries" in result.output.lower()


def test_deadletter_retry_invokes_with_id(ctx_home: Path) -> None:
    """`esr deadletter retry <id>` forwards the entry id to the helper."""
    with patch("esr.cli.main._submit_deadletter") as submit:
        submit.return_value = {"retried": "dl-a1b2"}
        runner = CliRunner()
        result = runner.invoke(cli, ["deadletter", "retry", "dl-a1b2"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("retry", "dl-a1b2")
    assert "dl-a1b2" in result.output


def test_deadletter_flush_empties_queue(ctx_home: Path) -> None:
    """`esr deadletter flush` clears the queue; output confirms the count."""
    with patch("esr.cli.main._submit_deadletter") as submit:
        submit.return_value = {"flushed": 17}
        runner = CliRunner()
        result = runner.invoke(cli, ["deadletter", "flush"])
    assert result.exit_code == 0, result.output
    submit.assert_called_once_with("flush", None)
    assert "17" in result.output
