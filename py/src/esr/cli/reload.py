"""``esr reload`` CLI wrapper — submits a ``reload`` admin command to
the queue (spec §5.2, plan DI-12 Task 27).

Thin shim over ``esr admin submit reload`` so operators can type a
short verb after merging a breaking change into dev / prod::

    esr reload
    esr reload --acknowledge-breaking
    esr reload --dry-run

The underlying primitive (``cli.admin.admin_submit``) handles YAML file
writing, atomic ``.tmp`` + rename, and the optional ``--wait`` polling
loop — this module only maps flags to ``key=value`` argument pairs and
re-invokes the primitive via ``ctx.invoke``.
"""
from __future__ import annotations

import click


@click.command("reload")
@click.option(
    "--acknowledge-breaking",
    is_flag=True,
    default=False,
    help="Confirm awareness of breaking commits since last reload "
         "(required when post-merge hook flagged ``!:`` or "
         "``BREAKING CHANGE:`` footer in the merge range).",
)
@click.option(
    "--dry-run",
    is_flag=True,
    default=False,
    help="Skip the launchctl kickstart; the dispatcher records the "
         "scan result but does not actually reload.",
)
@click.option(
    "--wait/--no-wait",
    default=True,
    help="Block until the dispatcher writes the completed / failed "
         "counterpart (default: --wait). Pass --no-wait for fire-and-"
         "forget submission (e.g. from CI / hooks).",
)
@click.option(
    "--timeout",
    default=60,
    show_default=True,
    help="Wait timeout in seconds (ignored when --no-wait).",
)
def reload(
    acknowledge_breaking: bool, dry_run: bool, wait: bool, timeout: int
) -> None:
    """Reload the current esrd via launchctl kickstart.

    Run ``esr reload`` (or ``esr reload --acknowledge-breaking``) after
    merging changes into ``main`` so the always-on prod / dev esrd
    picks up new patterns, handlers, or config. The admin dispatcher
    scans ``git log <last_reload>..HEAD`` for breaking-change markers
    and refuses to kickstart until the operator acknowledges them.
    """
    # Reuse the queue-writer primitive via ctx.invoke — single source of
    # truth for file format, atomic rename, and wait-loop semantics.
    from esr.cli.admin import admin_submit

    args: list[str] = []
    if acknowledge_breaking:
        args.append("acknowledge_breaking=true")
    if dry_run:
        args.append("dry_run=true")

    ctx = click.get_current_context()
    ctx.invoke(
        admin_submit,
        kind="reload",
        arg=tuple(args),
        wait=wait,
        timeout=timeout,
    )
