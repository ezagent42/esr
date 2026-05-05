"""``esr admin`` CLI group — submit admin commands to the queue (spec §5.2).

The ``submit`` subcommand is the primitive that all future admin CLI
wrappers (reload, notify, grant, revoke) delegate to: it writes a YAML
command file to ``~/.esrd/<instance>/admin_queue/pending/<ulid>.yaml``
using the atomic ``.tmp`` + rename pattern, then optionally polls for
the dispatcher's completed / failed counterpart.
"""
from __future__ import annotations

import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import click
import yaml
from ulid import ULID

from esr.cli import paths


@click.group()
def admin() -> None:
    """Administrative commands (queue-based)."""


@admin.command("submit")
@click.argument("kind")
@click.option("--arg", multiple=True, help="K=V argument pair; repeatable.")
@click.option("--wait/--no-wait", default=False)
@click.option("--timeout", default=30, help="Wait timeout in seconds.")
def admin_submit(kind: str, arg: tuple[str, ...], wait: bool, timeout: int) -> None:
    """Submit an admin command to the queue.

    Writes ``<admin_queue>/pending/<ULID>.yaml`` atomically (``.tmp`` +
    rename). With ``--wait``, polls ``completed/`` and ``failed/`` for
    the dispatcher's result and exits 0/1 accordingly; ``--timeout``
    bounds the wait and exits 3 if exceeded.
    """
    args_dict: dict[str, str] = {}
    for a in arg:
        if "=" not in a:
            click.echo(f"--arg must be K=V: got {a}", err=True)
            sys.exit(2)
        k, v = a.split("=", 1)
        args_dict[k] = v

    pending_dir: Path = paths.admin_queue_dir() / "pending"
    pending_dir.mkdir(parents=True, exist_ok=True)

    cmd_id = str(ULID())
    submitted_by = os.environ.get(
        "ESR_OPERATOR_PRINCIPAL_ID", os.environ.get("USER", "ou_local")
    )

    doc = {
        "id": cmd_id,
        "kind": kind,
        "submitted_by": submitted_by,
        "submitted_at": datetime.now(timezone.utc).isoformat(),
        "args": args_dict,
    }

    tmp_path = pending_dir / f"{cmd_id}.yaml.tmp"
    final_path = pending_dir / f"{cmd_id}.yaml"
    tmp_path.write_text(yaml.safe_dump(doc, sort_keys=False, allow_unicode=True))
    os.chmod(tmp_path, 0o600)
    os.rename(tmp_path, final_path)

    click.echo(f"submitted {cmd_id}")

    if wait:
        completed = paths.admin_queue_dir() / "completed" / f"{cmd_id}.yaml"
        failed = paths.admin_queue_dir() / "failed" / f"{cmd_id}.yaml"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if completed.exists():
                result = yaml.safe_load(completed.read_text()) or {}
                click.echo(yaml.safe_dump(result.get("result"), sort_keys=False))
                sys.exit(0)
            if failed.exists():
                result = yaml.safe_load(failed.read_text()) or {}
                payload = result.get("result") or result.get("error")
                click.echo(yaml.safe_dump(payload, sort_keys=False), err=True)
                sys.exit(1)
            time.sleep(0.2)
        click.echo(f"timed out after {timeout}s", err=True)
        sys.exit(3)
