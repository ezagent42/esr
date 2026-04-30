"""``esr daemon`` — esrd lifecycle management (PR-21n).

Wraps `launchctl` operations so operators don't have to memorize
plist paths or kickstart syntax. Selects the prod / dev daemon via
the same ``--env=prod|dev`` mapping used by ``esr.sh`` (PR-K era).

Why a CLI subcommand and not a script: the rest of the operator
surface is ``esr <subcmd>`` (cap, user, workspace, adapter, …).
Adding ``esr daemon`` keeps the mental model uniform — every
runtime-touching operation flows through the same binary.

Subcommands:
    esr daemon status   — show pid / uptime / plist label
    esr daemon start    — launchctl bootstrap (load plist if absent)
    esr daemon stop     — launchctl bootout (graceful)
    esr daemon restart  — launchctl kickstart -k (signal-based reload)

Operates against the launchd label that maps to ``$ESRD_HOME``:

    ESRD_HOME=~/.esrd       → com.ezagent.esrd       (prod)
    ESRD_HOME=~/.esrd-dev   → com.ezagent.esrd-dev   (dev)

When invoked from `esr.sh --env=...`, ESRD_HOME is set up-stream;
this module reads ``esrd_home()`` and derives the label.
"""
from __future__ import annotations

import os
import subprocess

import click

from esr.cli.paths import esrd_home


def _label_for_home() -> str:
    """Map current ESRD_HOME to its launchd label.

    Conventions match ``scripts/launchd/com.ezagent.esrd*.plist``
    placeholders. Operators with custom paths can override via
    ``ESR_LAUNCHD_LABEL`` env var.
    """
    explicit = os.environ.get("ESR_LAUNCHD_LABEL")
    if explicit:
        return explicit

    home = esrd_home()
    home_str = str(home)
    if home_str.endswith("/.esrd-dev") or home_str.endswith(".esrd-dev"):
        return "com.ezagent.esrd-dev"
    return "com.ezagent.esrd"


def _service_target() -> str:
    """Return ``gui/<uid>/<label>`` for launchctl operations."""
    uid = os.getuid()
    return f"gui/{uid}/{_label_for_home()}"


def _run(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


@click.group()
def daemon() -> None:
    """Manage the esrd background daemon (start / stop / restart / status)."""


@daemon.command("status")
def daemon_status() -> None:
    """Show whether esrd is running, with pid + label.

    Reads ``launchctl list <label>`` for the active state. Exit 0
    when running, 1 when stopped.
    """
    label = _label_for_home()
    result = _run(["launchctl", "list", label])

    if result.returncode != 0:
        click.echo(f"esrd ({label}) is not loaded")
        click.echo(f"  ESRD_HOME={esrd_home()}")
        click.echo("  start:  esr daemon start")
        raise SystemExit(1)

    pid = "-"
    last_exit = "-"
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith('"PID"'):
            pid = line.split("=", 1)[-1].strip().rstrip(";").strip()
        elif line.startswith('"LastExitStatus"'):
            last_exit = line.split("=", 1)[-1].strip().rstrip(";").strip()

    if pid != "-" and pid != "":
        click.echo(f"esrd ({label}) is RUNNING")
        click.echo(f"  pid: {pid}")
        click.echo(f"  ESRD_HOME: {esrd_home()}")
        click.echo(f"  last exit status: {last_exit}")
    else:
        click.echo(f"esrd ({label}) is loaded but not running")
        click.echo(f"  last exit status: {last_exit}")
        raise SystemExit(1)


@daemon.command("start")
def daemon_start() -> None:
    """Bring up esrd via launchctl bootstrap.

    Idempotent — if already loaded + running, it's a no-op (launchctl
    returns "service already loaded" which we report cleanly). If
    loaded but stopped, this sends ``kickstart``.
    """
    label = _label_for_home()
    target = _service_target()

    # First check if already loaded
    listing = _run(["launchctl", "list", label])
    if listing.returncode == 0:
        # Already loaded; kickstart it (handles the "loaded but stopped" case)
        result = _run(["launchctl", "kickstart", target])
        if result.returncode == 0:
            click.echo(f"esrd ({label}) started")
            return
        click.echo(f"failed to kickstart {label}: {result.stderr.strip()}", err=True)
        raise SystemExit(1)

    # Not loaded — bootstrap from the plist
    plist = os.path.expanduser(f"~/Library/LaunchAgents/{label}.plist")
    if not os.path.isfile(plist):
        click.echo(
            f"plist not installed: {plist}\n"
            f"  install via scripts/launchd/install-launchd.sh first",
            err=True,
        )
        raise SystemExit(2)

    result = _run(["launchctl", "bootstrap", f"gui/{os.getuid()}", plist])
    if result.returncode != 0:
        click.echo(f"failed to bootstrap {label}: {result.stderr.strip()}", err=True)
        raise SystemExit(1)

    click.echo(f"esrd ({label}) started")


@daemon.command("stop")
def daemon_stop() -> None:
    """Stop esrd via launchctl bootout.

    Bootout signals the daemon process and removes the plist from
    the launchd registry. Use ``esr daemon start`` to bring it back.
    """
    label = _label_for_home()
    target = _service_target()

    result = _run(["launchctl", "bootout", target])
    if result.returncode != 0:
        # Already stopped is OK; some launchctl versions exit non-zero
        # for "no such service" — distinguish via stderr.
        stderr = result.stderr.strip().lower()
        if "no such" in stderr or "not loaded" in stderr or "not found" in stderr:
            click.echo(f"esrd ({label}) was not loaded")
            return
        click.echo(f"failed to stop {label}: {result.stderr.strip()}", err=True)
        raise SystemExit(1)

    click.echo(f"esrd ({label}) stopped")


@daemon.command("restart")
def daemon_restart() -> None:
    """Restart esrd via launchctl kickstart -k.

    `kickstart -k` sends SIGTERM to the running process and waits for
    launchd to respawn it. Faster than stop+start (no plist re-load),
    and KeepAlive=true on our plist guarantees the respawn.
    """
    label = _label_for_home()
    target = _service_target()

    result = _run(["launchctl", "kickstart", "-k", target])
    if result.returncode != 0:
        click.echo(f"failed to restart {label}: {result.stderr.strip()}", err=True)
        raise SystemExit(1)

    click.echo(f"esrd ({label}) restarted")


@daemon.command("doctor")
def daemon_doctor() -> None:
    """Health snapshot.

    PR-21β 2026-04-30: --cleanup-orphans flag removed. Subprocess
    lifecycle is now BEAM-bound via erlexec; orphan accumulation
    is no longer possible.
    """
    from esr.cli.runtime_bridge import RuntimeUnreachable, call_runtime

    label = _label_for_home()

    def _data(reply: dict) -> dict:
        # call_runtime returns a phx_reply envelope:
        #   {"status": "ok", "response": {"data": {...}}}
        if reply.get("status") != "ok":
            raise RuntimeError(f"runtime returned non-ok: {reply!r}")
        return (reply.get("response") or {}).get("data") or {}

    try:
        data = _data(call_runtime(topic="cli:daemon/doctor", payload={}))

        click.echo(f"🩺 esrd ({label}) health")
        click.echo(f"  pid:                 {data.get('esrd_pid', '-')}")
        click.echo(f"  users loaded:        {data.get('users_loaded', 0)}")
        click.echo(f"  workspaces loaded:   {data.get('workspaces_loaded', 0)}")
        click.echo(f"  workers tracked:     {data.get('workers_tracked', 0)}")

        workers = data.get("workers") or []
        if workers:
            click.echo("  worker subprocess detail:")
            for w in workers:
                click.echo(
                    f"    {w.get('kind', '?'):8s}  "
                    f"{w.get('name', '?'):24s}  "
                    f"{w.get('id', '?'):24s}  "
                    f"pid={w.get('pid', '-')}"
                )

        click.echo()
        click.echo("Tips:")
        click.echo("  - Sweep orphan subprocesses: esr daemon doctor --cleanup-orphans")
        click.echo("  - Lifecycle: esr daemon {start|stop|restart}")
    except RuntimeUnreachable:
        click.echo(
            f"esrd ({label}) is not reachable on its WS port.\n"
            f"  start: esr daemon start",
            err=True,
        )
        raise SystemExit(1)
