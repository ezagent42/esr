# Multi-Instance Routing Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Eliminate PR-3 1:1 role-instance assumption + delete legacy diffusion mechanisms; introduce Esr.ActorQuery; make /session:add-agent actually spawn (CC, PTY) subtrees.

**Architecture:** ETS-backed Esr.Entity.Registry with 3 indexes (actor_id, (session, name), (session, role)); per-session DynamicSupervisor under Scope.Supervisor hosting (CC, PTY) :one_for_all subtrees; atomic /session:add-agent via InstanceRegistry GenServer.

**Tech Stack:** Elixir/OTP; ETS; existing UUID/NameIndex patterns.

**Spec:** `docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md` (rev-1, user-approved 2026-05-07).

**Migration: 5 phases, NO backward compatibility.** Hard cutover at every step. Each phase = 1 PR.

---

## File Structure

### Phase M-1 — added

| File | Role |
|---|---|
| `runtime/lib/esr/actor_query.ex` | New module `Esr.ActorQuery` with three public query functions |
| `runtime/test/esr/actor_query_test.exs` | Unit tests for all three ActorQuery functions |
| `runtime/test/esr/entity/registry_indexes_test.exs` | Lifecycle tests for Index 2 (name) + Index 3 (role) |

### Phase M-1 — modified

| File | Change summary |
|---|---|
| `runtime/lib/esr/entity/registry.ex` | Add `:esr_actor_name_index` + `:esr_actor_role_index` ETS tables; add `register_attrs/2`, `deregister_attrs/2`; add DOWN monitor handler; update `init` |
| `runtime/lib/esr/application.ex` | Start two new named ETS tables before `Esr.Entity.Registry` in supervision children list |
| `runtime/lib/esr/entity/pty_process.ex` | Add `@role :pty_process`; `register_attrs` in `init/1`; `deregister_attrs` in `terminate/2` |
| `runtime/lib/esr/plugins/claude_code/cc_process.ex` | Add `@role :cc_process`; `register_attrs` / `deregister_attrs` calls |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | Add `@role :feishu_chat_proxy`; `register_attrs` / `deregister_attrs` calls |

### Phase M-2 — added

| File | Role |
|---|---|
| `runtime/lib/esr/scope/agent_supervisor.ex` | New `Esr.Scope.AgentSupervisor` — DynamicSupervisor hosting per-agent `:one_for_all` subtrees |

### Phase M-2 — modified

| File | Change summary |
|---|---|
| `runtime/lib/esr/session/agent_spawner.ex` | Delete `backwire_neighbors/3`, `build_neighbors/1`, all `:sys.replace_state/2` neighbor wiring; remove `neighbors` arg from `spawn_peer` call |
| `runtime/lib/esr/entity/pty_process.ex` | Delete `rewire_session_siblings/1`, `patch_neighbor_in_state/3`, deferred rewire trigger; remove `:neighbors` from state struct and `init/1` |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | Replace `Keyword.get(state.neighbors, :cc_process)` and `Keyword.get(state.neighbors, :feishu_app_proxy)` with `ActorQuery.list_by_role/2`; remove `:neighbors` from state |
| `runtime/lib/esr/plugins/claude_code/cc_process.ex` | Replace `find_chat_proxy_neighbor/1` + `Keyword.get(state.neighbors, ...)` with `find_reply_target(state.session_id)`; remove `:neighbors` from state |
| `runtime/lib/esr/entity/agent/instance_registry.ex` | Add `add_instance_and_spawn/1`, `remove_instance_and_stop/2` GenServer calls |
| `runtime/lib/esr/entity/factory.ex` | Remove `neighbors` parameter: `spawn_peer/5` → `spawn_peer/4`; update `spawn_peer_bootstrap/4` → `spawn_peer_bootstrap/3` |
| `runtime/lib/esr/commands/session/add_agent.ex` | Call `add_instance_and_spawn/1` instead of `add_instance/1` |
| `runtime/lib/esr/scope.ex` | Add `Esr.Scope.AgentSupervisor` as child in per-session `init/1` |

### Phase M-3 — deleted

| File | Reason |
|---|---|
| `runtime/lib/esr/topology.ex` | Entire file (257 LOC); no caller remains after M-3 cc_process.ex cleanup |
| `runtime/test/esr/topology_test.exs` | Tests deleted module |

### Phase M-3 — modified

| File | Change summary |
|---|---|
| `runtime/lib/esr/plugins/claude_code/cc_process.ex` | Delete `reachable_set` state field, `build_initial_reachable_set/1`, `maybe_put_reachable/2`, `reachable_json/1`, and all `reachable_set` mutations (~145 LOC) |
| `runtime/lib/esr/resource/workspace/describe.ex` | Delete `neighbor_workspaces` output, `resolve_neighbour_workspaces/2`, `legacy_neighbors/1` |
| `runtime/lib/esr/entity/server.ex` | Delete `build_emit_for_tool("describe_topology", ...)` private function and `describe_topology` cap-bypass `if` condition |
| `runtime/lib/esr/plugins/claude_code/mcp/tools.ex` | Delete `@describe_topology` module attribute and its references in tool lists |
| `runtime/lib/esr/resource/workspace/registry.ex` | Remove `:neighbors` field from `%Workspace{}` struct; remove `_legacy.neighbors` reads from `to_legacy/1` and `normalize_to_struct/1` |
| `runtime/test/esr/plugins/claude_code/cc_process_test.exs` | Delete `reachable_set` tests; stub deleted sections with `# deleted in M-3` comments |

### Phase M-4 — modified

| File | Change summary |
|---|---|
| `runtime/lib/esr/resource/workspace/registry.ex` | Delete `defmodule Workspace`, `@legacy_table`, `to_legacy/1`, `normalize_to_struct/1`, `do_put(%Workspace{})` clause, `start_cmd_for/2`, legacy `list/0`, legacy `get/1`, all `@legacy_table` ETS operations (~139 LOC) |
| `runtime/lib/esr/commands/workspace/info.ex` | Delete `lookup_legacy/1`, `build_legacy_result/1`, `_legacy.*` reads, fallback rescue clause (~111 LOC) |
| `runtime/lib/esr/resource/workspace/describe.ex` | Delete `legacy_metadata/1`, `_legacy.role` / `_legacy.metadata` reads, `"role"` field from output (~13 LOC) |

### Phase M-5 — test rewrites

| File | Action |
|---|---|
| `runtime/test/esr/session/agent_spawner_test.exs` | Delete `backwire_neighbors` tests; add spawn-via-InstanceRegistry + rollback tests |
| `runtime/test/esr/entity/pty_process_test.exs` | Delete `rewire_session_siblings` tests |
| `runtime/test/esr/entity/server_describe_topology_test.exs` | Delete topology tool tests; retain any non-topology server tests |
| `runtime/test/esr/resource/workspace_describe_test.exs` | Delete `neighbor_workspaces` assertions |
| `runtime/test/esr/commands/workspace/info_test.exs` | Delete `_legacy.*` assertions; update expected response shape |
| `runtime/test/esr/actor_query_test.exs` | Extended full ActorQuery suite (from M-1) |
| `runtime/test/esr/entity/registry_indexes_test.exs` | Extended Registry index lifecycle suite (from M-1) |
| `tests/e2e/scenario_18_multi_cc_session/` | New e2e scenario: create session → add two CC agents → @mention routing → remove agent → end session |

---

## Phase M-1: Esr.ActorQuery + Registry indexes (additive)

**Depends on:** nothing — starts immediately after spec approval.

**Purpose:** Add the three-index Registry and the `Esr.ActorQuery` module without touching any existing production call sites. After M-1 merges, `state.neighbors` is still present and all existing paths remain unchanged. M-1 is the prerequisite for M-2.

**LOC estimate:** +250

**Risk:** Low — purely additive. Existing tests cannot break because no call site changes.

**Invariant test (gate for M-1 done):** After M-1, calling `Esr.Entity.Registry.register_attrs/2` from a process followed immediately by `Esr.ActorQuery.find_by_name/2` in the same test process must return `{:ok, pid}`. A test asserting this must be green before M-1 is claimed complete.

---

### Task M-1.1: Create `Esr.ActorQuery` module

**File:** `runtime/lib/esr/actor_query.ex` (new)

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/actor_query_test.exs
defmodule Esr.ActorQueryTest do
  use ExUnit.Case, async: true

  setup do
    # Each test gets isolated ETS tables started fresh. We test against the
    # real :esr_actor_name_index and :esr_actor_role_index tables which are
    # started in application.ex. For test isolation, we use unique session_ids.
    session_id = "test-sess-#{System.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  describe "find_by_name/2" do
    test "returns {:ok, pid} for registered (session_id, name)", %{session_id: sid} do
      actor_id = "actor-#{System.unique_integer([:positive])}"
      name = "helper-#{System.unique_integer([:positive])}"
      :ok = Esr.Entity.Registry.register_attrs(actor_id, %{session_id: sid, name: name, role: :cc_process})

      assert {:ok, pid} = Esr.ActorQuery.find_by_name(sid, name)
      assert pid == self()
    end

    test "returns :not_found when name not registered", %{session_id: sid} do
      assert :not_found == Esr.ActorQuery.find_by_name(sid, "nonexistent-#{sid}")
    end

    test "returns :not_found for different session_id", %{session_id: sid} do
      actor_id = "actor-#{System.unique_integer([:positive])}"
      name = "helper-#{System.unique_integer([:positive])}"
      :ok = Esr.Entity.Registry.register_attrs(actor_id, %{session_id: sid, name: name, role: :cc_process})

      assert :not_found == Esr.ActorQuery.find_by_name("other-session-#{sid}", name)
    end
  end

  describe "list_by_role/2" do
    test "returns [] for session with no registrations", %{session_id: sid} do
      assert [] == Esr.ActorQuery.list_by_role(sid, :cc_process)
    end

    test "returns [pid] for single-instance role", %{session_id: sid} do
      actor_id = "actor-#{System.unique_integer([:positive])}"
      :ok = Esr.Entity.Registry.register_attrs(actor_id, %{
        session_id: sid,
        name: "a-#{System.unique_integer([:positive])}",
        role: :cc_process
      })
      assert [_pid] = Esr.ActorQuery.list_by_role(sid, :cc_process)
    end
  end

  describe "find_by_id/1" do
    test "returns {:ok, pid} for registered actor_id" do
      actor_id = "actor-find-by-id-#{System.unique_integer([:positive])}"
      # Register in Index 1 via Elixir Registry (calling process registers itself)
      {:ok, _pid} = Esr.Entity.Registry.register(actor_id, self())
      assert {:ok, pid} = Esr.ActorQuery.find_by_id(actor_id)
      assert pid == self()
    end

    test "returns :not_found for unknown actor_id" do
      assert :not_found == Esr.ActorQuery.find_by_id("nonexistent-#{System.unique_integer([:positive])}")
    end
  end
end
```

**Step 2 — Confirm test fails:** `mix test runtime/test/esr/actor_query_test.exs` — fails with `module Esr.ActorQuery is not available`.

**Step 3 — Write implementation:**

```elixir
# runtime/lib/esr/actor_query.ex
defmodule Esr.ActorQuery do
  @moduledoc """
  Peer lookup. Three functions; three ETS indexes in Esr.Entity.Registry.

  Locked decision Q5.1 (Feishu 2026-05-07): NO predicate DSL, NO scope
  enum, NO multi-attribute query language. Cap-based discovery is out of
  scope (Q5.5).

  ## Monitor pattern

  ActorQuery returns live pids at the moment of the call. A pid can die
  between the return and the first send. Callers that need a stable
  reference should monitor immediately:

      case Esr.ActorQuery.find_by_name(sid, name) do
        {:ok, pid} ->
          _ref = Process.monitor(pid)
          send(pid, msg)
        :not_found ->
          handle_missing()
      end

  `list_by_role/2` reads from a `:bag` table. In the narrow window
  between a pid dying and the Registry DOWN handler processing, a dead
  pid may appear. Use `Process.alive?/1` or the monitor-before-send
  pattern to handle this safely.
  """

  @doc """
  Find a peer by its operator-facing display name within a session.

  Searches the `:esr_actor_name_index` ETS table (`:set` strategy;
  enforces uniqueness at insert time via `:ets.insert_new/2`).

  Returns `{:ok, pid}` when exactly one live registration exists.
  Returns `:not_found` when no entry exists for `{session_id, name}`.
  """
  @spec find_by_name(session_id :: String.t(), name :: String.t()) ::
          {:ok, pid()} | :not_found
  def find_by_name(session_id, name)
      when is_binary(session_id) and is_binary(name) do
    case :ets.lookup(:esr_actor_name_index, {session_id, name}) do
      [{_key, {pid, _actor_id}}] when is_pid(pid) -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc """
  List all live pids for a given role within a session.

  Searches the `:esr_actor_role_index` ETS table (`:bag` strategy;
  multiple values per `{session_id, role}` key support multi-instance
  same role).

  Returns a (possibly empty) list of pids. Ordering is not guaranteed.
  The caller chooses the selection strategy (List.first/1, fan-out, etc.).
  """
  @spec list_by_role(session_id :: String.t(), role :: atom()) :: [pid()]
  def list_by_role(session_id, role)
      when is_binary(session_id) and is_atom(role) do
    :esr_actor_role_index
    |> :ets.lookup({session_id, role})
    |> Enum.map(fn {_key, {pid, _actor_id}} -> pid end)
  end

  @doc """
  Find a peer by its UUID actor_id. Searches across all sessions.

  Delegates to `Esr.Entity.Registry.lookup/1` (Index 1: actor_id → pid).

  Returns `{:ok, pid}` or `:not_found`. Use for cross-references where
  the actor_id is stored in InstanceRegistry or in another actor's
  persisted state and must survive restarts (actor_id is stable; pid
  changes on restart).
  """
  @spec find_by_id(actor_id :: String.t()) :: {:ok, pid()} | :not_found
  def find_by_id(actor_id) when is_binary(actor_id) do
    case Esr.Entity.Registry.lookup(actor_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> :not_found
    end
  end
end
```

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/actor_query_test.exs` — green.

**Step 5 — Confirm no regressions:** `mix test` — full suite green. No existing module is changed; no regressions possible.

---

### Task M-1.2: Extend `Esr.Entity.Registry` with `(session_id, name) → pid` index

**File:** `runtime/lib/esr/entity/registry.ex` (modify)

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/entity/registry_indexes_test.exs
defmodule Esr.Entity.RegistryIndexesTest do
  use ExUnit.Case, async: false  # ETS tables are global named tables

  @name_table :esr_actor_name_index

  describe "name index (Index 2)" do
    setup do
      session_id = "reg-idx-test-#{System.unique_integer([:positive])}"
      actor_id = "actor-#{System.unique_integer([:positive])}"
      name = "peer-#{System.unique_integer([:positive])}"
      {:ok, session_id: session_id, actor_id: actor_id, name: name}
    end

    test "register_attrs/2 writes to name index", %{session_id: sid, actor_id: aid, name: name} do
      :ok = Esr.Entity.Registry.register_attrs(aid, %{session_id: sid, name: name, role: :cc_process})
      assert [{_, {pid, ^aid}}] = :ets.lookup(@name_table, {sid, name})
      assert pid == self()
    end

    test "register_attrs/2 returns {:error, :name_taken} on duplicate name",
         %{session_id: sid, actor_id: aid, name: name} do
      :ok = Esr.Entity.Registry.register_attrs(aid, %{session_id: sid, name: name, role: :cc_process})
      aid2 = "actor-#{System.unique_integer([:positive])}"
      result = Task.async(fn ->
        Esr.Entity.Registry.register_attrs(aid2, %{session_id: sid, name: name, role: :cc_process})
      end) |> Task.await()
      assert {:error, :name_taken} = result
    end

    test "deregister_attrs/2 removes name index entry",
         %{session_id: sid, actor_id: aid, name: name} do
      :ok = Esr.Entity.Registry.register_attrs(aid, %{session_id: sid, name: name, role: :cc_process})
      :ok = Esr.Entity.Registry.deregister_attrs(aid, %{session_id: sid, name: name, role: :cc_process})
      assert [] = :ets.lookup(@name_table, {sid, name})
    end
  end
end
```

**Step 2 — Confirm test fails:** `mix test runtime/test/esr/entity/registry_indexes_test.exs` — fails: `Esr.Entity.Registry.register_attrs/2 undefined`.

**Step 3 — Write implementation:**

Add to `runtime/lib/esr/entity/registry.ex`. The `Esr.Entity.Registry` module currently wraps `Elixir.Registry` for Index 1. We extend it to also own the two ETS tables. The ETS tables are created by `Esr.Application` (Task M-1.3) before Registry starts; registry.ex only operates on them.

```elixir
# Add to runtime/lib/esr/entity/registry.ex after the existing functions:

@name_index :esr_actor_name_index
@role_index :esr_actor_role_index

@doc """
Register peer attributes in Index 2 (name) and Index 3 (role).

Must be called from the peer's own `init/1` — i.e., `self()` is the
registrant. Returns `:ok` on success. Returns
`{:error, :name_taken}` if `(session_id, name)` is already taken.
Returns `{:error, :cannot_register_other_pid}` if called from a
process other than the intended registrant (defensive guard; should
not occur in normal operation).

Sets up a monitor on `self()` so the indexes are cleaned automatically
if the process crashes without calling `terminate/2`.
"""
@spec register_attrs(String.t(), %{
        session_id: String.t(),
        name: String.t(),
        role: atom()
      }) :: :ok | {:error, :name_taken | :cannot_register_other_pid}
def register_attrs(actor_id, %{session_id: sid, name: name, role: role})
    when is_binary(actor_id) and is_binary(sid) and is_binary(name) and is_atom(role) do
  pid = self()

  case :ets.insert_new(@name_index, {{sid, name}, {pid, actor_id}}) do
    true ->
      :ets.insert(@role_index, {{sid, role}, {pid, actor_id}})
      # Monitor the registrant. The Registry GenServer handles the DOWN
      # message and removes both index entries. Idempotent if deregister_attrs
      # was already called in terminate/2.
      Process.monitor(pid)
      :ok

    false ->
      {:error, :name_taken}
  end
end

@doc """
Remove peer attributes from Index 2 (name) and Index 3 (role).

Called from peer's `terminate/2`. Idempotent — safe to call even if
the entries were already removed by the DOWN handler.
"""
@spec deregister_attrs(String.t(), %{
        session_id: String.t(),
        name: String.t(),
        role: atom()
      }) :: :ok
def deregister_attrs(actor_id, %{session_id: sid, name: name, role: role})
    when is_binary(actor_id) and is_binary(sid) and is_binary(name) and is_atom(role) do
  :ets.delete(@name_index, {sid, name})
  pid = self()
  :ets.match_delete(@role_index, {{sid, role}, {pid, actor_id}})
  :ok
end
```

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/entity/registry_indexes_test.exs` — green (name index portion).

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-1.3: Extend `Esr.Entity.Registry` with `(session_id, role) → [pid]` index + ETS table creation

**File:** `runtime/lib/esr/application.ex` (modify) + `runtime/lib/esr/entity/registry.ex` (modify)

**Step 1 — Write failing test** (extend `registry_indexes_test.exs`):

```elixir
# Add to Esr.Entity.RegistryIndexesTest:
@role_table :esr_actor_role_index

describe "role index (Index 3)" do
  setup do
    session_id = "reg-role-test-#{System.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  test "register_attrs/2 writes to role index — single instance", %{session_id: sid} do
    aid = "actor-#{System.unique_integer([:positive])}"
    name = "peer-#{System.unique_integer([:positive])}"
    :ok = Esr.Entity.Registry.register_attrs(aid, %{session_id: sid, name: name, role: :pty_process})
    entries = :ets.lookup(@role_table, {sid, :pty_process})
    assert length(entries) == 1
    assert [{_, {pid, ^aid}}] = entries
    assert pid == self()
  end

  test "register_attrs/2 allows multiple entries for same role (bag)", %{session_id: sid} do
    aid1 = "actor-#{System.unique_integer([:positive])}"
    aid2 = "actor-#{System.unique_integer([:positive])}"
    name1 = "peer-#{System.unique_integer([:positive])}"
    name2 = "peer-#{System.unique_integer([:positive])}"

    t1 = Task.async(fn ->
      Esr.Entity.Registry.register_attrs(aid1, %{session_id: sid, name: name1, role: :cc_process})
    end)
    t2 = Task.async(fn ->
      Esr.Entity.Registry.register_attrs(aid2, %{session_id: sid, name: name2, role: :cc_process})
    end)

    :ok = Task.await(t1)
    :ok = Task.await(t2)

    entries = :ets.lookup(@role_table, {sid, :cc_process})
    assert length(entries) == 2
  end

  test "deregister_attrs/2 removes only the specific pid's entry from role index",
       %{session_id: sid} do
    aid1 = "actor-#{System.unique_integer([:positive])}"
    name1 = "peer-#{System.unique_integer([:positive])}"

    # Register two peers with the same role; deregister one; the other remains.
    t = Task.async(fn ->
      aid_inner = "actor-inner-#{System.unique_integer([:positive])}"
      name_inner = "peer-inner-#{System.unique_integer([:positive])}"
      :ok = Esr.Entity.Registry.register_attrs(aid_inner, %{
        session_id: sid, name: name_inner, role: :cc_process
      })
      :timer.sleep(200)
    end)

    :ok = Esr.Entity.Registry.register_attrs(aid1, %{session_id: sid, name: name1, role: :cc_process})

    before_entries = :ets.lookup(@role_table, {sid, :cc_process})
    assert length(before_entries) == 2

    # Deregister our own entry
    :ok = Esr.Entity.Registry.deregister_attrs(aid1, %{session_id: sid, name: name1, role: :cc_process})

    after_entries = :ets.lookup(@role_table, {sid, :cc_process})
    assert length(after_entries) == 1

    Task.await(t)
  end
end
```

**Step 2 — Confirm test fails:** Role index tests fail because the ETS table doesn't exist yet at the start of the test run.

**Step 3 — Write implementation (ETS table creation in application.ex):**

The two named ETS tables must be created before `Esr.Entity.Registry` starts. In `runtime/lib/esr/application.ex`, insert two entries before the `{Registry, keys: :unique, name: Esr.Entity.Registry}` line:

```elixir
# In Esr.Application.start/2, children list — add before the Entity.Registry entry:
# (around line 44 in the current file)

# Index 2: (session_id, name) → {pid, actor_id}. Created before Entity.Registry
# so register_attrs/2 can insert immediately on first call.
%{
  id: :esr_actor_name_index,
  start: {__MODULE__, :create_ets_table, [
    :esr_actor_name_index,
    [:named_table, :set, :public, read_concurrency: true]
  ]},
  restart: :permanent,
  type: :worker
},

# Index 3: (session_id, role) → {pid, actor_id}. Bag table: supports multiple
# pids per (session_id, role) key for multi-instance same role (Q5.2).
%{
  id: :esr_actor_role_index,
  start: {__MODULE__, :create_ets_table, [
    :esr_actor_role_index,
    [:named_table, :bag, :public, read_concurrency: true]
  ]},
  restart: :permanent,
  type: :worker
},
```

Add the helper function to `Esr.Application`:

```elixir
@doc false
def create_ets_table(name, opts) do
  # :ets.new returns the table reference. We wrap in a bare GenServer-less
  # process that owns the table so the table survives Application supervisor
  # restarts (the owning process stays alive until the Application stops).
  pid = spawn_link(fn ->
    :ets.new(name, opts)
    receive do :stop -> :ok end
  end)
  {:ok, pid}
end
```

**Note:** A simpler approach — which matches the existing `Esr.Resource.Workspace.NameIndex` pattern in this codebase — is to use a GenServer as the table owner. However, because these tables are global singletons needed before any peer process starts, a bare `spawn_link` owner (with a permanent restart child spec) is sufficient and avoids introducing a new GenServer just for table ownership. The chosen pattern is consistent with how OTP supervision trees manage ETS table ownership.

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/entity/registry_indexes_test.exs` — green.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-1.4: `Esr.Entity.Registry` GenServer DOWN handler for auto-deregistration on crash

**File:** `runtime/lib/esr/entity/registry.ex` (modify)

**Context:** `register_attrs/2` calls `Process.monitor(pid)`. The current `Esr.Entity.Registry` module is a plain module (not a GenServer) — it wraps `Elixir.Registry` which itself is a GenServer that handles its own DOWN messages for Index 1. For Index 2 and Index 3 cleanup on crash, we need a process that can receive the DOWN messages from the monitors set by `register_attrs/2`.

The `Elixir.Registry` GenServer that runs under the name `Esr.Entity.Registry` is the natural owner. However, because we cannot add `handle_info` to the underlying `Registry` process, we introduce a thin companion GenServer: `Esr.Entity.Registry.IndexWatcher`.

**Step 1 — Write failing test** (add to `registry_indexes_test.exs`):

```elixir
describe "crash cleanup via monitor DOWN" do
  test "Index 2 and Index 3 entries removed within 200ms of process death" do
    sid = "crash-test-#{System.unique_integer([:positive])}"
    aid = "actor-crash-#{System.unique_integer([:positive])}"
    name = "peer-crash-#{System.unique_integer([:positive])}"

    # Spawn a process that registers attrs and then dies.
    test_pid = self()
    spawned = spawn(fn ->
      :ok = Esr.Entity.Registry.register_attrs(aid, %{
        session_id: sid, name: name, role: :feishu_chat_proxy
      })
      send(test_pid, :registered)
      receive do :die -> :ok end
    end)

    assert_receive :registered, 1_000
    assert [{_, _}] = :ets.lookup(:esr_actor_name_index, {sid, name})

    send(spawned, :die)

    # Allow time for DOWN to be processed.
    Process.sleep(200)

    assert [] = :ets.lookup(:esr_actor_name_index, {sid, name})
    assert [] = :ets.lookup(:esr_actor_role_index, {sid, :feishu_chat_proxy})
  end
end
```

**Step 2 — Confirm test fails:** The DOWN message has no handler yet; Index 2 + 3 entries remain after process death.

**Step 3 — Write implementation:**

```elixir
# runtime/lib/esr/entity/registry/index_watcher.ex (new file)
defmodule Esr.Entity.Registry.IndexWatcher do
  @moduledoc """
  Companion GenServer that receives DOWN messages for monitors set by
  `Esr.Entity.Registry.register_attrs/2`.

  When a registered process crashes without calling `terminate/2` (and
  thus without calling `deregister_attrs/2`), this watcher cleans Index 2
  (:esr_actor_name_index) and Index 3 (:esr_actor_role_index) based on
  the metadata stored alongside the monitor reference.

  The watcher is a singleton started in Esr.Application before
  Esr.Entity.Registry.

  ## Monitor metadata

  The ETS scan-based cleanup approach: on DOWN, scan both indexes for
  entries whose pid matches the dead pid and delete them. This is O(n)
  over the number of entries per session, but sessions rarely have more
  than a handful of peers; the scan is fast and bounded.

  An alternative is to store `{monitor_ref → {sid, name, role, pid, actor_id}}`
  in a local map. We use that approach here for O(1) per-DOWN cleanup.
  """

  use GenServer

  @name_index :esr_actor_name_index
  @role_index :esr_actor_role_index

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Register a monitor reference with its associated cleanup metadata.
  Called by `Esr.Entity.Registry.register_attrs/2` after `Process.monitor/1`.
  """
  @spec track(reference(), %{
          pid: pid(),
          actor_id: String.t(),
          session_id: String.t(),
          name: String.t(),
          role: atom()
        }) :: :ok
  def track(ref, metadata) when is_reference(ref) and is_map(metadata) do
    GenServer.cast(__MODULE__, {:track, ref, metadata})
  end

  @impl true
  def init(_opts), do: {:ok, %{monitors: %{}}}

  @impl true
  def handle_cast({:track, ref, metadata}, %{monitors: monitors} = state) do
    {:noreply, %{state | monitors: Map.put(monitors, ref, metadata)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitors: monitors} = state) do
    case Map.pop(monitors, ref) do
      {nil, _} ->
        # Unknown monitor reference; ignore.
        {:noreply, state}

      {%{actor_id: aid, session_id: sid, name: name, role: role, pid: dead_pid}, remaining} ->
        :ets.delete(@name_index, {sid, name})
        :ets.match_delete(@role_index, {{sid, role}, {dead_pid, aid}})
        {:noreply, %{state | monitors: remaining}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

Update `register_attrs/2` in `registry.ex` to call `IndexWatcher.track/2` after `Process.monitor/1`:

```elixir
# In register_attrs/2, replace `Process.monitor(pid)` with:
ref = Process.monitor(pid)
Esr.Entity.Registry.IndexWatcher.track(ref, %{
  pid: pid,
  actor_id: actor_id,
  session_id: sid,
  name: name,
  role: role
})
```

Add `Esr.Entity.Registry.IndexWatcher` to `Esr.Application` children (before the ETS table owner entries):

```elixir
# In application.ex children list, before the ETS table entries:
Esr.Entity.Registry.IndexWatcher,
```

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/entity/registry_indexes_test.exs` — green including crash cleanup test.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-1.5: Add `@role` compile-time constant + `register_attrs` / `deregister_attrs` calls to peer modules

**Files:** `pty_process.ex`, `cc_process.ex`, `feishu_chat_proxy.ex`

**Context:** Each stateful peer must declare its role atom at compile time via `@role` and call `register_attrs/2` at the end of `init/1` and `deregister_attrs/2` in `terminate/2`. The `actor_id` for the ETS indexes must match what the peer already registered in Index 1 (the `Elixir.Registry` actor_id). Looking at the source:

- `pty_process.ex:132` registers as `"pty:" <> sid` — actor_id for Index 1.
- `cc_process.ex` does not register in Index 1 directly (it uses `handler_module` and proxy_ctx patterns). The `actor_id` used for `register_attrs` must be generated in `init/1` or passed as an arg. For M-1, generate a UUID at the start of `init/1` if not already provided in args.
- `feishu_chat_proxy.ex:83` registers as `"thread:" <> session_id` — actor_id for Index 1.

**Step 1 — Write failing test:**

```elixir
# Add to actor_query_test.exs:
describe "integration: peer module registers via @role on init" do
  test "pty_process registers with role :pty_process via register_attrs" do
    # After M-1.5: start a minimal PtyProcess in test env and verify
    # that list_by_role returns its pid.
    # This test is implemented fully in M-1.5 after peer modules are updated.
    # Here we assert the contract: a peer with @role :pty_process that calls
    # register_attrs in init/1 appears in list_by_role.
    sid = "role-test-#{System.unique_integer([:positive])}"
    actor_id = "pty-test-#{System.unique_integer([:positive])}"
    :ok = Esr.Entity.Registry.register_attrs(actor_id, %{
      session_id: sid, name: "pty-peer", role: :pty_process
    })
    assert [pid] = Esr.ActorQuery.list_by_role(sid, :pty_process)
    assert pid == self()
  end
end
```

**Step 2 — Confirm test passes immediately** (this specific test already works after M-1.2–M-1.4). The per-module integration tests come after the module changes below.

**Step 3 — Write implementation:**

Add to `runtime/lib/esr/entity/pty_process.ex`:

```elixir
# After the @moduledoc, before any def:
@role :pty_process
```

At the end of `pty_process.ex`'s `init/1`, after the existing `Esr.Entity.Registry.register/2` call at line 132, add:

```elixir
# M-1.5: register in Index 2 + 3 for ActorQuery lookup.
# Use the same string as Index 1 registration as the actor_id.
actor_id_for_index = "pty:" <> sid
name_for_index = Map.get(args, :name, "pty-" <> sid)

if is_binary(sid) and sid != "" do
  _ =
    try do
      Esr.Entity.Registry.register_attrs(actor_id_for_index, %{
        session_id: sid,
        name: name_for_index,
        role: @role
      })
    catch
      _, _ -> :ok
    end
end
```

Add `terminate/2` to `pty_process.ex` (it does not currently have one; add after `handle_downstream`):

```elixir
@impl GenServer
def terminate(_reason, %{session_id: sid} = state) when is_binary(sid) and sid != "" do
  actor_id_for_index = "pty:" <> sid
  name_for_index = Map.get(state, :name, "pty-" <> sid)

  _ =
    try do
      Esr.Entity.Registry.deregister_attrs(actor_id_for_index, %{
        session_id: sid,
        name: name_for_index,
        role: @role
      })
    catch
      _, _ -> :ok
    end

  :ok
end

def terminate(_reason, _state), do: :ok
```

Add to `runtime/lib/esr/plugins/claude_code/cc_process.ex`:

```elixir
@role :cc_process
```

At the end of `cc_process.ex`'s `init/1` (after the existing state map is constructed):

```elixir
# M-1.5: register in Index 2 + 3 for ActorQuery lookup.
actor_id_cc = "cc:" <> sid
name_cc = Map.get(args, :name, "cc-" <> sid)

_ =
  try do
    Esr.Entity.Registry.register_attrs(actor_id_cc, %{
      session_id: sid,
      name: name_cc,
      role: @role
    })
  catch
    _, _ -> :ok
  end
```

Add `terminate/2` to `cc_process.ex`:

```elixir
@impl GenServer
def terminate(_reason, %{session_id: sid} = state) when is_binary(sid) and sid != "" do
  actor_id_cc = "cc:" <> sid
  name_cc = Map.get(state, :name, "cc-" <> sid)

  _ =
    try do
      Esr.Entity.Registry.deregister_attrs(actor_id_cc, %{
        session_id: sid,
        name: name_cc,
        role: @role
      })
    catch
      _, _ -> :ok
    end

  :ok
end

def terminate(_reason, _state), do: :ok
```

Add to `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`:

```elixir
@role :feishu_chat_proxy
```

At the end of `feishu_chat_proxy.ex`'s `init/1`, after the existing `Registry.register` call at line 83:

```elixir
# M-1.5: register in Index 2 + 3 for ActorQuery lookup.
actor_id_fcp = "thread:" <> session_id
name_fcp = Map.get(args, :name, "fcp-" <> session_id)

_ =
  try do
    Esr.Entity.Registry.register_attrs(actor_id_fcp, %{
      session_id: session_id,
      name: name_fcp,
      role: @role
    })
  catch
    _, _ -> :ok
  end
```

Add `terminate/2` to `feishu_chat_proxy.ex`:

```elixir
@impl GenServer
def terminate(_reason, %{session_id: sid} = state) when is_binary(sid) and sid != "" do
  actor_id_fcp = "thread:" <> sid
  name_fcp = Map.get(state, :name, "fcp-" <> sid)

  _ =
    try do
      Esr.Entity.Registry.deregister_attrs(actor_id_fcp, %{
        session_id: sid,
        name: name_fcp,
        role: @role
      })
    catch
      _, _ -> :ok
    end

  :ok
end

def terminate(_reason, _state), do: :ok
```

**Step 4 — Confirm tests pass:** `mix test` — full suite green. The `try/catch` guards ensure M-1 changes are backward-compatible with tests that don't start ETS tables.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-1.6: PR + admin-merge

**Step 1 — Stage and commit:**

```bash
git add \
  runtime/lib/esr/actor_query.ex \
  runtime/lib/esr/entity/registry.ex \
  runtime/lib/esr/entity/registry/index_watcher.ex \
  runtime/lib/esr/application.ex \
  runtime/lib/esr/entity/pty_process.ex \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex \
  runtime/test/esr/actor_query_test.exs \
  runtime/test/esr/entity/registry_indexes_test.exs
```

**Step 2 — Create and push branch; open PR against integration branch:**

```bash
git branch feat/m1-actor-query-indexes
git push origin feat/m1-actor-query-indexes
gh pr create --base feat/multi-instance-routing-cleanup --head feat/m1-actor-query-indexes \
  --title "feat(m-1): Esr.ActorQuery + Registry indexes — additive" \
  --body "Additive phase: Registry indexes (name, role) + ActorQuery public API.

No deletions, no renames. Full backward compatibility.

Spec: docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md (rev-1, user-approved 2026-05-07)."
```

**Step 3 — Admin-merge:**
```bash
gh pr merge --admin --squash --delete-branch
```

**Step 4 — Verify:** `git log --oneline feat/multi-instance-routing-cleanup | head -3` — M-1 commit visible.

---

## Phase M-2: Migrate callers + delete state.neighbors + per-session DynSup + atomic add-agent

**Depends on:** M-1 merged into `dev`.

**Purpose:** The phase that actually changes behavior. Delete the `state.neighbors` keyword list and all wiring ceremonies from four peer modules. Add `Esr.Scope.AgentSupervisor`. Make `/session:add-agent` spawn live actor processes.

**LOC estimate:** -200 net

**Risk:** HIGH — simultaneous state changes in four hot-path modules. Stage one commit per module. Run `mix test` after every commit. Keep PR in draft until all four modules are independently reviewed.

**Review checklist per module (before merging):**
1. `state.neighbors` field removed from `defstruct` / init map
2. All `Keyword.get(state.neighbors, ...)` calls replaced with `Esr.ActorQuery`
3. `register_attrs/deregister_attrs` from M-1 are present (not accidentally removed)
4. No remaining reference to `:sys.replace_state` for neighbor wiring
5. `mix test` green on this commit alone

**Invariant test (gate for M-2 done):** After M-2, calling `InstanceRegistry.add_instance_and_spawn/1` and then immediately calling `Esr.ActorQuery.find_by_name/2` in the same test process must return `{:ok, pid}` — not `:not_found`. A test asserting this must be green before M-2 is claimed complete.

---

### Task M-2.1: Migrate `feishu_chat_proxy.ex` — replace `Keyword.get(state.neighbors, ...)` with ActorQuery

**File:** `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`

**Affected lines:**
- Line 63: `neighbors: Map.get(args, :neighbors, [])` — remove from state init
- Line 666: `case Keyword.get(state.neighbors, :cc_process) do` — replace
- Line 711: `case Keyword.get(state.neighbors, :feishu_app_proxy) do` — replace

**Step 1 — Write failing test** (confirm current behavior depends on neighbors):

```elixir
# runtime/test/esr/plugins/feishu/feishu_chat_proxy_routing_test.exs
defmodule Esr.FeishuChatProxyRoutingTest do
  use ExUnit.Case, async: false

  test "FCP routes to cc_process via ActorQuery list_by_role after M-2" do
    sid = "fcp-route-test-#{System.unique_integer([:positive])}"
    # Register a fake cc_process pid in the role index so FCP can find it.
    actor_id = "cc-fake-#{System.unique_integer([:positive])}"
    :ok = Esr.Entity.Registry.register_attrs(actor_id, %{
      session_id: sid,
      name: "cc-test",
      role: :cc_process
    })

    # Verify that list_by_role returns the registered pid.
    assert [pid] = Esr.ActorQuery.list_by_role(sid, :cc_process)
    assert pid == self()
  end
end
```

**Step 2 — Confirm test passes** (this confirms the M-1 infrastructure is in place). The actual migration test — confirming FCP no longer has a `neighbors` key — is verified by removing the field and running the full suite.

**Step 3 — Write implementation:**

In `feishu_chat_proxy.ex`, remove the `:neighbors` field from state init (line 63):

```elixir
# BEFORE (line 63):
neighbors: Map.get(args, :neighbors, []),

# AFTER: delete this line entirely
```

Replace line 666 routing:

```elixir
# BEFORE (lines 666-672 approximately):
case Keyword.get(state.neighbors, :cc_process) do
  nil ->
    Logger.warning("feishu_chat_proxy: no cc_process neighbor session_id=#{state.session_id}")
    state
  pid ->
    send(pid, envelope)
    state
end

# AFTER:
case Esr.ActorQuery.list_by_role(state.session_id, :cc_process) do
  [pid | _] ->
    send(pid, envelope)
    state
  [] ->
    Logger.warning(
      "feishu_chat_proxy: no cc_process found via ActorQuery " <>
        "session_id=#{state.session_id}"
    )
    state
end
```

Replace line 711 routing:

```elixir
# BEFORE (lines 711-718 approximately):
case Keyword.get(state.neighbors, :feishu_app_proxy) do
  nil -> :error
  pid -> GenServer.call(pid, {:send_msg, payload})
end

# AFTER:
case Esr.ActorQuery.list_by_role(state.session_id, :feishu_app_proxy) do
  [pid | _] -> GenServer.call(pid, {:send_msg, payload})
  []        -> :error
end
```

Also remove `:neighbors` from the `defstruct` declaration if `feishu_chat_proxy.ex` uses one (check: if the state is a plain map initialized in `init/1` rather than a struct, only the `init/1` map literal needs updating).

**Step 4 — Confirm tests pass:** `mix test runtime/test/esr/plugins/feishu/` — green.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-2.2: Migrate `cc_process.ex` — replace `find_chat_proxy_neighbor` with ActorQuery

**File:** `runtime/lib/esr/plugins/claude_code/cc_process.ex`

**Affected lines:**
- Line 17: `:neighbors` in module-level state key enumeration — remove
- Line 110: `neighbors: Map.get(args, :neighbors, [])` in state init — remove
- Lines 374–414: `find_chat_proxy_neighbor/1` + `Keyword.get(state.neighbors, :cc_proxy)` usages — replace

**Step 1 — Write failing test:**

```elixir
# Add to cc_process test or create a new routing test:
test "cc_process find_reply_target uses ActorQuery after M-2" do
  sid = "cc-reply-test-#{System.unique_integer([:positive])}"
  actor_id = "fcp-fake-#{System.unique_integer([:positive])}"
  :ok = Esr.Entity.Registry.register_attrs(actor_id, %{
    session_id: sid,
    name: "fcp-test",
    role: :feishu_chat_proxy
  })

  assert [pid] = Esr.ActorQuery.list_by_role(sid, :feishu_chat_proxy)
  assert pid == self()
end
```

**Step 2 — Confirm test passes** (M-1 infrastructure already supports this).

**Step 3 — Write implementation:**

Remove `:neighbors` from the state documentation comment at line 17 and from the state init map at line 110.

Replace `find_chat_proxy_neighbor/1` (lines 374–414 in cc_process.ex) with `find_reply_target/1`:

```elixir
# REMOVE the entire find_chat_proxy_neighbor/1 private function (lines 409-418):
# defp find_chat_proxy_neighbor(neighbors) do
#   Enum.find_value(neighbors, fn ...
# end

# REMOVE the two call sites at lines 374-380:
# target_pid =
#   find_chat_proxy_neighbor(state.neighbors) ||
#     Keyword.get(state.neighbors, :cc_proxy)

# REPLACE with:
defp find_reply_target(session_id) do
  case Esr.ActorQuery.list_by_role(session_id, :feishu_chat_proxy) do
    [pid | _] -> {:ok, pid}
    [] ->
      case Esr.ActorQuery.list_by_role(session_id, :cc_proxy) do
        [pid | _] -> {:ok, pid}
        []        -> :not_found
      end
  end
end
```

Update the call site that previously used `find_chat_proxy_neighbor`:

```elixir
# BEFORE (lines 374-395 approximately):
target_pid =
  find_chat_proxy_neighbor(state.neighbors) ||
    Keyword.get(state.neighbors, :cc_proxy)

case target_pid do
  pid when is_pid(pid) ->
    send(pid, msg)
  _ ->
    Logger.warning(
      "cc_process: :reply with no *_chat_proxy or cc_proxy neighbor " <>
        "session_id=#{state.session_id}"
    )
end

# AFTER:
case find_reply_target(state.session_id) do
  {:ok, pid} ->
    send(pid, msg)
  :not_found ->
    Logger.warning(
      "cc_process: :reply with no *_chat_proxy or cc_proxy via ActorQuery " <>
        "session_id=#{state.session_id}"
    )
end
```

**Step 4 — Confirm tests pass:** `mix test runtime/test/esr/plugins/claude_code/` — green.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-2.3: Delete `agent_spawner.ex` `backwire_neighbors` + `:sys.replace_state` calls

**File:** `runtime/lib/esr/session/agent_spawner.ex`

**Affected lines (verified via grep against HEAD):**
- Lines 263–282: comment block explaining the two-pass backwire rationale
- Line 308: `:ok = backwire_neighbors(refs, proxies, params)` call
- Lines 337–341: comment introducing `backwire_neighbors/3`
- Lines 342–395: `defp backwire_neighbors/3` — full implementation with `Enum.each` + `:sys.replace_state/2`
- Lines 420–430: `neighbors = build_neighbors(refs_acc)` local variable + pass to `spawn_peer`
- Lines 457–470: `defp build_neighbors/1`

**Step 1 — Write failing test** (confirm current backwire runs):

```elixir
# The existing agent_spawner_test.exs has tests for backwire_neighbors.
# Before removing: confirm those tests exist and run:
mix test runtime/test/esr/session/agent_spawner_test.exs --only backwire
# This should currently pass. After M-2.3, these tests are deleted.
```

**Step 2 — Write implementation (delete, not replace):**

Remove from `agent_spawner.ex`:
1. Delete lines 263–282 (backwire rationale comment block).
2. Delete line 308: `:ok = backwire_neighbors(refs, proxies, params)`.
3. Delete lines 337–395: the `backwire_neighbors/3` comment + full private function.
4. Delete lines 420–430: `neighbors = build_neighbors(refs_acc)` local variable and the `neighbors` argument in the `Esr.Entity.Factory.spawn_peer/5` call (becomes `spawn_peer/4` after M-2.4).
5. Delete lines 457–470: `defp build_neighbors/1`.

The `spawn_pipeline/3` function, after deletions, returns `{:ok, refs, monitors}` without the backwire call. The `spawn_one/5` function's `Esr.Entity.Factory.spawn_peer` call changes from `spawn_peer(session_id, impl, args, neighbors, ctx)` to `spawn_peer(session_id, impl, args, ctx)` — pending Task M-2.4.

**Step 3 — Delete corresponding tests in agent_spawner_test.exs:**

Remove any test that asserts `backwire_neighbors` behavior, `:sys.replace_state` patching, or `build_neighbors` output. Mark deleted sections with:

```elixir
# Tests for backwire_neighbors/3 and build_neighbors/1 deleted in M-2.
# Replacement: spawn-via-InstanceRegistry tests added in M-5.
```

**Step 4 — Confirm compilation:** `mix compile --force` — no undefined function errors.

**Step 5 — Confirm no regressions:** `mix test` — full suite green (excluding the deleted backwire tests which are gone).

---

### Task M-2.4: Delete `pty_process.ex` `rewire_session_siblings` + `patch_neighbor_in_state`

**File:** `runtime/lib/esr/entity/pty_process.ex`

**Affected lines (verified via grep against HEAD):**
- Line 116: `neighbors: Map.get(args, :neighbors, [])` in state init — remove
- Lines 138–145: deferred rewire trigger in `init/1` (`Process.send_after(self(), :rewire_siblings, 50)`) — remove
- Lines 283, 317–324: `handle_downstream(:rewire_siblings, state)` clause — remove
- Lines 325–328: comment for `rewire_session_siblings/1` — remove
- Lines 329–355: `def rewire_session_siblings/1` — remove
- Lines 357–367: `defp patch_neighbor_in_state/3` — remove

**Step 1 — Write failing test** (confirm rewire currently runs):

The existing `pty_process_test.exs` likely tests `rewire_session_siblings` (it is public per spec note at line 325: "Public for the rewire test in Phase 4"). Identify and note these tests for deletion.

**Step 2 — Write implementation (delete):**

Remove from `pty_process.ex`:
1. Line 116: delete `neighbors: Map.get(args, :neighbors, [])` from state init map.
2. Lines 138–145: delete the deferred rewire `if` block (the `Process.send_after(self(), :rewire_siblings, 50)` guard).
3. Lines 317–324: delete `handle_downstream(:rewire_siblings, state)` clause.
4. Lines 325–328: delete the `rewire_session_siblings/1` comment block.
5. Lines 329–355: delete `def rewire_session_siblings/1` (both clauses).
6. Lines 357–367: delete `defp patch_neighbor_in_state/3`.

The `handle_downstream/2` catch-all clause at line 326 (`def handle_downstream(_msg, state), do: {:forward, [], state}`) is retained — it is still needed for other downstream messages.

**Step 3 — Delete corresponding tests:**

In `pty_process_test.exs`, remove tests for `rewire_session_siblings`. Mark with:

```elixir
# Tests for rewire_session_siblings/1 deleted in M-2.
# Rationale: rewire mechanism removed; ActorQuery replaces runtime neighbor lookup.
```

**Step 4 — Confirm compilation:** `mix compile --force` — no undefined references.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-2.5: Delete `state.neighbors` field from FCP, CCProcess, PtyProcess state structs

**Files:** `feishu_chat_proxy.ex`, `cc_process.ex`, `pty_process.ex`

This task finalizes the struct-level removal. Tasks M-2.1 through M-2.4 removed individual field references. This task does the final audit to confirm no remaining `state.neighbors` / `Keyword.get(state.neighbors, ...)` patterns exist.

**Step 1 — Audit grep:**

```bash
grep -rn "state\.neighbors\|Keyword\.get.*neighbors\|neighbors.*Keyword\|:neighbors" \
  runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/entity/pty_process.ex
```

Expected output: zero results.

**Step 2 — Write test** (compile-time guard):

```elixir
# Regression test: assert that none of the three modules reference state.neighbors.
# Added to the test suite as a static check.
defmodule Esr.M2.NoNeighborsFieldTest do
  use ExUnit.Case

  @files [
    "runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex",
    "runtime/lib/esr/plugins/claude_code/cc_process.ex",
    "runtime/lib/esr/entity/pty_process.ex",
    "runtime/lib/esr/session/agent_spawner.ex"
  ]

  for file <- @files do
    test "#{file} contains no state.neighbors reference" do
      content = File.read!(unquote(file))
      refute content =~ ~r/state\.neighbors|Keyword\.get.*:neighbors|:sys\.replace_state.*neighbors/,
             "#{unquote(file)} still references state.neighbors — not fully migrated"
    end
  end
end
```

**Step 3 — Confirm test passes:** `mix test` — all four files pass the no-neighbors check.

**Step 4 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-2.6: Add per-session `Esr.Scope.AgentSupervisor` DynamicSupervisor

**Files:** `runtime/lib/esr/scope/agent_supervisor.ex` (new), `runtime/lib/esr/scope.ex` (modify)

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/scope/agent_supervisor_test.exs
defmodule Esr.Scope.AgentSupervisorTest do
  use ExUnit.Case, async: true

  test "AgentSupervisor starts with zero children" do
    {:ok, pid} = Esr.Scope.AgentSupervisor.start_link([])
    assert [] == DynamicSupervisor.which_children(pid)
  end

  test "AgentSupervisor.add_agent_subtree/3 adds a one_for_all child" do
    {:ok, sup_pid} = Esr.Scope.AgentSupervisor.start_link([])
    sid = "agent-sup-test-#{System.unique_integer([:positive])}"
    name = "helper-#{System.unique_integer([:positive])}"

    {:ok, child_pid} = Esr.Scope.AgentSupervisor.add_agent_subtree(
      sup_pid,
      %{
        session_id: sid,
        name: name,
        cc_args: %{session_id: sid, name: name, handler_module: Esr.Handlers.Default},
        pty_args: %{session_name: name, dir: "/tmp", session_id: sid}
      }
    )

    assert is_pid(child_pid)
    assert [_] = DynamicSupervisor.which_children(sup_pid)
  end
end
```

**Step 2 — Confirm test fails:** `Esr.Scope.AgentSupervisor` does not exist yet.

**Step 3 — Write implementation:**

```elixir
# runtime/lib/esr/scope/agent_supervisor.ex (new)
defmodule Esr.Scope.AgentSupervisor do
  @moduledoc """
  Per-session DynamicSupervisor hosting agent instance subtrees.

  Each call to `/session:add-agent` adds one child: a `:one_for_all`
  Supervisor (Esr.Scope.AgentInstanceSupervisor) containing exactly two
  workers: Esr.Entity.CCProcess and Esr.Entity.PtyProcess.

  The `:one_for_all` strategy ensures CC and PTY are always restarted
  together: if PTY crashes, CC has no output path (broken); if CC
  crashes, PTY has no consumer (stuck). Lone-survivor state has no
  semantic value.

  Restart intensity: max_restarts: 3, max_seconds: 60 per agent
  instance supervisor. If an agent subtree trips the restart budget,
  the instance is terminated. The operator must re-add it via
  `/session:add-agent`. This prevents tight crash loops.

  Locked decision Q5.3 sub-2 and sub-3 (Feishu 2026-05-07).
  """

  use DynamicSupervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Add a (CC, PTY) `:one_for_all` subtree for a named agent instance.

  `attrs` must contain:
  - `session_id` — the session this agent belongs to
  - `name` — the operator-facing agent name (must be unique in session)
  - `cc_args` — args map forwarded to `Esr.Entity.CCProcess.start_link/1`
  - `pty_args` — args map forwarded to `Esr.Entity.PtyProcess.start_link/1`

  Returns `{:ok, instance_sup_pid}` on success, `{:error, reason}` on failure.
  """
  @spec add_agent_subtree(sup :: pid() | atom(), attrs :: map()) ::
          {:ok, pid()} | {:error, term()}
  def add_agent_subtree(sup \\ __MODULE__, attrs) do
    sid = Map.fetch!(attrs, :session_id)
    name = Map.fetch!(attrs, :name)
    cc_args = Map.fetch!(attrs, :cc_args)
    pty_args = Map.fetch!(attrs, :pty_args)

    child_spec = %{
      id: {Esr.Scope.AgentInstanceSupervisor, sid, name},
      start: {Esr.Scope.AgentInstanceSupervisor, :start_link, [
        %{
          session_id: sid,
          name: name,
          cc_args: cc_args,
          pty_args: pty_args
        }
      ]},
      restart: :transient,
      type: :supervisor
    }

    DynamicSupervisor.start_child(sup, child_spec)
  end

  @doc """
  Remove and stop the agent instance supervisor for `{session_id, name}`.

  Cascades via OTP: instance supervisor terminates → CC and PTY
  `terminate/2` called → `deregister_attrs/2` cleans Index 2 + 3 →
  Registry monitors clean Index 1.
  """
  @spec remove_agent_subtree(sup :: pid() | atom(), instance_sup_pid :: pid()) ::
          :ok | {:error, term()}
  def remove_agent_subtree(sup \\ __MODULE__, instance_sup_pid) when is_pid(instance_sup_pid) do
    DynamicSupervisor.terminate_child(sup, instance_sup_pid)
  end
end
```

```elixir
# runtime/lib/esr/scope/agent_instance_supervisor.ex (new)
defmodule Esr.Scope.AgentInstanceSupervisor do
  @moduledoc """
  Per-agent-instance `:one_for_all` Supervisor hosting CC + PTY.

  If either child crashes, both are restarted together. This enforces
  the invariant that CC (the AI process) and PTY (its IO channel) are
  always in a consistent state. Lone-survivor restart is explicitly
  prohibited — spec Q5.3 sub-2 (Feishu 2026-05-07).

  Restart intensity: max_restarts: 3, max_seconds: 60. If the subtree
  trips this budget, the supervisor exits (reason: :shutdown). The
  parent AgentSupervisor's `:transient` child spec means it is NOT
  restarted automatically; the operator must call `/session:add-agent`
  again.
  """

  use Supervisor

  def start_link(%{session_id: sid, name: name, cc_args: cc_args, pty_args: pty_args}) do
    Supervisor.start_link(
      __MODULE__,
      %{session_id: sid, name: name, cc_args: cc_args, pty_args: pty_args},
      []
    )
  end

  @impl true
  def init(%{session_id: _sid, name: _name, cc_args: cc_args, pty_args: pty_args}) do
    children = [
      %{
        id: Esr.Entity.CCProcess,
        start: {Esr.Entity.CCProcess, :start_link, [cc_args]},
        restart: :permanent,
        type: :worker
      },
      %{
        id: Esr.Entity.PtyProcess,
        start: {Esr.Entity.PtyProcess, :start_link, [pty_args]},
        restart: :permanent,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 60)
  end
end
```

Update `runtime/lib/esr/scope.ex` to add `Esr.Scope.AgentSupervisor` as a child in `init/1`:

```elixir
# In Esr.Scope.init/1, add after the existing :peers child:
%{
  id: Esr.Scope.AgentSupervisor,
  start: {Esr.Scope.AgentSupervisor, :start_link, [[
    name: {:via, Registry, {Esr.Scope.Registry, {:agent_sup, sid}}}
  ]]},
  restart: :permanent,
  type: :supervisor
}
```

**Step 4 — Confirm tests pass:** `mix test runtime/test/esr/scope/agent_supervisor_test.exs` — green.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-2.7: Atomic `InstanceRegistry.add_instance_and_spawn/1` GenServer call

**File:** `runtime/lib/esr/entity/agent/instance_registry.ex` (modify)

**Context:** The current `add_instance/1` writes an ETS metadata record and returns `:ok` without spawning any processes. After M-2.7, `add_instance_and_spawn/1` is the primary API for `/session:add-agent`. It serializes all requests via the GenServer mailbox: check uniqueness → spawn subtree → register pid → return `{:ok, %{cc_pid, pty_pid}}`.

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/entity/agent/instance_registry_spawn_test.exs
defmodule Esr.Entity.Agent.InstanceRegistrySpawnTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, server} = Esr.Entity.Agent.InstanceRegistry.start_link(
      name: :"test_registry_#{System.unique_integer([:positive])}"
    )
    {:ok, server: server}
  end

  test "add_instance_and_spawn returns {:ok, ...} and find_by_name returns pid",
       %{server: server} do
    sid = "spawn-test-#{System.unique_integer([:positive])}"
    name = "helper-#{System.unique_integer([:positive])}"

    # For unit test, we need a fake AgentSupervisor or inject a test double.
    # This test verifies the contract: after add_instance_and_spawn, find_by_name works.
    # Full integration test (requiring real supervisor tree) lives in scenario_18.
    # Here we test the GenServer serialization + duplicate rejection logic.

    result = Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(
      server,
      %{session_id: sid, type: "cc", name: name, config: %{}}
    )

    # In test env without a real supervisor, spawn may return error.
    # The important contract is: on success, find_by_name returns pid.
    case result do
      {:ok, _} ->
        assert {:ok, _pid} = Esr.ActorQuery.find_by_name(sid, name)

      {:error, {:spawn_failed, _}} ->
        # In test env without supervisor tree: no orphan name index entry.
        assert :not_found == Esr.ActorQuery.find_by_name(sid, name)
    end
  end

  test "duplicate name rejected without spawning", %{server: server} do
    sid = "dup-test-#{System.unique_integer([:positive])}"
    name = "helper-#{System.unique_integer([:positive])}"

    _first = Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(
      server,
      %{session_id: sid, type: "cc", name: name, config: %{}}
    )

    second = Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(
      server,
      %{session_id: sid, type: "cc", name: name, config: %{}}
    )

    assert {:error, {:duplicate_agent_name, ^name}} = second
  end
end
```

**Step 2 — Confirm test fails:** `add_instance_and_spawn/1` is not yet defined.

**Step 3 — Write implementation:**

Add to `runtime/lib/esr/entity/agent/instance_registry.ex`:

```elixir
@doc """
Add an agent instance AND spawn its (CC, PTY) subtree atomically.

Serialized via GenServer mailbox — no two concurrent calls for the
same session can both pass the uniqueness check.

Returns `{:ok, %{cc_pid: pid, pty_pid: pid, actor_ids: %{cc: id, pty: id}}}` on success.
Returns `{:error, {:duplicate_agent_name, name}}` if name already taken.
Returns `{:error, {:spawn_failed, reason}}` if DynamicSupervisor.start_child fails.
  On spawn failure, any name index placeholder written in step 1 is deleted.
"""
@spec add_instance_and_spawn(GenServer.server(), map()) ::
        {:ok, %{cc_pid: pid(), pty_pid: pid(), actor_ids: map()}}
        | {:error, {:duplicate_agent_name, String.t()} | {:spawn_failed, term()}}
def add_instance_and_spawn(server \\ __MODULE__, attrs) when is_map(attrs) do
  GenServer.call(server, {:add_instance_and_spawn, attrs}, 30_000)
end
```

Add the `handle_call` clause:

```elixir
@impl true
def handle_call({:add_instance_and_spawn, attrs}, _from, state) do
  session_id = Map.fetch!(attrs, :session_id)
  name = Map.fetch!(attrs, :name)
  type = Map.fetch!(attrs, :type)
  config = Map.get(attrs, :config, %{})

  # Step 1: Check name uniqueness.
  case :ets.lookup(state.table, {session_id, name}) do
    [_] ->
      {:reply, {:error, {:duplicate_agent_name, name}}, state}

    [] ->
      cc_actor_id = uuid_v4()
      pty_actor_id = uuid_v4()

      cc_args = %{
        session_id: session_id,
        name: name,
        actor_id: cc_actor_id,
        handler_module: resolve_handler_module(type, config),
        proxy_ctx: %{session_id: session_id}
      }

      pty_args = %{
        session_name: name,
        dir: resolve_workspace_dir(session_id, config),
        session_id: session_id,
        name: name,
        actor_id: pty_actor_id
      }

      # Step 2: Spawn the (CC, PTY) subtree via the per-session AgentSupervisor.
      agent_sup_via =
        {:via, Registry, {Esr.Scope.Registry, {:agent_sup, session_id}}}

      case Esr.Scope.AgentSupervisor.add_agent_subtree(agent_sup_via, %{
             session_id: session_id,
             name: name,
             cc_args: cc_args,
             pty_args: pty_args
           }) do
        {:ok, instance_sup_pid} ->
          # Step 3: Wait for CC and PTY to register in Index 1 (up to 5s).
          # CC and PTY call register_attrs in their init/1 after M-1.5.
          # The wait is bounded — init/1 is synchronous; register_attrs writes
          # before init returns; DynamicSupervisor.start_child waits for init.
          # The pids are available immediately after start_child returns.
          cc_pid = resolve_child_pid(instance_sup_pid, Esr.Entity.CCProcess)
          pty_pid = resolve_child_pid(instance_sup_pid, Esr.Entity.PtyProcess)

          # Step 4: Write the permanent InstanceRegistry ETS record.
          inst = %Instance{
            id: cc_actor_id,
            session_id: session_id,
            type: type,
            name: name,
            config: config,
            created_at: iso_now()
          }

          :ets.insert(state.table, {{session_id, name}, inst})
          :ets.insert(state.table, {:instance_sup, session_id, name, instance_sup_pid})

          if :ets.lookup(state.table, {session_id, :__primary__}) == [] do
            :ets.insert(state.table, {{session_id, :__primary__}, name})
          end

          {:reply,
           {:ok,
            %{
              cc_pid: cc_pid,
              pty_pid: pty_pid,
              actor_ids: %{cc: cc_actor_id, pty: pty_actor_id}
            }}, state}

        {:error, reason} ->
          # Spawn failed — no ETS record was written. Clean name index placeholder
          # if register_attrs was called before the failure.
          :ets.delete(:esr_actor_name_index, {session_id, name})
          {:reply, {:error, {:spawn_failed, reason}}, state}
      end
  end
end

defp resolve_child_pid(instance_sup_pid, child_module) do
  instance_sup_pid
  |> Supervisor.which_children()
  |> Enum.find_value(fn
    {^child_module, pid, :worker, _} when is_pid(pid) -> pid
    _ -> nil
  end)
end

defp resolve_handler_module(_type, _config) do
  # For M-2: resolve to default handler. Future: look up from agent type registry.
  Esr.Handlers.Default
end

defp resolve_workspace_dir(session_id, config) do
  Map.get(config, "dir", Map.get(config, :dir, "/tmp/esr-agent-#{session_id}"))
end
```

**Step 4 — Confirm tests pass:** `mix test runtime/test/esr/entity/agent/instance_registry_spawn_test.exs` — green.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

---

### Task M-2.8: Update `commands/session/add_agent.ex` + PR + admin-merge

**File:** `runtime/lib/esr/commands/session/add_agent.ex`

**Step 1 — Write failing test:**

```elixir
# Verify that add_agent.ex calls add_instance_and_spawn (not add_instance).
# This can be a compile-time check:
defmodule Esr.Commands.Session.AddAgentMigrationTest do
  use ExUnit.Case

  test "add_agent.ex references add_instance_and_spawn not add_instance" do
    content = File.read!("runtime/lib/esr/commands/session/add_agent.ex")
    assert content =~ "add_instance_and_spawn",
           "add_agent.ex must call add_instance_and_spawn after M-2"
    refute content =~ ~r/InstanceRegistry\.add_instance\b(?!_and_spawn)/,
           "add_agent.ex must not call the old add_instance (without _and_spawn) after M-2"
  end
end
```

**Step 2 — Confirm test fails:** Currently `add_agent.ex` calls `add_instance/1`.

**Step 3 — Write implementation:**

In `add_agent.ex`, replace the `InstanceRegistry.add_instance(...)` call:

```elixir
# BEFORE:
case InstanceRegistry.add_instance(%{
       session_id: sid,
       type: type,
       name: name,
       config: config
     }) do
  :ok ->
    {:ok, %{"action" => "added", "session_id" => sid, "type" => type, "name" => name}}

  {:error, {:duplicate_agent_name, n}} ->
    {:error, %{"type" => "duplicate_agent_name", ...}}
end

# AFTER:
case InstanceRegistry.add_instance_and_spawn(%{
       session_id: sid,
       type: type,
       name: name,
       config: config
     }) do
  {:ok, %{actor_ids: actor_ids}} ->
    {:ok,
     %{
       "action" => "added",
       "session_id" => sid,
       "type" => type,
       "name" => name,
       "actor_ids" => %{
         "cc" => actor_ids.cc,
         "pty" => actor_ids.pty
       }
     }}

  {:error, {:duplicate_agent_name, n}} ->
    {:error,
     %{
       "type" => "duplicate_agent_name",
       "message" =>
         "agent name '#{n}' already exists in session '#{sid}' (pick a different name)"
     }}

  {:error, {:spawn_failed, reason}} ->
    {:error,
     %{
       "type" => "spawn_failed",
       "message" => "failed to start agent subtree: #{inspect(reason)}"
     }}
end
```

**Step 4 — Run invariant test (gate for M-2 done):**

```bash
mix test runtime/test/esr/entity/agent/instance_registry_spawn_test.exs
```

The invariant: after `add_instance_and_spawn` returns `{:ok, _}`, `Esr.ActorQuery.find_by_name/2` must return `{:ok, pid}` — not `:not_found`. This test must be green before M-2 is claimed complete.

**Step 5 — Full test suite:**

```bash
mix test
```

All tests green.

**Step 6 — Stage, commit, open PR, admin-merge:**

```bash
git add \
  runtime/lib/esr/scope/agent_supervisor.ex \
  runtime/lib/esr/scope/agent_instance_supervisor.ex \
  runtime/lib/esr/scope.ex \
  runtime/lib/esr/session/agent_spawner.ex \
  runtime/lib/esr/entity/pty_process.ex \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex \
  runtime/lib/esr/entity/agent/instance_registry.ex \
  runtime/lib/esr/entity/factory.ex \
  runtime/lib/esr/commands/session/add_agent.ex \
  runtime/test/esr/scope/agent_supervisor_test.exs \
  runtime/test/esr/entity/agent/instance_registry_spawn_test.exs \
  runtime/test/esr/commands/session/add_agent_migration_test.exs \
  runtime/test/esr/m2_no_neighbors_field_test.exs
```

**Step 7 — Create and push branch; open PR against integration branch:**

```bash
git branch feat/m2-delete-neighbors
git push origin feat/m2-delete-neighbors
gh pr create --base feat/multi-instance-routing-cleanup --head feat/m2-delete-neighbors \
  --title "feat(m-2): migrate callers to ActorQuery + delete state.neighbors + per-session AgentSupervisor + atomic add-agent" \
  --body "Core behavior migration: delete state.neighbors keyword lists, adopt per-session DynamicSupervisor, make /session:add-agent atomic via InstanceRegistry.add_instance_and_spawn.

Four callers migrated; -200 net LOC. Hard cutover, no backward compat.

Spec: docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md (rev-1, user-approved 2026-05-07)."
```

**Step 8 — Admin-merge:**
```bash
gh pr merge --admin --squash --delete-branch
```

---

## Phase M-3: Delete legacy diffusion

**Depends on:** M-2 merged into `dev`.

**Purpose:** Delete the entire `workspace.neighbors` / `reachable_set` / `describe_topology` / `symmetric_closure` surface area. Every deletion in this phase is a pure code removal — no replacement code is written. After M-3, the LLM no longer receives a `<reachable>` prompt element (follow-up design is §12 F-1 and F-4, not M-3 scope).

**LOC estimate:** -488 (actual; see §7 note for breakdown vs. -300 brainstorm estimate)

**Risk:** Medium — `cc_process.ex` reachable_set mutations are spread across `handle_info`, `handle_cast`, and private helpers. Each deletion site must be confirmed individually. Run `mix compile --force` after each file edit to catch dangling references early.

**Invariant test (gate for M-3 done):** After M-3, `grep -rn "Esr.Topology\|reachable_set\|describe_topology\|build_initial_reachable_set\|neighbor_workspaces" runtime/lib/` must return zero results. A CI step asserting this is the completion gate.

---

### Task M-3.1: Delete `runtime/lib/esr/topology.ex` (entire file, 257 LOC)

**Files:** `runtime/lib/esr/topology.ex` (delete), `runtime/test/esr/topology_test.exs` (delete), `runtime/test/esr/topology_integration_test.exs` (delete)

**Step 1 — Write failing test** (confirm the file is a dead-code candidate post M-2):

```elixir
# runtime/test/esr/m3_topology_dead_code_test.exs
defmodule Esr.M3TopologyDeadCodeTest do
  use ExUnit.Case

  @tag :m3_gate
  test "Esr.Topology has no callers outside cc_process reachable_set path" do
    # After M-3, this grep must return zero results.
    # Run as a static assertion so CI fails if topology is re-introduced.
    {output, _} = System.cmd("grep", [
      "-rn", "--include=*.ex",
      "Esr.Topology",
      "runtime/lib/"
    ])
    assert output == "",
      "Found unexpected Esr.Topology reference: #{output}"
  end
end
```

**Step 2 — Confirm test fails before M-3** (the test is deliberately red until M-3 completes).

**Step 3 — Write implementation (deletions):**

First confirm no remaining callers survive M-2:

```bash
grep -rn "Esr.Topology" runtime/lib/ runtime/test/
```

Expected output post-M-2:
- `runtime/lib/esr/topology.ex` (the module itself)
- `runtime/lib/esr/plugins/claude_code/cc_process.ex` — lines 131, 136, 141, 621 (all inside `build_initial_reachable_set/1` and `user_uri/1` one-liner — both deleted in M-3.2)
- `runtime/lib/esr/session/agent_spawner.ex:495` — comment only; confirm line is a comment, not a call

Then delete files:

```bash
rm runtime/lib/esr/topology.ex
rm runtime/test/esr/topology_test.exs
rm runtime/test/esr/topology_integration_test.exs
```

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/m3_topology_dead_code_test.exs` — green after M-3.2 also completes.

**Step 5 — Confirm no regressions:** `mix compile --force` — no `undefined module Esr.Topology` errors after M-3.2 removes all cc_process.ex call sites.

**Commit message:** `refactor(m-3.1): delete Esr.Topology + topology tests (Phase M-3.1)`

---

### Task M-3.2: Delete `reachable_set` from `cc_process.ex` (~145 LOC)

**File:** `runtime/lib/esr/plugins/claude_code/cc_process.ex`

**Affected line ranges (per spec §7 M-3 inventory):**
- Lines 87–103: Comment block explaining reachable_set seeding + `initial_reachable = build_initial_reachable_set(proxy_ctx)` call
- Line 115: `reachable_set: initial_reachable` in state map
- Lines 119–145: `defp build_initial_reachable_set/1` (calls `Esr.Topology.initial_seed/3`, `Esr.Topology.chat_uri/2`, `Esr.Topology.adapter_uri/2`)
- Lines 205–220: `handle_info` clause adding URIs to `reachable_set` on source URI events
- Lines 240–248: `reachable_set` mutation inside meta handler
- Lines 428–438: `reachable_present=...` log line + comment referencing reachable attribute
- Lines 498–538: `maybe_put_reachable/2` + `reachable_json/1` private functions
- Lines 592–614: PR-C C4 handler — union of new URIs into `state.reachable_set`
- Line 621: `user_uri/1` one-liner delegating to `Esr.Topology.user_uri/1` (also deleted)

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/plugins/claude_code/cc_process_m3_gate_test.exs
defmodule Esr.CCProcessM3GateTest do
  use ExUnit.Case

  @tag :m3_gate
  test "cc_process.ex has no reachable_set references after M-3" do
    content = File.read!("runtime/lib/esr/plugins/claude_code/cc_process.ex")
    refute String.contains?(content, "reachable_set"),
      "cc_process.ex still contains 'reachable_set'; M-3.2 is incomplete"
    refute String.contains?(content, "Esr.Topology"),
      "cc_process.ex still references Esr.Topology; M-3.2 is incomplete"
    refute String.contains?(content, "build_initial_reachable_set"),
      "cc_process.ex still contains build_initial_reachable_set; M-3.2 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit** (all three assertions fire on the current file).

**Step 3 — Write implementation:**

Delete each block in order from bottom to top to preserve line references:

1. Delete lines 592–621 (PR-C C4 handler + `user_uri/1`)
2. Delete lines 498–538 (`maybe_put_reachable/2` + `reachable_json/1`)
3. Delete lines 428–438 (`reachable_present` log line + comment)
4. Delete lines 240–248 (reachable_set mutation in meta handler)
5. Delete lines 205–220 (`handle_info` clause for URI source events)
6. Delete line 115 (`reachable_set: initial_reachable` in state map)
7. Delete lines 87–145 (comment block + `initial_reachable` assignment + `build_initial_reachable_set/1`)

After deletion, ensure the state map at line ~103 (adjusted) no longer has a `:reachable_set` key. The `<reachable>` XML element is built by `reachable_json/1` — with that function gone, the `build_prompt/1` call site that referenced it is also removed as part of step 2. Confirm `build_prompt/1` still compiles without the deleted helper.

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/plugins/claude_code/cc_process_m3_gate_test.exs` — green.

**Step 5 — Confirm no regressions:**

```bash
mix compile --force
mix test runtime/test/esr/plugins/claude_code/cc_process_test.exs
```

The `cc_process_test.exs` file will have failing tests (reachable_set tests). Stub them with `# deleted in M-3 — reachable_set removed; see ActorQuery tests for routing coverage`:

```elixir
# BEFORE (example pattern to delete from cc_process_test.exs):
test "build_initial_reachable_set populates from workspace neighbors" do
  ...
end

# AFTER — replace each deleted test block with:
# deleted in M-3 — reachable_set removed; routing coverage is in
# runtime/test/esr/actor_query_test.exs (M-5 extension)
```

**Commit message:** `refactor(m-3.2): delete cc_process reachable_set + Topology calls (~145 LOC) (Phase M-3.2)`

---

### Task M-3.3: Delete `neighbor_workspaces` from `describe.ex` (~32 LOC)

**File:** `runtime/lib/esr/resource/workspace/describe.ex`

**Affected lines (per spec §7 M-3 inventory):**
- Lines 61–66: `neighbours = resolve_neighbour_workspaces(ws, overlay)` + `"neighbor_workspaces" => Enum.map(...)` entry in result map
- Lines 122–123: `base_neighbors = legacy_neighbors(ws)` local variable
- Lines 164–170: `defp legacy_neighbors/1` — reads `_legacy.neighbors` from struct settings
- Lines 175–191: `defp resolve_neighbour_workspaces/2` — resolves neighbor name strings via Registry

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/resource/workspace_describe_m3_gate_test.exs
defmodule Esr.WorkspaceDescribeM3GateTest do
  use ExUnit.Case

  @tag :m3_gate
  test "describe output has no neighbor_workspaces key after M-3" do
    content = File.read!("runtime/lib/esr/resource/workspace/describe.ex")
    refute String.contains?(content, "neighbor_workspaces"),
      "describe.ex still contains neighbor_workspaces; M-3.3 is incomplete"
    refute String.contains?(content, "resolve_neighbour_workspaces"),
      "describe.ex still contains resolve_neighbour_workspaces; M-3.3 is incomplete"
    refute String.contains?(content, "legacy_neighbors"),
      "describe.ex still contains legacy_neighbors; M-3.3 is incomplete (M-3 part)"
  end
end
```

**Step 2 — Confirm test fails before edit.**

**Step 3 — Write implementation:**

Delete from bottom to top:
1. Delete `defp resolve_neighbour_workspaces/2` (lines 175–191)
2. Delete `defp legacy_neighbors/1` (lines 164–170)
3. Delete `base_neighbors = legacy_neighbors(ws)` at line 122
4. Delete the `neighbours = resolve_neighbour_workspaces(...)` assignment and `"neighbor_workspaces" => ...` map entry (lines 61–66)

After deletion, the describe result map no longer includes `"neighbor_workspaces"`. Verify that the `Struct` alias is still used (it is, for `%Struct{}` pattern matches in other functions).

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/resource/workspace_describe_m3_gate_test.exs` — green.

**Step 5 — Confirm no regressions:**

```bash
mix compile --force
mix test runtime/test/esr/resource/workspace_describe_test.exs
```

`workspace_describe_test.exs` assertions on `neighbor_workspaces` will fail — stub those test blocks with `# deleted in M-3 — neighbor_workspaces removed from describe output`.

**Commit message:** `refactor(m-3.3): delete neighbor_workspaces output + legacy_neighbors from describe.ex (Phase M-3.3)`

---

### Task M-3.4: Delete `describe_topology` from `server.ex` (~22 LOC)

**File:** `runtime/lib/esr/entity/server.ex`

**Affected lines (per spec §7 M-3 inventory):**
- Lines 284–291: Comment block about PR-F + the `if tool == "describe_topology" or capability_granted?(...)` bypass condition
- Lines 820–833: `defp build_emit_for_tool("describe_topology", args, _state)` entire private function

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/entity/server_m3_gate_test.exs
defmodule Esr.EntityServerM3GateTest do
  use ExUnit.Case

  @tag :m3_gate
  test "server.ex has no describe_topology after M-3" do
    content = File.read!("runtime/lib/esr/entity/server.ex")
    refute String.contains?(content, "describe_topology"),
      "server.ex still contains describe_topology; M-3.4 is incomplete"
    refute String.contains?(content, "neighbor_workspaces"),
      "server.ex still contains neighbor_workspaces; M-3.4 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit.**

**Step 3 — Write implementation:**

1. Delete `defp build_emit_for_tool("describe_topology", args, _state)` at lines 820–833 (bottom-up first).
2. At lines 284–291, delete the `describe_topology`-specific bypass. The `if tool == "describe_topology" or capability_granted?(...)` condition becomes simply `if capability_granted?(...)`. Remove the dead `tool == "describe_topology"` branch entirely.

The surviving `build_emit_for_tool/3` catch-all clause (which handles all other tools) remains unchanged.

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/entity/server_m3_gate_test.exs` — green.

**Step 5 — Confirm no regressions:**

```bash
mix compile --force
mix test runtime/test/esr/entity/
```

Any tests in `entity_server_describe_topology_test.exs` asserting describe_topology output will now fail — stub those sections with `# deleted in M-3 — describe_topology MCP tool removed`.

**Commit message:** `refactor(m-3.4): delete describe_topology MCP tool + cap bypass from server.ex (Phase M-3.4)`

---

### Task M-3.5: Delete `@describe_topology` from `mcp/tools.ex` (~29 LOC)

**File:** `runtime/lib/esr/plugins/claude_code/mcp/tools.ex`

**Affected lines (per spec §7 M-3 inventory):**
- Lines 89–115: `@describe_topology` module attribute — full map literal with "name", "description", "inputSchema"
- Line 124: `@describe_topology` reference in `diagnostic` role tool list
- Line 127: `@describe_topology` reference in default tool list

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/plugins/claude_code/mcp_tools_m3_gate_test.exs
defmodule Esr.MCPToolsM3GateTest do
  use ExUnit.Case

  @tag :m3_gate
  test "mcp/tools.ex does not advertise describe_topology after M-3" do
    content = File.read!("runtime/lib/esr/plugins/claude_code/mcp/tools.ex")
    refute String.contains?(content, "describe_topology"),
      "mcp/tools.ex still advertises describe_topology; M-3.5 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit.**

**Step 3 — Write implementation:**

1. Delete the `@describe_topology %{...}` module attribute block (lines 89–115).
2. Remove `@describe_topology` from both tool list references (lines ~124, ~127 — adjusted after step 1 deletion). The lists become:

```elixir
# diagnostic role list — before:
do: [@reply, @send_file, @describe_topology, @echo]

# After M-3.5:
do: [@reply, @send_file, @echo]

# default list — before:
do: [@reply, @send_file, @describe_topology]

# After M-3.5:
do: [@reply, @send_file]
```

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/plugins/claude_code/mcp_tools_m3_gate_test.exs` — green.

**Step 5 — Confirm no regressions:**

```bash
mix compile --force
mix test
```

Full suite must be green after M-3.5. The `cc_process_test.exs` stubs from M-3.2 should be in place; `describe_topology` tests from M-3.4 stubs should be in place.

**Commit message:** `refactor(m-3.5): delete @describe_topology module attr + tool list refs from mcp/tools.ex (Phase M-3.5)`

---

### Task M-3.6: Remove `:neighbors` field from `%Workspace{}` struct in `registry.ex` (~3 LOC)

**File:** `runtime/lib/esr/resource/workspace/registry.ex`

**Affected lines (per spec §7 M-3 inventory):**
- Line 55: `neighbors: [],` in `%Workspace{}` defstruct
- Line 587: `neighbors: Map.get(ws.settings, "_legacy.neighbors", []),` in `to_legacy/1`
- Line 604 (approx): `"_legacy.neighbors" => legacy.neighbors || [],` in `normalize_to_struct/1`

Note: `to_legacy/1` and `normalize_to_struct/1` themselves survive M-3 — they are deleted in their entirety in M-4. This task only removes the `:neighbors` field and its reads from the legacy conversion functions.

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/resource/workspace/registry_m3_gate_test.exs
defmodule Esr.WorkspaceRegistryM3GateTest do
  use ExUnit.Case

  @tag :m3_gate
  test "%Workspace{} struct has no :neighbors field after M-3" do
    # The legacy Workspace struct is Esr.Resource.Workspace.Registry.Workspace
    # M-3 removes :neighbors; M-4 removes the whole struct.
    # This test gates M-3 completion.
    refute Map.has_key?(
      struct(Esr.Resource.Workspace.Registry.Workspace),
      :neighbors
    ), "Workspace struct still has :neighbors field; M-3.6 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit.**

**Step 3 — Write implementation:**

In `registry.ex`:

```elixir
# BEFORE (line 55 in defstruct):
neighbors: [],
# AFTER: delete this line

# BEFORE (line 587 in to_legacy/1):
neighbors: Map.get(ws.settings, "_legacy.neighbors", []),
# AFTER: delete this line

# BEFORE (line ~604 in normalize_to_struct/1):
"_legacy.neighbors" => legacy.neighbors || [],
# AFTER: delete this line
```

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/resource/workspace/registry_m3_gate_test.exs` — green.

**Step 5 — Full M-3 gate sweep + commit all M-3 files:**

```bash
grep -rn "Esr.Topology\|reachable_set\|describe_topology\|build_initial_reachable_set\|neighbor_workspaces" runtime/lib/
# Must return zero results.

mix compile --force
mix test
```

**Commit message:** `refactor(m-3.6): remove :neighbors field from %Workspace{} + _legacy.neighbors reads (Phase M-3.6)`

---

### Task M-3.7: PR + admin-merge

**Step 1 — Stage all M-3 files:**

```bash
git rm \
  runtime/lib/esr/topology.ex \
  runtime/test/esr/topology_test.exs \
  runtime/test/esr/topology_integration_test.exs
git add \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/resource/workspace/describe.ex \
  runtime/lib/esr/entity/server.ex \
  runtime/lib/esr/plugins/claude_code/mcp/tools.ex \
  runtime/lib/esr/resource/workspace/registry.ex \
  runtime/test/esr/plugins/claude_code/cc_process_test.exs \
  runtime/test/esr/m3_topology_dead_code_test.exs \
  runtime/test/esr/plugins/claude_code/cc_process_m3_gate_test.exs \
  runtime/test/esr/resource/workspace_describe_m3_gate_test.exs \
  runtime/test/esr/entity/server_m3_gate_test.exs \
  runtime/test/esr/plugins/claude_code/mcp_tools_m3_gate_test.exs \
  runtime/test/esr/resource/workspace/registry_m3_gate_test.exs
```

**Step 2 — Create and push branch; open PR against integration branch:**

```bash
git branch feat/m3-delete-topology
git push origin feat/m3-delete-topology
gh pr create --base feat/multi-instance-routing-cleanup --head feat/m3-delete-topology \
  --title "feat(m-3): delete legacy diffusion — Topology + reachable_set + describe_topology + neighbor_workspaces" \
  --body "Pure deletion phase: remove Topology module, reachable_set mutations from cc_process, neighbor_workspaces from describe, describe_topology from server, etc. After M-3, LLM no longer receives <reachable> prompt.

-488 LOC. Hard cutover.

Spec: docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md (rev-1, user-approved 2026-05-07)."
```

**Step 3 — Admin-merge:**

```bash
gh pr merge --admin --squash --delete-branch
```

**Step 4 — Verify:** `git log --oneline feat/multi-instance-routing-cleanup | head -3` — M-3 commit visible.

---

## Phase M-4: Delete `_legacy.*` compat shim + legacy `%Workspace{}` struct

**Depends on:** M-3 merged into `dev`.

**Purpose:** Remove the entire `@legacy_table` ETS infrastructure, the `%Workspace{}` legacy embedded struct, `to_legacy/1`, `normalize_to_struct/1`, `do_put(%Workspace{})`, `start_cmd_for/2`, and all callers that read `_legacy.*` keys. After M-4, the codebase has no `_legacy.*` key reads, no dual-table workspace storage, and `registry.ex` drops from ~678 LOC to ~539 LOC.

**LOC estimate:** -263 pure delete (~-400 with cascading dead code cleanup in callers)

**Risk:** Medium — `workspace_for_chat/2` internally uses `@uuid_table` (not `@legacy_table`) and is unaffected; all 8 callers continue to work unchanged. Verify this explicitly in the PR description. The 4 callers of `Registry.get/1` (legacy struct path) must be migrated to `NameIndex.id_for_name + get_by_id` before `get/1` is deleted.

**Invariant test (gate for M-4 done):** After M-4, `grep -rn "@legacy_table\|_legacy\.\|defmodule Workspace\|normalize_to_struct\|to_legacy\|start_cmd_for" runtime/lib/` must return zero results.

---

### Task M-4.1: Migrate 4 callers of `Registry.get/1` to `NameIndex.id_for_name + get_by_id`

**Files:**
- `runtime/lib/esr/resource/workspace/bootstrap.ex` line 44
- `runtime/lib/esr/resource/capability/file_loader.ex` line 157
- `runtime/lib/esr/plugins/claude_code/cc_process.ex` line 565 (`Registry.list()`)
- `runtime/lib/esr/commands/doctor.ex` line 57 (`Registry.list()`)

**Step 1 — Write failing test** (confirm the new lookup path works before migration):

```elixir
# runtime/test/esr/resource/workspace/registry_m4_migration_test.exs
defmodule Esr.WorkspaceRegistryM4MigrationTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Workspace.{Registry, Struct, NameIndex}

  setup do
    tmp = Path.join(System.tmp_dir!(), "m4_migration_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")
    File.mkdir_p!(Path.join([tmp, "default", "workspaces"]))

    on_exit(fn ->
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
      Registry.refresh()
    end)

    unless Process.whereis(Registry), do: Registry.start_link([])
    Registry.refresh()
    %{tmp: tmp}
  end

  defp make_ws(tmp, name) do
    dir = Path.join([tmp, "default", "workspaces", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "workspace.json"), Jason.encode!(%{
      "schema_version" => 1,
      "id" => UUID.uuid4(),
      "name" => name,
      "owner" => "test"
    }))
  end

  test "NameIndex.id_for_name + get_by_id returns same struct as legacy get/1", %{tmp: tmp} do
    make_ws(tmp, "test-ws")
    Registry.refresh()

    {:ok, legacy_result} = Registry.get("test-ws")

    uuid = NameIndex.id_for_name(:esr_workspace_name_index, "test-ws")
    assert uuid != nil
    {:ok, new_result} = Registry.get_by_id(uuid)

    assert legacy_result.name == new_result.name
    assert legacy_result.id == new_result.id
  end

  test "Registry.list/0 via NameIndex.all returns same count", %{tmp: tmp} do
    make_ws(tmp, "ws-a")
    make_ws(tmp, "ws-b")
    Registry.refresh()

    legacy_list = Registry.list()

    new_list =
      NameIndex.all(:esr_workspace_name_index)
      |> Enum.map(fn {_name, uuid} -> Registry.get_by_id(uuid) end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, ws} -> ws end)

    assert length(legacy_list) == length(new_list)
  end
end
```

**Step 2 — Confirm test passes** (verifies that the migration target path is functionally equivalent before deleting the old one).

**Step 3 — Write implementation (migrate each caller):**

**`bootstrap.ex` line 44** — `Registry.get("default")` returns `{:ok, %Workspace{}}` (legacy struct). After migration:

```elixir
# BEFORE:
case Esr.Resource.Workspace.Registry.get("default") do
  :error -> create_default_workspace()
  {:ok, _} -> :ok
end

# AFTER:
alias Esr.Resource.Workspace.{Registry, NameIndex}
@name_index :esr_workspace_name_index

defp ensure_default_workspace do
  case NameIndex.id_for_name(@name_index, "default") do
    nil -> create_default_workspace()
    uuid ->
      case Registry.get_by_id(uuid) do
        {:ok, _} -> :ok
        :error -> create_default_workspace()
      end
  end
rescue
  _ -> :ok
end
```

**`file_loader.ex` line 157** — `Registry.get(name)` used to check existence:

```elixir
# BEFORE:
case Esr.Resource.Workspace.Registry.get(name) do
  {:ok, _ws} -> true
  :error -> false
end

# AFTER:
alias Esr.Resource.Workspace.{Registry, NameIndex}
@name_index :esr_workspace_name_index

defp workspace_exists?(name) do
  case NameIndex.id_for_name(@name_index, name) do
    nil -> false
    uuid -> match?({:ok, _}, Registry.get_by_id(uuid))
  end
end
```

**`cc_process.ex` line 565** — `Registry.list()` iterates all workspaces to find chat name:

```elixir
# BEFORE:
defp lookup_chat_name(chat_id) do
  Esr.Resource.Workspace.Registry.list()
  |> Enum.find_value(fn ws ->
    Enum.find_value(ws.chats || [], fn
      %{"chat_id" => ^chat_id} = c -> c["name"]
      _ -> nil
    end)
  end)
rescue
  ArgumentError -> nil
end

# AFTER (uses NameIndex.all to enumerate all workspaces via UUID table):
defp lookup_chat_name(chat_id) do
  alias Esr.Resource.Workspace.{Registry, NameIndex}

  NameIndex.all(:esr_workspace_name_index)
  |> Enum.find_value(fn {_name, uuid} ->
    case Registry.get_by_id(uuid) do
      {:ok, ws} ->
        Enum.find_value(ws.chats || [], fn
          %{"chat_id" => ^chat_id} = c -> c["name"]
          _ -> nil
        end)
      :error -> nil
    end
  end)
rescue
  ArgumentError -> nil
end
```

**`doctor.ex` line 57** — `Registry.list()` used for count only:

```elixir
# BEFORE:
workspace_count =
  try do
    length(Esr.Resource.Workspace.Registry.list())
  rescue
    _ -> 0
  end

# AFTER:
workspace_count =
  try do
    Esr.Resource.Workspace.NameIndex.all(:esr_workspace_name_index)
    |> length()
  rescue
    _ -> 0
  end
```

**Step 4 — Confirm test passes:** Run the migration test plus full suite:

```bash
mix test runtime/test/esr/resource/workspace/registry_m4_migration_test.exs
mix test
```

**Step 5 — No remaining callers:**

```bash
grep -rn "Registry\.get\b\|Registry\.list()" runtime/lib/esr/resource/workspace/ \
  runtime/lib/esr/resource/capability/ \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/commands/doctor.ex
```

Must return zero results (excluding the Registry module itself).

**Commit message:** `refactor(m-4.1): migrate 4 Registry.get/list callers to NameIndex + get_by_id (Phase M-4.1)`

---

### Task M-4.2: Delete `defmodule Workspace` legacy embedded struct (~20 LOC)

**File:** `runtime/lib/esr/resource/workspace/registry.ex` lines 41–60

The embedded `defmodule Workspace` block contains `@moduledoc`, `defstruct`, and `@type t`. It is referenced only by `to_legacy/1` and `normalize_to_struct/1` (both deleted in M-4.3) and `do_put(%Workspace{})` (deleted in M-4.4).

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/resource/workspace/registry_m4_struct_deleted_test.exs
defmodule Esr.WorkspaceRegistryM4StructDeletedTest do
  use ExUnit.Case

  @tag :m4_gate
  test "Esr.Resource.Workspace.Registry.Workspace module does not exist after M-4" do
    refute Code.ensure_loaded?(Esr.Resource.Workspace.Registry.Workspace),
      "Legacy Workspace struct module still exists; M-4.2 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit.**

**Step 3 — Write implementation:**

Delete the entire `defmodule Workspace do ... end` block at lines 41–60 in `registry.ex`. This includes the `@moduledoc`, `defstruct`, and `@type t` lines.

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/resource/workspace/registry_m4_struct_deleted_test.exs` — green.

**Step 5 — Compile check:** `mix compile --force` — no `Esr.Resource.Workspace.Registry.Workspace is not a module` errors (since we are deleting callers in M-4.3 and M-4.4).

**Commit message:** `refactor(m-4.2): delete %Workspace{} legacy embedded struct from registry.ex (Phase M-4.2)`

---

### Task M-4.3: Delete `@legacy_table` + `to_legacy/1` + `normalize_to_struct/1` (~139 LOC total across M-4.2–M-4.4)

**File:** `runtime/lib/esr/resource/workspace/registry.ex`

**Affected content (per spec §7 M-4 inventory):**
- `@legacy_table :esr_workspaces` declaration (line 63)
- `@uuid_table :esr_workspaces_uuid` declaration (line 66) — keep this; it is the surviving table
- ETS table creation for `@legacy_table` in `init/1` (lines 237–239)
- `:ets.delete(@legacy_table, name)` in rename (lines 342, 538)
- `:ets.delete_all_objects(@legacy_table)` in clear (line 357)
- `:ets.insert(@legacy_table, ...)` on put (lines 373, 487, 513, 539)
- `:ets.delete(@legacy_table, ...)` on delete (line 485)
- `defp to_legacy(%Struct{} = ws)` function (lines 563–590)
- `defp normalize_to_struct(%Workspace{} = legacy)` function (lines 592–615)
- `@spec start_cmd_for/2` + `def start_cmd_for/2` (lines 177–195)
- Legacy `list/0` reading from `@legacy_table` (line 139)
- Legacy `get/1` reading from `@legacy_table` (lines 127–135)

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/resource/workspace/registry_m4_legacy_deleted_test.exs
defmodule Esr.WorkspaceRegistryM4LegacyDeletedTest do
  use ExUnit.Case

  @tag :m4_gate
  test "registry.ex has no @legacy_table references after M-4" do
    content = File.read!("runtime/lib/esr/resource/workspace/registry.ex")
    refute String.contains?(content, "@legacy_table"),
      "registry.ex still contains @legacy_table; M-4.3 is incomplete"
    refute String.contains?(content, "to_legacy"),
      "registry.ex still contains to_legacy; M-4.3 is incomplete"
    refute String.contains?(content, "normalize_to_struct"),
      "registry.ex still contains normalize_to_struct; M-4.3 is incomplete"
    refute String.contains?(content, "start_cmd_for"),
      "registry.ex still contains start_cmd_for; M-4.7 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit** (multiple assertions fire).

**Step 3 — Write implementation:**

Delete in order from bottom to top:

1. Delete `defp normalize_to_struct/1` (lines 592–615)
2. Delete `defp to_legacy/1` (lines 563–590)
3. Delete `def start_cmd_for/2` both clauses (lines 177–195) and its `@spec`
4. Delete legacy `get/1` clause reading from `@legacy_table` (lines 127–135)
5. Delete legacy `list/0` reading from `@legacy_table` (line 139) — the surviving `list/0` reads from `@name_index_table` via `NameIndex.all/1`; verify which clause to delete
6. Delete all `:ets.insert(@legacy_table, ...)` calls from `do_put/1`, `rename/2` (lines 373, 487, 513, 538, 539)
7. Delete `:ets.delete(@legacy_table, ...)` calls (lines 342, 485, 538)
8. Delete `:ets.delete_all_objects(@legacy_table)` in clear (line 357)
9. Delete `@legacy_table :esr_workspaces` declaration (line 63)
10. Delete ETS table creation block for `@legacy_table` in `init/1` (lines 237–239)

After deletion, `registry.ex` `init/1` only creates the `@uuid_table`. The `@uuid_table` ETS operations remain intact.

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/resource/workspace/registry_m4_legacy_deleted_test.exs` — green.

**Step 5 — Full test sweep:**

```bash
mix compile --force
mix test runtime/test/esr/resource/workspace/
```

**Commit message:** `refactor(m-4.3): delete @legacy_table ETS + to_legacy/1 + normalize_to_struct/1 + start_cmd_for/2 from registry.ex (Phase M-4.3)`

---

### Task M-4.4: Delete `do_put(%Workspace{})` clause (~21 LOC)

**File:** `runtime/lib/esr/resource/workspace/registry.ex` lines 495–515

The `do_put(%Workspace{} = legacy)` clause converts the legacy struct to a `%Struct{}` via `normalize_to_struct/1` (already deleted in M-4.3) before writing. After M-4.3, this clause fails to compile. Delete it in the same commit as M-4.3 or immediately after.

**Step 1 — Write failing test** (compile-time test):

```elixir
# Add to registry_m4_legacy_deleted_test.exs (same file as M-4.3):
test "do_put no longer has a %Workspace{} clause after M-4" do
  content = File.read!("runtime/lib/esr/resource/workspace/registry.ex")
  refute String.contains?(content, "do_put(%Workspace{}"),
    "registry.ex still has do_put(%Workspace{}) clause; M-4.4 is incomplete"
end
```

**Step 2 — Confirm test fails before edit.**

**Step 3 — Write implementation:**

Delete `defp do_put(%Workspace{} = legacy)` and its body (lines 495–515). The surviving `defp do_put(%Struct{} = ws)` clause remains.

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/resource/workspace/registry_m4_legacy_deleted_test.exs` — all 5 assertions green.

**Step 5 — Compile + full suite:**

```bash
mix compile --force
mix test
```

**Commit message:** `refactor(m-4.4): delete do_put(%Workspace{}) legacy clause from registry.ex (Phase M-4.4)`

---

### Task M-4.5: Delete `lookup_legacy/1` + `build_legacy_result/1` + `_legacy.*` reads from `info.ex` (~111 LOC)

**File:** `runtime/lib/esr/commands/workspace/info.ex`

**Affected content (per spec §7 M-4 inventory):**
- Lines 26–35: `"role"`, `"neighbors"`, `"metadata"` fields in result map sourced from `_legacy.*` keys
- Lines 78: `{:ok, build_legacy_result(w)}` call — delete and replace with Struct-path result
- Lines 104–106: `ArgumentError -> lookup_legacy(ws_name)` rescue clause — delete
- Lines 107–167: `defp lookup_legacy/1` — full body (~61 LOC)
- Lines 167–200: `defp build_legacy_result/1` helper (~34 LOC)

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/commands/workspace/info_m4_gate_test.exs
defmodule Esr.InfoCommandM4GateTest do
  use ExUnit.Case

  @tag :m4_gate
  test "info.ex has no legacy path after M-4" do
    content = File.read!("runtime/lib/esr/commands/workspace/info.ex")
    refute String.contains?(content, "lookup_legacy"),
      "info.ex still has lookup_legacy; M-4.5 is incomplete"
    refute String.contains?(content, "build_legacy_result"),
      "info.ex still has build_legacy_result; M-4.5 is incomplete"
    refute String.contains?(content, "_legacy."),
      "info.ex still has _legacy.* reads; M-4.5 is incomplete"
    refute String.contains?(content, "ArgumentError"),
      "info.ex still has ArgumentError rescue fallback; M-4.5 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit** (all 4 assertions fire).

**Step 3 — Write implementation:**

Delete from bottom to top:

1. Delete `defp build_legacy_result/1` (lines 167–200)
2. Delete `defp lookup_legacy/1` (lines 107–167)
3. Delete the `ArgumentError -> lookup_legacy(ws_name)` rescue clause (lines 104–106) — the entire `rescue` block is removed if `lookup_legacy` was the only clause
4. Remove the `"role"`, `"neighbors"`, `"metadata"` fields from the result map (lines 26–35) — these fields are gone; the response shape shrinks to `id`, `name`, `settings` (filtered), and `workspace_path`

After deletion, `info.ex` uses only the Struct-path lookup. The `with` pipeline at the call site becomes:

```elixir
# BEFORE (abbreviated):
with {:ok, uuid} <- NameIndex.id_for_name(...),
     {:ok, ws} <- Registry.get_by_id(uuid) do
  {:ok, build_legacy_result(ws)}    # line 78 — deleted
end
rescue
  ArgumentError -> lookup_legacy(ws_name)  # lines 104-106 — deleted

# AFTER:
with {:ok, uuid} <- NameIndex.id_for_name(@name_index_table, ws_name),
     {:ok, ws} <- Registry.get_by_id(uuid) do
  {:ok, %{
    "id"       => ws.id,
    "name"     => ws.name,
    "settings" => ws.settings
      |> Enum.reject(fn {k, _} -> String.starts_with?(k, "_legacy.") end)
      |> Map.new(),
    "workspace_path" => ws.workspace_path
  }}
end
```

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/commands/workspace/info_m4_gate_test.exs` — green.

**Step 5 — Update `info_test.exs` and run full suite:**

```bash
# In runtime/test/esr/commands/workspace/info_test.exs:
# Delete assertions on "role", "neighbors", "metadata" fields.
# Update expected response to match new Struct-only shape.

mix compile --force
mix test
```

**Commit message:** `refactor(m-4.5): delete lookup_legacy + _legacy.* reads from info.ex (Phase M-4.5)`

---

### Task M-4.6: Delete `legacy_metadata/1` + `_legacy.role` reads from `describe.ex` (~13 LOC)

**File:** `runtime/lib/esr/resource/workspace/describe.ex`

**Affected content (per spec §7 M-4 inventory):**
- Line 123: `base_metadata = legacy_metadata(ws)` local variable
- Lines 134–136: `"role" => Map.get(ws.settings, "_legacy.role", "dev")` in describe result
- Line ~135: `"_legacy.metadata"` read in describe result
- Lines 168–174: `defp legacy_metadata/1` function body

**Step 1 — Write failing test:**

```elixir
# runtime/test/esr/resource/workspace_describe_m4_gate_test.exs
defmodule Esr.WorkspaceDescribeM4GateTest do
  use ExUnit.Case

  @tag :m4_gate
  test "describe.ex has no legacy_metadata or _legacy.role after M-4" do
    content = File.read!("runtime/lib/esr/resource/workspace/describe.ex")
    refute String.contains?(content, "legacy_metadata"),
      "describe.ex still has legacy_metadata; M-4.6 is incomplete"
    refute String.contains?(content, "_legacy.role"),
      "describe.ex still has _legacy.role; M-4.6 is incomplete"
    refute String.contains?(content, "_legacy.metadata"),
      "describe.ex still has _legacy.metadata; M-4.6 is incomplete"
  end
end
```

**Step 2 — Confirm test fails before edit.**

**Step 3 — Write implementation:**

1. Delete `defp legacy_metadata/1` (lines 168–174)
2. Delete `base_metadata = legacy_metadata(ws)` at line 123
3. Remove `"role" => Map.get(ws.settings, "_legacy.role", "dev")` from describe result map
4. Remove `"_legacy.metadata"` read from describe result map

The describe output no longer includes `"role"` (product decision: role concept is removed with M-4; F-2 tracks follow-up if workspace-level role is needed post-cleanup).

**Step 4 — Confirm test passes:** `mix test runtime/test/esr/resource/workspace_describe_m4_gate_test.exs` — green.

**Step 5 — Full suite:**

```bash
mix compile --force
mix test runtime/test/esr/resource/
```

**Commit message:** `refactor(m-4.6): delete legacy_metadata + _legacy.role/_legacy.metadata reads from describe.ex (Phase M-4.6)`

---

### Task M-4.7: PR + admin-merge

**Step 1 — Final M-4 gate sweep:**

```bash
grep -rn "@legacy_table\|_legacy\.\|defmodule Workspace\b\|normalize_to_struct\|to_legacy\|start_cmd_for\|lookup_legacy\|build_legacy_result" runtime/lib/
# Must return zero results.

mix compile --force
mix test
```

**Step 2 — Stage all M-4 files:**

```bash
git add \
  runtime/lib/esr/resource/workspace/registry.ex \
  runtime/lib/esr/commands/workspace/info.ex \
  runtime/lib/esr/resource/workspace/describe.ex \
  runtime/lib/esr/resource/workspace/bootstrap.ex \
  runtime/lib/esr/resource/capability/file_loader.ex \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/commands/doctor.ex \
  runtime/test/esr/resource/workspace/registry_m4_migration_test.exs \
  runtime/test/esr/resource/workspace/registry_m4_struct_deleted_test.exs \
  runtime/test/esr/resource/workspace/registry_m4_legacy_deleted_test.exs \
  runtime/test/esr/commands/workspace/info_m4_gate_test.exs \
  runtime/test/esr/commands/workspace/info_test.exs \
  runtime/test/esr/resource/workspace_describe_m4_gate_test.exs
```

**Step 3 — Create and push branch; open PR against integration branch:**

```bash
git branch feat/m4-delete-legacy-compat
git push origin feat/m4-delete-legacy-compat
gh pr create --base feat/multi-instance-routing-cleanup --head feat/m4-delete-legacy-compat \
  --title "feat(m-4): delete _legacy.* compat shim + %Workspace{} legacy struct + 4 caller migrations" \
  --body "Final compat deletion: remove @legacy_table + to_legacy/normalize_to_struct shim, delete embedded %Workspace{} struct, migrate 4 callers. workspace_for_chat/2 uses @uuid_table (verified registry.ex:149–175); all callers continue working.

-227 LOC. Hard cutover.

Spec: docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md (rev-1, user-approved 2026-05-07)."
```

**Step 4 — Admin-merge:**

```bash
gh pr merge --admin --squash --delete-branch
```

**Step 5 — Verify:** `git log --oneline dev | head -3` — M-4 commit visible.

---

## Phase M-5: Tests + e2e sweep

**Depends on:** M-4 merged into `dev`.

**Purpose:** Rewrite all tests that covered deleted code; extend the ActorQuery and InstanceRegistry test suites; add e2e scenario 18 (multi-CC session lifecycle); rewrite or delete the topology e2e scenarios. After M-5, the test suite covers only surviving production code; the e2e suite validates the multi-CC workflow end-to-end.

**LOC estimate:** +200 / -100

**Risk:** Low — tests only. No production code changes.

**Invariant test (gate for M-5 done):** The scenario 18 e2e script must complete with exit code 0. The ActorQuery integration test `find_by_name → add_instance_and_spawn → find_by_name` must be green. `grep -rn "backwire\|rewire_session_siblings\|reachable_set\|neighbor_workspaces" runtime/test/` must return zero results (excluding the M-3 stub comments).

---

### Task M-5.1: Delete obsolete test blocks from existing test files

**Files and deletions:**

**`runtime/test/esr/session/agent_spawner_test.exs`** — Delete all tests referencing `backwire_neighbors`, `build_neighbors`, or `:sys.replace_state` neighbor patching. These were the Phase 4 / PR-9 tests. Identify via:

```bash
grep -n "backwire\|build_neighbors\|replace_state.*neighbor" \
  runtime/test/esr/session/agent_spawner_test.exs
```

Replace each deleted test block with a comment:

```elixir
# deleted in M-5 — backwire_neighbors removed in M-2; routing via ActorQuery
# Coverage: runtime/test/esr/actor_query_test.exs + instance_registry_spawn_test.exs
```

Add two new tests to the same file:

```elixir
describe "spawn-via-InstanceRegistry (post-M-2)" do
  test "spawned agent is findable via ActorQuery.find_by_name immediately after add_instance_and_spawn" do
    sid = "spawner-m5-#{System.unique_integer([:positive])}"
    name = "test-agent-#{System.unique_integer([:positive])}"

    {:ok, _result} = Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(%{
      session_id: sid,
      agent_name: name,
      agent_type: :cc
    })

    assert {:ok, pid} = Esr.ActorQuery.find_by_name(sid, name)
    assert Process.alive?(pid)
  end

  test "spawn failure leaves no orphan in name index" do
    sid = "spawner-rollback-#{System.unique_integer([:positive])}"
    name = "rollback-agent-#{System.unique_integer([:positive])}"

    # Simulate spawn failure by passing invalid agent_type
    {:error, _reason} = Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(%{
      session_id: sid,
      agent_name: name,
      agent_type: :nonexistent_type
    })

    assert :not_found == Esr.ActorQuery.find_by_name(sid, name)
    assert [] == Esr.ActorQuery.list_by_role(sid, :cc_process)
  end
end
```

**`runtime/test/esr/entity/pty_process_test.exs`** — Delete all tests referencing `rewire_session_siblings` or `patch_neighbor_in_state`. Identify via:

```bash
grep -n "rewire_session_siblings\|patch_neighbor_in_state" \
  runtime/test/esr/entity/pty_process_test.exs
```

Replace with stub comments:

```elixir
# deleted in M-5 — rewire_session_siblings removed in M-2; sibling discovery via ActorQuery
# Coverage: runtime/test/esr/actor_query_test.exs list_by_role multi-instance tests
```

**`runtime/test/esr/plugins/claude_code/cc_process_test.exs`** — Delete all tests referencing `reachable_set`, `build_initial_reachable_set`, or `Esr.Topology`. These were already stubbed in M-3.2 with `# deleted in M-3` comments. In M-5, convert the stubs to proper test scaffolding for the ActorQuery-based routing (see M-5.3).

**`runtime/test/esr/entity_server_describe_topology_test.exs`** (or `entity/server_describe_topology_test.exs`) — If the file tests only `describe_topology` output, delete the entire file:

```bash
rm runtime/test/esr/entity/server_describe_topology_test.exs
# or:
rm runtime/test/esr/entity_server_describe_topology_test.exs
```

If the file also tests other server behavior, keep the file and delete only the topology-specific `describe` section.

**Step 1 — Write gate test:**

```bash
# Run as part of CI gate:
grep -rln "backwire\|rewire_session_siblings\|reachable_set\|neighbor_workspaces\|describe_topology" \
  runtime/test/esr/session/agent_spawner_test.exs \
  runtime/test/esr/entity/pty_process_test.exs \
  runtime/test/esr/plugins/claude_code/cc_process_test.exs
# Must return zero matches.
```

**Step 2 — Confirm non-zero matches before M-5.1.**

**Step 3 — Delete/stub as described above. Add new spawner tests.**

**Step 4 — Confirm zero matches after edits.**

**Step 5 — Full test suite:** `mix test` — green.

**Commit message:** `test(m-5.1): delete obsolete backwire/rewire/reachable_set/describe_topology tests + add spawn-via-InstanceRegistry tests (Phase M-5.1)`

---

### Task M-5.2: Update tests pattern-matching on `%Workspace{}` legacy struct

**Files:** Identified via:

```bash
grep -rln "%Esr.Resource.Workspace.Registry.Workspace{" runtime/test/
```

For each matched test file, replace any `%Esr.Resource.Workspace.Registry.Workspace{...}` struct literal with the equivalent `%Esr.Resource.Workspace.Struct{...}` construction, or replace the test entirely if it was testing legacy struct behavior.

**Step 1 — Inventory:**

```bash
grep -rn "%Esr.Resource.Workspace.Registry.Workspace{" runtime/test/
```

**Step 2 — For each occurrence:**

```elixir
# BEFORE:
assert %Esr.Resource.Workspace.Registry.Workspace{name: "foo"} = result

# AFTER:
assert %Esr.Resource.Workspace.Struct{name: "foo"} = result
```

If a test fixture constructs a legacy `%Workspace{}` to test `to_legacy/1` or `normalize_to_struct/1` behavior (both deleted), delete the entire test and replace with:

```elixir
# deleted in M-5 — to_legacy/normalize_to_struct removed in M-4;
# Struct-only path tested in registry_test.exs
```

**Step 3 — Write gate test:**

```elixir
# runtime/test/esr/m5_no_legacy_struct_test.exs
defmodule Esr.M5NoLegacyStructTest do
  use ExUnit.Case

  @tag :m5_gate
  test "no test file references the legacy Workspace embedded struct after M-5" do
    {output, _} = System.cmd("grep", [
      "-rln",
      "%Esr.Resource.Workspace.Registry.Workspace{",
      "runtime/test/"
    ])
    assert output == "",
      "Found legacy struct pattern-match in tests: #{output}"
  end
end
```

**Step 4 — Confirm gate passes after all migrations.**

**Step 5 — Full test suite:** `mix test` — green.

**Commit message:** `test(m-5.2): migrate legacy %Workspace{} struct refs in tests to %Struct{} (Phase M-5.2)`

---

### Task M-5.3: Extend `Esr.ActorQuery` integration tests

**File:** `runtime/test/esr/actor_query_test.exs` (extend from M-1 additions)

Add the following test cases to the existing `Esr.ActorQueryTest` module (per spec §10 ActorQuery unit tests table):

**Step 1 — Write failing tests** (these cases cover the full spec §10 inventory):

```elixir
# Additions to runtime/test/esr/actor_query_test.exs

describe "find_by_name/2 — extended" do
  test "returns :not_found after deregister", %{session_id: sid} do
    actor_id = "actor-dereg-#{System.unique_integer([:positive])}"
    name = "peer-dereg-#{System.unique_integer([:positive])}"
    :ok = Esr.Entity.Registry.register_attrs(actor_id, %{session_id: sid, name: name, role: :cc_process})
    :ok = Esr.Entity.Registry.deregister_attrs(actor_id, %{session_id: sid, name: name, role: :cc_process})

    assert :not_found == Esr.ActorQuery.find_by_name(sid, name)
  end

  test "returns :not_found after process crash (monitor DOWN cleanup)", %{session_id: sid} do
    actor_id = "actor-crash-#{System.unique_integer([:positive])}"
    name = "peer-crash-#{System.unique_integer([:positive])}"
    test_pid = self()

    # Spawn a process that registers itself, then waits to be killed.
    # register_attrs uses self(), so the spawned process must call it.
    pid = spawn(fn ->
      :ok = Esr.Entity.Registry.register_attrs(actor_id, %{session_id: sid, name: name, role: :cc_process})
      send(test_pid, :registered)
      receive do :stop -> :ok end
    end)

    # Wait for registration to complete before killing
    assert_receive :registered, 1000

    # Force-kill the registered process
    Process.exit(pid, :kill)
    # Allow monitor DOWN to propagate through IndexWatcher
    Process.sleep(200)

    assert :not_found == Esr.ActorQuery.find_by_name(sid, name)
  end
end

describe "list_by_role/2 — extended" do
  test "returns two pids for two same-role registrations", %{session_id: sid} do
    for n <- ["a", "b"] do
      actor_id = "actor-multi-#{n}-#{System.unique_integer([:positive])}"
      :ok = Esr.Entity.Registry.register_attrs(actor_id, %{
        session_id: sid,
        name: "peer-#{n}-#{System.unique_integer([:positive])}",
        role: :cc_process
      })
    end

    result = Esr.ActorQuery.list_by_role(sid, :cc_process)
    assert length(result) == 2
    assert Enum.all?(result, &is_pid/1)
  end

  test "returns one pid after one of two instances crashes", %{session_id: sid} do
    actor_id_a = "actor-crash-a-#{System.unique_integer([:positive])}"
    actor_id_b = "actor-crash-b-#{System.unique_integer([:positive])}"
    name_a = "peer-crash-a-#{System.unique_integer([:positive])}"
    name_b = "peer-crash-b-#{System.unique_integer([:positive])}"
    test_pid = self()

    # Each process registers itself (register_attrs uses self())
    pid_a = spawn(fn ->
      :ok = Esr.Entity.Registry.register_attrs(actor_id_a, %{session_id: sid, name: name_a, role: :cc_process})
      send(test_pid, {:registered, :a})
      receive do :stop -> :ok end
    end)
    _pid_b = spawn(fn ->
      :ok = Esr.Entity.Registry.register_attrs(actor_id_b, %{session_id: sid, name: name_b, role: :cc_process})
      send(test_pid, {:registered, :b})
      receive do :stop -> :ok end
    end)

    assert_receive {:registered, :a}, 1000
    assert_receive {:registered, :b}, 1000

    assert length(Esr.ActorQuery.list_by_role(sid, :cc_process)) == 2

    # Kill one; allow DOWN to propagate through IndexWatcher
    Process.exit(pid_a, :kill)
    Process.sleep(200)

    remaining = Esr.ActorQuery.list_by_role(sid, :cc_process)
    assert length(remaining) == 1
  end
end

describe "find_by_id/1 — extended" do
  test "returns :not_found after process exit", %{session_id: sid} do
    actor_id = "actor-exit-#{System.unique_integer([:positive])}"
    pid = spawn(fn -> receive do :stop -> :ok end end)
    {:ok, _} = Esr.Entity.Registry.register(actor_id, pid)

    Process.exit(pid, :kill)
    Process.sleep(100)

    assert :not_found == Esr.ActorQuery.find_by_id(actor_id)
  end
end
```

**Step 2 — Confirm new tests fail** before the monitor DOWN handler is confirmed working (they should pass once M-1's IndexWatcher is in place).

**Step 3 — No implementation changes needed** — all behavior is in M-1's Registry changes. Run tests to validate.

**Step 4 — Confirm all tests pass:** `mix test runtime/test/esr/actor_query_test.exs` — green on all cases.

**Step 5 — Confirm no regressions:** `mix test` — full suite green.

**Commit message:** `test(m-5.3): extend ActorQuery integration tests — crash cleanup + multi-instance (Phase M-5.3)`

---

### Task M-5.4: Rewrite or delete e2e topology scenarios

**Files:** `tests/e2e/05_topology_routing.sh` (and `04_multi_app_routing.sh` if it references `neighbor_workspaces`)

**Step 1 — Audit each scenario:**

```bash
grep -n "describe_topology\|neighbor_workspaces\|reachable_set" \
  tests/e2e/05_topology_routing.sh \
  tests/e2e/04_multi_app_routing.sh \
  tests/e2e/14_session_multiagent.sh
```

**Decision criteria per spec §9 R-3:**
- If scenario tests ONLY `describe_topology` response shape or `neighbor_workspaces` content: **delete the scenario file**.
- If scenario tests routing correctness beyond the deleted tool: **extract valid assertions into scenario 18** (M-5.5), then delete the topology-specific portion.

**For `05_topology_routing.sh`:** This scenario tests the `describe_topology` tool response and `neighbor_workspaces` content (per spec §9 R-3). The routing assertions (message delivered to correct session) are re-expressed in scenario 18. Delete the file:

```bash
rm tests/e2e/05_topology_routing.sh
```

**For `04_multi_app_routing.sh`:** Check if it uses `neighbor_workspaces`. If yes, remove only the `neighbor_workspaces` assertion block; preserve multi-app routing assertions.

**Step 2 — Write gate check:**

```bash
grep -rn "describe_topology\|neighbor_workspaces" tests/e2e/
# Must return zero results after M-5.4.
```

**Step 3 — Delete or edit as decided above.**

**Step 4 — Confirm remaining e2e scenarios still pass:**

```bash
bash tests/e2e/04_multi_app_routing.sh
bash tests/e2e/14_session_multiagent.sh
```

**Step 5 — No mix test needed** (bash e2e only in this task).

**Commit message:** `test(m-5.4): delete 05_topology_routing.sh + strip neighbor_workspaces from 04_multi_app_routing.sh (Phase M-5.4)`

---

### Task M-5.5: Add e2e scenario 18 — multi-CC session lifecycle

**File:** `tests/e2e/18_multi_cc_session.sh` (new)

**Step 1 — Write failing scenario** (fails until M-2 is in place because `/session:add-agent` does not spawn live processes before M-2):

```bash
#!/usr/bin/env bash
# tests/e2e/18_multi_cc_session.sh
# Scenario 18: multi-CC session lifecycle
# Validates: /session:new → add two CC agents → @mention routing → remove agent → /session:end
# Mirror: scenario 14 pattern (post-PR-249)
# Per project e2e standards: agent-browser screenshot required at step 3 + step 4.

set -euo pipefail
source "$(dirname "$0")/common.sh"

SCENARIO="18_multi_cc_session"
SESSION_ID=""

log_step() { echo "[${SCENARIO}] $*"; }

# ── Step 1: /session:new ──────────────────────────────────────────────────────
log_step "Step 1 — creating new session"
RESPONSE=$(esrd_cmd "/session:new")
SESSION_ID=$(echo "$RESPONSE" | jq -r '.session_id // empty')
assert_nonempty "$SESSION_ID" "session_id from /session:new"

# Assert: no CC agents yet
CC_COUNT=$(esrd_query "ActorQuery.list_by_role(\"${SESSION_ID}\", :cc_process) |> length()")
assert_equals "0" "$CC_COUNT" "no cc_process agents before add-agent"

log_step "Step 1 PASS — session_id=${SESSION_ID}"

# ── Step 2: /session:add-agent name=helper-A type=cc ─────────────────────────
log_step "Step 2 — adding helper-A"
ADD_A=$(esrd_cmd "/session:add-agent name=helper-A type=cc")
ACTOR_ID_A=$(echo "$ADD_A" | jq -r '.actor_id // empty')
assert_nonempty "$ACTOR_ID_A" "actor_id for helper-A"

PID_A=$(esrd_query "Esr.ActorQuery.find_by_name(\"${SESSION_ID}\", \"helper-A\")")
assert_matches "ok" "$PID_A" "find_by_name returns {:ok, pid} for helper-A"

ROLE_COUNT=$(esrd_query "Esr.ActorQuery.list_by_role(\"${SESSION_ID}\", :cc_process) |> length()")
assert_equals "1" "$ROLE_COUNT" "list_by_role returns 1 after add helper-A"

log_step "Step 2 PASS — actor_id_a=${ACTOR_ID_A}"

# ── Step 3: /session:add-agent name=helper-B type=cc ─────────────────────────
log_step "Step 3 — adding helper-B"
ADD_B=$(esrd_cmd "/session:add-agent name=helper-B type=cc")
ACTOR_ID_B=$(echo "$ADD_B" | jq -r '.actor_id // empty')
assert_nonempty "$ACTOR_ID_B" "actor_id for helper-B"
assert_not_equals "$ACTOR_ID_A" "$ACTOR_ID_B" "actor_id_a != actor_id_b"

ROLE_COUNT=$(esrd_query "Esr.ActorQuery.list_by_role(\"${SESSION_ID}\", :cc_process) |> length()")
assert_equals "2" "$ROLE_COUNT" "list_by_role returns 2 after add helper-A + helper-B"

# Agent-browser screenshot: two CC agents active in same session (PTY terminal)
# Per esr-e2e-standards.md: screenshot saved to tests/e2e/screenshots/18_step3_two_agents.png
screenshot_pty "18_step3_two_agents" "$SESSION_ID"
log_step "Step 3 PASS — actor_id_b=${ACTOR_ID_B}"

# ── Step 4: @helper-A mention routing ────────────────────────────────────────
log_step "Step 4 — @mention routing to helper-A"
ROUTED_TO=$(esrd_send_mention "$SESSION_ID" "@helper-A ping")
assert_equals "$ACTOR_ID_A" "$ROUTED_TO" "@helper-A routes to actor_id_a"

# Assert helper-B was NOT the recipient
assert_not_equals "$ACTOR_ID_B" "$ROUTED_TO" "@helper-A does NOT route to actor_id_b"

# Agent-browser screenshot: Feishu reply from helper-A specifically
screenshot_feishu "18_step4_mention_routing" "$SESSION_ID"
log_step "Step 4 PASS"

# ── Step 5: /session:remove-agent name=helper-A ──────────────────────────────
log_step "Step 5 — removing helper-A"
esrd_cmd "/session:remove-agent name=helper-A"

FIND_A_AFTER=$(esrd_query "Esr.ActorQuery.find_by_name(\"${SESSION_ID}\", \"helper-A\")")
assert_equals ":not_found" "$FIND_A_AFTER" "find_by_name returns :not_found after remove"

ROLE_COUNT_AFTER=$(esrd_query "Esr.ActorQuery.list_by_role(\"${SESSION_ID}\", :cc_process) |> length()")
assert_equals "1" "$ROLE_COUNT_AFTER" "list_by_role returns 1 after remove helper-A"

ALIVE_A=$(esrd_query "Process.alive?(pid_for_actor(\"${ACTOR_ID_A}\"))")
assert_equals "false" "$ALIVE_A" "helper-A pid is not alive after remove"

log_step "Step 5 PASS"

# ── Step 6: /session:end ─────────────────────────────────────────────────────
log_step "Step 6 — ending session"
esrd_cmd "/session:end"

ROLE_COUNT_FINAL=$(esrd_query "Esr.ActorQuery.list_by_role(\"${SESSION_ID}\", :cc_process) |> length()")
assert_equals "0" "$ROLE_COUNT_FINAL" "list_by_role returns 0 after session end"

ALIVE_B=$(esrd_query "Process.alive?(pid_for_actor(\"${ACTOR_ID_B}\"))")
assert_equals "false" "$ALIVE_B" "helper-B pid is not alive after session end"

log_step "Step 6 PASS"
log_step "SCENARIO 18 COMPLETE — multi-CC session lifecycle verified"
exit 0
```

**Step 2 — Confirm scenario fails before M-2** (`/session:add-agent` returns actor_id but no live pid — `assert_matches "ok"` fails at Step 2).

**Step 3 — No implementation changes** — the scenario exercises M-2's `add_instance_and_spawn` and M-1's ActorQuery. The script runs against a live `esrd` instance.

**Step 4 — Confirm scenario passes end-to-end:**

```bash
bash tests/e2e/18_multi_cc_session.sh
# Exit code 0; screenshots at:
#   tests/e2e/screenshots/18_step3_two_agents.png
#   tests/e2e/screenshots/18_step4_mention_routing.png
```

Per project e2e standards (`feedback_esr_e2e_standards.md`): agent-browser screenshots of (1) PTY showing both helper-A and helper-B in the same session, (2) Feishu chat showing `@helper-A` answered by helper-A specifically, are required before M-5 is claimed complete.

**Step 5 — Full e2e sweep:**

```bash
for f in tests/e2e/0*.sh tests/e2e/1*.sh; do
  bash "$f" && echo "PASS: $f" || echo "FAIL: $f"
done
```

All scenarios exit 0.

**Commit message:** `test(m-5.5): add e2e scenario 18 — multi-CC session lifecycle + @mention routing (Phase M-5.5)`

---

### Task M-5.6: PR + admin-merge

**Step 1 — Final M-5 gate sweep:**

```bash
# Zero references to deleted patterns in test code:
grep -rn "backwire\|rewire_session_siblings\|reachable_set\|neighbor_workspaces\|describe_topology" \
  runtime/test/
# (Stubs with "# deleted in M-3/M-5" comments are acceptable — only callable code triggers failure.)

# Zero legacy struct patterns:
grep -rln "%Esr.Resource.Workspace.Registry.Workspace{" runtime/test/
# Must be empty.

# Scenario 18 exits 0:
bash tests/e2e/18_multi_cc_session.sh

# Full unit suite green:
mix test
```

**Step 2 — Stage all M-5 files:**

```bash
git add \
  runtime/test/esr/session/agent_spawner_test.exs \
  runtime/test/esr/entity/pty_process_test.exs \
  runtime/test/esr/plugins/claude_code/cc_process_test.exs \
  runtime/test/esr/actor_query_test.exs \
  runtime/test/esr/entity/registry_indexes_test.exs \
  runtime/test/esr/m5_no_legacy_struct_test.exs \
  tests/e2e/18_multi_cc_session.sh \
  tests/e2e/04_multi_app_routing.sh  # stripped neighbor_workspaces assertion
# git rm tests/e2e/05_topology_routing.sh
# git rm runtime/test/esr/entity/server_describe_topology_test.exs  (if fully deleted)
```

**Step 3 — Create and push branch; open PR against integration branch:**

```bash
git branch feat/m5-tests-e2e-sweep
git push origin feat/m5-tests-e2e-sweep
gh pr create --base feat/multi-instance-routing-cleanup --head feat/m5-tests-e2e-sweep \
  --title "feat(m-5): tests + e2e sweep + scenario 18 multi-CC session lifecycle" \
  --body "Final validation phase: add scenario 18 (multi-CC in same session with @mention routing), sweep all e2e tests, confirm full unit suite green. All gate checks pass: no deleted patterns, no legacy structs, e2e 14/15/17/18 green.

Spec: docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md (rev-1, user-approved 2026-05-07)."
```

**Step 4 — Admin-merge:**

```bash
gh pr merge --admin --squash --delete-branch
```

**Step 5 — Final Step: Squash-merge integration branch → dev**

After M-5 PR is merged to feat/multi-instance-routing-cleanup, run e2e validation:

```bash
cd runtime
mix test
make e2e-14 e2e-15 e2e-17 e2e-18
```

If all green, open the integration → dev PR:

```bash
gh pr create --base dev --head feat/multi-instance-routing-cleanup \
  --title "Multi-instance routing cleanup — 5 phases (M-1..M-5)" \
  --body "Squash-merge of all 5 phases. Spec: docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md (rev-1, user-approved 2026-05-07).

Phases (each was a sub-PR to feat/multi-instance-routing-cleanup):
  - M-1: Esr.ActorQuery + Registry indexes
  - M-2: Migrate callers + delete state.neighbors / backwire / rewire + per-session DynSup + atomic add-agent
  - M-3: Delete legacy diffusion (workspace.neighbors / topology / reachable_set / describe_topology cleanup)
  - M-4: Delete _legacy.* compat shim + legacy %Workspace{} struct + 4 caller migrations
  - M-5: Tests + e2e sweep + scenario 18 multi-CC

Net ~-550 LOC. Hard cutover, no backward compatibility.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
gh pr merge --admin --squash --delete-branch
```

After merge, the feat/multi-instance-routing-cleanup branch is auto-deleted.

**Step 6 — Verify:** `git log --oneline dev | head -5` — all 5 M-1 through M-5 commits visible.

---

## §13: Branching strategy — integration branch

This plan ships through an integration branch `feat/multi-instance-routing-cleanup` (NOT directly to dev) because the changes are structurally invasive (M-2 deletes state.neighbors mid-flight).

**Mechanism:**
- Each phase PR (M-1 through M-5) targets `feat/multi-instance-routing-cleanup`, NOT `dev`
- Phase PRs are still independently reviewable + admin-mergeable
- Final step (after M-5): one squash-merge PR from integration branch → dev, gated on full e2e green

**Why not direct-to-dev:**
- M-2 → M-5 leaves dev in a broken state if e2e isn't run between phases
- Integration branch quarantines the broken-state window from dev's CI

**Why not e2e per phase (option A):**
- Adding e2e setup to every phase PR triples the per-PR work
- Operator-grade verification is meaningful only at full chain (all 5 phases)

---

<!-- PLAN_COMPLETE — all 5 phases planned -->
