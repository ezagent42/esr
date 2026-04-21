"""PRD 07 F03 / F06 — esr adapter/handler install (offline validation)."""

from __future__ import annotations

from pathlib import Path

from click.testing import CliRunner

from esr.cli.main import cli

_REPO_ROOT = Path(__file__).resolve().parents[2]


def test_adapter_install_validates_local_adapter(tmp_path: Path) -> None:
    """`esr adapter install adapters/feishu` reads manifest + runs I/O-permission scan."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["adapter", "install", str(_REPO_ROOT / "adapters" / "feishu")],
    )
    assert result.exit_code == 0, result.output
    assert "feishu" in result.output


def test_adapter_install_reports_manifest_missing(tmp_path: Path) -> None:
    """Target without esr.toml → clear error."""
    bogus = tmp_path / "bogus-adapter"
    bogus.mkdir()
    (bogus / "src").mkdir()

    runner = CliRunner()
    result = runner.invoke(cli, ["adapter", "install", str(bogus)])
    assert result.exit_code != 0
    assert "esr.toml" in result.output


def test_adapter_install_reports_io_permission_violation(tmp_path: Path) -> None:
    """An adapter whose imports exceed allowed_io fails install."""
    # Build a synthetic adapter that declares allowed_io={"esr": "*"} only
    # but imports `requests`. I/O-permission scan must catch it.
    root = tmp_path / "bad-adapter"
    (root / "src" / "esr_bad_adapter").mkdir(parents=True)
    (root / "src" / "esr_bad_adapter" / "__init__.py").write_text("")
    (root / "src" / "esr_bad_adapter" / "adapter.py").write_text(
        "import requests  # disallowed\n"
    )
    (root / "esr.toml").write_text(
        'name = "bad_adapter"\n'
        'version = "0.1.0"\n'
        'module = "esr_bad_adapter.adapter"\n'
        'entry = "BadAdapter"\n'
        "[allowed_io]\n"
    )

    runner = CliRunner()
    result = runner.invoke(cli, ["adapter", "install", str(root)])
    assert result.exit_code != 0
    assert "requests" in result.output or "allowed_io" in result.output


def test_handler_install_validates_local_handler(tmp_path: Path) -> None:
    """`esr handler install handlers/feishu_app` passes import allow-list."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["handler", "install", str(_REPO_ROOT / "handlers" / "feishu_app")],
    )
    assert result.exit_code == 0, result.output
    assert "feishu_app" in result.output


def test_handler_install_flags_import_violations(tmp_path: Path) -> None:
    """A handler with a disallowed import fails install."""
    root = tmp_path / "bad-handler"
    (root / "src" / "esr_handler_bad").mkdir(parents=True)
    (root / "src" / "esr_handler_bad" / "__init__.py").write_text("")
    (root / "src" / "esr_handler_bad" / "on_msg.py").write_text(
        "import requests\n"
    )
    (root / "esr.toml").write_text(
        'name = "bad"\nversion = "0.1.0"\n'
        'module = "esr_handler_bad.on_msg"\n'
        'entry = "on_msg"\n'
        'actor_type = "bad_actor"\n'
        "allowed_imports = []\n"
    )
    runner = CliRunner()
    result = runner.invoke(cli, ["handler", "install", str(root)])
    assert result.exit_code != 0
    assert "requests" in result.output
