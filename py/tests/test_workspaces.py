from pathlib import Path

import pytest

from esr.workspaces import Workspace, read_workspaces, write_workspace


def test_read_empty_path_returns_empty_dict(tmp_path: Path) -> None:
    f = tmp_path / "workspaces.yaml"
    assert read_workspaces(f) == {}


def test_write_then_read_roundtrip(tmp_path: Path) -> None:
    f = tmp_path / "workspaces.yaml"
    ws = Workspace(
        name="esr-dev",
        owner="linyilun",
        start_cmd="scripts/esr-cc.sh",
        role="dev",
        chats=[{"chat_id": "oc_x", "app_id": "cli_x", "kind": "dm"}],
        env={"EXTRA": "1"},
    )
    write_workspace(f, ws)

    loaded = read_workspaces(f)
    assert "esr-dev" in loaded
    assert loaded["esr-dev"].role == "dev"
    assert loaded["esr-dev"].owner == "linyilun"
    # PR-22: workspace.root removed
    assert not hasattr(loaded["esr-dev"], "root")
    assert loaded["esr-dev"].chats == [{"chat_id": "oc_x", "app_id": "cli_x", "kind": "dm"}]


def test_write_rejects_duplicate_name(tmp_path: Path) -> None:
    f = tmp_path / "workspaces.yaml"
    ws = Workspace(
        name="x", owner=None, start_cmd="a", role="dev", chats=[], env={}
    )
    write_workspace(f, ws)
    with pytest.raises(ValueError, match="already exists"):
        write_workspace(f, ws)


def test_optional_owner_omitted_from_yaml_when_none(tmp_path: Path) -> None:
    """PR-21c: owner is optional; None should not write the key."""
    f = tmp_path / "workspaces.yaml"
    ws = Workspace(
        name="legacy", owner=None, start_cmd="a", role="dev",
        chats=[], env={},
    )
    write_workspace(f, ws)

    raw = f.read_text()
    assert "owner" not in raw
    # PR-22: root never written under any condition
    assert "root" not in raw


def test_legacy_yaml_with_root_field_silently_ignored(tmp_path: Path) -> None:
    """PR-22: pre-PR-22 yaml may have `root:` entries; they're ignored."""
    f = tmp_path / "workspaces.yaml"
    f.write_text("""
schema_version: 1
workspaces:
  legacy:
    owner: linyilun
    root: /should/be/ignored
    start_cmd: x
    role: dev
""")
    loaded = read_workspaces(f)
    assert "legacy" in loaded
    assert loaded["legacy"].owner == "linyilun"
    # The `root` key on disk is silently dropped at parse time
    assert not hasattr(loaded["legacy"], "root")
