"""``esr user`` — esr user registry CLI (PR-21a).

esr users are the canonical principal identity in esrd: capabilities
key on them, sessions are owned by them, and `<channel>` envelopes
resolve their `user_id` (a Feishu open_id) to an esr username via the
binding table here.

Storage: ``~/.esrd/<instance>/users.yaml``. Schema::

    users:
      linyilun:
        feishu_ids:
          - ou_6b11faf8e93aedfb9d3857b9cc23b9e7
      yaoshengyue:
        feishu_ids: []

Multiple feishu ids per user are supported because Feishu open_ids are
app-scoped — one human registered with two apps has two open_ids that
must both resolve to the same esr user.

All commands mutate the file directly using ``ruamel.yaml`` to preserve
header comments and round-trip layout. The Elixir runtime's
``Esr.Users.Watcher`` picks up changes within its FSEvents poll window;
no esrd restart is required.
"""
from __future__ import annotations

import re
from pathlib import Path

import click
from ruamel.yaml import YAML

from esr.cli.paths import users_yaml_path

_yaml = YAML()
_yaml.preserve_quotes = True
_yaml.indent(mapping=2, sequence=4, offset=2)

# ASCII alphanumeric leading char + alphanumeric / underscore / dash.
# Aligned with PR-M adapter-naming rule and D13 in the PR-21 spec.
_USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_\-]*$")


def _validate_username(name: str) -> None:
    if not _USERNAME_RE.match(name):
        raise click.BadParameter(
            f"username {name!r} must match {_USERNAME_RE.pattern} "
            "(ASCII alphanumeric, optionally with - and _)"
        )


def _read_doc(path: Path) -> dict:
    if not path.exists():
        return {"users": {}}
    with path.open("r") as f:
        doc = _yaml.load(f) or {}
    if "users" not in doc or doc["users"] is None:
        doc["users"] = {}
    return doc


def _write_doc(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        _yaml.dump(doc, f)


@click.group()
def user() -> None:
    """Manage esr users (the principal identity behind capabilities)."""


@user.command("add")
@click.argument("name")
def user_add(name: str) -> None:
    """Register a new esr user with no feishu binding yet.

    Bind feishu ids afterwards via ``esr user bind-feishu <name> <feishu_id>``.
    """
    _validate_username(name)
    path = users_yaml_path()
    doc = _read_doc(path)

    if name in doc["users"]:
        click.echo(f"user {name!r} already exists", err=True)
        raise SystemExit(1)

    doc["users"][name] = {"feishu_ids": []}
    _write_doc(path, doc)
    click.echo(f"added esr user {name}")


@user.command("list")
def user_list() -> None:
    """Print every registered esr user, one per line, with bound feishu ids."""
    doc = _read_doc(users_yaml_path())
    users = doc.get("users") or {}

    if not users:
        click.echo("no users registered")
        return

    for name in sorted(users):
        ids = (users[name] or {}).get("feishu_ids") or []
        if ids:
            click.echo(f"{name}  feishu_ids={','.join(ids)}")
        else:
            click.echo(f"{name}  (unbound)")


@user.command("remove")
@click.argument("name")
def user_remove(name: str) -> None:
    """Remove an esr user and all their feishu bindings.

    Does NOT cascade-delete capabilities granted to the user (run
    ``esr cap revoke`` separately if you want a clean wipe).
    """
    path = users_yaml_path()
    doc = _read_doc(path)

    if name not in doc["users"]:
        click.echo(f"user {name!r} not found", err=True)
        raise SystemExit(1)

    del doc["users"][name]
    _write_doc(path, doc)
    click.echo(f"removed esr user {name}")


@user.command("bind-feishu")
@click.argument("name")
@click.argument("feishu_user_id")
def user_bind_feishu(name: str, feishu_user_id: str) -> None:
    """Bind a Feishu open_id to an existing esr user.

    Multiple feishu ids per user are allowed (one per registered Feishu
    app — open_ids are app-scoped). Idempotent: re-binding the same
    pair is a no-op.
    """
    if not feishu_user_id.startswith("ou_"):
        click.echo(
            f"warning: feishu open_id {feishu_user_id!r} doesn't start with 'ou_'; "
            "Feishu open_ids conventionally use that prefix",
            err=True,
        )

    path = users_yaml_path()
    doc = _read_doc(path)

    if name not in doc["users"]:
        click.echo(
            f"user {name!r} not found; run `esr user add {name}` first",
            err=True,
        )
        raise SystemExit(1)

    user_row = doc["users"][name] or {}
    ids = list(user_row.get("feishu_ids") or [])

    if feishu_user_id in ids:
        click.echo(f"{feishu_user_id} already bound to {name}")
        return

    # Reject if the id is already bound to a different user (one feishu
    # id can only resolve to one esr user — the runtime's by-feishu-id
    # ETS table is a 1:1 mapping). Surface this at write time so the
    # operator notices instead of getting last-write-wins surprise.
    for other_name, other_row in doc["users"].items():
        if other_name == name:
            continue
        other_ids = (other_row or {}).get("feishu_ids") or []
        if feishu_user_id in other_ids:
            click.echo(
                f"feishu_id {feishu_user_id} is already bound to {other_name!r}; "
                f"unbind it first with `esr user unbind-feishu {other_name} {feishu_user_id}`",
                err=True,
            )
            raise SystemExit(1)

    ids.append(feishu_user_id)
    user_row["feishu_ids"] = ids
    doc["users"][name] = user_row
    _write_doc(path, doc)

    # PR-21q: auto-grant the bootstrap caps to the freshly-bound
    # feishu open_id. Without these, the operator's first slash
    # command in Feishu (e.g. `/new-workspace`) would fail the
    # cap check (`workspace.create` required by Workspace.New).
    # Grants are keyed by the raw `ou_*` because the runtime's
    # cap check uses `principal_id` from the inbound envelope, which
    # is the open_id today (PR-21b's user-URI rekey is graceful
    # fallback only — caps haven't been re-keyed onto esr usernames).
    _bootstrap_grant_caps(feishu_user_id)

    click.echo(f"bound {feishu_user_id} to esr user {name}")
    click.echo(
        f"  + auto-granted workspace.create / session:default/create / "
        f"session:default/end / session.list to {feishu_user_id}"
    )


def _bootstrap_grant_caps(feishu_user_id: str) -> None:
    """PR-21q: write a default cap grant for a freshly-bound feishu id.

    The four bootstrap caps an active operator needs:

    - workspace.create        — for `/new-workspace` slash
    - session:default/create  — for `/new-session` slash
    - session:default/end     — for `/end-session` slash
    - session.list            — for `/sessions`, `/workspace info`, etc.

    Pure file-write — uses the same ruamel round-trip as the rest of
    this module so existing comments / formatting in capabilities.yaml
    survive. Skips silently when a grant is already present
    (idempotent — re-running `bind-feishu` with the same args
    won't duplicate cap entries).
    """
    from esr.cli.paths import capabilities_yaml_path

    target_caps = [
        "workspace.create",
        "session:default/create",
        "session:default/end",
        "session.list",
    ]

    caps_path = Path(capabilities_yaml_path())
    if caps_path.exists():
        with caps_path.open("r") as f:
            doc = _yaml.load(f) or {}
    else:
        doc = {}

    principals = doc.setdefault("principals", [])

    # Find or create the principal entry
    principal_entry = None
    for p in principals:
        if isinstance(p, dict) and p.get("id") == feishu_user_id:
            principal_entry = p
            break

    if principal_entry is None:
        principal_entry = {
            "id": feishu_user_id,
            "kind": "feishu_user",
            "capabilities": [],
        }
        principals.append(principal_entry)

    held = list(principal_entry.get("capabilities") or [])
    for cap in target_caps:
        if cap not in held:
            held.append(cap)
    principal_entry["capabilities"] = held

    caps_path.parent.mkdir(parents=True, exist_ok=True)
    with caps_path.open("w") as f:
        _yaml.dump(doc, f)


@user.command("unbind-feishu")
@click.argument("name")
@click.argument("feishu_user_id")
def user_unbind_feishu(name: str, feishu_user_id: str) -> None:
    """Remove a Feishu open_id binding from an esr user.

    PR-21s (2026-04-29): also auto-revokes the 4 bootstrap caps that
    bind-feishu auto-granted. Symmetric — bind grants, unbind revokes.
    Other manually-added caps on the open_id are preserved.
    """
    path = users_yaml_path()
    doc = _read_doc(path)

    if name not in doc["users"]:
        click.echo(f"user {name!r} not found", err=True)
        raise SystemExit(1)

    user_row = doc["users"][name] or {}
    ids = list(user_row.get("feishu_ids") or [])

    if feishu_user_id not in ids:
        click.echo(f"{feishu_user_id} not bound to {name}", err=True)
        raise SystemExit(1)

    ids.remove(feishu_user_id)
    user_row["feishu_ids"] = ids
    doc["users"][name] = user_row
    _write_doc(path, doc)

    revoked = _bootstrap_revoke_caps(feishu_user_id)

    click.echo(f"unbound {feishu_user_id} from esr user {name}")
    if revoked:
        click.echo(
            f"  - auto-revoked {len(revoked)} bootstrap cap(s) from "
            f"{feishu_user_id}: {', '.join(revoked)}"
        )


def _bootstrap_revoke_caps(feishu_user_id: str) -> list[str]:
    """PR-21s: counterpart to _bootstrap_grant_caps. Revoke ONLY the
    4 caps bind-feishu auto-granted; preserve any manually-added grants
    (e.g. `cap grant ou_xxx admin`).

    Returns the list of caps actually removed (for the operator-facing
    confirmation message). Empty list when the principal entry is gone
    or has no overlap with the bootstrap set.
    """
    from esr.cli.paths import capabilities_yaml_path

    target_caps = {
        "workspace.create",
        "session:default/create",
        "session:default/end",
        "session.list",
    }

    caps_path = Path(capabilities_yaml_path())
    if not caps_path.exists():
        return []

    with caps_path.open("r") as f:
        doc = _yaml.load(f) or {}

    principals = doc.get("principals") or []
    revoked: list[str] = []

    for p in principals:
        if not isinstance(p, dict) or p.get("id") != feishu_user_id:
            continue
        held = list(p.get("capabilities") or [])
        kept: list[str] = []
        for cap in held:
            if cap in target_caps:
                revoked.append(cap)
            else:
                kept.append(cap)
        p["capabilities"] = kept

    if not revoked:
        return []

    # Drop principal entry entirely if no caps remain (clean state)
    pruned = [
        p
        for p in principals
        if not (
            isinstance(p, dict)
            and p.get("id") == feishu_user_id
            and not (p.get("capabilities") or [])
        )
    ]
    doc["principals"] = pruned

    with caps_path.open("w") as f:
        _yaml.dump(doc, f)
    return revoked
