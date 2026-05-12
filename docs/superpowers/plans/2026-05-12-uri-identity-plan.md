# URI Identity Subsystem Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Land the URI identity subsystem (spec `docs/superpowers/specs/2026-05-12-uri-identity-design.md`) across 6 PRs. PR-0 lands the new infrastructure (`Esr.Uri.Store`, plugin handler behaviour, `Esr.Uri.Compat` migration shim, CI gate, feishu UriHandler) without touching any caller. PR-1..PR-4 migrate one entity domain per PR (User, Workspace, Session, Agent). PR-5 deletes the Compat shim, adds the compile-fail enforcement test, and ships e2e scenarios.

**Architecture:** Single `Esr.Uri.Store` GenServer + public ETS table holds both alias mappings and entity data (tagged values). `Esr.Uri` umbrella exposes `resolve/1`, `alias/2`, `put_entity/3`, `get_entity/1`, `delete/1`. Plugins declare URI subtrees via `uri_subtrees:` manifest block + implement `Esr.Uri.Plugin` behaviour (resolve/1 + alias/2). Migration uses `Esr.Uri.Compat` return-shape-preserving wrappers so the bulk of call-site changes are mechanical sed replacements.

**Tech Stack:** Elixir 1.18 / OTP 27 / Phoenix / ExUnit / `:elixir_uuid` (`UUID.uuid4()` — note `mix.exs:74` declares `elixir_uuid`, NOT `ecto_uuid`). ESR e2e scenario harness.

**Branches:**
- `feat/uri-store` (PR-0)
- `feat/uri-migrate-user` (PR-1)
- `feat/uri-migrate-workspace` (PR-2)
- `feat/uri-migrate-session` (PR-3)
- `feat/uri-migrate-agent` (PR-4)
- `feat/uri-cleanup` (PR-5)

Each branches off `origin/dev`, admin-squash-merged sequentially.

**Spec reference:** `docs/superpowers/specs/2026-05-12-uri-identity-design.md` (PR #353, rev-2).

**Migration scope:** ~387 call sites across 4 registries (115 User.Registry + 94 Workspace.Registry + 91 InstanceRegistry + 38 Workspace.NameIndex + 21 User.NameIndex + 16 Session.NameIndex + 12 Session.Registry).

---

## File Structure

### New files (PR-0)

| Path | Responsibility |
|---|---|
| `runtime/lib/esr/uri/store.ex` | GenServer owning ETS `:esr_uri_store`. Read via direct ETS; write via GenServer.call. Handles alias→canonical 1-hop invariant. |
| `runtime/lib/esr/uri/plugin.ex` | `Esr.Uri.Plugin` behaviour: `resolve/1`, `alias/2` callbacks. |
| `runtime/lib/esr/uri/compat.ex` | Migration shim. Return-shape-preserving wrappers for each old API (uuid_for_user_name, lookup_by_feishu_id, etc.) Internally calls `Esr.Uri.resolve/1`. DELETED in PR-5. |
| `runtime/lib/esr/uri/file_loader.ex` | Boot-time data loader. Reads users.yaml + workspaces/*/workspace.json + sessions/*/session.json + agent state, populates `:esr_uri_store`. |
| `runtime/lib/esr/plugins/feishu/uri_handler.ex` | Feishu plugin URI handler. Resolves `esr://localhost/users/feishu/<ou_xxx>` → canonical user URI. |
| `runtime/lib/mix/tasks/esr/check_uri_drift.ex` | Mix task implementing L1' path-pattern CI gate. |

### Modified files (PR-0)

| Path | Change |
|---|---|
| `runtime/lib/esr/uri.ex` | Add `resolve/1`, `alias/2`, `put_entity/3`, `get_entity/1`, `delete/1` functions alongside existing parser. Moduledoc updated to document dual role. |
| `runtime/lib/esr/application.ex` | Insert `Esr.Uri.Store` child spec before line 96 (Esr.Entity.Agent.InstanceRegistry). |
| `runtime/lib/esr/plugin/manifest.ex` | Add `uri_subtrees:` field parser following the existing `channels:`/`agent_kinds:` pattern (manifest.ex:41-51, 136-137). |
| `runtime/lib/esr/plugin/loader.ex` | After parsing manifests, register `prefix → handler` mappings via `:persistent_term.put({Esr.Uri, :plugin_handlers}, %{...})`. |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | Add `uri_subtrees:` block declaring `users/feishu` → `Esr.Plugins.Feishu.UriHandler`. |
| `.github/workflows/ci.yml` | Add `mix esr.check_uri_drift` step. |

### Modified files (PR-1 through PR-4 — per domain)

Each domain PR:
- **Modify** existing FileLoader to also call `Esr.Uri.put_entity/3` + `Esr.Uri.alias/2`
- **Sed-replace** all call sites referencing old API → `Esr.Uri.Compat.<wrapper>` or `Esr.Uri.<func>`
- **Delete** the old registry + NameIndex modules (or move their internals into UriHandler)
- **Update** the L1' baseline file `priv/uri-drift-baseline.txt` to reflect the now-zero call count for that domain

### Deleted files (across PR-1..PR-4)

- `runtime/lib/esr/entity/user/registry.ex` (PR-1)
- `runtime/lib/esr/entity/user/name_index.ex` (PR-1)
- `runtime/lib/esr/resource/workspace/registry.ex` (PR-2)
- `runtime/lib/esr/resource/workspace/name_index.ex` (PR-2)
- `runtime/lib/esr/resource/session/registry.ex` (PR-3)
- `runtime/lib/esr/session/name_index/registry.ex` (PR-3)
- `runtime/lib/esr/entity/agent/instance_registry.ex` (PR-4)
- `runtime/lib/esr/uri/compat.ex` (PR-5)

---

## PR-0: URI store + handler behaviour + Compat shim + CI gate

**Branch:** `feat/uri-store` off `origin/dev`.

### Task 0.1: Branch + Esr.Uri.Store skeleton

**Files:**
- Create: `runtime/lib/esr/uri/store.ex`

- [ ] **Step 1: Branch**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin dev && git checkout -b feat/uri-store origin/dev
```

- [ ] **Step 2: Write `Esr.Uri.Store` GenServer**

```elixir
defmodule Esr.Uri.Store do
  @moduledoc """
  Single-table URI store. Owns ETS `:esr_uri_store`.

  Row formats (tagged value):
    {uri :: String.t(), {:entity, kind :: atom(), data :: struct()}}
    {uri :: String.t(), {:alias,  canonical_uri :: String.t()}}

  Reads bypass GenServer (direct `:ets.lookup`).
  Writes serialize via GenServer.call to preserve alias→canonical
  1-hop invariant.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §8
  """

  use GenServer

  @table :esr_uri_store

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Direct ETS read; no GenServer round-trip. Returns raw row value."
  def lookup_raw(uri) when is_binary(uri) do
    case :ets.lookup(@table, uri) do
      [{^uri, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @doc "Write entity row."
  def put_entity(canonical_uri, kind, data) do
    GenServer.call(__MODULE__, {:put_entity, canonical_uri, kind, data})
  end

  @doc "Write alias row."
  def put_alias(alias_uri, canonical_uri) do
    GenServer.call(__MODULE__, {:put_alias, alias_uri, canonical_uri})
  end

  @doc "Delete row by URI."
  def delete(uri) do
    GenServer.call(__MODULE__, {:delete, uri})
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_entity, uri, kind, data}, _from, state) do
    :ets.insert(@table, {uri, {:entity, kind, data}})
    {:reply, :ok, state}
  end

  def handle_call({:put_alias, alias_uri, canonical_uri}, _from, state) do
    # Enforce: alias target must be a canonical entity (not another alias).
    case :ets.lookup(@table, canonical_uri) do
      [{^canonical_uri, {:entity, _, _}}] ->
        case :ets.lookup(@table, alias_uri) do
          [] ->
            :ets.insert(@table, {alias_uri, {:alias, canonical_uri}})
            {:reply, :ok, state}

          _ ->
            {:reply, {:error, :alias_exists}, state}
        end

      [{^canonical_uri, {:alias, _}}] ->
        {:reply, {:error, :target_is_alias}, state}

      [] ->
        {:reply, {:error, :canonical_missing}, state}
    end
  end

  def handle_call({:delete, uri}, _from, state) do
    :ets.delete(@table, uri)
    {:reply, :ok, state}
  end
end
```

- [ ] **Step 3: Add to supervision tree**

Edit `runtime/lib/esr/application.ex`. Find line ~96 (the `Esr.Entity.Agent.InstanceRegistry` entry) and add `Esr.Uri.Store` immediately before it:

```elixir
      Esr.Entity.Agent.StatefulRegistry,
      Esr.Uri.Store,                              # ← NEW (Task 0.1)
      Esr.Entity.Agent.InstanceRegistry,
```

- [ ] **Step 4: Smoke test**

```bash
cd runtime && iex -S mix
```

Run interactively:
```elixir
iex> Esr.Uri.Store.put_entity("esr://localhost/users/" <> UUID.uuid4(), :user, %Esr.Entity.User.Registry.User{username: "test"})
:ok
iex> Esr.Uri.Store.lookup_raw("esr://localhost/users/...")
{:ok, {:entity, :user, %Esr.Entity.User.Registry.User{...}}}
```

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/uri/store.ex runtime/lib/esr/application.ex
git commit -m "feat(uri): Esr.Uri.Store GenServer + ETS

PR-0 Task 0.1 of URI identity. Single ETS table :esr_uri_store with
tagged values ({:entity, kind, data} | {:alias, canonical}). Direct
read access; serialized writes for alias→canonical invariant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.2: `Esr.Uri.Plugin` behaviour + `Esr.Uri` facade

**Files:**
- Create: `runtime/lib/esr/uri/plugin.ex`
- Modify: `runtime/lib/esr/uri.ex` (add new public functions)

- [ ] **Step 1: Write plugin behaviour**

```elixir
defmodule Esr.Uri.Plugin do
  @moduledoc """
  Behaviour every plugin URI handler implements. Plugins declare URI
  subtrees in their manifest (`uri_subtrees:` block) and provide a
  handler module that implements these two callbacks.
  Spec §6.
  """

  @callback resolve(remaining_segments :: [String.t()])
              :: {:ok, canonical_uri :: String.t()} | :not_found | :invalid_format

  @callback alias(canonical_uri :: String.t(), args :: map())
              :: {:ok, alias_uri :: String.t()} | {:error, term()}
end
```

- [ ] **Step 2: Add `Esr.Uri.resolve/1` + sibling functions**

Open `runtime/lib/esr/uri.ex`. The file currently has only parser/builder code. Add a new section before the existing `defstruct` (or at the end of the module before the final `end`):

```elixir
  # ───────────────────────────────────────────────────────────────
  # URI STORE FACADE (spec 2026-05-12-uri-identity-design.md)
  # ───────────────────────────────────────────────────────────────
  # `Esr.Uri` serves two purposes:
  #   (1) `parse/1`, `build*/3` — pure parser/builder for esr:// grammar
  #   (2) `resolve/1`, `alias/2`, `put_entity/3`, `get_entity/1`, `delete/1`
  #       — store facade dispatching to `Esr.Uri.Store` GenServer.
  # `def alias/2` is legal Elixir despite `alias` being a kernel
  # directive (directive only at module-body level; here it's a
  # function definition).

  @uuid_re ~r/\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/

  @core_kinds ~w(users workspaces sessions agents)

  @spec resolve(String.t()) :: {:ok, canonical :: String.t()} | :not_found
  def resolve(uri) when is_binary(uri) do
    case Esr.Uri.Store.lookup_raw(uri) do
      {:ok, {:entity, _, _}} -> {:ok, uri}  # already canonical
      {:ok, {:alias, canonical}} -> {:ok, canonical}
      :not_found -> dispatch_to_plugin(uri)
    end
  end

  def resolve(_), do: :not_found

  @spec alias(canonical :: String.t(), alias_uri :: String.t())
          :: :ok | {:error, atom()}
  def alias(canonical_uri, alias_uri)
      when is_binary(canonical_uri) and is_binary(alias_uri) do
    Esr.Uri.Store.put_alias(alias_uri, canonical_uri)
  end

  @spec put_entity(String.t(), atom(), struct()) :: :ok | {:error, atom()}
  def put_entity(canonical_uri, kind, data) when is_atom(kind) and is_struct(data) do
    Esr.Uri.Store.put_entity(canonical_uri, kind, data)
  end

  @spec get_entity(String.t()) :: {:ok, atom(), struct()} | :not_found
  def get_entity(uri) when is_binary(uri) do
    with {:ok, canonical} <- resolve(uri),
         {:ok, {:entity, kind, data}} <- Esr.Uri.Store.lookup_raw(canonical) do
      {:ok, kind, data}
    else
      _ -> :not_found
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(uri) when is_binary(uri) do
    Esr.Uri.Store.delete(uri)
  end

  # Dispatch a non-canonical, non-stored URI to a plugin handler if its
  # prefix is registered.
  defp dispatch_to_plugin(uri) do
    case parse(uri) do
      {:ok, %{segments: [kind, plugin_seg | rest]}}
          when kind in @core_kinds and plugin_seg != "by-name" and plugin_seg != "by-uuid" ->
        handlers = :persistent_term.get({__MODULE__, :plugin_handlers}, %{})

        case Map.fetch(handlers, kind <> "/" <> plugin_seg) do
          {:ok, handler_mod} ->
            case handler_mod.resolve(rest) do
              {:ok, canonical} -> {:ok, canonical}
              _ -> :not_found
            end

          :error ->
            :not_found
        end

      _ ->
        :not_found
    end
  end
```

- [ ] **Step 3: Smoke test in iex**

```bash
cd runtime && iex -S mix
```

```elixir
iex> uri = "esr://localhost/users/" <> UUID.uuid4()
iex> Esr.Uri.put_entity(uri, :user, %Esr.Entity.User.Registry.User{username: "alice"})
:ok
iex> Esr.Uri.alias(uri, "esr://localhost/users/by-name/alice")
:ok
iex> Esr.Uri.resolve("esr://localhost/users/by-name/alice")
{:ok, "esr://localhost/users/..."}
iex> Esr.Uri.get_entity("esr://localhost/users/by-name/alice")
{:ok, :user, %Esr.Entity.User.Registry.User{username: "alice"}}
```

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/uri.ex runtime/lib/esr/uri/plugin.ex
git commit -m "feat(uri): Esr.Uri facade + Esr.Uri.Plugin behaviour

PR-0 Task 0.2. Adds resolve/1, alias/2, put_entity/3, get_entity/1,
delete/1 to Esr.Uri (alongside existing parser). New Esr.Uri.Plugin
behaviour for plugin handler callbacks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.3: Unit tests for `Esr.Uri`

**Files:**
- Create: `runtime/test/esr/uri_store_test.exs`

- [ ] **Step 1: Write tests**

```elixir
defmodule Esr.UriStoreTest do
  use ExUnit.Case, async: false

  alias Esr.Entity.User.Registry.User

  setup do
    # Each test gets a fresh table state.
    :ets.delete_all_objects(:esr_uri_store)
    :ok
  end

  describe "put_entity + lookup_raw" do
    test "stores entity row" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      data = %User{username: "alice"}
      assert :ok = Esr.Uri.put_entity(uri, :user, data)
      assert {:ok, {:entity, :user, ^data}} = Esr.Uri.Store.lookup_raw(uri)
    end
  end

  describe "alias/2" do
    test "happy: alias points to canonical entity" do
      uuid = UUID.uuid4()
      canonical = "esr://localhost/users/" <> uuid
      :ok = Esr.Uri.put_entity(canonical, :user, %User{username: "alice"})

      assert :ok = Esr.Uri.alias(canonical, "esr://localhost/users/by-name/alice")
      assert {:ok, ^canonical} = Esr.Uri.resolve("esr://localhost/users/by-name/alice")
    end

    test ":canonical_missing when target doesn't exist" do
      assert {:error, :canonical_missing} =
               Esr.Uri.alias("esr://localhost/users/nonexistent-uuid", "esr://localhost/users/by-name/x")
    end

    test ":target_is_alias when target is an alias" do
      canonical = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(canonical, :user, %User{username: "alice"})
      :ok = Esr.Uri.alias(canonical, "esr://localhost/users/by-name/alice")

      # Try to chain alias → alias (should be rejected)
      assert {:error, :target_is_alias} =
               Esr.Uri.alias("esr://localhost/users/by-name/alice", "esr://localhost/users/by-name/alice2")
    end

    test ":alias_exists when alias is already taken" do
      canonical1 = "esr://localhost/users/" <> UUID.uuid4()
      canonical2 = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(canonical1, :user, %User{username: "alice"})
      :ok = Esr.Uri.put_entity(canonical2, :user, %User{username: "bob"})

      :ok = Esr.Uri.alias(canonical1, "esr://localhost/users/by-name/alice")
      assert {:error, :alias_exists} = Esr.Uri.alias(canonical2, "esr://localhost/users/by-name/alice")
    end
  end

  describe "resolve/1" do
    test "canonical URI returns itself" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(uri, :user, %User{username: "x"})
      assert {:ok, ^uri} = Esr.Uri.resolve(uri)
    end

    test "alias URI returns canonical" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(uri, :user, %User{username: "x"})
      :ok = Esr.Uri.alias(uri, "esr://localhost/users/by-name/x")
      assert {:ok, ^uri} = Esr.Uri.resolve("esr://localhost/users/by-name/x")
    end

    test ":not_found for unknown URI" do
      assert :not_found = Esr.Uri.resolve("esr://localhost/users/nobody")
    end
  end

  describe "get_entity/1" do
    test "via canonical" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      data = %User{username: "alice"}
      :ok = Esr.Uri.put_entity(uri, :user, data)
      assert {:ok, :user, ^data} = Esr.Uri.get_entity(uri)
    end

    test "via alias (chain)" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      data = %User{username: "alice"}
      :ok = Esr.Uri.put_entity(uri, :user, data)
      :ok = Esr.Uri.alias(uri, "esr://localhost/users/by-name/alice")
      assert {:ok, :user, ^data} = Esr.Uri.get_entity("esr://localhost/users/by-name/alice")
    end
  end

  describe "delete/1" do
    test "removes row" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(uri, :user, %User{username: "x"})
      assert :ok = Esr.Uri.delete(uri)
      assert :not_found = Esr.Uri.resolve(uri)
    end
  end
end
```

- [ ] **Step 2: Run + verify pass**

```bash
cd runtime && mix test test/esr/uri_store_test.exs
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/uri_store_test.exs
git commit -m "test(uri): per-API unit tests for Esr.Uri facade

PR-0 Task 0.3. Covers put_entity / alias / resolve / get_entity /
delete with happy paths + error tuples (alias_exists, target_is_alias,
canonical_missing).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.4: `Esr.Uri.Compat` migration shim

**Files:**
- Create: `runtime/lib/esr/uri/compat.ex`

- [ ] **Step 1: Write the compat module**

```elixir
defmodule Esr.Uri.Compat do
  @moduledoc """
  MIGRATION SHIM (2026-05-12 → ~2026-05-13). DELETED in PR-5.

  Return-shape-preserving wrappers for old User.Registry / Workspace.Registry
  / Session.NameIndex / InstanceRegistry APIs, internally call Esr.Uri.*.

  Lets PR-1..PR-4 do mechanical sed-replacement instead of touching
  every caller's logic.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §10
  Plan: docs/superpowers/plans/2026-05-12-uri-identity-plan.md PR-0
  """

  # ────────────────────────────────────────────────────────────
  # User wrappers
  # ────────────────────────────────────────────────────────────

  @doc """
  Replaces Esr.Entity.User.NameIndex.id_for_name/1 AND /2 (the /2 form
  takes an ETS table atom which Compat ignores — table is implicit via
  the URI store). Return shape unchanged.
  """
  @spec uuid_for_user_name(String.t()) :: {:ok, String.t()} | :not_found
  def uuid_for_user_name(name) when is_binary(name) do
    case Esr.Uri.resolve("esr://localhost/users/by-name/" <> name) do
      {:ok, "esr://localhost/users/" <> uuid} -> {:ok, uuid}
      :not_found -> :not_found
    end
  end

  @spec uuid_for_user_name(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def uuid_for_user_name(_table, name), do: uuid_for_user_name(name)

  @doc "Replaces Esr.Entity.User.NameIndex.name_for_id/1 and /2 (table arg ignored)."
  @spec name_for_user_uuid(String.t()) :: {:ok, String.t()} | :not_found
  def name_for_user_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/users/" <> uuid) do
      {:ok, :user, %{username: name}} -> {:ok, name}
      :not_found -> :not_found
    end
  end

  @spec name_for_user_uuid(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def name_for_user_uuid(_table, uuid), do: name_for_user_uuid(uuid)

  @doc "Replaces Esr.Entity.User.Registry.lookup_by_feishu_id/1. Returns username."
  @spec username_for_feishu_id(String.t()) :: {:ok, String.t()} | :not_found
  def username_for_feishu_id(ou_id) when is_binary(ou_id) do
    case Esr.Uri.resolve("esr://localhost/users/feishu/" <> ou_id) do
      {:ok, "esr://localhost/users/" <> uuid} -> name_for_user_uuid(uuid)
      :not_found -> :not_found
    end
  end

  @doc "Replaces Esr.Entity.User.Registry.get_by_id/1."
  @spec user_by_uuid(String.t()) :: {:ok, struct()} | :not_found
  def user_by_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/users/" <> uuid) do
      {:ok, :user, data} -> {:ok, data}
      :not_found -> :not_found
    end
  end

  @doc "Replaces Esr.Entity.User.Registry.get/1 (by username)."
  @spec user_by_name(String.t()) :: {:ok, struct()} | :not_found
  def user_by_name(name) when is_binary(name) do
    case Esr.Uri.get_entity("esr://localhost/users/by-name/" <> name) do
      {:ok, :user, data} -> {:ok, data}
      :not_found -> :not_found
    end
  end

  @doc "Replaces Esr.Entity.User.Registry.get_default_workspace/1 (takes username, returns ws_id)."
  @spec default_workspace_for_user_name(String.t()) :: {:ok, String.t()} | :not_found
  def default_workspace_for_user_name(name) when is_binary(name) do
    case user_by_name(name) do
      {:ok, %{default_workspace_id: id}} when is_binary(id) and id != "" -> {:ok, id}
      _ -> :not_found
    end
  end

  # ────────────────────────────────────────────────────────────
  # Workspace wrappers
  # ────────────────────────────────────────────────────────────

  @doc "Replaces Esr.Resource.Workspace.NameIndex.id_for_name/2."
  @spec uuid_for_workspace_name(String.t()) :: {:ok, String.t()} | :not_found
  def uuid_for_workspace_name(name) when is_binary(name) do
    case Esr.Uri.resolve("esr://localhost/workspaces/by-name/" <> name) do
      {:ok, "esr://localhost/workspaces/" <> uuid} -> {:ok, uuid}
      :not_found -> :not_found
    end
  end

  @doc "Replaces Esr.Resource.Workspace.NameIndex.name_for_id/2."
  @spec name_for_workspace_uuid(String.t()) :: {:ok, String.t()} | :not_found
  def name_for_workspace_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/workspaces/" <> uuid) do
      {:ok, :workspace, %{name: name}} -> {:ok, name}
      :not_found -> :not_found
    end
  end

  @doc "Replaces Esr.Resource.Workspace.Registry.get_by_id/1."
  @spec workspace_by_uuid(String.t()) :: {:ok, struct()} | :not_found
  def workspace_by_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/workspaces/" <> uuid) do
      {:ok, :workspace, data} -> {:ok, data}
      :not_found -> :not_found
    end
  end

  @doc "Replaces Esr.Resource.Workspace.Registry.workspace_for_chat/2 (returns name)."
  @spec workspace_name_for_chat(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def workspace_name_for_chat(chat_id, app_id)
      when is_binary(chat_id) and is_binary(app_id) do
    case Esr.Uri.resolve("esr://localhost/workspaces/by-chat/#{chat_id}/#{app_id}") do
      {:ok, "esr://localhost/workspaces/" <> uuid} -> name_for_workspace_uuid(uuid)
      :not_found -> :not_found
    end
  end

  # ────────────────────────────────────────────────────────────
  # Session + Agent wrappers (Task 0.4b — added when PR-3/PR-4 lands)
  # ────────────────────────────────────────────────────────────

  # Stubs in PR-0; filled in when PR-3/PR-4 ships. (Keeps PR-0 LOC focused.)
end
```

- [ ] **Step 2: Commit**

```bash
git add runtime/lib/esr/uri/compat.ex
git commit -m "feat(uri): Esr.Uri.Compat migration shim (deleted in PR-5)

PR-0 Task 0.4. Return-shape-preserving wrappers for the User and
Workspace domain old APIs. Lets PR-1/PR-2 do mechanical sed-replace
instead of touching caller logic. Session/Agent wrappers added in
later PRs to keep PR-0 LOC focused.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.5: Manifest `uri_subtrees:` parsing + feishu UriHandler

**Files:**
- Modify: `runtime/lib/esr/plugin/manifest.ex` (parse `uri_subtrees:` block)
- Modify: `runtime/lib/esr/plugin/loader.ex` (register prefix→handler at boot)
- Create: `runtime/lib/esr/plugins/feishu/uri_handler.ex`
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml` (add `uri_subtrees:`)

- [ ] **Step 1: Add `uri_subtrees:` to `%Esr.Plugin.Manifest{}` struct + parser**

Read `runtime/lib/esr/plugin/manifest.ex:41-51` to see the existing `channels:` / `agent_kinds:` struct fields. Add a sibling field `uri_subtrees: []`. Add `parse_uri_subtrees/1` private helper following the `parse_channels/1` pattern (manifest.ex:136-137 area). Wire into the `parse_raw/1` `with` chain.

```elixir
# Add to defstruct around line 41-51:
defstruct [
  ...,
  channels: [],
  agent_kinds: [],
  uri_subtrees: []   # ← NEW
]

# Add a private helper:
defp parse_uri_subtrees(raw) when is_list(raw) do
  Enum.map(raw, fn entry ->
    case entry do
      %{"prefix" => prefix, "handler" => handler_str}
          when is_binary(prefix) and is_binary(handler_str) ->
        %{prefix: prefix, handler: String.to_existing_atom("Elixir." <> handler_str)}

      _ ->
        raise ArgumentError, "uri_subtrees entry malformed: #{inspect(entry)}"
    end
  end)
end

defp parse_uri_subtrees(_), do: []

# Add to parse_raw/1 `with`-chain (near other parse_* calls around line 136):
uri_subtrees <- parse_uri_subtrees(Map.get(raw, "uri_subtrees", [])),
```

- [ ] **Step 2: Register handlers at plugin load**

Modify `runtime/lib/esr/plugin/loader.ex`. Find where the manifest's `channels` / `agent_kinds` get registered (grep `start_plugin` or `register_*`). Add similar registration for `uri_subtrees`:

```elixir
# Inside start_plugin/2 or a sibling helper, after registering channels/agent_kinds:
defp register_uri_subtrees(%Manifest{uri_subtrees: subtrees}) do
  current = :persistent_term.get({Esr.Uri, :plugin_handlers}, %{})

  new = Enum.reduce(subtrees, current, fn %{prefix: prefix, handler: handler}, acc ->
    Map.put(acc, prefix, handler)
  end)

  :persistent_term.put({Esr.Uri, :plugin_handlers}, new)
  :ok
end
```

Call this from the plugin-startup hook chain.

- [ ] **Step 3: Write `Esr.Plugins.Feishu.UriHandler`**

```elixir
defmodule Esr.Plugins.Feishu.UriHandler do
  @moduledoc """
  Feishu plugin URI handler. Owns the `esr://localhost/users/feishu/<ou_xxx>` subtree.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §6
  Manifest entry: runtime/lib/esr/plugins/feishu/manifest.yaml `uri_subtrees:`
  """

  @behaviour Esr.Uri.Plugin

  @impl Esr.Uri.Plugin
  def resolve(["ou_" <> _ = ou_id]) do
    # Lookup via the migration-period shim. Once User domain migrates
    # to URI (PR-1), this can call Esr.Uri.resolve("esr://localhost/users/by-name/...")
    # directly.
    with {:ok, username} <- Esr.Uri.Compat.username_for_feishu_id(ou_id),
         {:ok, uuid} <- Esr.Uri.Compat.uuid_for_user_name(username) do
      {:ok, "esr://localhost/users/" <> uuid}
    else
      _ -> :not_found
    end
  end

  def resolve(_), do: :invalid_format

  @impl Esr.Uri.Plugin
  def alias(canonical_user_uri, %{ou_id: ou_id})
      when is_binary(canonical_user_uri) and is_binary(ou_id) do
    alias_uri = "esr://localhost/users/feishu/" <> ou_id

    case Esr.Uri.alias(canonical_user_uri, alias_uri) do
      :ok -> {:ok, alias_uri}
      {:error, _} = err -> err
    end
  end
end
```

Note: this handler today still calls `Esr.Uri.Compat.username_for_feishu_id/1`, which internally goes through the User.Registry. There's a small bootstrapping ordering — PR-0's handler works against the OLD registry (because URI store is empty for users at PR-0). After PR-1 migrates users into the URI store, the handler keeps working unchanged because Compat wrappers transparently switch their backing.

- [ ] **Step 4: Add `uri_subtrees:` to feishu manifest**

Edit `runtime/lib/esr/plugins/feishu/manifest.yaml`. Add a top-level block (additive):

```yaml
uri_subtrees:
  - prefix: "users/feishu"
    handler: Esr.Plugins.Feishu.UriHandler
```

- [ ] **Step 5: Compile + smoke test**

```bash
cd runtime && mix compile --warnings-as-errors
```

Expected: clean compile.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/plugin/manifest.ex runtime/lib/esr/plugin/loader.ex \
        runtime/lib/esr/plugins/feishu/uri_handler.ex \
        runtime/lib/esr/plugins/feishu/manifest.yaml
git commit -m "feat(uri): plugin uri_subtrees manifest + feishu UriHandler

PR-0 Task 0.5. Manifest parser learns uri_subtrees: block; Loader
registers prefix→handler at boot via :persistent_term. Feishu handler
owns esr://localhost/users/feishu/<ou_xxx>; calls Esr.Uri.Compat internally
during the migration window.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.6: `mix esr.check_uri_drift` CI gate

**Files:**
- Create: `runtime/lib/mix/tasks/esr/check_uri_drift.ex`
- Create: `runtime/priv/uri-drift-baseline.txt` (initial baseline)
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the mix task**

```elixir
defmodule Mix.Tasks.Esr.CheckUriDrift do
  @moduledoc """
  CI gate: ban old identity-lookup API calls outside designated handler files.

  Allowed file paths (path-pattern; new files CAN'T be added to "whitelist"):
    runtime/lib/esr/uri/**/*.ex
    runtime/lib/esr/plugins/*/uri_handler.ex
    runtime/lib/esr/uri/file_loader.ex

  Spec §10 (L1' path-pattern gate).
  """

  use Mix.Task

  @shortdoc "Check for old-API uses outside allowed URI handler files"

  @banned_patterns ~r/(?:lookup_by_feishu_id|UserRegistry\.get_default_workspace|UserRegistry\.get_by_id|UserRegistry\.get_by_username|NameIndex\.id_for_name|workspace_for_chat|InstanceRegistry\.primary)/

  @allowed_path_re ~r{runtime/lib/esr/uri/.*\.ex|runtime/lib/esr/plugins/[^/]+/uri_handler\.ex|runtime/lib/esr/uri/file_loader\.ex}

  @baseline_path "priv/uri-drift-baseline.txt"

  @impl Mix.Task
  def run(_args) do
    violations = scan()

    baseline = read_baseline()

    cond do
      length(violations) > baseline ->
        Mix.shell().error("uri-drift CI gate: count #{length(violations)} > baseline #{baseline}")
        Mix.shell().error("Violations:")
        Enum.each(violations, fn {file, line} -> Mix.shell().error("  #{file}:#{line}") end)
        Mix.shell().error("Old API calls outside allowed paths are banned. Migrate to Esr.Uri.* instead.")
        exit({:shutdown, 1})

      length(violations) < baseline ->
        Mix.shell().info("uri-drift: count #{length(violations)} < baseline #{baseline}. Ratcheting baseline DOWN — update priv/uri-drift-baseline.txt and commit.")
        :ok

      true ->
        Mix.shell().info("uri-drift: clean (#{length(violations)} == baseline)")
        :ok
    end
  end

  defp scan do
    Path.wildcard("runtime/lib/esr/**/*.ex")
    |> Enum.reject(&Regex.match?(@allowed_path_re, &1))
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(@banned_patterns, line) end)
      |> Enum.map(fn {_, idx} -> {file, idx} end)
    end)
  end

  defp read_baseline do
    case File.read(@baseline_path) do
      {:ok, content} ->
        content |> String.trim() |> String.to_integer()

      {:error, :enoent} ->
        0
    end
  end
end
```

- [ ] **Step 2: Initialize baseline file**

Capture current count and write to priv:

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
COUNT=$(grep -rE "lookup_by_feishu_id|UserRegistry\.get_default_workspace|UserRegistry\.get_by_id|UserRegistry\.get_by_username|NameIndex\.id_for_name|workspace_for_chat|InstanceRegistry\.primary" runtime/lib/ \
  | grep -vE "runtime/lib/esr/uri/.*\.ex|runtime/lib/esr/plugins/[^/]+/uri_handler\.ex" \
  | wc -l | tr -d ' ')
echo "$COUNT" > runtime/priv/uri-drift-baseline.txt
cat runtime/priv/uri-drift-baseline.txt
```

Expected: ~300+ lines (the lib-only subset of the 387 total).

- [ ] **Step 3: Add CI step to `.github/workflows/ci.yml`**

Find the existing `mix esr.check_command_docs` step (the unified-grammar drift gate). Add a sibling step right after it:

```yaml
      - name: Check URI drift
        run: cd runtime && mix esr.check_uri_drift
```

- [ ] **Step 4: Test locally**

```bash
cd runtime && mix esr.check_uri_drift
```

Expected: `uri-drift: clean (<N> == baseline)` (where N matches baseline file).

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/mix/tasks/esr/check_uri_drift.ex runtime/priv/uri-drift-baseline.txt .github/workflows/ci.yml
git commit -m "feat(ci): mix esr.check_uri_drift L1' path-pattern gate

PR-0 Task 0.6. Path-pattern enforcement: old identity APIs allowed
ONLY in runtime/lib/esr/uri/** and runtime/lib/esr/plugins/*/uri_handler.ex.
Ratchet: count > baseline = FAIL; count < baseline = pass (update
baseline). Initial baseline reflects PR-0 state (all 387 sites still
present since no migration yet).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 0.7: PR-0 push + admin-merge

- [ ] **Step 1: Feishu heads-up + push**

```bash
git push -u origin feat/uri-store
gh pr create --base dev --head feat/uri-store \
  --title "PR-0: URI identity infrastructure (store + handler + Compat + CI gate)" \
  --body "Spec docs/superpowers/specs/2026-05-12-uri-identity-design.md PR-0. No caller migration yet. Lands: Esr.Uri.Store + Esr.Uri facade + Esr.Uri.Plugin behaviour + Esr.Uri.Compat shim + feishu UriHandler + mix esr.check_uri_drift CI gate. Baseline: ~300 lib-side call sites."
gh pr merge --admin --squash --delete-branch
```

- [ ] **Step 2: Verify on dev**

```bash
git checkout dev && git pull --ff-only origin dev
mix test test/esr/uri_store_test.exs
```

---

## PR-1: User domain migration

**Branch:** `feat/uri-migrate-user` off `origin/dev` (after PR-0 merged).

**Scope:** 115 call sites for `Esr.Entity.User.Registry` + 21 for `Esr.Entity.User.NameIndex`. Delete both modules. Rewrite `Esr.Entity.User.FileLoader` to populate URI store.

### Task 1.1: Add Session + Agent stubs to Compat (forward-compat)

Add empty wrappers for Session + Agent to Compat module (filled in PR-3/PR-4). Keeps PR-1's mechanical replacements from referencing functions that don't exist yet — actually this is unneeded for PR-1 since PR-1 only touches User calls. Skip.

### Task 1.2: Inventory User-domain call sites via LSP

- [ ] **Step 1: Use LSP find-references to discover all callers**

If the implementer's IDE has Elixir LSP active (ElixirLS / Lexical), use "Find All References" on each of:
- `Esr.Entity.User.Registry.get_by_id/1`
- `Esr.Entity.User.Registry.lookup_by_feishu_id/1`
- `Esr.Entity.User.Registry.get/1`
- `Esr.Entity.User.Registry.get_default_workspace/1`
- `Esr.Entity.User.Registry.set_default_workspace/2`
- `Esr.Entity.User.Registry.load_snapshot_with_uuids/2`
- `Esr.Entity.User.NameIndex.id_for_name/2`
- `Esr.Entity.User.NameIndex.name_for_id/2`

Save results to `/tmp/user-domain-callers.txt`. This is more accurate than grep because LSP follows alias / import / unquote.

If LSP isn't available, fall back to grep:

```bash
grep -rn "User\.Registry\.\(get_by_id\|lookup_by_feishu_id\|get\|get_default_workspace\)\|User\.NameIndex\.\(id_for_name\|name_for_id\)" runtime/lib/ runtime/test/ \
  > /tmp/user-domain-callers.txt
wc -l /tmp/user-domain-callers.txt
```

Expected: ~136 lines (115 + 21).

### Task 1.3: Mechanical sed replacement (fat-function-first pattern)

**Migration technique** (per user 2026-05-12 — applies to PR-1 / PR-2 / PR-3 / PR-4):

The Compat wrappers in PR-0 were written to call `Esr.Uri.resolve/1` directly. That introduces TWO changes in one rename: (a) function name change, (b) backing-store change (registry → URI store). If tests fail post-rename, hard to tell which caused it.

**Better approach — "fat function, then simplify":**

1. **In PR-0 (already done)**: each `Esr.Uri.Compat.*` wrapper directly calls `Esr.Uri.resolve/1`. This is the "skinny" form. Wrappers are syntactic redirects only — internally they don't preserve the old code.

2. **For this PR (PR-1) — instead, rewrite wrappers temporarily**: BEFORE doing the rename in Task 1.3, edit `Esr.Uri.Compat.uuid_for_user_name/1` etc. to **mechanically inline the OLD `User.NameIndex.id_for_name/1` body** (and other functions), pulling in any necessary helpers. The wrapper becomes a "fat function" carrying all the legacy logic verbatim, callable under the new name.

3. **Then sed-rename** all call sites to point at the fat Compat wrappers. Run full test suite. Because the body is byte-identical to the old code (just renamed), tests SHOULD all pass — any failure indicates the rename itself broke something (e.g. an alias missed), not a logic change.

4. **After green CI on the rename**, return to Compat module and **simplify each wrapper** to delegate to `Esr.Uri.resolve/1`. This is now an isolated behavior change with its own test loop. If something fails, you know it's the simplification.

The principle: never do "rename + behavior change" in one PR. Decompose into two safe steps.

For PR-1 specifically: Task 1.3 below assumes the simpler "skinny Compat" form. If issues arise (tests fail unexpectedly), revert to the fat-then-simplify pattern: copy the registry function bodies into Compat verbatim first, sed-rename, verify green, THEN simplify.

#### Task 1.3 steps (skinny Compat — try this first)

**Important — handle BOTH fully-qualified AND short-form aliased call sites.** Many files do `alias Esr.Entity.User.Registry, as: UserRegistry` then call `UserRegistry.get(...)`. The first sed pass only catches `Esr.Entity.User.Registry.*`; do a second pass for short-form aliases per file. Concretely: grep files containing `alias Esr.Entity.User.Registry` and run a sed on those files for the short-form (`UserRegistry.get_by_id` → `Esr.Uri.Compat.user_by_uuid`, etc.). Same approach for `NameIndex` (which has both User.NameIndex and Workspace.NameIndex aliases — keep them disambiguated by which alias is declared in each file).

- [ ] **Step 1: sed-replace each call site mapping**

Run these sed commands against `runtime/lib/` and `runtime/test/`:

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev/runtime

# Map old API → Esr.Uri.Compat wrapper (return shape preserved)
find lib/esr test/esr -name "*.ex*" -exec sed -i '' \
  -e 's/Esr\.Entity\.User\.Registry\.lookup_by_feishu_id/Esr.Uri.Compat.username_for_feishu_id/g' \
  -e 's/Esr\.Entity\.User\.Registry\.get_by_id/Esr.Uri.Compat.user_by_uuid/g' \
  -e 's/Esr\.Entity\.User\.Registry\.get_default_workspace/Esr.Uri.Compat.default_workspace_for_user_name/g' \
  -e 's/Esr\.Entity\.User\.NameIndex\.id_for_name/Esr.Uri.Compat.uuid_for_user_name/g' \
  -e 's/Esr\.Entity\.User\.NameIndex\.name_for_id/Esr.Uri.Compat.name_for_user_uuid/g' \
  {} \;
```

Note: `User.Registry.get/1` (by username) is a name collision (`get` is too generic). Skip it; handle manually in Step 2.

- [ ] **Step 2: Manual fix for ambiguous matches**

`Esr.Entity.User.Registry.get/1` (by username) doesn't have a safe regex match (`get` is too common). Find call sites manually:

```bash
grep -rn "User\.Registry\.get(" runtime/lib/ runtime/test/ \
  | grep -v "get_by_id\|get_default_workspace"
```

For each result, replace `User.Registry.get(name)` → `Esr.Uri.Compat.user_by_name(name)` by hand (Edit tool).

Also: `load_snapshot_with_uuids/2` and `set_default_workspace/2` are MUTATORS, not lookups — these are NOT migrated in this PR. They stay on the old API (PR-1's User.FileLoader rewrite in Task 1.4 will replace them with `Esr.Uri.put_entity/3` calls at the FileLoader level).

- [ ] **Step 3: Compile + verify**

```bash
cd runtime && mix compile --warnings-as-errors
```

Expected: clean compile. If any unresolved `Esr.Uri.Compat.X` reference, double-check the wrapper exists in `runtime/lib/esr/uri/compat.ex`.

- [ ] **Step 4: Run full test suite**

```bash
cd runtime && mix test
```

Expected: tests pass. Caps test in particular — chat-side cap-check should now succeed via the new chain (regression from spec §2).

- [ ] **Step 5: Commit (intermediate; before FileLoader rewrite)**

```bash
git add runtime/
git commit -m "refactor(uri): migrate User domain callers to Esr.Uri.Compat

PR-1 Task 1.3. 136 call sites replaced via sed against Esr.Uri.Compat
wrappers (same return shapes). Mutators (load_snapshot, set_default)
stay on old API; FileLoader rewrite is Task 1.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 1.4: Rewrite `Esr.Entity.User.FileLoader` → URI store

**Files:**
- Modify: `runtime/lib/esr/entity/user/file_loader.ex`

- [ ] **Step 1: Read current FileLoader**

```bash
cat runtime/lib/esr/entity/user/file_loader.ex
```

Note where it calls `Registry.load_snapshot_with_uuids/2` and `Registry.set_default_workspace/2` (the only mutators).

- [ ] **Step 2: Replace the registry mutator calls with URI store calls**

Each `User` row gets:
- `Esr.Uri.put_entity("esr://localhost/users/" <> uuid, :user, %User{...})`
- `Esr.Uri.alias("esr://localhost/users/" <> uuid, "esr://localhost/users/by-name/" <> username)` for the by-name alias
- For each `feishu_id` in the user's `feishu_ids` list: `Esr.Uri.alias("esr://localhost/users/" <> uuid, "esr://localhost/users/feishu/" <> ou_id)`
- `default_workspace_id` is stored INSIDE the User struct in the entity row, no separate call needed

```elixir
# Sketch — adapt to actual FileLoader code structure:
defp populate_uri_store(snapshot_with_uuids) do
  Enum.each(snapshot_with_uuids, fn {username, %User{} = user, uuid} ->
    canonical = "esr://localhost/users/" <> uuid
    :ok = Esr.Uri.put_entity(canonical, :user, user)
    :ok = Esr.Uri.alias(canonical, "esr://localhost/users/by-name/" <> username)

    Enum.each(user.feishu_ids, fn ou_id ->
      :ok = Esr.Uri.alias(canonical, "esr://localhost/users/feishu/" <> ou_id)
    end)
  end)
end
```

Adjust to match real FileLoader function shape.

- [ ] **Step 3: Compile + boot test**

```bash
cd runtime && mix compile
iex -S mix
```

In iex, verify a user from users.yaml is now resolvable:

```elixir
iex> Esr.Uri.resolve("esr://localhost/users/by-name/admin")  # or whatever username
{:ok, "esr://localhost/users/<uuid>"}
```

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/entity/user/file_loader.ex
git commit -m "feat(uri): User.FileLoader populates URI store

PR-1 Task 1.4. FileLoader now writes to Esr.Uri.Store via
put_entity/3 + alias/2 instead of Registry mutators. Each user
gets: canonical esr://localhost/users/<uuid>, by-name alias, per-feishu_id
aliases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

### Task 1.5: Delete `Esr.Entity.User.Registry` + `User.NameIndex`

**Files:**
- Delete: `runtime/lib/esr/entity/user/registry.ex`
- Delete: `runtime/lib/esr/entity/user/name_index.ex`
- Modify: `runtime/lib/esr/application.ex` (remove from supervision tree)

- [ ] **Step 1: Move the `User` struct out of `Registry` BEFORE deletion**

The struct `Esr.Entity.User.Registry.User` is referenced by entity rows in the URI store. Don't lose it. Move it to a standalone module:

```bash
# Create new home for the struct:
cat > runtime/lib/esr/entity/user/struct.ex <<'EOF'
defmodule Esr.Entity.User.Struct do
  @moduledoc """
  Migrated from Esr.Entity.User.Registry.User (2026-05-12, PR-1).
  Stays in URI store entity rows.
  """
  defstruct [:username, feishu_ids: [], default_workspace_id: nil]
end
EOF
```

Then update all references from `%Esr.Entity.User.Registry.User{}` to `%Esr.Entity.User.Struct{}`:

```bash
find runtime/lib runtime/test -name "*.ex*" -exec sed -i '' \
  's/Esr\.Entity\.User\.Registry\.User/Esr.Entity.User.Struct/g' {} \;
```

- [ ] **Step 2: Remove Registry + NameIndex from supervision tree**

Edit `runtime/lib/esr/application.ex`. Find and remove `Esr.Entity.User.Registry` and `Esr.Entity.User.NameIndex` from the children list.

- [ ] **Step 3: Delete the modules**

```bash
git rm runtime/lib/esr/entity/user/registry.ex
git rm runtime/lib/esr/entity/user/name_index.ex
```

- [ ] **Step 4: Compile — expect zero callers**

```bash
cd runtime && mix compile --warnings-as-errors
```

Expected: clean compile. If any caller remains, error reveals it; fix by replacing with Compat wrapper or `Esr.Uri.*` call.

- [ ] **Step 5: Update CI gate baseline**

```bash
COUNT=$(grep -rE "lookup_by_feishu_id|UserRegistry\.get_default_workspace|UserRegistry\.get_by_id|UserRegistry\.get_by_username|NameIndex\.id_for_name|workspace_for_chat|InstanceRegistry\.primary" runtime/lib/ \
  | grep -vE "runtime/lib/esr/uri/.*\.ex|runtime/lib/esr/plugins/[^/]+/uri_handler\.ex" \
  | wc -l | tr -d ' ')
echo "$COUNT" > runtime/priv/uri-drift-baseline.txt
```

Expected: baseline drops by ~136 (the User domain count).

- [ ] **Step 6: Run full test suite**

```bash
cd runtime && mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit + push + admin-merge**

```bash
git add -A
git commit -m "feat(uri): delete User.Registry + User.NameIndex (PR-1 cleanup)

PR-1 Task 1.5. All callers migrated; Registry + NameIndex are dead
code. User struct moved to Esr.Entity.User.Struct. Baseline drops to
~190 (from ~326 initial).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
git push -u origin feat/uri-migrate-user
gh pr create --base dev --head feat/uri-migrate-user \
  --title "PR-1: User domain migration to URI store" \
  --body "Migrates 136 call sites + deletes User.Registry + User.NameIndex. FileLoader rewritten to populate URI store. Baseline drops from ~326 to ~190."
gh pr merge --admin --squash --delete-branch
```

---

## PR-2: Workspace domain migration

**Branch:** `feat/uri-migrate-workspace` off `origin/dev` (after PR-1 merged).

**Scope:** 94 Workspace.Registry + 38 Workspace.NameIndex = 132 sites. Delete both modules.

### Task 2.1-2.5: Same pattern as PR-1

Follow PR-1 task structure exactly, substituting:
- Modules: `Esr.Resource.Workspace.Registry` + `Esr.Resource.Workspace.NameIndex`
- Sed mappings:
  - `Esr.Resource.Workspace.Registry.get_by_id` → `Esr.Uri.Compat.workspace_by_uuid`
  - `Esr.Resource.Workspace.Registry.workspace_for_chat` → `Esr.Uri.Compat.workspace_name_for_chat`
  - `Esr.Resource.Workspace.NameIndex.id_for_name` → `Esr.Uri.Compat.uuid_for_workspace_name`
  - `Esr.Resource.Workspace.NameIndex.name_for_id` → `Esr.Uri.Compat.name_for_workspace_uuid`
- FileLoader: `Esr.Resource.Workspace.FileLoader` → call `Esr.Uri.put_entity/3` + `Esr.Uri.alias/2` per workspace (canonical UUID + by-name alias + per-chat-binding alias)
- Workspace.Struct stays in `runtime/lib/esr/resource/workspace/struct.ex` (already there, no move needed)

Mutators kept public on Workspace.Registry until full migration — `put/1`, `delete_by_id/1`, `rename/2`, `bind_session/2`, etc. Actually the whole Workspace.Registry is being deleted, so these need new homes. Likely move into `Esr.Resource.Workspace.Mutator` module (private), or have FileLoader/commands call `Esr.Uri.put_entity/3` directly.

Baseline target: drops from ~190 to ~58.

---

## PR-3: Session domain migration

**Branch:** `feat/uri-migrate-session` off `origin/dev` (after PR-2 merged).

**Scope:** 12 Session.Registry + 16 Session.NameIndex = 28 sites.

### Task 3.1: Add Session wrappers to `Esr.Uri.Compat`

Append to `runtime/lib/esr/uri/compat.ex`:

```elixir
  # ────────────────────────────────────────────────────────────
  # Session wrappers (PR-3)
  # ────────────────────────────────────────────────────────────

  @doc "Replaces Esr.Resource.Session.Registry.get_by_id/1."
  @spec session_by_uuid(String.t()) :: {:ok, struct()} | :not_found
  def session_by_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/sessions/" <> uuid) do
      {:ok, :session, data} -> {:ok, data}
      :not_found -> :not_found
    end
  end

  @doc "Replaces Esr.Session.NameIndex.Registry.lookup_by_name/4 (4-tuple scope)."
  @spec session_uuid_in_scope(String.t(), String.t(), String.t(), String.t())
          :: {:ok, String.t()} | :not_found
  def session_uuid_in_scope(env, username, workspace, name) do
    uri = "esr://localhost/sessions/by-name/#{env}/#{username}/#{workspace}/#{name}"

    case Esr.Uri.resolve(uri) do
      {:ok, "esr://localhost/sessions/" <> uuid} -> {:ok, uuid}
      :not_found -> :not_found
    end
  end
```

### Task 3.2-3.5: Same pattern as PR-1

Sed mappings + FileLoader rewrite + module deletion + baseline update.

Baseline target: drops from ~58 to ~30.

---

## PR-4: Agent domain migration (includes breaking change)

**Branch:** `feat/uri-migrate-agent` off `origin/dev` (after PR-3 merged).

**Scope:** 91 InstanceRegistry sites. **Breaking change**: `InstanceRegistry.primary/2` returns UUID instead of name (5 prod + 4 test sites — same as the superseded entity-resolver plan).

### Task 4.1: Add Agent wrappers to `Esr.Uri.Compat`

Append:

```elixir
  # ────────────────────────────────────────────────────────────
  # Agent wrappers (PR-4)
  # ────────────────────────────────────────────────────────────

  @doc "Replaces InstanceRegistry.get/3."
  @spec agent_in_session(String.t(), String.t()) :: {:ok, struct()} | :not_found
  def agent_in_session(session_id, name) do
    case Esr.Uri.get_entity("esr://localhost/agents/by-name/#{session_id}/#{name}") do
      {:ok, :agent, data} -> {:ok, data}
      :not_found -> :not_found
    end
  end

  @doc """
  Replaces InstanceRegistry.primary/2. BREAKING: returns UUID, not name.
  Migrate callers to consume UUID + call `Esr.Uri.get_entity/1` if name needed.
  """
  @spec primary_agent_uuid(String.t()) :: {:ok, String.t()} | :not_found
  def primary_agent_uuid(session_id) when is_binary(session_id) do
    case Esr.Uri.resolve("esr://localhost/agents/by-primary-for/" <> session_id) do
      {:ok, "esr://localhost/agents/" <> uuid} -> {:ok, uuid}
      :not_found -> :not_found
    end
  end
```

### Task 4.2-4.5: Migration

Sed for most callers. **5 prod + 4 test sites** for `InstanceRegistry.primary/2` are NOT simple sed — they were consuming `name`; now they consume `uuid`. Manual edit (refer to spec §5.4 and old entity-resolver plan's Task 3.4 site list):

Prod:
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:631`
- `runtime/lib/esr/entity/slash_handler.ex:370`
- `runtime/lib/esr/commands/key.ex:155`
- `runtime/lib/esr/commands/agent/primary.ex:30` (displays name → fetch via `Esr.Uri.get_entity`)
- `runtime/lib/esr/resource/session/registry.ex:224` (already deleted in PR-3; verify)

Test:
- `runtime/test/esr/entity/agent/instance_registry_test.exs:38,44,134,142`
- `runtime/test/esr/entity/slash_handler_mention_test.exs:32,47,54`

FileLoader: `Esr.Entity.Agent.<...>.FileLoader` (if exists; otherwise the InstanceRegistry's init/1 reads from disk — port that logic to URI loading).

Baseline target: drops from ~30 to 0.

---

## PR-5: Cleanup

**Branch:** `feat/uri-cleanup` off `origin/dev` (after PR-4 merged).

### Task 5.1: Delete `Esr.Uri.Compat`

- [ ] **Step 1: Replace all `Esr.Uri.Compat.*` calls with canonical `Esr.Uri.*` calls**

For each Compat wrapper, the call site can now use `Esr.Uri.resolve/1` / `Esr.Uri.get_entity/1` / `Esr.Uri.alias/2` directly. Sed-replace each Compat call with its underlying `Esr.Uri.*` form.

- [ ] **Step 2: Delete `runtime/lib/esr/uri/compat.ex`**

```bash
git rm runtime/lib/esr/uri/compat.ex
```

- [ ] **Step 3: Compile + test**

```bash
cd runtime && mix compile --warnings-as-errors && mix test
```

### Task 5.2: Old-API-unreachable compile-fail test

**Files:**
- Create: `runtime/test/esr/uri/old_api_unreachable_test.exs`

```elixir
defmodule Esr.Uri.OldApiUnreachableTest do
  use ExUnit.Case, async: true

  test "Esr.Entity.User.Registry module is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Entity.User.Registry)
  end

  test "Esr.Entity.User.NameIndex module is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Entity.User.NameIndex)
  end

  test "Esr.Resource.Workspace.Registry module is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Resource.Workspace.Registry)
  end

  test "Esr.Resource.Workspace.NameIndex module is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Resource.Workspace.NameIndex)
  end

  test "Esr.Resource.Session.Registry module is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Resource.Session.Registry)
  end

  test "Esr.Session.NameIndex.Registry module is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Session.NameIndex.Registry)
  end

  test "Esr.Entity.Agent.InstanceRegistry module is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Entity.Agent.InstanceRegistry)
  end

  test "Esr.Uri.Compat module is deleted (migration shim)" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Uri.Compat)
  end
end
```

### Task 5.3: E2E scenarios 31 + 32

Same as the old entity-resolver plan's Task 8.1 + 8.2 (uses existing mock-feishu pattern + reads `users.yaml` for UUID lookup; no fabricated CLI verbs).

### Task 5.4: Docs sweep + final PR

Update `docs/futures/todo.md`:
- Close `chat-cap-check-username-to-uuid-hop` (chat-side cap-check now goes through `Esr.Uri.resolve` → UUID → grants)
- Close `resolve-submitter-format-agnostic` (workspace/resolve uses `Esr.Uri.resolve(:user, ...)` for all forms)
- Close `uri-as-canonical-actor-name` (shipped as this PR series)
- Close `register-adapter-half-state-surface-cleanly` (note: orthogonal)

Push + admin-merge.

---

## Self-Review

**1. Spec coverage:**
- Spec §3 Architecture → PR-0 Tasks 0.1, 0.2
- Spec §4 URI grammar → encoded in canonical/alias URIs throughout
- Spec §5 Public API → PR-0 Task 0.2
- Spec §6 Plugin handler behaviour → PR-0 Tasks 0.2, 0.5
- Spec §7 Handler contract → enforced via PR review (subagent review per PR)
- Spec §8 Storage schema → PR-0 Task 0.1
- Spec §9 Migration map → PR-1 through PR-4
- Spec §10 Enforcement (L1') → PR-0 Task 0.6 + baseline ratchet across PR-1..PR-4
- Spec §11 Tests → PR-0 Task 0.3 (per-API) + each PR's own tests + PR-5 (compile-fail + e2e)

**2. Placeholder scan:**
- PR-2/PR-3/PR-4 are described as "same pattern as PR-1" with specific substitutions — acceptable because the pattern is fully spelled out in PR-1. The 28-line / 132-line / 91-line scopes are concrete.
- "manual fix for ambiguous matches" (`User.Registry.get/1`) is explicit — engineer knows to grep + Edit by hand.

**3. Type consistency:**
- `Esr.Uri.Compat.*` wrapper signatures match the old return shapes (verified per-function inline).
- UUID format: `UUID.uuid4/0` from `:elixir_uuid` (mix.exs:74) — NOT `Ecto.UUID.generate/0`.
- `Esr.Uri.resolve/1` returns `{:ok, canonical_uri :: String.t()} | :not_found` consistently.

**4. Mechanical replacement viability:**
- 80% of 387 sites are mechanical (sed-replace via Compat).
- `User.Registry.get/1` (name collision with `get_default_workspace`, `get_by_id`) handled manually.
- `InstanceRegistry.primary/2` is the 1 actual breaking change (5 prod + 4 test sites).

**5. LSP usage noted in PR-1 Task 1.2 (find-references).**

---

## Execution Handoff

**Plan complete.** Two execution options:

**1. Subagent-Driven (recommended)** — Controller dispatches fresh subagent per task, `model: "opus"`. Reviews between PRs.

**2. Inline Execution** — `superpowers:executing-plans`, batch with checkpoints.

Default: subagent-driven.
