"""CLI-layer tests for `esr cap grant / revoke`.

Uses the same `ESRD_HOME → tmp_path` monkeypatch pattern as
``test_cli_cap_read.py`` so the write commands operate on an isolated
``capabilities.yaml`` fixture. Each test seeds the YAML directly on
disk, invokes the command via ``CliRunner``, and then re-reads the
file to check the mutation.

Comment preservation is checked by seeding a file with header
comments and asserting they survive a ``grant`` round-trip —
the main reason CAP-7 uses ``ruamel.yaml`` rather than PyYAML for
writes.
"""
from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from esr.cli.main import cli


# --- Fixtures ---------------------------------------------------------


@pytest.fixture
def esrd_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point `ESRD_HOME` at `tmp_path` and create the `default/` dir."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    (tmp_path / "default").mkdir()
    return tmp_path


@pytest.fixture
def seeded_caps(esrd_home: Path) -> Path:
    """Seed a `capabilities.yaml` with ou_alice holding one permission."""
    caps_path = esrd_home / "default" / "capabilities.yaml"
    caps_path.write_text(
        """principals:
  - id: ou_alice
    kind: feishu_user
    note: regular user
    capabilities:
      - workspace:proj-a/msg.send
"""
    )
    return caps_path


# --- grant ------------------------------------------------------------


def test_grant_creates_principal_entry(esrd_home: Path) -> None:
    """grant on a missing principal inserts a new entry with
    id/kind/note/capabilities — no pre-existing file required."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        [
            "cap",
            "grant",
            "ou_new",
            "workspace:proj-a/msg.send",
            "--kind=feishu_user",
            "--note=Bob",
        ],
    )
    assert result.exit_code == 0, result.output

    caps_path = esrd_home / "default" / "capabilities.yaml"
    content = caps_path.read_text()
    assert "ou_new" in content
    assert "Bob" in content
    assert "workspace:proj-a/msg.send" in content
    assert "feishu_user" in content


def test_grant_appends_to_existing_principal(seeded_caps: Path) -> None:
    """ou_alice already has one permission — grant a second and both
    should be present exactly once."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cap", "grant", "ou_alice", "workspace:proj-a/session.create"],
    )
    assert result.exit_code == 0, result.output

    content = seeded_caps.read_text()
    assert content.count("workspace:proj-a/msg.send") == 1
    assert content.count("workspace:proj-a/session.create") == 1
    # The principal is not duplicated either.
    assert content.count("id: ou_alice") == 1


def test_grant_idempotent(seeded_caps: Path) -> None:
    """Granting a permission the principal already holds is a no-op
    (no duplicate line, friendly message, exit 0)."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cap", "grant", "ou_alice", "workspace:proj-a/msg.send"],
    )
    assert result.exit_code == 0, result.output
    assert "already has" in result.output

    content = seeded_caps.read_text()
    assert content.count("workspace:proj-a/msg.send") == 1


# --- revoke -----------------------------------------------------------


def test_revoke_removes_grant(seeded_caps: Path) -> None:
    """revoke strips the permission line but keeps the principal
    entry (id/kind/note survive for re-grant)."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cap", "revoke", "ou_alice", "workspace:proj-a/msg.send"],
    )
    assert result.exit_code == 0, result.output

    content = seeded_caps.read_text()
    assert "workspace:proj-a/msg.send" not in content
    # Principal entry retained even with empty capabilities list.
    assert "id: ou_alice" in content
    assert "kind: feishu_user" in content
    assert "note: regular user" in content


def test_revoke_noop_on_missing(seeded_caps: Path) -> None:
    """Revoking a permission not held yields exit 0 and a clear
    message — not an error state."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cap", "revoke", "ou_alice", "workspace:nope/xyz"],
    )
    assert result.exit_code == 0
    assert "no matching capability" in result.output


def test_revoke_noop_when_principal_missing(seeded_caps: Path) -> None:
    """Principal not in file → same 'no matching capability' message,
    exit 0. Exercises the early-return branch that covers a missing
    principal as well as a missing permission on a present principal.
    """
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cap", "revoke", "ou_nobody", "workspace:proj-a/msg.send"],
    )
    assert result.exit_code == 0
    assert "no matching capability" in result.output


def test_revoke_without_file_is_clean_noop(esrd_home: Path) -> None:
    """Revoke when capabilities.yaml doesn't exist at all — exit 0,
    helpful message, no file created."""
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cap", "revoke", "ou_alice", "workspace:proj-a/msg.send"],
    )
    assert result.exit_code == 0
    assert "no capabilities file" in result.output


# --- comment preservation --------------------------------------------


def test_grant_preserves_comments(esrd_home: Path) -> None:
    """The whole point of ruamel.yaml over PyYAML for writes — header
    comments and blank lines MUST survive a round-trip. This test
    first asserts the fixture actually contains the comments (so a
    future refactor can't let the assertion pass vacuously), then
    invokes grant and re-reads.
    """
    caps_path = esrd_home / "default" / "capabilities.yaml"
    seeded = """# Admin contact: linyilun@example.com
# Do not edit under active traffic

principals:
  - id: ou_alice
    kind: feishu_user
    capabilities: []
"""
    caps_path.write_text(seeded)

    # Sanity check: the fixture has the comments we're about to verify
    # survive. Without this, a future fixture refactor that drops the
    # comments would leave the post-grant assertion trivially passing.
    pre = caps_path.read_text()
    assert "# Admin contact: linyilun@example.com" in pre
    assert "# Do not edit under active traffic" in pre

    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["cap", "grant", "ou_alice", "workspace:proj-a/msg.send"],
    )
    assert result.exit_code == 0, result.output

    post = caps_path.read_text()
    # Comments survived the round-trip.
    assert "# Admin contact: linyilun@example.com" in post
    assert "# Do not edit under active traffic" in post
    # And the grant actually happened.
    assert "workspace:proj-a/msg.send" in post
