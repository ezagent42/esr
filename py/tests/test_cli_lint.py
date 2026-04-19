"""PRD 07 F14 — esr-lint / `esr lint` standalone purity linter."""

from __future__ import annotations

from pathlib import Path

from click.testing import CliRunner

from esr.cli.main import cli


def test_lint_clean_directory_exits_zero(tmp_path: Path) -> None:
    """A directory with purity-clean handler code exits 0."""
    (tmp_path / "ok.py").write_text(
        "from pydantic import BaseModel\n"
        "class State(BaseModel):\n"
        "    model_config = {'frozen': True}\n"
    )
    runner = CliRunner()
    result = runner.invoke(cli, ["lint", str(tmp_path)])
    assert result.exit_code == 0, result.output


def test_lint_disallowed_import_fails(tmp_path: Path) -> None:
    """A directory with a forbidden import exits nonzero and names the module."""
    (tmp_path / "bad.py").write_text("import requests\n")
    runner = CliRunner()
    result = runner.invoke(cli, ["lint", str(tmp_path)])
    assert result.exit_code != 0
    assert "requests" in result.output


def test_lint_missing_path_errors(tmp_path: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["lint", str(tmp_path / "does-not-exist")])
    assert result.exit_code != 0


def test_lint_scans_multiple_files(tmp_path: Path) -> None:
    """Lint walks subdirectories recursively and reports each violation."""
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "a.py").write_text("import requests\n")
    (sub / "b.py").write_text("import aiohttp\n")
    runner = CliRunner()
    result = runner.invoke(cli, ["lint", str(tmp_path)])
    assert result.exit_code != 0
    # Both violations surface
    assert "requests" in result.output
    assert "aiohttp" in result.output
