"""PRD 07 F13 — ``esr cmd restart <name> --param k=v`` reboots preserving state."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def compiled_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    home = tmp_path / "home"
    compiled = home / ".esrd" / "default" / "commands" / ".compiled"
    compiled.mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.delenv("ESR_CONTEXT", raising=False)
    CliRunner().invoke(cli, ["use", "localhost:4001"])
    return compiled


def _write_artifact(compiled_dir: Path, name: str) -> None:
    (compiled_dir / f"{name}.yaml").write_text(
        f"""\
name: {name}
params: [thread_id]
nodes:
  - id: "thread:{{{{thread_id}}}}"
    actor_type: feishu_thread_proxy
    handler: feishu_thread.on_msg
edges: []
"""
    )


def test_cmd_restart_calls_stop_then_run(compiled_dir: Path) -> None:
    """Restart invokes _submit_cmd_stop, then _submit_cmd_run (ordered)."""
    _write_artifact(compiled_dir, "feishu-thread-session")

    call_order: list[str] = []

    def stop_side_effect(name: str, params: dict[str, str]) -> dict[str, object]:
        call_order.append("stop")
        return {"name": name, "params": params, "stopped_peer_ids": ["thread:foo"]}

    def run_side_effect(artifact: dict[str, object], params: dict[str, str]) -> dict[str, object]:
        call_order.append("run")
        return {"name": artifact["name"], "params": params, "peer_ids": ["thread:foo"]}

    with (
        patch("esr.cli.main._submit_cmd_stop", side_effect=stop_side_effect) as stop,
        patch("esr.cli.main._submit_cmd_run", side_effect=run_side_effect) as run,
    ):
        runner = CliRunner()
        result = runner.invoke(
            cli,
            ["cmd", "restart", "feishu-thread-session", "--param", "thread_id=foo"],
        )

    assert result.exit_code == 0, result.output
    assert call_order == ["stop", "run"]
    stop.assert_called_once()
    run.assert_called_once()
    assert "restarted" in result.output.lower()
    assert "thread:foo" in result.output


def test_cmd_restart_survives_stop_not_running(compiled_dir: Path) -> None:
    """If stop reports the topology wasn't running (stopped_peer_ids=[]),
    restart still proceeds to run — restart is idempotent for missing
    prior state.
    """
    _write_artifact(compiled_dir, "feishu-thread-session")

    def stop_not_running(*_args: object, **_kwargs: object) -> dict[str, object]:
        return {"stopped_peer_ids": []}

    with (
        patch("esr.cli.main._submit_cmd_stop", side_effect=stop_not_running),
        patch("esr.cli.main._submit_cmd_run") as run,
    ):
        run.return_value = {"name": "feishu-thread-session", "peer_ids": ["thread:foo"]}

        runner = CliRunner()
        result = runner.invoke(
            cli,
            ["cmd", "restart", "feishu-thread-session", "--param", "thread_id=foo"],
        )

    assert result.exit_code == 0, result.output
    run.assert_called_once()


def test_cmd_restart_missing_artifact_errors(compiled_dir: Path) -> None:
    """Unknown name → fails cleanly, does NOT call stop/run."""
    with (
        patch("esr.cli.main._submit_cmd_stop") as stop,
        patch("esr.cli.main._submit_cmd_run") as run,
    ):
        runner = CliRunner()
        result = runner.invoke(
            cli,
            ["cmd", "restart", "nope", "--param", "thread_id=foo"],
        )

    assert result.exit_code != 0
    assert "not found" in result.output.lower()
    stop.assert_not_called()
    run.assert_not_called()
