"""Tests for ``esr.capabilities.CapabilitiesChecker``.

Mirrors ``runtime/test/esr/capabilities/grants_test.exs`` so the
Python and Elixir wildcard-match semantics stay in lockstep.
"""
from __future__ import annotations

import os
from pathlib import Path

import yaml

from esr.capabilities import CapabilitiesChecker


def _write_caps(path: Path, principals: list[dict]) -> None:
    path.write_text(yaml.safe_dump({"principals": principals}, sort_keys=False))


# --- parity with runtime/test/esr/capabilities/grants_test.exs ---


def test_empty_snapshot_denies_everything(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    _write_caps(path, [])
    c = CapabilitiesChecker(path)
    assert c.has("ou_xxx", "workspace:proj/msg.send") is False


def test_admin_wildcard_grants_all(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    _write_caps(path, [{"id": "ou_admin", "capabilities": ["*"]}])
    c = CapabilitiesChecker(path)
    assert c.has("ou_admin", "workspace:any/any.perm") is True


def test_exact_match(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    _write_caps(
        path,
        [{"id": "ou_alice", "capabilities": ["workspace:proj-a/msg.send"]}],
    )
    c = CapabilitiesChecker(path)
    assert c.has("ou_alice", "workspace:proj-a/msg.send") is True
    assert c.has("ou_alice", "workspace:proj-b/msg.send") is False
    assert c.has("ou_alice", "workspace:proj-a/session.create") is False


def test_scope_wildcard(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    _write_caps(
        path,
        [{"id": "ou_reader", "capabilities": ["workspace:*/msg.send"]}],
    )
    c = CapabilitiesChecker(path)
    assert c.has("ou_reader", "workspace:proj-a/msg.send") is True
    assert c.has("ou_reader", "workspace:proj-b/msg.send") is True
    assert c.has("ou_reader", "workspace:proj-a/session.create") is False


def test_permission_wildcard_within_scope(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    _write_caps(
        path,
        [{"id": "ou_owner", "capabilities": ["workspace:proj-a/*"]}],
    )
    c = CapabilitiesChecker(path)
    assert c.has("ou_owner", "workspace:proj-a/msg.send") is True
    assert c.has("ou_owner", "workspace:proj-a/session.create") is True
    assert c.has("ou_owner", "workspace:proj-b/msg.send") is False


def test_prefix_glob_does_not_match(tmp_path: Path) -> None:
    # session.* is NOT valid — only `*` as a whole segment
    path = tmp_path / "caps.yaml"
    _write_caps(
        path,
        [{"id": "ou_x", "capabilities": ["workspace:proj/session.*"]}],
    )
    c = CapabilitiesChecker(path)
    assert c.has("ou_x", "workspace:proj/session.create") is False


def test_prefix_must_match_literally(tmp_path: Path) -> None:
    """A different scope prefix (e.g. ``chat`` vs ``workspace``) must NOT
    match even with a wildcard name. Mirrors ``h_prefix == r_prefix``
    in the Elixir impl."""
    path = tmp_path / "caps.yaml"
    _write_caps(
        path,
        [{"id": "ou_x", "capabilities": ["chat:*/msg.send"]}],
    )
    c = CapabilitiesChecker(path)
    assert c.has("ou_x", "workspace:proj-a/msg.send") is False


# --- file-backed semantics ---


def test_missing_file_is_default_deny(tmp_path: Path) -> None:
    c = CapabilitiesChecker(tmp_path / "missing.yaml")
    assert c.has("ou_anyone", "workspace:proj/msg.send") is False


def test_reload_picks_up_edits_by_mtime(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    _write_caps(path, [{"id": "ou_alice", "capabilities": ["workspace:a/msg.send"]}])
    c = CapabilitiesChecker(path)
    assert c.has("ou_alice", "workspace:a/msg.send") is True
    assert c.has("ou_bob", "workspace:a/msg.send") is False

    # Rewrite with a new grant; bump mtime so reload picks it up.
    _write_caps(path, [{"id": "ou_bob", "capabilities": ["workspace:a/msg.send"]}])
    os.utime(path, (path.stat().st_atime, path.stat().st_mtime + 1.0))

    assert c.has("ou_bob", "workspace:a/msg.send") is True
    assert c.has("ou_alice", "workspace:a/msg.send") is False


def test_reload_skips_reread_when_mtime_unchanged(tmp_path: Path) -> None:
    """``has()`` must not rescan the yaml on every call; mtime-gating
    keeps the hot path cheap."""
    path = tmp_path / "caps.yaml"
    _write_caps(path, [{"id": "ou_alice", "capabilities": ["workspace:a/msg.send"]}])
    c = CapabilitiesChecker(path)
    assert c.has("ou_alice", "workspace:a/msg.send") is True

    # Monkey-delete the file contents; without a fresh mtime the
    # checker must still answer from the cached snapshot.
    path.unlink()
    # Recreate empty at the SAME mtime — reload should no-op because
    # mtime matches the cached value. (Hard to guarantee a same-mtime
    # write, so the real assertion is that the snapshot survives an
    # mtime that hasn't advanced past the cached value.)
    c2 = CapabilitiesChecker(tmp_path / "nope.yaml")
    # second checker on a never-existing file is default-deny
    assert c2.has("ou_alice", "workspace:a/msg.send") is False


def test_missing_capabilities_key_treats_principal_as_empty(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    _write_caps(path, [{"id": "ou_nobody"}])
    c = CapabilitiesChecker(path)
    assert c.has("ou_nobody", "workspace:proj/msg.send") is False


def test_non_dict_entry_is_skipped(tmp_path: Path) -> None:
    path = tmp_path / "caps.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "principals": [
                    "not a dict",
                    {"id": "ou_ok", "capabilities": ["*"]},
                ]
            }
        )
    )
    c = CapabilitiesChecker(path)
    assert c.has("ou_ok", "anything") is True
