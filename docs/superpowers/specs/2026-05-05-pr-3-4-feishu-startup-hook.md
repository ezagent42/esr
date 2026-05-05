# PR-3.4 — Feishu Plugin Startup Hook

**Date:** 2026-05-05
**Status:** Rev 3 (workarounds + whitelists + defaults + warn-and-degrade dropped per user feedback)
**Closes:** Phase 3 PR-3.4; North Star "feishu changes don't touch core" final gap.

## Goal

Move the boot-time call to `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0`
(currently in `Esr.Application.start/2:278`) into the feishu plugin
itself. After this PR:

1. **Adding a feishu instance** to `adapters.yaml` does not touch
   any file under `runtime/lib/esr/{application,scope,entity,
   resource}/`.
2. **Disabling the feishu plugin** (`enabled: []` in `plugins.yaml`)
   means feishu's startup callback doesn't run — no fallback path
   in core silently spawns FAA peers.
3. **A future codex/gemini-cli plugin** uses the same
   plugin-startup mechanism instead of inventing parallel logic.

## Non-goals

- Plugin shutdown hooks. Add when a plugin needs them.
- Per-instance lifecycle callbacks (used by `cli:adapters/rename`
  for terminate-old + spawn-new). Out of scope; rev 3 keeps the
  rename dispatch in `cli_channel.ex` calling into the new plugin
  module directly.
- Reloadable plugins (runtime enable/disable). Today restart-
  required; this PR doesn't change that.

## Architecture

### Plugin manifest gains a `startup:` field

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  entities: [...]
  python_sidecars: [...]
  startup:
    module: Esr.Plugins.Feishu.Bootstrap
    function: bootstrap
```

**Required fields**: `module:` and `function:`. No defaults — if
the manifest is missing either, `Esr.Plugin.Loader` raises during
`start_plugin/2`. Loud failure surfaces the typo immediately.

The shape is a single map (`startup: %{module:, function:}`), not a
list. A plugin with multiple bootstrap concerns wraps them in one
top-level function — keeps the manifest schema simple. Lifting to a
list later is a non-breaking change.

### `Esr.Plugin.Loader` gains startup orchestration

Two new responsibilities, both implemented as plain module
functions (Loader has no GenServer):

1. **`register_startup/1`** — called from `start_plugin/2` after
   entities/sidecars register. Reads the manifest's `startup:`
   block, validates `Code.ensure_loaded?(module)` and
   `function_exported?(module, function, 0)`. **Raises** on either
   failure — boot crashes with a clear error message naming the
   plugin and the missing module/function. Pushes the validated
   `{plugin_name, module, function}` tuple to a `:persistent_term`
   list keyed by `{__MODULE__, :startup_callbacks}`.

2. **`run_startup/0`** — called once from `Esr.Application.start/2`
   after `restore_adapters_from_disk/1` returns. Reads the
   `:persistent_term` list and calls each `module.function.()` in
   plugin-enable order. **No try/rescue.** A startup callback
   raising propagates and crashes esrd boot. The user explicitly
   wants let-it-crash; degraded-boot-with-warning hides incidents.

`:persistent_term` is the right store: writes are boot-only
(amortized GC cost is fine), reads are O(1), no GenServer
serialization on the read path. The Loader is module-functions-
only, so no obvious owner process exists; introducing a GenServer
just for this would be heavier than the storage actually warrants.

### Order in `Esr.Application.start/2`

```elixir
:ok = Esr.Entity.Agent.StatefulRegistry.register(Esr.Entity.PtyProcess)
load_enabled_plugins()                  # registers entities + sidecars + startup callbacks
load_workspaces_from_disk(...)
load_agents_from_disk()
restore_adapters_from_disk(...)
Esr.Plugin.Loader.run_startup()         # NEW — replaces the line below
# DELETED: _ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()
```

The boot-time call site (line 278) is **deleted**. Loader's
`run_startup/0` replaces it generically.

### `Esr.Plugins.Feishu.Bootstrap` (new module)

```elixir
# runtime/lib/esr/plugins/feishu/bootstrap.ex
defmodule Esr.Plugins.Feishu.Bootstrap do
  @moduledoc """
  Spawns one `Esr.Entity.FeishuAppAdapter` peer per `type: feishu`
  instance in `adapters.yaml`. Called by `Esr.Plugin.Loader.run_startup/0`
  at boot, and by `cli:adapters/{refresh,rename}` for runtime adapter
  CRUD.
  """

  @spec bootstrap() :: :ok
  def bootstrap, do: bootstrap(Esr.Paths.adapters_yaml())

  @spec bootstrap(Path.t()) :: :ok
  def bootstrap(adapters_yaml_path) do
    # body lifted verbatim from old Scope.Admin function
    ...
  end

  defp spawn_feishu_app_adapter(sup, instance_id, app_id) do
    # private helper, also lifted verbatim
    ...
  end
end
```

### `Esr.Scope.Admin` cleanup

After this PR:

- **`bootstrap_feishu_app_adapters/0` and `/1` deleted entirely.**
  No shim, no deprecated wrapper. The function moves to
  `Esr.Plugins.Feishu.Bootstrap.bootstrap/0|1` with the same body.
- **`spawn_feishu_app_adapter/3` deleted.** Moves with the public
  function.
- **`terminate_feishu_app_adapter/1` STAYS.** Used by `/end-session`
  cleanup logic; relocating it is a separate concern (per-instance
  lifecycle, out of scope).

### `cli_channel.ex` callers update

The two callers in `runtime/lib/esr_web/cli_channel.ex` change from:

```elixir
_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()
```

to:

```elixir
_ = Esr.Plugins.Feishu.Bootstrap.bootstrap()
```

This is a **direct cross-layer call** from cli_channel to the
feishu plugin. Yes, that means `cli_channel.ex` references a
plugin module by name. **The plugin-isolation invariant test
intentionally does not enforce isolation against `cli_channel.ex`**
— see "Invariant test scope" below.

## Invariant test scope

The new test `Esr.Plugins.IsolationTest` asserts:

> No file under `runtime/lib/esr/{application,scope,entity,resource}/`
> references `Esr.Plugins.Feishu.*` or
> `Esr.Scope.Admin.bootstrap_feishu_app_adapters`.

**Scope is the runtime boot path + per-session state directories,
not the entire codebase.** The test does NOT inspect:

- `runtime/lib/esr_web/` — Phoenix transport layer. cli_channel.ex
  calling `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` is a transport-
  layer dispatch, not a runtime-boot dependency.
- `runtime/lib/esr/interface/` — interface contracts. `@moduledoc`
  examples that mention `Esr.Entity.FeishuAppAdapter` are
  documentation, not code dependency.
- `runtime/lib/esr/cli/` — escript CLI source. References to plugin
  command modules are part of the CLI dispatch surface.

**No whitelist, no exception list.** The scope is narrow by design.
The architectural goal of PR-3.4 is "the runtime boot path is plugin-
agnostic" — the test enforces exactly that, and nothing more.

If a future PR wants to make `cli_channel.ex` plugin-agnostic too,
that's a separate spec (Phase D-3 candidate). The test would gain
new scoped assertions then, not a whitelist.

## Failure modes

| When | Behaviour |
|---|---|
| Manifest's startup `module:` doesn't load | `register_startup/1` raises with `"plugin <name>: startup module #{inspect(module)} not loadable"`. esrd boot crashes. |
| Manifest's startup `function:` not exported | Same — raise with explicit message. |
| Startup callback raises during `run_startup/0` | Propagates. esrd boot crashes with stacktrace. |
| Multiple plugins' startups have unrelated failures | First-fail wins; subsequent plugins don't run. Operator fixes the root cause and restarts. |
| `adapters.yaml` malformed | `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` raises (or returns `:ok` for no-such-file — depends on existing semantics, no behavior change). |

**No `try/rescue`. No `:warning` log + continue.** If startup fails,
the operator sees a loud crash with the actual error.

## Test strategy

| Layer | Test | What it asserts |
|---|---|---|
| Unit | `Esr.Plugin.LoaderTest.register_startup` | Valid manifest stashes the `{plugin, module, function}` tuple. Missing `module:` raises. Missing `function:` raises. Unloaded module raises. |
| Unit | `Esr.Plugin.LoaderTest.run_startup` | Callbacks invoked in `enabled_plugins` order. A raising callback propagates (no rescue). |
| Integration | `Esr.Plugins.Feishu.BootstrapTest` | `bootstrap/1` with fixture `adapters.yaml` spawns the right FAA peers (test ported verbatim from existing `runtime/test/esr/scope_admin_bootstrap_feishu_test.exs`, just with the module path renamed). |
| Invariant | `Esr.Plugins.IsolationTest` (NEW) | Scoped grep — see "Invariant test scope" above. **Test fails today; passing is what "PR-3.4 done" means.** |
| Manifest validation | Phase F's existing test | Module + function from `startup:` are loadable/exported. Already covered by the `entities:` validator pattern. |

## Diff size estimate

- `runtime/lib/esr/plugins/feishu/manifest.yaml`: **+4 LOC** (`startup:` block)
- `runtime/lib/esr/plugins/feishu/bootstrap.ex` (new): **+80 LOC** (lifted verbatim)
- `runtime/lib/esr/plugin/loader.ex`: **+50 LOC** (`register_startup/1` + `run_startup/0`)
- `runtime/lib/esr/plugin/manifest.ex`: **+10 LOC** (parse `startup:` block, validate required fields)
- `runtime/lib/esr/scope/admin.ex`: **−45 LOC** (delete `bootstrap_feishu_app_adapters/0|1` + `spawn_feishu_app_adapter/3`)
- `runtime/lib/esr/application.ex`: **−2 LOC** (delete the call + comment)
- `runtime/lib/esr_web/cli_channel.ex`: **±0** (rename calls; same line count)
- `runtime/test/esr/plugin/loader_test.exs`: **+50 LOC** (new tests)
- `runtime/test/esr/scope_admin_bootstrap_feishu_test.exs`: **deleted** (−110 LOC); replaced by:
- `runtime/test/esr/plugins/feishu/bootstrap_test.exs` (new): **+110 LOC** (verbatim move with module path rename)
- `runtime/test/esr/plugins/isolation_test.exs` (new): **+40 LOC**

**Net: ~+200 LOC, ~−155 LOC = ~+45 LOC.** Smaller than rev 2's
~+220 because the shim+whitelist+default complexity is gone.

## Roll-back

Revertible: this PR's commits revert cleanly because no shim or
compat layer survives. If `run_startup/0` mis-orders or the
`:persistent_term` store doesn't behave as expected:

1. Revert the PR.
2. The deleted `bootstrap_feishu_app_adapters/0|1` and
   `spawn_feishu_app_adapter/3` come back.
3. The `_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()` line
   in `Esr.Application.start/2` comes back.
4. cli_channel.ex's calls revert to the Scope.Admin form.
5. The new feishu module + tests + Loader changes go away.

Phase D-1's "Loader is canonical for entity registration" claim is
unaffected — only the post-Loader bootstrap mechanism reverts.

## Resolved design questions

These were open in rev 1/2; rev 3 takes the let-it-crash position:

- **No default for `function:`**. Required field. Manifest typo
  → boot crash with clear error.
- **Startup failure raises**, doesn't `:warning`+continue.
- **No whitelist** in invariant test. Test scope is intentionally
  narrow (runtime boot directories only); cli_channel.ex is
  separate-architectural-concern, explicitly out of test scope.
- **No shim** in `Esr.Scope.Admin`. Function is deleted; callers
  migrate to the plugin module directly. Two callers in
  `cli_channel.ex` (3 LOC of edits) + the unit test (file moved
  + module path renamed).
