# Operator bootstrap journey

**Audience:** operator running a fresh-install esr daemon (`esrd`) for
the first time. You know basic Linux + Feishu admin concepts, you've
already created a Feishu app in the Feishu developer console, and you
have its `app_id`, `app_secret`, plus your own Feishu `open_id` ready.

By the end of this guide you'll have:

- a running `esrd` instance
- yourself registered as the canonical esr user (auto-promoted to admin)
- one Feishu adapter wired up and streaming events
- your Feishu account bound to your esr user
- a `/claude_code:tui` URL you can click in Feishu chat to open a
  browser-based terminal for a Claude Code agent

**No env-var hacks, no yaml hand-editing.**

> **Sister doc:** [`feishu-adapter-setup.md`](feishu-adapter-setup.md)
> covers the Feishu side in more depth (multi-app, hot config update,
> troubleshooting).

## Quick start

If you already have a daemon running and just want the copy-paste
recipe:

```bash
# In the repo root
alias esr-dev='ESRD_HOME=$HOME/.esrd-dev ESR_INSTANCE=default ./runtime/esr'

# 1. Start the daemon (skip if launchctl already has it running)
bash scripts/esrd.sh start --instance=default

# 2. Create yourself — first user is auto-promoted to admin
esr-dev exec user_add --name=linyilun

# 3. Register a Feishu adapter (app_id + app_secret from Feishu console)
esr-dev exec register_adapter --type=feishu --name=esr_helper \
    --app_id=cli_xxx --app_secret=xxx

# 4. Bind your Feishu open_id to your esr user
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_xxx

# 5. From Feishu chat with the bot:
#    /session:new
#    /agent:add type=cc name=esr-developer
#    /claude_code:tui name=esr-developer
#    → click the URL → browser TUI opens on your CC session
```

**What this does (atomic):** writes `~/.esrd-dev/default/adapters/<name>/config.yaml`,
spawns the Python sidecar, AND spawns the Elixir-side `FeishuAppAdapter`
peer that handles inbound Feishu events. All three happen in one call —
no `esr exec adapter_refresh` follow-up needed.

That's the whole journey. The rest of this doc explains each step,
the underlying identity model, and what to do when something breaks.

## Pre-requisites

| Requirement | Where to get it |
|---|---|
| Feishu developer console app | <https://open.feishu.cn> — create app, copy `app_id` (starts with `cli_`) and `app_secret` |
| Feishu bot in your chat(s) | Add the bot from your app's "Add to chat" config; the bot must be a member of any chat where you want to drive sessions |
| Your Feishu `open_id` | Per-app value (`ou_xxx`). One way: send any message to the bot and check the inbound event payload, or query Feishu's user-info API with the app's token |
| `claude` CLI | [Claude Code installation](https://docs.claude.com/claude-code) — required to launch `cc` agents |
| `esrd` installed | Either built locally (`cd runtime && mix escript.build`) or installed via `mix escript.install` |

The `runtime/esr` escript is the operator's CLI front-end. It speaks
to `esrd` via the admin queue (file-based, under
`<ESRD_HOME>/<instance>/admin_queue/`), so the daemon must be running
for `esr exec ...` to make progress.

## Step-by-step (the 12 steps)

### 1. Start the daemon

```bash
# Launchctl-managed (recommended for dev)
ESRD_HOME=$HOME/.esrd-dev launchctl load -w \
    scripts/launchd/com.ezagent.esrd-dev.plist

# Or manual foreground start
ESRD_HOME=$HOME/.esrd-dev bash scripts/esrd.sh start --instance=default
```

State lives under `$ESRD_HOME/default/`: `esrd.pid`, `esrd.port`,
`users.yaml`, `capabilities.yaml`, `adapters/<name>/config.yaml`
(per-instance — see yaml-layout-v2 spec
`docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md`),
`operator.json` (written by step 2), and the
`admin_queue/{pending,completed,failed}/` submission queue.

Set up an alias so every CLI invocation points at this instance:

```bash
alias esr-dev='ESRD_HOME=$HOME/.esrd-dev ESR_INSTANCE=default ./runtime/esr'
```

### 2. First `user_add` — the bootstrap sentinel fires

```bash
esr-dev exec user_add --name=linyilun
```

Three things happen on this very first call:

1. **Sentinel.** The CLI has no `operator.json`, so it submits with
   `submitted_by: "system:bootstrap"`. The slash dispatcher
   (`Esr.Entity.SlashHandler`) sees no admin exists and bypasses
   cap-check just for `user_add`. (PR #282; spec
   `docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md`.)
2. **Auto-admin.** `Esr.Commands.User.Add` appends a new principal
   entry to `capabilities.yaml` with caps `["*"]`. (PR #281; audit
   step #2 in `docs/manual-checks/2026-05-08-post-multi-instance-audit.md`.)
3. **`operator.json`** is written with your UUID + name. Subsequent
   CLI calls read it in `Esr.Cli.Main.resolve_submitter/0` and submit
   as you — no env vars needed.

Response:

```
added esr user linyilun (auto-admin: bootstrap)
  id: <uuid-v4>
  default_workspace: linyilun-default
  auto_admin: true
```

After this call, the sentinel is dormant for the life of
`capabilities.yaml` — the `Grants.any_admin?/0 == false` condition
permanently flips to `true`.

### 3. Verify the cap landed

```bash
esr-dev exec cap_list
cat $HOME/.esrd-dev/default/operator.json
```

You should see your principal with `capabilities: ["*"]` and the
operator pointer:

```json
{ "schema_version": 1, "principal_id": "<your-uuid>",
  "name": "linyilun", "set_at": "...", "set_by": "user_add" }
```

### 4. Register the Feishu adapter

```bash
esr-dev exec register_adapter --type=feishu --name=esr_helper \
    --app_id=cli_xxx --app_secret=xxx
```

This writes a fresh per-instance directory at
`adapters/esr_helper/config.yaml` (yaml-layout-v2 — see spec
`docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md`),
with **both** `app_id` and `app_secret` in the `config:` block (pre-
`fix/register-adapter-app-secret`, only `app_id` was persisted and the
sidecar crash-looped with `app_secret missing from AdapterConfig`),
then spawns the Python sidecar (`feishu_adapter_runner`) under
`Esr.WorkerSupervisor`. The sidecar opens a long-lived WebSocket to
`open.feishu.cn` via Lark's `lark_oapi.ws.Client` — **no inbound HTTP
callback URL needed.**

Response: `{"adapter_id": "esr_helper", "running": true}`.

`esr-dev exec actor_list` should now show the sidecar peer. If not,
see [`feishu-adapter-setup.md`](feishu-adapter-setup.md) §
Troubleshooting.

From Feishu chat with the bot, `/adapter:list` confirms the wiring:

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/adapter:list
```

```chat-output
feishu_app_e2e-mock  type=feishu  app_id=e2e-mock  base_url=http://127.0.0.1:<int>  app_secret=***
```

The fence's `base_url` placeholder is the runtime port for the mock
Feishu used in e2e — in a real install you'd see no `base_url=` field
(it defaults to `open.feishu.cn`). The other fields render verbatim
per `Esr.Commands.Adapter.List.format_row/1`.

### 5. Bind your Feishu identity

```bash
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_xxx
```

Appends `ou_xxx` to your `users.yaml` row's `feishu_ids:` list.
Inbound Feishu messages from `ou_xxx` are now recognised as
`linyilun`, and the dispatcher picks up your admin caps.

> **`open_id` is per-app.** The same human has a different `ou_xxx`
> in each Feishu app — Feishu derives it from `(app_id, user)`.
> If you later register a second Feishu adapter, run a second
> `feishu_bind` with the new app's `ou_xxx`.

Operators can also self-bind from inside the chat with `/feishu:bind`
— the dispatcher reads the calling Feishu `open_id` from the inbound
envelope and binds it to the named esr user. Running it a second time
is a safe no-op:

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/feishu:bind name=linyilun
```

```chat-output
ou_test_linyilun already bound to linyilun
```

Note the reply contains the caller's `open_id` (`ou_test_linyilun`
here is the synthetic id used in the e2e fixture; a real install
shows your live `ou_xxx`). See
`runtime/lib/esr/plugins/feishu/commands/bind_user.ex` for the exact
text rendering.

### 6. (Feishu console) verify event subscription

In the Feishu developer console for your app:

- Find the event subscription configuration (label varies by Feishu
  version — recent UIs use a tab around "事件与回调" / "Events &
  callbacks"). Make sure the `im.message.receive_v1` event is enabled.
- For the long-connection transport, **no public callback URL is
  required** — the sidecar dials out to Feishu.
- Bot permissions (typical minimum):
  - `im:message` — read messages
  - `im:message:send_as_bot` — reply as the bot
  - `im:resource` — fetch images / files (multimedia protocol)
- Publish the app to internal use so it can join chats; add the bot
  to your target chat(s).

If your tenancy requires HTTP push instead of long-connection, see
[`feishu-adapter-setup.md`](feishu-adapter-setup.md) §
HTTP-callback transport.

### 7-8. (Feishu chat) `/help` and `/doctor`

```
/help
/doctor
```

`/help` lists categorised slashes (Users, Workspace, Sessions, Agents,
PTY, Plugins, Capabilities). `/doctor` runs the meta-system self-
check (dispatcher up, plugins loaded, capabilities readable). If the
bot doesn't respond, see [Common pitfalls](#common-pitfalls) below.

### 8a. `/workspace:new` (optional — only when you want a named workspace)

The auto-created `<username>-default` workspace from step 2 is enough
for most operators, but you may want a named workspace for a specific
project. Create one from chat with `/workspace:new`:

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/workspace:new name=demo
```

```chat-output
ok: %{"action" => "created", "chats" => [%{"app_id" => "feishu_app_e2e-mock", "chat_id" => "oc_mock_single", "kind" => "dm"}], "folders" => [], "id" => "<UUID>", "location" => "esr:<...>/workspaces/demo", "name" => "demo", "owner" => "linyilun"}
```

The chat automatically gets bound to the new workspace as a side
effect (see `chats` in the reply) — subsequent `/session:new` calls
resolve to `demo` via the chat-bound layer of the M-5 fallback chain.

### 9. `/session:new`

```
/session:new name=test-cc
```

Creates a session bound to the current chat. Workspace + agent are
resolved automatically: workspace via the M-5 fallback chain (chat-
current → user-default), agent from the session template's
`agent_def`. With nothing else configured, the auto-elected
`feishu-cc` template fills both in for you — `/session:new
name=<anything>` is the minimum operator gesture once steps 1-5 are
in place.

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/session:new name=test-cc
```

```chat-output capture=session_id
session started: <UUID>
```

This bare-name `/session:new` form is THE regression gate for
2026-05-10: prior to PR #334 the command failed at the legacy
`validate_args(agent, dir)` step with `invalid_args: dir required`
when neither was passed. The fence above will FAIL against any
build that re-introduces that gate (see
`tests/e2e/scenarios/19_session_first_default.sh` for the thin-
wrapper that drives this exact replay in CI).

### 10. `/agent:add`

```
/agent:add type=cc name=esr-developer
```

Spawns a Claude Code agent inside the chat-current session under
`Esr.Scope.AgentSupervisor` with `(CC, PTY) :one_for_all` supervision.
Returns:

```
{ "actor_ids": { "cc": "<uuid>", "pty": "<uuid>" } }
```

`name=` is the operator-facing tag, used by `/claude_code:tui` and
the other agent-reference slashes.

### 11. `/claude_code:tui`

```
/claude_code:tui name=esr-developer
```

Resolves the agent name → PTY actor id, then emits a signed PtySocket
URL. Click it — your browser opens an xterm.js terminal attached to
the agent's PTY. `/claude_code:tui` is a thin shortcut over
`/pty:attach`; if you already have the PTY id from step 10, call
`/pty:attach pty=<uuid>` directly.

### 12. Plain text → CC reply

```
hello — what's the cwd?
```

The session's CC agent receives the message via the `<channel>` tag
prelude and replies via the `mcp__esr-channel__reply` tool. The reply
appears in the same chat. You're done — bookmark the TUI URL to keep
a browser terminal open while you work from Feishu.

## Identity model

Four distinct identity concepts — keep them straight:

| Concept | What | Where | Created by |
|---|---|---|---|
| **esr user** | canonical CLI identity (e.g. `linyilun`); has a UUID v4 | `users.yaml` (one row); `users/<uuid>/user.json` | `esr exec user_add --name=<n>` |
| **Feishu `open_id`** | Feishu-side identity, per-app (`ou_xxx`) | bound into esr user's `feishu_ids:` list in `users.yaml` | `esr exec feishu_bind --name=<n> --feishu_user_id=<ou_xxx>` |
| **Active CLI operator** | which esr user the local `esr` escript submits as | `<ESRD_HOME>/<instance>/operator.json` | written by `user_add` (first run) or `user_switch` |
| **Sentinel `"system:bootstrap"`** | reserved string used as fallback `submitted_by` | embedded in queue envelopes | the CLI's `resolve_submitter/0` when `operator.json` is missing |

**`operator.json` schema:**

```json
{
  "schema_version": 1,
  "principal_id": "<user_uuid>",
  "name": "<username>",
  "set_at": "<iso8601>",
  "set_by": "user_add" | "user_switch" | "manual"
}
```

Read by `Esr.Cli.Main.resolve_submitter/0` on every `esr exec ...`
call. Written by `Esr.Commands.User.Add.maybe_grant_admin/1` (first
user_add) and `Esr.Commands.User.Switch.execute/1`.

**Sentinel safety:** the string `"system:bootstrap"` is rejected by
`Esr.Resource.Capability.FileLoader.validate_entry/1` (can't be
granted in yaml) and by `Esr.Commands.Cap.Grant.execute/1` (can't be
passed at submit time). The bypass logic lives only at the slash-
handler dispatch site, gated on three conditions:

1. `submitted_by == "system:bootstrap"`
2. `kind == "user_add"` (the only allowed kind)
3. `Esr.Resource.Capability.Grants.any_admin?/0 == false`

Any one false → normal cap-check. Once admin exists, condition 3
is permanently false and the sentinel is dormant.

See `docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md` for
the full design.

## Cap model summary

- Capabilities live in `<ESRD_HOME>/<instance>/capabilities.yaml`.
  Each principal entry has `id`, `kind` (`esr_user` or `feishu_user`),
  `capabilities: [...]`, optional `note`.
- `*` is the wildcard — admin. Auto-granted to the first `user_add`.
- All other caps are specific permission strings, e.g.
  `user.manage`, `workspace.create`, `cap.manage`,
  `session:<uuid>/spawn`, `pty:<actor_id>/attach`, `feishu/user-bind`.
- Operators add caps via `esr exec cap_grant principal_id=<uuid>
  permission=<cap>`. The reverse is `cap_revoke`.

A typical second-user setup:

```bash
esr-dev exec user_add --name=alice
# alice gets a UUID but no admin (you already hold *)
esr-dev exec cap_grant --principal_id=<alice-uuid> --permission=workspace.create
esr-dev exec cap_grant --principal_id=<alice-uuid> --permission=session:default/create
```

## Switching users

The active CLI operator is a single `operator.json` per instance.
Switch via:

```bash
esr-dev exec user_switch --name=alice
```

This:

1. Validates the user `alice` exists.
2. Validates the caller has `user.manage` (the sentinel does **not**
   bypass this — switching active user requires admin).
3. Overwrites `operator.json` with `set_by: "user_switch"`.

After the switch, every subsequent `esr exec ...` from this shell
submits as `alice`. To switch back, run `user_switch --name=linyilun`
(or whatever your admin user is).

> Manual override is supported — you can `echo '{...}' > operator.json`
> if you need to script around the CLI. Only `principal_id` and `name`
> are load-bearing; `set_by` is informational.

## Common pitfalls

### `unauthorized` on every CLI command

The dispatcher rejected your envelope's principal:

- `operator.json` missing → run `esr exec user_switch --name=<you>`
  (or a fresh `user_add` if no users exist).
- `operator.json` points at a UUID with no caps → check `cap_list`
  and grant what's missing.
- `operator.json` is malformed JSON → the CLI prints
  `operator.json malformed at <path>; using bootstrap sentinel` to
  stderr. Fix the JSON or delete the file.

### First `user_add` still returns `unauthorized`

All three sentinel bypass conditions must hold (see § Identity model
above). If condition 3 fails, an admin already exists — check
`cap_list`, since a prior boot or env-var seed may have populated
`capabilities.yaml`.

### Plugin install is local-path only

The grammar `/plugin:install <name>` is shipped but operates on
local plugin paths only — there's no remote registry. Built-in
plugins (`feishu`, `claude_code`, etc.) are enabled by default, so
most operators don't need to install anything manually.

### Feishu `open_id` is per-app

A second Feishu adapter means a different `ou_xxx` for the same
human. Bind each separately:

```bash
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_app1_xxx
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_app2_xxx
```

`users.yaml` will list both.

### Old env vars in dev plist / shell rc

- **`ESR_BOOTSTRAP_PRINCIPAL_ID`** — still set in
  `scripts/launchd/com.ezagent.esrd-dev.plist` for back-compat. With
  the sentinel in place this is now **optional** (spec D5 keeps it
  as a complementary boot-time seed; a future PR may deprecate it).
  Don't rely on it in new automation.
- **`ESR_OPERATOR_PRINCIPAL_ID`** — was the pre-PR #282 way to pick a
  submitter. The variable is **no longer read** (spec D3 hard
  cutover). Remove any exports from your shell rc; rely on
  `operator.json` + `esr exec user_switch`.

### Sidecar crash loop after `register_adapter`

If `actor_list` shows the sidecar repeatedly restarting, the
common cause was the pre-fix `register_adapter` bug where
`app_secret` was dropped from the spawn config. With
`fix/register-adapter-app-secret` applied, `adapters/<name>/config.yaml`
carries `config.app_secret` and the sidecar reads it on every restore.
If you registered an adapter on the buggy build, run
`/adapter:remove name=<n>` then re-run `register_adapter`, or
hand-edit `adapters/<name>/config.yaml` and restart the daemon. Per
yaml-layout-v2 (spec § 4.7) the daemon will fail-loud (Logger.error)
and **skip the spawn** for any feishu row missing `app_secret` — no
silent `plugins.yaml` fallback.

## References

- Specs:
  - `docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md` —
    sentinel + `operator.json` + `user_switch` design.
  - `docs/superpowers/specs/2026-05-08-resource-typed-grammar.md` —
    `/agent:*`, `/pty:*`, `/session:*`, `/claude_code:tui` grammar.
- Audit:
  - `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` —
    re-scored 12-step journey baseline.
- Sister doc:
  - `docs/guides/feishu-adapter-setup.md` — Feishu console setup,
    multi-app deployment, hot config, troubleshooting.
- Background:
  - `docs/cookbook.md` — recipe-style snippets.
  - `docs/dev-guide.md` — handler / adapter / pattern authoring.
