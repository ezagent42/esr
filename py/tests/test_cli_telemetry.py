"""PRD 07 F17 — ``esr telemetry subscribe <pattern>`` streams events."""

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


def test_telemetry_subscribe_default_table_format(ctx_home: Path) -> None:
    """Default --format=table prints one line per yielded event."""
    events = [
        {"ts": "2026-04-20T00:00:01Z", "event": "actor.spawned",
         "actor_id": "thread:foo"},
        {"ts": "2026-04-20T00:00:02Z", "event": "handler.invoked",
         "actor_id": "thread:foo"},
    ]

    with patch("esr.cli.main._stream_telemetry", return_value=iter(events)) as stream:
        runner = CliRunner()
        result = runner.invoke(cli, ["telemetry", "subscribe", "esr.*"])

    assert result.exit_code == 0, result.output
    stream.assert_called_once()
    _, kwargs = stream.call_args
    assert kwargs.get("pattern") == "esr.*"
    assert kwargs.get("format") == "table"
    assert "actor.spawned" in result.output
    assert "handler.invoked" in result.output


def test_telemetry_subscribe_json_format_emits_one_per_line(ctx_home: Path) -> None:
    """--format=json emits one JSON object per line (ndjson)."""
    events = [
        {"ts": "2026-04-20T00:00:01Z", "event": "e1", "actor_id": "a:1"},
        {"ts": "2026-04-20T00:00:02Z", "event": "e2", "actor_id": "a:2"},
    ]

    with patch("esr.cli.main._stream_telemetry", return_value=iter(events)):
        runner = CliRunner()
        result = runner.invoke(
            cli, ["telemetry", "subscribe", "esr.*", "--format", "json"]
        )

    assert result.exit_code == 0, result.output
    lines = [line for line in result.output.splitlines() if line.strip()]
    assert len(lines) == 2
    for line in lines:
        assert line.startswith("{") and line.endswith("}")


def test_telemetry_subscribe_invalid_format_errors(ctx_home: Path) -> None:
    """--format=xml (unsupported) → click error + non-zero exit."""
    runner = CliRunner()
    result = runner.invoke(
        cli, ["telemetry", "subscribe", "esr.*", "--format", "xml"]
    )
    assert result.exit_code != 0


def test_telemetry_subscribe_pattern_required(ctx_home: Path) -> None:
    """Missing pattern → click usage error."""
    runner = CliRunner()
    result = runner.invoke(cli, ["telemetry", "subscribe"])
    assert result.exit_code != 0
