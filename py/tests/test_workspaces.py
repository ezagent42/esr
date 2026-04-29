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
        root="/Users/h2oslabs/Workspace/esr",
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
    assert loaded["esr-dev"].root == "/Users/h2oslabs/Workspace/esr"
    assert loaded["esr-dev"].chats == [{"chat_id": "oc_x", "app_id": "cli_x", "kind": "dm"}]


def test_write_rejects_duplicate_name(tmp_path: Path) -> None:
    f = tmp_path / "workspaces.yaml"
    ws = Workspace(
        name="x", owner=None, root="/", start_cmd="a", role="dev", chats=[], env={}
    )
    write_workspace(f, ws)
    with pytest.raises(ValueError, match="already exists"):
        write_workspace(f, ws)


def test_optional_owner_root_omitted_from_yaml_when_none(tmp_path: Path) -> None:
    """PR-21c: owner/root are optional; None should not write the key."""
    f = tmp_path / "workspaces.yaml"
    ws = Workspace(
        name="legacy", owner=None, root=None, start_cmd="a", role="dev",
        chats=[], env={},
    )
    write_workspace(f, ws)

    raw = f.read_text()
    assert "owner" not in raw
    assert "root" not in raw
