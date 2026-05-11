# Default agent on session creation + agent-driven follow-up operations

**Status:** Draft — pending user approval (linyilun, 2026-05-11)
**Date:** 2026-05-11
**Author:** Claude (with linyilun)
**Companion:** [`.zh_cn.md`](2026-05-11-default-agent-and-agent-driven-flow-design.zh_cn.md)

Worktree: `.worktrees/fix-unconsumed-msg`, branch `spec/default-agent-and-agent-driven-flow`.

---

## 1. Why now

On 2026-05-11 the operator (linyilun) ran a manual Feishu test:

```
/workspace:use test-dev    → ok: %{"action" => "default_workspace_set", ...}
/session:list              → workspace test-dev: no live sessions
/session:new name=test-cc  → session started: b6bfbe47-...
hello?                     → (NO REPLY — silent hang)
```

The `hello?` was silently dropped. Investigating `~/.esrd-dev/default/logs/launchd-stdout.log`
revealed a 5-step cascade rooted in two production bugs and amplified by three
silent-drop bug classes:

1. **PtyProcess launched `claude` with `dir=/tmp`** (workspace `test-dev` had 0
   folders; the resolve-dir code fell through to `/tmp`). `claude` reads
   `.mcp.json` from `cwd`; `/tmp/.mcp.json` doesn't exist; `claude` refuses to
   start and exits 256.
2. **PtyProcess GenServer crashed** with `{:pty_crashed, 256}`. Per the
   `Esr.Session.AgentInstanceSupervisor` `:one_for_all` strategy (deliberate
   per spec Q5.3 sub-2, 2026-05-07: CC + PTY must move together), the CC
   process was killed too.
3. **PtyProcess `terminate/2` broadcast `:pty_closed` to FCP** via PubSub.
4. **`Esr.Plugins.Feishu.FeishuChatProxy.handle_info/2` has no clause for
   `:pty_closed`** → `FunctionClauseError` at
   `feishu_chat_proxy.ex:274` → FCP crashes with the same error every time
   it receives `:pty_closed`.
5. **Cascade**: PTY restarts (via `:one_for_all`) → claude exits 256 again
   → PTY crashes → FCP gets `:pty_closed` → FunctionClauseError →
   `AgentInstanceSupervisor` hits `max_restarts: 3` in 60s → instance
   subtree terminated with `restart: :transient` (no auto-restart).
6. **`:esr_session_chat_routing` ETS entry still points at the now-dead FCP
   pid**. FAA looks up by `(chat_id, app_id)`, gets the dead pid, calls
   `send(dead_pid, msg)` — Erlang silent no-op. The user's `hello?` vanishes.

**Manual test from operator (linyilun, 2026-05-11):** "session 建立的时候，
就默认帮我创建一个 agent（默认类型是 cc），后续我的操作应该让这个 agent
来帮我完成。如果我需要添加新的 agent，既可以使用 slash 命令，也可以使用
自然语言请主 agent 帮我来操作。"

The "default agent on session" intent IS already implemented (SessionTemplate
+ AgentSpawner.do_create + cc_mcp Channel). The bugs above prevent it from
working in production. This spec fixes the cascade AND adds the natural-language
admin layer that completes the operator's mental model.

---

## 2. Vocabulary

This spec inherits all terms from `docs/notes/concepts.md` (rev-11) and
`CONTEXT.md`. New terms:

| Term | Definition |
|---|---|
| **silent-drop cascade** | The 5-step chain in §1 where a single production bug causes a chat-visible regression to disappear without an error |
| **lifecycle message** | A PubSub or direct-send message representing a state transition: `:pty_closed`, `{:agent_crashed, _}`, `{:supervisor_giveup, _}` |
| **effect-level invariant** | A system-wide property (e.g. "no inbound is silently dropped") whose verification spans multiple supervisors; contrasted with per-supervisor invariants |
| **ChaosScenarios DSL** | A test macro library (this spec introduces) that lets us declare "kill child X under chaos, assert system invariant Y holds" |

---

## 3. Goals & non-goals

### Goals

- `/session:new <name>` reliably produces a working chat → CC reply round-trip
  (the original design intent finally lands in production).
- Every chat inbound either produces a chat-visible reply or a chat-visible
  error within 5 seconds. **No silent drops.**
- Workspace data model becomes well-formed: workspace ⊇ ≥1 folder, enforced
  at write time.
- ESR exposes a `submit_slash` MCP tool so CC can execute admin operations
  on behalf of the user via natural language.
- A test scaffold (real-claude boot + ChaosScenarios + audit mix task) prevents
  this bug class from recurring.

### Non-goals

- **Not** changing the `:one_for_all` strategy on `AgentInstanceSupervisor`.
  That decision (spec Q5.3 sub-2, 2026-05-07) is correct: CC + PTY must move
  together. ADR-0002 records this so a future engineer doesn't unwittingly
  reverse it.
- **Not** redesigning the workspace → folder relationship to VS Code style
  (workspace contains all per-session state). Per concepts.md §四,
  Resources (Dirs) are independent and shareable across Sessions; the
  current parallel `workspaces/` + `sessions/` layout is correct.
- **Not** introducing rate-limiting on `submit_slash`. If CC misbehaves,
  invariant I4 (chat reply within 5s) bounds the damage; explicit rate
  limit deferred.
- **Not** supporting `submit_slash` from a non-CC agent in v1. Bundle author
  can opt in later by exposing the tool from their own channel.

---

## 4. Phase A — silent-drop cascade fix (PR-1, PR-2, PR-3)

### 4.1 Workspace ≥1 folder invariant (PR-1, ~120 LOC)

Workspaces with zero folders are data corruption: every downstream consumer
(session create, agent spawn, claude cwd) needs a real path. Enforce at three
layers:

**A. schema:** `runtime/priv/schemas/workspace.v2.json` (or v3 if v2 is
post-Phase-1 of session-first migration) gains `folders: { minItems: 1 }`.
`Esr.Resource.Workspace.JsonWriter.write/2` validates the struct against the
schema before persisting; 0-folder write returns `{:error, :empty_folders}`.

**B. commands:**
- `/workspace:new name=X path=Y` — `path` becomes required (was optional);
  on success the workspace starts with one folder seeded from `path`. Updates
  to `Esr.Commands.Workspace.New.command_meta/0`.
- `/workspace:remove-folder workspace=X path=Y` — adds a guard: if removing
  this folder leaves the workspace at 0 folders, return
  `:cannot_remove_last_folder` with message "workspace %{name} has only
  1 folder; use /workspace:remove to delete the entire workspace instead".

**C. boot:** Since `~/.esrd-dev/` may be wiped + rebuilt per user instruction
(2026-05-11 Feishu: "esrd-dev 中的文件，全部都可以删掉重建，不需要考虑后向兼容性"),
no boot validator for legacy 0-folder workspaces is needed. The schema-level
constraint plus the command guards ensure no new 0-folder state can be
created.

**D. tests:**
- `runtime/test/esr/commands/workspace/new_test.exs` — `path` missing returns
  meta-DSL validation error.
- `runtime/test/esr/commands/workspace/remove_folder_test.exs` — removing the
  last folder returns `:cannot_remove_last_folder`.
- `flow-bootstrap.md` fence #3 (`/workspace:new`) passes `path=` explicitly.

### 4.2 `/session:new` pre-flight + `.mcp.json` generation (PR-2, ~280 LOC)

Replace the partial pre-flight in `Esr.Commands.Session.New.execute/2` with a
single `pre_flight/3` function that fails fast on any unmet pre-condition.

```elixir
defp pre_flight(args, submitter, chat_ctx) do
  with {:ok, claude_path}    <- check_claude_binary(),
       {:ok, workspace}      <- resolve_workspace(args, chat_ctx),
       {:ok, cwd}            <- pick_primary_folder_path(workspace),
       {:ok, session_dir}    <- prepare_session_dir(args[:sid]),
       {:ok, template_name}  <- resolve_template_name(args),
       {:ok, agent_def}      <- materialize_template(template_name) do
    {:ok, %{claude_path: claude_path, workspace: workspace, cwd: cwd,
            session_dir: session_dir, agent_def: agent_def}}
  end
end
```

**Error returns are structured** (link to `structured-reply-envelope` design
in `docs/futures/todo.md`). Concrete error kinds:

| Kind | When | Chat reply |
|---|---|---|
| `:missing_claude_binary` | `System.find_executable("claude")` nil | "claude binary not found on PATH; install Claude Code" |
| `:workspace_not_bound` | M-5 resolution chain returns nothing | "no workspace bound to this chat; run /workspace:use <name> first" |
| `:empty_workspace` | resolved workspace has 0 folders (defense-in-depth even though §4.1 prevents creation) | "workspace %{name} has no folders; run /workspace:add-folder first" |
| `:template_not_found` | template resolution returns `:not_found` | "template %{name} not found; available: ..." |

**`.mcp.json` generation lives in `session_dir`, NOT in the workspace folder:**

- Path: `$ESRD_HOME/<instance>/sessions/<sid>/mcp.json`
- Why not in workspace folder: see §3 non-goals + concepts.md §四 (Dir is a
  shared Resource; multi-session-per-workspace would conflict on a shared
  `.mcp.json`).
- Generation timing: AFTER cc_mcp Channel `start_link/1` returns
  `{:ok, %{port: N}}` (so we know the ephemeral port), BEFORE PtyProcess
  `start_link/1` (so claude can read it). The spawn pipeline becomes:
  ```
  AgentSpawner.do_create
    ↓
    1. Start cc_mcp Channel  → returns {:ok, %{port: N}}
    ↓
    2. Write session_dir/mcp.json with port=N
    ↓
    3. Start CCProcess (which doesn't shell out)
    ↓
    4. Start PtyProcess with cmd =
       claude --mcp-config $session_dir/mcp.json --cwd $cwd
  ```

**`.mcp.json` schema:**
```json
{
  "mcpServers": {
    "esr-channel": {
      "type": "http",
      "url": "http://127.0.0.1:<port>/mcp"
    }
  }
}
```

**Spawn-failure cleanup:** if any step 1–4 returns `{:error, _}`, AgentSpawner
calls `Esr.Session.Supervisor.stop_session(sid)`, deletes the
`:esr_session_chat_routing` ETS entry for the chat, and returns the error to
the command handler. **No half-started state.**

### 4.3 FCP explicit lifecycle handlers (PR-2, ~80 LOC)

`runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` adds explicit
`handle_info/2` clauses for every lifecycle message it may receive. The
current `FunctionClauseError` from §1 step 4 disappears.

```elixir
@impl GenServer
def handle_info(:pty_closed, state) do
  notify_chat(state, :agent_died, %{
    message: "claude agent exited; supervisor will restart shortly. If this " <>
             "repeats, run /session:end and /session:new to recover."
  })
  {:noreply, %{state | agent_state: :pty_restarting}}
end

def handle_info({:DOWN, _ref, :process, pid, reason}, state) when pid == state.cc_process_pid do
  notify_chat(state, :cc_crashed, %{reason: inspect(reason)})
  {:noreply, %{state | agent_state: :cc_restarting}}
end

def handle_info({:supervisor_giveup, sid}, state) when sid == state.session_id do
  notify_chat(state, :session_fatal, %{
    message: "session #{sid} exceeded max_restarts and was terminated. " <>
             "Run /session:end + /session:new to rebuild."
  })
  cleanup_routing_entry(state)
  {:stop, :normal, state}
end
```

`notify_chat/3` formats a structured envelope (link `structured-reply-envelope`)
and forwards it through the existing Feishu reply path.

`{:supervisor_giveup, sid}` is broadcast by the per-session
**`Esr.Session.LifecycleObserver`** introduced in §4.4.

### 4.4 ETS cleanup + LifecycleObserver + `Process.alive?` guards (PR-3, ~130 LOC)

**`Esr.Session.LifecycleObserver`** — a per-session GenServer that survives
its supervisor tree's death. Spawned by `/session:new` (registered in an
instance-level `Esr.Session.LifecycleObservers` registry), it
`Process.monitor`s the session supervisor pid. On `:DOWN`, it:

1. Broadcasts `{:supervisor_giveup, sid}` to the FCP (if FCP alive).
2. Deletes the `:esr_session_chat_routing` entry for the session.
3. Logs `Logger.warning "session #{sid} terminated; reason=#{inspect(reason)}"`.
4. Stops itself.

**FAA route-time alive check** —
`runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238` (the
`do_handle_upstream_inbound/5` lookup site):

```elixir
case Esr.Session.ChatRouting.Registry.lookup_by_chat(chat_id, app_id) do
  {:ok, _sid, %{feishu_chat_proxy: pid}} when is_pid(pid) ->
    if Process.alive?(pid) do
      send(pid, {:feishu_inbound, envelope})
    else
      # Stale entry — clean up + surface to chat
      :ok = Esr.Session.ChatRouting.Registry.delete_by_chat(chat_id, app_id)
      reply_chat_error(chat_id, app_id, :stale_session,
        "session for this chat died; run /session:new to recreate")
    end

  :not_found ->
    # existing handling: PubSub broadcast :new_chat_thread for auto-spawn
    handle_unbound_chat(envelope)
end
# NO `other ->` catch-all. Any unexpected return shape → MatchError → crash → supervisor.
```

### 4.5 `other ->` catch-all sweep (PR-3, ~60 LOC across files)

Grep target: `rg -n "other ->" runtime/lib/`. For each hit, decide:

| Hit type | Rewrite |
|---|---|
| Routing / lifecycle code (FAA, Router, SlashHandler) | Replace with explicit `:ok`, `:not_found`, etc.; let MatchError crash on unexpected shape |
| Cosmetic catch-all in a non-critical GenServer.handle_info that should ignore unknown messages | Rewrite as `_other -> :ok` with inline comment "intentional ignore" |
| Value-coercion fallback (`other -> default`) | Rewrite as `:error` and let the caller decide |

Tracked in invariant I5 (see §4.6).

### 4.6 System-level invariants + ChaosScenarios DSL (PR-3, ~150 LOC)

Capture cross-supervisor effect-level invariants in a single source of truth.

**`docs/notes/system-invariants.md`** — a prescriptive list:

| ID | Invariant | Verified by |
|---|---|---|
| **I1** | Every chat inbound that reaches FAA results in a chat-visible reply or chat-visible error within 5 seconds | `chaos_invariant_test/1` in `invariants_test.exs` |
| **I2** | Every entry in `:esr_session_chat_routing` ETS points at a process where `Process.alive?(pid) == true` | `eventually(fn -> ... end)` after chaos injection |
| **I3** | A session has on-disk state (`session_dir/`) iff its supervisor tree is alive | observer pattern in `invariants_test.exs` |
| **I4** | Agent death (any cause, including supervisor giveup) produces a chat-visible lifecycle reply within 5 seconds | direct timing assertion |
| **I5** | No routing-layer code uses `other -> Logger.warning + drop` catch-all | grep CI gate (file scan, not runtime) |

**`Esr.Test.ChaosScenarios` macro** (`runtime/test/support/chaos_scenarios.ex`):

```elixir
defmodule Esr.Test.ChaosScenarios do
  defmacro invariant_test(description, do: block) do
    quote do
      test "INVARIANT: " <> unquote(description) do
        unquote(block)
      end
    end
  end

  def chaos_inject(targets, opts \\ []) do
    times = Keyword.get(opts, :times, 1)
    Enum.each(1..times, fn _ ->
      target = Enum.random(List.wrap(targets))
      pid = resolve_chaos_target(target)
      if pid && Process.alive?(pid), do: Process.exit(pid, :kill)
      Process.sleep(50)
    end)
  end

  def assert_chat_reply_within(timeout_ms) do
    assert_receive {:chat_reply, _}, timeout_ms
  end
end
```

Tests in `runtime/test/esr/system/invariants_test.exs`:

```elixir
use Esr.Test.ChaosScenarios

invariant_test "I1: every inbound produces a reply under chaos" do
  {:ok, sid} = setup_session_with_chat_listener()
  chaos_inject([:kill_pty, :kill_cc, :kill_channel], times: 5)
  send_chat_text("hello?")
  assert_chat_reply_within(5_000)
end

invariant_test "I2: ETS routing has no dead pids" do
  {:ok, sid} = setup_session()
  chaos_inject(:kill_pty)
  eventually(fn ->
    Enum.all?(ets_routing_entries(), fn {_key, _sid, refs} ->
      Enum.all?(Map.values(refs), &Process.alive?/1)
    end)
  end, 3_000)
end

# I3, I4, I5 likewise
```

### 4.7 Real-claude boot integration test (PR-4, ~80 LOC)

`runtime/test/esr/integration/real_claude_boot_test.exs` — **the test that
would have caught today's regression**. Tagged `:real_claude`; the CI step
runs `mix test --only real_claude` on macos-latest (per Phase 1 of
guide-driven-e2e CI policy).

```elixir
@moduletag :real_claude

setup do
  case System.find_executable("claude") do
    nil -> {:skip, "claude not on PATH"}
    _ -> :ok
  end
end

test "real claude boots and responds via cc_mcp end-to-end" do
  {:ok, workspace} = setup_real_workspace_with_folder()
  {:ok, sid} = Esr.Session.Router.create_session(real_session_params(workspace))

  # Wait for cc_mcp + mcp.json + claude handshake
  assert eventually(fn ->
    Process.alive?(pid_of(sid, :cc_process)) and
    File.exists?(session_dir(sid) <> "/mcp.json") and
    claude_handshake_complete?(sid)
  end, 30_000)

  send_test_inbound("hello", sid)
  assert_receive {:chat_reply, _text}, 60_000

  :ok = Esr.Session.Router.stop_session(sid)
end
```

### 4.8 `mix esr.audit_supervision` (PR-3, ~50 LOC)

A maintenance mix task that, given a running esrd fixture, snapshots the
supervision tree (`Supervisor.which_children/1` recursively + strategy of
each supervisor) into a structured format, and diffs against
`docs/notes/supervisor-inventory.md`. CI gate fails on non-empty diff,
forcing intentional acknowledgement of supervisor structure changes.

This complements §4.6 — invariant tests catch behavioral regression;
supervision audit catches structural drift.

### 4.9 ADR-0002 (PR-3)

`docs/adr/0002-cc-pty-pair-one-for-all-invariant.md`:

```markdown
# CC + PTY pair uses :one_for_all supervisor

**Status:** accepted  **Date:** 2026-05-11

`Esr.Session.AgentInstanceSupervisor` supervises CC + PTY with
`:one_for_all` strategy. Both children must restart together; lone-survivor
restart is prohibited.

**Rationale:** CCProcess manages the active claude session via PtyProcess.
Restarting one without the other leaves the surviving process holding a
stale connection (CC waiting on a dead PTY pipe, or PTY managing a child
whose CC consumer is gone). Both states are unrecoverable in-place.
`:one_for_all` guarantees consistent restart.

**Originally established:** 2026-05-07 Feishu spec Q5.3 sub-2 (per the
moduledoc on `agent_instance_supervisor.ex`).

**Reversing this requires:** invalidating invariants I1-I4 (see
`docs/notes/system-invariants.md`) — the chaos tests will catch any
attempt to switch strategy here.

**Out of scope:** `Esr.Session.AgentSupervisor` (the parent DynamicSupervisor)
uses `:one_for_one` and that is also correct (multiple agent instances
in a session are independent).
```

---

## 5. Phase B — `submit_slash` MCP tool + CC skill (PR-4, ~150 LOC)

### 5.1 Tool definition

`runtime/lib/esr/plugins/claude_code/mcp/tools.ex` registers a new admin tool
on the cc_mcp Channel:

```elixir
@admin_tool %{
  name: "submit_slash",
  description: """
  Execute an ESR slash command on behalf of the operator. Use this when the
  user asks (in any language) to perform admin work: adding agents, listing
  sessions, switching workspace, registering adapters, etc. Returns a
  structured result; on error, translate the result into natural language
  before replying.
  """,
  input_schema: %{
    type: "object",
    properties: %{
      command: %{
        type: "string",
        description: "Full slash command including leading slash, e.g. /agent:add type=cc name=helper"
      }
    },
    required: ["command"]
  }
}
```

### 5.2 Handler

The tool handler (in the same module) builds an internal envelope using
chat context from the cc_mcp Channel state (cc_mcp knows the chat_id /
app_id / principal_id from its init args — populated by the SessionTemplate
when the bundle materialized):

```elixir
def handle_submit_slash(%{"command" => cmd_str}, %{chat_ctx: ctx}) do
  envelope = %{
    "payload" => %{
      "args" => Map.merge(ctx, %{"content" => cmd_str, "msg_type" => "text"})
    }
  }
  case Esr.Entity.SlashHandler.dispatch(envelope, submitter: ctx[:principal_id]) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, %{kind: reason, ...}}
  end
end
```

**Authentication:** the dispatch uses the **chat-bound user's principal_id**
(not ou_admin, not system). CC operates with the same capabilities as the
operator. If the user lacks a capability, the slash returns
`:missing_capability` and CC translates that to a chat reply.

### 5.3 CC skill prompt

`runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md` (loaded into CC's
system prompt at agent start; the cc agent_kind already supports
`--system-prompt` via its launcher):

```markdown
# Admin Operations Skill

If the operator asks you (in any language) to perform an ESR admin operation
— add an agent, list sessions, register an adapter, change the workspace
— use the `submit_slash` MCP tool.

Examples:
- 用户："加个新 agent 叫 helper" → submit_slash(command="/agent:add type=cc name=helper")
- 用户："列出现在的 session" → submit_slash(command="/session:list")
- 用户："换到 my-other workspace" → submit_slash(command="/workspace:use my-other")

If submit_slash returns an error result, translate the error into the user's
language and explain what they need to do next. Do not silently retry; ask
the operator for direction.

Slashes available: see /help.
```

### 5.4 Tests

- Unit: `submit_slash_handler_test.exs` — chat_ctx injection, principal_id
  threading, error path translation.
- Integration: extend `real_claude_boot_test.exs` to verify CC can execute a
  `submit_slash` call after boot (e.g. `/session:list` returning the current
  session as a sanity check).

---

## 6. Migration plan — 4 PRs

| PR | Title | LOC | Contents |
|---|---|---|---|
| **PR-1** | `feat(workspace): enforce workspace ≥1 folder invariant` | ~120 | §4.1 (schema, command guards, tests) |
| **PR-2** | `fix(session): /session:new pre-flight + mcp.json + FCP lifecycle handlers` | ~360 | §4.2 + §4.3 (pre-flight, mcp.json gen, FCP `handle_info/2` clauses) |
| **PR-3** | `feat(supervision): LifecycleObserver + ETS cleanup + ChaosScenarios + system invariants` | ~390 | §4.4 + §4.5 + §4.6 + §4.8 + ADR-0002 + `system-invariants.md` |
| **PR-4** | `feat(agent): submit_slash MCP tool + CC admin skill + real-claude integration test` | ~280 | §4.7 + Phase B (§5) + e2e fence #5 |

Each PR is independent in CI but ordered in dependencies: PR-1 must merge
before PR-2 (pre-flight assumes ≥1 folder); PR-2 before PR-3 (LifecycleObserver
assumes pre-flight is in place); PR-3 before PR-4 (real-claude test relies
on lifecycle visibility).

---

## 7. Acceptance criteria

| # | Acceptance | Verify |
|---|---|---|
| 1 | `/workspace:new name=X path=/some/dir` succeeds; `/workspace:new name=X` (no path) fails with explicit error | unit test + e2e fence |
| 2 | `/session:new name=test-cc` after `/workspace:use test-dev` produces a session with live FCP + CC + PTY + ready cc_mcp | manual replay of the 2026-05-11 hang scenario |
| 3 | `hello?` after `/session:new` produces a chat-visible reply (from CC) or chat-visible error within 5s | manual + invariant test I1 |
| 4 | Killing PtyProcess does not produce silent state — chat receives ":agent_died" lifecycle reply within 5s | invariant test I4 |
| 5 | Killing the entire session supervisor (`max_restarts` exhaustion) → chat receives ":session_fatal" reply; ETS routing entry deleted | invariant test I2 + I4 |
| 6 | `rg "other ->" runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex` returns 0 matches | invariant test I5 (file scan) |
| 7 | `mix esr.audit_supervision` runs green against current dev tree | CI gate |
| 8 | Real-claude integration test boots + receives reply | macos-latest CI step |
| 9 | CC can execute `/agent:add type=cc name=helper` when user says "加个 helper agent" | manual test (Feishu) + integration test |

---

## 8. Open questions / future work

Tracked in `docs/futures/todo.md`. The following are explicitly **closed** by
this spec:

- `phase-3-fence-cc-reply` → reopens fence #5 in `flow-bootstrap.md` per §4.7
- `unconsumed-message-errors-not-hangs` → resolved by §4.3 + §4.4 + §4.6 (I1)

Remaining open items potentially impacted but **not** addressed here:

- `structured-reply-envelope` (existing todo) — this spec assumes structured
  replies are available; if `task #220` doesn't ship first, the FCP
  `notify_chat/3` helper will use a minimal local envelope shape and the
  full schema lands in a follow-up.
- `e2e-15-principal-isolation` — submit_slash with non-admin principal needs
  testing once a non-admin test principal exists in the e2e fixture.

---

## 9. Approval gate

The user (linyilun) approves on Feishu. On approval:
1. This spec is committed + zh_cn mirror pushed
2. Plan written via `superpowers:writing-plans` to
   `docs/superpowers/plans/2026-05-11-default-agent-and-agent-driven-flow-plan.md`
3. Implementation begins with PR-1
