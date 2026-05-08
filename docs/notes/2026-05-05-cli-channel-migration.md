# cli_channel.ex → slash command migration (2026-05-05)

**Goal:** unify the operator-command dispatch surface. Today
`runtime/lib/esr_web/cli_channel.ex` hosts ~14 hand-rolled WS
dispatch handlers (`cli:adapters/refresh`, `cli:debug/pause`, etc.)
that bypass the slash registry. Python CLI is the only caller. This
note documents the conventions for migrating those handlers into
proper slash commands so escript / REPL / Feishu chat all share one
dispatch path.

## Why

After PR-3.5 (cc_mcp HTTP MCP transport) the only architectural
loose end on the operator-surface side is this duplicate dispatch
table. The slash registry (`Esr.Resource.SlashRoute.Registry` +
`runtime/priv/slash-routes.default.yaml` + `Esr.Commands.*`
modules) is the canonical operator-command primitive; cli_channel's
parallel handlers are pre-PR-21κ debt. Once migrated:

- escript users get every command via `esr <kind> [args...]`
- final_gate.sh stops needing Python CLI for `esr adapter add` etc.
- Python CLI can be deleted (the actual blocker for Phase C)

## Conventions

These are decisions for THIS migration. Not a spec — just convention
choices to keep the work mechanical.

### Slash naming: singular

`/adapter add`, `/adapter remove`, `/debug pause`, `/deadletter list`.
Aligns with existing `/plugin {list,info,...}` `/cap {list,...}`
`/user {list,...}`. The `cli:adapters/*` plural is just a topic
naming artefact — semantically each command targets a single
adapter (or none).

Internal kind atoms keep `_` separator: `adapter_add`,
`debug_pause`. (matches existing `cap_list` / `user_add` /
`plugin_install` etc.)

Existing `/sessions` (plural) stays as-is — it's a list verb on
multiple sessions, fundamentally different from
single-instance ops.

### Error response shape

cli_channel returns `%{"data" => %{"ok" => false, "error" => "..."}}`.

Slash commands return `{:error, %{"type" => "<atom>", "message" =>
"<human>"}}` — matches `Esr.Commands.User.Add`,
`Esr.Commands.Cap.Grant` etc. The Dispatcher writes this into the
admin_queue/failed/<id>.yaml's `result.error` field; escript's
`render_result/1` already formats it.

Translation table for the migration:
- `{ok: false, error: "missing X"}` → `{:error, %{"type" => "invalid_args", "message" => "missing X"}}`
- `{ok: false, error: "not found"}` → `{:error, %{"type" => "not_found", "message" => "..."}}`
- `{ok: false, reason: ...}` → same with `"type"` based on reason

### Args: flat key=value

cli_channel often takes nested maps (`%{config: %{app_id: "X"}}`).
Slash commands take flat `key=value` per `Esr.Commands.Cap.Grant`'s
`args.principal_id + args.permission` pattern.

For `adapter start`:
```
/adapter start type=feishu instance_id=X app_id=Y app_secret=Z
                                                  base_url=...
```
not `/adapter start type=feishu config={"app_id":"Y",...}`.

### Permissions

| Command | Permission |
|---|---|
| `/adapter {start,add,remove,rename,refresh}` | `adapter.manage` (NEW; declare in Bootstrap) |
| `/debug {pause,resume}` | `runtime.debug` (NEW) |
| `/deadletter {list,flush}` | `runtime.deadletter` (NEW) |
| `/actors {tree,inspect}` | `null` (read-only diagnostic, no permission) |
| `/trace` | `null` (read-only) |
| `/workspaces describe` | `null` (read-only — same allowlist as today) |

New permissions registered in
`Esr.Resource.Permission.Bootstrap` alongside existing
`cap.manage`, `user.manage`, `plugin/manage`.

### `/actors tree` real implementation

The cli_channel handler returns
`%{data: %{topologies: [], error: "topology module removed"}}` —
a stale stub from P3-13. Migration writes a real implementation:

1. Pull `Esr.Entity.Registry.list_all/0` for all live actors.
2. Group by session_id parsed from actor_id naming convention:
   - `thread:<sid>` → that session
   - `feishu_app_adapter_<id>` → admin scope
   - `cc_<sid>`, `cc_proxy_<sid>` → that session
   - others → `:unscoped`
3. Render as indented tree (admin scope first, then per-session).

No dependency on the old `Esr.Topology` registry (deleted) — this
is computed from live actor state.

### `/workspaces describe` ↔ cc MCP tool coordination

cli_channel.ex `cli:workspaces/describe` is consumed by cc's
`describe_topology` MCP tool — claude calls
`tools/call describe_topology` and the controller (post-PR-3.5)
forwards into the existing `{:tool_invoke, ...}` peer message,
which today reaches the cli_channel dispatch via the WS bridge.

Migration:
1. Lift the body of `cli:workspaces/describe` into a slash command
   `Esr.Commands.Workspace.Describe`.
2. Update `Esr.Plugins.ClaudeCode.Mcp.Tools` `describe_topology`
   schema to match.
3. McpController's `tools/call` for `describe_topology` dispatches
   directly to `Esr.Commands.Workspace.Describe.execute/1` (no
   peer hop, since this is a workspace-level read not a per-session
   tool).

The MCP tool API surface to claude stays identical
(name=`describe_topology`, same input schema, same output shape)
— internal wiring rerouted from "WS forward to cli_channel" to
"direct slash dispatch."

### Dead-handler deletions

`cli:run/<name>`, `cli:stop/<name>`, `cli:drain` all return P3-13
placeholder errors. No migration — just delete the dispatch
clauses + the `@topology_removed_error` constant. operators have
been using `/new-session` + `/end-session` for ~6 months; nobody
calls `cli:run/*` anymore (Python CLI's `esr cmd run` is the only
caller, deleted in this same PR).

### Merged handlers

- `cli:daemon/doctor` → fold into existing `/doctor` slash. cli_channel
  block deleted.
- `cli:workspace/register` → `/new-workspace`. The cli_channel handler
  takes a richer payload (name, role, owner, chats, neighbors,
  metadata, env, start_cmd); `/new-workspace` currently exposes a
  subset (name, role, start_cmd, owner). Either extend the slash
  schema or accept the existing args. **Decision: extend
  `/new-workspace` args** to include `chats`, `neighbors`, `metadata`,
  `env` (optional, JSON-encoded for non-string values), so power
  users have full control while default users still get the simple
  form.

## Scope

| Op | Count | Notes |
|---|---|---|
| Migrate to slash command | 12 | actors {tree,inspect}, debug {pause,resume}, deadletter {list,flush}, adapter {start,add,remove,rename,refresh}, workspace describe, trace |
| Delete (dead) | 3 | run, stop, drain |
| Merge into existing | 2 | daemon/doctor → /doctor; workspace/register → /new-workspace |
| escript file-readers | 5 | adapters list, handler list, cmd list/show/compile (read-only yaml/dir) |
| final_gate.sh update | 1 | swap 4 esr commands to escript form |
| Python CLI deletion | 1 | `py/src/esr/cli/` rm |

### Out of scope

- `/new-session` / `/end-session` vestige args (`root`, `cwd`,
  `worktree`) — separate redesign per `docs/futures/todo.md`'s
  "/session new <NAME> redesign" item.
- REPL implementation (was deferred Phase 2 PR-2.8).
- New plugin slash route extensibility (plugins can't yet
  contribute slashes; future work).

## Order of work

1. Field note (this file) + branch.
2. Delete dead handlers (run/stop/drain + topology_removed constant).
3. Easy migrations: deadletter, debug, trace.
4. Actors tree real implementation.
5. Adapter family (start, add wraps register_adapter, remove, rename, refresh).
6. Workspace describe + sync cc MCP tool.
7. Daemon/doctor merge into /doctor; workspace/register merge into /new-workspace.
8. escript file-reader commands (adapters list, handler list, cmd list/show/compile).
9. Update final_gate.sh.
10. Delete Python CLI + adapters/cc_mcp directory leftovers + pyproject entries.
11. Run unit tests + e2e 06/07 + final_gate.sh.
12. Open PR; subagent code-reviewer pass before merge.

Each numbered step is one commit. ~12 commits, one PR.

## Actual scope shipped (2026-05-05)

The work landed in 8 functional commits on
`feature/cli-channel-to-slash-migration`. Two scope reductions vs.
the original plan:

1. **escript file-readers limited to `adapters list`** — `handler list`,
   `cmd list/show/compile` were dropped. Each targets a P3-13-dead
   concept (Python plugin model deprecated by Phase-2 Elixir plugins;
   topology registry deleted 6 months ago). The Python implementations
   vanish with the rest of `py/src/esr/cli/` whenever step 10 lands.

2. **Python CLI deletion (step 10) deferred to a follow-up PR.** All
   runtime-coupled commands now hit `unknown_topic` because
   cli_channel.ex's dispatch table is empty — the CLI is functionally
   neutered already. Outstanding before deletion:
   (a) port `esr scenario run` to escript or shell — final_gate.sh:56
       depends on it as the e2e harness;
   (b) decide on `esr cmd stop` calls in final_gate.sh L5/L6 — they
       were P3-13 dead before this migration started;
   (c) audit `py/src/esr/` (non-CLI) for cross-module deps that
       survive deletion.

   Tracked in `docs/futures/todo.md` under "Pending — concrete next
   PRs".

What did ship: 12 cli_channel handlers migrated, 3 dead clauses
deleted, 2 merged into existing slashes, 1 file-reader added,
final_gate.sh swapped to escript, cli_channel.ex shrunk to a
30-line protocol shell. Net change: ~700 LOC deleted from
runtime/, 2 new cmd modules created, 1 single-source-of-truth
extraction (`Esr.Resource.Workspace.Describe`).
