"""PRD 07 F01 — ``esr use`` sets + prints the runtime endpoint."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Redirect HOME so the CLI writes into a temp dir."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("ESR_CONTEXT", raising=False)
    return tmp_path


def test_use_writes_context_file(home: Path) -> None:
    """`esr use localhost:4001` persists the endpoint to ~/.esr/context."""
    runner = CliRunner()
    result = runner.invoke(cli, ["use", "localhost:4001"])
    assert result.exit_code == 0, result.output

    ctx = home / ".esr" / "context"
    assert ctx.exists()
    data = yaml.safe_load(ctx.read_text())
    assert data["endpoint"] == "ws://localhost:4001/adapter_hub/socket"


def test_use_without_args_prints_current(home: Path) -> None:
    """`esr use` (no args) prints the current endpoint."""
    runner = CliRunner()
    runner.invoke(cli, ["use", "localhost:4001"])

    result = runner.invoke(cli, ["use"])
    assert result.exit_code == 0
    assert "localhost:4001" in result.output


def test_use_without_args_no_context_set(home: Path) -> None:
    """`esr use` with no context set prints a clear error + suggestion."""
    runner = CliRunner()
    result = runner.invoke(cli, ["use"])
    assert result.exit_code != 0
    assert "no context set" in result.output.lower() or "no context" in result.output.lower()


def test_env_var_overrides_context_file(home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """ESR_CONTEXT env var takes priority over ~/.esr/context."""
    runner = CliRunner()
    runner.invoke(cli, ["use", "localhost:4001"])

    monkeypatch.setenv("ESR_CONTEXT", "prod.internal:4000")
    result = runner.invoke(cli, ["use"])
    assert result.exit_code == 0
    assert "prod.internal:4000" in result.output
