"""CLI-layer tests for `esr cap list / show / who-can`.

Exercises the commands without a running esrd by pointing `ESRD_HOME`
at `tmp_path` and seeding both `capabilities.yaml` (for show / who-can)
and `permissions_registry.json` (for list) on disk. The production
runtime writes the JSON snapshot from
`Esr.Permissions.Bootstrap.bootstrap/1`; fixtures here simulate that.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from esr.cli.main import cli

# --- Fixtures ---------------------------------------------------------


@pytest.fixture
def esrd_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Seed an isolated ESRD_HOME under tmp_path.

    Creates `tmp_path/default/` and points `ESRD_HOME` at `tmp_path`.
    Tests then drop `capabilities.yaml` and/or `permissions_registry.json`
    into `tmp_path/default/` as needed.
    """
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    (tmp_path / "default").mkdir()
    return tmp_path


@pytest.fixture
def seeded_registry(esrd_home: Path) -> Path:
    """Seed a `permissions_registry.json` mirroring the shape
    `Registry.dump_json/1` produces (keyed by `to_string(module)`)."""
    registry_path = esrd_home / "default" / "permissions_registry.json"
    registry_path.write_text(
        json.dumps(
            {
                "Elixir.Esr.PeerServer": ["reply", "react", "send_file", "_echo"],
                "Elixir.Esr.Capabilities": ["cap.manage", "cap.read"],
            }
        )
    )
    return registry_path


@pytest.fixture
def seeded_caps(esrd_home: Path) -> Path:
    """Seed a `capabilities.yaml` with a mix of scoped + wildcard grants.

    `ou_alice` holds a scoped workspace grant; `ou_admin` holds the
    bare wildcard so who-can can exercise both match branches.
    """
    caps_path = esrd_home / "default" / "capabilities.yaml"
    caps_path.write_text(
        """principals:
  - id: ou_alice
    kind: feishu_user
    note: regular user
    capabilities:
      - workspace:proj-a/msg.send
      - workspace:proj-a/session.create
  - id: ou_admin
    kind: feishu_user
    note: admin
    capabilities:
      - "*"
  - id: ou_reader
    kind: feishu_user
    capabilities:
      - workspace:proj-b/msg.send
"""
    )
    return caps_path


# --- list -------------------------------------------------------------


def test_cap_list_prints_grouped_permissions(seeded_registry: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "list"])
    assert result.exit_code == 0, result.output

    # Modules print as headers, permissions as indented bullets.
    assert "Elixir.Esr.PeerServer:" in result.output
    assert "Elixir.Esr.Capabilities:" in result.output
    assert "  - reply" in result.output
    assert "  - cap.manage" in result.output

    # Permissions are sorted within a module.
    peer_block = result.output.split("Elixir.Esr.PeerServer:", 1)[1]
    # The next module header marks the end of the PeerServer block; in
    # sorted module order, Capabilities < PeerServer, so PeerServer is
    # actually the trailing block here. Slice up to EOF either way.
    lines = [
        ln.strip() for ln in peer_block.splitlines() if ln.strip().startswith("- ")
    ]
    # reply < send_file alphabetically? "_echo" < "react" < "reply" < "send_file"
    assert lines == sorted(lines)


def test_cap_list_missing_registry_exits_1(esrd_home: Path) -> None:
    """No snapshot → CLI tells the user to check esrd is running."""
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "list"])
    assert result.exit_code == 1
    assert "No permissions registered" in result.output
    assert "is esrd running?" in result.output


# --- show -------------------------------------------------------------


def test_cap_show_prints_principal_entry(seeded_caps: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "show", "ou_alice"])
    assert result.exit_code == 0, result.output

    # yaml.safe_dump includes the id/kind/note/capabilities fields;
    # check a representative handful to pin down the shape without
    # coupling to yaml's exact whitespace.
    assert "id: ou_alice" in result.output
    assert "kind: feishu_user" in result.output
    assert "workspace:proj-a/msg.send" in result.output
    assert "workspace:proj-a/session.create" in result.output


def test_cap_show_missing_principal_exits_1(seeded_caps: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "show", "ou_nobody"])
    assert result.exit_code == 1
    assert "not found" in result.output


def test_cap_show_handles_missing_capabilities_yaml(esrd_home: Path) -> None:
    """With no capabilities.yaml at all, show still exits cleanly (not
    a crash) — the principal simply isn't there."""
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "show", "ou_alice"])
    assert result.exit_code == 1
    assert "not found" in result.output


# --- who-can ----------------------------------------------------------


def test_cap_who_can_finds_exact_match(seeded_caps: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "who-can", "workspace:proj-a/msg.send"])
    assert result.exit_code == 0, result.output
    assert "ou_alice" in result.output
    # Admin's bare "*" grants everything — should also appear.
    assert "ou_admin" in result.output
    assert "(via *)" in result.output
    # ou_reader's grant is proj-b; should NOT match proj-a.
    assert "ou_reader" not in result.output


def test_cap_who_can_admin_wildcard_grants_anything(seeded_caps: Path) -> None:
    """Admin holds bare `*` — `_matches` short-circuits to True, so
    who-can surfaces them for every query regardless of segment shape.
    Non-admins without that query's specific grant drop out."""
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "who-can", "workspace:proj-a/cap.read"])
    assert result.exit_code == 0, result.output
    assert "ou_admin" in result.output
    # Alice holds workspace:proj-a/msg.send only, not cap.read.
    assert "ou_alice" not in result.output


def test_cap_who_can_empty_result_exits_0(esrd_home: Path) -> None:
    """Finding no one is a valid answer — not an error. Uses an
    admin-free fixture so the bare-`*` short-circuit can't mask a zero
    match."""
    (esrd_home / "default" / "capabilities.yaml").write_text(
        """principals:
  - id: ou_alice
    kind: feishu_user
    capabilities:
      - workspace:proj-a/msg.send
"""
    )
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "who-can", "workspace:nope/xyz"])
    assert result.exit_code == 0
    assert "no matching principals" in result.output
