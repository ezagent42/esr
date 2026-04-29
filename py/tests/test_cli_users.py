"""CLI tests for `esr user add / list / remove / bind-feishu / unbind-feishu` (PR-21a).

Exercises the commands without a running esrd by pointing `ESRD_HOME`
at `tmp_path` and reading/writing `users.yaml` directly. The Elixir
runtime's `Esr.Users.Watcher` would normally reload on FSEvents, but
these tests bypass it — they're checking the CLI's file-mutation
correctness (validation, idempotency, collision rejection).
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from click.testing import CliRunner

from esr.cli.main import cli


@pytest.fixture
def esrd_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    (tmp_path / "default").mkdir()
    return tmp_path


def _read_users(esrd_home: Path) -> dict:
    path = esrd_home / "default" / "users.yaml"
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text()) or {}


def test_user_add_creates_entry(esrd_home: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["user", "add", "linyilun"])
    assert result.exit_code == 0, result.output
    assert "added esr user linyilun" in result.output

    doc = _read_users(esrd_home)
    assert doc["users"]["linyilun"]["feishu_ids"] == []


def test_user_add_duplicate_fails(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    result = runner.invoke(cli, ["user", "add", "linyilun"])
    assert result.exit_code == 1
    assert "already exists" in result.output


def test_user_add_rejects_invalid_username(esrd_home: Path) -> None:
    runner = CliRunner()
    # Spaces, leading dash, and unicode all rejected by the regex
    for bad in ["with space", "-leading-dash", "中文"]:
        result = runner.invoke(cli, ["user", "add", bad])
        assert result.exit_code != 0, f"expected reject for {bad!r}, got: {result.output}"


def test_user_list_empty(esrd_home: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["user", "list"])
    assert result.exit_code == 0
    assert "no users registered" in result.output


def test_user_list_with_users(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "add", "yaoshengyue"])
    runner.invoke(
        cli, ["user", "bind-feishu", "linyilun", "ou_aaa"]
    )

    result = runner.invoke(cli, ["user", "list"])
    assert result.exit_code == 0
    assert "linyilun" in result.output
    assert "ou_aaa" in result.output
    assert "yaoshengyue" in result.output
    assert "(unbound)" in result.output


def test_user_remove(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    result = runner.invoke(cli, ["user", "remove", "linyilun"])
    assert result.exit_code == 0
    assert "removed esr user linyilun" in result.output

    doc = _read_users(esrd_home)
    assert "linyilun" not in (doc.get("users") or {})


def test_user_remove_unknown_fails(esrd_home: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["user", "remove", "nobody"])
    assert result.exit_code == 1
    assert "not found" in result.output


def test_bind_feishu_appends(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    result = runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    assert result.exit_code == 0

    doc = _read_users(esrd_home)
    assert doc["users"]["linyilun"]["feishu_ids"] == ["ou_aaa"]


def test_bind_feishu_idempotent(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    result = runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    assert result.exit_code == 0
    assert "already bound" in result.output

    doc = _read_users(esrd_home)
    assert doc["users"]["linyilun"]["feishu_ids"] == ["ou_aaa"]  # not duplicated


def test_bind_feishu_rejects_id_already_bound_to_other_user(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "add", "yaoshengyue"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])

    result = runner.invoke(
        cli, ["user", "bind-feishu", "yaoshengyue", "ou_aaa"]
    )
    assert result.exit_code == 1
    assert "already bound to 'linyilun'" in result.output


def test_bind_feishu_to_unknown_user_fails(esrd_home: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["user", "bind-feishu", "ghost", "ou_aaa"])
    assert result.exit_code == 1
    assert "not found" in result.output


def test_bind_feishu_supports_multiple_ids_per_user(esrd_home: Path) -> None:
    """Multi-app scenario: one human, two Feishu apps, two open_ids."""
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_AAA"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_BBB"])

    doc = _read_users(esrd_home)
    assert doc["users"]["linyilun"]["feishu_ids"] == ["ou_AAA", "ou_BBB"]


def test_unbind_feishu_removes(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    result = runner.invoke(
        cli, ["user", "unbind-feishu", "linyilun", "ou_aaa"]
    )
    assert result.exit_code == 0

    doc = _read_users(esrd_home)
    assert doc["users"]["linyilun"]["feishu_ids"] == []


def test_unbind_feishu_unknown_id_fails(esrd_home: Path) -> None:
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    result = runner.invoke(
        cli, ["user", "unbind-feishu", "linyilun", "ou_doesnt_exist"]
    )
    assert result.exit_code == 1
    assert "not bound" in result.output
