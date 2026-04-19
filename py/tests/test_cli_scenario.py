"""PRD 07 F20 — ``esr scenario run <name>`` executes a scenario YAML."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def scenarios_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Run each test in a tmp cwd with an empty scenarios/ subdir."""
    scenarios = tmp_path / "scenarios"
    scenarios.mkdir()
    monkeypatch.chdir(tmp_path)
    return scenarios


def test_scenario_run_missing_scenario_errors(scenarios_dir: Path) -> None:
    """Unknown scenario name produces a clean error + non-zero exit."""
    runner = CliRunner()
    result = runner.invoke(cli, ["scenario", "run", "nope"])
    assert result.exit_code != 0
    assert "not found" in result.output.lower() or "no such scenario" in result.output.lower()


def test_scenario_run_empty_scenario_runs_successfully(scenarios_dir: Path) -> None:
    """A well-formed scenario with zero steps still runs + reports PASSED."""
    (scenarios_dir / "trivial.yaml").write_text(
        """\
name: trivial
description: No-op scenario
setup: []
steps: []
acceptance: []
"""
    )

    runner = CliRunner()
    result = runner.invoke(cli, ["scenario", "run", "trivial"])
    assert result.exit_code == 0, result.output
    assert "PASSED" in result.output
    assert "trivial" in result.output


def test_scenario_run_counts_steps(scenarios_dir: Path) -> None:
    """Reports the step count in the summary output."""
    (scenarios_dir / "three-steps.yaml").write_text(
        """\
name: three-steps
description: test
setup: []
steps:
  - {kind: shell, cmd: "true"}
  - {kind: shell, cmd: "true"}
  - {kind: shell, cmd: "true"}
acceptance: []
"""
    )

    runner = CliRunner()
    result = runner.invoke(cli, ["scenario", "run", "three-steps"])
    assert result.exit_code == 0, result.output
    assert "3 step" in result.output or "3 steps" in result.output


def test_scenario_run_malformed_yaml_errors(scenarios_dir: Path) -> None:
    """Malformed YAML (missing required keys) surfaces as a clean error."""
    (scenarios_dir / "bad.yaml").write_text("this: is: not valid yaml: [")

    runner = CliRunner()
    result = runner.invoke(cli, ["scenario", "run", "bad"])
    assert result.exit_code != 0
    assert "invalid" in result.output.lower() or "parse" in result.output.lower()
