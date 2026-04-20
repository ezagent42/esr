"""``esr cap`` — capability-based access control CLI.

Read-only inspection commands — `list`, `show`, `who-can`. Write
commands (`grant`, `revoke`) arrive in Phase CAP-7.

``list`` consumes ``permissions_registry.json`` — a snapshot the
runtime drops next to ``capabilities.yaml`` once the permissions
registry finishes bootstrap. ``show`` and ``who-can`` read
``capabilities.yaml`` directly; no runtime RPC is involved, so these
commands work offline (useful when operators need to audit a
capabilities file without standing up esrd).
"""
from __future__ import annotations

import json
from pathlib import Path

import click
import yaml

from esr.capabilities import CapabilitiesChecker
from esr.cli.paths import capabilities_yaml_path


@click.group()
def cap() -> None:
    """Manage capabilities (who holds which permission)."""


@cap.command("list")
def cap_list() -> None:
    """Show every registered permission grouped by declaring module.

    Reads the JSON snapshot esrd writes at boot. If esrd has never
    started under the current `ESRD_HOME`, the snapshot is absent and
    this command exits 1.
    """
    cache = Path(capabilities_yaml_path()).parent / "permissions_registry.json"
    if not cache.exists():
        click.echo("No permissions registered (is esrd running?)", err=True)
        raise SystemExit(1)

    doc = json.loads(cache.read_text())
    for mod in sorted(doc):
        click.echo(f"{mod}:")
        for perm in sorted(doc[mod]):
            click.echo(f"  - {perm}")


@cap.command("show")
@click.argument("principal_id")
def cap_show(principal_id: str) -> None:
    """Pretty-print one principal's entry from ``capabilities.yaml``."""
    path = Path(capabilities_yaml_path())
    doc = yaml.safe_load(path.read_text()) if path.exists() else {}
    doc = doc or {}

    for entry in doc.get("principals") or []:
        if entry.get("id") == principal_id:
            click.echo(
                yaml.safe_dump(entry, sort_keys=False, allow_unicode=True),
                nl=False,
            )
            return

    click.echo(f"principal {principal_id} not found", err=True)
    raise SystemExit(1)


@cap.command("who-can")
@click.argument("permission")
def cap_who_can(permission: str) -> None:
    """Reverse lookup — list principals whose held capabilities grant
    ``permission``.

    Uses the same wildcard rules as `CapabilitiesChecker._matches`
    (runtime Lane A) so the CLI answer can't drift from the live
    enforcement. An empty match set is NOT an error — prints a note
    on stderr, exits 0.
    """
    path = Path(capabilities_yaml_path())
    doc = yaml.safe_load(path.read_text()) if path.exists() else {}
    doc = doc or {}

    hits: list[str] = []
    for entry in doc.get("principals") or []:
        pid = entry.get("id")
        if not pid:
            continue
        for held in entry.get("capabilities") or []:
            if CapabilitiesChecker._matches(held, permission):
                hits.append(f"{pid} (via {held})")
                break

    for h in hits:
        click.echo(h)
    if not hits:
        click.echo("no matching principals", err=True)
