"""``esr adapter feishu`` subgroup — L3 interactive wizard (plan DI-8 Task 15).

The wizard's job is to take an operator from "empty Feishu developer
backend" to "registered ESR adapter" in a single terminal session:

1. Print a pre-filled ``backend_oneclick`` launcher URL with ESR's
   canonical scope + event-subscription list encoded as query params.
   The operator opens the URL in a browser, reviews, and one-click
   creates the app on open.feishu.cn.
2. Prompt for the freshly-minted ``App ID`` and ``App Secret`` (the
   latter via ``hide_input`` so it never echoes into scrollback).
3. Validate the pair locally via ``tenant_access_token/internal`` —
   any 4xx shape (wrong app_id, secret mismatch) surfaces immediately
   as "Feishu 凭证验证失败" before we dirty the admin queue.
4. On success, rewrite ``ESRD_HOME`` according to ``--target-env``
   (``prod`` → ``~/.esrd``, ``dev`` → ``~/.esrd-dev``) so the submission
   lands in the right environment's ``admin_queue/pending/`` directory,
   and submit ``register_adapter`` through the existing ``esr admin
   submit`` primitive. The admin Dispatcher (Task 16) is responsible
   for the actual ``adapters.yaml`` / ``.env.local`` writes + runtime
   ``ensure_adapter`` call — this CLI stops at "command queued".

Design note: the wizard never talks to the runtime directly. It uses
the admin queue so the whole flow audits cleanly (submitted_by,
submitted_at, redacted secrets) and survives a dead esrd — once esrd
comes back, the Watcher will discover the pending command and finish
the registration.
"""
from __future__ import annotations

import os
import sys
from urllib.parse import quote

import click

# Canonical ESR scope set — keep in sync with the capability matrix in
# spec §5.3. ``im:message.file:readonly`` is the narrowest read-only
# surface that still supports message-body attachments.
_SCOPES: tuple[str, ...] = (
    "im:message",
    "im:message:send_as_bot",
    "im:chat",
    "contact:user.base:readonly",
    "im:message.file:readonly",
)

# Event subscriptions required for the default feishu-app-session
# topology (receive + p2p-create + reaction). Keep sorted by topic tree
# so the launcher displays them grouped.
_EVENTS: tuple[str, ...] = (
    "im.message.receive_v1",
    "im.chat.access_event.bot.p2p_chat_create_v1",
    "im.message.reaction.created_v1",
)

# Map ``--target-env`` → filesystem home. Public (no leading underscore
# would be cleaner, but tests monkey-patch this dict and the underscore
# prefix matches the rest of the module's module-private convention).
# ``setitem`` patches survive the wizard's own ``os.environ`` rewrite
# because the wizard reads through this dict to pick the override.
_HOME_MAP: dict[str, str] = {
    "prod": os.path.expanduser("~/.esrd"),
    "dev": os.path.expanduser("~/.esrd-dev"),
}


@click.group()
def feishu() -> None:
    """Feishu adapter commands."""


@feishu.command("create-app")
@click.option("--name", required=True, help="Human-readable app name shown in Feishu backend.")
@click.option(
    "--target-env",
    type=click.Choice(["prod", "dev"]),
    required=True,
    help=(
        "Which ESR environment receives the register_adapter command "
        "(prod → ~/.esrd, dev → ~/.esrd-dev)."
    ),
)
@click.option(
    "--wait/--no-wait",
    default=True,
    help="Wait for the admin Dispatcher to complete the registration (default) or fire-and-forget.",
)
@click.option(
    "--timeout",
    default=60,
    help="With --wait, seconds to poll admin_queue/completed before giving up.",
)
def create_app(name: str, target_env: str, wait: bool, timeout: int) -> None:
    """Interactive wizard: prefilled URL → creds → validate → queue submit.

    The flow is strictly linear — no retries, no interactive corrections.
    If validation fails, re-run the command; this keeps the wizard tiny
    enough to audit at a glance and makes the failure mode trivial to
    test (single call to ``_validate_creds``).
    """
    scopes_q = quote(",".join(_SCOPES))
    events_q = quote(",".join(_EVENTS))
    name_q = quote(name)
    url = (
        "https://open.feishu.cn/page/launcher?from=backend_oneclick"
        f"&name={name_q}&scopes={scopes_q}&events={events_q}"
    )

    click.echo("")
    click.echo("1. 打开这个 URL 在 Feishu 后台创建 app:")
    click.echo(f"   {url}")
    click.echo("")
    click.echo("2. 完成创建后，从后台复制 App ID + App Secret:")
    click.echo("")

    app_id = click.prompt("App ID").strip()
    app_secret = click.prompt("App Secret", hide_input=True).strip()

    if not _validate_creds(app_id, app_secret):
        click.echo(
            "Feishu 凭证验证失败 (tenant_access_token 4xx). "
            "检查 App ID / App Secret 后重试。",
            err=True,
        )
        sys.exit(1)

    click.echo("凭证验证通过 — submitting register_adapter ...")

    # --target-env rewrites ESRD_HOME so admin_submit writes to the
    # correct environment's pending/ directory. The test suite patches
    # _HOME_MAP to redirect to tmp_path.
    os.environ["ESRD_HOME"] = _HOME_MAP[target_env]

    # Reuse the existing admin-queue primitive — import lazily so the
    # module-level click wiring doesn't pull admin.py (and its ULID dep)
    # into every CLI import.
    from esr.cli.admin import admin_submit

    ctx = click.get_current_context()
    ctx.invoke(
        admin_submit,
        kind="register_adapter",
        arg=(
            "type=feishu",
            f"name={name}",
            f"app_id={app_id}",
            f"app_secret={app_secret}",
        ),
        wait=wait,
        timeout=timeout,
    )


def _validate_creds(app_id: str, app_secret: str) -> bool:
    """Return True iff ``app_id`` + ``app_secret`` produce a 200 from
    Feishu's ``auth/v3/tenant_access_token/internal`` endpoint.

    Any exception (network, SDK shape mismatch, malformed response) is
    treated as a failure — the wizard surfaces a single generic
    "验证失败" message regardless of the root cause because surfacing
    SDK internals to the operator would leak noise without actionable
    signal. They are expected to re-run after fixing the creds.
    """
    try:
        import lark_oapi as lark
        from lark_oapi.api.auth.v3 import (
            InternalTenantAccessTokenRequest,
            InternalTenantAccessTokenRequestBody,
        )

        client = (
            lark.Client.builder()
            .app_id(app_id)
            .app_secret(app_secret)
            .build()
        )
        req = (
            InternalTenantAccessTokenRequest.builder()
            .request_body(
                InternalTenantAccessTokenRequestBody.builder()
                .app_id(app_id)
                .app_secret(app_secret)
                .build()
            )
            .build()
        )
        resp = client.auth.v3.tenant_access_token.internal(req)
        return bool(resp.success())
    except Exception:
        return False
