# Plugin-Scoped Command Registration

**Spec id:** 2026-05-08-plugin-command-registration  
**Author:** Allen Woods + Claude  
**Status:** rev-2 (D4 reversed: physical migration of 3 commands now in scope)  
**Tracks:** post-multi-instance audit task #6  
**Related:** 2026-05-08-session-first-default-resolution.md (companion)

## 1. Problem statement

Today every new slash or admin-CLI command requires editing **core** files:

1. `runtime/priv/slash-routes.default.yaml` — add the route
2. `runtime/lib/esr/commands/<group>/<verb>.ex` — write the command module
3. `runtime/lib/esr/resource/permission/bootstrap.ex` — declare the capability (if new)
4. `runtime/lib/esr/entity/slash_handler.ex` — add an envelope-merge clause if the command needs chat context (most don't)
5. tests under `runtime/test/esr/commands/...`

That is fine for **core** commands (the handful built into ESR proper). It is unsustainable for **plugin** commands. Today's plugins (`feishu`, `claude_code`, …) cannot ship a slash without sending a PR against core. As more plugins land, the result will be:

- Core slash-routes.yaml grows unbounded with plugin-specific entries.
- Operators cannot tell which slashes belong to which subsystem.
- A plugin author cannot disable / reload / version their own commands.
- The colon namespace (`/<group>:<verb>`) is occupied ad-hoc — `/feishu:bind` and `/user:bind-feishu` collide on the same concept because nothing prevented either name from being used.

## 2. Goals

- **Single canonical entry point** for plugin authors to register commands. No core-file edits.
- **Namespace discipline**: a plugin named `feishu` may only register slashes under `/feishu:*` (or admin kinds prefixed `feishu_`). Enforced at manifest validation time, not after the slash is in production.
- **Symmetric with existing `capabilities:` / `python_sidecars:` declarations** in `Esr.Plugin.Manifest` — same pattern, same place, same lifecycle.
- **Prove the mechanism by migrating real plugin-owned commands** in this PR. Audit (§5.6) found 3 such commands today: `bind_feishu`, `unbind_feishu`, and `notify`. They move to the feishu plugin in this PR; future plugins inherit the cleared path.
- **Zero behavior change for the operator-visible kind names.** `kind: notify`, `kind: user_bind_feishu`, `kind: user_unbind_feishu` stay stable so the escript queue + any external caller continues to dispatch unchanged. Only `command_module:` flips.

## 3. Non-goals

- **No** dynamic / runtime command registration (e.g., a plugin emitting commands at boot via code). Declaration only — same as `capabilities:` today.
- **No** dispatching changes. `Esr.Entity.SlashHandler.dispatch/3` and the queue-watcher path stay byte-for-byte identical.
- **No** migration of `Workspace.BindChat` / `UnbindChat`. Audit found these are channel-agnostic (the `chats[]` data model takes any future Slack/Telegram tuple), so they correctly belong in core. Permission `workspace.create` is already core-namespaced.

## 4. Current registration mechanism (audit summary)

ESR's slash dispatch is **yaml-driven, single-source-of-truth**. Two ETS tables (`:esr_slash_routes`, `:esr_slash_kinds`) are populated from one yaml file (`runtime/priv/slash-routes.default.yaml`) by `Esr.Resource.SlashRoute.FileLoader`, replaced atomically on every file event by `Esr.Resource.SlashRoute.Registry.load_snapshot/1`.

Both `/<slash>` and `esr admin submit <kind>` paths look up via the same registry. There is **no separate router or dispatch table** — the yaml *is* the router.

The Plugin.Loader (`runtime/lib/esr/plugin/loader.ex:178-196`) already supports four declaration types:

```elixir
:ok <- register_capabilities(name, manifest),
:ok <- register_python_sidecars(manifest),
:ok <- register_entities(manifest),
:ok <- register_startup(name, manifest)
```

The Loader's docstring explicitly anticipates this spec:

> "Phase-1 supports `python_sidecars` + `capabilities`; remaining declaration types (**slash_routes**, agent_defs, entities, http_routes, …) arrive when the corresponding registries grow `register/3`-style APIs in subsequent tasks."

A yaml-fragment merger stub already exists (`runtime/lib/esr/yaml/fragment_merger.ex`) for the "base + per-plugin overlays" pattern.

## 5. Design

### 5.1 Manifest schema extension

A plugin's `manifest.yaml` grows a single new `declares.slash_routes:` block. The schema is the **same** as `slash-routes.default.yaml`, scoped to that plugin:

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  capabilities:
    - feishu/manage
    - feishu/bind

  slash_routes:
    schema_version: 1
    slashes:
      "/feishu:bind":
        kind: feishu_bind
        permission: feishu/bind
        command_module: Esr.Plugins.Feishu.Commands.Bind
        requires_workspace_binding: false
        requires_user_binding: false
        category: feishu
        description: "Bind a Feishu identity (ou_xxx) to an ESR user"
        args:
          - name: name
            required: true
          - name: feishu_id
            required: true
    internal_kinds:
      feishu_bind:
        permission: feishu/bind
        command_module: Esr.Plugins.Feishu.Commands.Bind
```

**Hard constraints enforced by `Manifest.validate/1`:**

- Every key in `slashes:` must match `^/<plugin_name>:` (e.g. `/feishu:*` for the `feishu` plugin). Reject otherwise.
- Every `kind:` value (in both `slashes:` and `internal_kinds:`) must start with `<plugin_name>_`. Reject otherwise.
- Every `permission:` referenced must be one of the caps the plugin also declares in `capabilities:`. Cross-plugin caps are not allowed in this spec.
- Every `command_module:` must be loadable via `Code.ensure_loaded?/1` AND its module name must start with `Esr.Plugins.<PluginCamel>.`.

### 5.2 Plugin.Loader integration

Add a fifth registration step:

```elixir
# runtime/lib/esr/plugin/loader.ex (start_plugin/2 with-chain)
:ok <- register_capabilities(name, manifest),
:ok <- register_python_sidecars(manifest),
:ok <- register_entities(manifest),
:ok <- register_slash_routes(name, manifest),    # NEW
:ok <- register_startup(name, manifest) do
```

`register_slash_routes/2` calls a new `Esr.Resource.SlashRoute.Registry.register_overlay/2`, passing the plugin name and the parsed snapshot.

### 5.3 Registry overlay model

`Esr.Resource.SlashRoute.Registry` grows:

```elixir
@spec register_overlay(plugin_name :: String.t(), snapshot :: map()) :: :ok
@spec unregister_overlay(plugin_name :: String.t()) :: :ok
```

State refactor: instead of one ETS-replacement on every file event, keep:

- `@base_table` — populated from `slash-routes.default.yaml` only (file watcher path).
- `@overlay_state :: %{plugin_name => snapshot}` — a per-plugin map kept in the GenServer state.
- `@slash_table` / `@kind_table` — the **merged** view, rebuilt from base + overlays whenever either changes.

Merge rule: **collision on a slash key or kind name is a hard error** (same rule as `Yaml.FragmentMerger`). The plugin's `register_overlay` returns `{:error, {:slash_collision, key, owner}}` and the plugin fails to start. This is the right behavior — silent override would let any plugin hijack `/user:add`.

A core-file watcher event rebuilds the base; overlays survive. A plugin reload re-registers its own overlay; others are untouched.

### 5.4 Namespace enforcement points

Belt-and-suspenders:

- **At manifest validate time** (`Esr.Plugin.Manifest.validate_slash_routes/2`) — reject before the plugin even attempts to start. This is the user-facing error a plugin author hits during development.
- **At registry register time** (`SlashRoute.Registry.register_overlay/2`) — reject again if the snapshot somehow gets through with a bad prefix. This catches the case where a plugin manifest is hand-edited at runtime or a future code path bypasses validate.

### 5.5 Physical migration of plugin-owned commands (in this PR)

The audit found exactly **3 commands** in core today that meet the plugin-ownership criteria (directly references plugin runtime, would be meaningless without the plugin, permission already in plugin namespace):

| Command | Current module | Plugin | New module |
|---|---|---|---|
| `kind: user_bind_feishu` (CLI-only) | `Esr.Commands.User.BindFeishu` (105 LOC) | feishu | `Esr.Plugins.Feishu.Commands.BindUser` |
| `kind: user_unbind_feishu` (CLI-only) | `Esr.Commands.User.UnbindFeishu` (70 LOC) | feishu | `Esr.Plugins.Feishu.Commands.UnbindUser` |
| `kind: notify` (CLI-only) | `Esr.Commands.Notify` (79 LOC) | feishu | `Esr.Plugins.Feishu.Commands.Notify` |

**Migration scope (per audit):**
- 3 source files moved (~254 LOC, verbatim move).
- 1 test file moved (`notify_test.exs`, 235 LOC).
- 1 test fixture cleanup: `runtime/test/esr/resource/slash_route/registry_test.exs` uses `Esr.Commands.Notify` as a placeholder sentinel module across ~30 lines — replace with a generic `Esr.Test.NoopCommand` (mechanical sed; ~50 LOC).
- 0 hard blockers identified.
- 1 doc-comment fix: `runtime/lib/esr/scope/admin/process.ex:32`.

**Stability contracts kept by the migration:**
- `kind:` names stay the same (`user_bind_feishu`, `user_unbind_feishu`, `notify`). Only `command_module:` flips. Escript queue + admin dispatcher continue to dispatch unchanged.
- `permission:` strings stay where they are unless we explicitly rename them as part of this migration. Recommend: keep `notify.send` as-is (plugin namespace already), but rename `user.manage` → `feishu/user-bind` for the bind/unbind commands so the `permission:` field matches the new `<plugin>/<rest>` pattern. Will require a small follow-up cap-rename note in the audit doc, but is a clean improvement.

**Workspace.BindChat / UnbindChat are explicitly NOT migrated.** Audit determined the `chats[]` data model on a workspace is channel-agnostic (future Slack/Telegram plugins will share it). They correctly belong in core; permission `workspace.create` is core-namespaced; no migration needed.

**Why move them now (not in a follow-up):**

- Cost is ~675 LOC mostly mechanical. Marginal effort over the mechanism-only scope is roughly 10–15%.
- The mechanism's correctness is harder to evaluate without a real consumer. Migrating real commands stress-tests the validator (does `feishu/user-bind` get accepted? does the `<plugin>_` kind prefix really catch typos?), the loader (does it survive plugin reload?), and the registry's collision detection (does removing the core entry from yaml + adding the overlay produce zero collision warnings?).
- A "mechanism + zero use" PR ships an untested abstraction. A "mechanism + 3 real consumers" PR ships a validated abstraction.

User-bind data persists under `<user_default_workspace_root>/bindings/feishu.json` — compatible with the session-first spec just shipped (§5 of that spec made user-default a hard invariant, so this path is always well-defined).

## 6. Decision log

- **D1.** Plugin commands are declarative-yaml only. No code-side `slash_hook` callback. *Rationale:* matches `capabilities:` pattern; yaml is statically inspectable for `/help` / docs / completion; a code hook would be opaque and harder to disable.
- **D2.** Collision is a hard error, not a silent override or a precedence rule. *Rationale:* lets two plugins claim `/feishu:bind` is undefined behavior — surface it loudly at startup.
- **D3.** Per-plugin namespace prefix is mandatory, not advisory. *Rationale:* the user explicitly named "ad-hoc additions causing user understanding difficulty" as the problem to solve. A plugin that can register `/user:foo` is still ad-hoc.
- **D4.** Migrate exactly 3 plugin-owned commands (`bind_feishu`, `unbind_feishu`, `notify`) to the feishu plugin in this PR. *Rationale:* audit (§5.5) found ~675 LOC of mostly mechanical work with zero hard blockers. Shipping a mechanism without a real consumer ships an untested abstraction; the migration validates the validator + loader + registry overlay end-to-end. `kind:` names stay stable so external dispatchers (escript queue, admin) see no surface change.
- **D5.** `cross-plugin caps` are forbidden in declared `permission:` values. *Rationale:* if `feishu` references `claude_code/spawn` it has hidden coupling on `claude_code`'s presence — caught at register time gives the authoring plugin a clear error.
- **D6.** Overlay map lives in the SlashRoute.Registry GenServer state, not in ETS or persistent_term. *Rationale:* consistent with how the existing snapshot lives behind a single GenServer call; rebuilds are cheap (the merged ETS is the only hot path, and it's rebuilt on every change anyway today).

## 7. Implementation surface (for the plan)

Total estimate: **~825 LOC + ~500 LOC test** = ~1325 LOC. Two distinct phases.

### 7a. Mechanism (~150 LOC + ~250 LOC test)

| File | Change |
|------|--------|
| `runtime/lib/esr/plugin/manifest.ex` | Add `slash_routes` to `@allowed_declares`; add `validate_slash_routes/2`; export `slash_route_snapshot/1` |
| `runtime/lib/esr/plugin/loader.ex` | Add `register_slash_routes/2` to the `with`-chain; `unregister_overlay/1` from `stop_plugin/1` |
| `runtime/lib/esr/resource/slash_route/registry.ex` | Add `register_overlay/2` + `unregister_overlay/1`; refactor state to base + overlays + merged view; add merge fn with collision detection |
| `runtime/lib/esr/resource/slash_route/file_loader.ex` | Existing `parse_slash_routes/1` reused for both base and overlay; no schema split |
| `runtime/test/esr/plugin/manifest_test.exs` | Cases: valid block, wrong-prefix rejection, cross-plugin cap reference rejection, unknown command_module rejection |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | Cases: overlay register, overlay unregister, slash collision detection, kind collision detection, base-file event preserves overlay |

### 7b. Migration (~675 LOC, mostly file moves)

| File | Change |
|------|--------|
| Move: `runtime/lib/esr/commands/user/bind_feishu.ex` → `runtime/lib/esr/plugins/feishu/commands/bind_user.ex` | Rename module to `Esr.Plugins.Feishu.Commands.BindUser`; logic verbatim |
| Move: `runtime/lib/esr/commands/user/unbind_feishu.ex` → `runtime/lib/esr/plugins/feishu/commands/unbind_user.ex` | Rename module to `Esr.Plugins.Feishu.Commands.UnbindUser`; logic verbatim |
| Move: `runtime/lib/esr/commands/notify.ex` → `runtime/lib/esr/plugins/feishu/commands/notify.ex` | Rename module to `Esr.Plugins.Feishu.Commands.Notify`; logic verbatim |
| Move: `runtime/test/esr/commands/notify_test.exs` → `runtime/test/esr/plugins/feishu/commands/notify_test.exs` | Update module name in tests |
| Modify: `runtime/priv/slash-routes.default.yaml` | Delete the 3 `internal_kinds:` entries (`user_bind_feishu`, `user_unbind_feishu`, `notify`) — they migrate to feishu manifest |
| Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml` | Add `slash_routes:` block with the 3 migrated kinds; reference new module names |
| Modify: `runtime/lib/esr/resource/permission/bootstrap.ex` | Rename `user.manage` related caps used by bind/unbind: introduce `feishu/user-bind` cap |
| Fix: `runtime/lib/esr/scope/admin/process.ex:32` | Doc-comment update referencing notify location |
| Fix: `runtime/test/esr/resource/slash_route/registry_test.exs` | ~30 sentinel lines using `Esr.Commands.Notify` → switch to a generic `Esr.Test.NoopCommand` test fixture |
| Add: `runtime/test/esr/test/noop_command.ex` (or similar) | Generic test-only command module so the registry tests don't depend on a real command's existence |

## 8. Test plan (red→green)

1. **Unit** — `Manifest.validate/1` rejects a `slash_routes` block whose slash key prefix doesn't match the plugin name.
2. **Unit** — `Manifest.validate/1` rejects a kind that doesn't start with `<plugin_name>_`.
3. **Unit** — `Manifest.validate/1` rejects a `permission:` not declared in the same plugin's `capabilities:`.
4. **Unit** — `SlashRoute.Registry.register_overlay/2` returns `{:error, {:slash_collision, key, owner}}` on duplicate slash key.
5. **Unit** — `SlashRoute.Registry.register_overlay/2` returns `{:error, {:kind_collision, kind, owner}}` on duplicate kind.
6. **Unit** — Core-file event (touch `slash-routes.default.yaml`) keeps registered overlays alive.
7. **Integration** — Loader starts the feishu plugin with a `slash_routes` block, the slash is dispatchable end-to-end via `SlashHandler.dispatch/3`.
8. **Integration** — `Loader.stop_plugin/1` (still TODO today) calls `unregister_overlay`; the overlay's slashes are gone afterward.
9. **Migration regression** — `kind: notify` still resolves through `Esr.Resource.SlashRoute.Registry.command_module_for/1` after migration (now to `Esr.Plugins.Feishu.Commands.Notify` instead of `Esr.Commands.Notify`); existing `notify_test.exs` cases continue to pass against the moved module.
10. **Migration regression** — `kind: user_bind_feishu` admin-CLI dispatch path resolves to `Esr.Plugins.Feishu.Commands.BindUser`; the user-binding YAML write produces the same on-disk shape as before (single-field structural equality on `users.yaml` after add).

## 9. Invariants

- **I1.** No two distinct registrations (base + overlays) ever share a slash key in the merged ETS table. Violation = registry refuses to install.
- **I2.** Every slash key in the merged ETS is prefixed with either a known core group (`/user:`, `/workspace:`, `/session:`, `/plugin:`, `/cap:`, `/help`) or a registered plugin's name (`/<plugin>:`). No exceptions.
- **I3.** Every kind in the merged ETS is prefixed by a core group or `<plugin>_`. (Same as I2 in the kind world.)
- **I4.** Plugin-declared `permission:` values are a subset of that plugin's declared `capabilities:`. Cross-plugin references not permitted at this layer.

## 10. Open questions for review

- **Q1.** Should a plugin be allowed to declare `internal_kinds:` (admin-CLI only, no slash)? Spec assumes yes (mirrors core), but it widens the surface area. *Recommend: yes.*
- **Q2.** What's the right error surface when a plugin's overlay collides with core? Today, plugin start fails — but does the daemon refuse to start, or does it skip just that plugin? *Recommend: skip the offending plugin, log a structured error, daemon stays up. Matches how a config_schema mismatch is handled today.*
- **Q3.** **Resolved (rev-2)** — migrate `bind_feishu` + `unbind_feishu` + `notify` in this PR. See §5.5 and D4.

## 11. Appendix — relationship to the session-first spec (#5)

The session-first spec just shipped guarantees every user has a `<username>-default` workspace at all times. This spec leans on that guarantee in the migration discussion (§5.5): the migrated `bind_feishu` command persists user→feishu mappings under `<user_default_workspace_root>/bindings/feishu.json`. With user-default as a hard invariant, that path is always well-defined — no fallback / null check / "no workspace" branch needed.

The two specs are independent on the *mechanism* axis (this spec doesn't require any session-first code), but together they form the foundation a plugin author needs to ship a self-contained plugin: command registration (this spec) + persistent per-user storage (session-first spec).
