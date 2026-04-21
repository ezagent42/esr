"""``esr notify`` CLI wrapper — submits a ``notify`` admin command to
the queue (spec §7.7 / §8.2, plan DI-13 Task 29).

Thin shim over ``esr admin submit notify`` so the post-merge git hook
(and any scripted caller) can shell a short command to send a DM via
the ESR 开发助手 bot::

    esr notify --type=breaking --since=abc123 --details='<commits>'
    esr notify --type=reload-complete
    esr notify --type=info --to=ou_XXXX --details='hello'

Flow mirrors ``esr reload``: this module only maps flags to ``key=value``
argument pairs and re-invokes ``cli.admin.admin_submit`` via
``ctx.invoke``. The underlying primitive owns YAML serialisation,
atomic ``.tmp`` + rename, and the optional ``--wait`` polling loop.

Notes:
  - ``--wait`` is forced to ``False`` by default because the primary
    caller is a git hook — blocking the shell after a ``git merge``
    on the admin dispatcher's round-trip would be hostile UX, and the
    hook already swallows errors (``|| true`` in spec §8.2).
  - ``--to`` is optional; when omitted, the dispatcher fans out to the
    admin list declared in the runtime config (spec §7.7).
"""
from __future__ import annotations

import click


@click.command("notify")
@click.option(
    "--type",
    "type_",
    required=True,
    type=click.Choice(["breaking", "info", "reload-complete"]),
    help="Notification kind: ``breaking`` (post-merge hook), ``info`` "
         "(generic operator message), ``reload-complete`` (emitted by "
         "the post-boot dispatcher after launchctl kickstart).",
)
@click.option(
    "--since",
    default=None,
    help="Git SHA the commit range starts from (pre-merge HEAD for "
         "``breaking``; last_reload SHA for ``reload-complete``).",
)
@click.option(
    "--details",
    default=None,
    help="Free-text body appended to the DM; the post-merge hook "
         "passes the raw ``git log`` output here (multi-line ok).",
)
@click.option(
    "--to",
    default=None,
    help="Target Feishu open_id; omit to fan out to all admins listed "
         "in the runtime admin-principal config.",
)
def notify(
    type_: str,
    since: str | None,
    details: str | None,
    to: str | None,
) -> None:
    """Send a notification via the ESR 开发助手 bot.

    Writes a ``kind=notify`` admin command to the queue; the
    ``Esr.Admin.Commands.Notify`` handler on the dispatcher side
    composes the DM and submits it through the existing Feishu adapter
    (spec §7.7). Fire-and-forget by default — see module docstring for
    why ``--wait`` is not exposed here.
    """
    # Reuse the queue-writer primitive via ctx.invoke — single source of
    # truth for file format, atomic rename, and wait-loop semantics.
    from esr.cli.admin import admin_submit

    args: list[str] = [f"type={type_}"]
    if since:
        args.append(f"since={since}")
    if details:
        args.append(f"details={details}")
    if to:
        args.append(f"to={to}")

    ctx = click.get_current_context()
    ctx.invoke(
        admin_submit,
        kind="notify",
        arg=tuple(args),
        wait=False,
        timeout=10,
    )
