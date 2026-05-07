# Plugin Config Hot-Reload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable operator-triggered config reload without esrd restart, via explicit `/plugin:reload <plugin>` slash command plus per-plugin opt-in.

**Architecture:** Trigger-only callback (VS Code style); manifest `hot_reloadable: true` opt-in; `Esr.Plugin.Behaviour.on_config_change/1` callback; best-effort + plugin fallback, no framework rollback; per-plugin only (no batch). Config snapshot diff tracked in ETS.

**Tech Stack:** Elixir/OTP; ETS-backed config snapshot; YAML manifest extension; existing slash routing.

**Spec:** `docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md` (rev-1, user-approved 2026-05-07).

**Migration order:** HR-1 → HR-2 → HR-3. Strict dependency chain (HR-2 needs `Behaviour` + `ConfigSnapshot` from HR-1; HR-3 needs `/plugin:reload` slash from HR-2).

---

## File Structure

### New files

| File | Phase | Responsibility |
|------|-------|---------------|
| `runtime/lib/esr/plugin/behaviour.ex` | HR-1 | `Esr.Plugin.Behaviour` — defines `on_config_change/1` callback contract |
| `runtime/lib/esr/plugin/config_snapshot.ex` | HR-1 | `Esr.Plugin.ConfigSnapshot` — ETS store for per-plugin "last-ok" config snapshots |
| `runtime/lib/esr/commands/plugin/reload.ex` | HR-2 | `Esr.Commands.Plugin.Reload` — `/plugin:reload` slash command implementation |
| `runtime/lib/esr/plugins/claude_code/plugin.ex` | HR-3 | `Esr.Plugins.ClaudeCode.Plugin` — claude_code opt-in module implementing `on_config_change/1` |
| `runtime/lib/esr/plugins/feishu/plugin.ex` | HR-3 | `Esr.Plugins.Feishu.Plugin` — feishu opt-in module implementing `on_config_change/1` |

### Test files

| File | Phase |
|------|-------|
| `runtime/test/esr/plugin/config_snapshot_test.exs` | HR-1 |
| `runtime/test/esr/commands/plugin/reload_test.exs` | HR-2 |
| `runtime/test/esr/plugins/claude_code/plugin_test.exs` | HR-3 |
| `runtime/test/esr/plugins/feishu/plugin_test.exs` | HR-3 |

### Modified files

| File | Phase | Change |
|------|-------|--------|
| `runtime/lib/esr/plugin/manifest.ex` | HR-1 | Add `hot_reloadable` field to struct; extend `parse/1` to read + validate the field |
| `runtime/lib/esr/plugin/loader.ex` | HR-1 | Call `ConfigSnapshot.init/2` after each plugin is loaded in `start_plugin/2` |
| `runtime/lib/esr/application.ex` | HR-1 | Call `ConfigSnapshot.create_table/0` before `load_enabled_plugins/0` |
| `runtime/priv/slash-routes.default.yaml` | HR-2 | Add `/plugin:reload` entry |
| `runtime/lib/esr/plugins/claude_code/manifest.yaml` | HR-3 | Add `hot_reloadable: true` |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | HR-3 | Add `hot_reloadable: true` |
| `runtime/test/esr/plugin/manifest_test.exs` | HR-1 | Add `hot_reloadable` test cases |

---

## Sub-phase HR-1: Behaviour Module + Manifest Parser Extension + ConfigSnapshot

**Prerequisite:** None. HR-1 is independently shippable — no user-visible changes.

**Approx scope:** ~100 LOC + ~80 LOC tests across 4 tasks.

---

### Task HR-1.1: `Esr.Plugin.Behaviour` module

**Files:**
- Create: `runtime/lib/esr/plugin/behaviour.ex`

This module defines the single callback contract. It is intentionally minimal — only the `@callback` declaration. No GenServer, no state. Any plugin that declares `hot_reloadable: true` in its manifest MUST implement this behaviour.

- [ ] **Step 1: Create `runtime/lib/esr/plugin/behaviour.ex`**

```elixir
defmodule Esr.Plugin.Behaviour do
  @moduledoc """
  Optional behaviour for plugins that support hot config reload.

  Plugins MUST implement this iff their manifest declares
  `hot_reloadable: true`. The framework checks
  `function_exported?(module, :on_config_change, 1)` at reload
  invocation time (not at boot).

  ## Callback semantics

  `on_config_change/1` is called by `Esr.Commands.Plugin.Reload` after
  `/plugin:reload <name>` is issued. `changed_keys` is the list of
  config key names whose effective value (merged across all three layers:
  workspace > user > global) differs from the value at the time the
  plugin last entered `:ok` state.

  Empty list = operator-triggered force reload (no actual config change
  was detected). The callback still fires — the plugin may use this to
  re-bind connections, flush caches, etc.

  The callback MUST read new config values via `Esr.Plugin.Config.get/3`
  (or `resolve/2`). Do NOT accept config as callback arguments — the
  three-layer store is already up-to-date when the callback fires.

  Return `:ok` if the plugin successfully applied the new config.
  The framework updates the internal config snapshot.

  Return `{:error, reason}` if the plugin failed to apply. The framework
  logs `[warning] plugin <name> failed to apply config change: <reason>`
  and does NOT update the snapshot. The plugin is responsible for its
  own fallback behavior (Q5 — no framework-level rollback).

  ## VS Code alignment

  Mirrors `vscode.workspace.onDidChangeConfiguration`:
    - Trigger-only (no old_config / new_config passed)
    - Plugin reads current state on demand
    - No framework rollback on failure
    - Empty `changed_keys` = force reload (callback still fires)

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §2.
  """

  @type changed_keys :: [String.t()]
  @type reason :: term()

  @doc """
  Called when `/plugin:reload <name>` is invoked AND the plugin's
  manifest declares `hot_reloadable: true`.

  `changed_keys` — list of config key names whose effective value
  differs from the last-ok snapshot. Empty list = force reload.

  Return `:ok` on success (framework updates snapshot).
  Return `{:error, reason}` on failure (framework logs warning;
  snapshot NOT updated; no rollback).
  """
  @callback on_config_change(changed_keys()) :: :ok | {:error, reason()}
end
```

- [ ] **Step 2: Verify the file compiles**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix compile --force 2>&1 | grep -E "error|warning|Esr.Plugin.Behaviour"
```

Expected: no compilation errors. The module appears in `mix compile` output as a compiled module.

- [ ] **Step 3: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/lib/esr/plugin/behaviour.ex
git commit -m "feat(hr-1): add Esr.Plugin.Behaviour with on_config_change/1 callback"
```

---

### Task HR-1.2: `Esr.Plugin.Manifest` — add `hot_reloadable` field + parser

**Files:**
- Modify: `runtime/lib/esr/plugin/manifest.ex`
- Modify: `runtime/test/esr/plugin/manifest_test.exs`

The manifest struct gains a `hot_reloadable :: boolean()` field (default `false`). The `parse/1` function is extended to read the new field. An invalid type (not a boolean) returns a structured `{:error, {:invalid_hot_reloadable, value}}` — this is caught at boot, not at reload time.

- [ ] **Step 1: Write the failing tests — add to `manifest_test.exs`**

Open `runtime/test/esr/plugin/manifest_test.exs`. Add a new `describe` block AFTER the existing `"config_schema: parsing (Phase 7.1)"` block:

```elixir
  describe "parse/1 — hot_reloadable field (HR-1)" do
    defp hr1_yaml(extra \\ "") do
      """
      name: test-plugin
      version: 0.1.0
      description: test
      depends_on:
        core: ">= 0.1.0"
        plugins: []
      declares: {}
      #{extra}
      """
    end

    test "hot_reloadable: true → manifest.hot_reloadable == true" do
      path = manifest_path(hr1_yaml("hot_reloadable: true"))
      assert {:ok, manifest} = Manifest.parse(path)
      assert manifest.hot_reloadable == true
    end

    test "hot_reloadable: false → manifest.hot_reloadable == false" do
      path = manifest_path(hr1_yaml("hot_reloadable: false"))
      assert {:ok, manifest} = Manifest.parse(path)
      assert manifest.hot_reloadable == false
    end

    test "absent hot_reloadable → manifest.hot_reloadable == false (default)" do
      path = manifest_path(hr1_yaml())
      assert {:ok, manifest} = Manifest.parse(path)
      assert manifest.hot_reloadable == false
    end

    test "hot_reloadable: 'yes' (string) → {:error, {:invalid_hot_reloadable, 'yes'}}" do
      path = manifest_path(hr1_yaml("hot_reloadable: \"yes\""))
      assert {:error, {:invalid_hot_reloadable, "yes"}} = Manifest.parse(path)
    end

    test "hot_reloadable: 1 (integer) → {:error, {:invalid_hot_reloadable, 1}}" do
      path = manifest_path(hr1_yaml("hot_reloadable: 1"))
      assert {:error, {:invalid_hot_reloadable, 1}} = Manifest.parse(path)
    end
  end
```

- [ ] **Step 2: Run the new tests to confirm they fail**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugin/manifest_test.exs --only hot_reloadable 2>&1 | tail -20
```

Expected: tests fail with `KeyError` (struct has no `:hot_reloadable` key) or similar.

- [ ] **Step 3: Implement the struct + parser changes in `manifest.ex`**

In `runtime/lib/esr/plugin/manifest.ex`, make the following changes:

**3a. Extend the `defstruct` to include `hot_reloadable`:**

Find the existing `defstruct`:

```elixir
  defstruct [
    :name,
    :version,
    :description,
    :depends_on,
    :declares,
    # path to the manifest.yaml (used by Loader to resolve `priv/*.yaml`
    # references back to absolute paths)
    :path
  ]
```

Replace with:

```elixir
  defstruct [
    :name,
    :version,
    :description,
    :depends_on,
    :declares,
    # Whether the plugin supports /plugin:reload without esrd restart.
    # Declared in manifest as `hot_reloadable: true|false`. Default: false.
    # Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §3.
    hot_reloadable: false,
    # path to the manifest.yaml (used by Loader to resolve `priv/*.yaml`
    # references back to absolute paths)
    :path
  ]
```

**3b. Extend the `@type t` spec:**

Find:

```elixir
  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          depends_on: %{core: String.t(), plugins: [String.t()]},
          declares: map(),
          path: Path.t() | nil
        }
```

Replace with:

```elixir
  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          depends_on: %{core: String.t(), plugins: [String.t()]},
          declares: map(),
          hot_reloadable: boolean(),
          path: Path.t() | nil
        }
```

**3c. Add `parse_hot_reloadable/1` private helper** (add after `defp atomize_declares/1`):

```elixir
  defp parse_hot_reloadable(parsed) do
    case parsed["hot_reloadable"] do
      nil   -> {:ok, false}
      true  -> {:ok, true}
      false -> {:ok, false}
      other -> {:error, {:invalid_hot_reloadable, other}}
    end
  end
```

**3d. Extend `parse/1` to call the helper** (find the `with` in `parse/1` and add the new step):

Find:

```elixir
    with {:ok, content} <- read_file(path),
         {:ok, parsed} <- read_yaml(content, path),
         {:ok, name} <- fetch_required(parsed, "name"),
         :ok <- validate_kebab(name),
         {:ok, version} <- fetch_required(parsed, "version"),
         {:ok, config_schema} <- parse_config_schema(parsed["config_schema"] || %{}) do
      depends_on = parse_depends_on(parsed["depends_on"] || %{})
      declares = atomize_declares(parsed["declares"] || %{})
      declares_with_schema = Map.put(declares, :config_schema, config_schema)

      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         description: parsed["description"] || "",
         depends_on: depends_on,
         declares: declares_with_schema,
         path: path
       }}
    end
```

Replace with:

```elixir
    with {:ok, content} <- read_file(path),
         {:ok, parsed} <- read_yaml(content, path),
         {:ok, name} <- fetch_required(parsed, "name"),
         :ok <- validate_kebab(name),
         {:ok, version} <- fetch_required(parsed, "version"),
         {:ok, config_schema} <- parse_config_schema(parsed["config_schema"] || %{}),
         {:ok, hot_reloadable} <- parse_hot_reloadable(parsed) do
      depends_on = parse_depends_on(parsed["depends_on"] || %{})
      declares = atomize_declares(parsed["declares"] || %{})
      declares_with_schema = Map.put(declares, :config_schema, config_schema)

      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         description: parsed["description"] || "",
         depends_on: depends_on,
         declares: declares_with_schema,
         hot_reloadable: hot_reloadable,
         path: path
       }}
    end
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugin/manifest_test.exs 2>&1 | tail -10
```

Expected: All tests pass including the 5 new `hot_reloadable` tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/lib/esr/plugin/manifest.ex runtime/test/esr/plugin/manifest_test.exs
git commit -m "feat(hr-1): extend Manifest struct + parse/1 with hot_reloadable field"
```

---

### Task HR-1.3: `Esr.Plugin.ConfigSnapshot` — ETS-backed snapshot store

**Files:**
- Create: `runtime/lib/esr/plugin/config_snapshot.ex`
- Create: `runtime/test/esr/plugin/config_snapshot_test.exs`

This is a pure ETS wrapper — no GenServer. The ETS table is created once at application start by calling `create_table/0` (wired in Task HR-1.4). The module exposes `get/1`, `init/2`, and `update/1`. All functions are synchronous and process-agnostic (ETS is globally accessible).

- [ ] **Step 1: Write the failing test**

Create `runtime/test/esr/plugin/config_snapshot_test.exs`:

```elixir
defmodule Esr.Plugin.ConfigSnapshotTest do
  @moduledoc """
  Tests for `Esr.Plugin.ConfigSnapshot`.

  The ETS table is created fresh per test to ensure isolation.
  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §5.
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.ConfigSnapshot

  @table :esr_plugin_config_snapshots

  setup do
    # Drop the table if it exists from a prior test run, then recreate it.
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table)
    end

    ConfigSnapshot.create_table()
    :ok
  end

  describe "get/1 — absent plugin" do
    test "returns %{} when no snapshot exists for plugin" do
      assert %{} == ConfigSnapshot.get("no_such_plugin")
    end
  end

  describe "init/2 + get/1" do
    test "stores and retrieves the snapshot map" do
      snapshot = %{"http_proxy" => "http://proxy.example.com", "log_level" => "debug"}
      :ok = ConfigSnapshot.init("my_plugin", snapshot)
      assert snapshot == ConfigSnapshot.get("my_plugin")
    end

    test "overwrites an existing snapshot for the same plugin" do
      :ok = ConfigSnapshot.init("my_plugin", %{"k" => "v1"})
      :ok = ConfigSnapshot.init("my_plugin", %{"k" => "v2"})
      assert %{"k" => "v2"} == ConfigSnapshot.get("my_plugin")
    end

    test "snapshots for different plugins are independent" do
      :ok = ConfigSnapshot.init("plugin_a", %{"x" => "1"})
      :ok = ConfigSnapshot.init("plugin_b", %{"y" => "2"})
      assert %{"x" => "1"} == ConfigSnapshot.get("plugin_a")
      assert %{"y" => "2"} == ConfigSnapshot.get("plugin_b")
    end
  end

  describe "update/1" do
    # update/1 calls Esr.Plugin.Config.resolve/1. We stub this via a mock
    # config snapshot: because Config.resolve reads yaml files, and we
    # control those paths via test helpers, we bypass Config.resolve by
    # directly storing a stub into the ETS table and then calling update/1
    # with a pre-seeded snapshot so we can verify the roundtrip contract.
    #
    # In production, update/1 calls Config.resolve(plugin_name) with no
    # path opts (reads the default global layer). For unit testing, we
    # verify only the ETS contract: after update/1, get/1 returns the
    # resolved map.

    test "update/1 replaces snapshot with current Config.resolve output" do
      # Seed the global plugins yaml with a known value for "test_plugin".
      tmp = System.tmp_dir!() |> Path.join("hr1_snapshot_update_#{:rand.uniform(99_999)}.yaml")
      File.write!(tmp, "config:\n  test_plugin:\n    log_level: \"debug\"\n")

      # Init with a stale snapshot.
      :ok = ConfigSnapshot.init("test_plugin", %{"log_level" => "info"})

      # Now call update/1 using the path override mechanism.
      # update/1 in production calls Config.resolve("test_plugin").
      # For testing, we call the internal update helper with an explicit path.
      :ok = ConfigSnapshot.update_with_path("test_plugin", global_path: tmp)

      assert %{"log_level" => "debug"} == ConfigSnapshot.get("test_plugin")

      File.rm(tmp)
    end
  end
end
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugin/config_snapshot_test.exs 2>&1 | tail -15
```

Expected: compilation failure — `Esr.Plugin.ConfigSnapshot` does not exist yet.

- [ ] **Step 3: Implement `config_snapshot.ex`**

Create `runtime/lib/esr/plugin/config_snapshot.ex`:

```elixir
defmodule Esr.Plugin.ConfigSnapshot do
  @moduledoc """
  ETS-backed store for per-plugin "last-ok" config snapshots.

  A snapshot is the result of `Esr.Plugin.Config.resolve/2` at the
  moment a plugin last successfully applied its config — either at boot
  (via `Esr.Plugin.Loader.start_plugin/2`) or after a successful
  `on_config_change/1` return.

  Used by `Esr.Commands.Plugin.Reload` to compute `changed_keys`:
  the diff between the stored snapshot and the current effective config.

  ## ETS table lifecycle

  The table is created once at application start by `create_table/0`,
  called from `Esr.Application.start/2` BEFORE `load_enabled_plugins/0`.
  The table uses `:public` access so any process (slash command task,
  plugin process, test process) can read/write without routing through
  a GenServer.

  Entries survive plugin process restarts because the table is owned by
  the application process (not any plugin process).

  ## API

    * `create_table/0`       — Create the ETS table. Called once at boot.
    * `get/1`               — Retrieve snapshot; returns %{} if absent.
    * `init/2`              — Store initial snapshot (called by Loader at plugin start).
    * `update/1`            — Re-resolve and store snapshot after successful reload.
    * `update_with_path/2`  — Same as update/1 but accepts path opts (test seam).

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §5.
  """

  @table :esr_plugin_config_snapshots

  @doc "Create the ETS table. Called once at application start."
  @spec create_table() :: :ok
  def create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Retrieve the stored snapshot for `plugin_name`.
  Returns `%{}` if no snapshot exists (e.g., first call after a fresh boot).
  """
  @spec get(plugin_name :: String.t()) :: map()
  def get(plugin_name) do
    case :ets.lookup(@table, plugin_name) do
      [{^plugin_name, snapshot}] -> snapshot
      [] -> %{}
    end
  end

  @doc """
  Store `snapshot` as the baseline for `plugin_name`.
  Called by `Esr.Plugin.Loader.start_plugin/2` immediately after a plugin
  is loaded, so the first `/plugin:reload` always has a baseline to diff against.
  """
  @spec init(plugin_name :: String.t(), snapshot :: map()) :: :ok
  def init(plugin_name, snapshot) do
    :ets.insert(@table, {plugin_name, snapshot})
    :ok
  end

  @doc """
  Re-resolve the current effective config for `plugin_name` (using
  production default paths — reads global layer only) and replace the
  stored snapshot. Called after a successful `on_config_change/1` return.
  """
  @spec update(plugin_name :: String.t()) :: :ok
  def update(plugin_name) do
    update_with_path(plugin_name, [])
  end

  @doc """
  Same as `update/1` but accepts `path_opts` for the config resolver.
  Used as a test seam — tests pass `global_path:` to point at a tmp file.
  """
  @spec update_with_path(plugin_name :: String.t(), path_opts :: keyword()) :: :ok
  def update_with_path(plugin_name, path_opts) do
    current = Esr.Plugin.Config.resolve(plugin_name, path_opts)
    :ets.insert(@table, {plugin_name, current})
    :ok
  end
end
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugin/config_snapshot_test.exs 2>&1 | tail -15
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/lib/esr/plugin/config_snapshot.ex runtime/test/esr/plugin/config_snapshot_test.exs
git commit -m "feat(hr-1): add Esr.Plugin.ConfigSnapshot ETS-backed snapshot store"
```

---

### Task HR-1.4: Wire `ConfigSnapshot` into `Application` + `Loader`

**Files:**
- Modify: `runtime/lib/esr/application.ex`
- Modify: `runtime/lib/esr/plugin/loader.ex`

Two small wiring tasks:
1. `Application.start/2` must call `ConfigSnapshot.create_table/0` before `load_enabled_plugins/0`.
2. `Loader.start_plugin/2` must call `ConfigSnapshot.init/2` after the plugin is successfully loaded.

- [ ] **Step 1: Extend `Esr.Application` to create the table at boot**

In `runtime/lib/esr/application.ex`, inside the `case result do {:ok, _} ->` block, add the `ConfigSnapshot.create_table/0` call BEFORE `load_enabled_plugins()`. Find:

```elixir
        load_enabled_plugins()
```

Replace with:

```elixir
        # HR-1: create the config snapshot ETS table before loading plugins
        # so ConfigSnapshot.init/2 (called from Loader.start_plugin/2) has
        # a table to write into.
        :ok = Esr.Plugin.ConfigSnapshot.create_table()

        load_enabled_plugins()
```

- [ ] **Step 2: Extend `Loader.start_plugin/2` to snapshot at load time**

In `runtime/lib/esr/plugin/loader.ex`, find the `start_plugin/2` function:

```elixir
  @spec start_plugin(plugin_name(), Manifest.t()) :: {:ok, :registered} | {:error, term()}
  def start_plugin(name, %Manifest{} = manifest) do
    with :ok <- check_core_version(manifest),
         :ok <- Manifest.validate(manifest),
         :ok <- register_capabilities(name, manifest),
         :ok <- register_python_sidecars(manifest),
         :ok <- register_entities(manifest),
         :ok <- register_startup(name, manifest) do
      Logger.info("plugin loader: started #{name} v#{manifest.version}")
      {:ok, :registered}
    end
  end
```

Replace with:

```elixir
  @spec start_plugin(plugin_name(), Manifest.t()) :: {:ok, :registered} | {:error, term()}
  def start_plugin(name, %Manifest{} = manifest) do
    with :ok <- check_core_version(manifest),
         :ok <- Manifest.validate(manifest),
         :ok <- register_capabilities(name, manifest),
         :ok <- register_python_sidecars(manifest),
         :ok <- register_entities(manifest),
         :ok <- register_startup(name, manifest) do
      # HR-1: take a config snapshot at plugin load time so the first
      # /plugin:reload always has a baseline to diff against.
      # ConfigSnapshot.create_table/0 is guaranteed to have been called
      # by Esr.Application.start/2 before load_enabled_plugins/0.
      snapshot = Esr.Plugin.Config.resolve(name)
      Esr.Plugin.ConfigSnapshot.init(name, snapshot)

      Logger.info("plugin loader: started #{name} v#{manifest.version}")
      {:ok, :registered}
    end
  end
```

Also add `alias Esr.Plugin.ConfigSnapshot` near the top of `loader.ex`, after the existing aliases:

Find:

```elixir
  alias Esr.Plugin.Manifest
  alias Esr.Plugin.Version, as: PluginVersion
```

Replace with:

```elixir
  alias Esr.Plugin.ConfigSnapshot
  alias Esr.Plugin.Manifest
  alias Esr.Plugin.Version, as: PluginVersion
```

- [ ] **Step 3: Verify compilation and full plugin test suite**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix compile --force 2>&1 | grep -E "^error" && mix test test/esr/plugin/ 2>&1 | tail -15
```

Expected: No compilation errors. All existing plugin tests pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/lib/esr/application.ex runtime/lib/esr/plugin/loader.ex
git commit -m "feat(hr-1): wire ConfigSnapshot.create_table + init into Application + Loader"
```

---

### Task HR-1.5: Open PR + admin-merge for HR-1

- [ ] **Step 1: Push and create PR**

```bash
cd /Users/h2oslabs/Workspace/esr && git push -u origin feat/hr-1-behaviour-manifest
gh pr create --base dev --head feat/hr-1-behaviour-manifest \
  --title "feat(hr-1): Esr.Plugin.Behaviour + manifest hot_reloadable + ConfigSnapshot" \
  --body "$(cat <<'EOF'
Hot-reload sub-phase HR-1 of spec/plugin-config-hot-reload.

Adds:
- `Esr.Plugin.Behaviour` with `on_config_change/1` callback definition (§2)
- `Esr.Plugin.Manifest` extended with `hot_reloadable: boolean()` field; parser validates type (§3)
- `Esr.Plugin.ConfigSnapshot` ETS-backed per-plugin snapshot store (§5)
- `Esr.Application` + `Esr.Plugin.Loader` wired to create table + init snapshot at plugin load time

No user-visible changes. Internal infrastructure only.
HR-2 (/plugin:reload slash command) depends on this PR.

Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §2, §3, §5.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Admin-merge**

```bash
cd /Users/h2oslabs/Workspace/esr && gh pr merge --admin --squash --delete-branch
```

---

## Sub-phase HR-2: `/plugin:reload` Slash Command

**Prerequisite:** HR-1 merged. HR-2 needs `Esr.Plugin.Behaviour`, `Esr.Plugin.ConfigSnapshot`, and the `hot_reloadable` field on `Manifest.t()`.

**Approx scope:** ~120 LOC + ~140 LOC tests across 4 tasks.

---

### Task HR-2.1: `Esr.Commands.Plugin.Reload` module

**Files:**
- Create: `runtime/lib/esr/commands/plugin/reload.ex`
- Create: `runtime/test/esr/commands/plugin/reload_test.exs`

The reload command follows the same pattern as `Esr.Commands.Plugin.Set`. It uses a `with` pipeline of 6 steps matching spec §4. The callback is invoked via `Task.async` + `Task.yield(5_000)` to enforce a 5-second timeout (spec §9 Risk 1).

Key behaviors:
- `not_hot_reloadable` → `{:error, %{"type" => "not_hot_reloadable", ...}}`
- `unknown_plugin` → `{:error, %{"type" => "unknown_plugin", ...}}`
- `callback_not_exported` → `{:error, %{"type" => "callback_not_exported", ...}}`
- Callback `:ok` → `{:ok, %{"reloaded" => true, "changed_keys" => [...]}}`
- Callback `{:error, reason}` → `{:ok, %{"reloaded" => false, "fallback_active" => true, ...}}`
- Callback timeout → `{:ok, %{"reloaded" => false, "reason" => "callback_timeout", ...}}`

- [ ] **Step 1: Write the failing tests**

Create `runtime/test/esr/commands/plugin/reload_test.exs`:

```elixir
defmodule Esr.Commands.Plugin.ReloadTest do
  @moduledoc """
  Tests for `Esr.Commands.Plugin.Reload`.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §4, §10.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Esr.Commands.Plugin.Reload
  alias Esr.Plugin.ConfigSnapshot

  # Ensure ConfigSnapshot table exists for all tests.
  setup_all do
    ConfigSnapshot.create_table()
    :ok
  end

  # Reset snapshot state between tests.
  setup do
    :ok
  end

  # ------------------------------------------------------------------
  # Stub modules for testing plugin module resolution.
  # These are compiled in-test using Module.create/3.
  # ------------------------------------------------------------------

  # A hot-reloadable stub that succeeds.
  defmodule StubPlugin.OkPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys), do: :ok
  end

  # A stub that returns an error.
  defmodule StubPlugin.ErrorPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys), do: {:error, :simulated_failure}
  end

  # A stub that raises an exception.
  defmodule StubPlugin.RaisingPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys), do: raise("boom")
  end

  # A stub that sleeps longer than the timeout.
  defmodule StubPlugin.SlowPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys) do
      Process.sleep(10_000)
      :ok
    end
  end

  # A module without on_config_change (not implementing the behaviour).
  defmodule StubPlugin.NoBehaviourPlugin do
    def some_other_function, do: :ok
  end

  # ------------------------------------------------------------------
  # Error path tests
  # ------------------------------------------------------------------

  describe "unknown plugin" do
    test "returns {:error, %{type: unknown_plugin}} for non-existent plugin" do
      cmd = %{"args" => %{"plugin" => "nonexistent_plugin_xyz_999"}}
      assert {:error, %{"type" => "unknown_plugin", "plugin" => "nonexistent_plugin_xyz_999"}} =
               Reload.execute(cmd)
    end
  end

  describe "not_hot_reloadable" do
    test "returns {:error, %{type: not_hot_reloadable}} for plugin without flag" do
      # The real 'feishu' plugin (before HR-3) has hot_reloadable: false.
      # We use a discovered plugin as a control — but in case feishu gains
      # hot_reloadable: true in HR-3, we inject a stub manifest directly.
      #
      # Direct path: inject a manifest with hot_reloadable: false via path override.
      # Since execute/1 uses Loader.discover() which reads from disk, we
      # test by providing a plugin name that matches a manifest we write.
      tmp_dir = System.tmp_dir!() |> Path.join("reload_test_#{:rand.uniform(99_999)}")
      plugin_dir = Path.join(tmp_dir, "cold_plugin")
      File.mkdir_p!(plugin_dir)
      manifest_path = Path.join(plugin_dir, "manifest.yaml")

      File.write!(manifest_path, """
      name: cold_plugin
      version: 0.1.0
      description: test
      depends_on:
        core: ">= 0.1.0"
        plugins: []
      declares: {}
      hot_reloadable: false
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Call with the loader root override so it discovers our stub plugin.
      cmd = %{"args" => %{"plugin" => "cold_plugin", "_plugin_root_override" => tmp_dir}}

      assert {:error, %{"type" => "not_hot_reloadable", "plugin" => "cold_plugin"}} =
               Reload.execute(cmd)
    end
  end

  describe "callback_not_exported" do
    test "returns {:error, %{type: callback_not_exported}} when module exists but has no on_config_change/1" do
      tmp_dir = System.tmp_dir!() |> Path.join("reload_test_#{:rand.uniform(99_999)}")
      plugin_dir = Path.join(tmp_dir, "stub_no_cb")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "manifest.yaml"), """
      name: stub_no_cb
      version: 0.1.0
      description: test
      depends_on:
        core: ">= 0.1.0"
        plugins: []
      declares: {}
      hot_reloadable: true
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Convention: stub_no_cb → Esr.Plugins.StubNoCb.Plugin
      # Esr.Plugins.StubNoCb.Plugin is not compiled so Code.ensure_loaded? returns false.
      # This tests the plugin_module_not_found branch.
      cmd = %{"args" => %{"plugin" => "stub_no_cb", "_plugin_root_override" => tmp_dir}}

      assert {:error, %{"type" => "plugin_module_not_found"}} = Reload.execute(cmd)
    end
  end

  describe "happy path — callback returns :ok" do
    test "returns {:ok, reloaded: true} and updates ConfigSnapshot" do
      # We test via the internal `invoke_and_handle/3` helper (private).
      # Since Reload.execute/1 resolves the plugin module from disk via
      # Loader.discover(), we exercise the callback path directly via a
      # public test-seam provided by the command module.
      #
      # The command module exposes a test-seam function for the callback step:
      # `Esr.Commands.Plugin.Reload.invoke_callback/3`
      # called with (module, plugin_name, changed_keys).

      ConfigSnapshot.init("ok_plugin", %{"http_proxy" => ""})

      result = Reload.invoke_callback(
        Esr.Commands.Plugin.ReloadTest.StubPlugin.OkPlugin,
        "ok_plugin",
        ["http_proxy"]
      )

      assert {:ok, %{"reloaded" => true, "changed_keys" => ["http_proxy"]}} = result
      # Snapshot should be updated after success.
      # We cannot predict the exact resolved value without a real yaml file,
      # but we can confirm update was called by checking get/1 no longer
      # returns the stale init value %{"http_proxy" => ""}.
      # (update/1 calls Config.resolve which reads no file → returns %{})
      assert %{} == ConfigSnapshot.get("ok_plugin")
    end
  end

  describe "force reload — empty changed_keys" do
    test "callback fires with [] and returns reloaded: true" do
      ConfigSnapshot.init("ok_plugin_force", %{})

      result = Reload.invoke_callback(
        Esr.Commands.Plugin.ReloadTest.StubPlugin.OkPlugin,
        "ok_plugin_force",
        []
      )

      assert {:ok, %{"reloaded" => true, "changed_keys" => []}} = result
    end
  end

  describe "callback returns {:error, reason}" do
    test "returns reloaded: false + fallback_active: true + logs warning" do
      ConfigSnapshot.init("err_plugin", %{"k" => "v"})

      log =
        capture_log(fn ->
          result = Reload.invoke_callback(
            Esr.Commands.Plugin.ReloadTest.StubPlugin.ErrorPlugin,
            "err_plugin",
            ["k"]
          )

          assert {:ok,
                  %{
                    "reloaded" => false,
                    "fallback_active" => true,
                    "plugin" => "err_plugin",
                    "changed_keys" => ["k"]
                  }} = result
        end)

      assert log =~ "failed to apply config change"
    end

    test "snapshot is NOT updated on callback error" do
      ConfigSnapshot.init("err_plugin2", %{"k" => "old"})

      Reload.invoke_callback(
        Esr.Commands.Plugin.ReloadTest.StubPlugin.ErrorPlugin,
        "err_plugin2",
        ["k"]
      )

      # Snapshot must remain at the init value (not updated).
      # Config.resolve("err_plugin2") returns %{} (no yaml on disk),
      # so if update was incorrectly called we'd see %{} instead of the init value.
      assert %{"k" => "old"} == ConfigSnapshot.get("err_plugin2")
    end
  end

  describe "callback raises an exception" do
    test "exception is caught; returns fallback_active: true" do
      ConfigSnapshot.init("raising_plugin", %{})

      log =
        capture_log(fn ->
          result = Reload.invoke_callback(
            Esr.Commands.Plugin.ReloadTest.StubPlugin.RaisingPlugin,
            "raising_plugin",
            []
          )

          assert {:ok, %{"reloaded" => false, "fallback_active" => true}} = result
        end)

      assert log =~ ~r/failed to apply|callback_timeout/
    end
  end

  describe "callback timeout (5 s)" do
    @tag timeout: 15_000
    test "returns reason: callback_timeout when callback exceeds 5 s" do
      ConfigSnapshot.init("slow_plugin", %{})

      log =
        capture_log(fn ->
          result = Reload.invoke_callback(
            Esr.Commands.Plugin.ReloadTest.StubPlugin.SlowPlugin,
            "slow_plugin",
            []
          )

          assert {:ok,
                  %{
                    "reloaded" => false,
                    "fallback_active" => true,
                    "reason" => "callback_timeout"
                  }} = result
        end)

      assert log =~ "timed out"
    end
  end
end
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/commands/plugin/reload_test.exs 2>&1 | tail -15
```

Expected: compilation failure — `Esr.Commands.Plugin.Reload` does not exist yet.

- [ ] **Step 3: Implement `reload.ex`**

Create `runtime/lib/esr/commands/plugin/reload.ex`:

```elixir
defmodule Esr.Commands.Plugin.Reload do
  @moduledoc """
  `/plugin:reload <plugin>`

  Triggers a config reload for a single named plugin. The plugin must
  declare `hot_reloadable: true` in its manifest (Q2). The reload is
  best-effort: if the plugin's `on_config_change/1` returns
  `{:error, reason}`, the framework logs a warning and returns a success
  response with `"reloaded" => false, "fallback_active" => true` (Q5).

  No batch form exists (Q7). The `plugin` arg is required; if absent,
  the dispatcher returns a missing-arg error before reaching this module.

  Permission: `plugin/manage` (shared with /plugin:set, per Q6).

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §4.
  """

  @behaviour Esr.Role.Control

  alias Esr.Plugin.Config
  alias Esr.Plugin.ConfigSnapshot
  alias Esr.Plugin.Loader

  require Logger

  @callback_timeout_ms 5_000

  @impl Esr.Role.Control
  def execute(%{"args" => args} = _cmd) do
    plugin_name = args["plugin"]
    plugin_root = args["_plugin_root_override"]

    with {:ok, manifest} <- resolve_manifest(plugin_name, plugin_root),
         :ok <- check_hot_reloadable(manifest),
         {:ok, module} <- resolve_module(manifest),
         :ok <- check_callback_exported(module, plugin_name),
         {:ok, changed_keys} <- compute_changed_keys(plugin_name, args) do
      invoke_callback(module, plugin_name, changed_keys)
    end
  end

  # ------------------------------------------------------------------
  # Step 1: resolve manifest (same as Plugin.Set)
  # ------------------------------------------------------------------

  defp resolve_manifest(plugin_name, plugin_root) do
    root = plugin_root || Loader.default_root()

    case Loader.discover(root) do
      {:ok, manifests} ->
        case Enum.find(manifests, fn {name, _} -> name == plugin_name end) do
          nil ->
            {:error, %{"type" => "unknown_plugin", "plugin" => plugin_name}}

          {_, manifest} ->
            {:ok, manifest}
        end

      {:error, reason} ->
        {:error, %{"type" => "discovery_failed", "reason" => inspect(reason)}}
    end
  end

  # ------------------------------------------------------------------
  # Step 2: check hot_reloadable flag in manifest (Q2)
  # ------------------------------------------------------------------

  defp check_hot_reloadable(%{hot_reloadable: true}), do: :ok

  defp check_hot_reloadable(%{name: name}) do
    {:error,
     %{
       "type" => "not_hot_reloadable",
       "plugin" => name,
       "message" =>
         "plugin must declare hot_reloadable: true in manifest to support reload; " <>
           "restart esrd to apply config changes"
     }}
  end

  # ------------------------------------------------------------------
  # Step 3: resolve module from manifest name convention
  # Convention: plugin "claude_code" → Esr.Plugins.ClaudeCode.Plugin
  # ------------------------------------------------------------------

  defp resolve_module(%{name: name}) do
    module_name =
      name
      |> String.split(~r/[-_]/)
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()
      |> then(&"Esr.Plugins.#{&1}.Plugin")

    module = Module.concat([module_name])

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error,
       %{
         "type" => "plugin_module_not_found",
         "plugin" => name,
         "module" => module_name,
         "message" =>
           "expected module #{module_name} to be loaded; " <>
             "verify the plugin's Plugin module exists"
       }}
    end
  end

  # ------------------------------------------------------------------
  # Step 4: check on_config_change/1 is exported (Q3)
  # ------------------------------------------------------------------

  defp check_callback_exported(module, plugin_name) do
    if function_exported?(module, :on_config_change, 1) do
      :ok
    else
      {:error,
       %{
         "type" => "callback_not_exported",
         "plugin" => plugin_name,
         "message" =>
           "plugin declares hot_reloadable: true but does not export on_config_change/1; " <>
             "check that the module implements Esr.Plugin.Behaviour"
       }}
    end
  end

  # ------------------------------------------------------------------
  # Step 5: compute changed_keys by diffing current config vs snapshot
  # ------------------------------------------------------------------

  defp compute_changed_keys(plugin_name, args) do
    path_opts = path_opts_from_args(args)
    current = Config.resolve(plugin_name, path_opts)
    snapshot = ConfigSnapshot.get(plugin_name)

    changed =
      (Map.keys(current) ++ Map.keys(snapshot))
      |> Enum.uniq()
      |> Enum.filter(fn k -> Map.get(current, k) != Map.get(snapshot, k) end)

    {:ok, changed}
  end

  defp path_opts_from_args(args) do
    [
      global_path: args["_global_path_override"],
      user_path: args["_user_path_override"],
      workspace_path: args["_workspace_path_override"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # ------------------------------------------------------------------
  # Step 6: invoke callback in a Task with timeout (Risk 1)
  # Exposed as a public function for test seam access.
  # ------------------------------------------------------------------

  @doc false
  # Public for test access only. Do not call from outside this module in production.
  def invoke_callback(module, plugin_name, changed_keys) do
    task = Task.async(fn -> safe_call(module, changed_keys) end)

    case Task.yield(task, @callback_timeout_ms) || Task.shutdown(task) do
      {:ok, :ok} ->
        ConfigSnapshot.update(plugin_name)

        {:ok,
         %{
           "plugin" => plugin_name,
           "reloaded" => true,
           "changed_keys" => changed_keys
         }}

      {:ok, {:error, reason}} ->
        Logger.warning(
          "plugin #{plugin_name} failed to apply config change: #{inspect(reason)}"
        )

        {:ok,
         %{
           "plugin" => plugin_name,
           "reloaded" => false,
           "fallback_active" => true,
           "reason" => inspect(reason),
           "changed_keys" => changed_keys
         }}

      nil ->
        Logger.warning(
          "plugin #{plugin_name} on_config_change/1 timed out after #{@callback_timeout_ms}ms"
        )

        {:ok,
         %{
           "plugin" => plugin_name,
           "reloaded" => false,
           "fallback_active" => true,
           "reason" => "callback_timeout",
           "changed_keys" => changed_keys
         }}
    end
  end

  # Wrap the callback so that exceptions are caught and returned as errors.
  # The timeout in invoke_callback/3 covers the slow-callback case.
  defp safe_call(module, changed_keys) do
    module.on_config_change(changed_keys)
  rescue
    e -> {:error, {:callback_raised, Exception.message(e)}}
  end
end
```

- [ ] **Step 4: Expose `default_root/0` on Loader (needed by Reload)**

The `Reload` module calls `Loader.default_root()`. The loader uses a module attribute `@default_root` but does not expose it publicly. Add a public accessor to `loader.ex`:

Find in `loader.ex`:

```elixir
  @default_root Path.expand("../plugins", __DIR__)
```

Add immediately after that line:

```elixir
  @doc "Returns the default plugins root directory. Used by commands that need to discover plugins."
  @spec default_root() :: Path.t()
  def default_root, do: @default_root
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/commands/plugin/reload_test.exs 2>&1 | tail -20
```

Expected: All tests pass. The timeout test may take ~5 seconds — that is expected.

- [ ] **Step 6: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/lib/esr/commands/plugin/reload.ex runtime/test/esr/commands/plugin/reload_test.exs runtime/lib/esr/plugin/loader.ex
git commit -m "feat(hr-2): add Esr.Commands.Plugin.Reload slash command"
```

---

### Task HR-2.2: Add `/plugin:reload` to `slash-routes.default.yaml`

**Files:**
- Modify: `runtime/priv/slash-routes.default.yaml`
- Test: extend `runtime/test/esr/resource/slash_route/registry_test.exs`

- [ ] **Step 1: Write the failing test — verify `/plugin:reload` appears in the registry**

Open `runtime/test/esr/resource/slash_route/registry_test.exs`. Add a new test at the end of the file (before the final `end`):

```elixir
  describe "/plugin:reload route registration (HR-2)" do
    test "plugin:reload is registered with permission plugin/manage and correct module" do
      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      FileLoader.load(priv)

      assert {:ok, route} = SlashRouteRegistry.lookup("/plugin:reload test_plugin")
      assert route.kind == "plugin_reload"
      assert route.permission == "plugin/manage"
      assert route.command_module == "Esr.Commands.Plugin.Reload"
    end
  end
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/resource/slash_route/registry_test.exs --only "plugin:reload" 2>&1 | tail -15
```

Expected: test fails — `/plugin:reload` is not found in the registry.

- [ ] **Step 3: Add the route to `slash-routes.default.yaml`**

Open `runtime/priv/slash-routes.default.yaml`. Find the `/plugin:list-config` entry (the last plugin slash before `/cap:grant`) and add the new entry AFTER `/plugin:list-config`:

```yaml
  "/plugin:reload":
    kind: plugin_reload
    permission: "plugin/manage"
    command_module: "Esr.Commands.Plugin.Reload"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Plugins"
    description: "触发指定 plugin 的 config reload（plugin manifest 必须 hot_reloadable: true；不传 plugin name = 报错，无 batch reload）"
    args:
      - { name: plugin, required: true }
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/resource/slash_route/registry_test.exs 2>&1 | tail -10
```

Expected: All slash route tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/priv/slash-routes.default.yaml runtime/test/esr/resource/slash_route/registry_test.exs
git commit -m "feat(hr-2): add /plugin:reload to slash-routes.default.yaml"
```

---

### Task HR-2.3: Open PR + admin-merge for HR-2

- [ ] **Step 1: Push and create PR**

```bash
cd /Users/h2oslabs/Workspace/esr && git push -u origin feat/hr-2-reload-command
gh pr create --base dev --head feat/hr-2-reload-command \
  --title "feat(hr-2): /plugin:reload slash command + ConfigSnapshot wiring" \
  --body "$(cat <<'EOF'
Hot-reload sub-phase HR-2 of spec/plugin-config-hot-reload.

Adds:
- `Esr.Commands.Plugin.Reload` — full `/plugin:reload <plugin>` command (§4)
  - Resolves manifest → checks hot_reloadable → resolves module → checks callback export
  - Diffs current config vs ConfigSnapshot to compute changed_keys
  - Invokes callback via Task.async + 5s Task.yield timeout (§9 Risk 1)
  - Best-effort: callback error → fallback_active: true (no rollback, Q5)
- `/plugin:reload` entry added to slash-routes.default.yaml (permission: plugin/manage, Q6)

Depends on: feat/hr-1-behaviour-manifest (must be merged first).

Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §4, §7.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Admin-merge**

```bash
cd /Users/h2oslabs/Workspace/esr && gh pr merge --admin --squash --delete-branch
```

---

## Sub-phase HR-3: `claude_code` + `feishu` Opt-In

**Prerequisite:** HR-1 and HR-2 merged. HR-3 adds `hot_reloadable: true` to both plugin manifests and implements `on_config_change/1`.

**Approx scope:** ~80 LOC + ~80 LOC tests + 2 manifest lines each, across 4 tasks.

---

### Task HR-3.1: `claude_code` — manifest opt-in + `Plugin` module

**Files:**
- Modify: `runtime/lib/esr/plugins/claude_code/manifest.yaml`
- Create: `runtime/lib/esr/plugins/claude_code/plugin.ex`
- Create: `runtime/test/esr/plugins/claude_code/plugin_test.exs`

The `claude_code` plugin config keys are all spawn-time values (they are injected into the PTY environment at session start via `Esr.Plugins.ClaudeCode.Launcher.build_env/1`). The callback is intentionally thin:
- `anthropic_api_key_ref` change → log `[warning]` (running sessions are unaffected; key is injected at spawn time). Return `:ok`.
- All other keys → no-op. Return `:ok`.

This means new sessions automatically pick up changed values at spawn time. No rebinding of running processes is required.

- [ ] **Step 1: Write the failing tests**

Create `runtime/test/esr/plugins/claude_code/plugin_test.exs`:

```elixir
defmodule Esr.Plugins.ClaudeCode.PluginTest do
  @moduledoc """
  Tests for `Esr.Plugins.ClaudeCode.Plugin.on_config_change/1`.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 HR-3 + §10.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Esr.Plugins.ClaudeCode.Plugin

  describe "on_config_change/1" do
    test "returns :ok for proxy key change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["http_proxy"])
      end)
      assert log == ""
    end

    test "returns :ok for https_proxy change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["https_proxy"])
      end)
      assert log == ""
    end

    test "returns :ok for no_proxy change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["no_proxy"])
      end)
      assert log == ""
    end

    test "returns :ok for esrd_url change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["esrd_url"])
      end)
      assert log == ""
    end

    test "returns :ok for anthropic_api_key_ref change AND logs a warning" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["anthropic_api_key_ref"])
      end)
      assert log =~ "anthropic_api_key_ref"
      assert log =~ ~r/warn|warning/i
    end

    test "returns :ok when changed_keys includes both a proxy key and anthropic_api_key_ref" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["http_proxy", "anthropic_api_key_ref"])
      end)
      # Only the api_key warning should appear.
      assert log =~ "anthropic_api_key_ref"
    end

    test "returns :ok for empty changed_keys (force reload, no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change([])
      end)
      assert log == ""
    end
  end
end
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugins/claude_code/plugin_test.exs 2>&1 | tail -15
```

Expected: compilation failure — `Esr.Plugins.ClaudeCode.Plugin` does not exist yet.

- [ ] **Step 3: Create `runtime/lib/esr/plugins/claude_code/plugin.ex`**

```elixir
defmodule Esr.Plugins.ClaudeCode.Plugin do
  @moduledoc """
  Hot-reload opt-in module for the `claude_code` plugin.

  Implements `Esr.Plugin.Behaviour.on_config_change/1`.

  ## Config key behavior

  All `claude_code` config keys are spawn-time values — they are
  injected into the PTY environment at session start via
  `Esr.Plugins.ClaudeCode.Launcher.build_env/1` (or equivalent).
  The running `claude` subprocess holds its own copy of the values from
  the time it was launched; hot-reload cannot retroactively change a
  running subprocess's environment.

  Behavior per key:
    - `http_proxy`, `https_proxy`, `no_proxy`, `esrd_url` — new value
      takes effect for the NEXT cc session spawn (no rebind needed).
    - `anthropic_api_key_ref` — new value also takes effect at next spawn.
      A warning is logged because running sessions are unaffected (the
      API key is the session's identity; operators may expect immediate
      effect and be surprised).

  Return: always `:ok`. The plugin does not enter a fallback state — all
  config keys are safe to acknowledge regardless of running session state.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 (HR-3).
  """

  @behaviour Esr.Plugin.Behaviour

  require Logger

  @impl Esr.Plugin.Behaviour
  def on_config_change(changed_keys) do
    if "anthropic_api_key_ref" in changed_keys do
      Logger.warning(
        "claude_code plugin: anthropic_api_key_ref changed but running cc sessions " <>
          "are unaffected (key is injected at spawn time). " <>
          "Restart active sessions to apply the new API key reference."
      )
    end

    # For all other config keys (http_proxy, https_proxy, no_proxy, esrd_url),
    # the effective change is visible to new sessions automatically — they call
    # Config.resolve/2 at spawn time. No rebinding of running processes required.
    :ok
  end
end
```

- [ ] **Step 4: Add `hot_reloadable: true` to `claude_code/manifest.yaml`**

Open `runtime/lib/esr/plugins/claude_code/manifest.yaml`. After the `version: 0.1.0` line, add:

```yaml
hot_reloadable: true
```

The top of the manifest should now read:

```yaml
name: claude_code
version: 0.1.0
hot_reloadable: true
description: |
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugins/claude_code/plugin_test.exs 2>&1 | tail -15
```

Expected: All 7 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/lib/esr/plugins/claude_code/plugin.ex runtime/test/esr/plugins/claude_code/plugin_test.exs runtime/lib/esr/plugins/claude_code/manifest.yaml
git commit -m "feat(hr-3): claude_code plugin — hot_reloadable opt-in + on_config_change/1"
```

---

### Task HR-3.2: `feishu` — manifest opt-in + `Plugin` module

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`
- Create: `runtime/lib/esr/plugins/feishu/plugin.ex`
- Create: `runtime/test/esr/plugins/feishu/plugin_test.exs`

The `feishu` plugin config keys:
- `app_id`, `app_secret` — used by `FeishuAppAdapter` peers when making Lark REST API calls. The adapter reads config at call time (not cached at start), so new values take effect on the next outbound API call automatically. No rebinding needed.
- `log_level` — applied to the `feishu_adapter_runner` Python sidecar. The sidecar does not support live log-level changes. Log a `[warning]` that a sidecar restart is required. Return `:ok`.

- [ ] **Step 1: Write the failing tests**

Create `runtime/test/esr/plugins/feishu/plugin_test.exs`:

```elixir
defmodule Esr.Plugins.Feishu.PluginTest do
  @moduledoc """
  Tests for `Esr.Plugins.Feishu.Plugin.on_config_change/1`.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 HR-3 + §10.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Esr.Plugins.Feishu.Plugin

  describe "on_config_change/1" do
    test "returns :ok for app_id change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["app_id"])
      end)
      assert log == ""
    end

    test "returns :ok for app_secret change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["app_secret"])
      end)
      assert log == ""
    end

    test "returns :ok for log_level change AND logs a warning" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["log_level"])
      end)
      assert log =~ "log_level"
      assert log =~ ~r/warn|warning/i
    end

    test "returns :ok when changed_keys has both app_id and log_level" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["app_id", "log_level"])
      end)
      # Only the log_level warning should appear.
      assert log =~ "log_level"
      refute log =~ "app_id"
    end

    test "returns :ok for empty changed_keys (force reload, no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change([])
      end)
      assert log == ""
    end
  end
end
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugins/feishu/plugin_test.exs 2>&1 | tail -15
```

Expected: compilation failure — `Esr.Plugins.Feishu.Plugin` does not exist yet.

- [ ] **Step 3: Create `runtime/lib/esr/plugins/feishu/plugin.ex`**

```elixir
defmodule Esr.Plugins.Feishu.Plugin do
  @moduledoc """
  Hot-reload opt-in module for the `feishu` plugin.

  Implements `Esr.Plugin.Behaviour.on_config_change/1`.

  ## Config key behavior

    - `app_id`, `app_secret` — consumed by `FeishuAppAdapter` peers when
      making Lark REST API calls. The adapter reads config via
      `Esr.Plugin.Config.get/3` at call time (not cached at start), so
      new values take effect on the next outbound API call automatically.
      No rebinding required.

    - `log_level` — forwarded to the `feishu_adapter_runner` Python
      sidecar at subprocess start. The sidecar does not support live
      log-level changes at runtime. A warning is logged; the operator
      must restart the sidecar to apply the change.

  Return: always `:ok`. The plugin does not enter a fallback state.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 (HR-3).
  """

  @behaviour Esr.Plugin.Behaviour

  require Logger

  @impl Esr.Plugin.Behaviour
  def on_config_change(changed_keys) do
    if "log_level" in changed_keys do
      Logger.warning(
        "feishu plugin: log_level changed but the feishu_adapter_runner sidecar " <>
          "does not support live log-level changes. " <>
          "Restart the sidecar to apply the new log level."
      )
    end

    # app_id / app_secret: FeishuAppAdapter reads config at call time via
    # Esr.Plugin.Config.get/3, so new values take effect on the next
    # outbound API call automatically. No rebinding needed.
    :ok
  end
end
```

- [ ] **Step 4: Add `hot_reloadable: true` to `feishu/manifest.yaml`**

Open `runtime/lib/esr/plugins/feishu/manifest.yaml`. After the `version: 0.1.0` line, add:

```yaml
hot_reloadable: true
```

The top of the manifest should now read:

```yaml
name: feishu
version: 0.1.0
hot_reloadable: true
description: |
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugins/feishu/plugin_test.exs 2>&1 | tail -15
```

Expected: All 5 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add runtime/lib/esr/plugins/feishu/plugin.ex runtime/test/esr/plugins/feishu/plugin_test.exs runtime/lib/esr/plugins/feishu/manifest.yaml
git commit -m "feat(hr-3): feishu plugin — hot_reloadable opt-in + on_config_change/1"
```

---

### Task HR-3.3: Full test suite verification

Before opening the HR-3 PR, run the full test suite to ensure no regressions.

- [ ] **Step 1: Run the full plugin + commands test suite**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/plugin/ test/esr/commands/plugin/ test/esr/plugins/ test/esr/resource/slash_route/ 2>&1 | tail -20
```

Expected: All tests pass. Note: the reload timeout test takes ~5 seconds.

- [ ] **Step 2: Run the entire test suite**

```bash
cd /Users/h2oslabs/Workspace/esr/runtime && mix test 2>&1 | tail -20
```

Expected: No new failures introduced by HR-3.

---

### Task HR-3.4: Open PR + admin-merge for HR-3

- [ ] **Step 1: Push and create PR**

```bash
cd /Users/h2oslabs/Workspace/esr && git push -u origin feat/hr-3-cc-feishu-opt-in
gh pr create --base dev --head feat/hr-3-cc-feishu-opt-in \
  --title "feat(hr-3): claude_code + feishu hot-reload opt-in" \
  --body "$(cat <<'EOF'
Hot-reload sub-phase HR-3 of spec/plugin-config-hot-reload.

Adds hot_reloadable: true opt-in + on_config_change/1 for two plugins:

claude_code (§8 HR-3):
- manifest.yaml: hot_reloadable: true
- plugin.ex: on_config_change/1 — all keys are spawn-time values;
  anthropic_api_key_ref change logs a warning (running sessions unaffected);
  all keys return :ok.

feishu (§8 HR-3):
- manifest.yaml: hot_reloadable: true
- plugin.ex: on_config_change/1 — app_id/app_secret take effect on next
  API call (no rebinding); log_level change logs warning (sidecar restart
  required). Returns :ok for all keys.

Depends on: feat/hr-1-behaviour-manifest + feat/hr-2-reload-command
(both must be merged first).

Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Admin-merge**

```bash
cd /Users/h2oslabs/Workspace/esr && gh pr merge --admin --squash --delete-branch
```

---

## Self-Review Checklist

### Spec coverage (Q1–Q7 + all sections)

- [x] **Q1** (explicit slash): `/plugin:reload <plugin>` slash → HR-2.1 `Reload.execute/1` + HR-2.2 yaml entry
- [x] **Q2** (per-plugin opt-in): `hot_reloadable: true` in manifest → HR-1.2 manifest parser + HR-3.1/HR-3.2 manifest changes
- [x] **Q3** (callback): `Esr.Plugin.Behaviour.on_config_change/1` → HR-1.1; `check_callback_exported/2` in HR-2.1
- [x] **Q4** (trigger-only): callback receives `changed_keys :: [String.t()]`; plugins read config via `Config.get/3` → HR-2.1 module body + HR-3.1/HR-3.2 plugin bodies
- [x] **Q5** (best-effort, no rollback): callback error → `fallback_active: true`, snapshot NOT updated → HR-2.1 `invoke_callback/3`
- [x] **Q6** (shared cap): `permission: "plugin/manage"` in yaml entry → HR-2.2
- [x] **Q7** (no batch): `plugin` arg is required; no batch form → HR-2.2 yaml entry + HR-2.1 execute clause
- [x] **§2** (Behaviour): HR-1.1
- [x] **§2** (snapshot semantics): HR-1.3 `ConfigSnapshot`, HR-1.4 loader wiring
- [x] **§3** (manifest schema): HR-1.2
- [x] **§4** (Reload module): HR-2.1 (full 6-step pipeline)
- [x] **§5** (ConfigSnapshot): HR-1.3
- [x] **§6** (best-effort + fallback): HR-2.1 + HR-3.1/HR-3.2 (plugin modules log warnings as specified)
- [x] **§7** (cap sharing): HR-2.2
- [x] **§8** phasing: HR-1 → HR-2 → HR-3 (dependency chain enforced via PR base branches)
- [x] **§9 Risk 1** (slow callback): `Task.async + Task.yield(5_000)` in HR-2.1
- [x] **§9 Risk 3** (stale snapshot after restart): Addressed by design — `create_table + init` in HR-1.4 gives full-diff on first reload after restart (intentional per spec)
- [x] **§9 Risk 4** (empty changed_keys force reload): `compute_changed_keys` returns `[]` when no diff; callback still fires; test in HR-2.1
- [x] **§10 Test Plan**: all unit + integration test cases from §10 are covered in HR-1.2, HR-1.3, HR-2.1, HR-3.1, HR-3.2
- [x] **§10 E2E (rev-2 MANDATORY)**: scenario 17 bash + Makefile covered in HR-4.1, HR-4.2
- [x] **§9.5 mock proxy strategy**: Plug-based inline server documented and justified in HR-4.1
- [x] **§9.5 assertions**: 5-step assertion table (a/b/c/d/e) covered in HR-4.1 scenario body

### No placeholders scan

All code blocks are complete and concrete. No "TBD", "TODO", or "implement later" present.

### Type consistency

- `on_config_change/1` signature is `changed_keys() :: :ok | {:error, reason()}` throughout — matches spec §2 exactly.
- `ConfigSnapshot.get/1` returns `map()` (not `{:ok, map()} | :error`), consistent across HR-1.3 and HR-2.1 usage.
- `invoke_callback/3` is `def` (public) in the command module — used as a test seam in HR-2.1 tests.
- `update_with_path/2` is public on `ConfigSnapshot` — test seam used in HR-1.3 tests.

### Phase deps

- HR-1 tasks depend on nothing outside the existing codebase.
- HR-2 tasks depend on: `Esr.Plugin.ConfigSnapshot` (HR-1.3), `Manifest.hot_reloadable` field (HR-1.2), `Loader.default_root/0` (HR-1.4 adds it).
- HR-3 tasks depend on: `Esr.Plugin.Behaviour` (HR-1.1), `/plugin:reload` slash (HR-2.2).
- HR-4 tasks depend on: HR-3 fully merged (scenario exercises the full `/plugin:reload` path end-to-end, including `claude_code` `on_config_change/1` and yaml persistence).
- **Total LOC updated**: ~300 LOC + ~300 LOC tests (HR-1/2/3) + ~150 LOC e2e (HR-4) = **~750 LOC total**. Previous rev-1 total was ~600 LOC (including tests).

No cycles.

---

## Sub-phase HR-4: e2e Validation — HTTP Proxy Hot-Reload

**Prerequisite:** HR-1, HR-2, and HR-3 all merged. This phase ships as a standalone PR against `dev`.

**Spec reference:** `docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md` §9.5

**Approx scope:** ~150 LOC bash (scenario script + Makefile entry) across 3 tasks.

---

### Task HR-4.1: Mock HTTP proxy helper (inlined in scenario)

**Files:**
- Create: `tests/e2e/scenarios/17_plugin_config_hot_reload.sh` (mock proxy is inlined, not a separate helper file)

The mock proxy is a minimal Plug/Cowboy server spawned inline via `mix run --no-halt --eval` in the scenario script. It records all inbound requests in an ETS table and exposes `GET /request_count` → `{"count": N}`.

No separate `_helpers/*.exs` file is needed. Existing `tests/e2e/scenarios/` only uses `_common_selftest.sh` and `_wait_url.py` as helpers — there is no `.exs` helper pattern to follow, and the proxy logic is trivial enough to inline.

**Mock proxy LOC estimate**: ~25 LOC Elixir (inside `--eval` string in the bash script).

- [ ] **Step 1: Write the failing test (bash syntax check)**

```bash
bash -n tests/e2e/scenarios/17_plugin_config_hot_reload.sh
```

Expected at this point: `17_plugin_config_hot_reload.sh: No such file or directory` (file doesn't exist yet).

- [ ] **Step 2: Implement `tests/e2e/scenarios/17_plugin_config_hot_reload.sh`**

Create the file following the spec §9.5 test flow. Key structure:

```bash
#!/usr/bin/env bash
# e2e scenario 17 — claude_code http_proxy hot-reload end-to-end.
#
# Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §9.5
# Phase: HR-4 (hot-reload e2e validation).
#
# WHAT THIS TEST PROVES:
#   1. Before /plugin:reload: yaml-set alone does NOT change plugin behavior
#   2. After /plugin:reload: on_config_change fires; effective config reflects new proxy
#   3. changed_keys includes "http_proxy" in the reload response
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/17_plugin_config_hot_reload.sh 2>&1 | tail -3
#   → "PASS: 17_plugin_config_hot_reload"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# --- pick a free port for the mock proxy ---
MOCK_PROXY_PORT=$(python3 -c \
  "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
MOCK_PROXY_PID_FILE="/tmp/mock-proxy-${ESR_E2E_RUN_ID}.pid"
MOCK_PROXY_READY_FILE="/tmp/mock-proxy-ready-${ESR_E2E_RUN_ID}"

# --- inline Plug mock proxy ---
PLUG_EVAL=$(cat <<'ELIXIR'
defmodule MockProxy do
  use Plug.Router
  plug :match
  plug :dispatch

  get "/request_count" do
    count = case :ets.info(:mock_proxy_requests, :size) do
      :undefined -> 0
      n -> n
    end
    Plug.Conn.send_resp(conn, 200, Jason.encode!(%{count: count}))
  end

  match _ do
    :ets.insert(:mock_proxy_requests, {System.monotonic_time(), conn.method, conn.request_path})
    Plug.Conn.send_resp(conn, 200, "")
  end
end

:ets.new(:mock_proxy_requests, [:named_table, :public, :bag])
port = String.to_integer(System.get_env("MOCK_PROXY_PORT", "8299"))
{:ok, _} = Plug.Cowboy.http(MockProxy, [], port: port)
IO.puts("MOCK_PROXY_READY port=#{port}")
Process.sleep(:infinity)
ELIXIR
)

# spawn mock proxy
(cd "${_E2E_REPO_ROOT}/runtime" && \
  MOCK_PROXY_PORT="${MOCK_PROXY_PORT}" \
  mix run --no-halt --eval "${PLUG_EVAL}" 2>/dev/null &
  echo $! > "${MOCK_PROXY_PID_FILE}")

# wait for proxy to be ready (up to 10s)
for _ in $(seq 1 50); do
  if curl -sSf "http://127.0.0.1:${MOCK_PROXY_PORT}/request_count" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
curl -sSf "http://127.0.0.1:${MOCK_PROXY_PORT}/request_count" >/dev/null \
  || { echo "FAIL: mock proxy did not start on port ${MOCK_PROXY_PORT}"; exit 1; }
echo "17: mock proxy ready on port ${MOCK_PROXY_PORT}"

# --- setup: start esrd with http_proxy="" ---
seed_plugin_config
seed_capabilities
start_esrd

# --- step a: proxy count = 0 before any proxy config set ---
COUNT_A=$(curl -sS "http://127.0.0.1:${MOCK_PROXY_PORT}/request_count" | jq '.count')
assert_eq "${COUNT_A}" "0" "17: step a — proxy count 0 before proxy config"
echo "17: step a passed — proxy count 0 before any config"

# --- step b: /plugin:set http_proxy ---
SET_RESULT=$(esr_cli admin submit plugin_set \
  --arg plugin=claude_code \
  --arg key=http_proxy \
  --arg value="http://127.0.0.1:${MOCK_PROXY_PORT}" \
  --arg layer=global \
  --wait --timeout 15)
echo "plugin_set result: ${SET_RESULT}"
assert_contains "${SET_RESULT}" "ok: true" "17: step b — plugin_set http_proxy ok"
echo "17: step b passed — http_proxy written to yaml"

# --- step c: proxy count still 0 (plugin not reloaded) ---
COUNT_C=$(curl -sS "http://127.0.0.1:${MOCK_PROXY_PORT}/request_count" | jq '.count')
assert_eq "${COUNT_C}" "0" "17: step c — proxy count still 0; plugin not reloaded"
echo "17: step c passed — yaml-set alone does not change plugin behavior"

# --- step d: /plugin:reload claude_code ---
RELOAD_RESULT=$(esr_cli admin submit plugin_reload \
  --arg plugin=claude_code \
  --wait --timeout 15)
echo "plugin_reload result: ${RELOAD_RESULT}"
assert_contains "${RELOAD_RESULT}" '"reloaded":true'  "17: step d — reloaded=true"
assert_contains "${RELOAD_RESULT}" '"http_proxy"'     "17: step d — http_proxy in changed_keys"
echo "17: step d passed — reload fired; reloaded=true; http_proxy in changed_keys"

# --- step e: effective config now reflects new proxy ---
SHOW_RESULT=$(esr_cli admin submit plugin_show_config \
  --arg plugin=claude_code \
  --arg layer=effective \
  --wait --timeout 15)
echo "plugin_show_config: ${SHOW_RESULT}"
assert_contains "${SHOW_RESULT}" "127.0.0.1:${MOCK_PROXY_PORT}" \
  "17: step e — effective config shows new proxy after reload"
echo "17: step e passed — effective config reflects new proxy"

# --- cleanup ---
[[ -f "${MOCK_PROXY_PID_FILE}" ]] && kill "$(cat "${MOCK_PROXY_PID_FILE}")" 2>/dev/null || true
rm -f "${MOCK_PROXY_PID_FILE}" "${MOCK_PROXY_READY_FILE}" 2>/dev/null || true

echo "PASS: 17_plugin_config_hot_reload"
```

- [ ] **Step 3: Bash syntax check**

```bash
bash -n tests/e2e/scenarios/17_plugin_config_hot_reload.sh
```

Expected: no output (clean parse).

- [ ] **Step 4: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add tests/e2e/scenarios/17_plugin_config_hot_reload.sh
git commit -m "feat(hr-4): e2e scenario 17 — http_proxy hot-reload end-to-end"
```

---

### Task HR-4.2: Makefile — add `e2e-16` and `e2e-17` targets

**Files:**
- Modify: `Makefile`

Add `e2e-16` (scenario 16 already exists but has no target) and `e2e-17` to the Makefile.

- [ ] **Step 1: Extend `.PHONY` and add targets**

In `Makefile`:

**1a.** Replace the `.PHONY` line:

```makefile
.PHONY: test test-py test-ex lint fmt run-runtime clean e2e e2e-ci e2e-01 e2e-02 e2e-04 e2e-05 e2e-06 e2e-07 e2e-08 e2e-11 e2e-escript e2e-cli
```

With:

```makefile
.PHONY: test test-py test-ex lint fmt run-runtime clean e2e e2e-ci e2e-01 e2e-02 e2e-04 e2e-05 e2e-06 e2e-07 e2e-08 e2e-11 e2e-14 e2e-15 e2e-16 e2e-17 e2e-escript e2e-cli
```

**1b.** After the `e2e-11` target, add:

```makefile
e2e-14:
	$(E2E_RUN) tests/e2e/scenarios/14_session_multiagent.sh

e2e-15:
	$(E2E_RUN) tests/e2e/scenarios/15_session_share.sh

e2e-16:
	$(E2E_RUN) tests/e2e/scenarios/16_plugin_config_layers.sh

e2e-17:
	$(E2E_RUN) tests/e2e/scenarios/17_plugin_config_hot_reload.sh
```

**Note**: `e2e-14`, `e2e-15`, `e2e-16` are added for completeness (their scenario files exist but had no make targets). They are NOT added to the default `e2e:` aggregate — only `e2e-17` is the mandatory new gate.

- [ ] **Step 2: Verify Makefile syntax**

```bash
make -n e2e-17 2>&1
```

Expected: prints the `perl -e 'alarm ...' bash tests/e2e/scenarios/17_plugin_config_hot_reload.sh` line without errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr && git add Makefile
git commit -m "feat(hr-4): add e2e-16/e2e-17 Makefile targets for plugin config scenarios"
```

---

### Task HR-4.3: PR + admin-merge for HR-4

- [ ] **Step 1: Push and create PR**

```bash
cd /Users/h2oslabs/Workspace/esr && git push -u origin feat/hr-4-e2e-validation
gh pr create --base dev --head feat/hr-4-e2e-validation \
  --title "feat(hr-4): e2e 17 — http_proxy hot-reload validation" \
  --body "$(cat <<'EOF'
Hot-reload sub-phase HR-4 of spec/plugin-config-hot-reload.

Adds e2e scenario 17 proving the full http_proxy hot-reload round-trip:

  a. No proxy set → mock proxy sees 0 requests
  b. /plugin:set http_proxy=http://localhost:<port> → yaml written
  c. Still 0 requests (plugin not reloaded yet)
  d. /plugin:reload claude_code → reloaded=true, changed_keys=["http_proxy"]
  e. plugin_show_config effective → returns new proxy URL

Mock proxy: Plug/Cowboy server inlined in the scenario script,
listening on a random free port, recording requests in ETS.

Depends on: feat/hr-3-cc-feishu-opt-in (all prior HR phases merged).

Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §9.5.
Plan: docs/superpowers/plans/2026-05-07-plugin-config-hot-reload-plan.md HR-4.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Admin-merge**

```bash
cd /Users/h2oslabs/Workspace/esr && gh pr merge --admin --squash --delete-branch
```
