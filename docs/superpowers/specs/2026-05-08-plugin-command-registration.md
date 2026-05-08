# Plugin-Scoped Command Registration

**Spec id:** 2026-05-08-plugin-command-registration  
**Author:** Allen Woods + Claude  
**Status:** rev-1 (draft, awaiting user review)  
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
- **Zero behavior change for existing core slashes.** This spec adds plugin extensibility; it does not move core slashes around in this PR.

## 3. Non-goals

- **No** physical migration of `/user:bind-feishu` → `/feishu:bind` in this PR. The `bind_feishu` command stays where it is; the spec only ensures the *mechanism* is in place so a follow-up PR can move it cleanly.
- **No** dynamic / runtime command registration (e.g., a plugin emitting commands at boot via code). Declaration only — same as `capabilities:` today.
- **No** dispatching changes. `Esr.Entity.SlashHandler.dispatch/3` and the queue-watcher path stay byte-for-byte identical.

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

### 5.5 Migration path for `/user:bind-feishu` → `/feishu:bind` (out of scope, but unblocked)

After this PR, a follow-up can:

1. Add `Esr.Plugins.Feishu.Commands.Bind` (re-exports the same logic, or moves it bodily from `Esr.Commands.User.BindFeishu`).
2. Add the `slash_routes:` block to `runtime/lib/esr/plugins/feishu/manifest.yaml`.
3. Delete `/user:bind-feishu` from `slash-routes.default.yaml`.
4. Delete `runtime/lib/esr/commands/user/bind_feishu.ex`.
5. Bind data still persists under the user's user-default workspace folder (`<user_default_ws_root>/bindings/feishu.json`) — this is compatible with the session-first spec just shipped, since user-default is now a hard-guaranteed concept.

That follow-up touches no core registration code — only moves files. Exactly the desired property.

## 6. Decision log

- **D1.** Plugin commands are declarative-yaml only. No code-side `slash_hook` callback. *Rationale:* matches `capabilities:` pattern; yaml is statically inspectable for `/help` / docs / completion; a code hook would be opaque and harder to disable.
- **D2.** Collision is a hard error, not a silent override or a precedence rule. *Rationale:* lets two plugins claim `/feishu:bind` is undefined behavior — surface it loudly at startup.
- **D3.** Per-plugin namespace prefix is mandatory, not advisory. *Rationale:* the user explicitly named "ad-hoc additions causing user understanding difficulty" as the problem to solve. A plugin that can register `/user:foo` is still ad-hoc.
- **D4.** No physical command migration in this PR. *Rationale:* keep PR scope tight; #5's session-first work is already substantial. The mechanism is the deliverable here.
- **D5.** `cross-plugin caps` are forbidden in declared `permission:` values. *Rationale:* if `feishu` references `claude_code/spawn` it has hidden coupling on `claude_code`'s presence — caught at register time gives the authoring plugin a clear error.
- **D6.** Overlay map lives in the SlashRoute.Registry GenServer state, not in ETS or persistent_term. *Rationale:* consistent with how the existing snapshot lives behind a single GenServer call; rebuilds are cheap (the merged ETS is the only hot path, and it's rebuilt on every change anyway today).

## 7. Implementation surface (for the plan)

Estimate: ~150 LOC + ~250 LOC test.

| File | Change |
|------|--------|
| `runtime/lib/esr/plugin/manifest.ex` | Add `slash_routes` to `@allowed_declares`; add `validate_slash_routes/2`; export `slash_route_snapshot/1` |
| `runtime/lib/esr/plugin/loader.ex` | Add `register_slash_routes/2` to the `with`-chain |
| `runtime/lib/esr/resource/slash_route/registry.ex` | Add `register_overlay/2` + `unregister_overlay/1`; refactor state to base + overlays + merged view; add merge fn with collision detection |
| `runtime/lib/esr/resource/slash_route/file_loader.ex` | Existing `parse_slash_routes/1` reused for both base and overlay; no schema split |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | Add an empty `slash_routes:` block (no slashes yet — sanity gate that the validator passes a no-op manifest) |
| `runtime/test/esr/plugin/manifest_test.exs` | Cases: valid block, wrong-prefix rejection, cross-plugin cap reference rejection, unknown command_module rejection |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | Cases: overlay register, overlay unregister, slash collision detection, kind collision detection, base-file event preserves overlay |

## 8. Test plan (red→green)

1. **Unit** — `Manifest.validate/1` rejects a `slash_routes` block whose slash key prefix doesn't match the plugin name.
2. **Unit** — `Manifest.validate/1` rejects a kind that doesn't start with `<plugin_name>_`.
3. **Unit** — `Manifest.validate/1` rejects a `permission:` not declared in the same plugin's `capabilities:`.
4. **Unit** — `SlashRoute.Registry.register_overlay/2` returns `{:error, {:slash_collision, key, owner}}` on duplicate slash key.
5. **Unit** — `SlashRoute.Registry.register_overlay/2` returns `{:error, {:kind_collision, kind, owner}}` on duplicate kind.
6. **Unit** — Core-file event (touch `slash-routes.default.yaml`) keeps registered overlays alive.
7. **Integration** — Loader starts the feishu plugin with a `slash_routes` block, the slash is dispatchable end-to-end via `SlashHandler.dispatch/3`.
8. **Integration** — `Loader.stop_plugin/1` (still TODO today) calls `unregister_overlay`; the overlay's slashes are gone afterward.

## 9. Invariants

- **I1.** No two distinct registrations (base + overlays) ever share a slash key in the merged ETS table. Violation = registry refuses to install.
- **I2.** Every slash key in the merged ETS is prefixed with either a known core group (`/user:`, `/workspace:`, `/session:`, `/plugin:`, `/cap:`, `/help`) or a registered plugin's name (`/<plugin>:`). No exceptions.
- **I3.** Every kind in the merged ETS is prefixed by a core group or `<plugin>_`. (Same as I2 in the kind world.)
- **I4.** Plugin-declared `permission:` values are a subset of that plugin's declared `capabilities:`. Cross-plugin references not permitted at this layer.

## 10. Open questions for review

- **Q1.** Should a plugin be allowed to declare `internal_kinds:` (admin-CLI only, no slash)? Spec assumes yes (mirrors core), but it widens the surface area. *Recommend: yes.*
- **Q2.** What's the right error surface when a plugin's overlay collides with core? Today, plugin start fails — but does the daemon refuse to start, or does it skip just that plugin? *Recommend: skip the offending plugin, log a structured error, daemon stays up. Matches how a config_schema mismatch is handled today.*
- **Q3.** Migrate `/user:bind-feishu` to `/feishu:bind` in this PR or follow-up? *Recommend: follow-up, to keep this PR focused on the mechanism.*

## 11. Appendix — relationship to the session-first spec (#5)

The session-first spec just shipped guarantees every user has a `<username>-default` workspace at all times. This spec leans on that guarantee in the migration discussion (§5.5): plugin bind-data persists under `user_default_workspace_root/bindings/<plugin>.json`. With user-default as a hard invariant, that path is always well-defined — no fallback / null check / "no workspace" branch needed.

The two specs are independent on the *mechanism* axis (this spec doesn't require any session-first code), but together they form the foundation a plugin author needs to ship a self-contained plugin: command registration (this spec) + persistent per-user storage (session-first spec).
