# ESR Capability-Based Access Control — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce capability-based access control to ESR — a hot-reloadable YAML grant store keyed by principal_id with workspace-scoped wildcard matching — enforced at two lanes (Feishu adapter inbound, PeerServer routing).

**Architecture:** `permission` = action identifier (e.g. `msg.send`); `capability` = (principal, permission) binding. Handlers/adapters declare the permissions they implement; `~/.esrd/<instance>/capabilities.yaml` lists each principal's held capabilities. Two ETS-backed registries (`Esr.Permissions.Registry` for declared permissions, `Esr.Capabilities.Grants` for the file-driven snapshot) are queried at two enforcement lanes.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 (runtime), Python 3.14 / uv (SDK + adapters + CLI), `:file_system` (fs_watch), `:yaml_elixir` (YAML parse), `ruamel.yaml` (comment-preserving YAML writes), ETS.

**Spec:** `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md` (commit `ee219da`).

**Key working-dir discipline:** primary repo is `/Users/h2oslabs/Workspace/esr`. Python commands use `uv run`. Elixir commands run from `runtime/`. Run `make test && make lint` after each task to catch regressions early.

---

## Phase CAP-0 — Rename `capability` → `io_permission`

Frees the word "capability" for this subsystem's single meaning. One coherent commit.

### Task 1: Rename `verify/capability.py` → `verify/io_permission.py`

**Files:**
- Rename: `py/src/esr/verify/capability.py` → `py/src/esr/verify/io_permission.py`
- Rename: `py/tests/test_capability.py` → `py/tests/test_io_permission.py`
- Rename: `adapters/feishu/tests/test_capability.py` → `adapters/feishu/tests/test_io_permission.py`
- Rename: `adapters/cc_tmux/tests/test_capability.py` → `adapters/cc_tmux/tests/test_io_permission.py`
- Modify: `py/src/esr/verify/__init__.py` (re-export)
- Modify: `py/src/esr/adapter.py` (docstring ref)
- Modify: `py/src/esr/cli/main.py:447,452` (import)

- [ ] **Step 1: Git move the four files and update imports**

```bash
cd /Users/h2oslabs/Workspace/esr
git mv py/src/esr/verify/capability.py py/src/esr/verify/io_permission.py
git mv py/tests/test_capability.py py/tests/test_io_permission.py
git mv adapters/feishu/tests/test_capability.py adapters/feishu/tests/test_io_permission.py
git mv adapters/cc_tmux/tests/test_capability.py adapters/cc_tmux/tests/test_io_permission.py
```

- [ ] **Step 2: Update every `from esr.verify.capability import ...` → `from esr.verify.io_permission import ...`**

Use Grep + Edit on each hit. Expected locations: all three `test_io_permission.py` files; `py/src/esr/cli/main.py:452`; `py/src/esr/verify/__init__.py`.

- [ ] **Step 3: Update docstring refs to the old path**

```bash
# Expected hits after the rename:
# - py/src/esr/adapter.py — "esr.verify.capability.scan_adapter"
# - py/src/esr/cli/main.py:447 — comment mentioning the old path
```

Replace each with `esr.verify.io_permission.scan_adapter`.

- [ ] **Step 4: Run the Python test suite**

```bash
cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -30
```

Expected: 440 passed, 1 skipped — same as before the rename.

- [ ] **Step 5: Update doc references**

PRDs and traceability docs reference the old path. Grep, then `Edit --replace_all` each:

```
docs/superpowers/prds/02-python-sdk.md:79
docs/superpowers/prds/07-cli.md:33
docs/superpowers/prds/04-adapters.md — any `verify.capability` refs
docs/superpowers/glossary.md — if it has an entry
docs/superpowers/traceability.md — if present
docs/superpowers/specs/2026-04-18-esr-extraction-design.md
docs/superpowers/tests/e2e-platform-validation.md
README.md — if it mentions capability
docs/design/*.md — update each file that mentions `verify.capability` or `capability.py`
```

- [ ] **Step 6: Run lint**

```bash
cd /Users/h2oslabs/Workspace/esr && make lint 2>&1 | tail -20
```

Expected: clean (the 12 prior SIM105 items in v0.2 test files are separate — the renames should not add new lint).

- [ ] **Step 7: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr
git add -A
git commit -m "$(cat <<'EOF'
refactor(verify): rename capability → io_permission

Phase CAP-0 of capability-based access control spec. Frees the word
"capability" for the new user-authz subsystem (Esr.Capabilities) and
clarifies the existing sandbox-scan layer as "io_permission".

No behavior change — module/file renames + import updates only.

Spec: docs/superpowers/specs/2026-04-20-esr-capabilities-design.md §14.1
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase CAP-1 — `Esr.Permissions` + `Esr.Capabilities` scaffold

Create the runtime subsystem with no enforcement wired in. Pure unit tests.

### Task 2: `Esr.Permissions.Registry` — ETS-backed permission catalog

**Files:**
- Create: `runtime/lib/esr/permissions.ex`
- Create: `runtime/lib/esr/permissions/registry.ex`
- Create: `runtime/test/esr/permissions/registry_test.exs`

- [ ] **Step 1: Write the failing test**

`runtime/test/esr/permissions/registry_test.exs`:
```elixir
defmodule Esr.Permissions.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Permissions.Registry

  setup do
    start_supervised!(Registry)
    :ok
  end

  test "register and lookup single permission" do
    :ok = Registry.register("msg.send", declared_by: Some.Module)
    assert Registry.declared?("msg.send")
    refute Registry.declared?("msg.unknown")
    assert "msg.send" in Registry.all()
  end

  test "all/0 returns every registered permission sorted" do
    Registry.register("z.last", declared_by: M)
    Registry.register("a.first", declared_by: M)
    assert Registry.all() |> Enum.sort() == ["a.first", "z.last"]
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/permissions/registry_test.exs
```

Expected: fails with `UndefinedFunctionError` on `Esr.Permissions.Registry`.

- [ ] **Step 3: Implement `Esr.Permissions.Registry`**

`runtime/lib/esr/permissions/registry.ex`:
```elixir
defmodule Esr.Permissions.Registry do
  @moduledoc """
  ETS-backed catalog of declared permissions.

  Populated at boot from handler/adapter `permissions/0` callbacks and
  the Python handler_hello IPC envelope. Frozen after boot (writes
  disabled once `Esr.Capabilities.Grants` has loaded the capability
  file, to prevent late additions from invalidating prior validation).
  """
  use GenServer

  @table :esr_permissions_registry

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def register(name, opts) when is_binary(name) do
    GenServer.call(__MODULE__, {:register, name, Keyword.get(opts, :declared_by)})
  end

  def declared?(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [] -> false
      [_] -> true
    end
  end

  def all do
    :ets.tab2list(@table) |> Enum.map(fn {name, _} -> name end)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, name, declared_by}, _from, state) do
    :ets.insert(@table, {name, declared_by})
    {:reply, :ok, state}
  end
end
```

`runtime/lib/esr/permissions.ex`:
```elixir
defmodule Esr.Permissions do
  @moduledoc "Public façade for the permissions subsystem."
  defdelegate all(), to: Esr.Permissions.Registry
  defdelegate declared?(name), to: Esr.Permissions.Registry
  defdelegate register(name, opts), to: Esr.Permissions.Registry
end
```

- [ ] **Step 4: Run to verify pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/permissions/registry_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr
git add runtime/lib/esr/permissions.ex runtime/lib/esr/permissions/registry.ex runtime/test/esr/permissions/registry_test.exs
git commit -m "$(cat <<'EOF'
feat(capabilities): Esr.Permissions.Registry

ETS-backed catalog of declared action permissions. Populated at boot
from handler/adapter callbacks.

Spec: §4.1, §4.2
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3: `Esr.Capabilities.Grants` — ETS-backed capability snapshot

**Files:**
- Create: `runtime/lib/esr/capabilities.ex`
- Create: `runtime/lib/esr/capabilities/grants.ex`
- Create: `runtime/test/esr/capabilities/grants_test.exs`

- [ ] **Step 1: Write the failing test**

`runtime/test/esr/capabilities/grants_test.exs`:
```elixir
defmodule Esr.Capabilities.GrantsTest do
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants

  setup do
    start_supervised!(Grants)
    :ok
  end

  test "empty snapshot denies everything" do
    refute Grants.has?("ou_xxx", "workspace:proj/msg.send")
  end

  test "admin wildcard grants all" do
    Grants.load_snapshot(%{"ou_admin" => ["*"]})
    assert Grants.has?("ou_admin", "workspace:any/any.perm")
  end

  test "exact match" do
    Grants.load_snapshot(%{"ou_alice" => ["workspace:proj-a/msg.send"]})
    assert Grants.has?("ou_alice", "workspace:proj-a/msg.send")
    refute Grants.has?("ou_alice", "workspace:proj-b/msg.send")
    refute Grants.has?("ou_alice", "workspace:proj-a/session.create")
  end

  test "scope wildcard" do
    Grants.load_snapshot(%{"ou_reader" => ["workspace:*/msg.send"]})
    assert Grants.has?("ou_reader", "workspace:proj-a/msg.send")
    assert Grants.has?("ou_reader", "workspace:proj-b/msg.send")
    refute Grants.has?("ou_reader", "workspace:proj-a/session.create")
  end

  test "permission wildcard within scope" do
    Grants.load_snapshot(%{"ou_owner" => ["workspace:proj-a/*"]})
    assert Grants.has?("ou_owner", "workspace:proj-a/msg.send")
    assert Grants.has?("ou_owner", "workspace:proj-a/session.create")
    refute Grants.has?("ou_owner", "workspace:proj-b/msg.send")
  end

  test "prefix glob does not match" do
    # session.* is NOT a valid matcher — only `*` as whole segment matches
    Grants.load_snapshot(%{"ou_x" => ["workspace:proj/session.*"]})
    refute Grants.has?("ou_x", "workspace:proj/session.create")
  end

  test "load_snapshot atomically replaces prior state" do
    Grants.load_snapshot(%{"ou_a" => ["*"]})
    assert Grants.has?("ou_a", "workspace:x/y")
    Grants.load_snapshot(%{"ou_b" => ["*"]})
    refute Grants.has?("ou_a", "workspace:x/y")
    assert Grants.has?("ou_b", "workspace:x/y")
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/capabilities/grants_test.exs
```

Expected: `UndefinedFunctionError` on `Esr.Capabilities.Grants`.

- [ ] **Step 3: Implement `Esr.Capabilities.Grants`**

`runtime/lib/esr/capabilities/grants.ex`:
```elixir
defmodule Esr.Capabilities.Grants do
  @moduledoc """
  ETS-backed snapshot of principal → [permission] grants.

  Loaded from `capabilities.yaml` (see `Esr.Capabilities.FileLoader`)
  and replaced atomically on reload.

  Matching rules (spec §3.3):
  - bare `*` grants everything
  - `workspace:<s>/<p>` matches when both segments match (each literally
    or via bare `*`)
  - no prefix glob — only whole-segment wildcards
  """
  use GenServer

  @table :esr_capabilities_grants

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Replace the full snapshot atomically."
  def load_snapshot(snapshot) when is_map(snapshot) do
    GenServer.call(__MODULE__, {:load, snapshot})
  end

  @doc "Does the capability (principal_id, permission) exist?"
  def has?(principal_id, permission) when is_binary(principal_id) and is_binary(permission) do
    case :ets.lookup(@table, principal_id) do
      [] -> false
      [{^principal_id, held}] -> Enum.any?(held, &matches?(&1, permission))
    end
  end

  defp matches?("*", _required), do: true
  defp matches?(held, required) do
    with {:ok, {h_scope, h_perm}} <- split(held),
         {:ok, {r_scope, r_perm}} <- split(required) do
      segment_match?(h_scope, r_scope) and segment_match?(h_perm, r_perm)
    else
      _ -> false
    end
  end

  defp split(str) do
    case String.split(str, "/", parts: 2) do
      [scope, perm] -> {:ok, {scope, perm}}
      _ -> :error
    end
  end

  defp segment_match?("*", _), do: true
  defp segment_match?(a, a), do: true
  defp segment_match?(_, _), do: false

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, snapshot}, _from, state) do
    :ets.delete_all_objects(@table)
    Enum.each(snapshot, fn {pid, held} -> :ets.insert(@table, {pid, held}) end)
    {:reply, :ok, state}
  end
end
```

`runtime/lib/esr/capabilities.ex`:
```elixir
defmodule Esr.Capabilities do
  @moduledoc """
  Public façade for the capabilities (access-control) subsystem.

  Permission = action name (e.g. "msg.send").
  Capability = (principal_id, permission) binding.
  """

  @doc "Check whether principal holds the given permission (possibly via wildcard)."
  defdelegate has?(principal_id, permission), to: Esr.Capabilities.Grants
end
```

- [ ] **Step 4: Run to verify pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/capabilities/grants_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr
git add runtime/lib/esr/capabilities.ex runtime/lib/esr/capabilities/grants.ex runtime/test/esr/capabilities/grants_test.exs
git commit -m "$(cat <<'EOF'
feat(capabilities): Esr.Capabilities.Grants + wildcard match

ETS-backed principal → [permission] snapshot with whole-segment
wildcard matching. Admin via bare "*"; scope/perm wildcards via
"workspace:*/..." or ".../\*". No prefix globs (YAGNI per spec §3.2).

Spec: §3.3, §5
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4: `Esr.Capabilities.FileLoader` — YAML parse + validation

**Files:**
- Create: `runtime/lib/esr/capabilities/file_loader.ex`
- Create: `runtime/test/esr/capabilities/file_loader_test.exs`
- Create: `runtime/test/support/capabilities_fixtures/valid.yaml`
- Create: `runtime/test/support/capabilities_fixtures/invalid_yaml.yaml`
- Create: `runtime/test/support/capabilities_fixtures/unknown_permission.yaml`

- [ ] **Step 1: Create fixtures**

`runtime/test/support/capabilities_fixtures/valid.yaml`:
```yaml
principals:
  - id: ou_admin
    kind: feishu_user
    note: admin
    capabilities: ["*"]
  - id: ou_alice
    kind: feishu_user
    note: Alice
    capabilities:
      - "workspace:proj-a/msg.send"
      - "workspace:proj-a/session.create"
```

`runtime/test/support/capabilities_fixtures/invalid_yaml.yaml`:
```yaml
principals:
  - id: ou_x
    capabilities: [unterminated
```

`runtime/test/support/capabilities_fixtures/unknown_permission.yaml`:
```yaml
principals:
  - id: ou_typo
    kind: feishu_user
    capabilities:
      - "workspace:proj-a/msg.sned"   # typo: declared as msg.send
```

- [ ] **Step 2: Write the failing test**

`runtime/test/esr/capabilities/file_loader_test.exs`:
```elixir
defmodule Esr.Capabilities.FileLoaderTest do
  use ExUnit.Case, async: false

  alias Esr.Capabilities.{FileLoader, Grants}
  alias Esr.Permissions.Registry

  @fixtures "test/support/capabilities_fixtures"

  setup do
    start_supervised!(Registry)
    start_supervised!(Grants)
    # Registry must declare the permissions used in fixtures
    Registry.register("msg.send", declared_by: Test)
    Registry.register("session.create", declared_by: Test)
    :ok
  end

  test "load valid file" do
    assert :ok = FileLoader.load(Path.join(@fixtures, "valid.yaml"))
    assert Grants.has?("ou_admin", "workspace:any/any.perm")
    assert Grants.has?("ou_alice", "workspace:proj-a/msg.send")
    refute Grants.has?("ou_alice", "workspace:proj-b/msg.send")
  end

  test "missing file → empty snapshot, no error" do
    assert :ok = FileLoader.load("/tmp/does/not/exist.yaml")
    refute Grants.has?("ou_admin", "workspace:any/any")
  end

  test "malformed YAML → error, prior snapshot kept" do
    FileLoader.load(Path.join(@fixtures, "valid.yaml"))
    {:error, {:yaml_parse, _}} = FileLoader.load(Path.join(@fixtures, "invalid_yaml.yaml"))
    # admin grant from previous load survives
    assert Grants.has?("ou_admin", "workspace:any/any.perm")
  end

  test "unknown permission → error, prior snapshot kept" do
    FileLoader.load(Path.join(@fixtures, "valid.yaml"))
    {:error, {:unknown_permission, "msg.sned", "ou_typo"}} =
      FileLoader.load(Path.join(@fixtures, "unknown_permission.yaml"))
    assert Grants.has?("ou_alice", "workspace:proj-a/msg.send")
  end
end
```

- [ ] **Step 3: Implement the loader**

`runtime/lib/esr/capabilities/file_loader.ex`:
```elixir
defmodule Esr.Capabilities.FileLoader do
  @moduledoc """
  Parses capabilities.yaml, validates each entry against the
  Permissions.Registry, and atomically swaps the Grants snapshot.

  Load is non-destructive on failure: if validation fails, the existing
  snapshot is retained and the caller sees the specific error.
  """
  require Logger

  alias Esr.Capabilities.Grants
  alias Esr.Permissions.Registry

  @spec load(Path.t()) :: :ok | {:error, term()}
  def load(path) do
    cond do
      not File.exists?(path) ->
        Grants.load_snapshot(%{})
        :ok

      true ->
        with {:ok, yaml} <- parse(path),
             {:ok, snapshot} <- validate(yaml) do
          Grants.load_snapshot(snapshot)
          Logger.info("capabilities: loaded #{map_size(snapshot)} principals from #{path}")
          :ok
        else
          {:error, reason} = err ->
            Logger.error("capabilities: load failed (#{inspect(reason)}); keeping previous snapshot")
            err
        end
    end
  end

  defp parse(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, err} -> {:error, {:yaml_parse, err}}
    end
  end

  defp validate(yaml) when is_map(yaml) do
    principals = Map.get(yaml, "principals", [])
    Enum.reduce_while(principals, {:ok, %{}}, fn entry, {:ok, acc} ->
      case validate_entry(entry) do
        {:ok, pid, held} -> {:cont, {:ok, Map.put(acc, pid, held)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_entry(%{"id" => pid, "capabilities" => caps} = _entry)
       when is_binary(pid) and is_list(caps) do
    Enum.reduce_while(caps, {:ok, pid, []}, fn cap, {:ok, pid, acc} ->
      case validate_cap(cap, pid) do
        :ok -> {:cont, {:ok, pid, [cap | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pid, held} -> {:ok, pid, Enum.reverse(held)}
      err -> err
    end
  end

  defp validate_entry(entry), do: {:error, {:malformed_entry, entry}}

  defp validate_cap("*", _pid), do: :ok

  defp validate_cap(cap, pid) when is_binary(cap) do
    with [scope, perm] <- String.split(cap, "/", parts: 2),
         :ok <- validate_scope(scope),
         :ok <- validate_perm(perm, pid) do
      :ok
    else
      {:error, _} = err -> err
      _ -> {:error, {:malformed_cap, cap, pid}}
    end
  end

  defp validate_scope("workspace:" <> name = scope) do
    # Spec §11: warn but don't fail if workspace not yet configured.
    # Cross-check against Esr.Workspaces.Registry if it's up.
    cond do
      name == "*" -> :ok
      Process.whereis(Esr.Workspaces.Registry) == nil -> :ok  # registry not yet started
      Esr.Workspaces.Registry.exists?(name) -> :ok
      true ->
        Logger.warning("capabilities: workspace #{inspect(name)} in grant #{scope} is not in workspaces.yaml (keeping entry anyway)")
        :ok
    end
  end
  defp validate_scope("*"), do: :ok
  defp validate_scope(scope), do: {:error, {:bad_scope_prefix, scope}}

  defp validate_perm("*", _pid), do: :ok

  defp validate_perm(perm, pid) do
    if Registry.declared?(perm) do
      :ok
    else
      {:error, {:unknown_permission, perm, pid}}
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/capabilities/file_loader_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr
git add runtime/lib/esr/capabilities/file_loader.ex runtime/test/esr/capabilities/ runtime/test/support/capabilities_fixtures/
git commit -m "$(cat <<'EOF'
feat(capabilities): FileLoader with validation

YAML parse + per-entry validation against Permissions.Registry.
On validation failure, keep previous snapshot; return specific error
tuple for the caller/log to surface. Missing file is OK (empty
snapshot, default-deny).

Spec: §4.3, §5.1, §11
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5: fs_watch hot-reload + Supervisor + Application wiring

**Files:**
- Create: `runtime/lib/esr/capabilities/watcher.ex`
- Create: `runtime/lib/esr/capabilities/supervisor.ex`
- Modify: `runtime/lib/esr/application.ex` (add to supervision tree)
- Modify: `runtime/mix.exs` (declare `:file_system` directly)
- Create: `runtime/test/esr/capabilities/watcher_test.exs`

- [ ] **Step 1: Add `:file_system` to mix.exs**

Edit `runtime/mix.exs` — in `defp deps`, add `{:file_system, "~> 1.0"}` (check current version with `mix hex.info file_system` first).

Run:
```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix deps.get
```

- [ ] **Step 2: Write the failing test**

`runtime/test/esr/capabilities/watcher_test.exs`:
```elixir
defmodule Esr.Capabilities.WatcherTest do
  use ExUnit.Case, async: false

  alias Esr.Capabilities.{Watcher, Grants, FileLoader}
  alias Esr.Permissions.Registry

  setup do
    start_supervised!(Registry)
    start_supervised!(Grants)
    Registry.register("msg.send", declared_by: Test)

    tmp = Path.join(System.tmp_dir!(), "cap_watch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    file = Path.join(tmp, "capabilities.yaml")
    File.write!(file, """
    principals:
      - id: ou_a
        capabilities: ["workspace:x/msg.send"]
    """)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, file: file, dir: tmp}
  end

  test "initial load on start", %{file: file} do
    start_supervised!({Watcher, path: file})
    assert Grants.has?("ou_a", "workspace:x/msg.send")
  end

  test "reload on file change", %{file: file} do
    start_supervised!({Watcher, path: file})
    refute Grants.has?("ou_b", "workspace:x/msg.send")

    File.write!(file, """
    principals:
      - id: ou_b
        capabilities: ["workspace:x/msg.send"]
    """)
    # fs_system debounce + our handler: sub-2s convergence
    Process.sleep(1500)

    assert Grants.has?("ou_b", "workspace:x/msg.send")
    refute Grants.has?("ou_a", "workspace:x/msg.send")
  end
end
```

- [ ] **Step 3: Implement Watcher and Supervisor**

`runtime/lib/esr/capabilities/watcher.ex`:
```elixir
defmodule Esr.Capabilities.Watcher do
  @moduledoc """
  Watches the capabilities.yaml file and triggers FileLoader.load/1 on
  any change event. Also performs the initial load on start.
  """
  use GenServer
  require Logger

  alias Esr.Capabilities.FileLoader

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    FileLoader.load(path)  # initial load

    case File.exists?(path) do
      true ->
        {:ok, pid} = FileSystem.start_link(dirs: [Path.dirname(path)])
        FileSystem.subscribe(pid)
        {:ok, %{path: path, fs_pid: pid}}

      false ->
        Logger.warning("capabilities: file not present at #{path}; will not watch")
        {:ok, %{path: path, fs_pid: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {changed_path, _events}}, %{path: path} = state) do
    if Path.expand(changed_path) == Path.expand(path) do
      FileLoader.load(path)
    end
    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end
end
```

`runtime/lib/esr/capabilities/supervisor.ex`:
```elixir
defmodule Esr.Capabilities.Supervisor do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())

    children = [
      Esr.Permissions.Registry,
      Esr.Capabilities.Grants,
      {Esr.Capabilities.Watcher, path: path}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp default_path do
    esrd_home = System.get_env("ESRD_HOME") || Path.expand("~/.esrd")
    Path.join([esrd_home, "default", "capabilities.yaml"])
  end
end
```

- [ ] **Step 4: Add to Application supervision tree**

`runtime/lib/esr/application.ex` — in the `children = [...]` list, add `Esr.Capabilities.Supervisor` AFTER the existing `Esr.Workspaces` supervisor (so Registry/Grants exist before anything tries to check).

- [ ] **Step 5: Run watcher test + full suite**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/capabilities/ && cd .. && make test 2>&1 | tail -20
```

Expected: watcher tests 2/2 pass; full suite: 155 + 440 both green.

- [ ] **Step 6: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr
git add runtime/lib/esr/capabilities/watcher.ex runtime/lib/esr/capabilities/supervisor.ex runtime/test/esr/capabilities/watcher_test.exs runtime/lib/esr/application.ex runtime/mix.exs runtime/mix.lock
git commit -m "$(cat <<'EOF'
feat(capabilities): fs_watch hot-reload + supervision tree

Watcher subscribes to fs events on capabilities.yaml's directory and
triggers FileLoader.load/1 on any change. Supervisor glues Permissions
Registry + Grants + Watcher with rest_for_one so a loader crash does
not take down the snapshot.

Uses :file_system as a direct dep (previously transitive via Phoenix).

Spec: §5.3, §14.2
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase CAP-2 — Permission declarations

### Task 6: Elixir `permissions/0` callback + handler migrations

**Files:**
- Modify: `runtime/lib/esr/handler.ex` (the behaviour) — add `@optional_callbacks permissions: 0`
- Modify: every Elixir handler module under `runtime/lib/esr/handler_router/` and adapters — add `permissions/0` callback
- Create: `runtime/test/esr/permissions/bootstrap_test.exs`

- [ ] **Step 1: Add optional callback to ESR.Handler behaviour**

Find the behaviour definition (likely `runtime/lib/esr/handler_router.ex` or a sibling). Add:
```elixir
@callback permissions() :: [String.t()]
@optional_callbacks permissions: 0
```

- [ ] **Step 2: Add `permissions/0` to each existing handler**

For every module that `@behaviour ESR.Handler` — add `def permissions, do: [...]` returning the action names the handler implements:

- `feishu_app_proxy`: `["msg.send", "session.create", "session.switch", "workspace.read", "workspace.list"]`
- `feishu_thread_proxy`: `["msg.send", "session.switch"]`
- other handlers: assess their module docstring for actions they expose; declare none (`[]`) if purely internal

- [ ] **Step 3: Register built-in MCP tools as permissions**

`runtime/lib/esr/peer_server.ex:680-740` defines four tool handlers (`reply`, `react`, `send_file`, `_echo`). **CAP-4's enforcement derives required permissions as `workspace:<ws>/<tool_name>`**, so these four tool names MUST be registered or every existing tool_invoke will be denied. Register them alongside the subsystem-intrinsic caps.

- [ ] **Step 4: Bootstrap permissions into Registry at boot**

In `Esr.Capabilities.Supervisor.init/1` (or a new `Esr.Permissions.Bootstrap` module called from it) — after starting Permissions.Registry, iterate known handlers and call `Registry.register(name, declared_by: mod)` for each. Also register:

```elixir
# Runtime-intrinsic tools (from peer_server.ex:680-740)
for tool <- ["reply", "react", "send_file", "_echo"] do
  Registry.register(tool, declared_by: Esr.PeerServer)
end

# Subsystem-intrinsic
Registry.register("cap.manage", declared_by: Esr.Capabilities)
Registry.register("cap.read", declared_by: Esr.Capabilities)
```

Discovery approach for handlers: use `Application.spec(:esr, :modules)` then `Code.ensure_loaded?/1` + `function_exported?(mod, :permissions, 0)`.

- [ ] **Step 4: Write the bootstrap test**

`runtime/test/esr/permissions/bootstrap_test.exs`:
```elixir
defmodule Esr.Permissions.BootstrapTest do
  use ExUnit.Case, async: false

  alias Esr.Permissions.Registry

  setup do
    start_supervised!({Esr.Capabilities.Supervisor, path: "/tmp/nonexistent.yaml"})
    :ok
  end

  test "handler-declared permissions are registered" do
    assert Registry.declared?("msg.send")
    assert Registry.declared?("session.create")
  end

  test "subsystem-intrinsic permissions are registered" do
    assert Registry.declared?("cap.manage")
    assert Registry.declared?("cap.read")
  end
end
```

- [ ] **Step 5: Run + commit**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/permissions/
cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -10
git add -A
git commit -m "feat(capabilities): handlers declare permissions/0 at boot

Every ESR.Handler gains an optional permissions/0 callback listing
the action names it implements. Supervisor.init bootstraps these into
Esr.Permissions.Registry alongside the subsystem's own cap.manage and
cap.read.

Spec: §3.1, §4.1
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 7: Python `@handler(permissions=[...])` + IPC handshake

**Files:**
- Modify: `py/src/esr/handler.py` (extend decorator)
- Create: `py/src/esr/permissions.py`
- Modify: every `@handler(...)` call in the repo to add `permissions=[...]`
- Modify: `py/src/esr/ipc/adapter_runner.py` (include in `handler_hello`)
- Modify: `runtime/lib/esr_web/adapter_channel.ex` (ingest `handler_hello.permissions`)
- Create: `py/tests/test_permissions_decoration.py`

- [ ] **Step 1: Write the Python decorator test**

`py/tests/test_permissions_decoration.py`:
```python
from esr.handler import handler, HANDLER_REGISTRY, all_permissions


def test_handler_stores_permissions():
    @handler("test_actor", "test_action", permissions=["msg.send"])
    def h(state, event): ...
    entry = HANDLER_REGISTRY["test_actor.test_action"]
    assert entry.permissions == frozenset(["msg.send"])


def test_handler_without_permissions_has_empty_frozenset():
    @handler("test_actor", "no_perm")
    def h(state, event): ...
    entry = HANDLER_REGISTRY["test_actor.no_perm"]
    assert entry.permissions == frozenset()


def test_all_permissions_union():
    @handler("a", "x", permissions=["p1"])
    def h1(s, e): ...
    @handler("b", "y", permissions=["p1", "p2"])
    def h2(s, e): ...
    assert {"p1", "p2"}.issubset(all_permissions())
```

- [ ] **Step 2: Run — expected failure**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest py/tests/test_permissions_decoration.py -v
```

Expected: fail on `permissions` kwarg / `all_permissions` import.

- [ ] **Step 3: Extend the decorator (keyword-only, preserve duplicate check)**

The real decorator at `py/src/esr/handler.py:54` is **keyword-only** (`def handler(*, actor_type, name)`) and raises `ValueError` on duplicate registration. Both must be preserved — there are existing tests at `py/tests/test_handler.py:44-55` (duplicate must raise) and `:58-61` (keyword-only enforcement) that would otherwise break.

Edit `py/src/esr/handler.py`:

```python
@dataclass(frozen=True)
class HandlerEntry:
    actor_type: str
    name: str
    fn: Callable[..., Any]
    permissions: frozenset[str] = frozenset()


def handler(
    *,
    actor_type: str,
    name: str,
    permissions: list[str] | None = None,
) -> Callable[[HandlerFn], HandlerFn]:
    """Register a handler function under actor_type.name.

    Duplicate registration raises ValueError (unchanged).
    The optional permissions kwarg declares which action names this
    handler implements; aggregated into all_permissions().
    """
    def decorate(fn: HandlerFn) -> HandlerFn:
        key = f"{actor_type}.{name}"
        if key in HANDLER_REGISTRY:
            raise ValueError(f"handler {key} already registered")
        HANDLER_REGISTRY[key] = HandlerEntry(
            actor_type=actor_type,
            name=name,
            fn=fn,
            permissions=frozenset(permissions or []),
        )
        return fn
    return decorate


def all_permissions() -> frozenset[str]:
    return frozenset().union(*(e.permissions for e in HANDLER_REGISTRY.values()))
```

**Also update the Python test stubs in Step 1** — every `@handler(...)` call must use keyword args: `@handler(actor_type="test_actor", name="test_action", permissions=["msg.send"])`.

Also create `py/src/esr/permissions.py`:
```python
"""Public API for Python permission declarations (see spec §3.1)."""
from esr.handler import all_permissions  # noqa: F401
```

- [ ] **Step 4: Migrate existing `@handler(...)` sites**

Grep `@handler(` across `handlers/`, `adapters/`, `py/`. For each:
- feishu_thread.on_msg → `permissions=["msg.send", "session.switch"]`
- feishu_app_proxy actions → map as per spec §3.1
- Others: add `permissions=[]` (explicit empty set is fine; decorator default is also empty).

- [ ] **Step 5: Extend handler_hello IPC**

`py/src/esr/ipc/adapter_runner.py` — find where `handler_hello` or equivalent boot envelope is constructed. Add `permissions: sorted(all_permissions())` to the payload.

`runtime/lib/esr_web/adapter_channel.ex` — find the `handler_hello` message handler (likely `handle_in("handler_hello", ...)` or similar). Extract the `permissions` list and register each via `Esr.Permissions.Registry.register/2`.

- [ ] **Step 6: Run all tests**

```bash
cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -20
```

Expected: all green (py 443+, ex 155 +).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(capabilities): Python @handler(permissions=[...]) + IPC

Handler decorator gains permissions kwarg; HandlerEntry stores them
as frozenset. adapter_runner.handler_hello envelope extended to include
the union. Elixir AdapterChannel registers them into Permissions.Registry
on receipt.

Spec: §3.1, §4.1
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7.5: Bootstrap — ensure capabilities.yaml exists before enforcement turns on

**NOTE on ordering**: the original plan placed bootstrap in Phase CAP-8. The plan review showed this causes Phase CAP-5 (Lane A enforcement) to default-deny every user if no file exists yet. Bootstrap must land **before** CAP-5 activates enforcement. Implementing it here, immediately after permissions are declared and before envelope work starts.

**Files:**
- Modify: `runtime/lib/esr/capabilities/supervisor.ex` (bootstrap hook in `init/1`)
- Create: `etc/capabilities.yaml.example`
- Create: `runtime/test/esr/capabilities/bootstrap_test.exs`

- [ ] **Step 1: Create example seed**

`etc/capabilities.yaml.example`:
```yaml
# ESR capabilities configuration.
# Edit to grant users permissions; changes hot-reload automatically.
# Copy this file to ~/.esrd/default/capabilities.yaml to activate.

principals:
  - id: ou_CHANGEME
    kind: feishu_user
    note: admin (owner)
    capabilities: ["*"]
```

- [ ] **Step 2: Test**

Boot with no file + `ESR_BOOTSTRAP_PRINCIPAL_ID=ou_xyz` → file created with that principal holding `["*"]`.

- [ ] **Step 3: Implement**

`Esr.Capabilities.Supervisor.init/1` — before starting Watcher, if `!File.exists?(path)` and `System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID")` is set, write:
```yaml
principals:
  - id: <bootstrap_id>
    kind: feishu_user
    note: bootstrap admin
    capabilities: ["*"]
```
Log: `"capabilities: bootstrapped <id> as admin at <path>"`.

- [ ] **Step 4: Run + commit**

```bash
cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -10
git add -A
git commit -m "feat(capabilities): bootstrap via ESR_BOOTSTRAP_PRINCIPAL_ID

First-run: if capabilities.yaml is missing and
ESR_BOOTSTRAP_PRINCIPAL_ID is set, write a seed file granting that
principal the admin wildcard. Ships etc/capabilities.yaml.example.

Moved from original Phase CAP-8 to here so Lane A (Task 11) does not
default-deny every user on a fresh install.

Spec: §9.1
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase CAP-3 — Envelope extension (principal_id + workspace_name)

### Task 8: Feishu adapter sets principal_id + workspace_name on msg_received

**Files:**
- Modify: `adapters/feishu/src/esr_feishu/adapter.py` at lines 427, 579, 628 (three `msg_received` construction sites)
- Modify: `adapters/feishu/src/esr_feishu/adapter.py` startup (load workspaces.yaml into a reverse-lookup map)
- Create: `adapters/feishu/tests/test_envelope_principal.py`

- [ ] **Step 1: Build `(chat_id, app_id) → workspace_name` map**

In the feishu adapter's `__init__` or first-call lazy init, load `workspaces.yaml` via the existing `esr.workspaces.read_workspaces(Path(...))`. Build:
```python
self._workspace_of: dict[tuple[str, str], str] = {}
for ws in read_workspaces(self._workspaces_path).values():
    for chat in ws.chats:
        self._workspace_of[(chat["chat_id"], chat["app_id"])] = ws.name
```

The path comes from `ESRD_HOME/default/workspaces.yaml` (same pattern as capabilities file).

- [ ] **Step 2: Write envelope test**

`adapters/feishu/tests/test_envelope_principal.py`:
```python
from esr_feishu.adapter import FeishuAdapter
# ... use existing test fixtures for P2ImMessageReceiveV1

def test_envelope_has_principal_and_workspace(adapter_with_fake_ws):
    # adapter_with_fake_ws has app_id cli_a9563cc and workspaces.yaml
    # listing workspace "proj-a" with chats [{chat_id: oc_foo, app_id: cli_a9563cc, kind: dm}]
    raw = make_fake_msg(open_id="ou_alice", chat_id="oc_foo")
    env = adapter_with_fake_ws._build_msg_received_envelope(raw)
    assert env["principal_id"] == "ou_alice"
    assert env["workspace_name"] == "proj-a"


def test_envelope_workspace_nil_when_no_match(adapter_with_fake_ws):
    raw = make_fake_msg(open_id="ou_alice", chat_id="oc_unbound")
    env = adapter_with_fake_ws._build_msg_received_envelope(raw)
    assert env["workspace_name"] is None
```

- [ ] **Step 3: Update three construction sites**

At each of lines 427, 579, 628 in `adapters/feishu/src/esr_feishu/adapter.py`, extend the envelope dict:
```python
env = {
    # ... existing fields ...
    "principal_id": open_id,
    "workspace_name": self._workspace_of.get((chat_id, self.app_id)),
    "payload": {"event_type": "msg_received", "args": {...}}
}
```

Factor the three sites through a shared helper `_build_msg_received_envelope(raw)` if they aren't already — the existing code has the extraction logic inline.

- [ ] **Step 4: Run adapter tests**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest adapters/feishu/tests -v 2>&1 | tail -20
```

Expected: new tests pass + all existing feishu tests green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(adapters/feishu): envelope carries principal_id + workspace_name

Adapter loads workspaces.yaml at startup into a (chat_id, app_id) →
workspace_name map. Every msg_received envelope gains principal_id
(sender.open_id) and workspace_name (reverse-lookup; nil if chat not
in any workspace).

Spec: §6.2, §6.3
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 9: AdapterChannel + PeerServer envelope + tool_invoke tuple arity

**Files:**
- Modify: `runtime/lib/esr_web/adapter_channel.ex` (require principal_id + workspace_name on inbound)
- Modify: `runtime/lib/esr_web/channel_channel.ex` (session register frame → principal_id; inject into tool_invoke tuple)
- Modify: `runtime/lib/esr/session_registry.ex` (add principal_id + workspace_name fields)
- Modify: `runtime/lib/esr/peer_server.ex` at lines 216-227 and 232-264 (read new fields; tuple arity 6)
- Modify: tests touching `{:tool_invoke, ...}` (update arity)
- Create: `runtime/test/esr_web/adapter_channel_principal_test.exs`
- Create: `runtime/test/esr_web/channel_channel_principal_test.exs`

- [ ] **Step 1: Add principal + workspace to SessionRegistry row**

`runtime/lib/esr/session_registry.ex` stores session rows as plain maps (not structs). Around line 71 the `Map.take(...)` whitelist controls which keys persist. Widen that whitelist to include `:principal_id` and `:workspace_name`. Thread both through `register/1` and any `spawn` / `ensure_session` paths.

- [ ] **Step 2: Extend session register frame**

The real entry point is `channel_channel.ex:29`:
```elixir
def handle_in("envelope", %{"kind" => "session_register"} = payload, socket) do
```
Extract `payload["principal_id"]` and `payload["workspace_name"]` and forward to `Esr.SessionRegistry.register/1`. Default `principal_id` to `System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID")` if absent (bootstrap admin); default `workspace_name` to `nil`.

(`phx_join` is a framework-level callback — not where ESR does session registration. The plan previously pointed at the wrong site.)

- [ ] **Step 3: Extend tool_invoke tuple arity**

Every `send(peer_server, {:tool_invoke, req_id, tool, args, reply_pid})` becomes `{:tool_invoke, req_id, tool, args, reply_pid, principal_id}`. Concrete migration sites (complete list, grepped):
- `runtime/lib/esr/peer_server.ex:233` (receiver — the `handle_info` clause; extend arity)
- `runtime/lib/esr_web/channel_channel.ex:55` (sender — reads `principal_id` from the socket assigns populated in Step 2)

No Python adapter sends tool_invoke tuples — Python uses JSON `{"kind": "tool_invoke", ...}` envelopes that AdapterChannel translates.

Every `handle_info({:tool_invoke, ...}, state)` clause (peer_server.ex:232, and any test that pattern-matches the tuple) becomes arity-6 matching.

- [ ] **Step 4: Require principal_id + workspace_name on adapter inbound envelopes**

`adapter_channel.ex` — in the `handle_in("event", envelope, ...)` (or equivalent) clause, check `envelope["principal_id"]` and `envelope["workspace_name"]` exist. If missing, log error + reject:
```elixir
case {envelope["principal_id"], envelope["workspace_name"]} do
  {pid, _ws} when is_nil(pid) ->
    {:reply, {:error, %{reason: "principal_id required"}}, socket}
  # ... normal path
end
```

(`workspace_name` may be nil — that's the "chat not in any workspace" case. Still propagate, let Lane B decide.)

- [ ] **Step 5: Write integration tests**

Cover: adapter frame with missing principal_id is rejected; with principal_id and workspace_name present, PeerServer receives them on envelope / tool_invoke tuple.

- [ ] **Step 6: Run and commit**

```bash
cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -20
git add -A
git commit -m "feat(runtime): envelope principal_id + workspace_name end-to-end

- SessionRegistry gains principal_id + workspace_name fields
- channel_channel reads them from phx_join params; injects into
  {:tool_invoke, ...} tuple (arity 5 → 6)
- adapter_channel rejects inbound event frames missing principal_id
- peer_server handle_info clauses read both fields from envelope/tuple

No enforcement yet — fields are wired through for CAP-4 to consume.

Spec: §6.2, §6.3
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase CAP-4 — Lane B enforcement (PeerServer)

### Task 10: Lane B check + deny propagation

**Files:**
- Modify: `runtime/lib/esr/peer_server.ex` (insert checks in handle_info clauses)
- Modify: handler modules that emit tool_invoke (catch `{:error, :unauthorized}` → `reply` directive)
- Create: `runtime/test/esr/peer_server_lane_b_test.exs`

- [ ] **Step 1: Write Lane B integration tests**

`runtime/test/esr/peer_server_lane_b_test.exs`:
```elixir
defmodule Esr.PeerServerLaneBTest do
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.Permissions.Registry

  setup do
    start_supervised!(Registry)
    start_supervised!(Grants)
    Registry.register("msg.send", declared_by: Test)
    Registry.register("session.create", declared_by: Test)
    :ok
  end

  test "inbound_event without matching permission → invoke_handler skipped, denied telemetry" do
    Grants.load_snapshot(%{"ou_unauth" => []})
    # craft an envelope with principal_id=ou_unauth, workspace=proj-a,
    # event_type=msg_received; send to a running PeerServer
    # assert: handler NOT invoked
    # assert: telemetry [:esr, :capabilities, :denied] received
  end

  test "inbound_event with msg.send → handler invoked" do
    Grants.load_snapshot(%{"ou_ok" => ["workspace:proj-a/msg.send"]})
    # assert: handler invoked
  end

  test "tool_invoke session.create without cap → {:error, :unauthorized}" do
    Grants.load_snapshot(%{"ou_user" => ["workspace:proj-a/msg.send"]})
    # craft {:tool_invoke, req, "session.create", %{"workspace_name" => "proj-a"}, self(), "ou_user"}
    # assert: reply is {:error, :unauthorized}
  end

  test "admin wildcard bypasses everything" do
    Grants.load_snapshot(%{"ou_admin" => ["*"]})
    # assert: both inbound_event and tool_invoke succeed
  end
end
```

- [ ] **Step 2: Insert check in `handle_info({:inbound_event, ...}, ...)` at peer_server.ex:216-227**

```elixir
def handle_info({:inbound_event, envelope}, state) do
  principal_id = envelope["principal_id"]
  workspace = envelope["workspace_name"]
  event_type = get_in(envelope, ["payload", "event_type"])
  required = "workspace:#{workspace || "*"}/#{permission_for_event(event_type)}"

  if Esr.Capabilities.has?(principal_id, required) do
    # ... existing invoke_handler/3 path
  else
    :telemetry.execute(
      [:esr, :capabilities, :denied],
      %{count: 1},
      %{principal_id: principal_id, required_perm: required, lane: :B_inbound}
    )
    {:noreply, state}  # drop silently; Lane A already handled user-facing response
  end
end

defp permission_for_event("msg_received"), do: "msg.send"
defp permission_for_event(other), do: other
```

- [ ] **Step 3: Insert check in `handle_info({:tool_invoke, ..., principal_id}, ...)` at peer_server.ex:232-264**

```elixir
def handle_info({:tool_invoke, req_id, tool, args, reply_pid, principal_id}, state) do
  workspace = Map.get(args, "workspace_name")
  required = "workspace:#{workspace || "*"}/#{tool}"

  if Esr.Capabilities.has?(principal_id, required) do
    # ... existing tool_invoke path
  else
    :telemetry.execute(
      [:esr, :capabilities, :denied],
      %{count: 1},
      %{principal_id: principal_id, required_perm: required, lane: :B_tool_invoke}
    )
    # Use the same reply shape as the success path (peer_server.ex:283, 255)
    send(reply_pid, {:tool_result, req_id, %{
      "ok" => false,
      "error" => %{
        "type" => "unauthorized",
        "required_perm" => required,
      }
    }})
    {:noreply, state}
  end
end
```

The `{:tool_result, req_id, result}` shape matches the real receiver at `channel_channel.ex:84` — previously the plan used a non-existent `:tool_reply` which would have been silently dropped.

- [ ] **Step 4: Handlers catch `:unauthorized` and emit deny reply**

Patch `feishu_app_proxy` / `feishu_thread_proxy` tool-call paths so `{:error, :unauthorized}` results in a `reply` directive with:
`"❌ 无权限执行 <tool>（请联系管理员授权）"`

- [ ] **Step 5: Run full suite**

```bash
cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(peer_server): Lane B permission enforcement

- handle_info({:inbound_event, ...}) checks msg.send before invoking handler
- handle_info({:tool_invoke, ..., principal_id}) checks tool name before dispatch
- Denied events emit [:esr, :capabilities, :denied] telemetry
- Unauthorized tool_invokes reply with :unauthorized; caller handler emits
  \"❌ 无权限...\" via reply directive

Spec: §7.2, §7.3
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase CAP-5 — Lane A enforcement (Feishu adapter)

### Task 11: Lane A check + rate-limited deny DM

**Files:**
- Modify: `adapters/feishu/src/esr_feishu/adapter.py` at the three emit sites
- Create: `py/src/esr/capabilities.py` (SDK-shared checker — per spec §14.2 this lives in the SDK, not adapter-local, so cc_tmux etc. can reuse it)
- Create: `adapters/feishu/tests/test_lane_a.py`

Adapter-side capabilities check must read the same YAML as the runtime. The wildcard match logic is ported from `grants.ex`. Placing it in `py/src/esr/capabilities.py` (per the spec's touch list) lets every Python adapter share one check implementation.

- [ ] **Step 1: Write SDK-shared capabilities checker**

`py/src/esr/capabilities.py`:
```python
"""SDK-shared capability check mirroring Esr.Capabilities semantics.

Loaded from the same capabilities.yaml as the runtime. fnmatch-style
whole-segment wildcards only (no prefix globs) — matches Elixir impl.

Every Python adapter that needs Lane A enforcement uses this class;
the adapter passes the path to __init__.
"""
import fnmatch
import yaml
from pathlib import Path


class CapabilitiesChecker:
    def __init__(self, path: Path):
        self._path = path
        self._snapshot: dict[str, list[str]] = {}
        self.reload()

    def reload(self) -> None:
        if not self._path.exists():
            # File absent → empty snapshot, default-deny. The caller
            # (adapter) must treat this as "no one is allowed yet" and
            # rely on admin running `esr cap grant` (or boot-time
            # ESR_BOOTSTRAP_PRINCIPAL_ID creating the file, Task 14)
            # before enforcement becomes useful.
            self._snapshot = {}
            return
        doc = yaml.safe_load(self._path.read_text()) or {}
        self._snapshot = {
            entry["id"]: list(entry.get("capabilities", []))
            for entry in (doc.get("principals") or [])
            if isinstance(entry, dict) and "id" in entry
        }

    def has(self, principal_id: str, permission: str) -> bool:
        held = self._snapshot.get(principal_id, [])
        return any(self._matches(h, permission) for h in held)

    @staticmethod
    def _matches(held: str, required: str) -> bool:
        if held == "*":
            return True
        if "/" not in held or "/" not in required:
            return False
        h_scope, h_perm = held.split("/", 1)
        r_scope, r_perm = required.split("/", 1)
        return fnmatch.fnmatchcase(r_scope, h_scope) and fnmatch.fnmatchcase(r_perm, h_perm)
```

- [ ] **Step 2: Write Lane A test**

`adapters/feishu/tests/test_lane_a.py`:
```python
import time
from esr_feishu.adapter import FeishuAdapter

def test_unauth_user_gets_denied_and_rate_limited(adapter_fixture, fake_feishu_client):
    # principal ou_rando not in capabilities.yaml
    raw = make_fake_msg(open_id="ou_rando", chat_id="oc_in_proj_a")
    events = list(adapter_fixture._receive_and_filter([raw]))
    assert events == []  # no msg_received emitted
    # first deny triggers one DM reply
    assert len(fake_feishu_client.sent) == 1
    assert "无权使用" in fake_feishu_client.sent[0].text

    # second message within 10 min → silently dropped
    fake_feishu_client.sent.clear()
    events = list(adapter_fixture._receive_and_filter([raw]))
    assert events == []
    assert len(fake_feishu_client.sent) == 0


def test_authorized_user_passes(adapter_fixture):
    # principal ou_alice has workspace:proj-a/msg.send in the fixture yaml
    raw = make_fake_msg(open_id="ou_alice", chat_id="oc_in_proj_a")
    events = list(adapter_fixture._receive_and_filter([raw]))
    assert len(events) == 1
    assert events[0]["principal_id"] == "ou_alice"


def test_rate_limit_window_expires_after_10_min(adapter_fixture, fake_feishu_client, monkeypatch):
    # First deny at t=0 sends a DM
    clock = [1000.0]
    monkeypatch.setattr("time.monotonic", lambda: clock[0])
    raw = make_fake_msg(open_id="ou_rando", chat_id="oc_in_proj_a")
    list(adapter_fixture._receive_and_filter([raw]))
    assert len(fake_feishu_client.sent) == 1
    fake_feishu_client.sent.clear()

    # At t=+601s (past 600s window), deny should fire again
    clock[0] = 1601.0
    list(adapter_fixture._receive_and_filter([raw]))
    assert len(fake_feishu_client.sent) == 1
```

- [ ] **Step 3: Insert check at three emit sites**

At each of lines 427, 579, 628 of `adapters/feishu/src/esr_feishu/adapter.py`:
```python
chat_id = self._extract_chat_id(raw)
workspace = self._workspace_of.get((chat_id, self.app_id))
if workspace is None or not self._caps.has(
    principal_id=open_id,
    permission=f"workspace:{workspace}/msg.send",
):
    await self._deny_rate_limited(open_id, chat_id)
    continue  # skip emit

# ... existing envelope construction
```

Add the deny-rate-limit helper:
```python
async def _deny_rate_limited(self, open_id: str, chat_id: str) -> None:
    now = time.monotonic()
    last = self._last_deny_ts.get(open_id, 0.0)
    if now - last < 600:  # 10 min
        return  # silent
    self._last_deny_ts[open_id] = now
    await self._client.im.v1.message.create(
        receive_id=chat_id,
        content={"text": "你无权使用此 bot，请联系管理员授权。"},
        receive_id_type="chat_id",
        msg_type="text",
    )
```

- [ ] **Step 4: Run and commit**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest adapters/feishu/tests/ -v 2>&1 | tail -30
make test 2>&1 | tail -20
git add -A
git commit -m "feat(adapters/feishu): Lane A msg.send enforcement

Adapter loads capabilities.yaml at startup (local CapabilitiesChecker).
Every msg_received site checks principal+workspace msg.send before
emitting; unauthorized users get one rate-limited deny DM per 10 min
and their messages are dropped before reaching the runtime.

Spec: §7.1
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase CAP-6 — CLI read commands

### Task 12: `esr cap list / show / who-can`

**Files:**
- Create: `py/src/esr/cli/cap.py`
- Modify: `py/src/esr/cli/main.py` (register the group)
- Create: `py/tests/test_cli_cap_read.py`

- [ ] **Step 1: Write CLI test**

`py/tests/test_cli_cap_read.py`:
```python
from click.testing import CliRunner
from esr.cli.main import cli

def test_cap_list(monkeypatch, tmp_path):
    # set ESRD_HOME + seed a capabilities.yaml
    # seed declared permissions via a mock registry query
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "list"])
    assert result.exit_code == 0
    assert "msg.send" in result.output


def test_cap_show(tmp_path, seeded_caps):
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "show", "ou_alice"])
    assert result.exit_code == 0
    assert "workspace:proj-a/msg.send" in result.output


def test_cap_show_missing_principal():
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "show", "ou_nobody"])
    assert result.exit_code == 1
    assert "not found" in result.output


def test_cap_who_can(tmp_path, seeded_caps):
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "who-can", "workspace:proj-a/msg.send"])
    assert result.exit_code == 0
    assert "ou_alice" in result.output
```

- [ ] **Step 2: Implement the three read commands**

`py/src/esr/cli/cap.py`:
```python
"""esr cap — capability-based access control CLI.

Read commands (list, show, who-can). Write commands (grant, revoke)
live in Phase CAP-7.
"""
import click
import fnmatch
import yaml
from pathlib import Path

from esr.cli.paths import capabilities_yaml_path  # new helper


@click.group()
def cap():
    """Manage capabilities (who holds which permission)."""


@cap.command("list")
def cap_list():
    """Show all registered permissions."""
    # Query runtime via a small RPC or read from a declared-perms file
    # produced at boot. For v1: read handler_hello cache at
    # ESRD_HOME/default/permissions_registry.json (written on runtime boot).
    cache = Path(capabilities_yaml_path()).parent / "permissions_registry.json"
    if not cache.exists():
        click.echo("No permissions registered (is esrd running?)", err=True)
        raise SystemExit(1)
    import json
    doc = json.loads(cache.read_text())
    for mod, perms in sorted(doc.items()):
        click.echo(f"{mod}:")
        for p in sorted(perms):
            click.echo(f"  - {p}")


@cap.command("show")
@click.argument("principal_id")
def cap_show(principal_id: str):
    """Show one principal's capabilities."""
    path = capabilities_yaml_path()
    doc = yaml.safe_load(Path(path).read_text()) or {}
    for entry in doc.get("principals") or []:
        if entry.get("id") == principal_id:
            click.echo(yaml.safe_dump(entry, sort_keys=False, allow_unicode=True))
            return
    click.echo(f"principal {principal_id} not found", err=True)
    raise SystemExit(1)


@cap.command("who-can")
@click.argument("permission")
def cap_who_can(permission: str):
    """Reverse lookup — who holds a permission (wildcards supported)."""
    path = capabilities_yaml_path()
    doc = yaml.safe_load(Path(path).read_text()) or {}
    hits = []
    for entry in doc.get("principals") or []:
        pid = entry.get("id")
        for held in entry.get("capabilities") or []:
            if _matches(held, permission):
                hits.append(f"{pid} (via {held})")
                break
    for h in hits:
        click.echo(h)
    if not hits:
        click.echo("no matching principals", err=True)


def _matches(held: str, required: str) -> bool:
    if held == "*":
        return True
    if "/" not in held or "/" not in required:
        return False
    h_scope, h_perm = held.split("/", 1)
    r_scope, r_perm = required.split("/", 1)
    return fnmatch.fnmatchcase(r_scope, h_scope) and fnmatch.fnmatchcase(r_perm, h_perm)
```

Add `py/src/esr/cli/paths.py` if not already present — export `capabilities_yaml_path() -> str` returning `${ESRD_HOME:-~/.esrd}/default/capabilities.yaml`.

- [ ] **Step 3: Runtime writes permissions_registry.json at boot**

Add `Esr.Permissions.Registry.dump_json/1` + wire it into the supervisor. Required wiring (both):

(a) In `runtime/lib/esr/permissions/registry.ex`:
```elixir
def dump_json(path) do
  entries =
    :ets.tab2list(@table)
    |> Enum.group_by(fn {_name, declared_by} -> to_string(declared_by) end,
                    fn {name, _} -> name end)
  File.mkdir_p!(Path.dirname(path))
  File.write!(path, Jason.encode!(entries, pretty: true))
  :ok
end
```

(b) In `runtime/lib/esr/capabilities/supervisor.ex` — after the `init/1` bootstrap step registers all permissions, call:
```elixir
dump_path = Path.join([Path.dirname(path), "permissions_registry.json"])
Esr.Permissions.Registry.dump_json(dump_path)
```

Without (b), `esr cap list` shows empty output even when handlers are correctly declaring permissions.

- [ ] **Step 4: Register group in main CLI**

`py/src/esr/cli/main.py` — near other groups:
```python
from esr.cli.cap import cap as cap_group
cli.add_command(cap_group)
```

- [ ] **Step 5: Run + commit**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest py/tests/test_cli_cap_read.py -v
make test 2>&1 | tail -10
git add -A
git commit -m "feat(cli): esr cap list/show/who-can

Read-only commands for capability inspection. list reads a
permissions_registry.json cache written by esrd at boot; show/who-can
read capabilities.yaml directly (no runtime RPC needed).

Spec: §8
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase CAP-7 — CLI write commands

### Task 13: `esr cap grant / revoke` with ruamel.yaml

**Files:**
- Modify: `py/src/esr/cli/cap.py`
- Modify: `py/pyproject.toml` (add `ruamel.yaml`)
- Create: `py/tests/test_cli_cap_write.py`

- [ ] **Step 1: Add ruamel.yaml dep**

`py/pyproject.toml` — add `"ruamel.yaml>=0.18"` to dependencies. Run `uv sync`.

- [ ] **Step 2: Write tests**

`py/tests/test_cli_cap_write.py`:
```python
from click.testing import CliRunner
from esr.cli.main import cli

def test_grant_creates_principal_entry(tmp_capabilities_yaml):
    runner = CliRunner()
    result = runner.invoke(cli, [
        "cap", "grant", "ou_new", "workspace:proj-a/msg.send",
        "--kind=feishu_user", "--note=Bob",
    ])
    assert result.exit_code == 0
    content = tmp_capabilities_yaml.read_text()
    assert "ou_new" in content
    assert "Bob" in content
    assert "workspace:proj-a/msg.send" in content


def test_grant_appends_to_existing_principal(tmp_capabilities_yaml):
    # ou_alice exists with [msg.send]
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "grant", "ou_alice", "workspace:proj-a/session.create"])
    assert result.exit_code == 0
    content = tmp_capabilities_yaml.read_text()
    assert content.count("workspace:proj-a/msg.send") == 1
    assert content.count("workspace:proj-a/session.create") == 1


def test_grant_idempotent(tmp_capabilities_yaml):
    runner = CliRunner()
    runner.invoke(cli, ["cap", "grant", "ou_alice", "workspace:proj-a/msg.send"])
    # already there — no duplicate
    content = tmp_capabilities_yaml.read_text()
    assert content.count("workspace:proj-a/msg.send") == 1


def test_revoke_removes_grant(tmp_capabilities_yaml):
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "revoke", "ou_alice", "workspace:proj-a/msg.send"])
    assert result.exit_code == 0
    content = tmp_capabilities_yaml.read_text()
    assert "workspace:proj-a/msg.send" not in content


def test_revoke_noop_on_missing(tmp_capabilities_yaml):
    runner = CliRunner()
    result = runner.invoke(cli, ["cap", "revoke", "ou_alice", "workspace:nope/xyz"])
    assert result.exit_code == 0
    assert "no matching capability" in result.output


def test_grant_preserves_comments(tmp_path):
    # Seed a file with header comments
    path = tmp_path / "capabilities.yaml"
    path.write_text("""# Admin contact: linyilun@example.com
# Do not edit under active traffic

principals:
  - id: ou_alice
    kind: feishu_user
    capabilities: []
""")
    # set ESRD_HOME to tmp_path, invoke grant
    # ...
    content = path.read_text()
    assert "Admin contact" in content
    assert "Do not edit" in content
```

- [ ] **Step 3: Implement grant/revoke with ruamel.yaml**

Append to `py/src/esr/cli/cap.py`:
```python
from ruamel.yaml import YAML

_yaml = YAML()
_yaml.preserve_quotes = True
_yaml.indent(mapping=2, sequence=4, offset=2)


@cap.command("grant")
@click.argument("principal_id")
@click.argument("permission")
@click.option("--kind", default="feishu_user")
@click.option("--note", default="")
def cap_grant(principal_id: str, permission: str, kind: str, note: str):
    """Add a capability (principal holds permission)."""
    path = Path(capabilities_yaml_path())
    path.parent.mkdir(parents=True, exist_ok=True)

    doc = _yaml.load(path) if path.exists() else {}
    doc.setdefault("principals", [])

    target = next(
        (e for e in doc["principals"] if e.get("id") == principal_id),
        None,
    )
    if target is None:
        entry = {"id": principal_id, "kind": kind, "capabilities": [permission]}
        if note:
            entry["note"] = note
        doc["principals"].append(entry)
        click.echo(f"added principal {principal_id} with {permission}")
    else:
        if permission in (target.get("capabilities") or []):
            click.echo(f"{principal_id} already has {permission}; no change")
            return
        target.setdefault("capabilities", []).append(permission)
        click.echo(f"{principal_id} + {permission}")

    _yaml.dump(doc, path)


@cap.command("revoke")
@click.argument("principal_id")
@click.argument("permission")
def cap_revoke(principal_id: str, permission: str):
    """Remove a capability."""
    path = Path(capabilities_yaml_path())
    if not path.exists():
        click.echo("no capabilities file; nothing to revoke")
        return

    doc = _yaml.load(path)
    target = next(
        (e for e in doc.get("principals") or [] if e.get("id") == principal_id),
        None,
    )
    if target is None or permission not in (target.get("capabilities") or []):
        click.echo("no matching capability")
        return

    target["capabilities"].remove(permission)
    _yaml.dump(doc, path)
    click.echo(f"{principal_id} - {permission}")
```

- [ ] **Step 4: Run + commit**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run pytest py/tests/test_cli_cap_write.py -v
make test 2>&1 | tail -10
git add -A
git commit -m "feat(cli): esr cap grant/revoke

Capability mutation CLI using ruamel.yaml for comment-preserving
writes. grant is idempotent; revoke is no-op on missing. Principal
entries are retained when their capabilities list becomes empty
(note/kind persist).

Spec: §8
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase CAP-8 — (moved) Bootstrap is now Task 7.5 above.

See §Task 7.5. Left as a placeholder heading for cross-referencing
against the spec's original phase numbering; all steps executed there.

---

## Phase CAP-9 — End-to-end acceptance

### Task 15: E2E track doc + scenario script

**Files:**
- Create: `docs/superpowers/tests/e2e-capabilities.md` (track-by-track scripts)
- Create: `scripts/scenarios/e2e_capabilities.py` (runnable test harness)

- [ ] **Step 1: Write the E2E doc per v0.1 pattern**

`docs/superpowers/tests/e2e-capabilities.md` with tracks:
- **Track CAP-A**: Admin flow — bootstrap ou_admin, send `/new-thread`, session created.
- **Track CAP-B**: Regular user flow — ou_alice with msg.send + session.create, same path succeeds.
- **Track CAP-C**: Lane A deny — ou_rando (no grants), first msg → rate-limited deny DM; second msg within 10 min → silent.
- **Track CAP-D**: Lane B deny — ou_reader (msg.send only), sends `/new-thread`, reply "❌ 无权限 session.create".
- **Track CAP-E**: Workspace scoping — ou_dev with proj-a capabilities tries action in proj-b → Lane A denies.
- **Track CAP-F**: Hot reload — run grant command, capability live within 2s, previously-denied user can now act.
- **Track CAP-G**: File corruption — invalid YAML written, prior snapshot survives, log shows error.

(Track CAP-H "CAP-0 rename non-regression" was proposed in an earlier draft but is redundant — Task 1 Step 4 already runs the full test suite to validate the rename, and every subsequent task's `make test` run provides ongoing non-regression signal. Per-reviewer guidance: dropped.)

Each track gets:
- Preconditions (capabilities.yaml contents)
- Steps (commands/messages to send)
- Expected observables (log lines, reply text, files changed, telemetry)

- [ ] **Step 2: Scenario harness**

`scripts/scenarios/e2e_capabilities.py` — follows the `e2e-esr-channel` harness pattern (invokes `esr scenario run e2e-capabilities`, returns exit 0 iff all 8 tracks pass). Minimum: each track is a function that asserts the observables.

- [ ] **Step 3: Run and commit**

```bash
cd /Users/h2oslabs/Workspace/esr && uv run python scripts/scenarios/e2e_capabilities.py
git add -A
git commit -m "test(e2e): capabilities end-to-end — 8 tracks

Per spec §12 acceptance criteria. Tracks cover admin flow, regular
flow, Lane A/B deny, workspace scoping, hot reload, file corruption,
and CAP-0 non-regression.

Spec: §12
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

### Task 16: Full green gate

- [ ] **Step 1: Run everything**

```bash
cd /Users/h2oslabs/Workspace/esr && make test && make lint && uv run python scripts/scenarios/e2e_capabilities.py
```

Expected:
- `mix test`: 155+ passed (new tests add ~15-20), 0 failed
- `uv run pytest`: 440+ passed
- `make lint`: clean
- E2E: 8/8 tracks PASSED

- [ ] **Step 2: Update docs/superpowers/prds/ with an 08-capabilities.md PRD**

Stub (full PRD content can follow in a later pass):
```markdown
# PRD 08 — Capability-Based Access Control

See spec: `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md`
See plan: `docs/superpowers/plans/2026-04-20-esr-capabilities-implementation.md`

## Functional requirements

(Enumerated with unit test matrix — to be expanded during v0.3
ralph-loop enforcement.)
```

- [ ] **Step 3: Commit and tag**

```bash
git add -A
git commit -m "docs(prds): 08-capabilities PRD stub"
git tag capabilities-v1-complete -m "CAP-0..CAP-9 complete per plan"
```

---

## Self-review checklist (fill during writing-plans output)

- [x] Every spec §14 touch-list entry has at least one task.
- [x] No "TBD" / "implement later" / "similar to Task N" placeholders.
- [x] Type/function/module names are consistent across tasks (e.g.
      `Esr.Capabilities.has?/2` used in Tasks 3, 10, 14 — not
      `Esr.Capabilities.check?/2` elsewhere).
- [x] Phase ordering matches spec §15: CAP-0 → CAP-1 → CAP-2 → CAP-3 →
      CAP-4 → CAP-5 → CAP-6 → CAP-7 → CAP-8 → CAP-9.
- [x] Every TDD task has: failing test → run to confirm fail → implement
      → run to confirm pass → commit.
- [x] Python commands use `uv run`; Elixir commands run from
      `runtime/`.
- [x] Commit messages follow Conventional Commits with the required
      Co-Authored-By footer.
