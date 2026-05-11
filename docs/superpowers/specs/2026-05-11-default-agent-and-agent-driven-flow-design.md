# Default agent on session creation + agent-driven follow-up operations

**Status:** Draft rev-2 — pending user approval (linyilun, 2026-05-11)
**Date:** 2026-05-11
**Author:** Claude (with linyilun)
**Companion:** [`.zh_cn.md`](2026-05-11-default-agent-and-agent-driven-flow-design.zh_cn.md)

Worktree: `.worktrees/fix-unconsumed-msg`, branch `spec/default-agent-and-agent-driven-flow`.

rev-2 changes: rewritten from scratch after subagent code review (commit
`5d81734` → this commit) found 7 critical mis-grounded claims. Every
proposed change in this rev is anchored to a verified file:line in
`runtime/lib/`.

---

## 1. Why now

On 2026-05-11 the operator (linyilun) ran a manual Feishu test:

```
/workspace:use test-dev    → ok: %{"action" => "default_workspace_set", ...}
/session:list              → workspace test-dev: no live sessions
/session:new name=test-cc  → session started: b6bfbe47-...
hello?                     → (NO REPLY — silent hang)
```

`~/.esrd-dev/default/logs/launchd-stdout.log` showed a 4-step cascade
(verified at 2026-05-11 14:33:41 GMT+8, session `b6bfbe47-91ae-...`):

1. **PtyProcess spawned `claude` with `dir: "/tmp"`** even though
   `workspace_name: "test-dev"` was set. The PtyProcess init's
   `dir: get_param(params, :dir) || "/tmp"` (`runtime/lib/esr/entity/pty_process.ex:80`)
   silently fell through because `params[:dir]` was nil. The workspace
   `test-dev` was created via `/workspace:new name=test-dev` (no `folder=`),
   which currently writes `folders: []` with `location: {:esr_bound, ...}`
   (`runtime/lib/esr/commands/workspace/new.ex:119-129`). `/session:new`'s
   `resolve_dir_from_workspace/1` (`runtime/lib/esr/commands/session/new.ex`)
   reads `workspace.folders[0].path` — returns nil for the 0-folder case.
2. **`claude` exited 256** immediately:
   ```
   Error: Invalid MCP configuration:
   MCP config file not found: /private/tmp/.mcp.json
   ```
   No `.mcp.json` is written anywhere in the live spawn path. `Esr.Plugins.ClaudeCode.Launcher`
   has `prepare_spawn/1` and `write_mcp_json/1` at
   `runtime/lib/esr/plugins/claude_code/launcher.ex:68-183` — but those
   functions are **only called from tests**. The production PTY spawn at
   `runtime/lib/esr/entity/pty_process.ex:202-216` calls
   `Launcher.spawn_cmd/1` which just appends `--mcp-config .mcp.json` to
   argv without writing the file. `claude` reads its `cwd` (which is `/tmp`),
   finds no `.mcp.json`, refuses to start.
3. **PtyProcess crash** with `{:pty_crashed, 256}`. `Esr.Session.AgentInstanceSupervisor`
   (`runtime/lib/esr/session/agent_instance_supervisor.ex`) uses
   `:one_for_all` per spec Q5.3 sub-2 (2026-05-07) — correct for CC+PTY
   consistency; CC is killed too. PtyProcess's `terminate/2` broadcasts
   `:pty_closed` on PubSub topic `pty:<actor_id>`.
4. **FCP receives `:pty_closed` but has no `handle_info/2` clause for it.**
   `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:162` subscribes to
   `pty:<actor_id>` at init; line 274 has no matching clause for the
   `:pty_closed` atom. **FunctionClauseError** → FCP crashes → its own
   supervisor restarts FCP → cycle repeats → `AgentInstanceSupervisor`
   exhausts `max_restarts: 3` in 60s → subtree terminated with
   `restart: :transient` (no auto-restart).
5. **`:esr_session_chat_routing` ETS entry still points at dead FCP pid.**
   FAA at `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238` looks
   up by `(chat_id, app_id)`, pattern-matches the old-shape ETS row
   `{key, sid, %{feishu_chat_proxy: pid}}`, calls `send(dead_pid, msg)` —
   Erlang silent no-op. **The user's `hello?` vanishes.**

**Five distinct production bugs** are at play:

| # | Bug | File:line |
|---|---|---|
| **B1** | 0-folder workspace is legal but unusable (data model split: `folders: []` + `location: {:esr_bound, ...}`) | `commands/workspace/new.ex:119-129` |
| **B2** | `PtyProcess.init` falls back to `dir: "/tmp"` when params lacks `:dir` | `entity/pty_process.ex:80` |
| **B3** | `Launcher.prepare_spawn` and `write_mcp_json` are dead — only called from tests; production goes through `spawn_cmd` which skips the file write | `plugins/claude_code/launcher.ex:68-183` |
| **B4** | FCP has no `handle_info/2` clause for `:pty_closed` | `plugins/feishu/feishu_chat_proxy.ex:274` |
| **B5** | `:esr_session_chat_routing` ETS has two coexisting row shapes (`register_session/3` writes 3-tuple with refs; `attach_session/3` writes 2-tuple with no refs). FAA absorbs the new shape with a silent `other -> Logger.warning + drop` (line 270) | `session/chat_routing/registry.ex` + `feishu_app_adapter.ex:270` |

**Operator intent (linyilun, 2026-05-11):** "session 建立的时候，就默认帮我
创建一个 agent（默认类型是 cc），后续我的操作应该让这个 agent 来帮我完成。
如果我需要添加新的 agent，既可以使用 slash 命令，也可以使用自然语言请主
agent 帮我来操作。"

This spec fixes B1-B5 and adds the natural-language admin layer.

---

## 2. Vocabulary

Inherits `docs/notes/concepts.md` (rev-11) + `CONTEXT.md`. New:

| Term | Definition |
|---|---|
| **silent-drop cascade** | The 4-step chain in §1 where a single production bug causes a chat-visible regression to disappear without any error reaching the operator |
| **lifecycle message** | A PubSub message representing a state transition: `:pty_closed`, `:agent_crashed`, `:supervisor_giveup` |
| **effect-level invariant** | A system-wide property (e.g. "no inbound is silently dropped") whose verification spans multiple supervisors |
| **dead code** | Code that compiles and is referenced from tests but never reached from the production code path |

---

## 3. Goals & non-goals

### Goals

- `/session:new <name>` reliably produces a chat → CC reply round-trip
- Every chat inbound either produces a chat-visible reply or chat-visible error within 5s — **no silent drops**
- Workspace data model is well-formed: every workspace has ≥1 folder; ESR-bound mode keeps working but as a real 1-folder workspace (not a 0-folder split-state)
- ESR exposes `submit_slash` MCP tool so CC can execute admin operations via natural language
- All proposed code paths anchor to real APIs verified in this rev
- Plugin boundaries respected: feishu plugin does NOT know about cc plugin's process types (per user 2026-05-11: "feishu 和 cc 是两个独立的 plugin")

### Non-goals

- **Not** changing `:one_for_all` on `Esr.Session.AgentInstanceSupervisor` —
  CC+PTY consistency invariant from spec Q5.3 sub-2 (2026-05-07) is correct.
  ADR-0002 records this so a future engineer doesn't reverse it.
- **Not** redesigning workspace ↔ folder as VS Code style — per concepts.md
  §四, Dir is a Resource referenced by Session, not owned. (Brainstorm
  decision 2026-05-11.)
- **Not** introducing rate-limiting on `submit_slash` — invariant I4 bounds
  damage; rate-limit deferred.
- **Not** keeping legacy support in esrd-dev fixtures — user 2026-05-11:
  "全部都可以删掉重建，不需要考虑后向兼容性".

---

## 4. Phase A — silent-drop cascade fix (PR-1 through PR-4)

Each sub-section names the verified file:line being modified and grounds
the proposed change in current code shape.

### 4.1 Workspace folders ≥1 + ESR-bound becomes 1-folder (fixes B1) — PR-1

**Current state** (`commands/workspace/new.ex:119-129`):
```elixir
location = case folder do
  nil -> {:esr_bound, Esr.Paths.workspace_dir(name)}
  path -> {:repo_bound, path}
end
folders = case folder do
  nil -> []                                  ← 0-folder split state
  path -> [%{path: path, name: Path.basename(path)}]
end
```

ESR-bound workspaces hold the path in `location` but `folders` is empty.
Every downstream (session create, dir resolve) reads `folders` → split
state surfaces as bug.

**Change:** unify. Both branches produce a 1+ folder workspace; ESR-bound
just uses the ESR-managed path as the first folder.

```elixir
folder_path = folder || Esr.Paths.workspace_dir(name)
folders = [%{path: folder_path, name: Path.basename(folder_path)}]
location = case folder do
  nil -> {:esr_bound, folder_path}
  path -> {:repo_bound, path}
end
# location is now redundant with folders[0].path BUT retained
# for backwards-compat readers; eventually removable.
```

`Esr.Paths.workspace_dir(name)` (the ESR-managed directory) gets created
on disk (`File.mkdir_p!`) at workspace creation so PtyProcess can `cd`
into it.

**Files touched:**
- `runtime/lib/esr/commands/workspace/new.ex` — body unification (~20 LOC)
- `runtime/priv/schemas/workspace.v1.json` — add `"folders": { "minItems": 1 }` (~3 LOC)
- `runtime/lib/esr/resource/workspace/json_writer.ex` — call `ExJsonSchema.Validator.validate(...)` before write (new dep; ~15 LOC). Or simpler: hand-roll a `Esr.Resource.Workspace.Struct.valid?/1` checking `length(folders) >= 1`.
- `runtime/lib/esr/commands/workspace/remove_folder.ex` — guard: refuse removing the last folder; return `:cannot_remove_last_folder` error.
- Tests (~40 LOC).

**Note on esrd-dev:** user's 2026-05-11 instruction — wipe and rebuild
~/.esrd-dev/, no migrator needed.

### 4.2 Make `Launcher.prepare_spawn` the only spawn entry; delete `spawn_cmd` (fixes B2 + B3) — PR-2

**Current state** (`plugins/claude_code/launcher.ex:68-183`):
- `prepare_spawn/1` — reads workspace dir, writes `.mcp.json`, builds claude argv, returns full spawn args. **Called only from tests.**
- `spawn_cmd/1` — builds claude argv with `--mcp-config .mcp.json` but does NOT write the file. **Called by `PtyProcess` at runtime/lib/esr/entity/pty_process.ex:202-216.**

**Change:**

1. **Delete `Launcher.spawn_cmd/1` entirely.** Move its caller in
   `entity/pty_process.ex:202-216` to call `Launcher.prepare_spawn/1` instead.
2. **`prepare_spawn/1` becomes the sole spawn entry.** Asserts (with
   `{:ok, _}` / `{:error, _}` returns, NOT `raise`):
   - `cwd` (workspace folder path) exists as a directory
   - `claude` binary on PATH
   - `.mcp.json` writes successfully to `session_dir`
   - argv includes `--mcp-config <session_dir>/mcp.json` (absolute path)
3. **Delete the `dir || "/tmp"` fallback** at `entity/pty_process.ex:80`.
   If `dir` is missing, return `{:error, :missing_dir}` to AgentSpawner.
4. **`.mcp.json` location: `$ESRD_HOME/<instance>/sessions/<sid>/mcp.json`.**
   Per brainstorm 2026-05-11: session-owned, not workspace-folder-owned.
   Path computed by a new helper `Esr.Paths.session_mcp_json(sid)`.
5. **`.mcp.json` content** (verified against existing `Launcher.write_mcp_json/1`):
   ```json
   {
     "mcpServers": {
       "esr-channel": {
         "type": "http",
         "url": "<esrd_http_base>/mcp/<session_id>"
       }
     }
   }
   ```
   `<esrd_http_base>` from `EsrWeb.Endpoint.config(:url)`; path-based session
   routing already exists at `EsrWeb.McpController` (verified — McpHttp
   Channel is a thin PubSub wrapper around the singleton controller, NOT
   a per-session port-binding HTTP server).

**Files touched:**
- `runtime/lib/esr/plugins/claude_code/launcher.ex` — delete `spawn_cmd/1`, generalize `prepare_spawn/1` to return `{:ok, args}` / `{:error, reason}` (~40 LOC of changes)
- `runtime/lib/esr/entity/pty_process.ex:80, :202-216` — remove `/tmp` fallback, call `prepare_spawn/1`, propagate errors (~30 LOC)
- `runtime/lib/esr/paths.ex` — add `session_mcp_json/1` helper (~10 LOC)
- `runtime/lib/esr/plugins/claude_code/launcher_test.exs` — adjust tests to use the new entry point (~20 LOC)

### 4.3 SessionTemplate pipeline integrity check (plugin-decouple framing) — PR-2

**User insight (2026-05-11):** "feishu 和 cc 是两个独立的 plugin，最终形态下，
按照 feishu 的用户不一定会安装 cc... 问题出在 SessionTemplate 没有被编译好，
导致这里面环节中出现了 process 被丢失的情况"

The original spec rev-1 wanted FCP to monitor CCProcess. That violates
plugin independence: FCP should not know CC's process type. The correct
architectural fix is: **SessionTemplate's materializer verifies the
pipeline is whole before declaring session ready**.

**Current state:** `AgentSpawner.do_create/1` (`runtime/lib/esr/session/agent_spawner.ex:178-188`)
iterates `pipeline.inbound` and calls `spawn_one/5` for each peer (line 364).
On any spawn failure it throws `{:spawn_failed, spec, reason}` which is
caught and returned. **However:** the throw cleanup may leave intermediate
peers running (the failure happens mid-iteration; already-spawned peers
are not torn down).

**Change:**
1. In `agent_spawner.ex`, wrap `spawn_pipeline/3` in a try/throw block that
   on partial failure calls `Esr.Session.Router.end_session(sid)` to tear
   down everything spawned so far. Verified API at
   `runtime/lib/esr/session/router.ex:67-69`.
2. Add a final post-spawn assertion: **after all stages complete, verify
   each declared pipeline stage has a registered live pid** in the per-
   session `Esr.Entity.Agent.InstanceRegistry`. If any stage is missing,
   tear down and return `:pipeline_incomplete`.
3. `/session:new` propagates the error to the operator with a structured
   error reply listing which stage failed and why.

**Files touched:**
- `runtime/lib/esr/session/agent_spawner.ex` — wrap `spawn_pipeline/3`, add post-spawn integrity check (~50 LOC)
- `runtime/lib/esr/commands/session/new.ex` — surface `:pipeline_incomplete` as a chat reply (~10 LOC)
- Tests (~30 LOC).

### 4.4 FCP `:pty_closed` clause (plugin-self-consistent) (fixes B4) — PR-2

FCP subscribes to `pty:<actor_id>` PubSub at init (verified at
`feishu_chat_proxy.ex:162`). Add the missing clause:

```elixir
@impl GenServer
def handle_info(:pty_closed, state) do
  # The downstream PTY (whoever owns it; FCP doesn't care about the
  # specific agent kind) has exited. Tell the chat; let supervisor
  # decide restart. Plugin boundary preserved: this clause doesn't
  # mention CC at all.
  notify_chat(state, %{
    kind: :downstream_died,
    message: "agent process exited; supervisor will restart if " <>
             "possible. If this repeats, run /session:end then " <>
             "/session:new to rebuild."
  })
  {:noreply, state}
end
```

`notify_chat/2` constructs a chat reply via existing FCP reply path
(`emit_reply_envelope/2` or similar). The message text does not name
"CC" or "claude" — it says "agent process", maintaining plugin
neutrality.

**No `{:DOWN, _, _, cc_pid, _}` monitor** — FCP does not know cc_process.
That would violate plugin independence. The lifecycle signal comes via
the pty PubSub topic which any plugin's PTY can publish to.

**Supervisor giveup notification:** if `AgentInstanceSupervisor` exits
(max_restarts), FCP doesn't directly observe it via `:pty_closed` (which
fires on each PTY death, not the final supervisor exit). The
LifecycleObserver in §4.6 fills this gap.

**Files touched:**
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:274` — add clause (~30 LOC)
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:?` — add `notify_chat/2` helper if not present (~30 LOC)
- Tests (~40 LOC).

### 4.5 ChatRouting: delete legacy register_session, unify on attach (fixes B5) — PR-3

**Current state** (`session/chat_routing/registry.ex`):
- `register_session/3` (line 63) — single caller `agent_spawner.ex:460`, writes ETS row `{(chat_id, app_id), sid, peer_refs}` (3-tuple, has refs)
- `attach_session/3` (line 74) — `/session:bind-chat` etc, writes ETS row `{(chat_id, app_id), %{current: sid, attached: [...]}}` (2-tuple, no refs)
- `lookup_by_chat/2` returns three shapes; FAA matches old-shape and absorbs new-shape via `other -> drop`

This is the dual-shape ETS bug class. Plus the API name `register_session`
is a leaky abstraction — it's just "write a row" exposed as if it had
semantic meaning.

**Change:** delete legacy. One ETS shape, one API.

1. **Delete `register_session/3` and `unregister_session/1`** from the
   registry module.
2. **Migrate the sole caller** `agent_spawner.ex:460` to use
   `attach_session(chat_id, app_id, sid)` (no peer refs).
3. **Migrate `agent_spawner.ex:145` + `router.ex:121`** (the two
   `unregister_session/1` callers) to a new `detach_session/3` if not
   already present, or `delete_by_session/1`.
4. **FAA route logic** (`feishu_app_adapter.ex:238`) updates to:
   ```elixir
   case ChatRouting.Registry.current_session(chat_id, app_id) do
     {:ok, sid} ->
       case Esr.Entity.Agent.InstanceRegistry.fcp_for_session(sid) do
         {:ok, fcp_pid} when is_pid(fcp_pid) ->
           if Process.alive?(fcp_pid) do
             send(fcp_pid, {:feishu_inbound, envelope})
           else
             # Stale pid — clean up + error
             cleanup_and_reply(chat_id, app_id, sid, :session_dead)
           end
         :not_found ->
           # Session exists in routing but has no FCP registered.
           # This is :pipeline_incomplete recovery.
           cleanup_and_reply(chat_id, app_id, sid, :session_incomplete)
       end

     :not_found ->
       handle_unbound_chat(envelope)  # existing :new_chat_thread broadcast
   end
   ```
   **No `other ->` catch-all.** Every case is explicit. (Verified shape of
   `current_session/2` at `chat_routing/registry.ex:99` — it returns
   `{:ok, sid}` or `:not_found`. After legacy deletion that's the only
   two cases.)
5. **Add `fcp_for_session(sid)` to InstanceRegistry** — currently
   `Esr.Entity.Agent.InstanceRegistry` indexes by role; need a convenience
   lookup that filters role=`:feishu_chat_proxy` for a given sid.
   Probably ~20 LOC delegating to existing `list_by_role/2`.

**Files touched:**
- `runtime/lib/esr/session/chat_routing/registry.ex` — delete legacy API + persistence code (~80 LOC removed)
- `runtime/lib/esr/session/agent_spawner.ex:145, :460` — migrate callers (~10 LOC)
- `runtime/lib/esr/session/router.ex:121` — migrate caller (~5 LOC)
- `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238-275` — replace pattern + delete `other -> Logger.warning + drop` (~40 LOC)
- `runtime/lib/esr/entity/agent/instance_registry.ex` — add `fcp_for_session/1` (~20 LOC)
- Tests + cleanup of obsolete fixtures (~50 LOC).

### 4.6 LifecycleObserver + ETS cleanup — PR-3

Per-session observer process. Spawned alongside session by `/session:new`
or `AgentSpawner.do_create/1`. Lives in a top-level supervisor
(`Esr.Session.LifecycleObservers`) — survives session subtree death.

```elixir
defmodule Esr.Session.LifecycleObserver do
  use GenServer
  require Logger

  def start_link(%{session_id: sid, session_sup_pid: sup_pid,
                   chat_id: chat_id, app_id: app_id}) do
    GenServer.start_link(__MODULE__, %{sid: sid, chat_id: chat_id,
                                       app_id: app_id, sup_pid: sup_pid})
  end

  def init(state) do
    Process.monitor(state.sup_pid)
    {:ok, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("session #{state.sid} supervisor exited: #{inspect(reason)}")
    # Tell the chat (best-effort via FAA reply route — FCP is dead at this point).
    Esr.Plugins.Feishu.FeishuAppAdapter.reply_chat_error(
      state.chat_id, state.app_id, :session_terminated,
      "session #{state.sid} 异常终止: #{inspect(reason)}"
    )
    # Clean ETS routing entry.
    Esr.Session.ChatRouting.Registry.detach_session(
      state.chat_id, state.app_id, state.sid)
    {:stop, :normal, state}
  end
end
```

**Files touched:**
- New: `runtime/lib/esr/session/lifecycle_observer.ex` (~70 LOC)
- New: `runtime/lib/esr/session/lifecycle_observers.ex` — DynamicSupervisor for observers (~20 LOC)
- `runtime/lib/esr/session/agent_spawner.ex` — start observer post-spawn (~10 LOC)
- Tests (~40 LOC).

### 4.7 System invariants + ChaosScenarios DSL — PR-3

`docs/notes/system-invariants.md` (new):

| ID | Invariant | Verified by |
|---|---|---|
| **I1** | Every chat inbound reaching FAA produces a chat-visible reply or chat-visible error within 5 seconds | `invariant_test/1` in `invariants_test.exs` using ChaosScenarios |
| **I2** | Every alive entry in `:esr_session_chat_routing` ETS points at a real session with a live FCP in InstanceRegistry | `eventually` poll |
| **I3** | A session_dir exists iff its supervisor tree has alive root | observer-based check |
| **I4** | Agent process death (any cause, including supervisor giveup) produces a chat-visible lifecycle reply within 5 seconds | direct timing |
| **I5** | No routing code uses `other -> Logger.warning + drop` | grep CI gate on file content |

`runtime/test/support/chaos_scenarios.ex` (new): `~80 LOC` macro library
with helpers `chaos_inject/2`, `assert_chat_reply_within/1`, `eventually/2`,
`setup_session_with_listener/0`, `kill_role_in_session/2`.

`runtime/test/esr/system/invariants_test.exs` (new): I1-I5 implementations
(~120 LOC).

**Files touched:**
- New: `runtime/test/support/chaos_scenarios.ex`
- New: `runtime/test/esr/system/invariants_test.exs`
- New: `docs/notes/system-invariants.md`

### 4.8 Real-claude integration test — PR-4

`runtime/test/esr/integration/real_claude_boot_test.exs` (new). Tag
`:real_claude`. CI runs on macos-latest only (per Phase 1 of
guide-driven-e2e CI policy):

```elixir
@moduletag :real_claude

setup do
  case System.find_executable("claude") do
    nil -> {:skip, "claude not on PATH"}
    _ -> :ok
  end
end

test "real claude boots, mcp.json written, chat reply round-trip" do
  {:ok, ws} = setup_real_workspace_with_folder()
  {:ok, sid} = Esr.Session.Router.create_session(real_params(ws))

  assert eventually(fn ->
    File.exists?(Esr.Paths.session_mcp_json(sid)) and
    instance_registry_has_role?(sid, :feishu_chat_proxy) and
    instance_registry_has_role?(sid, :cc_process) and
    cc_mcp_ready?(sid)  # subscribe to PubSub topic cc_mcp_ready/<sid>
  end, 30_000)

  send_test_inbound("hello", sid, ws.chat)
  assert_receive {:chat_reply, _}, 60_000

  :ok = Esr.Session.Router.end_session(sid)
end
```

`cc_mcp_ready?/1` subscribes to topic `cc_mcp_ready/<sid>` (verified —
broadcast by `EsrWeb.McpController` on first MCP request).

**Files touched:**
- New: `runtime/test/esr/integration/real_claude_boot_test.exs` (~80 LOC)
- `.github/workflows/ci.yml` — add macos-latest job running `mix test --only real_claude` (~30 LOC of workflow YAML; user previously authorized macos-CI scope in guide-driven-e2e Phase 1)

### 4.9 `mix esr.audit_supervision` — PR-3

`runtime/lib/mix/tasks/esr.audit_supervision.ex` (new). Walks live
supervision tree via `Supervisor.which_children/1`, compares against
`docs/notes/supervisor-inventory.md` snapshot. Non-empty diff fails the
CI gate.

Initial snapshot committed in PR-3 as the baseline. Future supervisor
changes require updating the snapshot, forcing intentional ack.

**Files touched:**
- New: `runtime/lib/mix/tasks/esr.audit_supervision.ex` (~80 LOC)
- New: `docs/notes/supervisor-inventory.md` (baseline)
- `.github/workflows/ci.yml` — add gate (~5 LOC YAML)

### 4.10 ADR-0002 — PR-3

`docs/adr/0002-cc-pty-pair-one-for-all-invariant.md` (new). Records the
`AgentInstanceSupervisor :one_for_all` design choice from spec Q5.3 sub-2
(2026-05-07). Same content as rev-1, unchanged.

---

## 5. Phase B — `submit_slash` MCP tool via real SlashHandler API (PR-4)

**Real `SlashHandler.dispatch/2` signature** (verified at
`runtime/lib/esr/entity/slash_handler.ex:112-115`):
```elixir
@spec dispatch(map(), reply_to()) :: reference()
def dispatch(envelope, reply_to)
```
- Second arg is reply target, NOT options.
- Returns `reference()` — the async dispatch ref.
- Submitter lives inside the envelope: `args.submitted_by`.

### 5.1 Tool registration

`runtime/lib/esr/plugins/claude_code/mcp/tools.ex` adds:
```elixir
@admin_tool %{
  name: "submit_slash",
  description: """
  Execute an ESR slash command on behalf of the operator. Use when the
  user asks (in any language) to perform admin work: adding agents,
  listing sessions, switching workspace, etc. Returns structured result.
  """,
  input_schema: %{
    type: "object",
    properties: %{
      command: %{type: "string",
                 description: "Full slash command with leading /, e.g. /agent:add type=cc name=helper"}
    },
    required: ["command"]
  }
}
```

### 5.2 Handler — anchored to real dispatch contract

```elixir
def handle_submit_slash(%{"command" => cmd_str}, mcp_state) do
  # mcp_state.session_id is known (cc_mcp Channel was started with it).
  # Resolve chat_ctx by looking up session metadata.
  sid = mcp_state.session_id

  with {:ok, ctx} <- resolve_chat_ctx_for_session(sid) do
    envelope = %{
      "id" => "submit-#{UUID.uuid4()}",
      "kind" => "event",
      "payload" => %{
        "args" => Map.merge(ctx, %{
          "content" => cmd_str,
          "msg_type" => "text"
        }),
        "event_type" => "msg_received"
      },
      "source" => "esr://localhost/submit_slash",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "event",
      "principal_id" => ctx["submitted_by"]
    }

    # Use a per-call collector pid as reply_to to capture the result.
    {collector_pid, ref} = spawn_result_collector()
    _dispatch_ref = Esr.Entity.SlashHandler.dispatch(envelope, collector_pid)

    # Wait for reply (with timeout)
    receive do
      {:slash_result, ^ref, result} -> {:ok, result}
      {:slash_error, ^ref, reason} -> {:error, %{kind: reason}}
    after
      30_000 -> {:error, %{kind: :slash_timeout}}
    end
  end
end

defp resolve_chat_ctx_for_session(sid) do
  # Look up session metadata to find chat_id / app_id / submitter.
  case Esr.Resource.Session.Registry.get(sid) do
    {:ok, session} ->
      {:ok, %{
        "chat_id" => session.chat_id,
        "app_id" => session.app_id,
        "submitted_by" => session.principal_id  # chat-bound user
      }}

    :not_found ->
      {:error, %{kind: :session_not_found}}
  end
end
```

**Auth:** `submitted_by` is the chat-bound user (session.principal_id),
NOT ou_admin. CC operates with the operator's capabilities. Cap-denied
slashes return `:missing_capability`, which CC translates to natural
language for the user.

### 5.3 CC skill prompt

`runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md` (new):

```markdown
# Admin Operations Skill

If the operator asks you (in any language) to perform an ESR admin
operation — add an agent, list sessions, register an adapter, change
workspace, etc. — use the `submit_slash` MCP tool.

Examples:
- 用户："加个新 agent 叫 helper" → submit_slash(command="/agent:add type=cc name=helper")
- 用户："列出现在的 session" → submit_slash(command="/session:list")
- 用户："换到 my-other workspace" → submit_slash(command="/workspace:use my-other")

If submit_slash returns an error, translate it into the user's language
and explain what they need to do next. Do not silently retry; ask the
operator for direction.

Slashes available: /help.
```

Injected into CC's system prompt at agent start (via `--system-prompt`
or equivalent in `Launcher.prepare_spawn/1`).

### 5.4 Tests

- Unit: `submit_slash_handler_test.exs` — chat_ctx resolution, principal_id threading, error translation.
- Integration: extend `real_claude_boot_test.exs` with a follow-up assertion: after boot, CC successfully calls `submit_slash(command="/session:list")` and gets the current session back.

---

## 6. Migration plan — 4 PRs

| PR | Title | LOC est | Contents |
|---|---|---|---|
| **PR-1** | `feat(workspace): folders ≥1 + ESR-bound 1-folder unification` | ~120 | §4.1 |
| **PR-2** | `fix(session): delete spawn_cmd dead code + FCP :pty_closed handler + pipeline integrity check` | ~250 | §4.2 + §4.3 + §4.4 |
| **PR-3** | `feat(supervision): unify ChatRouting on attach + LifecycleObserver + ChaosScenarios + audit + ADR-0002` | ~400 | §4.5 + §4.6 + §4.7 + §4.9 + §4.10 |
| **PR-4** | `feat(agent): submit_slash MCP tool + CC admin skill + real-claude integration test` | ~270 | §4.8 + §5 |

**Total ~1040 LOC across 4 PRs.** Net LOC will be lower than estimate
because §4.5 + §4.2 delete dead/legacy code.

**Dependency order:**
- PR-1 before PR-2 (§4.2 cwd resolution depends on §4.1 unified folders)
- PR-2 before PR-3 (lifecycle handlers must exist before ChaosScenarios
  can verify invariant I4)
- PR-3 before PR-4 (real-claude test depends on lifecycle visibility +
  unified ChatRouting)

---

## 7. Acceptance criteria

| # | Acceptance | Verify |
|---|---|---|
| 1 | `/workspace:new name=X` (no folder=) creates a workspace with `folders: [%{path: <esr_managed_dir>}]` and `<esr_managed_dir>` exists on disk | unit test |
| 2 | `/workspace:new name=X folder=/some/dir` creates `folders: [%{path: "/some/dir"}]` | unit test |
| 3 | `/session:new name=test-cc` after `/workspace:use test-dev` (where test-dev has ≥1 folder) succeeds; PtyProcess starts with cwd = workspace folder, NOT `/tmp` | manual replay 2026-05-11 hang + unit |
| 4 | Real `claude` binary starts when launched via `Launcher.prepare_spawn/1`; `.mcp.json` exists at `$session_dir/mcp.json` with correct content | real-claude integration test |
| 5 | After `/session:new`, sending plain `hello?` produces a chat-visible reply from CC (or chat-visible error within 5s) | manual + I1 |
| 6 | Killing PtyProcess produces chat-visible `:downstream_died` reply within 5s | I4 |
| 7 | `AgentInstanceSupervisor` exhausting max_restarts produces chat-visible `:session_terminated` reply; ETS routing entry deleted by LifecycleObserver | I2 + I4 |
| 8 | `rg "register_session\|unregister_session\|other -> Logger\.warning" runtime/lib/` returns 0 matches | I5 + grep CI |
| 9 | `mix esr.audit_supervision` runs green | CI gate |
| 10 | Real-claude integration test boots + receives chat reply | macos-latest CI |
| 11 | CC executes `/agent:add type=cc name=helper` when user says "加个 helper agent" | manual Feishu + integration |

---

## 8. Open questions / future work

`docs/futures/todo.md` tracks. **Closed by this spec:**
- `phase-3-fence-cc-reply` → see §4.8 (real-claude test) + flow-bootstrap.md fence #5 re-enabled
- `unconsumed-message-errors-not-hangs` → resolved by §4.4 + §4.5 + §4.6 (I1)

**Still open, this spec depends on or interacts with:**
- `structured-reply-envelope` (`docs/futures/todo.md:37`) — this spec assumes
  structured replies. If that todo doesn't ship first, `notify_chat/2` uses
  a minimal local envelope shape and the full schema lands in a follow-up.
  (rev-1 reference to closed task #220 was a stale mis-attribution; rev-2
  corrects to `structured-reply-envelope`.)
- `e2e-15-principal-isolation` — submit_slash with a non-admin principal
  needs testing once a non-admin test principal exists in the e2e fixture.

---

## 9. Approval gate

The user (linyilun) approves on Feishu. On approval:
1. This spec is committed + zh_cn mirror pushed
2. Plan written via `superpowers:writing-plans` to
   `docs/superpowers/plans/2026-05-11-default-agent-and-agent-driven-flow-plan.md`
3. Implementation begins with PR-1
