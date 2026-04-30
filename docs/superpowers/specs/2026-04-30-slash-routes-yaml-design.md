# Slash Routes Yaml — Design

**Date**: 2026-04-30
**Author**: linyilun (via brainstorm with Claude Opus 4.7)
**Status**: design — subagent review pass 1 complete (2026-04-30); pending user sign-off
**Related**: task #221 (yaml-ify slash command business logic); silent-fail incident discovered 2026-04-30 where `/new-session` from a chat with no live session fell into the SessionRouter auto-create path and was lost (`unknown_agent`).

## Background

ESR's slash command surface lives in three Elixir source files, each carrying a hand-rolled lookup table or case chain:

1. **`Esr.Peers.FeishuAppAdapter`** (`feishu_app_adapter.ex:170-172`):
   ```elixir
   defp inline_bootstrap_slash?(text), do: slash_head(text) in ~w(/help /whoami /doctor)
   defp routed_bootstrap_slash?(text), do: slash_head(text) in ~w(/new-workspace)
   ```
   Two hardcoded string lists deciding whether a slash bypasses the per-session `FeishuChatProxy` (FCP) and routes to `AdminSession`'s `SlashHandler` directly.

2. **`Esr.Peers.SlashHandler.parse_command/1`** + per-command parsers (`slash_handler.ex`):
   A case chain for each known slash, plus bespoke `parse_new_session/1`, `parse_new_workspace/1`, `parse_end_session/1`, `parse_workspace/1` functions. ~200 LOC.

3. **`Esr.Admin.Dispatcher`** (`dispatcher.ex:80, 115`):
   ```elixir
   @required_permissions %{"session_new" => "session:default/create", ...}   # 14 entries
   @command_modules %{"session_new" => Esr.Admin.Commands.Session.New, ...}  # 14 entries
   ```

Adding a new slash command today requires:
- Editing `feishu_app_adapter.ex` to add to one of the bypass lists (or creating per-session FCP routing — high friction)
- Editing `slash_handler.ex` to add a `case` arm + a per-command parse helper
- Editing `dispatcher.ex` to add a permission entry + a module entry
- Compiling, restarting esrd

Today's incident proved this is fragile: `/new-session` was missing from `routed_bootstrap_slash?`, causing it to fall through to the session auto-create path. SessionRouter then failed with `:unknown_agent` because `agents.yaml` lacked the `cc` agent definition. The user saw silent failure (no Feishu reply) and esrd logged a single `[warning]` line that nobody was watching.

## A bigger architectural problem (surfaced during brainstorm)

The SlashHandler is logically *adapter-agnostic* — it reads `envelope["payload"]["text"]`, `envelope["principal_id"]`, etc. — but the *entry path* is leaky:

- `FeishuAppAdapter` decides which slashes go to SlashHandler (Feishu-specific bypass list)
- `FeishuChatProxy` (per-session) historically also routes some slashes
- A future `TelegramAdapter` would need to duplicate that routing logic, OR every adapter would need its own bypass list

If we believe a `/help` from a Telegram bot should produce the same `/help` text via the same SlashHandler code, **the slash entry path itself should be uniform across adapters**. The per-adapter outbound (Feishu directive vs Telegram method vs terminal stdout) is the only platform-specific piece.

## Goals

After this PR ships:

1. **Yaml-driven slash routing.** A new `slash-routes.yaml` declares every slash command's `kind`, `permission`, `command_module`, and arg list. Adding a new slash = adding a yaml entry + writing the command module. No edits to FeishuAppAdapter or SlashHandler or Dispatcher.

2. **Adapter-agnostic SlashHandler entry.** Every adapter's inbound handler does the same thing for slash text: route to `Esr.AdminSession.SlashHandler.dispatch/2` with `reply_to: self()`, then handle `{:reply, text}` reply messages by emitting platform-specific outbound. No adapter knows which slashes exist or what they do.

3. **No FCP slash routing.** `FeishuChatProxy` no longer handles slash commands — its surface is "non-slash messages routed into a CC session." All slash text goes to admin SlashHandler regardless of session existence.

4. **Hot-reload.** `slash-routes.yaml` is watched via FSEvents; edits update the in-memory routing table without esrd restart.

5. **Schema validation at boot.** Bad yaml fails fast with a structured error (which slash, which field, what's wrong). Same fail-fast policy as `capabilities.yaml` / `workspaces.yaml`.

## Non-goals

- Not yaml-ifying argument parsing logic or default-value derivation. The KV parser stays in code (generic, ~30 LOC); bespoke arg manipulation (e.g. PR-21θ's cwd derivation from root + worktree) moves *into the command module's* `execute/1`, not the parser.
- Not yaml-ifying the command module implementations — `Esr.Admin.Commands.*` stay in Elixir.
- Not introducing a slash DSL (e.g. yaml-described conditional rules). YAGNI.
- Not addressing other yaml-ification candidates (sidecar dispatch, permissions registry, defaults, rate-limit windows). Workshops 2 & 3 — see `docs/futures/todo.md`.

## Architecture

### Before

```
Feishu inbound text="/new-session foo"
       ↓
FeishuAppAdapter
       ↓
inline_bootstrap_slash?(text) → false
routed_bootstrap_slash?(text) → false  ← /new-session not in list
       ↓
do_handle_upstream_inbound
       ↓
SessionRegistry.lookup_by_chat_thread → :not_found
       ↓
broadcast {:new_chat_thread, ...}
       ↓
SessionRouter auto-create with agent="cc"
       ↓
agents.yaml lacks "cc" → :unknown_agent → silent log warning
```

### After

```
Feishu inbound text="/new-session foo"
       ↓
FeishuAppAdapter
       ↓
String.starts_with?(text, "/")?
       ↓ yes
AdminSession.SlashHandler.dispatch(envelope, reply_to: self())
       ↓
slash_routes.yaml lookup → {kind: session_new, command_module: ..., permission: ..., args_spec}
       ↓
Generic KV parse → args
       ↓
Cap check (Dispatcher.execute)
       ↓
Esr.Admin.Commands.Session.New.execute/1  (does its own arg validation, cwd derivation, etc.)
       ↓
{:reply, text} sent back to FeishuAppAdapter
       ↓
FeishuAppAdapter.handle_info({:reply, text}, state)
       ↓
{:outbound, %{kind: "reply", args: %{chat_id: ..., text: text}}}
       ↓
Feishu directive on adapter:feishu/<id> → Python adapter → Feishu API
```

The same path for non-slash text:

```
Feishu inbound text="hello CC"
       ↓
FeishuAppAdapter
       ↓
String.starts_with?(text, "/")? no
       ↓
do_handle_upstream_inbound (existing routing through FCP / SessionRouter / etc.)
```

`FeishuChatProxy` no longer sees slash text at all.

## File: `slash-routes.yaml`

Located at `<runtime_home>/slash-routes.yaml` (alongside `agents.yaml`, `workspaces.yaml`, etc.).

```yaml
schema_version: 1

slashes:
  "/help":
    kind: help
    permission: null                       # null = no cap required
    command_module: "Esr.Admin.Commands.Help"
    requires_workspace_binding: false
    requires_user_binding: false
    description: "显示这份命令清单 / show command reference"
    args: []

  "/whoami":
    kind: whoami
    permission: null
    command_module: "Esr.Admin.Commands.Whoami"
    requires_workspace_binding: false
    requires_user_binding: false
    description: "显示你的身份 / show your identity"
    args: []

  "/doctor":
    kind: doctor
    permission: null
    command_module: "Esr.Admin.Commands.Doctor"
    requires_workspace_binding: false
    requires_user_binding: false
    description: "状态检查 / health diagnostic"
    args: []

  "/new-workspace":
    kind: workspace_new
    permission: "workspace.create"
    command_module: "Esr.Admin.Commands.Workspace.New"
    requires_workspace_binding: false
    requires_user_binding: true
    description: "创建新 workspace"
    args:
      - { name: name, required: true }
      - { name: role, required: false, default: "dev" }
      - { name: start_cmd, required: false }
      - { name: owner, required: false }    # null → fill from username

  "/new-session":
    aliases: ["/session new"]
    kind: session_new
    permission: "session:default/create"
    command_module: "Esr.Admin.Commands.Session.New"
    requires_workspace_binding: true
    requires_user_binding: true
    description: "启 CC session（git worktree fork from origin/main）"
    args:
      - { name: workspace, required: true }
      - { name: name, required: true }
      - { name: root, required: false }
      - { name: worktree, required: false }

  "/end-session":
    aliases: ["/session end"]
    kind: session_end
    permission: "session:default/end"
    command_module: "Esr.Admin.Commands.Session.End"
    requires_workspace_binding: true
    requires_user_binding: true
    description: "结束 session（worktree 干净则自动 prune）"
    args:
      - { name: name, required: true }
      - { name: root, required: false }
      - { name: cwd, required: false }

  "/sessions":
    aliases: ["/list-sessions", "/workspace sessions"]
    kind: session_list
    permission: "session.list"
    command_module: "Esr.Admin.Commands.Session.List"
    requires_workspace_binding: true       # false for /list-sessions specifically? see "alias inheritance" below
    requires_user_binding: true
    description: "列当前 workspace 的 live sessions"
    args:
      - { name: workspace, required: false }   # auto-fills from chat binding

  "/workspace info":
    kind: workspace_info
    permission: "session.list"               # workspace.info shares session.list scope (PR-21j)
    command_module: "Esr.Admin.Commands.Workspace.Info"
    requires_workspace_binding: true
    requires_user_binding: true
    description: "显示 workspace 配置（owner/role/chats/metadata）"
    args:
      - { name: workspace, required: false }

  "/list-agents":
    kind: agent_list
    permission: null                          # operator introspection; no cap
    command_module: "Esr.Admin.Commands.Agent.List"
    requires_workspace_binding: false
    requires_user_binding: false
    description: "列所有可用 agent"
    args: []
```

### Field semantics

- **slash key**: the literal text to match. Can include spaces (`/workspace info`). Lookup is longest-prefix on whitespace boundaries.
- **aliases** (optional list): alternate slash keys mapping to the same command. Useful for `/new-session` ↔ `/session new` migration.
- **kind**: internal Dispatcher kind. Today's `@required_permissions` keys move here; `Esr.Admin.Dispatcher` reads them via `SlashRoutes.permission_for/1`.
- **permission**: cap string or `null`. `null` = no cap check.
- **command_module**: Elixir module string. **Validated at yaml-load time** via `Code.ensure_loaded?(Module.concat([str]))`. On failure, snapshot rejected with `Logger.error({:unknown_module, str})`; previous snapshot retained. Boot continues with empty snapshot if no prior snapshot exists (symmetric to `capabilities.yaml` failure mode). `Module.safe_concat/1` was the obvious choice but **only resolves modules already in the BEAM atom table** at call time — fragile in tests with lazy code-loading and at first-boot validation.
- **requires_workspace_binding** (bool): when true, the dispatcher rejects with a clear error if the originating chat isn't bound to a workspace.
- **requires_user_binding** (bool): when true, rejects if `principal_id` doesn't resolve to an esr user via `Users.Registry`.
- **description**: human-readable for `/help` rendering. Both Chinese and English fine.
- **args** (list of maps): each arg has `name`, `required` (default false), and `default` (optional).

### Binding-gate error shape

When `requires_workspace_binding: true` and the originating chat has no `workspaces.yaml` binding, SlashHandler **short-circuits before Dispatcher cap check** with:

```elixir
{:reply, "this command requires the chat to be bound to a workspace; run /new-workspace first"}
```

Same for `requires_user_binding: true` with the equivalent text. The pre-PR-21θ behavior of letting `Workspace.New` / `Session.List` etc. surface `invalid_args` for missing `username` becomes unreachable for these slashes — the SlashHandler-level rejection runs first. The migration sequence (step 4 below) removes those now-dead branches in the command modules.

Trade-off: error text moves from per-command to uniform; less specific but operator-readable.

### Alias inheritance

By default, all aliases share the parent slash's full metadata (kind, permission, requirements, args). To override per alias, declare the alias as its own top-level entry instead of using `aliases:` — only one form per logical command.

(For now, no per-alias overrides are needed; `aliases:` is purely a re-routing list.)

## SlashHandler refactor

`Esr.Peers.SlashHandler` shrinks dramatically:

```elixir
defmodule Esr.Peers.SlashHandler do
  use GenServer

  @doc """
  Adapter-agnostic entry point. Adapters call this with the inbound
  envelope (must contain `payload.text` and `principal_id`) and a
  `reply_to` pid that will receive `{:reply, text}` once the command
  completes.
  """
  def dispatch(envelope, reply_to) do
    GenServer.cast(__MODULE__, {:dispatch, envelope, reply_to})
  end

  def handle_cast({:dispatch, envelope, reply_to}, state) do
    text = get_in(envelope, ["payload", "text"]) || ""
    principal_id = envelope["principal_id"] || "ou_unknown"

    with {:ok, route} <- Esr.SlashRoutes.lookup(text),
         {:ok, args} <- parse_kv_args(text, route.args_spec),
         :ok <- check_bindings(envelope, route),
         cmd <- build_cmd(route.kind, principal_id, args, envelope) do
      GenServer.cast(state.dispatcher, {:execute, cmd, {:reply_to, {:pid, self(), make_ref()}}})
      {:noreply, put_reply_pending(state, reply_to)}
    else
      {:error, reason} ->
        send(reply_to, {:reply, format_error(reason)})
        {:noreply, state}
    end
  end

  # parse_kv_args/2 — generic KV split; honors required + default per route.args_spec
  # check_bindings/2 — workspace-bound / user-bound gates per route.requires_*
  # build_cmd/4 — assembles the dispatch envelope (merge_chat_context + username resolve)
end
```

The bespoke per-command parsers (`parse_new_session/1`, `parse_new_workspace/1`, etc.) are deleted. Their bespoke logic moves into the corresponding `Esr.Admin.Commands.*.execute/1`:

- `Session.New.execute/1` — derives `cwd = "<root>/.worktrees/<branch>"` when `root` and `worktree` are present and `cwd` is absent. Rejects explicit `cwd=` with the "use CLI" hint.
- `Workspace.New.execute/1` — already handles `name_exists` idempotency (PR-21η). No change.
- `Session.End.execute/1` — unchanged surface.

## Dispatcher refactor

`Esr.Admin.Dispatcher`:
- Drop `@required_permissions` and `@command_modules` constants.
- Replace with `Esr.SlashRoutes.permission_for(kind)` and `Esr.SlashRoutes.command_module_for(kind)`.
- Validation rules (kind-must-be-string, etc.) unchanged.

## New module: `Esr.SlashRoutes`

GenServer + ETS, mirroring `Esr.Workspaces.Registry` shape:

- `start_link/1` — loads `slash-routes.yaml` at boot via the supervisor's `Esr.SlashRoutes.FileLoader`
- `lookup(text)` — text-prefix match against slash keys (longest-match wins for `/workspace info` vs `/workspace`)
- `permission_for(kind)` — kind → permission string or nil
- `command_module_for(kind)` — kind → Elixir module
- `route_for_kind(kind)` — full route map for a kind
- `list/0` — all routes (used by `/help` rendering)

`Esr.SlashRoutes.Watcher` (FSEvents) reloads on file change, mirroring `Esr.Workspaces.Watcher`.

## Adapter changes

### `Esr.Peers.FeishuAppAdapter`

- **Remove**: `inline_bootstrap_slash?/1`, `routed_bootstrap_slash?/1`, `handle_inline_bootstrap_slash/5`, `route_to_slash_handler/3`.
- **Replace with**: a single check at the top of `handle_upstream({:inbound_event, _})`:

```elixir
text = (get_in(envelope, ["payload", "args", "content"]) || "") |> to_string()

if String.starts_with?(text, "/") do
  envelope_with_text = put_in(envelope, ["payload", "text"], text)
  Esr.Peers.SlashHandler.dispatch(envelope_with_text, self())
  {:drop, :slash_dispatched, state}
else
  do_handle_upstream_inbound(envelope, args, chat_id, thread_id, state)
end
```

- **Add**: `handle_info({:reply, text, ref}, state)` — pop `ref` from `slash_pending_chat: %{ref => chat_id}` and emit `{:outbound, %{kind: "reply", args: %{chat_id: chat_id, text: text}}}`.

**⚠ Reply correlation — replaces PR-21t's `bootstrap_pending_chat`**

PR-21t introduced `bootstrap_pending_chat` as a `slash_pid → chat_id` map drained on every `{:reply, _}`. That works only because the bootstrap path is single-flight today. Once **every** slash from any chat goes through this path, two concurrent slashes from different chats race — both replies route to whichever chat was inserted last.

**Replacement design**:
- SlashHandler's `dispatch/2` takes a fresh `ref = make_ref()` per call and threads it through the dispatcher cast as part of the reply_to tuple.
- SlashHandler emits `{:reply, text, ref}` (not `{:reply, text}`) on completion.
- FAA tracks `state.slash_pending_chat = %{ref => chat_id}`. On `{:reply, text, ref}`, pops the ref + emits outbound. Map remains bounded (slash latencies are ~ms; ref cleanup is automatic on reply or timeout).
- `bootstrap_pending_chat` is renamed to `slash_pending_chat` and the map shape changes from `%{slash_pid => chat_id}` to `%{ref => chat_id}`.

**Timeout safety**: `dispatch/2` schedules a 5s `:timeout` message on the SlashHandler tagged with `ref`; if the dispatcher doesn't respond within 5s, SlashHandler emits `{:reply, "command timed out", ref}` to the adapter so the operator sees a failure rather than silence. 5s default; configurable via `Application.get_env(:esr, :slash_dispatch_timeout_ms, 5000)`.

### `Esr.Peers.FeishuChatProxy`

- **Remove**: any slash detection / routing. FCP becomes purely "forward non-slash messages to CC session."

### Future adapters

A `TelegramAdapter` would implement the same shape:
- Inbound text starts with `/`? → `Esr.Peers.SlashHandler.dispatch(envelope, self())`
- `handle_info({:reply, text}, state)` → emit Telegram-formatted send_message

No `slash-routes.yaml` knowledge needed.

## New command modules (PR-21θ workshop 1 ships these alongside the refactor)

- `Esr.Admin.Commands.Help` — emits the help text (formerly `feishu_app_adapter.ex:help_text/0`); rendering is data-driven from `SlashRoutes.list/0`.
- `Esr.Admin.Commands.Whoami` — emits the whoami text (formerly `feishu_app_adapter.ex:whoami_text/3`).
- `Esr.Admin.Commands.Doctor` — emits the doctor text (formerly `feishu_app_adapter.ex:doctor_text/3`).
- `Esr.Admin.Commands.Agent.List` — **NEW module**. `/list-agents` is currently a latent bug: SlashHandler parses it into `{:ok, "agent_list", %{}}` (slash_handler.ex:256), but Dispatcher has no `agent_list` entry in `@required_permissions`/`@command_modules`, so today's actual behavior is `unknown_kind` error. This PR ships the module alongside the yaml entry, fixing the bug.

These are pure-function modules: `execute/1` returns `{:ok, %{"text" => ...}}` or `{:error, ...}`.

## Hot-reload & failure modes

| Event | Behaviour |
|---|---|
| Boot, yaml present, valid | Snapshot loaded into ETS; SlashHandler ready. |
| Boot, yaml absent | Empty snapshot; every slash returns "unknown command" until file appears. |
| Boot, yaml malformed | `Logger.error` + boot continues with empty snapshot. (Symmetric to `capabilities.yaml` failure mode.) |
| Edit, valid | Watcher fires; `FileLoader.load/1` reads + validates; snapshot atomically swapped. |
| Edit, invalid (bad command_module) | `FileLoader.load/1` returns `{:error, {:unknown_module, ...}}`; previous snapshot retained. |
| Edit, breaking command_module rename | Same as above — breaking rename detected at load time. |
| Adapter inbound during reload | Read-side uses ETS without GenServer hop; no race window. |

## Testing

| Layer | Cases |
|---|---|
| `slash_routes_test.exs` | parse valid yaml; reject malformed (bad scope, missing kind, unknown_module); alias resolution; longest-prefix match |
| `slash_handler_test.exs` (rewrite) | dispatch known slash → command kind + args; unknown slash → unknown_command reply; missing required arg → error reply; `requires_workspace_binding` enforced; `requires_user_binding` enforced |
| Per-command tests (existing) | unchanged shape; SlashHandler no longer in the call chain for those tests, but bespoke logic (cwd derivation) is now tested at command-module level |
| Integration tests | `feishu_app_adapter_test.exs` updated to assert "any slash → SlashHandler.dispatch/2 called"; `feishu_slash_new_session_test.exs` simpler envelope (no FCP routing) |
| E2E | Update scenarios to verify slash flows. Specifically: `/new-session` from a chat with no live session must succeed (the bug discovered today). |

## Migration sequence

The PR is large — rolled in the standard PR → dev → main flow:

1. Add `Esr.SlashRoutes` module + `slash-routes.yaml` + `FileLoader` + `Watcher` (no callers yet).
2. Wire SlashHandler to use `SlashRoutes.lookup/1` (parallel to existing case chain via feature flag `:esr_use_yaml_slash_routes`).
3. Move bespoke per-command parser logic (cwd derivation, etc.) into command modules.
4. Add `Help/Whoami/Doctor/Agent.List` command modules; populate `slash-routes.yaml` with all 14 slash entries.
5. Flip flag to true; verify; delete the old hardcoded paths in SlashHandler.
6. Adapter refactor: FAA drops bypass lists; routes any "/"-prefixed text to SlashHandler.
7. FCP cleanup: remove slash routing.
8. Dispatcher cleanup: drop `@required_permissions`/`@command_modules`.
9. Doc + gen-docs regen.

Each commit independently green; PR merges to dev as a single squash; promote to main via direct push (FF).

## Risks

| Risk | Probability | Mitigation |
|---|---|---|
| Forgotten slash command (some PR added one without yaml) | low | Boot test asserts every legacy `Esr.Admin.Commands.*` module has a corresponding yaml entry |
| Yaml typo silently rolls back to empty snapshot | low | Strict validation: malformed yaml → boot continues with EMPTY snapshot (current code returns `:ok`) — operator sees every slash fail with "unknown command" rather than partial state |
| Hot-reload race with in-flight slash | low | Snapshot swap is atomic via `:ets.delete_all_objects` + insert; in-flight routes don't see partial state |
| Operator edits yaml + adds module that doesn't exist | medium | `FileLoader.load/1` validates `Module.safe_concat/1` succeeds; if not, snapshot rejected, error logged, previous snapshot kept |
| Adapter doesn't implement `{:reply, text, ref}` handler | medium | New peer-implementer doc note; existing FAA already has the handler from PR-21t; future Telegram et al. follow the pattern |
| Concurrent slashes from two chats race on reply correlation | medium | Ref-keyed `slash_pending_chat: %{ref => chat_id}` per the Adapter changes section; replaces PR-21t's single-flight `bootstrap_pending_chat`. |
| `command_module` string in yaml refers to module that hasn't been compiled / loaded | medium | yaml-load uses `Code.ensure_loaded?/1` (NOT `Module.safe_concat/1`); rejection retains previous snapshot. Boot test asserts every kind in yaml resolves to a loaded module. |

## Open questions

1. **Help text grouping in `/help`**: yaml carries per-slash `description`, but the current `feishu_app_adapter.ex:help_text/0` groups by category (诊断 / Workspace / Sessions). Add a `category:` string field per slash; `/help` renders sections in deterministic order. **Status**: spec'd; final category list tunable in plan.

(Resolved during subagent review:
- `<runtime_home>/slash-routes.yaml` location, seeded from `priv/slash-routes.default.yaml` on first boot — same shape as other yaml files.
- 5s `dispatch/2` timeout, configurable via `Application.get_env(:esr, :slash_dispatch_timeout_ms, 5000)` — see Adapter changes section.)
