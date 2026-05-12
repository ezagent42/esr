# Entity Resolver Implementation Plan (rev-2)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Land `Esr.Entity` unified identity resolver (spec `docs/superpowers/specs/2026-05-12-entity-resolver-design.md`) in a single PR with full alpha enforcement — every caller migrated, old lookup API privatized, breaking change to `InstanceRegistry.primary/2` absorbed in-PR, 2 e2e scenarios.

**Architecture:** Single public API `Esr.Entity.resolve_by(kind, by, value)` returning `{:ok, {kind, uuid}}`. Four private stores (`UserStore`, `WorkspaceStore`, `SessionStore`, `AgentStore`) wrap existing registries during migration; Phase 6 privatizes the wrapped surface.

**Tech Stack:** Elixir 1.18 / OTP 27 / Phoenix / ExUnit / ESR e2e scenario harness.

**Branch:** `feat/entity-resolver` off `origin/dev`. Single PR, admin-squash-merge.

**Spec reference:** `docs/superpowers/specs/2026-05-12-entity-resolver-design.md` (merged 2026-05-12, commit b4695a9).

**Rev-2 changes from rev-1** (this fixes the 5 P0 issues reviewer flagged):
1. No fabricated function calls. Every API the plan references has been grep-verified against `origin/dev` source (see "Verified API inventory" below).
2. Real UUID strings (`Ecto.UUID.generate/0` or pre-minted hex-only fixtures).
3. Phase 0 adds the 2 minimal helpers the resolver requires (`InstanceRegistry.get_by_uuid/2`, `Workspace.Registry.workspace_id_for_chat/2`) instead of inventing mutators.
4. Test fixtures use snapshot loaders (the only real mutator path for `User.Registry` + `Grants`) plus `Workspace.Registry.put/1` (the real per-row mutator). No invented `add_user`/`bind_chat`/`put/2`/`delete/1`.
5. `InstanceRegistry.primary/2` breaking change includes the 3 test sites in `slash_handler_mention_test.exs:32,47,54` that rev-1 missed.
6. E2E scenarios use existing mock-feishu pattern (scenario 23) and read users.yaml directly for UUID lookup — no invented `mock_feishu_inbound` / `user_show`.

---

## Verified API inventory (run against origin/dev 2026-05-12)

The store implementations call ONLY these real functions. Reviewer flagged ~10 fabricated calls in rev-1; this list is the corrected surface.

**`Esr.Entity.User.Registry`** (`runtime/lib/esr/entity/user/registry.ex`):
- `load_snapshot(snapshot)` — full atomic replace (test fixtures)
- `load_snapshot_with_uuids(snapshot, uuids)` — full atomic replace + UUID index
- `get_by_id(uuid)` → `{:ok, %User{}} | :not_found` (User struct has no `:id` field — UUID is the key)
- `lookup_by_feishu_id(ou_xxx)` → `{:ok, username} | :not_found`
- `get(username)` → `{:ok, %User{}} | :not_found`
- `set_default_workspace(username, ws_id)`, `get_default_workspace(username)`
- `list_all/0`, `list/0`

User struct: `%User{username, feishu_ids: [], default_workspace_id: nil}` — no `:id`.

**`Esr.Entity.User.NameIndex`** (`runtime/lib/esr/entity/user/name_index.ex`):
- `id_for_name(table \\ :esr_user_name_index, name)` → `{:ok, uuid} | :not_found`
- `name_for_id(table, uuid)` → `{:ok, name} | :not_found`
- `put(table, name, id)` — mutator (test fixtures use this to populate)

**`Esr.Resource.Workspace.Registry`** (`runtime/lib/esr/resource/workspace/registry.ex`):
- `put(%Esr.Resource.Workspace.Struct{})` — per-row mutator
- `get_by_id(uuid)` → `{:ok, %Struct{}} | :not_found`
- `delete_by_id(uuid)`, `rename(old, new)`, `refresh/0`
- `workspace_for_chat(chat_id, app_id)` → `{:ok, name} | :not_found` (returns NAME)
- `bind_session(workspace_id, session_id)`, `unbind_session/1`, `sessions_for/1`

**`Esr.Resource.Workspace.NameIndex`** (`runtime/lib/esr/resource/workspace/name_index.ex`):
- `put(table, name, id)`, `id_for_name(table, name)` → `{:ok, uuid}`, `name_for_id(table, uuid)`
- Default table: `:esr_workspace_name_index`

**`Esr.Resource.Session.Registry`** (`runtime/lib/esr/resource/session/registry.ex`):
- `get_by_id(uuid)`, `list_all/0`, `reload/0`
- `create_session(data_dir, attrs)` — per-row mutator
- `add_agent_to_session/5`, `remove_agent_from_session/3`

**`Esr.Session.NameIndex.Registry`** (`runtime/lib/esr/session/name_index/registry.ex`):
- `claim_uri(session_id, %{env, username, workspace, name})`
- `lookup_by_name(env, username, workspace, name)` → `{:ok, sid} | :not_found`
- `release_uri(session_id)`

**`Esr.Session.ChatRouting.Registry`** (`runtime/lib/esr/session/chat_routing/registry.ex`):
- `attach_session(chat_id, app_id, sid)`, `detach_session/3`, `detach_session_by_id/1`
- `current_session(chat_id, app_id)` → `{:ok, sid} | :not_found`
- `set_current_session(chat_id, app_id, sid)`
- `list_sessions(chat_id, app_id)`

**`Esr.Entity.Agent.InstanceRegistry`** (`runtime/lib/esr/entity/agent/instance_registry.ex`):
- `add_instance(server \\ __MODULE__, attrs)` — single map arg (NOT `add_instance/4`)
- `get(server, session_id, name)` → `{:ok, %Instance{}} | :not_found`
- `set_primary(server, session_id, name)`, `primary(server, session_id)` → `{:ok, name}` today (Phase 3.4 changes this to UUID)
- `list(server, session_id)`, `names_for_session/2`, `remove_instance/3`, `rename_instance/4`, `attach_to_session/4`, `pty_actor_id_for/3`
- **MISSING**: `get_by_uuid/2` — Phase 0.1 adds this as net-new

**`Esr.Resource.Capability.Grants`** (`runtime/lib/esr/resource/capability/grants.ex`):
- `load_snapshot(snapshot)` — full atomic replace (test fixtures use this)
- `has?(principal_id, permission)` → `boolean()`
- `any_admin?/0`
- **No `put/2`, `delete/1`** — tests build a `%{principal_id => [perms]}` map and call `load_snapshot/1`

---

## File Structure (rev-2)

### New files

| Path | Responsibility |
|---|---|
| `runtime/lib/esr/entity/user_store.ex` | Private user resolver. Composes `User.Registry.get_by_id/1`, `User.NameIndex.id_for_name/2`, `User.Registry.lookup_by_feishu_id/1`. |
| `runtime/lib/esr/entity/workspace_store.ex` | Private workspace resolver. Composes `Workspace.Registry.get_by_id/1`, `Workspace.NameIndex.id_for_name/2`, `Workspace.Registry.workspace_id_for_chat/2` (Phase 0.2 net-new), `User.Registry.get_default_workspace/1`. |
| `runtime/lib/esr/entity/session_store.ex` | Private session resolver. Composes `Session.Registry.get_by_id/1`, `Session.NameIndex.Registry.lookup_by_name/4`, `Session.ChatRouting.Registry.current_session/2`. |
| `runtime/lib/esr/entity/agent_store.ex` | Private agent resolver. Composes `InstanceRegistry.get/3`, `InstanceRegistry.primary/2`, `InstanceRegistry.get_by_uuid/2` (Phase 0.1 net-new). |
| `runtime/test/esr/entity/resolver_test.exs` | Per-by-clause unit tests (13 by-clauses) |
| `runtime/test/esr/integration/chat_cap_check_regression_test.exs` | Regression: chat-side cap-check finds UUID-keyed caps |
| `runtime/test/esr/integration/resolve_submitter_uuid_form_test.exs` | Regression: resolve_submitter accepts UUID form |
| `runtime/test/esr/entity/old_api_unreachable_test.exs` | Compile-fail fixture |
| `tests/e2e/scenarios/31_entity_resolver_chat_flow.sh` | Full chat-flow regression |
| `tests/e2e/scenarios/32_entity_resolver_cli_uuid_form.sh` | CLI UUID-form regression |

### Modified files (39 call sites in 29 files + breaking change + 2 helper additions)

Baseline grep: `grep -rn "lookup_by_feishu_id\|UserRegistry\.get_default_workspace\|UserRegistry\.get_by_uuid\|UserRegistry\.get_by_username\|NameIndex\.id_for_name" runtime/lib/ | grep -v "user/registry.ex\|user/name_index.ex\|user/file_loader.ex"` → 39 lines / 29 files.

Breaking change: `runtime/lib/esr/entity/agent/instance_registry.ex` — `primary/2` returns UUID instead of name. 5 prod callers + 4 test sites (3 in `slash_handler_mention_test.exs:32,47,54` + 1 in `instance_registry_test.exs`):
- Prod: `feishu_chat_proxy.ex:631`, `entity/slash_handler.ex:370`, `commands/key.ex:155`, `commands/agent/primary.ex:30`, `resource/session/registry.ex:224`
- Test: `runtime/test/esr/entity/slash_handler_mention_test.exs:32,47,54`, `runtime/test/esr/entity/agent/instance_registry_test.exs:38,44,134,142`

---

## Phase 0: Setup + minimal net-new helpers

### Task 0.1: Branch + baseline grep

- [ ] **Step 1: Branch**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin dev && git checkout -b feat/entity-resolver origin/dev
```

- [ ] **Step 2: Capture baseline**

```bash
grep -rn "lookup_by_feishu_id\|UserRegistry\.get_default_workspace\|UserRegistry\.get_by_uuid\|UserRegistry\.get_by_username\|NameIndex\.id_for_name" runtime/lib/ \
  | grep -v "user/registry.ex\|user/name_index.ex\|user/file_loader.ex\|entity/user_store.ex\|entity/workspace_store.ex\|entity/session_store.ex\|entity/agent_store.ex" \
  > /tmp/entity-resolver-baseline.txt
wc -l /tmp/entity-resolver-baseline.txt
```

Expected: 39 lines (use as migration checklist; Phase 5's final task verifies count = 0).

### Task 0.2: Add `InstanceRegistry.get_by_uuid/2`

The resolver's `:agent :uuid` by-clause needs UUID → instance lookup. Today's `InstanceRegistry` indexes only `(session_id, name)`. Add a new by-UUID ETS index.

**Files:**
- Modify: `runtime/lib/esr/entity/agent/instance_registry.ex`
- Modify: `runtime/test/esr/entity/agent/instance_registry_test.exs`

- [ ] **Step 1: Failing test**

Append to `instance_registry_test.exs`:

```elixir
  describe "get_by_uuid/2" do
    test "returns instance by UUID after add_instance/2", %{registry: reg} do
      attrs = %{
        session_id: @sess1,
        name: "alice",
        kind: :cc,
        instance_id: "11111111-1111-1111-1111-111111111111",
        actor_ids: %{cc: "cc-act-001", pty: "pty-act-001"}
      }
      assert {:ok, _} = InstanceRegistry.add_instance(reg, attrs)
      assert {:ok, %{name: "alice", session_id: @sess1}} =
               InstanceRegistry.get_by_uuid(reg, "11111111-1111-1111-1111-111111111111")
    end

    test "returns :not_found for unknown UUID", %{registry: reg} do
      assert :not_found =
               InstanceRegistry.get_by_uuid(reg, "ffffffff-ffff-ffff-ffff-ffffffffffff")
    end
  end
```

- [ ] **Step 2: Implement `get_by_uuid/2`**

Read `runtime/lib/esr/entity/agent/instance_registry.ex` around `init/1` to find the ETS table layout. Add a new `@by_uuid_table` ETS table created in `init/1`, populated in the `:add_instance` handler, cleaned in `:remove_instance`/`:rename_instance` handlers. Then add the public function:

```elixir
@spec get_by_uuid(GenServer.server(), String.t()) ::
        {:ok, Instance.t()} | :not_found
def get_by_uuid(server \\ __MODULE__, instance_id) when is_binary(instance_id) do
  GenServer.call(server, {:get_by_uuid, instance_id})
end

# ... and the handler clause:
def handle_call({:get_by_uuid, instance_id}, _from, state) do
  case :ets.lookup(state.by_uuid_table, instance_id) do
    [{^instance_id, %Instance{} = inst}] -> {:reply, {:ok, inst}, state}
    [] -> {:reply, :not_found, state}
  end
end
```

- [ ] **Step 3: Run + verify**

```bash
cd runtime && mix test test/esr/entity/agent/instance_registry_test.exs
```

Expected: all tests pass (existing + 2 new).

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/entity/agent/instance_registry.ex runtime/test/esr/entity/agent/instance_registry_test.exs
git commit -m "feat(agent): InstanceRegistry.get_by_uuid/2 reverse index

Phase 0.2 of entity-resolver. Required for :agent :uuid resolver
by-clause. Adds @by_uuid_table ETS populated on add_instance,
cleaned on remove/rename.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.3: Add `Workspace.Registry.workspace_id_for_chat/2`

Today's `workspace_for_chat/2` returns the workspace NAME. The resolver needs UUID directly. Add a sibling that skips the name-hop.

**Files:**
- Modify: `runtime/lib/esr/resource/workspace/registry.ex`
- Modify: `runtime/test/esr/resource/workspace/registry_test.exs`

- [ ] **Step 1: Failing test**

```elixir
  describe "workspace_id_for_chat/2" do
    test "returns UUID of workspace bound to (chat_id, app_id)" do
      ws_id = Ecto.UUID.generate()
      :ok =
        Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Struct{
          id: ws_id,
          name: "ws_with_chat",
          owner: "alice",
          folders: [%{name: "ws_with_chat", path: "/tmp/x"}],
          chats: [%{chat_id: "oc_test", app_id: "app_test", kind: "dm"}]
        })

      assert {:ok, ^ws_id} =
               Esr.Resource.Workspace.Registry.workspace_id_for_chat("oc_test", "app_test")
    end

    test ":not_found for unbound chat" do
      assert :not_found =
               Esr.Resource.Workspace.Registry.workspace_id_for_chat("oc_nobody", "app_nobody")
    end
  end
```

- [ ] **Step 2: Implement** (in `runtime/lib/esr/resource/workspace/registry.ex`, near `workspace_for_chat/2`)

```elixir
@spec workspace_id_for_chat(String.t(), String.t()) :: {:ok, String.t()} | :not_found
def workspace_id_for_chat(chat_id, app_id) when is_binary(chat_id) and is_binary(app_id) do
  with {:ok, name} <- workspace_for_chat(chat_id, app_id),
       {:ok, uuid} <- Esr.Resource.Workspace.NameIndex.id_for_name(name) do
    {:ok, uuid}
  else
    _ -> :not_found
  end
end
```

- [ ] **Step 3: Run + commit**

```bash
cd runtime && mix test test/esr/resource/workspace/registry_test.exs
```

Expected: all tests pass.

```bash
git add runtime/lib/esr/resource/workspace/registry.ex runtime/test/esr/resource/workspace/registry_test.exs
git commit -m "feat(workspace): workspace_id_for_chat/2 returns UUID directly

Phase 0.3 of entity-resolver. Sibling to workspace_for_chat/2
(which returns name) — needed by :workspace :chat_binding resolver
to return canonical UUID without caller hop.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.4: Document the fixture pattern (`runtime/test/support/entity_fixtures.ex`)

Test fixtures use snapshot loaders (only real mutator path for User.Registry and Grants). Create a single shared helper module rather than duplicating across test files.

**Files:**
- Create: `runtime/test/support/entity_fixtures.ex`

- [ ] **Step 1: Write the helper**

```elixir
defmodule Esr.TestSupport.EntityFixtures do
  @moduledoc """
  Shared test fixtures for Esr.Entity.* tests (2026-05-12 entity-resolver).
  Goes through real public APIs only — no invented mutators.

  Use `setup_user/1` and friends from a test's setup block.
  """

  alias Esr.Entity.User.Registry, as: UserReg
  alias Esr.Entity.User.NameIndex, as: UserNameIx
  alias Esr.Entity.User.Registry.User
  alias Esr.Resource.Workspace.Registry, as: WsReg
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIx
  alias Esr.Resource.Capability.Grants

  @doc """
  Seed a user via snapshot-load. Replaces any existing snapshot —
  caller is responsible for combining multi-user fixtures.
  """
  def setup_user(%{username: username, uuid: uuid} = opts) do
    feishu_ids = Map.get(opts, :feishu_ids, [])
    default_ws = Map.get(opts, :default_workspace_id)

    user = %User{
      username: username,
      feishu_ids: feishu_ids,
      default_workspace_id: default_ws
    }

    snapshot = %{username => user}
    uuids = %{username => uuid}

    :ok = UserReg.load_snapshot_with_uuids(snapshot, uuids)
    :ok = UserNameIx.put(:esr_user_name_index, username, uuid)

    {:ok, %{username: username, uuid: uuid}}
  end

  @doc """
  Seed a workspace via Registry.put/1 (real per-row mutator).
  """
  def setup_workspace(%{id: id, name: name, owner: owner} = opts) do
    chats = Map.get(opts, :chats, [])
    folders =
      Map.get(opts, :folders, [
        %{name: name, path: "/tmp/test-fixture-#{id}"}
      ])

    :ok =
      WsReg.put(%Esr.Resource.Workspace.Struct{
        id: id,
        name: name,
        owner: owner,
        folders: folders,
        chats: chats
      })

    :ok = WsNameIx.put(:esr_workspace_name_index, name, id)

    {:ok, %{id: id, name: name}}
  end

  @doc """
  Seed cap grants via snapshot-load. Caller passes a map of
  `principal_id => [permissions]`.
  """
  def setup_caps(grants_map) when is_map(grants_map) do
    :ok = Grants.load_snapshot(grants_map)
    {:ok, grants_map}
  end
end
```

- [ ] **Step 2: Wire into `test_helper.exs` so it's compiled**

Verify `runtime/test/test_helper.exs` has `Code.compiler_options(warnings_as_errors: false)` for fixtures, or that the support dir is loaded. If not, add to `runtime/mix.exs` test paths if needed (check existing setup — most ESR test fixtures already work, so this is likely a no-op).

- [ ] **Step 3: Commit**

```bash
git add runtime/test/support/entity_fixtures.ex
git commit -m "test(support): EntityFixtures helper for resolver tests

Phase 0.4 of entity-resolver. Centralized test fixture helpers
that go through real public APIs (load_snapshot_with_uuids,
Workspace.Registry.put/1, Grants.load_snapshot/1, NameIndex.put/3).
No invented mutators.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Phase 1: Store implementations + per-by-clause tests

### Task 1.1: `UserStore` + 3 user by-clauses

**Files:**
- Create: `runtime/lib/esr/entity/user_store.ex`
- Create: `runtime/lib/esr/entity/{workspace,session,agent}_store.ex` (stubs for compile)
- Modify: `runtime/lib/esr/entity.ex` (add `resolve_by/3` + `actor_for_agent/2`)
- Create: `runtime/test/esr/entity/resolver_test.exs`

- [ ] **Step 1: Failing tests**

```elixir
defmodule Esr.Entity.ResolverTest do
  use ExUnit.Case, async: false

  alias Esr.Entity
  alias Esr.TestSupport.EntityFixtures

  @user1_uuid "11111111-1111-1111-1111-111111111111"
  @user1_name "resolver_user_alice"
  @user1_ou "ou_resolver_alice_001"

  setup do
    {:ok, _} = EntityFixtures.setup_user(%{
      username: @user1_name,
      uuid: @user1_uuid,
      feishu_ids: [@user1_ou]
    })
    :ok
  end

  describe "resolve_by :user :uuid" do
    test "happy" do
      assert {:ok, {:user, @user1_uuid}} = Entity.resolve_by(:user, :uuid, @user1_uuid)
    end

    test ":not_found" do
      assert :not_found = Entity.resolve_by(:user, :uuid, "ffffffff-ffff-ffff-ffff-ffffffffffff")
    end

    test ":invalid_format" do
      assert :invalid_format = Entity.resolve_by(:user, :uuid, "not-a-uuid")
    end
  end

  describe "resolve_by :user :username" do
    test "happy" do
      assert {:ok, {:user, @user1_uuid}} = Entity.resolve_by(:user, :username, @user1_name)
    end

    test ":not_found" do
      assert :not_found = Entity.resolve_by(:user, :username, "nobody_user")
    end
  end

  describe "resolve_by :user :feishu_id" do
    test "happy (ou_xxx → username → uuid chain)" do
      assert {:ok, {:user, @user1_uuid}} = Entity.resolve_by(:user, :feishu_id, @user1_ou)
    end

    test ":not_found for unbound open_id" do
      assert :not_found = Entity.resolve_by(:user, :feishu_id, "ou_nobody_xxxx")
    end

    test ":invalid_format for non-ou prefix" do
      assert :invalid_format = Entity.resolve_by(:user, :feishu_id, "alice")
    end
  end
end
```

- [ ] **Step 2: Run — verify failure**

```bash
cd runtime && mix test test/esr/entity/resolver_test.exs
```

Expected: `(UndefinedFunctionError) function Esr.Entity.resolve_by/3 is undefined`.

- [ ] **Step 3: Create `UserStore` with real APIs only**

```elixir
defmodule Esr.Entity.UserStore do
  @moduledoc """
  Private user resolver (spec §5.1). Composes existing real APIs
  during the migration window; Phase 6 privatizes the underlying
  registries.
  """

  alias Esr.Entity.User.Registry, as: UserReg
  alias Esr.Entity.User.NameIndex

  # UUID v4 hyphenated: 8-4-4-4-12 lowercase hex.
  @uuid_re ~r/\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/

  @doc false
  def resolve(:uuid, uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_re, uuid) do
      case UserReg.get_by_id(uuid) do
        {:ok, _user} -> {:ok, {:user, uuid}}
        :not_found -> :not_found
      end
    else
      :invalid_format
    end
  end

  def resolve(:username, name) when is_binary(name) and name != "" do
    case NameIndex.id_for_name(name) do
      {:ok, uuid} -> {:ok, {:user, uuid}}
      :not_found -> :not_found
    end
  end

  def resolve(:feishu_id, "ou_" <> _ = ou_id) do
    with {:ok, username} <- UserReg.lookup_by_feishu_id(ou_id),
         {:ok, uuid} <- NameIndex.id_for_name(username) do
      {:ok, {:user, uuid}}
    else
      _ -> :not_found
    end
  end

  def resolve(:feishu_id, _), do: :invalid_format
  def resolve(_, _), do: :invalid_format
end
```

- [ ] **Step 4: Stub remaining stores + extend `Esr.Entity`**

Create `runtime/lib/esr/entity/{workspace,session,agent}_store.ex` each with:

```elixir
defmodule Esr.Entity.<Name>Store do
  @moduledoc false
  def resolve(_, _), do: :not_found
end
```

For `AgentStore` add `def actor_for(_, _), do: :not_found` too.

Append to `runtime/lib/esr/entity.ex` before the closing `end`:

```elixir
  # ───────────────────────────────────────────────────────────────
  # Identity resolver (2026-05-12 spec)
  # ───────────────────────────────────────────────────────────────

  @type kind :: :user | :workspace | :session | :agent
  @type uuid_string :: String.t()

  @spec resolve_by(kind(), atom(), term()) ::
          {:ok, {kind(), uuid_string()}} | :not_found | :invalid_format
  def resolve_by(:user, by, value), do: Esr.Entity.UserStore.resolve(by, value)
  def resolve_by(:workspace, by, value), do: Esr.Entity.WorkspaceStore.resolve(by, value)
  def resolve_by(:session, by, value), do: Esr.Entity.SessionStore.resolve(by, value)
  def resolve_by(:agent, by, value), do: Esr.Entity.AgentStore.resolve(by, value)
  def resolve_by(_, _, _), do: :invalid_format

  @spec actor_for_agent(uuid_string(), atom()) :: {:ok, String.t()} | :not_found
  def actor_for_agent(agent_uuid, role) when is_binary(agent_uuid) and is_atom(role) do
    Esr.Entity.AgentStore.actor_for(agent_uuid, role)
  end
```

- [ ] **Step 5: Run + verify**

```bash
cd runtime && mix test test/esr/entity/resolver_test.exs
```

Expected: 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/entity.ex runtime/lib/esr/entity/user_store.ex runtime/lib/esr/entity/workspace_store.ex runtime/lib/esr/entity/session_store.ex runtime/lib/esr/entity/agent_store.ex runtime/test/esr/entity/resolver_test.exs
git commit -m "feat(entity): add Esr.Entity.resolve_by/3 + UserStore

Phase 1.1 of entity-resolver. Public API additive; no callers
migrated yet. UserStore composes real User.Registry +
User.NameIndex APIs (no invented mutators). 3 by-clauses for :user
+ 8 tests using EntityFixtures helper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 1.2: `WorkspaceStore` + 4 workspace by-clauses

Same pattern. The `:owner_default` clause takes a `user_uuid` and internally translates: `User.NameIndex.name_for_id(uuid) → username` → `User.Registry.get_default_workspace(username) → ws_id`.

**Files:**
- Modify: `runtime/lib/esr/entity/workspace_store.ex`
- Modify: `runtime/test/esr/entity/resolver_test.exs`

- [ ] **Step 1: Append tests using EntityFixtures (real API)** — full coverage of `:uuid`, `:name`, `:chat_binding`, `:owner_default`. Setup creates a user via `setup_user` + a workspace via `setup_workspace` with chats including (chat_id, app_id) entries; then `User.Registry.set_default_workspace(username, ws_id)` for `:owner_default`.

- [ ] **Step 2: Implement `WorkspaceStore`**

```elixir
defmodule Esr.Entity.WorkspaceStore do
  alias Esr.Resource.Workspace.Registry, as: WsReg
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIx
  alias Esr.Entity.User.Registry, as: UserReg
  alias Esr.Entity.User.NameIndex, as: UserNameIx

  @uuid_re ~r/\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/

  def resolve(:uuid, uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_re, uuid) do
      case WsReg.get_by_id(uuid) do
        {:ok, _} -> {:ok, {:workspace, uuid}}
        :not_found -> :not_found
      end
    else
      :invalid_format
    end
  end

  def resolve(:name, name) when is_binary(name) and name != "" do
    case WsNameIx.id_for_name(name) do
      {:ok, uuid} -> {:ok, {:workspace, uuid}}
      :not_found -> :not_found
    end
  end

  def resolve(:chat_binding, %{chat_id: chat_id, app_id: app_id})
      when is_binary(chat_id) and is_binary(app_id) do
    case WsReg.workspace_id_for_chat(chat_id, app_id) do
      {:ok, uuid} -> {:ok, {:workspace, uuid}}
      :not_found -> :not_found
    end
  end

  def resolve(:owner_default, user_uuid) when is_binary(user_uuid) do
    if Regex.match?(@uuid_re, user_uuid) do
      with {:ok, username} <- UserNameIx.name_for_id(user_uuid),
           {:ok, ws_id} <- UserReg.get_default_workspace(username) do
        {:ok, {:workspace, ws_id}}
      else
        _ -> :not_found
      end
    else
      :invalid_format
    end
  end

  def resolve(_, _), do: :invalid_format
end
```

- [ ] **Step 3: Run + commit**

### Task 1.3: `SessionStore` + 3 session by-clauses

Setup uses `Session.Registry.create_session(data_dir, attrs)` (data_dir = `System.tmp_dir!()` for tests). `:name_in_scope` requires the 4-tuple — internally translates user_uuid → username and workspace_uuid → workspace_name to compose the `Session.NameIndex.Registry.lookup_by_name/4` call.

```elixir
def resolve(:name_in_scope, %{env: env, user_uuid: uuid, workspace_uuid: ws_uuid, name: name})
    when is_binary(env) and is_binary(uuid) and is_binary(ws_uuid) and is_binary(name) do
  with {:ok, username} <- UserNameIx.name_for_id(uuid),
       {:ok, ws_name} <- WsNameIx.name_for_id(ws_uuid),
       {:ok, sid} <- Esr.Session.NameIndex.Registry.lookup_by_name(env, username, ws_name, name) do
    {:ok, {:session, sid}}
  else
    _ -> :not_found
  end
end

def resolve(:chat_current, %{chat_id: chat_id, app_id: app_id})
    when is_binary(chat_id) and is_binary(app_id) do
  case Esr.Session.ChatRouting.Registry.current_session(chat_id, app_id) do
    {:ok, sid} -> {:ok, {:session, sid}}
    :not_found -> :not_found
  end
end
```

Tests use `Session.ChatRouting.Registry.set_current_session/3` (real API) for `:chat_current` setup; build `claim_uri/2` calls to populate `Session.NameIndex.Registry` for `:name_in_scope` setup.

### Task 1.4: `AgentStore` + 3 agent by-clauses + `actor_for_agent/2`

Uses Phase 0.2's `InstanceRegistry.get_by_uuid/2` for `:uuid` and the `actor_for_agent` impl.

```elixir
def resolve(:uuid, uuid) when is_binary(uuid) do
  if Regex.match?(@uuid_re, uuid) do
    case InstanceRegistry.get_by_uuid(uuid) do
      {:ok, _} -> {:ok, {:agent, uuid}}
      :not_found -> :not_found
    end
  else
    :invalid_format
  end
end

def resolve(:name_in_session, %{name: name, session_uuid: sid})
    when is_binary(name) and is_binary(sid) do
  case InstanceRegistry.get(sid, name) do
    {:ok, %{instance_id: uuid}} -> {:ok, {:agent, uuid}}
    :not_found -> :not_found
  end
end

# During the migration window primary/2 still returns {:ok, name};
# Phase 3.4 changes it to return uuid directly, after which this
# becomes a thin pass-through.
def resolve(:primary_for_session, sid) when is_binary(sid) do
  case InstanceRegistry.primary(sid) do
    {:ok, name_or_uuid} ->
      # Detect format: if UUID-shaped, treat as post-Phase-3.4 return;
      # else treat as pre-Phase-3.4 name and do the name→uuid hop.
      if Regex.match?(@uuid_re, name_or_uuid) do
        {:ok, {:agent, name_or_uuid}}
      else
        case InstanceRegistry.get(sid, name_or_uuid) do
          {:ok, %{instance_id: uuid}} -> {:ok, {:agent, uuid}}
          :not_found -> :not_found
        end
      end

    :not_found ->
      :not_found
  end
end

def actor_for(agent_uuid, role) when is_binary(agent_uuid) and is_atom(role) do
  case InstanceRegistry.get_by_uuid(agent_uuid) do
    {:ok, %{actor_ids: actor_ids}} ->
      key =
        case role do
          :primary -> :cc
          :terminal -> :pty
          other -> other
        end

      case Map.fetch(actor_ids, key) do
        {:ok, actor_id} when is_binary(actor_id) -> {:ok, actor_id}
        _ -> :not_found
      end

    :not_found ->
      :not_found
  end
end
```

Tests use `InstanceRegistry.add_instance(registry, attrs)` (real single-arg-map API; `attrs = %{session_id, name, kind, instance_id, actor_ids}`).

---

## Phase 2: Regression tests for today's drift bugs (red phase)

### Task 2.1: chat-cap-check regression

Uses `EntityFixtures.setup_user/1` + `EntityFixtures.setup_caps/1` (which calls `Grants.load_snapshot/1`). Real UUIDs:

```elixir
setup do
  uuid = "22222222-2222-2222-2222-222222222222"
  user = "regress_cap_user"
  ou = "ou_regress_cap_001"

  {:ok, _} = EntityFixtures.setup_user(%{username: user, uuid: uuid, feishu_ids: [ou]})
  {:ok, _} = EntityFixtures.setup_caps(%{uuid => ["*"]})

  {:ok, uuid: uuid, user: user, ou: ou}
end

test "chat-cap-check finds UUID-keyed cap via ou_xxx → username → UUID", %{ou: ou} do
  assert Esr.Resource.Capability.has?(ou, "session:default/create")
end
```

Pre-fix: cap is keyed under UUID. `Capability.has?(ou, perm)` chain stops at ou→username and never reaches UUID → returns false. Test fails. Post-Wave-A: chain extends through resolver → passes.

### Task 2.2: resolve_submitter UUID-form regression

Same fixture pattern with real UUIDs. Tests CLI submitted_by=<uuid> resolves user-default workspace.

---

## Phase 3: Wave A migration (drift-fix call sites + breaking change)

### Task 3.1: Migrate `Esr.Resource.Capability.has?/2`

**Important correction (rev-2)**: rev-1's "pre-fix description" was wrong. Today's `Capability.has?/2` ALREADY does the ou_xxx→username hop (capability.ex:32-53):

```elixir
# Current chain:
if Grants.has?(principal_id, permission) do
  true
else
  case maybe_resolve_to_username(principal_id) do
    {:ok, username} when username != principal_id ->
      Grants.has?(username, permission)
    _ ->
      false
  end
end
```

The DRIFT is that the chain stops at `Grants.has?(username, perm)`. caps.yaml keyed by UUID won't match. Need to extend by one more hop to UUID via the resolver.

Replacement (refer to spec §5.1 chain):

```elixir
def has?(principal_id, permission)
    when is_binary(principal_id) and is_binary(permission) do
  if Esr.Resource.Capability.Grants.has?(principal_id, permission) do
    true
  else
    # Sniff input form and route through the unified resolver to UUID.
    case Esr.Entity.resolve_by(:user, identifier_form(principal_id), principal_id) do
      {:ok, {:user, uuid}} when uuid != principal_id ->
        Esr.Resource.Capability.Grants.has?(uuid, permission)

      _ ->
        false
    end
  end
end

defp identifier_form(<<_::8*8, "-", _::4*8, "-", _::4*8, "-", _::4*8, "-", _::12*8>>),
  do: :uuid
defp identifier_form("ou_" <> _), do: :feishu_id
defp identifier_form(_), do: :username
```

Run regression test from Task 2.1 — should pass now.

### Task 3.2: Migrate `Esr.Commands.Workspace.Resolve`

Replace `resolve_submitter/1` (resolve.ex:71-79) with a UUID-form-aware version dispatching through `Esr.Entity.resolve_by(:user, sniffed_form, value)`. Same `identifier_form/1` helper pattern.

### Task 3.3: Migrate `Esr.Entity.SlashHandler` chat-flow lookups

Read the file, grep for old-API calls, replace each per the pattern. Leave the `InstanceRegistry.primary/2` call at line 370 for Task 3.4 (breaking change).

### Task 3.4: Breaking change — `InstanceRegistry.primary/2` returns UUID

**Files:**
- Modify: `runtime/lib/esr/entity/agent/instance_registry.ex` (the `primary/2` function around line 170)
- Modify: 5 prod call sites
- Modify: 4 test sites (rev-2: now includes `slash_handler_mention_test.exs:32,47,54`)

- [ ] **Step 1: Change `primary/2` return**

In `instance_registry.ex` `:primary` handler (around line 175), change from:

```elixir
def handle_call({:primary, session_id}, _from, state) do
  case :ets.lookup(state.primary_table, session_id) do
    [{^session_id, name}] -> {:reply, {:ok, name}, state}
    [] -> {:reply, :not_found, state}
  end
end
```

to:

```elixir
def handle_call({:primary, session_id}, _from, state) do
  case :ets.lookup(state.primary_table, session_id) do
    [{^session_id, name}] ->
      case :ets.lookup(state.metadata_table, {session_id, name}) do
        [{_, %Instance{instance_id: uuid}}] -> {:reply, {:ok, uuid}, state}
        _ -> {:reply, :not_found, state}
      end

    [] ->
      {:reply, :not_found, state}
  end
end
```

(Read the actual file to confirm the ETS table layout — adjust the handler shape if real layout differs.)

- [ ] **Step 2: Migrate 5 prod sites** — for each, the caller used to consume `name`; now consumes UUID. If caller needs the actor pid, chain `actor_for_agent/2`.

- [ ] **Step 3: Migrate 4 test sites**

For `slash_handler_mention_test.exs:32,47,54` — each is `{:ok, primary_name} = InstanceRegistry.primary(sess)` followed by name-based assertions. After the breaking change, the return is UUID. Update each assertion to match UUID OR call `InstanceRegistry.get_by_uuid/2` to get back the Instance with name field.

For `instance_registry_test.exs:38,44,134,142` — similar pattern.

---

## Phase 4: Wave B migration (5 high-traffic files)

For each: `feishu_chat_proxy.ex`, `feishu_app_adapter.ex`, `mention_parser.ex`, `entity/server.ex`, `session/router.ex` — apply the migration pattern from Task 3.3.

Each task: grep old-API calls in the file → replace per pattern → run file's test → commit.

---

## Phase 5: Wave C migration (21 remaining files)

Same pattern, one task per file. After all done, verify baseline = 0:

```bash
grep -rn "lookup_by_feishu_id\|UserRegistry\.get_default_workspace\|UserRegistry\.get_by_uuid\|UserRegistry\.get_by_username\|NameIndex\.id_for_name" runtime/lib/ \
  | grep -v "user/registry.ex\|user/name_index.ex\|user/file_loader.ex\|entity/user_store.ex\|entity/workspace_store.ex\|entity/session_store.ex\|entity/agent_store.ex"
```

Expected: empty output.

---

## Phase 6: Privatize old public APIs

After all callers migrated, change the wrapped functions from `def` to `defp` (or move into the new `*Store` modules as `defp`).

**Privatize list** (rev-2 explicit, no hand-waving):

`Esr.Entity.User.Registry`:
- `get_by_id/1` → defp (used only by UserStore now)
- `lookup_by_feishu_id/1` → defp (used only by UserStore now)
- `get/1` → defp (no longer external; `UserNameIx.name_for_id/2` is the user-public path)
- **KEEP public**: `load_snapshot/1`, `load_snapshot_with_uuids/2`, `set_default_workspace/2`, `get_default_workspace/1` (FileLoader at line 218 calls these; also `runtime/test/esr/application_first_boot_test.exs:83` uses `get_default_workspace/1` — keep public + `@doc false`)
- `list_all/0`, `list/0` — used elsewhere? Grep first; privatize only if no external callers.

`Esr.Entity.User.NameIndex`:
- `id_for_name/2` → defp (Wave C-migrated callers go through UserStore now)
- `name_for_id/2` → KEEP public — UserStore + WorkspaceStore + SessionStore call this from outside the User namespace. Document as `@doc false`.
- `put/3`, `rename/3`, `delete_by_id/2` → KEEP public (mutators called from FileLoader / `/user:add` / `/user:remove` commands).

`Esr.Resource.Workspace.Registry`:
- `get_by_id/1` → defp (used only by WorkspaceStore)
- `workspace_for_chat/2` → KEEP public for now (Phase-6.2 follow-up could merge into UUID variant later). Or privatize since WorkspaceStore wraps the UUID variant — verify no external callers via grep.
- `workspace_id_for_chat/2` → defp (used only by WorkspaceStore; Phase 0.3 added this).
- **KEEP public**: `put/1`, `delete_by_id/1`, `rename/2`, `refresh/0`, `bind_session/2`, `unbind_session/1`, `sessions_for/1`, `list_names/0`, `list_all/0`.

`Esr.Resource.Workspace.NameIndex`:
- `id_for_name/2` → defp (used only by WorkspaceStore + UserStore composition).
- KEEP public: `put/3`, `name_for_id/2` (used by WorkspaceStore + SessionStore from outside namespace).

`Esr.Resource.Session.Registry`:
- `get_by_id/1` → defp (only SessionStore reads).
- KEEP public: `create_session/2`, `reload/0`, `add_agent_to_session/5`, `remove_agent_from_session/3`, `list_all/0`.

`Esr.Session.NameIndex.Registry`:
- `lookup_by_name/4` → defp (only SessionStore reads).
- KEEP public: `claim_uri/2`, `release_uri/1`, `list_uris/3`.

`Esr.Session.ChatRouting.Registry`:
- `current_session/2` → defp (only SessionStore reads).
- KEEP public: `attach_session/3`, `detach_session/3`, `set_current_session/3`, `list_sessions/2`, `detach_session_by_id/1`.

`Esr.Entity.Agent.InstanceRegistry`:
- `get/3`, `get_by_uuid/2`, `primary/2`, `pty_actor_id_for/3` → defp (only AgentStore reads).
- KEEP public: `add_instance/2`, `add_instance_and_spawn/2`, `attach_to_session/4`, `remove_instance/3`, `list/2`, `set_primary/3`, `rename_instance/4`, `names_for_session/2`.

**ETS `:named_table` removal** — separate concern. Each store keeps `:named_table` for now (boot-time fixture loading still needs it; deeper refactor to private ETS is a follow-up). Update spec §3 + §6 to reflect: "physical enforcement is via Elixir module visibility (defp), not via private ETS in PR-1." This is honest and ships.

### Task 6.1 through 6.6: per-module privatization

One task per module, run full test suite after each (compile-fail catches missed migrations).

---

## Phase 7: Old-API-unreachable compile-fail test

Create `runtime/test/esr/entity/old_api_unreachable_test.exs`:

```elixir
defmodule Esr.Entity.OldApiUnreachableTest do
  use ExUnit.Case, async: true

  test "User.Registry.get_by_id/1 is not exported (privatized)" do
    {:module, _} = Code.ensure_compiled(Esr.Entity.User.Registry)
    refute function_exported?(Esr.Entity.User.Registry, :get_by_id, 1)
  end

  test "User.Registry.lookup_by_feishu_id/1 is not exported" do
    {:module, _} = Code.ensure_compiled(Esr.Entity.User.Registry)
    refute function_exported?(Esr.Entity.User.Registry, :lookup_by_feishu_id, 1)
  end

  test "User.NameIndex.id_for_name/2 is not exported" do
    {:module, _} = Code.ensure_compiled(Esr.Entity.User.NameIndex)
    refute function_exported?(Esr.Entity.User.NameIndex, :id_for_name, 2)
  end

  test "Workspace.Registry.get_by_id/1 is not exported" do
    {:module, _} = Code.ensure_compiled(Esr.Resource.Workspace.Registry)
    refute function_exported?(Esr.Resource.Workspace.Registry, :get_by_id, 1)
  end

  test "Workspace.NameIndex.id_for_name/2 is not exported" do
    {:module, _} = Code.ensure_compiled(Esr.Resource.Workspace.NameIndex)
    refute function_exported?(Esr.Resource.Workspace.NameIndex, :id_for_name, 2)
  end

  test "InstanceRegistry.primary/2 stays public (kept for AgentStore caller wiring)" do
    # primary/2 is privatized inside Phase 6, but tests outside this file
    # access via Esr.Entity.resolve_by(:agent, :primary_for_session, ...).
    # This test verifies the PUBLIC-by-design surface is still callable.
    {:module, _} = Code.ensure_compiled(Esr.Entity.Agent.InstanceRegistry)
    # Either assert it's still exported (if Phase 6 kept it) or refute
    # (if privatized). Update based on Phase 6 final decision.
  end
end
```

The last test is templated; finalize when Phase 6 ships.

---

## Phase 8: E2E scenarios

### Task 8.1: `31_entity_resolver_chat_flow.sh`

**Use the existing `mock_feishu` adapter pattern**, NOT an invented `mock_feishu_inbound` verb. Look at how `tests/e2e/scenarios/23_zero_config_bootstrap.sh` injects inbound messages — copy that pattern.

Concretely: scenario 23 uses `seed_capabilities` then walks register_adapter + feishu_bind via `esr_cli exec`. For "send an inbound text message", existing scenarios use the mock-feishu adapter which accepts HTTP POST or stdin commands. Read scenario 14 or 15 for the inject pattern.

To read user UUID: NO `user_show` command exists. Read from `~/.esrd-dev/default/users.yaml` + cross-reference `~/.esrd-dev/default/users/<uuid>/user.json` directly. Pattern:

```bash
USER_UUID=$(find "${ESRD_HOME}/${ESR_INSTANCE}/users" -name "user.json" -exec \
  jq -r 'select(.username == "linyilun") | .id' {} \; | head -1)
```

Or grep users.yaml for the username and find the matching subdirectory.

Scenario shape (after reading 23 + 14 for real patterns):
- Start esrd
- `user_add name=linyilun` → auto-admin
- `register_adapter type=feishu name=esr_e2e_31 app_id=cli_e2e_31 app_secret=s`
- `feishu_bind name=linyilun feishu_user_id=ou_e2e_31`
- Inject inbound Feishu message via the existing mock pattern with text `/session:new name=test-cc`
- Assert chat reply contains `session started`
- Crucially: do NOT call `cap_grant target_principal_id=linyilun` — that's the regression we're locking

### Task 8.2: `32_entity_resolver_cli_uuid_form.sh`

Same `seed_capabilities` + `user_add` flow. Read UUID from disk (per above). Then:

```bash
esr_cli exec session_new \
  name=test-cli-uuid \
  workspace=linyilun-default \
  submitted_by="${USER_UUID}"
```

Assert output contains `session_id:`.

---

## Phase 9: Subagent review + PR

### Task 9.1: Dispatch code-quality reviewer

Per memory rule `feedback_subagent_review_plans`: subagent-review the full diff `origin/dev...feat/entity-resolver`. Pass `model: "opus"`.

### Task 9.2: Push + open PR + admin-merge

Standard pattern: Feishu heads-up → `git push -u origin feat/entity-resolver` → `gh pr create --base dev` → review findings → `gh pr merge --admin --squash --delete-branch` → Feishu completion update.

---

## Self-Review (rev-2)

**1. Spec coverage:**
- §1-§5 → Phases 0-1 + spec §5.4 breaking change → Phase 3.4
- §6 store renames → Phase 1 introduces; Phase 6 privatizes
- §7 migration map → Phases 3-5
- §8 old API deprecation → Phase 6 (explicit list, no hand-wave)
- §9 tests → Phases 1 (per-by-clause), 2 (regression), 7 (compile-fail), 8 (e2e)
- §10 future-proofing → captured as todo.md `uri-as-canonical-actor-name`

**2. Placeholder scan**: each phase shows real API calls. Wave B/C tasks reference "Task 3.3 pattern" rather than enumerating every file — acceptable, baseline grep is the enumeration.

**3. Type consistency**:
- `Esr.Entity.resolve_by/3` signature unchanged across all tasks
- Real UUID strings (`Ecto.UUID.generate/0` in tests, 36-char hex-only fixtures in code blocks)
- `User.Registry.get_by_id/1` returns `%User{}` without `:id` field — plan reflects this (no `user.id` access)
- `InstanceRegistry.add_instance/2` takes single attrs map — plan reflects this
- `InstanceRegistry.primary/2` post-Phase-3.4 returns UUID — `AgentStore.resolve(:primary_for_session, sid)` handles both pre/post-migration shapes during the migration window

**4. Reviewer's P0 issues addressed**:
- ✅ No fabricated function calls (verified API inventory at top)
- ✅ Real UUIDs in fixtures
- ✅ 3 missed test sites in `slash_handler_mention_test.exs` listed in Task 3.4
- ✅ Phase 6 explicit privatize list per module
- ✅ E2E uses existing scenario 23 pattern, reads users.yaml for UUID

---

## Execution Handoff

**Plan v2 complete.** Two execution options:

**1. Subagent-Driven (recommended)** — Controller dispatches fresh subagent per task with `model: "opus"`, reviews between major phases.

**2. Inline Execution** — `superpowers:executing-plans`, batch with checkpoints.

Default: subagent-driven.
