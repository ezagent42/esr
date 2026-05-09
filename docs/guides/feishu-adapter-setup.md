# Feishu adapter setup

**Audience:** operator wiring a new Feishu app to a running `esrd`
instance. You already know how to run `esr exec ...` commands and
have an admin esr user — see
[`operator-bootstrap-journey.md`](operator-bootstrap-journey.md) for
the zero-to-admin journey.

This doc focuses on Feishu-side specifics: console setup, adapter
registration, multi-app deployment, hot config update, and
troubleshooting.

## Overview

The Feishu adapter is a Python sidecar process — `feishu_adapter_runner`
— spawned by `Esr.WorkerSupervisor` when an adapter instance is
registered. It connects to esrd via WebSocket on the
`/adapter_hub/socket/websocket` endpoint and to Feishu via Lark's
WebSocket long-connection client (`lark_oapi.ws.Client`).

```
+-----------+    Lark WS long-connection    +-----------+
|  Feishu   | <----------------------------> | sidecar   |
|  servers  |    (outbound from sidecar)     | (Python)  |
+-----------+                                +-----+-----+
                                                   ^
                                                   | WS to /adapter_hub
                                                   v
                                             +-----+-----+
                                             |  esrd     |
                                             |  (Elixir) |
                                             +-----------+
```

Because the transport is long-connection (sidecar dials Feishu, not
the other way around), **no public callback URL is required for the
default setup**. This matters: you don't need to expose esrd or the
sidecar to the public internet, and Tailscale-only deployments work.

## Feishu console setup

In the Feishu developer console (<https://open.feishu.cn>):

1. **Create the app** (Developer Console → "Create app" → "Custom app"
   or your tenancy's equivalent). Copy `app_id` (starts with `cli_`)
   + `app_secret`. Never commit the secret to a repo.
2. **Subscribe to events.** Find the event subscription tab — recent
   UIs label it "事件与回调" / "Events & callbacks"; older versions
   may differ.
   - Choose "WebSocket" / "long-connection" mode if the console
     offers a transport selector.
   - Subscribe to `im.message.receive_v1` at minimum; add others as
     your topology requires (reaction add/delete, message edit, etc.).
   - **No public callback URL is required** for long-connection mode.
     If your tenancy only supports HTTP push, see
     [Troubleshooting → HTTP-callback transport](#http-callback-transport).
3. **Grant bot permissions.** Minimum:
   - `im:message` — read messages
   - `im:message:send_as_bot` — reply as the bot
   - `im:resource` — fetch images / files (multimedia protocol)

   Add as needed: `im:chat` / `im:chat:readonly`,
   `contact:user.id:readonly`, `im:message.reaction`, etc.
4. **Add the bot to your chats** from the bot settings.
5. **Publish the app** — internal use is enough for most tenancies.

> Feishu console UI labels shift between versions. When this doc says
> "the event subscription tab", interpret loosely — the underlying
> concepts (events, OAuth scopes, distribution) are stable.

## esrd-side registration

```bash
esr exec register_adapter --type=feishu --name=esr_helper \
    --app_id=cli_xxx --app_secret=xxx
```

| Arg | Meaning |
|---|---|
| `--type=feishu` | Adapter implementation. Only `feishu` is wired through `register_adapter` today. |
| `--name=<n>` | Instance name; becomes the directory basename under `adapters/<n>/`. Must be unique; must not start with `_` (reserved prefix). Naming convention: `<purpose>_<env>` (e.g. `esr_helper`, `esr_helper_dev`). |
| `--app_id=cli_xxx` | Feishu app id from the console. |
| `--app_secret=xxx` | Feishu app secret. **Persisted to `adapters/<name>/config.yaml`** — make sure file permissions are restrictive (`0600` by default). |

On success:

1. A fresh per-instance directory is written at
   `<ESRD_HOME>/<instance>/adapters/esr_helper/config.yaml` (yaml-
   layout-v2 — see spec `docs/superpowers/specs/2026-05-09-yaml-layout-
   v2-per-thing-directories.md`):

   ```yaml
   type: feishu
   config:
     app_id: cli_xxx
     app_secret: xxx
   ```

   Both fields live in the `config:` block — pre-`fix/register-adapter-
   app-secret`, only `app_id` was persisted and the sidecar crash-
   looped with `app_secret missing from AdapterConfig` on every
   restart. The fix ensures both round-trip through `register_adapter`
   and are available on future esrd reboots. Per yaml-layout-v2 spec
   § 4.7, a feishu row missing `app_secret` will fail-loud and skip
   the spawn at boot — there is no longer a `plugins.yaml` fallback.

2. The sidecar is spawned via `Esr.WorkerSupervisor.ensure_adapter/4`
   — the same path `Esr.Application.restore_adapters_from_disk/1` uses
   at boot, so registration and a fresh boot reach the same state.

3. Response: `{"adapter_id": "esr_helper", "running": true}`.

After registration, `esr exec actor_list` shows the sidecar peer.
If it doesn't, see [Troubleshooting](#troubleshooting).

## Multi-app deployment

You can register multiple Feishu adapters on a single esrd. Each gets
its own sidecar process and its own Lark WS connection:

```bash
esr exec register_adapter --type=feishu --name=helper_a \
    --app_id=cli_aaa --app_secret=secret_aaa

esr exec register_adapter --type=feishu --name=helper_b \
    --app_id=cli_bbb --app_secret=secret_bbb
```

`adapters/` tree after both calls (yaml-layout-v2):

```
adapters/
├── helper_a/config.yaml
└── helper_b/config.yaml
```

Each `config.yaml`:

```yaml
# adapters/helper_a/config.yaml
type: feishu
config:
  app_id: cli_aaa
  app_secret: secret_aaa
```

```yaml
# adapters/helper_b/config.yaml
type: feishu
config:
  app_id: cli_bbb
  app_secret: secret_bbb
```

**Each app has its own `open_id` namespace.** A human bound to
`helper_a` via `feishu_bind --name=linyilun --feishu_user_id=ou_aaa`
must **also** bind to `helper_b` separately:

```bash
esr exec feishu_bind --name=linyilun --feishu_user_id=ou_bbb
```

`users.yaml` ends up with:

```yaml
users:
  linyilun:
    feishu_ids:
      - ou_aaa
      - ou_bbb
```

Inbound events from either app match this user; cross-app reply is
handled by the `mcp__esr-channel__reply` tool's explicit `app_id` arg
(see `docs/dev-guide.md` § Multi-app + cross-app reply).

## Hot config update

If you need to rotate `app_secret` (or fix any other config field)
after the adapter is registered:

1. Edit `<ESRD_HOME>/<instance>/adapters/<name>/config.yaml` directly.
   Update the `config.app_secret` field.
2. Restart the daemon so `Esr.Application.restore_adapters_from_disk/1`
   re-reads the file and respawns the sidecar with the new config.
   For the launchctl-managed dev daemon:

   ```bash
   launchctl kickstart -k gui/$UID/com.ezagent.esrd-dev
   ```

   For the manual `scripts/esrd.sh` path:

   ```bash
   bash scripts/esrd.sh stop  --instance=default
   bash scripts/esrd.sh start --instance=default
   ```

> **Why no live reload?** The Feishu adapter holds a long-lived Lark
> WS connection bound to `(app_id, app_secret)` at construction time.
> Live-rotating the secret without rebuilding the connection is more
> complex than just respawning, and the respawn path is already well-
> tested via the boot restore flow. Live secret rotation may land in
> a future spec.

> Re-running `register_adapter` with the same `--name=` returns
> `already_exists` (the per-thing layout treats `add` as create-only,
> not upsert). To rotate via CLI: `/adapter:remove name=<n>` then
> `register_adapter` with the new secret. Hand-edit
> `adapters/<n>/config.yaml` + restart works too when CLI is unavailable.

## Troubleshooting

### `app_secret missing from AdapterConfig` (sidecar crash loop)

The `adapters/<name>/config.yaml` entry for this instance lacks
`config.app_secret`. Either:

- The entry was written by a buggy `register_adapter` (pre
  `fix/register-adapter-app-secret`). Per yaml-layout-v2 (spec § 4.7)
  the daemon now fail-loud-skips the spawn for this case at boot —
  check the boot log for the `register_adapter` hint. Run
  `/adapter:remove name=<n>` then re-run `register_adapter` with the
  secret, or hand-edit `adapters/<n>/config.yaml` + restart.
- The entry was hand-written and the secret was forgotten. Add it.

### `/help` no response in Feishu

Check, in this order:

1. **Is the sidecar running?** `esr exec actor_list | grep feishu`.
   If absent or repeatedly restarting, check the logs at
   `<ESRD_HOME>/<instance>/logs/`. Common causes: bad `app_id` /
   `app_secret`, missing Feishu permissions.
2. **Is the bot in your chat?** In Feishu, check chat members. If
   the bot isn't there, add it from the app config.
3. **Are events being received?** Tail the sidecar log — every
   inbound message logs at debug/info level. Silent log = events
   not arriving = (a) wrong event subscription mode in the console,
   or (b) bot lacks `im:message` permission.
4. **Is the slash-route loaded?** `esr exec describe-slashes |
   grep '/help'`. If absent, the runtime didn't load the default
   slash routes — check `<ESRD_HOME>/<instance>/logs/` for boot
   errors.

### `actor_list` shows sidecar but no message ever arrives

The sidecar's WS to esrd is up but the Lark WS is silently dead.
Causes:

- `app_secret` rotated on the Feishu side; sidecar's connect handshake
  fails. Re-run `register_adapter` with the new secret.
- Feishu app revoked / disabled. Check the developer console.
- Bot kicked from the chat. Re-add and try again.

### HTTP-callback transport

Some Feishu tenancies (or compliance-locked deployments) only allow
HTTP push for events. The default `feishu_adapter_runner` setup uses
the long-connection transport — if you need HTTP push instead, you'll
need to:

1. Stand up a public-reachable HTTP endpoint (the sidecar would have
   to expose its own listener; today this is not provided
   out-of-the-box).
2. Configure the Feishu console's callback URL to point at that
   endpoint.
3. Add code to the sidecar to ingest HTTP push payloads (the current
   sidecar only consumes WS payloads from `lark_oapi.ws.Client`).

This path is not currently shipped. If you need it, file an issue —
or use the WebSocket transport which is the default.

> **Tailscale note:** the Tailscale IP `100.64.0.27` is reachable only
> from Tailnet members. Feishu's servers are not on your Tailnet, so
> a public HTTP callback URL pointing at a Tailscale IP cannot work.
> Use the long-connection transport (default) or expose a real public
> endpoint.

### Sidecar can't reach esrd

The sidecar dials esrd at the URL embedded in its spawn config —
typically `ws://127.0.0.1:<port>/adapter_hub/socket/websocket?vsn=2.0.0`,
where `<port>` comes from `EsrWeb.Endpoint`'s `:http` config (4001 by
default for dev, possibly different for prod). If you've set a
non-default port and the sidecar can't connect:

- Confirm `esrd.port` on disk matches your Phoenix config.
- Confirm the sidecar log's connect target matches.
- Re-register the adapter so a fresh spawn picks up the right URL.

### Re-registering an adapter

Per yaml-layout-v2, `register_adapter` is **create-only**: re-running
with the same `--name` returns `already_exists`. To rotate or fix:

```bash
esr exec adapter_remove --instance_id=<name>
esr exec register_adapter --type=feishu --name=<name> \
    --app_id=<id> --app_secret=<new_secret>
```

This applies for any of:

- Rotating `app_secret`
- Fixing a typo in `app_id`
- Switching the instance to a different Feishu app entirely

Hand-editing `adapters/<name>/config.yaml` + restart works too when
CLI is unavailable.

## References

- [`operator-bootstrap-journey.md`](operator-bootstrap-journey.md) —
  zero-to-admin journey + identity model.
- `docs/dev-guide.md` § Multi-app + cross-app reply — how routes
  work with multiple registered Feishu apps.
- `runtime/lib/esr/commands/register_adapter.ex` — source of truth
  for what `register_adapter` persists + spawns.
- `adapters/feishu/src/esr_feishu/adapter.py` — Python adapter
  implementation, including the Lark WS connection setup.
- Relevant specs:
  - `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md` —
    image + file inbound/outbound.
  - `docs/superpowers/specs/2026-05-08-plugin-command-registration.md` —
    how `feishu_bind` and `feishu_unbind` are declared by the feishu
    plugin manifest.
