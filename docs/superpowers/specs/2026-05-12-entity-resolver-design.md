# Entity Resolver Design

**Status:** approved 2026-05-12 (linyilun, Feishu chat oc_d9b47511b085e9d5b66c4595b3ef9bb9 — brainstorm transcript in same chat)
**Author:** Claude Opus 4.7 (controller) + linyilun (decisions)

## 1. Goal + Non-goals

**Goal:** introduce `Esr.Entity.resolve_by/3` as the sole public API for translating any identifier shape (UUID / username / feishu open_id / chat_id+app_id / name+scope) into a canonical `{kind, uuid}` tuple. Make the underlying stores private so the API cannot be bypassed. This eliminates the "lookup chain drift" class of bugs documented in `docs/futures/todo.md` (2026-05-12 chat-flow validation findings).

**Non-goals:**
- Sqlite persistence (out of scope; future PR can swap ETS for sqlite without changing the API).
- Capabilities subsystem unification (out of scope; `Esr.Resource.Capability` keeps its current shape — it will *use* the new resolver via the chat-side cap-check fix).
- `Esr.Entity.Registry` string-keyed routing (e.g. `"feishu_app_adapter_<app_id>"`) — out of scope; that's a separate "entity routing key" subsystem to address in a later PR.
- New external identifier formats (e.g. Slack user_id, Telegram user_id) — schema accommodates them, but no by-clauses ship until a real plugin needs them.

## 2. Background — drift bugs that motivated this

Eight bugs surfaced 2026-05-12 during the wipe → register_adapter → /feishu:bind → /session:new manual walk. Two fall directly in the "lookup chain drift" category:

| Bug | Drift shape |
|---|---|
| Chat-side cap-check (`Esr.Resource.Capability.has?/2`, capability.ex:32-45) returns `false` for valid principals because the chain stops at `ou_xxx → username` and doesn't continue to UUID; caps.yaml is UUID-keyed | One missing translation hop in a multi-source ETS lookup chain |
| `Esr.Commands.Workspace.Resolve.resolve_submitter/1` (resolve.ex:71-79) only recognizes `submitted_by=ou_xxx` (feishu open_id) and `submitter_username=X`; UUID-form `submitted_by=cba75063-...` falls through to `:not_found` | Ad-hoc dispatch on identifier shape with incomplete coverage |

Plus a sibling category — *envelope arg injection drift* — that this spec does not address (separate audit needed):

| Bug | Category |
|---|---|
| `Esr.Entity.SlashHandler.merge_chat_context/3` (slash_handler.ex:742-824) missing `workspace_bind_chat` clause → `chat_id` not auto-injected | Envelope injection drift (not lookup) |
| chat-side render template substitution drops `details:` interpolation | Render drift (not lookup) |

Shared root for both categories: lookups are composed ad-hoc per call-site instead of through a single API.

## 3. Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     PUBLIC: Esr.Entity                              │
│                                                                     │
│  resolve_by(kind, by, value) :: {:ok, {kind, uuid}} | :not_found   │
│  actor_for_agent(agent_uuid, role) :: {:ok, actor_id} | :not_found │
│                                                                     │
└──┬─────────────┬─────────────┬─────────────┬───────────────────────┘
   │             │             │             │
   ▼             ▼             ▼             ▼
┌──────┐    ┌──────────┐  ┌─────────┐  ┌──────────┐
│ User │    │Workspace │  │ Session │  │  Agent   │
│Store │    │  Store   │  │  Store  │  │  Store   │      (all private)
│      │    │          │  │         │  │          │
│(ETS, │    │(ETS, no  │  │(ETS, no │  │(ETS, no  │
│ no   │    │ :named_  │  │ :named_ │  │ :named_  │
│:named│    │  table)  │  │  table) │  │  table)  │
│table)│    │          │  │         │  │          │
└──────┘    └──────────┘  └─────────┘  └──────────┘
```

`Esr.Entity` is the only module callers compose. Each `*Store` owns its private ETS table (no `:named_table` so external `:ets.lookup` can't reach it). Stores are renamed from today's `Esr.Entity.User.Registry` etc. to `Esr.Entity.UserStore` etc. to signal "private implementation, not for direct calls."

## 4. Public API

### 4.1 `resolve_by/3`

```elixir
@spec resolve_by(kind :: kind(), by :: atom(), value :: term()) ::
        {:ok, {kind(), uuid_string()}} | :not_found | :invalid_format

@type kind :: :user | :workspace | :session | :agent
@type uuid_string :: <<_::36*8>>  # 36-char hyphenated UUID v4
```

`:not_found` — value was well-formed but no entity matches.
`:invalid_format` — value's literal format is wrong for the by-clause (e.g. `:user :uuid "not-a-uuid"`). Caught early so callers can distinguish data corruption from typed input bugs.

No `:ambiguous` outcome: duplicate keys are prevented at write-side (username uniqueness in `add_user`, workspace name uniqueness in `workspace.new`, etc.). Duplicate state = corruption = let-it-crash.

### 4.2 `actor_for_agent/2`

```elixir
@spec actor_for_agent(agent_uuid :: uuid_string(), role :: atom()) ::
        {:ok, actor_id()} | :not_found
```

Role is per-kind:
- cc-kind agent: `:primary` (CC actor_id), `:terminal` (PTY actor_id)
- codex-kind agent (future): `:primary` (codex_runtime actor_id), no `:terminal`

Role atoms validated against the agent kind's manifest declaration; unknown role returns `:not_found` (not raise, since callers may probe per-kind capability).

### 4.3 Coverage matrix (13 by-clauses)

| kind | by | value type | returns | semantics |
|---|---|---|---|---|
| `:user` | `:uuid` | uuid_string | user_uuid | identity check |
| `:user` | `:username` | string | user_uuid | human-readable lookup |
| `:user` | `:feishu_id` | string (`ou_*`) | user_uuid | Feishu open_id → esr user |
| `:workspace` | `:uuid` | uuid_string | workspace_uuid | identity check |
| `:workspace` | `:name` | string | workspace_uuid | by name |
| `:workspace` | `:chat_binding` | `%{chat_id, app_id}` | workspace_uuid | workspace bound to this chat (workspace.chats[]) |
| `:workspace` | `:owner_default` | uuid_string (user_uuid) | workspace_uuid | the user's default_workspace_id |
| `:session` | `:uuid` | uuid_string | session_uuid | identity check |
| `:session` | `:name_in_scope` | `%{name, workspace_uuid, user_uuid, env}` | session_uuid | name unique within `(env, user, workspace)` 4-tuple scope (today's actual key — see §5.3) |
| `:session` | `:chat_current` | `%{chat_id, app_id}` | session_uuid | chat-current session |
| `:agent` | `:uuid` | uuid_string | agent_uuid (stable instance-level UUID) | identity check |
| `:agent` | `:name_in_session` | `%{name, session_uuid}` | agent_uuid | name unique within session |
| `:agent` | `:primary_for_session` | uuid_string (session_uuid) | agent_uuid | session's primary agent for mention routing |

## 5. Per-kind semantics

### 5.1 `:user`

UUID-stable identity; username + feishu_ids are mutable attributes.

`:feishu_id` chain: `feishu_id → username → uuid`. Old API exposed only the first hop (`lookup_by_feishu_id/1` returned username). New API completes the chain internally.

### 5.2 `:workspace`

Name is unique within an instance. `chat_binding` returns the workspace whose `chats[]` array contains the (chat_id, app_id) pair. `owner_default` reads the user's persisted `default_workspace_id` field (from user.json, mirrored to ETS at boot).

### 5.3 `:session`

Session name uniqueness is scoped by the 4-tuple `(env, user_uuid, workspace_uuid, name)` — see `runtime/lib/esr/session/name_index/registry.ex:48,132` for the live mapping. The same human-readable name (e.g. `test-cc`) can exist for different users or in different workspaces; uniqueness is enforced only within a single user+workspace pair. The `:name_in_scope` by-clause therefore requires all 4 fields. `chat_current` returns the session most recently `/session:bind-chat`'d into the chat (or auto-bound via `/session:new` in the chat context).

### 5.4 `:agent`

**Stable identity model.** Today's `Esr.Entity.Agent.Instance.id` (the supervisor-restart-stable UUID) is the agent UUID. Actor IDs (CC and PTY) are minted per-spawn and may change across `:one_for_all` restarts — they are NOT the agent's identity. Callers wanting an actor pid go through `actor_for_agent/2`.

**Breaking change to `InstanceRegistry.primary/2`.** Today (instance_registry.ex:170-178) it returns `{:ok, agent_name :: String.t()}`. PR-1 changes the return to `{:ok, agent_uuid :: uuid_string()}` so the resolver contract ("always returns UUID") holds without exceptions. Five caller sites migrate in the same PR — they receive a UUID and call `actor_for_agent/2` for the actor pid when needed, or pass UUID downstream. The `:agent :primary_for_session` by-clause delegates to the updated `primary/2`.

**Future-proofing.** New agent kinds (codex, etc.) declare their `actor_roles` in their plugin manifest:

```yaml
# plugin manifest snippet (future codex plugin)
agent_kinds:
  codex:
    module: Esr.Plugins.Codex.Agent
    actor_roles: [:primary]   # no terminal
```

`resolve_by(:agent, ...)` returns the agent_uuid regardless of kind; `actor_for_agent(uuid, :primary)` works for any kind; `actor_for_agent(uuid, :terminal)` returns `:not_found` for kinds without a terminal.

## 6. Private store modules

Four new modules replace today's lookup-exposing registries:

| New | Replaces | Public surface |
|---|---|---|
| `Esr.Entity.UserStore` | `Esr.Entity.User.Registry` | `defp` for lookups; public mutators stay (`load_snapshot_with_uuids`, `set_default_workspace`, `add_user`, `remove_user`, ...) |
| `Esr.Entity.WorkspaceStore` | `Esr.Resource.Workspace.Registry` + `Esr.Resource.Workspace.NameIndex` (merge) | `defp` lookups; public mutators (`put`, `delete`, `add_chat_binding`, ...) |
| `Esr.Entity.SessionStore` | `Esr.Resource.Session.Registry` (which today embeds its name index as inline ETS `:esr_resource_session_name_index` — no separate NameIndex module exists for resource sessions) + `Esr.Session.NameIndex.Registry` (the 4-tuple live-session URI claim map; merge so both name maps live behind one store) | `defp` lookups; public mutators (`put`, `delete`, ...) |
| `Esr.Entity.AgentStore` | `Esr.Entity.Agent.InstanceRegistry` (rename, no functional change to instance lifecycle) | `defp` lookups; public mutators (`add_instance`, `remove_instance`, `set_primary`, ...) |

ETS table options change: `:named_table` removed. Each Store GenServer holds the table reference in its state and serves all reads through `Esr.Entity` dispatch. Mutators stay public for FileLoaders, command modules that write (`/user:add`, `/workspace:new`, etc.), and the lifecycle owners.

## 7. Migration map (41 call sites across 29 files)

Grep baseline (run 2026-05-12 against origin/dev):

```bash
grep -rn "lookup_by_feishu_id\|UserRegistry\.get_default_workspace\|UserRegistry\.get_by_uuid\|UserRegistry\.get_by_username\|NameIndex\.id_for_name" runtime/lib/ \
  | grep -v "user/registry.ex\|user/name_index.ex\|user/file_loader.ex"
```

Returns 41 lines across 29 files. PR-1 migrates **all** of them. Three waves:

**Wave A — drift-fix call sites (3 files, the bugs this PR closes regression-test the new API):**
- `runtime/lib/esr/resource/capability.ex:32-45` — chat-cap-check chain
- `runtime/lib/esr/commands/workspace/resolve.ex:61-79` — resolve_submitter + lookup_user_default. **Note**: callers today hold username, but `:workspace :owner_default` takes user_uuid input. Migration adds `resolve_by(:user, :username, ...)` first then `:owner_default` — mechanical two-step per call site. Same shape at `resource/workspace/bootstrap.ex:54,77,102` (Wave B).
- `runtime/lib/esr/entity/slash_handler.ex` — chat-flow lookups (multiple lines)

**Breaking-change site (in Wave A):** `runtime/lib/esr/entity/agent/instance_registry.ex:170-178` — change `primary/2` return from `{:ok, name}` to `{:ok, uuid}`. Five caller sites migrate to consume UUID (and call `actor_for_agent/2` when actor_id needed):
- `runtime/lib/esr/entity/slash_handler.ex:365` (mention routing)
- `runtime/lib/esr/commands/agent/primary.ex:30` (`/agent:primary` slash)
- `runtime/lib/esr/commands/agent/set_primary.ex` (rename consumer)
- `runtime/lib/esr/commands/agent/list.ex` (display rendering)
- `runtime/lib/esr_web/adapter_channel.ex` (legacy)

**Wave B — high-traffic routing (5 files):**
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — FCP lookups
- `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex` — FAA lookups
- `runtime/lib/esr/entity/agent/mention_parser.ex` — mention → agent
- `runtime/lib/esr/entity/server.ex` — entity server lookups
- `runtime/lib/esr/session/router.ex` — session router

**Wave C — remaining (21 files, mechanical replacements):**
- `runtime/lib/esr/commands/{actors,agent,workspace,session,pty,...}/...ex` — command dispatch lookups
- `runtime/lib/esr/persistence/ets.ex` — boot-time bulk read

Each call site becomes `Esr.Entity.resolve_by(kind, by, value)` + a `case` on `{:ok, {_, uuid}}` / `:not_found`. No call site retains its old call shape — that's the choke-point enforcement.

## 8. Old API deprecation

After Wave C completes, the old public functions exist as `defp` inside the new stores:

```elixir
# Esr.Entity.UserStore
defp lookup_by_feishu_id_internal(feishu_id) do
  case :ets.lookup(state.feishu_id_table, feishu_id) do
    [{^feishu_id, username}] -> {:ok, username}
    [] -> :not_found
  end
end
```

External callers physically cannot reach `lookup_by_feishu_id_internal/1`. The drift bug pattern (chain stops one hop short) becomes a compile error if re-introduced.

## 9. Tests

**Per by-clause unit tests** (13 by-clauses × {happy path, :not_found, :invalid_format}):
- `runtime/test/esr/entity/resolver_test.exs` — comprehensive coverage matrix

**Regression tests for today's 2 drift bugs** (the spec's reason for existing):
- `runtime/test/esr/integration/chat_cap_check_regression_test.exs` — chat-side cap-check now finds UUID-keyed caps via `ou_xxx → username → uuid` chain. Fails the test if anyone re-introduces a chain that stops early.
- `runtime/test/esr/integration/resolve_submitter_uuid_form_test.exs` — `Esr.Commands.Workspace.Resolve` accepts `submitted_by=<uuid>` AND `submitted_by=<ou_xxx>` AND `submitter_username=X`. Migrated to the new resolver.

**Old API compile-fail fixture:**
- `runtime/test/esr/entity/old_api_unreachable_test.exs` — uses `Code.ensure_compiled/1` + `function_exported?/3` to assert `Esr.Entity.User.Registry.lookup_by_feishu_id/1` (and siblings) are undefined. Locks the structural enforcement.

**E2E scenarios** (per user directive 2026-05-12: "plan 里面要规划好 e2e 测试"):
- `tests/e2e/scenarios/31_entity_resolver_chat_flow.sh` — full reproduction of today's failing flow: wipe → boot → `register_adapter` → `/feishu:bind` → `/session:new name=test-cc` (no explicit `workspace=`). Asserts session starts (chat reply contains `session started: <UUID>`) WITHOUT operator running `cap_grant target_principal_id=linyilun` first AND without `/workspace:bind-chat` first — the resolver chain must find user-default workspace + caps via UUID directly.
- `tests/e2e/scenarios/32_entity_resolver_cli_uuid_form.sh` — CLI submit with `submitted_by=<uuid>` succeeds. Today's bug: `resolve_submitter` doesn't accept UUID form → `:no_workspace_target`.

**Test fixture pattern for private ETS** (no `:named_table`):
- Stores expose a test-only helper `Esr.Entity.UserStore.__test_ets_refs__/0` (compile-time gated `if Mix.env() == :test`) returning the internal ETS references for direct test setup. Production callers never see this.
- Alternative: tests construct fixture state by going through public mutators (`add_user`, `set_default_workspace`, etc.) which already exist for production use. Preferred for new tests; the `__test_ets_refs__` helper is for migrating existing tests that poke ETS directly.

## 10. Open questions / future-proofing notes

**Sqlite persistence (future PR).** ETS today; sqlite is a drop-in candidate when persistence-across-restart becomes important. The public API stays the same — only the store's internal storage changes. Trigger to consider sqlite: when `users.yaml + user.json` drift bugs become repeated (today's `feishu_bind doesn't update user.json` is the early signal).

**`Esr.Entity.Registry` string-keyed routing (future PR).** Today's global `Esr.Entity.Registry` uses string keys like `"feishu_app_adapter_<app_id>"` for process registration. That's a separate drift surface (register/lookup key parity, see [[feedback_register_lookup_key_parity]]). Out of scope here, but a future PR can apply the same playbook: tuple keys, single `Esr.Entity.register_process(kind, id, pid)` API.

**Cap UUID translation hop in `capability.ex` (post-PR-1).** After this PR lands, the chat-cap-check fix is one of the Wave A migrations. Captured in `docs/futures/todo.md` row `chat-cap-check-username-to-uuid-hop`.

**Codex / other agent kinds (when plugin lands).** Manifest's `agent_kinds.<kind>.actor_roles` block ships in this PR (declarative). The runtime registry registers roles at plugin load. `actor_for_agent(uuid, role)` consults this registry. No future PR change is needed to add a new kind — only the plugin manifest entry.

## 11. References

- Brainstorm transcript: Feishu chat `oc_d9b47511b085e9d5b66c4595b3ef9bb9`, 2026-05-12
- Memory: [[feedback_uuid_is_canonical_identifier]] (UUID-canonical principle)
- Memory: [[feedback_register_lookup_key_parity]] (key-format drift class)
- Todo: `docs/futures/todo.md` rows `chat-cap-check-username-to-uuid-hop`, `resolve-submitter-format-agnostic`
- Existing modules being replaced: `runtime/lib/esr/entity/user/registry.ex`, `runtime/lib/esr/resource/workspace/registry.ex`, `runtime/lib/esr/entity/agent/instance_registry.ex`
- Existing public API caller landscape: `grep -rn "lookup_by_feishu_id\|UserRegistry\.get_*\|NameIndex\.id_for_name" runtime/lib/` (41 lines, 29 files)
