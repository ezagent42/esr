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
