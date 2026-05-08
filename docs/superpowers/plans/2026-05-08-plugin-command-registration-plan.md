# Plugin-Scoped Command Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manifest-driven mechanism for plugins to register slash and admin-CLI commands without editing core files, then prove it by physically migrating 3 existing plugin-owned commands (`bind_feishu`, `unbind_feishu`, `notify`) into the feishu plugin.

**Architecture:** Extend `Esr.Plugin.Manifest` with a `slash_routes:` declaration block (parallel to `capabilities:` / `python_sidecars:`). `Esr.Plugin.Loader.start_plugin/2` calls a new `register_slash_routes/2` step that registers an overlay on `Esr.Resource.SlashRoute.Registry`. The Registry refactors from "single ETS replacement" to "base table + per-plugin overlay map + merged view" — collisions across base+overlays are hard errors. Belt-and-suspenders namespace enforcement at both manifest-validate time and registry-register time.

**Tech Stack:** Elixir 1.19, OTP 27, ExUnit, ETS, YamlElixir, Jason

**Spec:** `docs/superpowers/specs/2026-05-08-plugin-command-registration.md` rev-2 (user-approved 2026-05-08)

**Branch:** Implementation lands on `feat/session-first-default-resolution` (so #6 ships in the same PR as #5). Spec commits `5424fd5` + `3d882c9` cherry-picked onto impl branch in Phase 0.

**Estimated total scope:** ~825 LOC + ~500 LOC tests = ~1325 LOC across 7 phases / 22 tasks.

---

## File structure

### New files

| Path | Responsibility |
|------|----------------|
| `runtime/lib/esr/plugins/feishu/commands/bind_user.ex` | `Esr.Plugins.Feishu.Commands.BindUser` — verbatim move of `Esr.Commands.User.BindFeishu` |
| `runtime/lib/esr/plugins/feishu/commands/unbind_user.ex` | `Esr.Plugins.Feishu.Commands.UnbindUser` — verbatim move of `Esr.Commands.User.UnbindFeishu` |
| `runtime/lib/esr/plugins/feishu/commands/notify.ex` | `Esr.Plugins.Feishu.Commands.Notify` — verbatim move of `Esr.Commands.Notify` |
| `runtime/test/esr/plugins/feishu/commands/notify_test.exs` | Move + module rename of existing notify_test.exs |
| `runtime/test/support/noop_command.ex` | `Esr.Test.NoopCommand` — generic `Esr.Role.Control` stub for slash-route registry tests |
| `runtime/test/esr/resource/slash_route/overlay_test.exs` | New test module for overlay-specific behaviors (register/unregister/collision/preserve) |

### Modified files

| Path | Responsibility |
|------|----------------|
| `runtime/lib/esr/plugin/manifest.ex` | Add `slash_routes` to allowed declares; add `validate_slash_routes/1`; add `slash_route_snapshot/1` reader |
| `runtime/lib/esr/plugin/loader.ex` | Insert `register_slash_routes/2` into `start_plugin/2` with-chain; call `unregister_overlay/1` from `stop_plugin/1` |
| `runtime/lib/esr/resource/slash_route/registry.ex` | Refactor state to `base + overlays + merged_view`; add `register_overlay/2` + `unregister_overlay/1` with collision detection |
| `runtime/lib/esr/resource/slash_route/file_loader.ex` | Extract `parse_routes_block/1` so both base yaml and plugin manifest can use the same parser |
| `runtime/priv/slash-routes.default.yaml` | Delete the 3 internal_kinds entries: `notify`, `user_bind_feishu`, `user_unbind_feishu` |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | Add `slash_routes:` block declaring the 3 migrated kinds |
| `runtime/lib/esr/resource/permission/bootstrap.ex` | Add `feishu/user-bind` cap; the bind/unbind commands switch to it |
| `runtime/lib/esr/scope/admin/process.ex` | One-line doc-comment update referencing new notify location |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | Replace 33 `Esr.Commands.Notify` sentinel uses with `Esr.Test.NoopCommand` |
| `runtime/test/esr/plugin/manifest_test.exs` | Add slash_routes validation test cases |
| `runtime/mix.exs` | Add `test/support` to test elixirc_paths if not already there |

---

## Phase 0: Branch + plumbing prep

### Task 0.1: Cherry-pick spec onto impl branch

**Files:**
- Modify: nothing (git op only)

- [ ] **Step 1: Confirm impl branch state**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git checkout feat/session-first-default-resolution
git log --oneline -3
```

Expected: HEAD is at `cee6eb6` (yellow-fix #2) or later. 25+ commits ahead of origin/dev.

- [ ] **Step 2: Cherry-pick the two spec commits from the docs branch**

```bash
git cherry-pick 5424fd5 3d882c9
```

Expected: clean cherry-pick, no conflicts. New HEAD is rev-2 spec commit.

- [ ] **Step 3: Verify spec files travel with code**

```bash
ls docs/superpowers/specs/2026-05-08-plugin-command-registration*.md
git log --oneline -1 docs/superpowers/specs/2026-05-08-plugin-command-registration.md
```

Expected: both `.md` and `.zh_cn.md` present; the latest commit is `3d882c9`.

### Task 0.2: Cherry-pick the plan onto impl branch

**Files:**
- Modify: nothing (git op only — assumes plan committed on docs branch first)

- [ ] **Step 1: Switch to docs branch, commit the plan**

```bash
git checkout docs/audit-6-plugin-command-registration
git add docs/superpowers/plans/2026-05-08-plugin-command-registration-plan.md \
        docs/superpowers/plans/2026-05-08-plugin-command-registration-plan.zh_cn.md
git commit -m "plan: plugin-scoped command registration (rev-2 → impl)"
```

- [ ] **Step 2: Cherry-pick onto impl branch**

```bash
git checkout feat/session-first-default-resolution
git cherry-pick docs/audit-6-plugin-command-registration
```

Expected: spec + plan now travel with the impl PR.

### Task 0.3: Add `test/support` to mix elixirc_paths if absent

**Files:**
- Modify: `runtime/mix.exs`

- [ ] **Step 1: Check current paths**

```bash
grep -n "elixirc_paths\|test/support" runtime/mix.exs
```

If `test/support` is already in `elixirc_paths(:test)`, skip Step 2. Otherwise:

- [ ] **Step 2: Add the path**

In `runtime/mix.exs`, after the `def project do` block, ensure these defs exist:

```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

And confirm the `def project` map includes `elixirc_paths: elixirc_paths(Mix.env())`.

- [ ] **Step 3: Compile to verify**

```bash
cd runtime && mix compile 2>&1 | tail -3
```

Expected: clean compile, no warnings about test/support.

- [ ] **Step 4: Commit**

```bash
git add runtime/mix.exs
git commit -m "build: include test/support in test elixirc_paths"
```

---

## Phase 1: `Esr.Test.NoopCommand` sentinel fixture

This phase intentionally goes first (before any mechanism work) so that registry tests in later phases can use the sentinel without first migrating off `Esr.Commands.Notify`.

### Task 1.1: Create the noop command module

**Files:**
- Create: `runtime/test/support/noop_command.ex`

- [ ] **Step 1: Write the module**

```elixir
defmodule Esr.Test.NoopCommand do
  @moduledoc """
  Test-only `Esr.Role.Control` implementation. Used by slash-route
  registry tests as a generic, always-loadable sentinel module
  reference — any test that needs *some* concrete `command_module:`
  value but doesn't care about the actual logic should use this.

  Replaces ad-hoc use of `Esr.Commands.Notify` (which is now a real
  feishu-plugin command and shouldn't be reused as a test fixture).
  """

  @behaviour Esr.Role.Control

  @impl true
  def execute(_cmd) do
    {:ok, %{"action" => "noop"}}
  end
end
```

- [ ] **Step 2: Run `mix compile`**

```bash
cd runtime && mix compile 2>&1 | tail -3
```

Expected: clean compile.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/support/noop_command.ex
git commit -m "test(support): add Esr.Test.NoopCommand sentinel"
```

### Task 1.2: Replace sentinel uses in registry_test.exs

**Files:**
- Modify: `runtime/test/esr/resource/slash_route/registry_test.exs`

- [ ] **Step 1: Run the replacement**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
sed -i '' 's/Esr\.Commands\.Notify/Esr.Test.NoopCommand/g' \
    runtime/test/esr/resource/slash_route/registry_test.exs
```

- [ ] **Step 2: Verify replacement count**

```bash
grep -c "Esr.Test.NoopCommand" runtime/test/esr/resource/slash_route/registry_test.exs
grep -c "Esr.Commands.Notify" runtime/test/esr/resource/slash_route/registry_test.exs
```

Expected: 33 hits for NoopCommand, 0 for Notify.

- [ ] **Step 3: Run the registry test to confirm green**

```bash
cd runtime && mix test test/esr/resource/slash_route/registry_test.exs 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add runtime/test/esr/resource/slash_route/registry_test.exs
git commit -m "test(slash_route): use NoopCommand sentinel, not Esr.Commands.Notify"
```

---

## Phase 2: Manifest schema extension

### Task 2.1: Add `slash_routes` to allowed declares + parser

**Files:**
- Modify: `runtime/lib/esr/plugin/manifest.ex`

- [ ] **Step 1: Read the current `validate/1` function and `atomize_declares/1`**

Read `runtime/lib/esr/plugin/manifest.ex` lines 95-101 and 204-212. Confirm `validate/1` chains `validate_caps/1` → `validate_entities/1`. Confirm `atomize_declares/1` is generic (just converts top-level keys).

- [ ] **Step 2: Add a new `validate_slash_routes/1` clause to the validate chain**

Edit `validate/1` at lines 95-101 — change from:

```elixir
@spec validate(t()) :: :ok | {:error, term()}
def validate(%__MODULE__{} = manifest) do
  with :ok <- validate_caps(manifest),
       :ok <- validate_entities(manifest) do
    :ok
  end
end
```

to:

```elixir
@spec validate(t()) :: :ok | {:error, term()}
def validate(%__MODULE__{} = manifest) do
  with :ok <- validate_caps(manifest),
       :ok <- validate_entities(manifest),
       :ok <- validate_slash_routes(manifest) do
    :ok
  end
end
```

- [ ] **Step 3: Add the `validate_slash_routes/1` body**

After the `validate_entities/1` definition (around line 257), insert:

```elixir
# slash_routes validator (audit #6 / 2026-05-08-plugin-command-registration spec).
#
# Hard constraints enforced here (manifest validate time):
#   - every slash key must match `^/<plugin_name>:`
#   - every kind must start with `<plugin_name>_`
#   - every permission must be in this manifest's own capabilities list
#   - every command_module must be loadable AND start with
#     `Esr.Plugins.<PluginCamel>.`
#
# Belt-and-suspenders: SlashRoute.Registry.register_overlay/2 re-checks
# at register time (catches manifests hand-edited at runtime).
defp validate_slash_routes(%__MODULE__{name: name, declares: declares}) do
  case Map.get(declares, :slash_routes) do
    nil ->
      :ok

    block when is_map(block) ->
      caps = Map.get(declares, :capabilities, [])
      slashes = Map.get(block, "slashes", %{}) || %{}
      kinds = Map.get(block, "internal_kinds", %{}) || %{}

      with :ok <- validate_slash_keys(slashes, name),
           :ok <- validate_kind_names(slashes, kinds, name),
           :ok <- validate_permission_subset(slashes, kinds, caps),
           :ok <- validate_command_modules(slashes, kinds, name) do
        :ok
      end

    other ->
      {:error, {:invalid_slash_routes_block, name, other}}
  end
end

defp validate_slash_keys(slashes, plugin_name) do
  prefix = "/" <> plugin_name <> ":"

  Enum.reduce_while(Map.keys(slashes), :ok, fn key, :ok ->
    if String.starts_with?(key, prefix) do
      {:cont, :ok}
    else
      {:halt, {:error, {:bad_slash_prefix, key, plugin_name}}}
    end
  end)
end

defp validate_kind_names(slashes, kinds, plugin_name) do
  prefix = plugin_name <> "_"

  slash_kinds =
    slashes
    |> Map.values()
    |> Enum.flat_map(fn entry ->
      case Map.get(entry, "kind") do
        k when is_binary(k) -> [k]
        _ -> []
      end
    end)

  all_kinds = slash_kinds ++ Map.keys(kinds)

  Enum.reduce_while(all_kinds, :ok, fn kind, :ok ->
    if String.starts_with?(kind, prefix) do
      {:cont, :ok}
    else
      {:halt, {:error, {:bad_kind_prefix, kind, plugin_name}}}
    end
  end)
end

defp validate_permission_subset(slashes, kinds, caps) do
  declared = MapSet.new(caps)

  refs =
    (Map.values(slashes) ++ Map.values(kinds))
    |> Enum.flat_map(fn entry ->
      case Map.get(entry, "permission") do
        nil -> []
        "" -> []
        p when is_binary(p) -> [p]
      end
    end)

  Enum.reduce_while(refs, :ok, fn perm, :ok ->
    if MapSet.member?(declared, perm) do
      {:cont, :ok}
    else
      {:halt, {:error, {:cross_plugin_permission, perm}}}
    end
  end)
end

defp validate_command_modules(slashes, kinds, plugin_name) do
  prefix = "Elixir.Esr.Plugins." <> Macro.camelize(plugin_name) <> "."

  refs =
    (Map.values(slashes) ++ Map.values(kinds))
    |> Enum.flat_map(fn entry ->
      case Map.get(entry, "command_module") do
        m when is_binary(m) -> [m]
        _ -> []
      end
    end)

  Enum.reduce_while(refs, :ok, fn mod_str, :ok ->
    fully_qualified =
      if String.starts_with?(mod_str, "Elixir."),
        do: mod_str,
        else: "Elixir." <> mod_str

    cond do
      not String.starts_with?(fully_qualified, prefix) ->
        {:halt, {:error, {:bad_command_module_prefix, mod_str, plugin_name}}}

      true ->
        mod = String.to_atom(fully_qualified)

        if Code.ensure_loaded?(mod) do
          {:cont, :ok}
        else
          {:halt, {:error, {:unknown_command_module, mod_str}}}
        end
    end
  end)
end
```

- [ ] **Step 4: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -5
```

Expected: clean compile (no warnings).

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugin/manifest.ex
git commit -m "feat(plugin): manifest validate_slash_routes — namespace + cap + module checks"
```

### Task 2.2: Manifest validate test — slash prefix mismatch rejected

**Files:**
- Modify: `runtime/test/esr/plugin/manifest_test.exs`

- [ ] **Step 1: Find the file's tail and pick the test placement**

```bash
grep -n "^end$\|^  describe " runtime/test/esr/plugin/manifest_test.exs | tail -5
```

Identify the last describe block. The new tests append a new describe block at file end (before the final `end`).

- [ ] **Step 2: Write the failing test**

Append before the final `end` of `runtime/test/esr/plugin/manifest_test.exs`:

```elixir
  describe "slash_routes validation (audit #6)" do
    test "rejects a slash key with the wrong plugin prefix" do
      manifest = %Esr.Plugin.Manifest{
        name: "feishu",
        version: "0.1.0",
        description: nil,
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{
          capabilities: ["feishu/bind"],
          slash_routes: %{
            "slashes" => %{
              "/user:bind-feishu" => %{
                "kind" => "feishu_bind",
                "permission" => "feishu/bind",
                "command_module" => "Esr.Plugins.Feishu.Commands.BindUser"
              }
            }
          }
        },
        path: "/tmp/manifest.yaml",
        hot_reloadable: false
      }

      assert {:error, {:bad_slash_prefix, "/user:bind-feishu", "feishu"}} =
               Esr.Plugin.Manifest.validate(manifest)
    end
  end
```

- [ ] **Step 3: Run test (expect FAIL — module under test doesn't ship the validator yet was step 2, but if Task 2.1 already landed it should pass)**

```bash
cd runtime && mix test test/esr/plugin/manifest_test.exs --only line:<line-of-the-test> 2>&1 | tail -3
```

Expected: PASS (Task 2.1 already implemented the validator; this test confirms it works on the slash-prefix axis).

If FAIL: confirm Task 2.1 changes are present, the validator chain runs `validate_slash_routes`, and the bad-prefix arm returns `{:error, {:bad_slash_prefix, ...}}`.

- [ ] **Step 4: Commit**

```bash
git add runtime/test/esr/plugin/manifest_test.exs
git commit -m "test(plugin): manifest rejects bad slash-prefix in slash_routes block"
```

### Task 2.3: Manifest validate tests — kind prefix, permission subset, module loadability

**Files:**
- Modify: `runtime/test/esr/plugin/manifest_test.exs`

- [ ] **Step 1: Append three tests inside the existing `slash_routes validation` describe block**

Add after the existing test from Task 2.2:

```elixir
    test "rejects an internal_kinds entry whose kind doesn't start with <plugin_name>_" do
      manifest = %Esr.Plugin.Manifest{
        name: "feishu",
        version: "0.1.0",
        description: nil,
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{
          capabilities: ["feishu/bind"],
          slash_routes: %{
            "internal_kinds" => %{
              "user_bind_feishu" => %{
                "permission" => "feishu/bind",
                "command_module" => "Esr.Plugins.Feishu.Commands.BindUser"
              }
            }
          }
        },
        path: "/tmp/manifest.yaml",
        hot_reloadable: false
      }

      assert {:error, {:bad_kind_prefix, "user_bind_feishu", "feishu"}} =
               Esr.Plugin.Manifest.validate(manifest)
    end

    test "rejects a permission not declared in this plugin's capabilities" do
      manifest = %Esr.Plugin.Manifest{
        name: "feishu",
        version: "0.1.0",
        description: nil,
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{
          capabilities: ["feishu/manage"],
          slash_routes: %{
            "internal_kinds" => %{
              "feishu_bind" => %{
                "permission" => "claude_code/spawn",
                "command_module" => "Esr.Plugins.Feishu.Commands.BindUser"
              }
            }
          }
        },
        path: "/tmp/manifest.yaml",
        hot_reloadable: false
      }

      assert {:error, {:cross_plugin_permission, "claude_code/spawn"}} =
               Esr.Plugin.Manifest.validate(manifest)
    end

    test "rejects a command_module that doesn't exist (not loadable)" do
      manifest = %Esr.Plugin.Manifest{
        name: "feishu",
        version: "0.1.0",
        description: nil,
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{
          capabilities: ["feishu/bind"],
          slash_routes: %{
            "internal_kinds" => %{
              "feishu_bogus" => %{
                "permission" => "feishu/bind",
                "command_module" => "Esr.Plugins.Feishu.Commands.NopeNotReal"
              }
            }
          }
        },
        path: "/tmp/manifest.yaml",
        hot_reloadable: false
      }

      assert {:error, {:unknown_command_module, "Esr.Plugins.Feishu.Commands.NopeNotReal"}} =
               Esr.Plugin.Manifest.validate(manifest)
    end
```

- [ ] **Step 2: Run all 4 slash_routes-validation tests**

```bash
cd runtime && mix test test/esr/plugin/manifest_test.exs 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/plugin/manifest_test.exs
git commit -m "test(plugin): manifest validates kind prefix, cross-plugin perm, module loadability"
```

---

## Phase 3: SlashRoute.Registry overlay model

### Task 3.1: Refactor Registry state to base + overlays + merged view

**Files:**
- Modify: `runtime/lib/esr/resource/slash_route/registry.ex`

- [ ] **Step 1: Read the existing GenServer `init/1` and `handle_call({:load, snapshot}, ...)`**

Lines 263-290 of the file. Note that `:esr_slash_routes` and `:esr_slash_kinds` are populated directly from the snapshot via `:ets.delete_all_objects` + `:ets.insert`.

- [ ] **Step 2: Refactor state to track base + overlays**

Replace the current `init/1` (lines 263-268) with:

```elixir
@impl true
def init(:ok) do
  :ets.new(@slash_table, [:named_table, :set, :public, read_concurrency: true])
  :ets.new(@kind_table, [:named_table, :set, :public, read_concurrency: true])
  {:ok, %{base: %{slashes: [], internal_kinds: []}, overlays: %{}}}
end
```

- [ ] **Step 3: Refactor `handle_call({:load, snapshot}, ...)` to write base then merge**

Replace the existing handler (lines 270-290) with:

```elixir
@impl true
def handle_call({:load, snapshot}, _from, state) do
  base = %{
    slashes: Map.get(snapshot, :slashes, []),
    internal_kinds: Map.get(snapshot, :internal_kinds, [])
  }

  new_state = %{state | base: base}

  case rebuild_merged_view(new_state) do
    :ok ->
      {:reply, :ok, new_state}

    {:error, reason} = err ->
      Logger.error("SlashRoute.Registry: base load produced collision: #{inspect(reason)}")
      {:reply, err, state}
  end
end
```

- [ ] **Step 4: Add the merge function**

Add after the GenServer callbacks (before the closing `end`):

```elixir
# Rebuild the public ETS tables from base + every overlay. Collision
# across registrations is a hard error — we refuse to install rather
# than silently overwrite.
defp rebuild_merged_view(%{base: base, overlays: overlays}) do
  all_slashes =
    base.slashes ++
      (overlays |> Map.values() |> Enum.flat_map(&Map.get(&1, :slashes, [])))

  all_internal =
    base.internal_kinds ++
      (overlays |> Map.values() |> Enum.flat_map(&Map.get(&1, :internal_kinds, [])))

  with :ok <- detect_slash_collision(all_slashes),
       :ok <- detect_kind_collision(all_slashes ++ all_internal) do
    :ets.delete_all_objects(@slash_table)
    :ets.delete_all_objects(@kind_table)

    Enum.each(all_slashes, fn route ->
      keys = [route.slash | Map.get(route, :aliases, [])]
      Enum.each(keys, fn key -> :ets.insert(@slash_table, {key, route}) end)
      :ets.insert(@kind_table, {route.kind, route})
    end)

    Enum.each(all_internal, fn route -> :ets.insert(@kind_table, {route.kind, route}) end)

    :ok
  end
end

defp detect_slash_collision(slashes) do
  keys =
    Enum.flat_map(slashes, fn route ->
      [route.slash | Map.get(route, :aliases, [])]
    end)

  case keys -- Enum.uniq(keys) do
    [] -> :ok
    [dup | _] -> {:error, {:slash_collision, dup}}
  end
end

defp detect_kind_collision(routes) do
  kinds = Enum.map(routes, & &1.kind)

  case kinds -- Enum.uniq(kinds) do
    [] -> :ok
    [dup | _] -> {:error, {:kind_collision, dup}}
  end
end
```

- [ ] **Step 5: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -3
```

Expected: clean compile.

- [ ] **Step 6: Run existing registry tests — must still pass with the refactor**

```bash
cd runtime && mix test test/esr/resource/slash_route/ 2>&1 | tail -3
```

Expected: all existing tests pass (refactor is internal; public API contracts unchanged for `load_snapshot/1`).

- [ ] **Step 7: Commit**

```bash
git add runtime/lib/esr/resource/slash_route/registry.ex
git commit -m "refactor(slash_route): state = base + overlays + merged view (audit #6)"
```

### Task 3.2: Add `register_overlay/2` + `unregister_overlay/1`

**Files:**
- Modify: `runtime/lib/esr/resource/slash_route/registry.ex`

- [ ] **Step 1: Add public API on top of existing snapshot API**

Locate the `@spec load_snapshot(map())` block (around lines 246-254) and append below it:

```elixir
@doc """
Register a per-plugin slash-route overlay. `snapshot` has the same
shape as the one passed to `load_snapshot/1` (`:slashes` + `:internal_kinds`
lists). Collision against base or any other overlay is a hard error
— the call returns `{:error, {:slash_collision | :kind_collision, key}}`
and the overlay is NOT installed.

Audit #6 / 2026-05-08-plugin-command-registration spec §5.3.
"""
@spec register_overlay(plugin_name :: String.t(), snapshot :: map()) ::
        :ok | {:error, term()}
def register_overlay(plugin_name, snapshot)
    when is_binary(plugin_name) and is_map(snapshot) do
  GenServer.call(__MODULE__, {:register_overlay, plugin_name, snapshot})
end

@doc """
Remove the overlay registered by `plugin_name`. Idempotent — removing
an overlay that was never registered is `:ok`.
"""
@spec unregister_overlay(plugin_name :: String.t()) :: :ok
def unregister_overlay(plugin_name) when is_binary(plugin_name) do
  GenServer.call(__MODULE__, {:unregister_overlay, plugin_name})
end
```

- [ ] **Step 2: Add the GenServer handlers**

After the existing `handle_call({:load, snapshot}, ...)` add:

```elixir
@impl true
def handle_call({:register_overlay, plugin_name, snapshot}, _from, state) do
  overlay = %{
    slashes: Map.get(snapshot, :slashes, []),
    internal_kinds: Map.get(snapshot, :internal_kinds, [])
  }

  candidate = %{state | overlays: Map.put(state.overlays, plugin_name, overlay)}

  case rebuild_merged_view(candidate) do
    :ok ->
      {:reply, :ok, candidate}

    {:error, _} = err ->
      # Collision — do NOT install the overlay; rebuild from the
      # pre-call state so the merged ETS reflects the rolled-back view.
      _ = rebuild_merged_view(state)
      {:reply, err, state}
  end
end

@impl true
def handle_call({:unregister_overlay, plugin_name}, _from, state) do
  candidate = %{state | overlays: Map.delete(state.overlays, plugin_name)}
  :ok = rebuild_merged_view(candidate)
  {:reply, :ok, candidate}
end
```

- [ ] **Step 3: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -3
```

Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/resource/slash_route/registry.ex
git commit -m "feat(slash_route): register_overlay/2 + unregister_overlay/1"
```

### Task 3.3: Overlay tests — register, unregister, collision, base-preserve

**Files:**
- Create: `runtime/test/esr/resource/slash_route/overlay_test.exs`

- [ ] **Step 1: Write the failing test file**

```elixir
defmodule Esr.Resource.SlashRoute.OverlayTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  defp simple_route(slash, kind, mod_str \\ "Esr.Test.NoopCommand") do
    %{
      slash: slash,
      kind: kind,
      permission: nil,
      command_module: Module.concat([mod_str]),
      requires_workspace_binding: false,
      requires_user_binding: false,
      category: "test",
      description: "test",
      args: [],
      aliases: []
    }
  end

  defp base_snapshot(slashes \\ [], internal \\ []) do
    %{slashes: slashes, internal_kinds: internal}
  end

  setup do
    # Reset to a known baseline so tests don't depend on each other.
    :ok = SlashRouteRegistry.load_snapshot(base_snapshot([simple_route("/help", "help")]))
    :ok = SlashRouteRegistry.unregister_overlay("test_a")
    :ok = SlashRouteRegistry.unregister_overlay("test_b")
    :ok
  end

  describe "register_overlay/2" do
    test "installs a plugin's slashes alongside the base table" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([simple_route("/test_a:foo", "test_a_foo")]))

      assert {:ok, _} = SlashRouteRegistry.lookup("/help")
      assert {:ok, _} = SlashRouteRegistry.lookup("/test_a:foo")
      assert SlashRouteRegistry.command_module_for("test_a_foo") == Esr.Test.NoopCommand
    end

    test "rejects an overlay that collides with the base on a slash key" do
      assert {:error, {:slash_collision, "/help"}} =
               SlashRouteRegistry.register_overlay(
                 "test_a",
                 base_snapshot([simple_route("/help", "test_a_help")])
               )

      assert SlashRouteRegistry.command_module_for("help") != Esr.Test.NoopCommand
    end

    test "rejects an overlay that collides with another overlay on a kind" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([], [simple_route("/test_a:x", "shared_kind")]))

      assert {:error, {:kind_collision, "shared_kind"}} =
               SlashRouteRegistry.register_overlay(
                 "test_b",
                 base_snapshot([], [simple_route("/test_b:y", "shared_kind")])
               )
    end
  end

  describe "unregister_overlay/1" do
    test "removes the overlay's entries from the merged view" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([simple_route("/test_a:foo", "test_a_foo")]))

      :ok = SlashRouteRegistry.unregister_overlay("test_a")

      assert :not_found = SlashRouteRegistry.lookup("/test_a:foo")
    end

    test "is idempotent" do
      assert :ok = SlashRouteRegistry.unregister_overlay("never_registered")
    end
  end

  describe "load_snapshot preserves overlays" do
    test "reloading the base file does not wipe a registered overlay" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([simple_route("/test_a:foo", "test_a_foo")]))

      :ok =
        SlashRouteRegistry.load_snapshot(
          base_snapshot([simple_route("/help", "help"), simple_route("/info", "info")])
        )

      assert {:ok, _} = SlashRouteRegistry.lookup("/test_a:foo")
      assert {:ok, _} = SlashRouteRegistry.lookup("/info")
    end
  end
end
```

- [ ] **Step 2: Run the test**

```bash
cd runtime && mix test test/esr/resource/slash_route/overlay_test.exs 2>&1 | tail -5
```

Expected: all 6 tests pass.

If any test fails: re-read Task 3.1 + 3.2 — likely a collision-detection bug or merged-view rebuild bug.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/resource/slash_route/overlay_test.exs
git commit -m "test(slash_route): overlay register/unregister/collision/preserve cases"
```

---

## Phase 4: Plugin.Loader integration

### Task 4.1: Add `register_slash_routes/2` to `start_plugin/2` with-chain

**Files:**
- Modify: `runtime/lib/esr/plugin/loader.ex`

- [ ] **Step 1: Read existing `start_plugin/2` with-chain and the four sibling registrar helpers**

Lines 178-196 (with-chain) and 263-343 (helpers) of `runtime/lib/esr/plugin/loader.ex`.

- [ ] **Step 2: Add the new register_slash_routes/2 step inserted between register_entities and register_startup**

In the `with` block at lines 182-186, change:

```elixir
:ok <- register_capabilities(name, manifest),
:ok <- register_python_sidecars(manifest),
:ok <- register_entities(manifest),
:ok <- register_startup(name, manifest) do
```

to:

```elixir
:ok <- register_capabilities(name, manifest),
:ok <- register_python_sidecars(manifest),
:ok <- register_entities(manifest),
:ok <- register_slash_routes(name, manifest),
:ok <- register_startup(name, manifest) do
```

- [ ] **Step 3: Add the new registrar helper**

After `register_entities/1` (after line 314), insert:

```elixir
# Audit #6 / 2026-05-08-plugin-command-registration spec §5.2.
# Reads the manifest's `slash_routes:` block and registers it as a
# per-plugin overlay on `Esr.Resource.SlashRoute.Registry`. Namespace
# enforcement was already done in `Manifest.validate/1` at parse time;
# the registry's collision detector (audit #6 spec §5.3) catches any
# remaining base/overlay clashes.
#
# Empty / absent block is a no-op (most plugins won't ship slashes).
defp register_slash_routes(plugin_name, %Manifest{declares: declares}) do
  case Map.get(declares, :slash_routes) do
    nil ->
      :ok

    %{} = block when block == %{} ->
      :ok

    block when is_map(block) ->
      snapshot = parse_block_to_snapshot(block)
      Esr.Resource.SlashRoute.Registry.register_overlay(plugin_name, snapshot)
  end
end

# Convert the yaml-shape block (from the manifest) into the same
# {:slashes, :internal_kinds} snapshot shape that the file loader
# produces for the base yaml.  Reuses the file_loader's parser via
# its public `parse_block_to_snapshot/1` (Phase 4 task adds this).
defp parse_block_to_snapshot(block) do
  Esr.Resource.SlashRoute.FileLoader.parse_block_to_snapshot(block)
end
```

- [ ] **Step 4: Compile (will fail — `parse_block_to_snapshot` doesn't exist on FileLoader yet)**

```bash
cd runtime && mix compile 2>&1 | tail -5
```

Expected: warnings about `Esr.Resource.SlashRoute.FileLoader.parse_block_to_snapshot/1` being undefined. We add it in Task 4.2.

- [ ] **Step 5: Don't commit yet — the chain is incomplete. Move to Task 4.2.**

### Task 4.2: Extract `parse_block_to_snapshot/1` in FileLoader

**Files:**
- Modify: `runtime/lib/esr/resource/slash_route/file_loader.ex`

- [ ] **Step 1: Read existing `parse_slash_routes/1` and find the inner parsing logic**

```bash
grep -n "defp parse_\|def parse_\|^  def\|^  defp " runtime/lib/esr/resource/slash_route/file_loader.ex | head -20
```

- [ ] **Step 2: Add a public `parse_block_to_snapshot/1` that wraps the existing internal parser**

Add near the top of `runtime/lib/esr/resource/slash_route/file_loader.ex` after the `defmodule` opening and `@moduledoc`:

```elixir
@doc """
Parse a yaml-shape `slash_routes:` block (top-level keys: `"slashes"`,
`"internal_kinds"`) into the `:slashes` + `:internal_kinds` snapshot
that `Esr.Resource.SlashRoute.Registry.load_snapshot/1` and
`register_overlay/2` expect.

Used by both the file-watcher path (base yaml) and the plugin loader
(per-plugin manifest). One parser, two callers — see audit #6 spec §5.4.
"""
@spec parse_block_to_snapshot(map()) :: %{slashes: list(), internal_kinds: list()}
def parse_block_to_snapshot(block) when is_map(block) do
  slashes_map = Map.get(block, "slashes", %{}) || %{}
  internal_map = Map.get(block, "internal_kinds", %{}) || %{}

  slashes =
    Enum.flat_map(slashes_map, fn {key, entry} ->
      case validate_slash_entry(key, entry) do
        {:ok, route} -> [route]
        {:error, _} -> []
      end
    end)

  internal_kinds =
    Enum.flat_map(internal_map, fn {kind, entry} ->
      case validate_kind_entry(kind, entry) do
        {:ok, route} -> [route]
        {:error, _} -> []
      end
    end)

  %{slashes: slashes, internal_kinds: internal_kinds}
end
```

If `validate_slash_entry/2` is private (`defp`), promote it to public (`def`) — the helper at the line you found in Step 1.  Same for `validate_kind_entry/2` if it exists, or refactor the inline kind-parser into a function with that name.

If the existing parser inlines kind-extraction in `validate_slash_entry`, extract a sibling `validate_kind_entry/2` that does the same but for the simpler internal_kinds shape (only `permission`, `command_module`).

- [ ] **Step 3: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -3
```

Expected: clean (Task 4.1's call to `parse_block_to_snapshot/1` now resolves).

- [ ] **Step 4: Run existing slash_route tests**

```bash
cd runtime && mix test test/esr/resource/slash_route/ 2>&1 | tail -3
```

Expected: all pass (the extraction is a refactor; behavior is preserved).

- [ ] **Step 5: Commit (single commit covering Tasks 4.1 + 4.2)**

```bash
git add runtime/lib/esr/plugin/loader.ex runtime/lib/esr/resource/slash_route/file_loader.ex
git commit -m "feat(plugin): Loader.register_slash_routes/2 via FileLoader.parse_block_to_snapshot/1"
```

### Task 4.3: Wire `unregister_overlay/1` from `stop_plugin/1`

**Files:**
- Modify: `runtime/lib/esr/plugin/loader.ex`

- [ ] **Step 1: Find stop_plugin/1**

```bash
grep -n "def stop_plugin\|defp stop_plugin\|stop_plugin(_\|stop_plugin\\b" runtime/lib/esr/plugin/loader.ex | head -10
```

- [ ] **Step 2: Edit stop_plugin/1 to call unregister_overlay**

If `stop_plugin/1` is currently a stub `defp stop_plugin(_), do: :ok`, replace with:

```elixir
def stop_plugin(name) when is_binary(name) do
  Esr.Resource.SlashRoute.Registry.unregister_overlay(name)
  :ok
end
```

If it's a `defp` (private), promote to `def` so it's callable from a plugin-management command later.

- [ ] **Step 3: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -3
```

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/plugin/loader.ex
git commit -m "feat(plugin): stop_plugin/1 calls SlashRoute.Registry.unregister_overlay/1"
```

### Task 4.4: Integration test — feishu plugin starts with empty slash_routes block, daemon stays up

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`
- Test: `runtime/test/esr/plugin/loader_test.exs` (or wherever existing loader integration tests live)

- [ ] **Step 1: Add an empty `slash_routes:` block to the feishu manifest as a sanity gate**

Edit `runtime/lib/esr/plugins/feishu/manifest.yaml` — append at the end of the `declares:` block (after the existing `entities:`/`python_sidecars:`/`startup:` sections, before `config_schema:`):

```yaml
  # Audit #6 (2026-05-08-plugin-command-registration spec §7b):
  # Phase 5 + Phase 6 of the plan land the actual migrated commands
  # (notify, bind_user, unbind_user) here. The empty block ships first
  # as a sanity gate that the validator accepts a no-op manifest.
  slash_routes:
    schema_version: 1
    slashes: {}
    internal_kinds: {}
```

- [ ] **Step 2: Compile + run the test suite to confirm Loader still starts feishu cleanly**

```bash
cd runtime && mix test test/esr/plugins/feishu/ test/esr/plugin/ 2>&1 | tail -5
```

Expected: all pass. The empty block exercises the validator's "absent / empty is no-op" branch.

- [ ] **Step 3: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/manifest.yaml
git commit -m "feat(feishu): empty slash_routes block — sanity-gate Phase 4 mechanism"
```

---

## Phase 5: Migrate `notify`

### Task 5.1: Move `Esr.Commands.Notify` source file + rename module

**Files:**
- Create: `runtime/lib/esr/plugins/feishu/commands/notify.ex`
- Delete: `runtime/lib/esr/commands/notify.ex`

- [ ] **Step 1: Create the new file**

```bash
mkdir -p runtime/lib/esr/plugins/feishu/commands
git mv runtime/lib/esr/commands/notify.ex \
       runtime/lib/esr/plugins/feishu/commands/notify.ex
```

- [ ] **Step 2: Rename the module declaration inside the file**

Open `runtime/lib/esr/plugins/feishu/commands/notify.ex`. The first line is:

```elixir
defmodule Esr.Commands.Notify do
```

Change to:

```elixir
defmodule Esr.Plugins.Feishu.Commands.Notify do
```

- [ ] **Step 3: Add a one-line file-header comment about the move**

After the `defmodule` line (before `@moduledoc`), keep the moduledoc as-is and add — inside the moduledoc — a final paragraph:

```elixir
  Phase 5 of audit #6 (2026-05-08-plugin-command-registration plan):
  moved from `Esr.Commands.Notify` into the feishu plugin namespace.
  Logic unchanged; only the module name and file path differ.
```

- [ ] **Step 4: Compile (will fail — callers still reference old module)**

```bash
cd runtime && mix compile 2>&1 | tail -5
```

Expected: warning(s) about `Esr.Commands.Notify` being undefined / used by `Esr.Scope.Admin.Process` doc + slash-routes yaml.

- [ ] **Step 5: Don't commit — continue to Task 5.2.**

### Task 5.2: Move + rename the test file

**Files:**
- Create: `runtime/test/esr/plugins/feishu/commands/notify_test.exs`
- Delete: `runtime/test/esr/commands/notify_test.exs`

- [ ] **Step 1: Move the test file**

```bash
mkdir -p runtime/test/esr/plugins/feishu/commands
git mv runtime/test/esr/commands/notify_test.exs \
       runtime/test/esr/plugins/feishu/commands/notify_test.exs
```

- [ ] **Step 2: Update module references inside the test file**

```bash
sed -i '' 's/Esr\.Commands\.Notify/Esr.Plugins.Feishu.Commands.Notify/g' \
    runtime/test/esr/plugins/feishu/commands/notify_test.exs
```

- [ ] **Step 3: Update the test module name itself**

Open the file. The first line:

```elixir
defmodule Esr.Commands.NotifyTest do
```

(was already replaced by the sed above to `Esr.Plugins.Feishu.Commands.NotifyTest`). Verify with:

```bash
head -3 runtime/test/esr/plugins/feishu/commands/notify_test.exs
```

- [ ] **Step 4: Run the test to confirm it still passes (against the moved module)**

```bash
cd runtime && mix test test/esr/plugins/feishu/commands/notify_test.exs 2>&1 | tail -3
```

Expected: all pass — logic is unchanged, only module names moved.

- [ ] **Step 5: Don't commit — continue to Task 5.3 to wire the registration.**

### Task 5.3: Add `notify` to feishu manifest's `slash_routes:` block + delete from core yaml

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`
- Modify: `runtime/priv/slash-routes.default.yaml`

- [ ] **Step 1: Replace the empty manifest block with the populated version**

In `runtime/lib/esr/plugins/feishu/manifest.yaml`, replace the empty `slash_routes:` block from Task 4.4 with:

```yaml
  slash_routes:
    schema_version: 1
    slashes: {}
    internal_kinds:
      notify:
        permission: "notify.send"
        command_module: "Esr.Plugins.Feishu.Commands.Notify"
```

- [ ] **Step 2: Add `notify.send` to the feishu plugin's declared `capabilities:` if not already present**

Check existing `capabilities:` in feishu manifest:

```bash
grep -A 10 "^declares:" runtime/lib/esr/plugins/feishu/manifest.yaml | grep -i "capab\|notify"
```

If `notify.send` isn't there, add it under `declares.capabilities:`:

```yaml
  capabilities:
    - notify.send
```

(If `capabilities:` doesn't exist at all under `declares:`, add the whole block.)

- [ ] **Step 3: Delete `notify` from `slash-routes.default.yaml`**

Remove lines 514-516 from `runtime/priv/slash-routes.default.yaml` (the 3-line block):

```yaml
  notify:
    permission: "notify.send"
    command_module: "Esr.Commands.Notify"
```

Verify removal:

```bash
grep -n "^  notify:\|kind: notify" runtime/priv/slash-routes.default.yaml
```

Expected: empty output.

- [ ] **Step 4: Update doc-comment in admin/process.ex**

Open `runtime/lib/esr/scope/admin/process.ex`. Around line 31-33 the doc says:

```elixir
  Used by legacy callers (e.g. `Esr.Commands.Notify`) that need
```

Change to:

```elixir
  Used by legacy callers (e.g. `Esr.Plugins.Feishu.Commands.Notify`) that need
```

- [ ] **Step 5: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -5
```

Expected: clean compile, no warnings about `Esr.Commands.Notify` undefined.

- [ ] **Step 6: Run notify_test, registry tests, and any feishu plugin tests**

```bash
cd runtime && mix test test/esr/plugins/feishu/ test/esr/resource/slash_route/ 2>&1 | tail -5
```

Expected: all pass. The runtime resolves `kind: notify` to `Esr.Plugins.Feishu.Commands.Notify` via the loader's overlay registration at boot.

- [ ] **Step 7: Commit (single commit covering Tasks 5.1 + 5.2 + 5.3)**

```bash
git add runtime/lib/esr/plugins/feishu/commands/notify.ex \
        runtime/test/esr/plugins/feishu/commands/notify_test.exs \
        runtime/lib/esr/plugins/feishu/manifest.yaml \
        runtime/priv/slash-routes.default.yaml \
        runtime/lib/esr/scope/admin/process.ex
git rm runtime/lib/esr/commands/notify.ex || true
git rm runtime/test/esr/commands/notify_test.exs || true
git commit -m "refactor(feishu): migrate Esr.Commands.Notify → Esr.Plugins.Feishu.Commands.Notify"
```

---

## Phase 6: Migrate `bind_feishu` + `unbind_feishu`

### Task 6.1: Add `feishu/user-bind` cap to permission bootstrap

**Files:**
- Modify: `runtime/lib/esr/resource/permission/bootstrap.ex`

- [ ] **Step 1: Read current @subsystem_permissions**

Lines 23-46 of the file. The `user.manage` entry on line 35 currently gates user_add/remove + bind/unbind.

- [ ] **Step 2: Add `feishu/user-bind` and update the docstring on `user.manage`**

Edit lines 33-35 from:

```elixir
    # Phase B-3 (2026-05-05): `user.manage` gates user_add/remove/
    # bind-feishu/unbind-feishu. Read-only `user_list` is permission-less.
    {"user.manage", Esr.Entity.User.Registry},
```

to:

```elixir
    # Phase B-3 (2026-05-05): `user.manage` gates user_add/remove.
    # As of audit #6 (2026-05-08-plugin-command-registration), the
    # bind-feishu/unbind-feishu commands moved into the feishu plugin
    # and switched to `feishu/user-bind` (declared by feishu manifest
    # `capabilities:`). `user.manage` is now identity-only.
    # Read-only `user_list` is permission-less.
    {"user.manage", Esr.Entity.User.Registry},
```

- [ ] **Step 3: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -3
```

Expected: clean compile (no functional change yet — the new cap is declared by the feishu manifest in a later task).

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/resource/permission/bootstrap.ex
git commit -m "docs(perm): user.manage now identity-only; bind moves to feishu/user-bind"
```

### Task 6.2: Move `BindFeishu` source + rename module + rename cap

**Files:**
- Create: `runtime/lib/esr/plugins/feishu/commands/bind_user.ex`
- Delete: `runtime/lib/esr/commands/user/bind_feishu.ex`

- [ ] **Step 1: Move the file**

```bash
git mv runtime/lib/esr/commands/user/bind_feishu.ex \
       runtime/lib/esr/plugins/feishu/commands/bind_user.ex
```

- [ ] **Step 2: Rename the module declaration inside**

Open `runtime/lib/esr/plugins/feishu/commands/bind_user.ex`. Change:

```elixir
defmodule Esr.Commands.User.BindFeishu do
```

to:

```elixir
defmodule Esr.Plugins.Feishu.Commands.BindUser do
```

- [ ] **Step 3: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -5
```

Expected: warnings only — the slash-routes yaml still references the old module via `command_module:`. We fix that in Task 6.4.

### Task 6.3: Move `UnbindFeishu` source + rename module

**Files:**
- Create: `runtime/lib/esr/plugins/feishu/commands/unbind_user.ex`
- Delete: `runtime/lib/esr/commands/user/unbind_feishu.ex`

- [ ] **Step 1: Move the file**

```bash
git mv runtime/lib/esr/commands/user/unbind_feishu.ex \
       runtime/lib/esr/plugins/feishu/commands/unbind_user.ex
```

- [ ] **Step 2: Rename the module declaration inside**

Open `runtime/lib/esr/plugins/feishu/commands/unbind_user.ex`. Change:

```elixir
defmodule Esr.Commands.User.UnbindFeishu do
```

to:

```elixir
defmodule Esr.Plugins.Feishu.Commands.UnbindUser do
```

- [ ] **Step 3: Compile (still expect slash-routes warnings until Task 6.4)**

```bash
cd runtime && mix compile 2>&1 | tail -5
```

### Task 6.4: Migrate the registrations (manifest + remove from core yaml)

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`
- Modify: `runtime/priv/slash-routes.default.yaml`

- [ ] **Step 1: Add `feishu/user-bind` to feishu manifest's `capabilities:`**

In `runtime/lib/esr/plugins/feishu/manifest.yaml`, ensure `declares.capabilities:` includes:

```yaml
  capabilities:
    - notify.send
    - feishu/user-bind
```

- [ ] **Step 2: Extend the manifest's `internal_kinds:` with bind/unbind**

In the same file's `slash_routes.internal_kinds:` block (currently has `notify` from Phase 5), add:

```yaml
    internal_kinds:
      notify:
        permission: "notify.send"
        command_module: "Esr.Plugins.Feishu.Commands.Notify"
      user_bind_feishu:
        permission: "feishu/user-bind"
        command_module: "Esr.Plugins.Feishu.Commands.BindUser"
      user_unbind_feishu:
        permission: "feishu/user-bind"
        command_module: "Esr.Plugins.Feishu.Commands.UnbindUser"
```

- [ ] **Step 3: Delete `user_bind_feishu` and `user_unbind_feishu` from `slash-routes.default.yaml`**

Remove lines 591-597 (the two 3-line blocks) from `runtime/priv/slash-routes.default.yaml`.

Verify:

```bash
grep -n "user_bind_feishu\|user_unbind_feishu" runtime/priv/slash-routes.default.yaml
```

Expected: empty output.

- [ ] **Step 4: Compile**

```bash
cd runtime && mix compile 2>&1 | tail -5
```

Expected: clean — no warnings about undefined modules.

- [ ] **Step 5: Run all relevant tests**

```bash
cd runtime && mix test test/esr/plugins/feishu/ test/esr/resource/slash_route/ test/esr/plugin/ test/esr/commands/user/ 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 6: Commit (single commit covering Tasks 6.2 + 6.3 + 6.4)**

```bash
git add runtime/lib/esr/plugins/feishu/commands/bind_user.ex \
        runtime/lib/esr/plugins/feishu/commands/unbind_user.ex \
        runtime/lib/esr/plugins/feishu/manifest.yaml \
        runtime/priv/slash-routes.default.yaml
git rm runtime/lib/esr/commands/user/bind_feishu.ex || true
git rm runtime/lib/esr/commands/user/unbind_feishu.ex || true
git commit -m "refactor(feishu): migrate User.{Bind,Unbind}Feishu → feishu plugin"
```

### Task 6.5: Migration regression test — admin-CLI dispatch via kind name

**Files:**
- Modify: `runtime/test/esr/plugins/feishu/commands/notify_test.exs` (add an integration shape check) OR add a small new test file.

- [ ] **Step 1: Add a test that confirms the registry resolves the migrated kinds**

Append to `runtime/test/esr/plugins/feishu/commands/notify_test.exs` or create `runtime/test/esr/plugins/feishu/commands/migration_test.exs`:

```elixir
defmodule Esr.Plugins.Feishu.MigrationTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  describe "post-migration kind dispatch (audit #6)" do
    test "kind: notify resolves to the new module" do
      # The runtime boots with the feishu plugin's overlay already
      # registered (via Plugin.Loader.start_plugin/2 → register_slash_routes).
      assert Esr.Plugins.Feishu.Commands.Notify ==
               SlashRouteRegistry.command_module_for("notify")
    end

    test "kind: user_bind_feishu resolves to BindUser" do
      assert Esr.Plugins.Feishu.Commands.BindUser ==
               SlashRouteRegistry.command_module_for("user_bind_feishu")
    end

    test "kind: user_unbind_feishu resolves to UnbindUser" do
      assert Esr.Plugins.Feishu.Commands.UnbindUser ==
               SlashRouteRegistry.command_module_for("user_unbind_feishu")
    end
  end
end
```

- [ ] **Step 2: Run the test**

```bash
cd runtime && mix test test/esr/plugins/feishu/ 2>&1 | tail -5
```

Expected: all 3 cases pass — kind names stable, only the module flipped.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/plugins/feishu/commands/migration_test.exs
git commit -m "test(feishu): post-migration kind names dispatch to new modules"
```

---

## Phase 7: Final regression sweep + PR

### Task 7.1: Full unit-test sweep

**Files:** none

- [ ] **Step 1: Run the full test suite**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev/runtime
mix test 2>&1 | tail -3
```

Expected: ≤ Phase 0 baseline failure count (9) plus or minus seed-dependent flakes. No NEW deterministic failures.

- [ ] **Step 2: If new failures appear, identify the root cause (do not paper over)**

For each new failure:
1. Read the test
2. Read the production code it exercises
3. If the test is asserting the OLD module name, update the test
4. If the test is asserting OLD slash-routes shape, update the fixture
5. Re-run

Common gotchas:
- A test that imported `Esr.Commands.Notify` directly — switch to `Esr.Plugins.Feishu.Commands.Notify`
- A test fixture loading slash-routes.yaml with the deleted `notify:` entry — remove the assertion or update to expect overlay-driven registration

### Task 7.2: E2E scenarios 14 / 18 / 19 from a clean wipe

**Files:** none

- [ ] **Step 1: Wipe + run e2e-19 (session-first scenario, the gating test for #5)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
echo "yes" | tools/wipe-esrd-home.sh --dev
make e2e-19 2>&1 | tail -3
```

Expected: `PASS: 19_session_first_default`.

- [ ] **Step 2: Wipe + run e2e-14 (multi-agent regression)**

```bash
echo "yes" | tools/wipe-esrd-home.sh --dev
make e2e-14 2>&1 | tail -3
```

Expected: `PASS: 14_session_multiagent`.

- [ ] **Step 3: Wipe + run e2e-18 (multi-CC atomic spawn)**

```bash
echo "yes" | tools/wipe-esrd-home.sh --dev
make e2e-18 2>&1 | tail -3
```

Expected: `PASS: 18_multi_cc_atomic_spawn`.

- [ ] **Step 4: If any e2e fails, debug:**
  - `kind: notify` not found → loader didn't load feishu's overlay (check Plugin.Loader.start_plugin/2 chain order)
  - `kind: user_bind_feishu` not found → same root cause
  - Slash-route registry collision → an entry was double-registered (base yaml still has it AND manifest declares it)

### Task 7.3: Subagent code-reviewer pass

**Files:** none

- [ ] **Step 1: Dispatch a code-reviewer subagent**

Use the `superpowers:code-reviewer` agent type with `model: "opus"`. Brief it on:
- Working dir `/Users/h2oslabs/Workspace/esr/.worktrees/dev`
- Branch `feat/session-first-default-resolution` is now ~30+ commits ahead of `origin/dev`
- Spec at `docs/superpowers/specs/2026-05-08-plugin-command-registration.md` rev-2
- Plan at `docs/superpowers/plans/2026-05-08-plugin-command-registration-plan.md`
- Key files to review:
  - `runtime/lib/esr/plugin/manifest.ex` — slash_routes validator
  - `runtime/lib/esr/plugin/loader.ex` — register_slash_routes integration
  - `runtime/lib/esr/resource/slash_route/registry.ex` — overlay model + collision detection
  - `runtime/lib/esr/resource/slash_route/file_loader.ex` — extracted parse_block_to_snapshot
  - `runtime/lib/esr/plugins/feishu/manifest.yaml` — slash_routes block
  - `runtime/lib/esr/plugins/feishu/commands/{notify,bind_user,unbind_user}.ex`
  - `runtime/test/support/noop_command.ex` — sentinel
  - `runtime/test/esr/plugin/manifest_test.exs` — validate cases
  - `runtime/test/esr/resource/slash_route/overlay_test.exs` — overlay cases
  - `runtime/test/esr/plugins/feishu/commands/migration_test.exs` — kind-stable assertions
- Ask for: 🔴 Blockers / 🟡 Concerns / 🟢 Strengths, under 600 words.

- [ ] **Step 2: Address any 🔴 blockers in-loop (do NOT proceed to PR with blockers)**

For each blocker: write a failing test first (TDD), implement the fix, confirm green, re-run focused subset, commit.

- [ ] **Step 3: Note 🟡 concerns**

If yellows are small (≤ 30 LOC each) and don't depend on user input, fix in-loop. If they're scope-extending, add to `docs/futures/todo.md` with target.

### Task 7.4: Push + open PR + admin-merge to dev

**Files:** none

- [ ] **Step 1: Confirm branch state**

```bash
git status
git log --oneline origin/dev..HEAD | wc -l
```

Expected: clean tree; 30+ commits ahead of origin/dev.

- [ ] **Step 2: Heads-up Feishu before pushing (memory rule: notify before remote ops)**

Send to `oc_d9b47511b085e9d5b66c4595b3ef9bb9`:

> [PR push] feat/session-first-default-resolution → dev. Bundles #5 session-first + reviewer yellows + #6 plugin-command registration + 3-command physical migration. Pushing now.

- [ ] **Step 3: Push the branch**

```bash
git push -u origin feat/session-first-default-resolution
```

- [ ] **Step 4: Open the PR**

```bash
gh pr create --base dev \
  --title "feat: session-first default + plugin-scoped command registration + feishu migration" \
  --body "$(cat <<'EOF'
## Summary

Bundles two audit-driven features + reviewer yellow-fixes:

### #5 Session-first default workspace resolution (2026-05-08-session-first-default-resolution.md)
- /user:add auto-creates <username>-default workspace + sets as user-default
- /user:use changes user-default to a different workspace (persists to user.json)
- /session:new fallback chain: explicit → chat-default → user-default → error
- /workspace:add-folder name= optional (falls back through chain)
- Bootstrap eliminates the literal "default" workspace
- e2e scenario 19 (session-first invariant gate) — PR-blocking, runs green from clean wipe

### Reviewer yellow-fixes (post-#5 review)
- /user:use persists default_workspace_id to user.json (survives restart, spec §4.3 conformance)
- User.Add atomic rollback on partial failure (spec §9 invariant 5)

### #6 Plugin-scoped command registration (2026-05-08-plugin-command-registration.md)
- Esr.Plugin.Manifest gains `slash_routes:` declaration block
- Esr.Resource.SlashRoute.Registry refactored: base + per-plugin overlays + merged view; collision detection at register time
- Esr.Plugin.Loader register_slash_routes/2 wired into start_plugin/2 with-chain
- Belt-and-suspenders namespace enforcement (manifest validate + register-time)

### Physical migration (proves the mechanism end-to-end)
- Esr.Commands.Notify → Esr.Plugins.Feishu.Commands.Notify
- Esr.Commands.User.BindFeishu → Esr.Plugins.Feishu.Commands.BindUser
- Esr.Commands.User.UnbindFeishu → Esr.Plugins.Feishu.Commands.UnbindUser
- New cap feishu/user-bind (replaces user.manage for bind/unbind)
- registry_test.exs sentinel: Esr.Commands.Notify → Esr.Test.NoopCommand
- kind: notify / user_bind_feishu / user_unbind_feishu names stable — external dispatch unchanged

## Test plan
- [x] mix test — at Phase 0 baseline (9 failures, all pre-existing)
- [x] e2e scenario 14 (multi-agent) — PASS from clean wipe
- [x] e2e scenario 18 (multi-CC atomic spawn) — PASS from clean wipe
- [x] e2e scenario 19 (session-first invariant) — PASS from clean wipe
- [x] subagent code-reviewer pass — no blockers

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Admin-merge per memory rule (in ezagent42/esr; auto-merge each PR in planned sequences)**

```bash
gh pr merge --admin --squash --delete-branch
```

- [ ] **Step 6: Notify Feishu**

Send to `oc_d9b47511b085e9d5b66c4595b3ef9bb9`:

> [#5 + #6 ✓ merged to dev] PR <url>. Branches deleted. Phase 10 of #5 plan + Phase 7 of #6 plan complete. Audit task 5 and 6 closed.

- [ ] **Step 7: Mark TaskUpdate items completed**

Update task #426 (#5 execute) and #429 (#6 brainstorm) to completed if not already; close #6 implementation tracking task if one was created.

---

## Invariants (verified by the test suite, not the plan)

After Phase 7 finishes, the following must hold:

- **I1.** No two distinct registrations (base + overlays) ever share a slash key in the merged ETS table. Violation → registry refuses to install.
- **I2.** Every slash key in the merged ETS is prefixed with either a known core group (`/user:`, `/workspace:`, `/session:`, `/plugin:`, `/cap:`, `/help`) or a registered plugin's name (`/<plugin>:`). No exceptions.
- **I3.** Every kind in the merged ETS is prefixed by a core group or `<plugin>_`.
- **I4.** Plugin-declared `permission:` values are a subset of that plugin's declared `capabilities:`. No cross-plugin references.
- **I5.** `kind: notify`, `kind: user_bind_feishu`, `kind: user_unbind_feishu` continue to dispatch correctly via `SlashRoute.Registry.command_module_for/1` (verified by Task 6.5's migration_test).
