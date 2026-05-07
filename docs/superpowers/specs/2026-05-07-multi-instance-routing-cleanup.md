# Multi-Instance Routing Cleanup

**Date:** 2026-05-07
**Status:** rev-1 DRAFT
**Companion zh_cn:** `docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.zh_cn.md`

---

## Locked Decisions (Feishu 2026-05-07, Q5.1–Q5.7)

All decisions below were locked in Feishu on 2026-05-07 and are cited verbatim. No decision in this section may be changed without a new brainstorm session and an updated spec revision.

**Q5.1 — ActorQuery primitive (decision: simple version, no predicate DSL)**

```elixir
defmodule Esr.ActorQuery do
  @spec find_by_name(session_id :: String.t(), name :: String.t()) :: {:ok, pid} | :not_found
  @spec list_by_role(session_id :: String.t(), role :: atom()) :: [pid]
  @spec find_by_id(actor_id :: String.t()) :: {:ok, pid} | :not_found
end
```

NO predicate DSL, NO scope enum, NO multi-attribute query language. Cap-based discovery (Q5.5) is **explicitly out of scope** — future spec.

**Q5.2 — Esr.Entity.Registry indexes**

Three ETS indexes (the existing actor_id index + two new):
- `actor_id → pid` (existing)
- `(session_id, name) → pid` (NEW — for find_by_name)
- `(session_id, role) → [pid]` (NEW — for list_by_role; bag-style; supports multi-instance same role)

Peers register at `init/1` with `%{actor_id, session_id, name, role}`. Deregister on terminate or monitor DOWN.

**Q5.3 sub-1 — Session creation: empty (no default agents)**

Session creation spawns ONLY base pipeline (FCP + admin scope peers). CC/PTY/etc. require explicit `/session:add-agent`. No `agent=cc` default — fully empty.

**Q5.3 sub-2 — (CC, PTY) supervision: `:one_for_all`**

PTY is the IO channel; lone-survivor has no semantic value. Strategy: `:one_for_all`.

**Q5.3 sub-3 — DynamicSupervisor location: per-session**

Each session supervisor (`Esr.Scope.Supervisor`) hosts ONE child DynamicSupervisor that hosts the (CC, PTY) subtrees. `/session:end` automatically cleans via OTP shutdown (no manual enumerate).

**Q5.3 sub-4 — /session:add-agent atomicity: serialize via GenServer**

InstanceRegistry GenServer's `add_instance(session_id, name, type)` is one atomic call: check uniqueness → DynamicSupervisor.start_child → register pid. Mirrors Phase 5.2 metamodel-aligned pattern.

**Q5.4 — actor_id vs name**

- `actor_id`: UUID v4, generated at `/session:add-agent`, stored in InstanceRegistry (existing field)
- `name`: mutable display alias (operator-facing); rename doesn't change actor_id
- Three query functions reflect three access patterns (above)

**Q5.5 — Cap-based DSL: NOT in scope**

Future spec. This spec deliberately limits ActorQuery to (name, role, actor_id) lookups. The brainstorm doc's §4.1 "unified primitive" wording is dropped: there is no unification of "deterministic wire" with "dynamic discovery" yet.

**Q5.6 — Migration: 5 phases, NO backward compatibility**

Hard cutover at every phase. NO `state.neighbors` fallback period. NO double-write to `_legacy.*` after this spec ships. Each phase is one PR; sequential dependency chain (M-1 must be in dev before M-2 starts; etc.). Tests stay green at every PR boundary.

| Phase | Title | Est LOC delta |
|---|---|---|
| M-1 | Esr.ActorQuery + Registry indexes (additive) | +250 |
| M-2 | Migrate callers + delete state.neighbors + per-session DynSup + atomic add-agent | -200 net |
| M-3 | Delete legacy diffusion (workspace.neighbors / topology symmetric_closure / reachable_set / describe_topology neighbor_workspaces) | -300 delete |
| M-4 | Delete _legacy.* compat shim + legacy %Workspace{} struct + 4 caller migrations | -400 delete |
| M-5 | Tests + e2e sweep + new multi-CC scenario | +200 / -100 |
| **Net** | | **~ -550 LOC** |

**Q5.7 — Time window: moot**

Session-first model migration shipped 2026-05-07 (metamodel-aligned ESR spec). The prerequisite named in the brainstorm doc is now satisfied. This spec proceeds immediately.

---

## References

- `docs/futures/multi-instance-routing-cleanup.md` — brainstorm input document (facts, open questions, evidence pointers)
- `docs/notes/concepts.md` — Tetrad metamodel: Scope / Entity / Resource / Interface / Session vocabulary
- `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md` — session-first migration that shipped concurrently; establishes InstanceRegistry + MentionParser
- `docs/notes/pubsub-audit-pr3.md` — PR-3 PubSub discipline (UNCHANGED by this spec)
- `docs/superpowers/specs/2026-04-27-actor-topology-routing.md` — original actor topology routing design (superseded by this spec)

---

## §1 — Motivation

### 1.1 The 1:1 role-instance assumption

PR-3 introduced `state.neighbors :: Keyword<role_atom, pid>` to wire peers together during session startup. A `Keyword` list with atom keys structurally enforces that each key appears at most once — `Keyword.get/2` returns the first match. At the time of PR-3, the specification was 1:1: each session had exactly one CC process, one PTY process, one Feishu Chat Proxy. The wiring was correct and the constraint was intentional. The decision to use a `Keyword` list was not a review failure; it matched the design of the era.

By 2026-05-07 the design has moved. `Esr.Entity.Agent.InstanceRegistry` and `MentionParser` allow multiple agent instances per session (the "multi-CC" capability). `/session:add-agent` stores instance metadata in ETS. However, the spawning layer was not updated alongside the metadata layer. `/session:add-agent` currently writes an ETS record in InstanceRegistry but does not spawn any actor processes. The result is that `MentionParser` correctly parses `@helper-A` from a Feishu message, but the subsequent pid lookup returns `:not_found` because `helper-A` has no corresponding actor in the BEAM. The named agent does not exist at runtime.

The `state.neighbors` keyword list also requires a second, equally fragile mechanism: `backwire_neighbors` in `agent_spawner.ex` uses `:sys.replace_state/2` to patch the running state of every spawned peer after the full peer set is up. When a PTY process restarts, `rewire_session_siblings` in `pty_process.ex` re-patches the `:pty_process` key in all sibling peers' states. Both mechanisms — the initial backwire and the restart rewire — are workarounds for the absence of a runtime peer lookup. They are also brittle: `:sys.replace_state/2` bypasses all GenServer message ordering guarantees, and the restart rewire relies on a 50ms timer (`Process.send_after(self(), :rewire_siblings, 50)`) that is inherently racy.

### 1.2 The legacy diffusion layer

Simultaneously, the codebase carries an accumulation of code whose original purpose was to guide LLM routing decisions:

- `workspace.neighbors:` field in `Esr.Resource.Workspace.Registry.Workspace` (line 55) and in the `%Struct{}` settings under `_legacy.neighbors`
- `Esr.Topology.symmetric_closure/0` — computes the transitive closure of workspace neighbor relationships
- `Esr.Topology.initial_seed/3` — seeds a CC peer's `reachable_set` from workspace neighbors + its own chat URI + adapter URI
- The `reachable_set` field in `Esr.Entity.CCProcess` state, and the `<reachable>` JSON element in CC's outbound prompt envelope
- The `describe_topology` MCP tool (advertised in `tools.ex`, implemented in `server.ex`) which returns `neighbor_workspaces` in its response

None of these mechanisms participate in routing decisions. `cap_guard` at the receiver side governs access; workspace neighbors are not consulted. The `<reachable>` element is informational only — the LLM sees a list of URI strings and may choose to mention them, but there is no enforcement. The neighbor concept overlaps with capability grants (which already govern what a peer may do with another workspace) without adding anything that cap_guard does not already provide. The diffusion layer is a LLM context shaper that has drifted from its original design intent.

### 1.3 Root cause

Both problems share the same root cause: **role and instance were never separated into distinct concepts.** A workspace neighbor is a coarse-grained proxy for "which other workspaces has this CC been told about," not a runtime lookup mechanism. The `state.neighbors` keyword list is a compile-time shape that assumed 1:1 role binding. The fix is to introduce a proper runtime peer registry indexed by both role and instance name, remove the word-of-mouth neighbor diffusion, and make `/session:add-agent` actually do what its name says.

---

## §2 — Goals

1. Unify peer lookup behind `Esr.ActorQuery` — three simple functions covering the three real access patterns: by name (operator perspective), by role (system fan-out), by actor_id (stable cross-reference).

2. Eliminate the 1:1 role-instance assumption embodied in `state.neighbors :: Keyword<role_atom, pid>`. After this spec, any number of CC peers may coexist in one session, each findable by its unique name and retrievable as a list by role.

3. Make `/session:add-agent` actually spawn the (CC, PTY) actor subtree, so a named agent has a live BEAM pid from the moment the command returns `:ok`.

4. Delete all legacy diffusion mechanisms in their entirety: `workspace.neighbors`, `<reachable>`, `symmetric_closure`, `describe_topology neighbor_workspaces`, `reachable_set` field in CC state, and the `backwire_neighbors` / `rewire_session_siblings` wiring ceremonies.

5. Net delete approximately 550 LOC across the runtime.

---

## §3 — Non-Goals

The following are **explicitly out of scope** for this spec. Adding any of them to the implementation is a spec violation and requires a new brainstorm + revised spec.

- **Cap-based discovery (Q5.5):** Locked out of scope (Feishu 2026-05-07). Future spec. `Esr.ActorQuery` deliberately has only three functions and no predicate DSL.

- **Replacing BEAM direct-send with a broker or message queue:** PR-3 data-plane discipline remains unchanged. Peers continue to use `send/2`, `GenServer.call/2`, `GenServer.cast/2` directly. PubSub remains the control plane (7 topic family whitelist).

- **Cross-esrd federation:** This spec covers single-esrd actor lookup only. Multi-esrd routing is a future architectural concern.

- **`cap_guard` changes:** Authorization layer is orthogonal. `ActorQuery` is a discovery mechanism; `cap_guard` is an authorization mechanism. They compose: discover a pid via ActorQuery, then let `cap_guard` at the receiver decide whether the message is allowed.

- **Backward compatibility:** There is no fallback period. No `state.neighbors` is kept as a secondary cache. No double-write to `_legacy.*` keys. Each phase hard-cuts over. Callers that depend on `state.neighbors` will break on M-2 until they are migrated in that same PR.

- **Workspace-level metadata API:** `workspace.role` and `workspace.metadata` (stored under `_legacy.role`, `_legacy.metadata`) are deleted in M-4. If operators need workspace-level metadata after this spec ships, the replacement API will be designed separately — without the `_legacy.*` key indirection and without the dual-table architecture.

- **New MCP tool to replace describe_topology:** The `describe_topology` MCP tool is deleted in M-3 with no replacement shipped in this spec. If CC needs to discover its session peers in its prompt, a new tool based on `ActorQuery` semantics is the correct design — but that is §12 follow-up work, not M-3 scope.

---

## §4 — The ActorQuery API

### 4.1 Design rationale

The three functions in `Esr.ActorQuery` correspond to three distinct access patterns that exist in the current codebase:

| Pattern | Current code | ActorQuery replacement |
|---|---|---|
| Route a @mention to a named agent | `MentionParser` parses name → no lookup (pid doesn't exist) | `find_by_name(session_id, name)` |
| Find the FCP to send a reply through | `Keyword.get(state.neighbors, :feishu_chat_proxy)` | `list_by_role(session_id, :feishu_chat_proxy) \|> List.first()` |
| Cross-reference a known actor_id (restart-safe) | `Esr.Entity.Registry.lookup(actor_id)` | `find_by_id(actor_id)` (same underlying lookup, but surfaced in a unified API) |

The decision NOT to add a predicate DSL (Q5.1, Feishu 2026-05-07) was explicit. A predicate DSL would add complexity before the simpler form has been proven necessary. The three functions cover all current call sites. Cap-based discovery (Q5.5) remains the open design space for future extension.

### 4.2 Full module spec

```elixir
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

  list_by_role/2 filters out dead pids (Registry cleanup is async on
  monitor DOWN). In the narrow window between a pid dying and the DOWN
  being processed, a caller may receive a dead pid. The monitor-before-
  send pattern handles this correctly — the send silently drops, and the
  DOWN arrives promptly.
  """

  @doc """
  Find a peer by its operator-facing display name within a session.

  Searches the (session_id, name) ETS index.

  Returns `{:ok, pid}` when exactly one live registration exists.
  Returns `:not_found` if no registration exists for (session_id, name).

  ## Guarantees

  - Name uniqueness within a session is enforced at registration time
    via `:ets.insert_new/2`. `find_by_name/2` will therefore never be
    in a state where two registrations share the same (session_id, name).

  - After M-2, a name present in InstanceRegistry always has a
    corresponding live pid. The pre-spec "orphan name" state (name in
    InstanceRegistry but no spawned process) cannot occur.

  ## Example

      iex> Esr.ActorQuery.find_by_name("sess-abc", "helper-A")
      {:ok, #PID<0.123.0>}

      iex> Esr.ActorQuery.find_by_name("sess-abc", "nonexistent")
      :not_found
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

  Searches the (session_id, role) ETS bag index.

  Returns a (possibly empty) list of pids. Ordering is not guaranteed.

  ## Multi-instance support

  If a session has two CCProcess peers (both with role :cc_process),
  both pids are returned. Callers choose their own selection strategy
  (first / round-robin / fan-out).

  ## Stale entry handling

  The bag index is cleaned on monitor DOWN. In the narrow async window
  between a pid dying and the DOWN processing, a dead pid may appear.
  Filter with `Process.alive?/1` if needed, or use the monitor-before-
  send pattern.

  ## Example

      iex> Esr.ActorQuery.list_by_role("sess-abc", :cc_process)
      [#PID<0.123.0>, #PID<0.124.0>]

      iex> Esr.ActorQuery.list_by_role("sess-abc", :pty_process)
      []
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

  Delegates to Esr.Entity.Registry.lookup/1 (Index 1, actor_id → pid).

  Returns `{:ok, pid}` or `:not_found`.

  Use this for cross-references where the actor_id is stored (e.g., in
  InstanceRegistry or in another actor's persisted state) and must
  survive restarts. The actor_id is stable; the pid changes on restart.

  ## Example

      iex> Esr.ActorQuery.find_by_id("550e8400-e29b-41d4-a716-446655440000")
      {:ok, #PID<0.125.0>}
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

### 4.3 Caller migration patterns

**Pattern A — FCP routing to CC (before / after):**

Before (feishu_chat_proxy.ex:666):
```elixir
case Keyword.get(state.neighbors, :cc_process) do
  nil -> {:error, :no_cc}
  pid -> send(pid, envelope)
end
```

After:
```elixir
# For FCP → one CC: take first (most sessions have one CC).
# For multi-CC @mention routing: caller already resolved name before here.
case Esr.ActorQuery.list_by_role(state.session_id, :cc_process) do
  [pid | _] -> send(pid, envelope)
  []        -> {:error, :no_cc}
end
```

**Pattern B — CC routing to FCP (before / after):**

Before (cc_process.ex:379, find_chat_proxy_neighbor):
```elixir
defp find_chat_proxy_neighbor(neighbors) do
  Enum.find_value(neighbors, fn
    {:feishu_chat_proxy, pid} when is_pid(pid) -> pid
    _ -> nil
  end) || Keyword.get(neighbors, :cc_proxy)
end
```

After:
```elixir
defp find_reply_target(session_id) do
  case Esr.ActorQuery.list_by_role(session_id, :feishu_chat_proxy) do
    [pid | _] -> {:ok, pid}
    []        ->
      case Esr.ActorQuery.list_by_role(session_id, :cc_proxy) do
        [pid | _] -> {:ok, pid}
        []        -> :not_found
      end
  end
end
```

**Pattern C — FCP routing to feishu_app_proxy (before / after):**

Before (feishu_chat_proxy.ex:711):
```elixir
case Keyword.get(state.neighbors, :feishu_app_proxy) do
  nil -> :error
  pid -> GenServer.call(pid, {:send_msg, payload})
end
```

After:
```elixir
case Esr.ActorQuery.list_by_role(state.session_id, :feishu_app_proxy) do
  [pid | _] -> GenServer.call(pid, {:send_msg, payload})
  []        -> :error
end
```

**Pattern D — @mention routing to named agent:**

New pattern (no before — this was broken before M-2):
```elixir
# MentionParser already parsed the name from the Feishu message.
def route_mention(mention_name, session_id, envelope) do
  case Esr.ActorQuery.find_by_name(session_id, mention_name) do
    {:ok, pid} ->
      _ref = Process.monitor(pid)
      send(pid, {:mention, envelope})
      :ok

    :not_found ->
      {:error, {:agent_not_found, mention_name}}
  end
end
```

### 4.4 What ActorQuery does NOT do

The following are explicitly excluded:

- **Predicate filtering:** No `find_where(role: :cc_process, session_id: sid, name: ~r/helper/)`. Use `list_by_role/2` and filter in the caller.
- **Scope enum:** No `find_in_scope({:neighborhood, ws_id}, predicate)`. Scope is always the session_id.
- **Fan-out routing decisions:** `list_by_role/2` returns pids; the caller decides what to do with them (take first, fan-out, round-robin).
- **Cap checking:** That is `cap_guard`'s job at the receiver.
- **Cross-esrd lookup:** Single-esrd only.
- **Pid liveness guarantee:** Returns a pid that was alive at query time. Monitor before use.

---

## §5 — Esr.Entity.Registry Upgrade

### 5.1 Current state

`Esr.Entity.Registry` (`runtime/lib/esr/entity/registry.ex`) is a thin wrapper over Elixir's `Registry` module with `:unique` strategy. It maintains a single index: `actor_id → pid`. Registration is called from `Esr.Entity.Server.init/1`. Deregistration happens automatically via `Registry`'s built-in monitor when the registered process exits.

The module currently exports:
- `register(actor_id, pid)` — register calling process
- `lookup(actor_id)` — look up by actor_id
- `list_all()` — enumerate all registered pairs

### 5.2 New ETS index layout

After M-1, three indexes coexist:

**Index 1 — actor_id (existing, unchanged):**
```
Backend:   Elixir Registry (:unique strategy)
Atom name: Esr.Entity.Registry
Key:       actor_id :: String.t()
Value:     pid (caller = registrant)
Cleanup:   automatic via Registry monitor on process exit
```

**Index 2 — (session_id, name) (NEW in M-1):**
```
Backend:   :ets.new(:esr_actor_name_index, [:named_table, :set, :public,
                    read_concurrency: true])
Key:       {session_id :: String.t(), name :: String.t()}
Value:     {pid :: pid(), actor_id :: String.t()}
Insert:    :ets.insert_new/2 for race-free uniqueness
Cleanup:   manual via Registry.deregister_attrs/1 on terminate,
           OR via monitor DOWN callback in Registry GenServer
```

The `:set` table type ensures at most one entry per (session_id, name) key. `:ets.insert_new/2` returns `false` if the key already exists, making the uniqueness check atomic within ETS.

**Index 3 — (session_id, role) (NEW in M-1):**
```
Backend:   :ets.new(:esr_actor_role_index, [:named_table, :bag, :public,
                    read_concurrency: true])
Key:       {session_id :: String.t(), role :: atom()}
Value:     {pid :: pid(), actor_id :: String.t()}
Insert:    :ets.insert/2 (bag allows multiple values per key)
Cleanup:   manual via Registry.deregister_attrs/1 on terminate,
           OR via monitor DOWN callback in Registry GenServer
```

The `:bag` table type allows multiple entries with the same key, directly supporting the multi-instance same-role case.

### 5.3 New API additions to Esr.Entity.Registry

```elixir
@doc """
Register peer attributes in Index 2 and Index 3.
Must be called from the peer's own init/1 (i.e., self() == pid).

Returns :ok on success.
Returns {:error, :name_taken} if (session_id, name) is already registered.
Returns {:error, :cannot_register_other_pid} if called from a different pid.
"""
@spec register_attrs(actor_id :: String.t(), attrs :: %{
        session_id: String.t(),
        name: String.t(),
        role: atom()
      }) :: :ok | {:error, :name_taken | :cannot_register_other_pid}
def register_attrs(actor_id, %{session_id: sid, name: name, role: role}) do
  pid = self()
  case :ets.insert_new(:esr_actor_name_index, {{sid, name}, {pid, actor_id}}) do
    true ->
      :ets.insert(:esr_actor_role_index, {{sid, role}, {pid, actor_id}})
      # Also set up monitor for async cleanup on crash without terminate.
      Process.monitor(pid)
      :ok
    false ->
      {:error, :name_taken}
  end
end

@doc """
Remove peer attributes from Index 2 and Index 3.
Called from peer's terminate/2.
"""
@spec deregister_attrs(actor_id :: String.t(), attrs :: %{
        session_id: String.t(),
        name: String.t(),
        role: atom()
      }) :: :ok
def deregister_attrs(actor_id, %{session_id: sid, name: name, role: role}) do
  :ets.delete(:esr_actor_name_index, {sid, name})
  pid = self()
  :ets.match_delete(:esr_actor_role_index, {{sid, role}, {pid, actor_id}})
  :ok
end
```

The monitor set up by `register_attrs/2` is handled inside `Esr.Entity.Registry` itself. When the DOWN fires, the Registry GenServer removes Index 2 and Index 3 entries for the dead pid. The handler is idempotent: if entries were already removed by `deregister_attrs/2` in `terminate/2`, the DOWN handler silently skips.

### 5.4 Registration lifecycle

**Happy path (normal shutdown):**
1. Peer `init/1`: calls `Esr.Entity.Registry.register(actor_id, self())` — Index 1 entry
2. Peer `init/1`: calls `Esr.Entity.Registry.register_attrs(actor_id, %{...})` — Index 2 + 3 entries
3. Peer `terminate/2`: calls `Esr.Entity.Registry.deregister_attrs(actor_id, %{...})` — removes Index 2 + 3
4. Process exits: Registry monitor fires for Index 1 cleanup

**Crash path (no terminate/2 called):**
1. Peer `init/1`: registers in all three indexes; Registry monitors the pid
2. Process crashes: Registry's built-in monitor cleans Index 1; Registry GenServer's DOWN handler cleans Index 2 + 3

**Ordering guarantee:** `init/1` returns only after all three index entries are written. `find_by_name/2` called after `init/1` completes will find the pid. There is no async registration delay.

### 5.5 Role atom vocabulary

Each stateful peer module declares `@role` at compile time. The complete list of role atoms (derived from current `state.neighbors` keys in the 508a834 HEAD):

| Role atom | Module | Source file |
|---|---|---|
| `:cc_process` | `Esr.Entity.CCProcess` | `plugins/claude_code/cc_process.ex:110` (state init) |
| `:pty_process` | `Esr.Entity.PtyProcess` | `entity/pty_process.ex:116` (state init) |
| `:feishu_chat_proxy` | `Esr.Entity.FeishuChatProxy` | `plugins/feishu/feishu_chat_proxy.ex:63` (state init) |
| `:feishu_app_proxy` | proxy module | `session/agent_spawner.ex` (proxy spec) |
| `:cc_proxy` | proxy module | `plugins/claude_code/cc_process.ex:17` (module doc) |

Proxy peers (non-stateful GenServers) do not register in Index 2 or Index 3 because they have no `init/1`. If a caller needs to find a proxy, it does so via actor_id from InstanceRegistry (`find_by_id/1`), not via `list_by_role/2`.

New peer modules added by future plugins must declare `@role` and call `register_attrs/2` in their `init/1`. This is enforced by the `Esr.Role.State` behaviour (which `Esr.Entity.Registry` already implements as a sentinel) — add a compile-time check in M-1.

### 5.6 Race-free name uniqueness

The critical invariant: within one session, at most one live actor may have a given name at any moment.

The enforcement mechanism:

1. `InstanceRegistry.add_instance_and_spawn/1` serializes all attempts via GenServer (one request at a time). No two concurrent add-agent calls for the same session can pass the check simultaneously.
2. Inside the GenServer call, `register_attrs/2` uses `:ets.insert_new/2` as a second atomic gate. Even if two requests somehow bypassed the GenServer serialization (e.g., direct ETS access from tests), the ETS-level gate catches it.

The two gates together make name uniqueness robust against both logical races (concurrent commands) and low-level races (concurrent ETS access). The GenServer is the primary gate; ETS insert_new is the safety net.

---

## §6 — Session Structure (Post-Spec)

### 6.1 Session creation at /session:new (Q5.3 sub-1)

**Current behavior (before this spec):** `agent_spawner.ex` reads the agent declaration's `pipeline.inbound` list from `agents.yaml` and spawns every peer in sequence. For the `cc` agent type, this includes `Esr.Entity.FeishuChatProxy`, `Esr.Entity.CCProcess`, and `Esr.Entity.PtyProcess`. After `backwire_neighbors` runs, all three are cross-wired via `:sys.replace_state/2`.

**New behavior (after M-2):** `/session:new` spawns ONLY the base pipeline:
- `Esr.Entity.FeishuChatProxy` (FCP) — chat ingress/egress
- Admin scope peers (slash handler, etc.)

No CC, no PTY. No default agent. The session exists but has no AI agent capability until the operator explicitly calls `/session:add-agent`. The `pipeline.inbound` entry in `agents.yaml` for the base session type is trimmed to contain only FCP + admin peers.

**Rationale:** Q5.3 sub-1 (Feishu 2026-05-07) locks this. The prior behavior baked the `cc` agent type into session creation, which conflates session existence with agent existence. After this spec, sessions and agents are separate concerns. A session may exist with zero agents (e.g., a monitoring session that only routes Feishu messages to a human).

### 6.2 Per-session DynamicSupervisor (Q5.3 sub-3)

Each `Esr.Scope` (per-session supervisor process) gets one child `Esr.Scope.AgentSupervisor` (a `DynamicSupervisor`). This supervisor is started at session creation time and initially has zero children. Each `/session:add-agent` adds one child (a `:one_for_all` sub-supervisor containing CC + PTY).

**Supervision tree — before this spec:**
```
Esr.Scope.Supervisor (DynamicSupervisor, top-level)
└── Esr.Scope (per-session, Supervisor :one_for_one)
    ├── Esr.Entity.FeishuChatProxy
    ├── Esr.Entity.CCProcess          ← always present; spawned at session create
    └── Esr.Entity.PtyProcess         ← always present; spawned at session create
```

**Supervision tree — after this spec:**
```
Esr.Scope.Supervisor (DynamicSupervisor, top-level)
└── Esr.Scope (per-session, Supervisor :one_for_one)
    ├── Esr.Entity.FeishuChatProxy    ← base pipeline, always present
    ├── <other base pipeline peers>   ← slash handler, etc.
    └── Esr.Scope.AgentSupervisor     ← DynamicSupervisor, empty at session create
        ├── agent-instance-supervisor-1 (Supervisor :one_for_all)
        │   ├── Esr.Entity.CCProcess  (instance "helper-A", actor_id UUID-1)
        │   └── Esr.Entity.PtyProcess (instance "helper-A", actor_id UUID-2)
        └── agent-instance-supervisor-2 (Supervisor :one_for_all)
            ├── Esr.Entity.CCProcess  (instance "helper-B", actor_id UUID-3)
            └── Esr.Entity.PtyProcess (instance "helper-B", actor_id UUID-4)
```

`/session:end` sends a shutdown to `Esr.Scope`, which cascades via OTP supervision to terminate `Esr.Scope.AgentSupervisor`, which terminates all agent instance supervisors, which terminate all CC + PTY peers. No manual enumeration needed.

### 6.3 (CC, PTY) :one_for_all strategy (Q5.3 sub-2)

The CC process and PTY process for a single agent instance are placed under a private `Supervisor` with `strategy: :one_for_all`. This supervisor is the direct child of `Esr.Scope.AgentSupervisor`.

**Why :one_for_all?**

PTY is the IO channel through which CC interacts with the operating system. CC sends commands to PTY; PTY streams stdout/stderr back to CC. If PTY crashes, CC has no output path — it is stuck waiting for data that will never come. Restarting CC alone without PTY would leave CC in a broken state. Conversely, if CC crashes, PTY has no consumer; its buffered output goes nowhere. Restarting both ensures a clean, consistent state.

A lone-survivor CC without PTY has no semantic value in the current implementation. The `:one_for_all` strategy enforces this invariant at the OTP level: if either child crashes, both are restarted.

**Restart intensity recommendation:** Set `max_restarts: 3, max_seconds: 60` on the agent instance supervisor. If an agent subtree crashes more than 3 times in 60 seconds, the supervisor gives up and the agent is terminated. The operator must re-add it via `/session:add-agent`. This prevents tight restart loops from consuming resources.

### 6.4 /session:add-agent atomic dispatch (Q5.3 sub-4)

The current `Esr.Commands.Session.AddAgent.execute/1` calls `InstanceRegistry.add_instance/1` which writes one ETS entry and returns `:ok`. No actor is spawned.

After M-2, the command calls `InstanceRegistry.add_instance_and_spawn/1`:

```elixir
# Esr.Commands.Session.AddAgent (after M-2)
def execute(%{"args" => %{"session_id" => sid, "type" => type, "name" => name} = args}) do
  config = Map.get(args, "config", %{})
  with :ok <- validate_agent_type(type) do
    case InstanceRegistry.add_instance_and_spawn(%{
           session_id: sid,
           type: type,
           name: name,
           config: config
         }) do
      {:ok, %{cc_pid: cc_pid, pty_pid: pty_pid}} ->
        {:ok, %{"action" => "added", "session_id" => sid, "type" => type, "name" => name,
                "actor_ids" => %{"cc" => cc_actor_id, "pty" => pty_actor_id}}}

      {:error, {:duplicate_agent_name, n}} ->
        {:error, %{"type" => "duplicate_agent_name",
                   "message" => "agent name '#{n}' already exists in session '#{sid}'"}}

      {:error, {:spawn_failed, reason}} ->
        {:error, %{"type" => "spawn_failed",
                   "message" => "failed to start agent subtree: #{inspect(reason)}"}}
    end
  end
end
```

`InstanceRegistry.add_instance_and_spawn/1` is a new GenServer call that atomically:
1. Checks name uniqueness (`:ets.insert_new/2` in the name index)
2. Generates actor_ids for CC and PTY (UUID v4)
3. Calls `DynamicSupervisor.start_child(agent_sup_pid, child_spec)` where the child spec is a `:one_for_all` supervisor wrapping CC + PTY
4. Waits for the child supervisor to start and both CC + PTY to register in Entity.Registry
5. Stores the permanent InstanceRegistry ETS record with the real pids
6. Returns `{:ok, %{cc_pid: ..., pty_pid: ...}}`

If step 3 fails (DynamicSupervisor returns `{:error, reason}`), the name index placeholder is deleted and `{:error, {:spawn_failed, reason}}` is returned. The InstanceRegistry ETS record is never written on failure.

### 6.5 /session:remove-agent teardown

`/session:remove-agent` (new slash command, not currently in codebase) calls `InstanceRegistry.remove_instance_and_stop/2`:

1. Look up the agent instance supervisor pid via InstanceRegistry (keyed by session_id + name).
2. Call `DynamicSupervisor.terminate_child/2` on `Esr.Scope.AgentSupervisor` with the instance supervisor pid. OTP cascades: instance supervisor terminates → CC and PTY `terminate/2` called → `deregister_attrs/2` cleans Index 2 + 3 → Registry monitors clean Index 1.
3. Delete the InstanceRegistry ETS record.

The primary agent guard: if the agent being removed is the session's primary (first-added) agent, `remove_instance_and_stop/2` checks whether another agent in the session can be promoted to primary. If none, return `{:error, :cannot_remove_last_agent}` (or allow it — decision for the M-2 implementer to confirm with product; default: allow removal even of last agent, session simply has no AI capability after).

---

## §7 — Legacy Delete Inventory

This section enumerates every file and line range deleted across M-2, M-3, and M-4. All line numbers are verified against the 508a834 HEAD of this branch via grep. LOC estimates include blank lines and comments within the deleted blocks.

### M-2 deletes: state.neighbors + backwire/rewire

#### `runtime/lib/esr/session/agent_spawner.ex` (564 LOC total)

| Line range | Content | Est LOC |
|---|---|---|
| 263–282 | Comment block: "PR-9 T6 — bidirectional neighbors (two-pass). Pre-T6 each peer was spawned with a forward-only neighbors keyword list..." rationale for backwire | ~20 |
| 308 | `:ok = backwire_neighbors(refs, proxies, params)` call site | 1 |
| 337–341 | Comment: "PR-9 T6: patch `state.neighbors` on every spawned pid after all...recurse into it." | ~5 |
| 342–395 | `backwire_neighbors/3` private function — full implementation including inbound_entries construction, proxy_entries resolution, and the `:sys.replace_state/2` loop | ~54 |
| 420–430 | `neighbors = build_neighbors(refs_acc)` local var + pass to `spawn_peer` as arg | ~11 |
| 457–470 | `defp build_neighbors(refs_acc)` — maps `refs_acc` keyword list to `{name, pid}` pairs | ~14 |

Also: remove `neighbors` parameter from `Esr.Entity.Factory.spawn_peer/5` call signature — the function currently takes `(session_id, impl, args, neighbors, ctx)`. After M-2 it takes `(session_id, impl, args, ctx)`. This requires updating `spawn_peer`'s definition in `entity/factory.ex` as well.

**M-2 delta in agent_spawner.ex: approximately -105 LOC**

#### `runtime/lib/esr/entity/pty_process.ex` (398 LOC total)

| Line range | Content | Est LOC |
|---|---|---|
| 116 | `neighbors: Map.get(args, :neighbors, [])` in state struct init | 1 |
| 138–145 | Comment + `Process.send_after(self(), :rewire_siblings, 50)` deferred rewire trigger in `init/1` | ~8 |
| 283 | Module doc reference: "handle_downstream(:rewire_siblings, state) runs the PR-21ω' rewire" | ~2 |
| 317–325 | `handle_downstream(:rewire_siblings, state)` clause delegating to `rewire_session_siblings` | ~9 |
| 325–328 | Comment: "Sibling rewire (PR-21ω'). Public for the rewire test in Phase 4." | ~4 |
| 329–355 | `def rewire_session_siblings/1` — looks up session children via DynamicSupervisor, patches `:pty_process` key in each sibling's state | ~27 |
| 357–367 | `defp patch_neighbor_in_state/3` — uses `:sys.replace_state` to patch neighbor keyword list | ~11 |

Also: remove `:neighbors` from the `defstruct` / initial state map at `pty_process.ex:107`. The struct field is gone; `Map.get(args, :neighbors, [])` is gone.

**M-2 delta in pty_process.ex: approximately -62 LOC**

#### `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`

| Line | Content | Est LOC |
|---|---|---|
| 63 | `neighbors: Map.get(args, :neighbors, [])` in state init | 1 |
| 666 | `case Keyword.get(state.neighbors, :cc_process) do` branch (incl body ~6 lines) | ~6 |
| 711 | `case Keyword.get(state.neighbors, :feishu_app_proxy) do` branch (incl body ~6 lines) | ~6 |

Replacement: `Keyword.get(state.neighbors, :cc_process)` → `Esr.ActorQuery.list_by_role(state.session_id, :cc_process) |> List.first()`. Net change is small (delete 1 line, add 1 line).

**M-2 delta in feishu_chat_proxy.ex: approximately -1 LOC net (replace, not pure delete)**

#### `runtime/lib/esr/plugins/claude_code/cc_process.ex` (M-2 portion)

| Line | Content | Est LOC |
|---|---|---|
| 17 | `:neighbors` in module-level state key enumeration | 1 |
| 110 | `neighbors: Map.get(args, :neighbors, [])` in state init | 1 |
| 374–414 | `find_chat_proxy_neighbor/1` + two `Keyword.get(state.neighbors, ...)` call sites that use it | ~41 |

Replacement: `find_chat_proxy_neighbor` → `find_reply_target(state.session_id)` using ActorQuery (see §4.3 Pattern B). Net: ~-38 LOC.

**M-2 delta in cc_process.ex (M-2 portion): approximately -38 LOC net**

**M-2 total across all files: approximately -200 LOC net**

---

### M-3 deletes: legacy diffusion

#### `runtime/lib/esr/topology.ex` — **ENTIRE FILE DELETED** (257 LOC)

The file exports three functions, all consumed only by `cc_process.ex`'s `build_initial_reachable_set/1` (also deleted in M-3):

- `initial_seed/3` (lines 48–70): seeds the initial `reachable_set` MapSet from workspace neighbors + chat URI + adapter URI
- `neighbour_set/1` (lines ~68–74): returns the URI set reachable as neighbours for a given workspace
- `symmetric_closure/0` (lines 78–138): computes the transitive symmetric closure of the workspace neighbor graph from `workspaces.yaml`

After M-3 deletes `build_initial_reachable_set/1` from cc_process.ex, no caller in the codebase references `Esr.Topology`. The module is dead. Delete the file entirely.

Also delete: `runtime/test/esr/topology_test.exs` if it exists (or stub it with a migration note).

**M-3 delta for topology.ex: -257 LOC**

#### `runtime/lib/esr/plugins/claude_code/cc_process.ex` (M-3 portion)

| Line range | Content | Est LOC |
|---|---|---|
| 87–103 | Comment block explaining reachable_set seeding from workspaces.yaml + `initial_reachable = build_initial_reachable_set(proxy_ctx)` | ~17 |
| 115 | `reachable_set: initial_reachable` in state map | 1 |
| 119–145 | `defp build_initial_reachable_set/1` — calls `Esr.Topology.initial_seed/3`, returns MapSet | ~27 |
| 205–220 | `handle_info` clause that adds URIs to `reachable_set` on source URI events | ~16 |
| 240–248 | `reachable_set` mutation inside meta handler | ~9 |
| 428–438 | `reachable_present=...` log line + comment about reachable attribute | ~11 |
| 498–538 | `maybe_put_reachable/2` + `reachable_json/1` private functions | ~41 |
| 592–614 | PR-C C4 handler: union of new URIs into `state.reachable_set` | ~23 |

**M-3 delta in cc_process.ex: approximately -145 LOC**

#### `runtime/lib/esr/resource/workspace/describe.ex` (M-3 portion, 196 LOC total)

| Line range | Content | Est LOC |
|---|---|---|
| 61–66 | `neighbours = resolve_neighbour_workspaces(ws, overlay)` + `"neighbor_workspaces" => Enum.map(neighbours, ...)` entry in result map | ~6 |
| 122–123 | `base_neighbors = legacy_neighbors(ws)` local var | 2 |
| 164–170 | `defp legacy_neighbors/1` — reads `_legacy.neighbors` from struct settings | ~7 |
| 175–191 | `defp resolve_neighbour_workspaces/2` — resolves neighbor name strings to `%Struct{}` via Registry | ~17 |

**M-3 delta in describe.ex (M-3 portion): approximately -32 LOC**

#### `runtime/lib/esr/entity/server.ex` (M-3 portion)

| Line range | Content | Est LOC |
|---|---|---|
| 284–291 | Comment block: "PR-F 2026-04-28: `describe_topology` returns non-secret yaml data...`workspace:<ws>/describe_topology` for every principal." + bypass `if` condition | ~8 |
| 820–833 | `defp build_emit_for_tool("describe_topology", args, _state)` entire private function | ~14 |

After M-3, the `describe_topology` MCP tool no longer exists. The `if tool == "describe_topology" or capability_granted?(...)` bypass at line 291 is also removed; the tool name no longer appears in any list, so the branch becomes dead code.

**M-3 delta in server.ex: approximately -22 LOC**

#### `runtime/lib/esr/plugins/claude_code/mcp/tools.ex` (M-3 portion)

| Line range | Content | Est LOC |
|---|---|---|
| 89–115 | `@describe_topology` module attribute — map literal with "name", "description", "inputSchema" | ~27 |
| 124 | `@describe_topology` reference in `diagnostic` role tool list | 1 |
| 127 | `@describe_topology` reference in default tool list | 1 |

**M-3 delta in tools.ex: approximately -29 LOC**

#### `runtime/lib/esr/resource/workspace/registry.ex` (M-3 portion — neighbors field only)

| Line | Content | Est LOC |
|---|---|---|
| 55 | `neighbors: [],` field in `%Workspace{}` defstruct | 1 |
| 587 | `neighbors: Map.get(ws.settings, "_legacy.neighbors", []),` in `to_legacy/1` | 1 |
| 604 | `"_legacy.neighbors" => legacy.neighbors \|\| [],` in `normalize_to_struct/1` | 1 |

Note: `to_legacy/1` and `normalize_to_struct/1` functions themselves survive M-3. They are deleted entirely in M-4.

**M-3 delta in registry.ex (M-3 portion): approximately -3 LOC**

**M-3 total across all files: approximately -488 LOC**

(257 topology.ex + 145 cc_process.ex + 32 describe.ex + 22 server.ex + 29 tools.ex + 3 registry.ex)

> Note: The LOC estimate for M-3 exceeds the -300 LOC target in the locked decision table. The discrepancy is because the Q5.6 table estimated -300 for the diffusion layer broadly; the actual reachable_set code in cc_process.ex is larger than estimated at brainstorm time. The phase boundary and ordering remain correct.

---

### M-4 deletes: _legacy.* compat shim + legacy %Workspace{} struct

#### `runtime/lib/esr/resource/workspace/registry.ex` (M-4 portion, 678 LOC total)

| Content | Line range (approx) | Est LOC |
|---|---|---|
| `defmodule Workspace do ... end` including `@moduledoc`, `defstruct`, `@type t` | 41–60 | ~20 |
| `@legacy_table :esr_workspaces` declaration | 63 | 1 |
| `@uuid_table :esr_workspaces_uuid` declaration | 66 | 1 |
| ETS table creation for `@legacy_table` in `init` | 237–239 | ~3 |
| `:ets.delete(@legacy_table, name)` in rename | 342, 538 | 2 |
| `:ets.delete_all_objects(@legacy_table)` in clear | 357 | 1 |
| `:ets.insert(@legacy_table, ...)` on put | 373, 487, 513, 539 | ~4 |
| `:ets.delete(@legacy_table, ...)` on delete | 485 | 1 |
| `defp to_legacy(%Struct{} = ws)` function | 563–590 | ~28 |
| `defp normalize_to_struct(%Workspace{} = legacy)` function | 592–615 | ~24 |
| `defp do_put(%Workspace{} = legacy)` clause | 495–515 | ~21 |
| `@spec start_cmd_for/2` + `def start_cmd_for/2` (2 clauses) | 177–195 | ~19 |
| `def list/0` that reads from `@legacy_table` | 139 | ~5 |
| Legacy `get/1` that reads from `@legacy_table` | 127–135 | ~9 |

**M-4 delta in registry.ex: approximately -139 LOC**

After M-4, `registry.ex` retains: `get/1` using UUID table, `put/1` accepting only `%Struct{}`, `list/0` from UUID table, `workspace_for_chat/2`, `rename/2` using UUID table, and all UUID-keyed ETS operations. The file drops from ~678 LOC to approximately ~539 LOC.

#### `runtime/lib/esr/commands/workspace/info.ex` (M-4 portion, 224 LOC total)

| Content | Line range (approx) | Est LOC |
|---|---|---|
| `defp lookup_legacy(ws_name)` function — full body including `@legacy_table` lookup, `_legacy.*` key reads, result map construction | 107–167 | ~61 |
| `defp build_legacy_result/1` helper | 167–200 | ~34 |
| `ArgumentError -> lookup_legacy(ws_name)` rescue clause (fallback to legacy) | 104–106 | ~3 |
| `"role"`, `"neighbors"`, `"metadata"` fields in the result map (lines 26–35) sourced from `_legacy.*` keys | 26–35 | ~10 |
| `_legacy.role` / `_legacy.neighbors` / `_legacy.metadata` reads inside `lookup_legacy` | 124–126 | ~3 |

**M-4 delta in info.ex: approximately -111 LOC**

After M-4, `info.ex` returns workspace information from the new `%Struct{}` path only. The `"role"`, `"neighbors"`, and `"metadata"` fields are removed from the response (or replaced with struct equivalents if a product decision preserves them via a new mechanism).

#### `runtime/lib/esr/resource/workspace/describe.ex` (M-4 portion)

| Content | Line range (approx) | Est LOC |
|---|---|---|
| `base_metadata = legacy_metadata(ws)` local var | 123 | 1 |
| `defp legacy_metadata/1` function | 168–174 | ~7 |
| `"_legacy.role"` read in describe result | 134 | 1 |
| `"_legacy.metadata"` read in describe result | ~135 | 1 |
| `"role"` field in describe output (sourced from `_legacy.role`) | ~134–136 | ~3 |

**M-4 delta in describe.ex (M-4 portion): approximately -13 LOC**

#### `workspace_for_chat/2` callers — NOT deleted in M-4

`workspace_for_chat/2` is the function mapping `(chat_id, app_id) → workspace_name`. It is called from 8 locations:

1. `plugins/feishu/feishu_chat_proxy.ex:548`
2. `plugins/claude_code/cc_process.ex:509`
3. `entity/unbound_user_guard.ex:40`
4. `entity/slash_handler.ex:746`
5. `entity/unbound_chat_guard.ex:47`
6. `commands/whoami.ex:37`
7. `commands/doctor.ex:109`
8. `session/agent_spawner.ex:202`

`workspace_for_chat/2` is implemented using the UUID-keyed Struct table (`@uuid_table`), not `@legacy_table`. Its signature and implementation are unaffected by M-4. All 8 callers continue to compile and work without modification. This is verified by the implementation at `registry.ex:149–175`.

**M-4 total across all files: approximately -263 LOC pure delete, reaching ~-400 LOC when including cascading simplifications in callers (dead `rescue` clauses, simplified result map construction, etc.)**

---

## §8 — Migration Plan

Five phases, sequential dependency chain. Each phase is one PR. Hard cutover — no fallback periods, no double-write. Tests must be green at every PR boundary.

### M-1: Esr.ActorQuery + Registry indexes (additive)

**Depends on:** nothing — can start immediately after this spec is approved.

**Purpose:** Add the three-index Registry and the `Esr.ActorQuery` module without touching any existing production code paths. After M-1 merges, callers can optionally use `ActorQuery` but `state.neighbors` is still present. M-1 must merge before M-2 starts.

**Files added:**
- `runtime/lib/esr/actor_query.ex` — `Esr.ActorQuery` with three public functions
- `runtime/test/esr/actor_query_test.exs` — unit tests for all three functions
- `runtime/test/esr/entity/registry_indexes_test.exs` — unit tests for Index 2 + 3 lifecycle

**Files modified:**
- `runtime/lib/esr/entity/registry.ex` — add ETS tables for Index 2 + 3; add `register_attrs/2`, `deregister_attrs/2`; add internal monitor DOWN handler; update `list_all/0` to enumerate all three indexes
- `runtime/lib/esr/application.ex` — start the two new ETS named tables (`:esr_actor_name_index`, `:esr_actor_role_index`) in the supervision tree before `Esr.Entity.Registry`
- `runtime/lib/esr/entity/pty_process.ex` — add `@role :pty_process` module attribute; add `register_attrs` call in `init/1`; add `deregister_attrs` call in `terminate/2`
- `runtime/lib/esr/plugins/claude_code/cc_process.ex` — add `@role :cc_process`; add `register_attrs` / `deregister_attrs` calls
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — add `@role :feishu_chat_proxy`; add `register_attrs` / `deregister_attrs` calls

**Estimated LOC:** +250
**Estimated commits:** 5–6 (registry, application, actor_query, three peer modules, tests)
**Peer modules touched:** pty_process, cc_process, feishu_chat_proxy (additive changes only)

### M-2: Migrate callers + delete state.neighbors + per-session DynSup + atomic add-agent

**Depends on:** M-1 merged into dev.

**Purpose:** Complete the migration from `state.neighbors` to `ActorQuery`. Delete `backwire_neighbors` and `rewire_session_siblings`. Add the per-session `AgentSupervisor`. Make `/session:add-agent` spawn the (CC, PTY) actor subtree.

**Files modified:**
- `runtime/lib/esr/session/agent_spawner.ex` — delete `backwire_neighbors/3`, `build_neighbors/1`, `:sys.replace_state/2` usage; remove `neighbors` arg from `spawn_peer` call; trim `create_session/1` to not pass neighbors
- `runtime/lib/esr/entity/pty_process.ex` — delete `rewire_session_siblings/1`, `patch_neighbor_in_state/3`, deferred rewire trigger; remove `:neighbors` from state struct and init
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — replace `Keyword.get(state.neighbors, :cc_process)` with `ActorQuery.list_by_role/2`; replace `Keyword.get(state.neighbors, :feishu_app_proxy)` with ActorQuery; remove `:neighbors` from state struct
- `runtime/lib/esr/plugins/claude_code/cc_process.ex` — replace `find_chat_proxy_neighbor` with ActorQuery-based `find_reply_target`; remove `:neighbors` from state struct
- `runtime/lib/esr/entity/agent/instance_registry.ex` — add `add_instance_and_spawn/1`, `remove_instance_and_stop/2` GenServer callbacks
- `runtime/lib/esr/entity/factory.ex` — remove `neighbors` parameter from `spawn_peer/5` (reduces to `spawn_peer/4`)
- `runtime/lib/esr/commands/session/add_agent.ex` — call `add_instance_and_spawn` instead of `add_instance`

**Files added:**
- `runtime/lib/esr/scope/agent_supervisor.ex` — `Esr.Scope.AgentSupervisor` wrapper around `DynamicSupervisor`

**Files modified (supervision wiring):**
- `runtime/lib/esr/scope.ex` or the per-session supervisor — add `Esr.Scope.AgentSupervisor` as a child in the session supervision tree

**Estimated LOC:** -200 net
**Estimated commits:** 8–10 (one commit per file/concern, small diffs)
**Risk:** Highest-risk phase — see §9 R-1. Stage in small commits; run `mix test --cover` after each commit.

### M-3: Delete legacy diffusion

**Depends on:** M-2 merged into dev.

**Purpose:** Delete the entire `workspace.neighbors` / `reachable_set` / `describe_topology` / `symmetric_closure` surface area. These are pure deletes with no replacement code.

**Files deleted:**
- `runtime/lib/esr/topology.ex` — entire file (257 LOC)
- `runtime/test/esr/topology_test.exs` — if present

**Files modified:**
- `runtime/lib/esr/plugins/claude_code/cc_process.ex` — delete all `reachable_set` code (see §7 M-3 inventory)
- `runtime/lib/esr/resource/workspace/describe.ex` — delete `neighbor_workspaces` output, `resolve_neighbour_workspaces/2`, `legacy_neighbors/1`
- `runtime/lib/esr/entity/server.ex` — delete `build_emit_for_tool("describe_topology", ...)` and the `describe_topology` cap bypass
- `runtime/lib/esr/plugins/claude_code/mcp/tools.ex` — delete `@describe_topology` and list references
- `runtime/lib/esr/resource/workspace/registry.ex` — remove `:neighbors` field from `%Workspace{}` struct; remove `_legacy.neighbors` reads from `to_legacy/1` and `normalize_to_struct/1`
- `runtime/test/esr/plugins/claude_code/cc_process_test.exs` — delete reachable_set tests; stub with `# deleted in M-3` comments pointing to new ActorQuery tests

**Estimated LOC:** -488 (actual, see §7 note)
**Estimated commits:** 5–6 (topology.ex deletion, cc_process cleanup, describe.ex + server.ex + tools.ex, registry.ex cleanup, test updates)

### M-4: Delete _legacy.* compat shim + legacy %Workspace{} struct

**Depends on:** M-3 merged into dev.

**Purpose:** Remove the entire `@legacy_table` ETS infrastructure, `%Workspace{}` legacy struct, `to_legacy/1`, `normalize_to_struct/1`, `do_put(%Workspace{})` clause, and the callers that read `_legacy.*` keys. After M-4, the codebase has no `_legacy.*` key reads and no dual-table workspace storage.

**Files modified:**
- `runtime/lib/esr/resource/workspace/registry.ex` — delete `defmodule Workspace`, `@legacy_table`, `to_legacy/1`, `normalize_to_struct/1`, `do_put(%Workspace{})`, `start_cmd_for/2`, legacy `list/0`, all `@legacy_table` ETS operations
- `runtime/lib/esr/commands/workspace/info.ex` — delete `lookup_legacy/1`, `build_legacy_result/1`, `_legacy.*` Map.get reads, fallback rescue clause
- `runtime/lib/esr/resource/workspace/describe.ex` — delete `legacy_metadata/1`, `_legacy.role` / `_legacy.metadata` reads, `"role"` field from output

**Estimated LOC:** -263 pure delete (-400 with cascading dead code)
**Estimated commits:** 4–5

### M-5: Tests + e2e sweep + new multi-CC scenario

**Depends on:** M-4 merged into dev.

**Purpose:** Rewrite all tests that covered deleted code; add new ActorQuery and multi-CC tests; run full e2e sweep; validate the multi-CC scenario end-to-end.

**Files modified/deleted:**
- `runtime/test/esr/session/agent_spawner_test.exs` — delete `backwire_neighbors` tests; add tests for agent spawn-via-InstanceRegistry; add rollback test (spawn failure leaves no orphan)
- `runtime/test/esr/entity/pty_process_test.exs` — delete `rewire_session_siblings` tests
- `runtime/test/esr/entity/server_describe_topology_test.exs` — delete or rename (tool is gone); if the file tests other server behavior, keep it with topology section removed
- `runtime/test/esr/resource/workspace_describe_test.exs` — delete `neighbor_workspaces` assertions
- `runtime/test/esr/commands/workspace/info_test.exs` — delete `_legacy.*` assertions; update expected response shape

**Files added:**
- `runtime/test/esr/actor_query_test.exs` — full ActorQuery test suite (moved from M-1 additions; or extended)
- `runtime/test/esr/entity/registry_indexes_test.exs` — full Registry index lifecycle tests
- `tests/e2e/scenario_18_multi_cc_session/` — new e2e scenario (see §10)

**Estimated LOC:** +200 / -100
**Estimated commits:** 6–8

---

## §9 — Risk Register

### R-1: M-2 simultaneous state changes in four peer modules (HIGH)

M-2 modifies `state.neighbors` in four peer modules at once: `agent_spawner.ex`, `pty_process.ex`, `feishu_chat_proxy.ex`, `cc_process.ex`. Any one of these touches hot paths in every active session. A bug in one module's migration can manifest as a routing failure in production without an obvious error log.

**Mitigation:**
- Stage M-2 as one commit per peer module. Run `mix test --cover` after each commit.
- The M-2 PR must not land unless the full test suite is green on every intermediate commit SHA (not just the final one).
- Review checklist for each module: (1) `state.neighbors` field removed from `defstruct`/init, (2) all `Keyword.get(state.neighbors, ...)` calls replaced with ActorQuery, (3) module's `register_attrs` / `deregister_attrs` calls are present (from M-1), (4) no remaining reference to `:sys.replace_state` for neighbor wiring.
- Keep M-2 branch in draft until all four modules pass review independently.

### R-2: Known test breakage (ENUMERATED, managed in M-5)

Tests that will break on M-3 or M-4 and require rewrite in M-5:

| Test file | Reason for breakage | M-5 action |
|---|---|---|
| `agent_spawner_test.exs` | Tests `backwire_neighbors/3`, `:sys.replace_state` patching | Delete backwire tests; add spawn-via-InstanceRegistry tests |
| `pty_process_test.exs` | Tests `rewire_session_siblings` (public in Phase 4) | Delete rewire tests |
| `cc_process_test.exs` | Tests `reachable_set` population, `build_initial_reachable_set` | Delete reachable_set tests |
| `entity_server_describe_topology_test.exs` | Tests `describe_topology` MCP tool response | Delete or replace with new tool test if applicable |
| `workspace_describe_test.exs` | Asserts `neighbor_workspaces` in describe output | Delete `neighbor_workspaces` assertions |
| `workspace_info_test.exs` | Asserts `_legacy.neighbors` / `_legacy.role` in info response | Update expected response shape |
| `topology_test.exs` | Tests `Esr.Topology` module (deleted in M-3) | Delete entire test file |

None of these breakages are regressions — they are tests for code that is intentionally deleted. The M-3 and M-4 PRs should each note that these test files break; M-5 cleans them up.

### R-3: e2e scenario 04 (topology integration)

Scenario 04 tests the `describe_topology` MCP tool response shape and possibly `neighbor_workspaces` content. After M-3, this scenario fails because the tool is gone.

**Options to evaluate in M-5:**
- If scenario 04 only tests the describe_topology response shape: delete it. The tool is gone.
- If scenario 04 tests routing correctness beyond the topology tool: extract the routing assertions into scenario 18 or a new scenario; delete the topology-specific parts.
- Decision criteria: does scenario 04 test anything that cannot be re-expressed in terms of ActorQuery behavior?

### R-4: workspace_for_chat/2 callers (LOW — no change needed)

`workspace_for_chat/2` internally uses `@uuid_table` (UUID-keyed `%Struct{}` table), not `@legacy_table`. The function is unaffected by M-4. All 8 call sites continue to work. Verification: grep confirms `workspace_for_chat/2` implementation at `registry.ex:149–175` reads from `@uuid_table` only. Document this explicitly in the M-4 PR description to prevent reviewer concern.

### R-5: DynamicSupervisor child limits (MEDIUM)

The top-level `Esr.Scope.Supervisor` (`runtime/lib/esr/scope/supervisor.ex:17`) is initialized with a `max_children: max` parameter. The new per-session `Esr.Scope.AgentSupervisor` is a DynamicSupervisor nested inside each `Esr.Scope`. Set `max_children: :infinity` for `AgentSupervisor` in development; establish a bounded value (e.g., 10) for production. This limit controls how many agent instances a single session can have, not how many total across the esrd.

### R-6: PTY restart storms under :one_for_all (LOW)

`:one_for_all` means PTY crash → CC restarts. CC has a longer init time (MCP handshake with the claude CLI, PTY allocation). If PTY crashes rapidly (OOM, SIGKILL from OS), the supervisor's restart intensity could trip and permanently kill the agent subtree for the session.

**Mitigation:** Set explicit `max_restarts: 3, max_seconds: 60` on the per-agent `:one_for_all` supervisor. If it trips, the agent is removed from `Esr.Scope.AgentSupervisor`'s children, ETS monitor DOWNs fire and clean the Registry, and InstanceRegistry must be updated to reflect the gone state. The operator must re-add the agent via `/session:add-agent`. Document this in the operator runbook.

### R-7: InstanceRegistry ETS consistency on add_instance_and_spawn failure (MEDIUM)

`add_instance_and_spawn/1` has a two-phase write: (1) name index placeholder via `insert_new`, (2) DynamicSupervisor.start_child. If step 2 fails, step 1 must be rolled back. The rollback is `ets.delete(:esr_actor_name_index, {session_id, name})`.

If the GenServer crashes between step 1 and the rollback (unlikely but possible under severe OOM), the name index entry becomes a phantom. On restart, any subsequent `/session:add-agent` with the same name would see `insert_new` return `false` and report a duplicate. 

**Mitigation:** On `InstanceRegistry` GenServer restart (via `init/1`), scan the name index for entries where the referenced pid is not alive. Delete these phantoms. This is a defensive startup cleanup, not a normal-path operation.

---

## §10 — Test Plan

### ActorQuery unit tests (added in M-1, `actor_query_test.exs`)

All tests use a test-isolated Registry (started with a unique name per test) to avoid cross-test contamination.

| Test case | Setup | Assertion |
|---|---|---|
| `find_by_name/2` — found | Register peer with session_id="s1", name="helper-A" | `{:ok, pid}` returned |
| `find_by_name/2` — not found (no registration) | Empty Registry | `:not_found` |
| `find_by_name/2` — after deregister | Register then deregister | `:not_found` |
| `find_by_name/2` — after process crash | Register; kill process | `:not_found` (monitor DOWN cleaned) |
| `find_by_name/2` — different session | Register in "s1"; query in "s2" | `:not_found` |
| `list_by_role/2` — empty session | No registrations | `[]` |
| `list_by_role/2` — single instance | Register 1 peer with role :cc_process | `[pid]` |
| `list_by_role/2` — multi-instance same role | Register 2 peers with role :cc_process | list of 2 pids (order unspecified) |
| `list_by_role/2` — after one instance crashes | Register 2; kill one | list of 1 pid (crashed one removed) |
| `find_by_id/1` — found | Standard Registry registration | `{:ok, pid}` |
| `find_by_id/1` — not found | No registration | `:not_found` |
| `find_by_id/1` — after process exit | Register; exit | `:not_found` |

### Registry index lifecycle tests (added in M-1, `registry_indexes_test.exs`)

| Test case | Assertion |
|---|---|
| `register_attrs/2` success | Index 2 and Index 3 both have entries after call |
| `register_attrs/2` name duplicate | Returns `{:error, :name_taken}`; Index 3 NOT written |
| `register_attrs/2` from wrong pid | Returns `{:error, :cannot_register_other_pid}` |
| `deregister_attrs/2` | Both Index 2 and Index 3 entries absent after call |
| Monitor DOWN cleanup on crash | Entries absent within 100ms of process death |
| Concurrent register same name (stress) | Exactly one `register_attrs` succeeds; others get `:name_taken` |
| `insert_new` atomicity | Two concurrent `Task.async` registrations with same name → exactly one ok |

### /session:add-agent atomic tests (added in M-2)

| Test case | Assertion |
|---|---|
| Happy path | Returns `{:ok, ...}`; `find_by_name` returns pid; `list_by_role(:cc_process)` returns pid |
| Duplicate name rejection | Returns `{:error, {:duplicate_agent_name, _}}`; no ETS entries |
| Spawn-fail rollback | Simulate `DynamicSupervisor.start_child` failure; name index has no entry |
| Concurrent add-agent same name | One succeeds; one returns duplicate error |
| Supervisor crash mid-add | No orphan ETS entries after crash + cleanup |

### Multi-CC integration test — scenario 18 (added in M-5)

Full lifecycle exercising multi-instance routing (Dim 4 from brainstorm doc §2):

**Step 1:** `/session:new` → assert `list_by_role(sid, :cc_process) == []`

**Step 2:** `/session:add-agent name=helper-A type=cc` →
- assert `find_by_name(sid, "helper-A") == {:ok, pid_a}` where `pid_a` is alive
- assert `list_by_role(sid, :cc_process) == [pid_a]`

**Step 3:** `/session:add-agent name=helper-B type=cc` →
- assert `find_by_name(sid, "helper-B") == {:ok, pid_b}` where `pid_b != pid_a`
- assert `list_by_role(sid, :cc_process) |> length() == 2`

**Step 4:** Send Feishu message `@helper-A answer this question` →
- assert the message was routed to `pid_a`, NOT to `pid_b`
- assert `pid_b` received no message

**Step 5:** `/session:remove-agent name=helper-A` →
- assert `find_by_name(sid, "helper-A") == :not_found`
- assert `list_by_role(sid, :cc_process) == [pid_b]`
- assert `pid_a` is no longer alive (`Process.alive?(pid_a) == false`)

**Step 6:** `/session:end` →
- assert `list_by_role(sid, :cc_process) == []`
- assert `pid_b` is no longer alive

### E2E scenario 18 (new)

Required screenshots per project e2e standards (`docs/notes/esr-e2e-standards.md`):
1. PTY terminal output showing both helper-A and helper-B active in the same session.
2. Feishu chat screenshot showing `@helper-A` message being answered by helper-A specifically.

---

## §11 — Cross-References and Appendix

### Related documents

- Brainstorm input: `docs/futures/multi-instance-routing-cleanup.md` — problem statement, evidence pointers, open questions that this spec answers
- Metamodel vocabulary: `docs/notes/concepts.md` — Scope / Entity / Resource / Interface / Session definitions used throughout this spec
- PR-3 PubSub discipline: `docs/notes/pubsub-audit-pr3.md` — data-plane discipline (UNCHANGED by this spec). Direct send remains the data plane; PubSub remains the control plane with 7 topic family whitelist.
- Future cap-based DSL: `docs/futures/peer-session-capability-projection.md` — Q5.5 deferred design space
- Original topology routing design: `docs/superpowers/specs/2026-04-27-actor-topology-routing.md` — superseded by this spec for the peer-lookup portion; cap-guard design in that spec remains valid

### Invariant test (completion gate)

Per project policy (feedback_completion_requires_invariant_test.md), a phase cannot be claimed "done" on PR-merge alone. The invariant test that gates completion of this entire spec:

> **Invariant:** After M-2 merges into dev, it must be impossible to call `/session:add-agent` and have the command return `:ok` without a live pid being findable via `Esr.ActorQuery.find_by_name/2` within the same GenServer call boundary.

Concretely: a test that calls `add_instance_and_spawn` and then immediately calls `find_by_name` in the same process must return `{:ok, pid}` — not `:not_found`. This test fails if `add_agent` writes metadata without spawning.

### Diff from brainstorm doc

The brainstorm input (`docs/futures/multi-instance-routing-cleanup.md`) §4 proposed a "unified primitive" that would merge deterministic wiring with dynamic discovery under one `ActorQuery.find(predicate, scope)` function. Q5.1 (Feishu 2026-05-07) overrides this: the unified primitive is deferred. The simple three-function form is the decision.

The brainstorm doc §5.3 left supervision strategy open between `:one_for_all` and `:one_for_one`. Q5.3 sub-2 (Feishu 2026-05-07) locks `:one_for_all`.

The brainstorm doc §5.5 left cap-based DSL as an option for this spec. Q5.5 (Feishu 2026-05-07) explicitly removes it from scope.

---

## §12 — Open Follow-Ups (Not Blocking This Spec)

### F-1: Esr.Topology future replacement

After M-3 deletes `Esr.Topology`, the LLM no longer receives a `<reachable>` element in its prompt context. This element was informational (not decision-making), so removing it does not break routing. However, if the product needs the LLM to be aware of peer topology (e.g., "which other agents are available in this session"), a new mechanism must be designed.

The natural replacement, when the cap-based DSL spec lands, is a new MCP tool: `list_session_agents` returning `[{name, role, actor_id, status}]` for all live agents in the session. This is ActorQuery semantics exposed as a tool rather than as a `<reachable>` prompt injection. This is §12 follow-up work, not M-3 scope.

### F-2: workspace.role / workspace.metadata post-deletion

M-4 deletes `_legacy.role` and `_legacy.metadata` from the workspace registry. If operators currently rely on workspace-level role labels (e.g., for the `_echo` tool's `role: diagnostic` gate in `mcp/tools.ex`), those reads must be migrated before M-4 lands.

Identify all `Map.get(settings, "_legacy.role", ...)` reads and replace with direct `%Struct{}` field access or remove if the role concept is no longer needed post-cleanup.

### F-3: todo.md update

After M-1 merges:
- Mark `docs/futures/todo.md` entry "Migrate to session-first model" as shipped (done by the metamodel-aligned ESR spec that shipped concurrently).
- Add "Multi-instance routing cleanup — M-1 through M-5" as new in-flight work.
- Update the "Multi-agent metadata-vs-runtime gap [待检查]" entry to reference this spec.

### F-4: describe_topology MCP tool replacement

The `describe_topology` tool (deleted in M-3) allowed CC to inspect the workspace's neighbor topology. After deletion, CC has no tool-based topology inspection. If CC needs to know about its session peers in its prompt, design a replacement tool grounded in ActorQuery:

Proposed API (future spec, not M-3 scope):
```elixir
# MCP tool: list_session_agents
# Input: {} (no parameters; session inferred from ESR_SESSION_ID env)
# Output: [{name, role, actor_id, alive}]
```

This gives CC factual, real-time information about live peers rather than the static YAML-derived neighbor list that `describe_topology` provided.

### F-5: Operator documentation

After M-5, update operator-facing documentation:
- Remove any mention of `workspace.neighbors:` from `workspaces.yaml` documentation.
- Add `/session:add-agent` and `/session:remove-agent` to the operator command reference.
- Document the multi-CC session lifecycle (create session → add agents → use @mention routing → remove agents → end session).
