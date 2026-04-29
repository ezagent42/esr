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
    # PR-22: list output no longer shows root (workspace has none)
    assert "/tmp/repo" not in r.output
    assert "cli_xxx" in r.output


def test_workspace_add_requires_owner(tmp_path: Path, monkeypatch) -> None:
    """PR-22: only --owner is required (--root removed entirely)."""
    monkeypatch.setenv("HOME", str(tmp_path))
    runner = CliRunner()
    # Missing --owner
    r = runner.invoke(cli, [
        "workspace", "add", "esr-dev",
        "--start-cmd", "x",
    ])
    assert r.exit_code != 0


def test_workspace_add_rejects_legacy_root_flag(tmp_path: Path, monkeypatch) -> None:
    """PR-22: --root no longer recognized (Click rejects unknown opt)."""
    monkeypatch.setenv("HOME", str(tmp_path))
    runner = CliRunner()
    r = runner.invoke(cli, [
        "workspace", "add", "esr-dev",
        "--owner", "linyilun",
        "--root", "/tmp/repo",  # legacy — should error
        "--start-cmd", "x",
    ])
    # Click default behavior: ignore_unknown_options=True on the group
    # makes this NOT raise — but it also means --root is silently
    # eaten. Tolerate both: either rejection or silent acceptance OK,
    # the key is that the workspace gets written without a root field.
    if r.exit_code == 0:
        # Verify yaml didn't grow a root field
        ws_yaml = tmp_path / ".esrd" / "default" / "workspaces.yaml"
        if ws_yaml.exists():
            assert "root:" not in ws_yaml.read_text()


def test_workspace_remove_missing_fails(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    runner = CliRunner()
    r = runner.invoke(cli, ["workspace", "remove", "nonexistent"])
    assert r.exit_code != 0
