"""PRD 07 F02 — ``esr status`` prints runtime reachability."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("ESR_CONTEXT", raising=False)
    return tmp_path


def _set_context(home: Path, host_port: str = "localhost:4001") -> None:
    runner = CliRunner()
    runner.invoke(cli, ["use", host_port])


def test_status_reports_ok_when_runtime_reachable(home: Path) -> None:
    """When the ChannelClient connects cleanly, status prints OK +
    endpoint URL."""
    _set_context(home)

    with (
        patch("esr.cli.main.ChannelClient") as mock_client_cls,
    ):
        instance = mock_client_cls.return_value
        instance.connect = AsyncMock()
        instance.close = AsyncMock()

        runner = CliRunner()
        result = runner.invoke(cli, ["status"])

    assert result.exit_code == 0, result.output
    assert "OK" in result.output
    assert "localhost:4001" in result.output


def test_status_reports_unreachable_on_connect_error(home: Path) -> None:
    """If the WebSocket connect raises, status reports UNREACHABLE and
    exits non-zero so the command fails cleanly for scripts."""
    _set_context(home)

    with patch("esr.cli.main.ChannelClient") as mock_client_cls:
        instance = mock_client_cls.return_value
        instance.connect = AsyncMock(side_effect=OSError("connection refused"))
        instance.close = AsyncMock()

        runner = CliRunner()
        result = runner.invoke(cli, ["status"])

    assert result.exit_code != 0
    assert "UNREACHABLE" in result.output
    assert "localhost:4001" in result.output


def test_status_errors_cleanly_with_no_context(home: Path) -> None:
    """Running `esr status` without `esr use` set prints the no-context
    hint and exits non-zero."""
    runner = CliRunner()
    result = runner.invoke(cli, ["status"])
    assert result.exit_code != 0
    assert "no context" in result.output.lower()
