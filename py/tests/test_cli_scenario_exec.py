"""Tests for 'esr scenario run' real command execution (Phase 8e).

The pre-8e scenario_run just counted steps. v2.1 requires each step to
execute its `command:` and match `expect_stdout_match:` regex against
stdout. These tests nail down the execution contract.
"""
from __future__ import annotations

from pathlib import Path

from click.testing import CliRunner

from esr.cli.main import scenario_run


def _write(tmp: Path, body: str) -> None:
    (tmp / "scenarios").mkdir(parents=True, exist_ok=True)
    (tmp / "scenarios" / "e2e.yaml").write_text(body)


def test_scenario_run_executes_command_and_matches_regex(tmp_path: Path) -> None:
    _write(tmp_path, """\
name: e2e
description: pass-test
mode: mock
setup: []
steps:
  - id: hello
    description: print a signature-bearing line
    command: printf 'actor_id=thread:alpha-42 ready\\n'
    expect_stdout_match: 'actor_id=thread:alpha-42'
    expect_exit: 0
    timeout_sec: 5
teardown: []
""")
    runner = CliRunner()
    with runner.isolated_filesystem(temp_dir=str(tmp_path)) as cwd:
        (Path(cwd) / "scenarios").mkdir()
        (Path(cwd) / "scenarios" / "e2e.yaml").write_text(
            (tmp_path / "scenarios" / "e2e.yaml").read_text()
        )
        result = runner.invoke(scenario_run, ["e2e"])

    assert result.exit_code == 0, result.output
    assert "1/1 steps PASSED" in result.output


def test_scenario_run_fails_when_stdout_does_not_match(tmp_path: Path) -> None:
    _write(tmp_path, """\
name: e2e
description: fail-test
mode: mock
setup: []
steps:
  - id: weak
    description: prints nothing interesting
    command: printf 'nothing matches\\n'
    expect_stdout_match: 'actor_id=thread:[a-z]+'
    expect_exit: 0
    timeout_sec: 5
teardown: []
""")
    runner = CliRunner()
    with runner.isolated_filesystem(temp_dir=str(tmp_path)) as cwd:
        (Path(cwd) / "scenarios").mkdir()
        (Path(cwd) / "scenarios" / "e2e.yaml").write_text(
            (tmp_path / "scenarios" / "e2e.yaml").read_text()
        )
        result = runner.invoke(scenario_run, ["e2e"])

    assert result.exit_code != 0
    assert "0/1 steps PASSED" in result.output or "FAILED" in result.output
    assert "stdout did not match" in result.output.lower() or \
           "expect_stdout_match" in result.output.lower()


def test_scenario_run_fails_on_wrong_exit_code(tmp_path: Path) -> None:
    _write(tmp_path, """\
name: e2e
description: exit-mismatch
mode: mock
setup: []
steps:
  - id: nonzero
    description: exits 3
    command: sh -c 'printf "actor_id=thread:x\\n"; exit 3'
    expect_stdout_match: 'actor_id=thread:x'
    expect_exit: 0
    timeout_sec: 5
teardown: []
""")
    runner = CliRunner()
    with runner.isolated_filesystem(temp_dir=str(tmp_path)) as cwd:
        (Path(cwd) / "scenarios").mkdir()
        (Path(cwd) / "scenarios" / "e2e.yaml").write_text(
            (tmp_path / "scenarios" / "e2e.yaml").read_text()
        )
        result = runner.invoke(scenario_run, ["e2e"])

    assert result.exit_code != 0
    assert "exit" in result.output.lower()
