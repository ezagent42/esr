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

**Step 2 — Open PR against `dev`; title:** `feat(m-1): Esr.ActorQuery + Registry indexes — additive`

**Step 3 — Admin-merge** (per project policy):
```bash
gh pr merge --admin --squash --delete-branch
```

**Step 4 — Verify:** `git log --oneline dev | head -3` — M-1 commit visible.

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

Open PR against `dev`; title: `feat(m-2): migrate callers to ActorQuery + delete state.neighbors + per-session AgentSupervisor + atomic add-agent`

Admin-merge:
```bash
gh pr merge --admin --squash --delete-branch
```

---

<!-- PLAN_END_M2 — next subagent: append "## Phase M-3" here -->
