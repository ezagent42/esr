"""PRD 07 F04 — esr adapter add <instance> --type <module> ..."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def isolated_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("HOME", str(tmp_path))
    return tmp_path


def test_adapter_add_rejects_non_ascii_instance_name(isolated_home: Path) -> None:
    """PR-M: instance names that don't survive slugify (non-ASCII,
    slashes, leading dashes) are rejected at the CLI boundary with
    exit code 2 and a suggestion."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        [
            "adapter", "add",
            "ESR助手",  # Chinese — pre-PR-M this silently slugified to ESR______
            "--type", "feishu",
            "--app-id", "cli_x",
            "--app-secret", "y",
        ],
    )
    assert result.exit_code == 2, result.output
    assert "ESR助手" in result.output or "instance identifier" in result.output


def test_adapter_add_rejects_slash_in_instance_name(isolated_home: Path) -> None:
    """A slash would break Phoenix-topic split logic."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        [
            "adapter", "add",
            "feishu/main",
            "--type", "feishu",
            "--app-id", "cli_x",
            "--app-secret", "y",
        ],
    )
    assert result.exit_code == 2, result.output


def test_adapter_add_accepts_ascii_underscore_dash(isolated_home: Path) -> None:
    """Sanity: the convention the validator nudges toward still works.
    Avoid hitting esrd by using a non-feishu type so _refresh_adapters_via_runtime
    isn't called."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        [
            "adapter", "add",
            "esr_zhushou",
            "--type", "feishu_does_not_trigger_runtime_call",  # non-feishu skip
            "--app-id", "cli_x",
        ],
    )
    # Validation passes; yaml gets written regardless of whether the
    # adapter type is real (CLI doesn't gate on type). This test only
    # exercises that the validator accepts the recommended shape.
    assert result.exit_code == 0, result.output


def test_adapter_add_writes_instance_config(isolated_home: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(
        cli,
        [
            "adapter", "add",
            "feishu-shared",
            "--type", "feishu",
            "--app-id", "cli_abc",
            "--app-secret", "s1",
        ],
    )
    assert result.exit_code == 0, result.output

    cfg = isolated_home / ".esrd" / "default" / "adapters.yaml"
    assert cfg.exists()
    data = yaml.safe_load(cfg.read_text())
    entry = data["instances"]["feishu-shared"]
    assert entry["type"] == "feishu"
    assert entry["config"]["app_id"] == "cli_abc"
    assert entry["config"]["app_secret"] == "s1"


def test_adapter_add_duplicate_instance_errors(isolated_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(
        cli,
        ["adapter", "add", "dup-instance", "--type", "feishu", "--app-id", "a"],
    )
    result = runner.invoke(
        cli,
        ["adapter", "add", "dup-instance", "--type", "feishu", "--app-id", "b"],
    )
    assert result.exit_code != 0
    assert "already" in result.output.lower()


def test_adapter_add_preserves_existing_instances(isolated_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["adapter", "add", "a", "--type", "feishu", "--app-id", "a1"])
    runner.invoke(cli, ["adapter", "add", "b", "--type", "cc_tmux", "--start-cmd", "/x"])

    cfg = isolated_home / ".esrd" / "default" / "adapters.yaml"
    data = yaml.safe_load(cfg.read_text())
    assert set(data["instances"].keys()) == {"a", "b"}
