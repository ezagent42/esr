from pathlib import Path

from click.testing import CliRunner

from esr.cli.main import cli


def test_workspace_add_then_list(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("ESR_CONTEXT", raising=False)

    runner = CliRunner()
    r = runner.invoke(cli, [
        "workspace", "add", "esr-dev",
        "--owner", "linyilun",
        "--root", "/tmp/repo",
        "--start-cmd", "scripts/esr-cc.sh",
        "--role", "dev",
        "--chat", "oc_aaa:cli_xxx:dm",
    ])
    assert r.exit_code == 0, r.output
    assert "added esr-dev" in r.output

    r = runner.invoke(cli, ["workspace", "list"])
    assert r.exit_code == 0, r.output
    assert "esr-dev" in r.output
    assert "linyilun" in r.output
    assert "/tmp/repo" in r.output
    assert "cli_xxx" in r.output


def test_workspace_add_requires_owner_and_root(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    runner = CliRunner()
    # Missing --owner
    r = runner.invoke(cli, [
        "workspace", "add", "esr-dev",
        "--root", "/tmp/repo",
        "--start-cmd", "x",
    ])
    assert r.exit_code != 0
    # Missing --root
    r = runner.invoke(cli, [
        "workspace", "add", "esr-dev",
        "--owner", "linyilun",
        "--start-cmd", "x",
    ])
    assert r.exit_code != 0


def test_workspace_remove_missing_fails(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    runner = CliRunner()
    r = runner.invoke(cli, ["workspace", "remove", "nonexistent"])
    assert r.exit_code != 0
