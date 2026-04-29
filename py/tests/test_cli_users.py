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


def test_bind_feishu_writes_bootstrap_caps_under_username(esrd_home: Path) -> None:
    """PR-21y: bind-feishu auto-grants 4 bootstrap caps under the
    esr-username (NOT the raw open_id). Inbound cap reads still work
    via PR-21s graceful resolve (open_id → username at check time)."""
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    result = runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    assert result.exit_code == 0
    assert "auto-granted" in result.output
    assert "to linyilun" in result.output

    caps_path = esrd_home / "default" / "capabilities.yaml"
    assert caps_path.exists()
    caps_doc = yaml.safe_load(caps_path.read_text()) or {}

    # Bootstrap caps land under `linyilun`, not `ou_aaa`.
    by_id = {p["id"]: p for p in caps_doc.get("principals", []) if isinstance(p, dict)}
    assert "linyilun" in by_id
    assert "ou_aaa" not in by_id

    held = set(by_id["linyilun"].get("capabilities") or [])
    assert "workspace.create" in held
    assert "session:default/create" in held
    assert "session:default/end" in held
    assert "session.list" in held


def test_bind_feishu_migrates_existing_ou_caps_to_username(esrd_home: Path) -> None:
    """PR-21y: when capabilities.yaml already has caps under the raw
    open_id (e.g. PR-21q-era `cap grant ou_xxx admin`), bind-feishu
    moves them to the username entry and drops the open_id row."""
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])

    # Pre-seed capabilities.yaml with `ou_aaa` holding `*`.
    caps_path = esrd_home / "default" / "capabilities.yaml"
    caps_path.parent.mkdir(parents=True, exist_ok=True)
    caps_path.write_text(
        "principals:\n"
        "  - id: ou_aaa\n"
        "    kind: feishu_user\n"
        "    capabilities:\n"
        "      - '*'\n"
    )

    result = runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    assert result.exit_code == 0
    assert "migrated 1 existing cap(s)" in result.output
    assert "*" in result.output  # cap appears in the migration line

    caps_doc = yaml.safe_load(caps_path.read_text()) or {}
    by_id = {p["id"]: p for p in caps_doc.get("principals", []) if isinstance(p, dict)}

    # ou_aaa entry gone; everything moved under linyilun.
    assert "ou_aaa" not in by_id
    assert "linyilun" in by_id
    held = set(by_id["linyilun"].get("capabilities") or [])
    assert "*" in held
    assert "workspace.create" in held  # bootstrap cap still added


def test_unbind_feishu_last_binding_revokes_bootstrap_from_username(
    esrd_home: Path,
) -> None:
    """PR-21y: unbind that removes the LAST Feishu binding revokes the
    4 bootstrap caps from the username's entry. Manual grants survive."""
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])

    # Manually add an `*` cap under the username.
    caps_path = esrd_home / "default" / "capabilities.yaml"
    caps_doc = yaml.safe_load(caps_path.read_text()) or {}
    for p in caps_doc["principals"]:
        if p["id"] == "linyilun":
            p["capabilities"].append("*")
    caps_path.write_text(yaml.safe_dump(caps_doc))

    result = runner.invoke(cli, ["user", "unbind-feishu", "linyilun", "ou_aaa"])
    assert result.exit_code == 0
    assert "auto-revoked 4 bootstrap cap(s)" in result.output
    assert "no Feishu bindings remain" in result.output

    caps_doc = yaml.safe_load(caps_path.read_text()) or {}
    by_id = {p["id"]: p for p in caps_doc.get("principals", []) if isinstance(p, dict)}
    assert by_id["linyilun"]["capabilities"] == ["*"]


def test_unbind_feishu_with_other_bindings_preserves_caps(esrd_home: Path) -> None:
    """PR-21y: unbinding ONE feishu_id while others remain leaves the
    username's caps untouched (the user can still invoke caps via the
    other binding)."""
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_bbb"])

    result = runner.invoke(cli, ["user", "unbind-feishu", "linyilun", "ou_aaa"])
    assert result.exit_code == 0
    assert "auto-revoked" not in result.output  # caps stay

    caps_path = esrd_home / "default" / "capabilities.yaml"
    caps_doc = yaml.safe_load(caps_path.read_text()) or {}
    by_id = {p["id"]: p for p in caps_doc.get("principals", []) if isinstance(p, dict)}
    held = set(by_id["linyilun"].get("capabilities") or [])
    assert "workspace.create" in held  # bootstrap caps preserved


def test_unbind_feishu_last_binding_with_no_manual_caps_drops_entry(
    esrd_home: Path,
) -> None:
    """PR-21y: when unbind removes the last binding AND only the 4
    bootstrap caps were held under the username, the entry is pruned."""
    runner = CliRunner()
    runner.invoke(cli, ["user", "add", "linyilun"])
    runner.invoke(cli, ["user", "bind-feishu", "linyilun", "ou_aaa"])
    runner.invoke(cli, ["user", "unbind-feishu", "linyilun", "ou_aaa"])

    caps_path = esrd_home / "default" / "capabilities.yaml"
    caps_doc = yaml.safe_load(caps_path.read_text()) or {}
    principal_ids = [p.get("id") for p in caps_doc.get("principals", [])]
    assert "linyilun" not in principal_ids
    assert "ou_aaa" not in principal_ids
