# PR-3.4 — Feishu Plugin Startup Hook

**Date:** 2026-05-05
**Status:** Draft (subagent review pending; user review pending)
**Closes:** Phase 3 PR-3.4 (deferred from 2026-05-05 autonomous run);
North Star "feishu changes don't touch core" final gap.

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
# 280 — feishu adapter bootstrap (THE LINE THIS PR MOVES)
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

### `Esr.Scope.Admin` cleanup

After this PR:

- `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` deleted.
- `Esr.Scope.Admin.terminate_feishu_app_adapter/1` STAYS — it's
  used by `/end-session` cleanup logic, not by boot. Renaming /
  relocating this is a separate concern (could be Phase D-3).
- `Esr.Scope.Admin.spawn_feishu_app_adapter/3` (private helper)
  moves to `Esr.Plugins.Feishu.Bootstrap` along with the public
  function.

`Esr.Application.start/2` line 280 deleted. Comment block
274-279 trimmed to point operators at the new plugin location.

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
| **Invariant (new)** | `Esr.Plugins.IsolationTest` (NEW) | grep `runtime/lib/esr/{application,scope,entity,resource}.ex*` for `feishu`/`Feishu` — must be empty (or whitelist the few comment references that make sense). **This is the test that fails today; passing it is what "PR-3.4 done" means.** |
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

1. **Should `function:` default to `bootstrap`** when manifest
   omits it? (Spec assumes yes.)
2. **Should startup-failure logs be at `:warning` (current behavior)
   or `:error`** (more visible to operators tailing the log)?
3. **Should the plugin-isolation invariant test allow `Feishu` /
   `feishu` in COMMENTS** (currently 145+ matches in core, mostly
   docs) or only in code? Spec proposes "code only" via comment-
   stripping regex. Could become brittle.
4. **Do we want `Esr.Plugins.IsolationTest` to whitelist
   `Esr.Entity.FeishuAppProxy`** (still referenced in
   `interface/boundary.ex` example)? Or delete those references
   too? (Probably whitelist for now; eliminate when boundary
   spec is rewritten.)
