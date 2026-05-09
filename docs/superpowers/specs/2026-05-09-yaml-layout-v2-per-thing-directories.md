# YAML layout v2 — per-thing directories

**Spec id:** 2026-05-09-yaml-layout-v2-per-thing-directories
**Author:** Allen Woods + Claude
**Status:** rev-1 (draft)
**Tracks:** follow-up to PR #287 + #283 — `app_secret` ownership disambiguation, generalized to a layout convention

## 1. Motivation

The current `$ESRD_HOME/<inst>/` layout mixes two storage idioms inconsistently:

```
~/.esrd/default/
├── adapters.yaml           # monolithic — all instances in one file
├── plugins.yaml            # monolithic — enabled list + plugin-wide config
├── users.yaml              # monolithic — user index
├── capabilities.yaml       # monolithic
├── slash-routes.yaml       # monolithic
├── users/<uuid>/...        # directory-per-user ✓
├── workspaces/<name>/...   # directory-per-workspace ✓
└── sessions/<name>/...     # directory-per-session ✓
```

The cluster of recent bugs around `app_secret` ownership (PR #283 added a `plugins.yaml → adapters.yaml` fallback; PR #287 fixed the manifest schema misclassification) is a symptom of conflating **two distinct concerns** in `plugins.yaml`:

1. *Which plugins are enabled* (registry-shaped state)
2. *How a plugin is configured* (plugin-internal state)

Per the project's stated architectural stance (services self-manage, runtime just registers), these belong in different files. Same logic applies to `adapters.yaml`: each instance is independent — there is no reason for all of them to share one file. Per-instance files give the same `mv-on-disable` and atomic-write properties that `users/`, `workspaces/`, `sessions/` already enjoy.

This spec aligns the plugin/adapter layout with the existing directory-per-thing convention.

## 2. Non-goals

- No change to the **data model** of plugin configs or adapter configs — only the on-disk layout.
- No change to `capabilities.yaml`, `users.yaml`, `slash-routes.yaml`, or any other monolithic file unrelated to plugins/adapters.
- No new configuration sources (no env, no remote, no merging of repository-bundled configs).
- **No migration tooling.** ESR is pre-launch — existing dev/prod state can be deleted and recreated. See § 5.

## 3. Target layout

### 3.1 Global layer (esrd home)

```
$ESRD_HOME/<inst>/
├── plugins.yaml                          # ONLY: enabled: [name1, name2]
├── plugins/
│   └── <plugin_name>/
│       └── config.yaml                   # plugin-wide config (global layer)
├── adapters/
│   ├── <instance_name>/
│   │   └── config.yaml                   # type + per-instance config
│   └── _disabled/
│       └── <instance_name>/
│           └── config.yaml               # paused — runtime ignores
└── users/, workspaces/, sessions/, capabilities.yaml, ...   # unchanged
```

### 3.2 User layer

```
$ESRD_HOME/<inst>/users/<uuid>/.esr/
└── plugins/
    └── <plugin_name>/
        └── config.yaml
```

### 3.3 Workspace layer

```
<workspace_root>/.esr/
└── plugins/
    └── <plugin_name>/
        └── config.yaml
```

### 3.4 File contract

`plugins.yaml` (global only):
```yaml
enabled:
  - feishu
  - claude_code
```
That is the **only** legal top-level key. Presence of `:config` or any other key → boot refuse.

`plugins/<name>/config.yaml` (any layer):
```yaml
log_level: info
# arbitrary plugin-defined keys here
```
Schema validation deferred to plugin manifest (`runtime/lib/esr/plugins/<name>/manifest.yaml :config_schema`).

`adapters/<name>/config.yaml`:
```yaml
type: feishu
config:
  app_id: cli_xxx
  app_secret: xxx
```
Top-level keys: `type` (required string), `config` (required map). Adapter `name` = directory basename.

### 3.5 Reserved names

The directory name `_disabled` is reserved under `adapters/`. `register_adapter` validation rejects any instance name starting with underscore. `_disabled` itself is created lazily by `Esr.Adapters.disable/1` — operators do not create it manually.

## 4. Module surface

### 4.1 `Esr.Plugin.Config` (existing module — internal change only)

3-layer merge order, **last-wins**: `global → user → workspace`. Workspace overrides user, user overrides global. (Aligns with VS Code / Git config conventions.)

```elixir
@spec get(plugin_name :: String.t(), key :: String.t(), opts :: keyword()) :: any() | nil
def get(name, key, opts \\ [])
# opts:
#   :global_path     (default: from Esr.Paths.plugin_global_dir/1)
#   :user_path       (default: nil — skip user layer if not provided)
#   :workspace_path  (default: nil — skip workspace layer if not provided)
#   :default         (default: nil — returned if all 3 layers miss)

@spec set(plugin_name :: String.t(), key :: String.t(), value :: any(), layer, opts) :: :ok
      when layer: :global | {:user, uuid :: String.t()} | {:workspace, root :: Path.t()}
def set(name, key, value, layer, opts \\ [])

@spec list_layers(plugin_name :: String.t(), opts :: keyword()) :: [{layer, Path.t() | nil}]
def list_layers(name, opts \\ [])  # debug aid: returns all 3 paths and which exist
```

Empty config dir (e.g., `plugins/feishu/` exists but no `config.yaml`) → that layer contributes nothing; merge falls through to next layer or default. Never an error.

### 4.2 `Esr.Plugin.PluginsYaml` (existing — slimmer)

Strip all `:config` handling. Keep only enabled-list operations:

```elixir
def list_enabled(opts \\ [])           # read enabled: [...]
def enable(name, opts \\ [])           # add to enabled list (atomic write)
def disable(name, opts \\ [])          # remove from enabled list
```

Reading a `plugins.yaml` that contains `:config` or any non-`enabled` top-level key → raise / refuse-to-boot (see § 5).

### 4.3 `Esr.Adapters` (new module)

```elixir
@type instance_name :: String.t()
@type adapter :: %{name: instance_name, type: String.t(), config: map()}

@spec list(opts :: keyword()) :: [adapter]
def list(opts \\ [])                   # scan adapters/*/config.yaml; ignore _disabled/

@spec list_disabled(opts :: keyword()) :: [adapter]
def list_disabled(opts \\ [])          # scan adapters/_disabled/*/config.yaml

@spec get(instance_name, opts) :: {:ok, adapter} | {:error, :not_found}
def get(name, opts \\ [])

@spec exists?(instance_name, opts) :: boolean
def exists?(name, opts \\ [])

@spec disabled?(instance_name, opts) :: boolean
def disabled?(name, opts \\ [])

@spec add(instance_name, type :: String.t(), config :: map(), opts) :: :ok | {:error, term}
def add(name, type, config, opts \\ [])
# - validates name (not "_disabled", no leading underscore, ASCII identifier)
# - mkdir adapters/<name>/
# - atomic write adapters/<name>/config.yaml

@spec remove(instance_name, opts) :: :ok | {:error, :not_found}
def remove(name, opts \\ [])           # rm -rf adapters/<name>

@spec disable(instance_name, opts) :: :ok | {:error, term}
def disable(name, opts \\ [])          # mv adapters/<name> adapters/_disabled/<name>

@spec enable(instance_name, opts) :: :ok | {:error, term}
def enable(name, opts \\ [])           # mv adapters/_disabled/<name> adapters/<name>
```

All writes go through `Esr.Yaml.Writer.write/2` (the canonical atomic writer used by `register_adapter.ex:112` and `workspaces.yaml`). Do not roll a custom tmp+rename — the shared writer already handles FSEvents-friendly atomic semantics on macOS (CLAUDE.md gotcha #2).

### 4.4 `Esr.Paths` (existing — additions)

```elixir
def plugin_global_dir(name),   do: Path.join([runtime_home(), "plugins", name])
def plugin_user_dir(name, uuid), do: Path.join([user_dir(uuid), ".esr", "plugins", name])
def plugin_workspace_dir(name, root), do: Path.join([root, ".esr", "plugins", name])

def adapters_dir,              do: Path.join(runtime_home(), "adapters")
def adapter_dir(name),         do: Path.join(adapters_dir(), name)
def adapter_disabled_dir,      do: Path.join(adapters_dir(), "_disabled")

# REMOVED in this spec:
def adapters_yaml              # was: $ESRD_HOME/<inst>/adapters.yaml — gone
# kept but slimmer:
def plugins_yaml               # still global enabled-list path, just no :config
```

### 4.5 Consumer-side changes

Files that currently read the old layout and need to switch to the new module surface:

| File | Current call | New call |
|---|---|---|
| `runtime/lib/esr/application.ex:417` | `Esr.Paths.adapters_yaml() + YamlElixir.read_from_file` | `Esr.Adapters.list/0` |
| `runtime/lib/esr/commands/register_adapter.ex:76,95` | `adapters_path = Esr.Paths.adapters_yaml()` then `defp append_instance_to_yaml/4` | `Esr.Adapters.add/3` |
| `runtime/lib/esr/plugins/feishu/bootstrap.ex:48,52` | `def bootstrap(adapters_yaml_path)` reading via `YamlElixir.read_from_file` | `Esr.Adapters.list/1` (with opts for tests) |
| `runtime/lib/esr/plugin/config.ex` (current 3-layer reader) | reads `plugins.yaml :config` per layer | reads `plugins/<name>/config.yaml` per layer |

### 4.6 Alignment with unified-command-grammar (PRs #294 → #307)

`Esr.Adapters` is a **library** module (plain functions returning `{:ok, ...} | {:error, atom_reason}`). User-facing operations are exposed through **command modules** that wrap it, and those command modules MUST follow the conventions established by the 2026-05-09 unified-command-grammar migration ([`docs/superpowers/specs/2026-05-09-unified-command-grammar-and-errors.md`](2026-05-09-unified-command-grammar-and-errors.md)):

- `use Esr.Commands.Meta` and a `command :name do … end` declaration block (declares `slash`, `category`, `description`, `permission`, `arg`, `error` codes)
- Errors returned via `Render.error(__MODULE__.command_meta(), :code, %{detail: ...})`
- No hand-editing of `runtime/priv/slash-routes.default.yaml` — that file is **derived state**, regenerated from `command_meta/0` via the project's grammar generator (introduced by PR #304)
- CI gate `mix esr.check_command_docs` enforces that yaml + module declarations stay in sync

New command modules in this spec's scope:

| Module | Slash | Wraps |
|---|---|---|
| `Esr.Commands.Adapter.Disable` | `/adapter:disable name=<n>` | `Esr.Adapters.disable/1` |
| `Esr.Commands.Adapter.Enable`  | `/adapter:enable name=<n>`  | `Esr.Adapters.enable/1`  |
| `Esr.Commands.Adapter.Remove`  | `/adapter:remove name=<n>`  | `Esr.Adapters.remove/1`  |
| `Esr.Commands.Adapter.List`    | `/adapter:list`             | `Esr.Adapters.list/0` + `list_disabled/0` |

Existing `Esr.Commands.RegisterAdapter` (already DSL-converted) needs only its internal `append_instance_to_yaml/4` body replaced with `Esr.Adapters.add/3` — its DSL `command` block stays unchanged.

### 4.7 Cleanup A subsumed

The previously-planned standalone "Cleanup A" PR (drop `app_secret` plugins.yaml fallback) is **fully subsumed** by this spec. Specifically:

- `application.ex:438-486` `defp ensure_app_secret("feishu", config)` — deleted (the fallback path becomes structurally impossible: there is no `plugins.yaml :config` to fall back to)
- `application.ex:424` call site — the `type == "feishu" && missing app_secret` row is **skipped fail-loud** (Logger.error + continue without `spawn_fn`), as Cleanup A specified
- `runtime/test/esr/application_restore_adapters_test.exs` — fallback test replaced with fail-loud + skip-spawn assertion

Do not open a separate Cleanup A PR. The implementation PR for this spec carries the cleanup.

## 5. Compatibility check on boot

No migration script. ESR is pre-launch; operators delete old state and let runtime recreate. **But** silently ignoring stale files would mask user error — boot should fail loud with a one-line cleanup instruction.

In `Esr.Application.start/2`, before any other init:

```elixir
defp check_legacy_layout!(esrd_home) do
  legacy = []
  legacy = if File.exists?(Path.join(esrd_home, "adapters.yaml")),
              do: ["#{esrd_home}/adapters.yaml" | legacy], else: legacy
  legacy = if has_config_key?(Path.join(esrd_home, "plugins.yaml")),
              do: ["#{esrd_home}/plugins.yaml (contains :config — must be enabled-only)" | legacy], else: legacy

  unless legacy == [] do
    Logger.error("""
    Pre-v2 yaml layout detected:
      #{Enum.join(legacy, "\n  ")}

    ESR is pre-launch and provides no migration. Delete the legacy files:
      rm #{esrd_home}/adapters.yaml
      # then edit #{esrd_home}/plugins.yaml to keep only `enabled: [...]`
    Then re-run `./esr.sh adapter add ...` for each adapter you need.
    """)
    System.halt(1)
  end
end
```

Same check on user/workspace `plugins.yaml` is **not** required — those layers were rarely written and any stragglers are silently ignored by the new reader (no `:config` key → no contribution → fall through to global).

## 6. Test plan

### 6.1 Unit (Elixir, ExUnit)

- `Esr.Adapters` round-trip: `add/3` → `list/0` returns it → `disable/1` → `list/0` excludes, `list_disabled/0` includes → `enable/1` → `list/0` includes again → `remove/1` → `get/1` returns `:not_found`
- `Esr.Adapters.add/3` rejects names: `"_disabled"`, `"_anything"`, `""`, `"with/slash"`, non-ASCII
- `Esr.Adapters.list/0` ignores files at `adapters/<name>/config.yaml.bak`, hidden files, and `adapters/_disabled/`
- `Esr.Plugin.Config.get/3` 3-layer merge order verified with all 8 combinations (each layer present/absent)
- `Esr.Plugin.Config.get/3` returns default when all 3 layers miss
- Empty `plugins/<name>/` directory → that layer contributes nothing (no error)
- `Esr.Application.check_legacy_layout!/1` halts on stale `adapters.yaml`; halts on `plugins.yaml` with `:config` key; passes on clean state

### 6.2 E2E (bash scenario)

New scenario: `tests/e2e/scenarios/<NN>_yaml_layout_v2.sh`
- Start with empty `$ESRD_HOME` test instance
- `./esr.sh adapter add --type=feishu --name=app_a --app_id=… --app_secret=…`
- Assert `<inst>/adapters/app_a/config.yaml` exists with correct shape
- `./esr.sh adapter disable app_a`
- Assert `<inst>/adapters/_disabled/app_a/config.yaml` exists; original gone
- `./esr.sh adapter enable app_a`
- Assert reverse
- esrd boot: confirm `Esr.Adapters.list/0` picks up app_a; confirm `app_b` (also disabled) does not spawn

### 6.3 Compatibility check test

- Place a stale `adapters.yaml` in test esrd home → start runtime → assert `System.halt(1)` was called (or use `application:start/2` return value if testable)
- Place `plugins.yaml` with `enabled: [...]` AND `config: ...` → assert halt

## 7. Rollout

**Single PR.** No staging. No backward compatibility shim.

Scope:
1. Add `Esr.Adapters` library module + new `Esr.Paths` helpers
2. Rewrite `Esr.Plugin.Config` and `Esr.Plugin.PluginsYaml` to per-directory layout
3. Switch all consumers (table in § 4.5)
4. Delete `Esr.Paths.adapters_yaml/0` and any code referencing it (CI catches)
5. Add `check_legacy_layout!/1` to application boot
6. Update `register_adapter` validation (reserved names: reject `_*`)
7. Add new command modules `Esr.Commands.Adapter.{Disable,Enable,Remove,List}` per § 4.6 (DSL form, structured errors)
8. Regenerate `runtime/priv/slash-routes.default.yaml` via the grammar generator (do NOT hand-edit) — adds `/adapter:disable`, `/adapter:enable`, `/adapter:remove`, `/adapter:list` entries derived from command_meta
9. Tests per § 6
10. Update operator docs: `README.md` "E2E test scenarios" + `docs/dev-guide.md` "esrd home layout" section + `docs/guides/writing-an-agent-topology.md` if it references `adapters.yaml`
11. CI: `mix esr.check_command_docs` must pass on the new modules

If a regression appears post-merge: revert the PR; operators delete `adapters/`, `plugins/` directories and recreate via CLI. No data loss because there is no production data to lose.

## 8. Open questions / future

- **Plugin local state** (cache, sqlite, etc.) — this spec creates the `plugins/<name>/` directory, but only specifies `config.yaml` as the inhabitant. A future spec can add conventions for `plugins/<name>/state/` or `plugins/<name>/cache/` without touching this spec.
- **Schema validation timing** — currently plugin `config_schema` is consulted only on write via `/plugin:set` slash. Whether `Esr.Plugin.Config.get/3` should validate-on-read is left for a separate spec.
- **`adapters/_disabled/` GC** — disabled adapters accumulate. Whether to prune (and when) is left for ops policy, not this spec.
