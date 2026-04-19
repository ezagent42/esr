"""PRD 07 F11 — ``esr cmd run <name> --param k=v`` triggers instantiation."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def compiled_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Stub ~/.esrd/default/commands/.compiled with a fake artifact."""
    home = tmp_path / "home"
    compiled = home / ".esrd" / "default" / "commands" / ".compiled"
    compiled.mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.delenv("ESR_CONTEXT", raising=False)
    # Set context so the command has an endpoint to talk to.
    CliRunner().invoke(cli, ["use", "localhost:4001"])
    return compiled


def _write_artifact(compiled_dir: Path, name: str) -> Path:
    path = compiled_dir / f"{name}.yaml"
    path.write_text(
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
    return path


def test_cmd_run_missing_compiled_artifact(compiled_dir: Path) -> None:
    """Unknown name → `not found` error + non-zero exit."""
    runner = CliRunner()
    result = runner.invoke(cli, ["cmd", "run", "nope"])
    assert result.exit_code != 0
    assert "not found" in result.output.lower()


def test_cmd_run_submits_artifact_with_params(compiled_dir: Path) -> None:
    """Compiled artifact found + mocked submit → prints the handle on stdout."""
    _write_artifact(compiled_dir, "feishu-thread-session")

    with patch("esr.cli.main._submit_cmd_run") as submit:
        submit.return_value = {
            "name": "feishu-thread-session",
            "params": {"thread_id": "foo"},
            "peer_ids": ["thread:foo"],
        }

        runner = CliRunner()
        result = runner.invoke(
            cli,
            ["cmd", "run", "feishu-thread-session", "--param", "thread_id=foo"],
        )

    assert result.exit_code == 0, result.output
    submit.assert_called_once()
    # The submitted artifact carries the declared name
    artifact_arg = submit.call_args.args[0]
    assert artifact_arg["name"] == "feishu-thread-session"
    # And the params pass through
    params_arg = submit.call_args.args[1]
    assert params_arg == {"thread_id": "foo"}
    # Output reports the handle
    assert "feishu-thread-session" in result.output
    assert "thread:foo" in result.output


def test_cmd_run_timeout_prints_helpful_error(compiled_dir: Path) -> None:
    """Runtime timeout → non-zero exit, hint mentions `esr status`."""
    _write_artifact(compiled_dir, "feishu-thread-session")

    with patch("esr.cli.main._submit_cmd_run", side_effect=TimeoutError("runtime")):
        runner = CliRunner()
        result = runner.invoke(
            cli,
            ["cmd", "run", "feishu-thread-session", "--param", "thread_id=foo"],
        )

    assert result.exit_code != 0
    assert "timeout" in result.output.lower() or "esr status" in result.output.lower()


def test_cmd_run_missing_param_errors(compiled_dir: Path) -> None:
    """Artifact declares params=[thread_id] but caller omits it → error."""
    _write_artifact(compiled_dir, "feishu-thread-session")

    runner = CliRunner()
    result = runner.invoke(cli, ["cmd", "run", "feishu-thread-session"])

    assert result.exit_code != 0
    assert "thread_id" in result.output.lower() or "missing" in result.output.lower()
