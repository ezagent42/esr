# PR-3.4 — Feishu Plugin Startup Hook

**Date:** 2026-05-05
**Status:** Rev 2 (subagent review applied; user review pending)
**Closes:** Phase 3 PR-3.4 (deferred from 2026-05-05 autonomous run);
North Star "feishu changes don't touch core" final gap.

**Rev 2 changes (subagent review):**

1. Line number in `application.ex` corrected from 280 → **278**.
2. **Three additional callers** of `bootstrap_feishu_app_adapters/0`
   surfaced — see "Additional call sites" below. The "just delete
   the function" plan needed reshaping into a thin core shim.
3. ETS owner for the startup-callbacks store specified — the
   Loader is module-functions-only with no GenServer, so we use
   `:persistent_term` with a stable key.
4. Plugin-isolation invariant test changed from "comment-stripping"
   (brittle — too many legitimate `lookup_by_feishu_id` /
   `feishu_id` schema references in core) to **pattern-based**:
   it targets two specific anti-patterns only.

## Goal

Move `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` (currently
defined in `runtime/lib/esr/scope/admin.ex` and called from
`runtime/lib/esr/application.ex:280`) into the feishu plugin so that:

1. **Adding a new feishu instance** to `adapters.yaml` does not
   require any change to core code.
2. **Removing the feishu plugin** (setting `enabled: []` in
   `plugins.yaml`) cleanly disables FAA peer spawning — no
   bootstrap-fallback runs.
3. **A future codex/gemini-cli plugin** with its own per-instance
   peer-spawn logic uses the same plugin-startup mechanism instead
   of inventing a parallel one.

## Non-goals

- Plugin shutdown hooks (mirror of startup). Defer until needed.
- Async startup callbacks. Synchronous is sufficient for current
  use cases (bootstrap is bounded by adapters.yaml row count).
- Inter-plugin dependency graph beyond `enable order`. Order today
  is a plain list in `plugins.yaml`; extend later if a plugin needs
  another plugin's state at startup.
- Reloadable plugins (enable feishu at runtime, runs startup; then
  disable, runs shutdown). Today plugin enable/disable is restart-
  required; this PR doesn't change that.
- Removing `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` itself.
  After this PR's startup hook calls into the new plugin module,
  the old `Scope.Admin` function is dead code; deletion is part of
  this PR's diff.

## Architecture

### Manifest schema gains a `startup:` field

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  entities: [...]
  python_sidecars: [...]
  startup:
    - module: Esr.Plugins.Feishu.Bootstrap
      function: bootstrap
```

Each entry names a 0-arity callable. `function:` defaults to
`bootstrap` when omitted (convention: every plugin's startup module
exports `bootstrap/0`).

### `Esr.Plugin.Loader` gains startup orchestration

Two new responsibilities:

1. **`register_startup/1`** — during `start_plugin/2`, parse the
   manifest's `startup:` entries and stash them in a new ETS table
   keyed by plugin name. Validation happens here:
   - `module:` resolves via `Code.ensure_loaded?/1` (Phase F's
     manifest validation test catches misconfigured manifests at
     `mix test`).
   - `function:` exists as `module.function/0` via
     `function_exported?/3`.
   - Failures emit a warning and skip the entry; do not crash boot.

2. **`run_startup/0`** — called by `Esr.Application.start/2` after
   ALL plugins have completed `start_plugin/2`. Iterates the ETS
   table in plugin-enable order and invokes each callback. Each
   callback's success/failure is logged; one plugin's startup
   failure does not block another's.

### Ordering inside `Esr.Application.start/2`

Current sequence (relevant lines only):

```elixir
# 226-240 — register core stateful peer + run plugin Loader
:ok = Esr.Entity.Agent.StatefulRegistry.register(Esr.Entity.PtyProcess)
load_enabled_plugins()
# 260-272 — restore yaml-on-disk state
load_workspaces_from_disk(...)
load_agents_from_disk()
restore_adapters_from_disk(...)
# 278 — feishu adapter bootstrap (THE LINE THIS PR MOVES)
_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()
```

New sequence:

```elixir
:ok = Esr.Entity.Agent.StatefulRegistry.register(Esr.Entity.PtyProcess)
load_enabled_plugins()
load_workspaces_from_disk(...)
load_agents_from_disk()
restore_adapters_from_disk(...)
# Plugin startup callbacks run AFTER yaml-on-disk state is restored.
# `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` reads adapters.yaml and
# spawns FAA peers — same body as the old function.
Esr.Plugin.Loader.run_startup()
```

The hook runs AFTER `restore_adapters_from_disk/1` because feishu's
bootstrap reads the just-loaded adapters table.

### `Esr.Plugins.Feishu.Bootstrap`

New module under `runtime/lib/esr/plugins/feishu/bootstrap.ex`.
Body is `bootstrap_feishu_app_adapters/0`'s code, with the
private `spawn_feishu_app_adapter/3` helper colocated. The module
follows the existing plugin-module convention (lives under
`runtime/lib/esr/plugins/feishu/`, no compile-time alias from
core).

### Additional call sites (rev 2 finding)

`bootstrap_feishu_app_adapters/1` (note the path-arg form too) is
called from **three production sites beyond `Esr.Application`**:

| File | Line | Caller | Purpose |
|---|---|---|---|
| `runtime/lib/esr_web/cli_channel.ex` | 319 | `cli:adapters/refresh` | Re-bootstrap after `esr adapter add` |
| `runtime/lib/esr_web/cli_channel.ex` | 408 | `cli:adapters/rename` | Re-spawn under new name |
| `runtime/test/esr/scope_admin_bootstrap_feishu_test.exs` | 64,90,93,103 | bootstrap-with-path test | Direct unit test of the function |

Plus `runtime/test/esr_web/cli_channel_test.exs:162` covers the
refresh dispatcher.

**Implication for the plan:** `Esr.Scope.Admin.bootstrap_feishu_app_adapters/1`
cannot be deleted as a one-liner cleanup — `cli_channel.ex`'s two
callers would break. The choices are:

- **(A) Migrate cli_channel callers to invoke
  `Esr.Plugins.Feishu.Bootstrap.bootstrap/1` directly.** Cleanest
  but bakes a plugin-module reference into a core file
  (`cli_channel.ex`). Defeats "no plugin names in core" (the
  plugin-isolation invariant test would fail).
- **(B) Leave a thin shim in `Esr.Scope.Admin` that delegates to
  `Esr.Plugins.Feishu.Bootstrap.bootstrap/1`.** Application boot
  still calls into the plugin (via Loader's startup-callback
  runner, NOT via the shim). The shim is for the channel
  callers only — they're cli-channel-specific transport, not
  generic app boot. The "feishu changes don't touch core" goal
  is functionally met (a new feishu manifest entry is enough),
  the shim is an explicit transition wrapper. Pragmatic.
- **(C) Move `cli:adapters/refresh` and `cli:adapters/rename`
  dispatch logic into a feishu-plugin-owned channel.** Bigger
  refactor; out of scope for PR-3.4 (would block on Phase 3.5
  HTTP MCP transport spec).

**Spec choice: (B).** Rationale:

- The plugin-isolation invariant test should target the **runtime
  boot path** (Application, Scope, Entity, Resource), not the
  cli-channel transport which is its own subsystem. Whitelist the
  `cli_channel.ex` shim call.
- The shim is one line per caller (`Esr.Plugins.Feishu.Bootstrap.bootstrap/1`);
  total 3 LOC of thin wrapping.
- Phase D-3 (or later) can do option (C) once HTTP MCP transport
  spec stabilizes — the cli_channel WS path may change shape
  anyway.

### `Esr.Scope.Admin` cleanup

After this PR:

- `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` and `/1`
  collapsed into a single thin shim:

  ```elixir
  @deprecated "Call Esr.Plugins.Feishu.Bootstrap.bootstrap/1 directly. Shim retained for cli_channel.ex callers; remove in Phase D-3."
  def bootstrap_feishu_app_adapters(adapters_yaml_path \\ nil) do
    Esr.Plugins.Feishu.Bootstrap.bootstrap(adapters_yaml_path)
  end
  ```

- `Esr.Scope.Admin.terminate_feishu_app_adapter/1` STAYS unchanged
  — used by `/end-session` cleanup logic, not by boot. Phase D-3
  separate concern.
- `Esr.Scope.Admin.spawn_feishu_app_adapter/3` (private helper)
  moves to `Esr.Plugins.Feishu.Bootstrap` (it's pure-feishu logic).

`Esr.Application.start/2` line **278** deleted (the call). The
shim is no longer invoked from app boot — only from cli_channel.

### Loader's startup-callback store

The Loader is module-functions-only — no GenServer, no ETS owner
process. **Use `:persistent_term`** with key
`{Esr.Plugin.Loader, :startup_callbacks}` storing a list of
`{plugin_name, module, function}` tuples in plugin-enable order.

```elixir
def register_startup(plugin_name, manifest) do
  entries = manifest |> Map.get("declares", %{}) |> Map.get("startup", [])
  cb_list = Enum.flat_map(entries, fn entry -> ... end)
  current = :persistent_term.get({__MODULE__, :startup_callbacks}, [])
  :persistent_term.put({__MODULE__, :startup_callbacks}, current ++ cb_list)
end

def run_startup do
  :persistent_term.get({__MODULE__, :startup_callbacks}, [])
  |> Enum.each(fn {plugin, mod, fun} -> ... end)
end
```

`:persistent_term` is appropriate here because:
- Write is rare (boot-time only, one write per plugin enable).
- Read is rare (one bulk read at end of boot).
- The "GC penalty on update" concern of `:persistent_term` doesn't
  apply when updates are at boot only.

## Failure modes

| When | Behaviour |
|---|---|
| Plugin manifest's startup `module:` doesn't load | Warning logged; that plugin's startup skipped; other plugins continue. |
| Startup callback raises | Logged with stacktrace; esrd boot continues degraded. Same as current `bootstrap_feishu_app_adapters/0` swallow-all. |
| Multiple plugins with startup hooks | Run sequentially in `enabled_plugins` order from `plugins.yaml`. No parallelism. |
| `adapters.yaml` malformed | Logged warning by `Esr.Plugins.Feishu.Bootstrap.bootstrap/0`; no FAA peers spawned. Same as current. |

## Test strategy

| Layer | Test | What it asserts |
|---|---|---|
| Unit | `Esr.Plugin.LoaderTest.register_startup` | Manifest's startup entry is stashed, retrievable. |
| Unit | `Esr.Plugin.LoaderTest.run_startup` | Callbacks run in `enabled_plugins` order; failures don't cascade. |
| Integration | `Esr.Plugins.Feishu.BootstrapTest` | bootstrap/0 with a fixture adapters.yaml spawns the right FAA peer. |
| **Invariant (new)** | `Esr.Plugins.IsolationTest` (NEW) | **Pattern-based** (rev 2): asserts (a) `Esr.Plugins.Feishu.*` is not referenced from `runtime/lib/esr/{application,scope,entity,resource,interface}/**/*.ex`, except in `cli_channel.ex` where the cli-channel transport shim is whitelisted; (b) `Esr.Scope.Admin.bootstrap_feishu_app_adapters` is called only from the shim (delegating to `Esr.Plugins.Feishu.Bootstrap.bootstrap/1`), nowhere else. The original "comment-stripping" approach was rejected as brittle — `lookup_by_feishu_id` / `feishu_id` schema field references in `entity/user/registry.ex`, `entity/cap_guard.ex`, etc. are deeper coupling that PR-3.4 explicitly doesn't address; pattern-based avoids that noise. **Test fails today; passing is what "PR-3.4 done" means.** |
| Manifest validation | Phase F's test (already shipping) | The new startup entry's module is loadable. |

The invariant test is the non-negotiable completion gate per the
2026-05-05 "completion claim requires invariant test" memory rule.
Without it, "PR-3.4 done" is just "PR merged + tests pass" again,
the same false-completion pattern that triggered this whole Phase
3/4 finish.

## Out of scope follow-ups

- **Plugin shutdown hooks** — once per-session cleanup needs
  per-plugin `shutdown/0` symmetry, mirror the startup mechanism
  with a `shutdown:` manifest field.
- **Topological ordering of startup hooks** — today plugin order
  is a plain list. If a plugin needs to wait for another's
  startup, add `depends_on_startup:` to manifest and topo-sort.
- **`terminate_feishu_app_adapter/1` move** — same plugin
  isolation argument, but used in a different code path
  (`/end-session`); separate PR (D-3 or later).

## Roll-back plan

If the startup-hook mechanism turns out to mis-order or mis-time,
the rollback is:

1. Restore the deleted `_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()`
   call in `Esr.Application.start/2`.
2. Restore the deleted `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0`
   function (re-import from `Esr.Plugins.Feishu.Bootstrap`).
3. Leave the manifest `startup:` entry in place — it's a no-op
   when `Esr.Plugin.Loader.run_startup/0` is also reverted.
4. The plugin Loader changes stay (they're additive — registering
   startup entries that nobody calls is harmless).

This is a reversible change. The "Loader is canonical" claim from
Phase D-1 is unaffected by rollback (only the post-Loader timing
of the feishu bootstrap shifts).

## Estimated diff size

- `runtime/lib/esr/plugins/feishu/manifest.yaml`: +5 LOC (`startup:` block)
- `runtime/lib/esr/plugins/feishu/bootstrap.ex` (new): ~80 LOC (verbatim copy)
- `runtime/lib/esr/plugin/loader.ex`: +60 LOC (`register_startup/1` + `run_startup/0`)
- `runtime/lib/esr/scope/admin.ex`: -45 LOC (delete `bootstrap_feishu_app_adapters/0` + `spawn_feishu_app_adapter/3`)
- `runtime/lib/esr/application.ex`: -2 LOC (delete the call + 1-line comment)
- `runtime/test/esr/plugin/loader_test.exs`: +50 LOC (new tests)
- `runtime/test/esr/plugins/feishu/bootstrap_test.exs` (new): ~80 LOC
- `runtime/test/esr/plugins/isolation_test.exs` (new — the invariant): ~40 LOC

**Net: ~270 LOC added, ~50 LOC deleted = ~+220 LOC.** Slightly larger
than typical because we're adding both infrastructure (plugin Loader
startup) and an invariant test.

## Open questions for user review

The four open questions from rev 1 were resolved in subagent review:

1. **`function:` defaults to `bootstrap`** — yes (convention-over-
   config matches existing Loader style).
2. **Startup-failure logs at `:error`** (was `:warning`) — operators
   tail at `:error+`; bootstrap miss = silent dropped frames is
   exactly the prod incident PR-K/L chased.
3. **Pattern-based isolation test, NOT comment-stripping** — see
   "Test strategy" invariant row above. Comment-stripping was
   rejected as brittle.
4. **Whitelist `Esr.Entity.FeishuAppAdapter` reference in
   `interface/boundary.ex`** — yes, but pair with TODO to rewrite
   that `@moduledoc` example after Phase D is done so the
   whitelist doesn't become permanent.

**Remaining for user (林懿伦) to confirm before plan stage:**

- The shim approach (option B in "Additional call sites" above) is
  the trade-off that keeps `cli_channel.ex` callers working without
  baking a plugin-module reference into the cli-channel transport
  layer. The plugin-isolation invariant test whitelists that one
  shim call. Does this pragmatic compromise sit right? Alternative
  is option C — relocate `cli:adapters/{refresh,rename}` dispatch
  into the feishu plugin too — but that's a larger Phase D-3 task.
- The `:persistent_term`-based startup-callbacks store is per-BEAM
  global. If we ever want runtime plugin disable to undo startup
  effects, we'd need a different store. Today plugin enable/disable
  requires restart anyway, so this isn't a concern for PR-3.4.
