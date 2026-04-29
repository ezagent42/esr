"""CLI tests for `esr daemon {start,stop,restart,status}` (PR-21n).

These tests stub the ``launchctl`` subprocess calls — we're not
verifying that launchd actually starts esrd, just that the CLI
produces the right argv + reports the right exit codes given the
canonical launchctl outputs.
"""
from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from click.testing import CliRunner

from esr.cli.main import cli


def _completed(returncode: int, stdout: str = "", stderr: str = "") -> MagicMock:
    m = MagicMock(spec=subprocess.CompletedProcess)
    m.returncode = returncode
    m.stdout = stdout
    m.stderr = stderr
    return m


@pytest.fixture
def fake_running_listing() -> str:
    return """{
\t"PID" = 12345;
\t"LastExitStatus" = 0;
\t"Label" = "com.ezagent.esrd";
}
"""


@pytest.fixture
def fake_loaded_but_stopped_listing() -> str:
    return """{
\t"LastExitStatus" = 0;
\t"Label" = "com.ezagent.esrd";
}
"""


def test_daemon_status_running(
    fake_running_listing: str,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path / ".esrd"))

    with patch("esr.cli.daemon._run") as run_mock:
        run_mock.return_value = _completed(0, stdout=fake_running_listing)

        runner = CliRunner()
        result = runner.invoke(cli, ["daemon", "status"])

        assert result.exit_code == 0
        assert "RUNNING" in result.output
        assert "pid: 12345" in result.output
        run_mock.assert_called_once()
        assert run_mock.call_args[0][0] == ["launchctl", "list", "com.ezagent.esrd"]


def test_daemon_status_not_loaded(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path / ".esrd"))

    with patch("esr.cli.daemon._run") as run_mock:
        run_mock.return_value = _completed(113)  # launchctl: not loaded

        runner = CliRunner()
        result = runner.invoke(cli, ["daemon", "status"])

        assert result.exit_code == 1
        assert "not loaded" in result.output


def test_daemon_status_dev_env_uses_dev_label(
    fake_running_listing: str,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path / ".esrd-dev"))

    with patch("esr.cli.daemon._run") as run_mock:
        run_mock.return_value = _completed(
            0, stdout=fake_running_listing.replace("esrd", "esrd-dev")
        )

        runner = CliRunner()
        result = runner.invoke(cli, ["daemon", "status"])

        assert result.exit_code == 0
        assert "com.ezagent.esrd-dev" in result.output


def test_daemon_restart_calls_kickstart_k(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path / ".esrd"))

    with patch("esr.cli.daemon._run") as run_mock:
        run_mock.return_value = _completed(0)

        runner = CliRunner()
        result = runner.invoke(cli, ["daemon", "restart"])

        assert result.exit_code == 0
        assert "restarted" in result.output
        argv = run_mock.call_args[0][0]
        assert argv[0] == "launchctl"
        assert argv[1] == "kickstart"
        assert "-k" in argv


def test_daemon_stop_handles_already_stopped(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path / ".esrd"))

    with patch("esr.cli.daemon._run") as run_mock:
        run_mock.return_value = _completed(
            113, stderr="No such service: com.ezagent.esrd"
        )

        runner = CliRunner()
        result = runner.invoke(cli, ["daemon", "stop"])

        assert result.exit_code == 0
        assert "was not loaded" in result.output


def test_daemon_start_already_loaded_kickstarts(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path / ".esrd"))

    with patch("esr.cli.daemon._run") as run_mock:
        run_mock.side_effect = [
            _completed(0, stdout='"PID" = 99;'),  # listing OK → already loaded
            _completed(0),  # kickstart succeeds
        ]

        runner = CliRunner()
        result = runner.invoke(cli, ["daemon", "start"])

        assert result.exit_code == 0
        assert "started" in result.output
        # Second call was kickstart
        assert run_mock.call_args_list[1][0][0][1] == "kickstart"


def test_daemon_label_override_via_env(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path / "custom-home"))
    monkeypatch.setenv("ESR_LAUNCHD_LABEL", "com.example.custom-esrd")

    with patch("esr.cli.daemon._run") as run_mock:
        run_mock.return_value = _completed(113)

        runner = CliRunner()
        result = runner.invoke(cli, ["daemon", "status"])

        assert result.exit_code == 1
        argv = run_mock.call_args[0][0]
        assert argv == ["launchctl", "list", "com.example.custom-esrd"]
