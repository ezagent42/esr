"""``esr cap`` — capability-based access control CLI.

Read commands — `list`, `show`, `who-can` — plus write commands
`grant` and `revoke`.

``list`` consumes ``permissions_registry.json`` — a snapshot the
runtime drops next to ``capabilities.yaml`` once the permissions
registry finishes bootstrap. ``show`` and ``who-can`` read
``capabilities.yaml`` directly; no runtime RPC is involved, so these
commands work offline (useful when operators need to audit a
capabilities file without standing up esrd).

``grant`` and ``revoke`` mutate ``capabilities.yaml`` in place using
``ruamel.yaml`` so header comments and whitespace survive the
round-trip. The watcher in ``Esr.Capabilities.Watcher`` picks up the
change within its poll interval — no esrd restart needed.
"""
from __future__ import annotations

import json
from pathlib import Path

import click
import yaml
from ruamel.yaml import YAML

from esr.capabilities import CapabilitiesChecker
from esr.cli.paths import capabilities_yaml_path

# Shared round-tripping loader/dumper — preserves comments, quote
# style, and uses the block-style indent matching the seeded fixtures
# and the runtime's conventional layout.
_yaml = YAML()
_yaml.preserve_quotes = True
_yaml.indent(mapping=2, sequence=4, offset=2)


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


@cap.command("grant")
@click.argument("principal_id")
@click.argument("permission")
@click.option("--kind", default="feishu_user", help="Principal kind (default: feishu_user)")
@click.option("--note", default="", help="Human-readable note for new principals")
def cap_grant(principal_id: str, permission: str, kind: str, note: str) -> None:
    """Grant ``permission`` to ``principal_id``.

    Creates the principal entry if missing; idempotent if the
    permission is already held. Preserves header comments and
    formatting in ``capabilities.yaml`` via ruamel round-trip.
    """
    path = Path(capabilities_yaml_path())
    path.parent.mkdir(parents=True, exist_ok=True)

    doc = _yaml.load(path) if path.exists() else {}
    if doc is None:
        doc = {}
    doc.setdefault("principals", [])

    target = next(
        (e for e in doc["principals"] if e.get("id") == principal_id),
        None,
    )
    if target is None:
        entry: dict[str, object] = {
            "id": principal_id,
            "kind": kind,
            "capabilities": [permission],
        }
        if note:
            entry["note"] = note
        doc["principals"].append(entry)
        click.echo(f"added principal {principal_id} with {permission}")
    else:
        if permission in (target.get("capabilities") or []):
            click.echo(f"{principal_id} already has {permission}; no change")
            return
        target.setdefault("capabilities", []).append(permission)
        click.echo(f"{principal_id} + {permission}")

    _yaml.dump(doc, path)


@cap.command("revoke")
@click.argument("principal_id")
@click.argument("permission")
def cap_revoke(principal_id: str, permission: str) -> None:
    """Revoke ``permission`` from ``principal_id``.

    No-op with a message if the principal or permission isn't found.
    The principal entry is retained even if its capabilities list
    becomes empty — note/kind persist for future grants.
    """
    path = Path(capabilities_yaml_path())
    if not path.exists():
        click.echo("no capabilities file; nothing to revoke")
        return

    doc = _yaml.load(path)
    if doc is None:
        doc = {}

    target = next(
        (e for e in doc.get("principals") or [] if e.get("id") == principal_id),
        None,
    )
    if target is None or permission not in (target.get("capabilities") or []):
        click.echo("no matching capability")
        return

    target["capabilities"].remove(permission)
    _yaml.dump(doc, path)
    click.echo(f"{principal_id} - {permission}")
