# YAML layout v2 — per-thing directories

**Spec id:** 2026-05-09-yaml-layout-v2-per-thing-directories
**Author:** Allen Woods + Claude
**Status:** rev-2 (draft — legacy gate dropped per user feedback)
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
- **No migration tooling.** ESR is pre-launch — existing dev/prod state can be deleted and recreated.
- **No backward-compat shim.** No boot-time legacy detection, no auto-migration, no v1 read fallback. After this PR, `Esr.Adapters.list/0` simply returns empty if no `adapters/*/` exists; operators notice and re-register. Old `adapters.yaml` files on disk are silently ignored (the readers don't know about that path anymore).

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
That is the **only** legal top-level key. Presence of `:config` or any other key → reader raises (per § 4.2).

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

`Esr.Adapters.list/0` skips any directory under `adapters/` whose name starts with `_`. `_disabled/` is the canonical use; the prefix rule covers any future reserved name (`_trash`, `_experimental`) and any operator-created folder they want runtime to ignore. `register_adapter` validation rejects any user-supplied name starting with `_`.

## 4. Module surface

### 4.1 `Esr.Plugin.Config` (existing module — internal change, **API names unchanged**)

3-layer merge order, **last-wins**: `global → user → workspace`. Workspace overrides user, user overrides global.

The existing public API stays — only internal path resolution changes from `<layer>/plugins.yaml :config[name]` to `<layer>/plugins/<name>/config.yaml`. Existing callers (`commands/plugin/{set,unset,show_config,list_config}.ex`, `plugin/{config_snapshot,loader}.ex`) keep working without code changes.

Existing API (kept verbatim): `get/3`, `resolve/2`, `store_layer/4`, `delete_layer/3`.

Empty config dir → that layer contributes nothing; never an error.

**Malformed yaml** at any layer **raises** (not silent fall-through). Broken `config.yaml` is operator error worth surfacing immediately.

### 4.2 `Esr.Plugin.PluginsYaml` (already enabled-only — small addition)

dev's `Esr.Plugin.PluginsYaml` is already enabled-only (`read/0`, `enable/1`, `disable/1`; no `:config` handling). Only addition: reading a `plugins.yaml` that contains `:config` or any non-`enabled` top-level key **raises** at read time. No boot gate.

### 4.3 `Esr.Adapters` (new module)

```elixir
@type instance_name :: String.t()
@type adapter :: %{name: instance_name, type: String.t(), config: map()}

@spec list(opts :: keyword()) :: [adapter]
def list(opts \\ [])                   # scan adapters/*/config.yaml; ignore any entry whose
                                       # name starts with `_` (covers _disabled and any other
                                       # reserved/manual prefix)

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
# - validates name (no leading underscore, ASCII identifier)
# - mkdir adapters/<name>/
# - atomic write adapters/<name>/config.yaml

@spec remove(instance_name, opts) :: :ok | {:error, :not_found}
def remove(name, opts \\ [])           # rm -rf adapters/<name>

@spec disable(instance_name, opts) :: :ok | {:error, term}
def disable(name, opts \\ [])          # mv adapters/<name> adapters/_disabled/<name>

@spec enable(instance_name, opts) :: :ok | {:error, term}
def enable(name, opts \\ [])           # mv adapters/_disabled/<name> adapters/<name>

@spec rename(old_name, new_name, opts) :: :ok | {:error, term}
def rename(old_name, new_name, opts \\ [])  # mv adapters/<old> adapters/<new>; new_name validated
```

`opts` accepts `:home` (test override for `Esr.Paths.runtime_home/0`).

**Atomicity (rev-3 correction)**: `Esr.Yaml.Writer.write/2` is **NOT atomic** — it's plain `File.write` (overwrite-in-place). The atomic tmp+rename pattern lives in `Esr.Plugin.PluginsYaml` and `Esr.Plugin.Config.update_layer_file`. For `Esr.Adapters`:
- `add/3` (writes new `config.yaml`): use tmp+rename. Either inline (mirroring `PluginsYaml`) OR extract a new `Esr.Yaml.Writer.write_atomic/2` helper. **Preferred: extraction** (canonical home, future re-use).
- `disable/1` and `enable/1`: POSIX `rename(2)` on same fs is OS-atomic. No extra work.
- `remove/1` (`rm -rf`): atomicity not relevant.

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

Review pass #1 expanded this from 4 → 11 rows.

**Adapter storage callers** (all touched by `Esr.Paths.adapters_yaml/0` deletion):

| File | Current call | New call |
|---|---|---|
| `runtime/lib/esr/application.ex:417` | `Esr.Paths.adapters_yaml() + YamlElixir.read_from_file` | `Esr.Adapters.list/0` |
| `runtime/lib/esr/commands/register_adapter.ex:76,95` | `adapters_path = Esr.Paths.adapters_yaml()` then `defp append_instance_to_yaml/4` | `Esr.Adapters.add/3` |
| `runtime/lib/esr/commands/adapter/remove.ex:41,54` | inline yaml read/write | `Esr.Adapters.remove/1` |
| `runtime/lib/esr/commands/adapter/rename.ex:66,91` | inline yaml read/write | `Esr.Adapters.rename/2` |
| `runtime/lib/esr/commands/adapters/list.ex:50` | `Esr.Paths.adapters_yaml()` (file also moves to `adapter/list.ex`) | `Esr.Adapters.list/0` + `list_disabled/0` |
| `runtime/lib/esr/plugins/feishu/bootstrap.ex:48,52` | `def bootstrap(adapters_yaml_path)` reading via `YamlElixir.read_from_file` | `Esr.Adapters.list/1` (`:home` opt for tests) |

**Plugin-config storage callers** (per-directory layout):

| File | Current call | New call |
|---|---|---|
| `runtime/lib/esr/plugin/config.ex` (3-layer reader, internal) | reads `plugins.yaml :config` per layer | reads `plugins/<name>/config.yaml` per layer; **public API names unchanged** |
| `runtime/lib/esr/commands/plugin/show_config.ex:54` | `Esr.Paths.global_plugins_yaml/0` | `Esr.Paths.plugin_global_dir/1` |
| `runtime/lib/esr/commands/plugin/set.ex:113` | `Esr.Paths.global_plugins_yaml/0` (calls `store_layer/4`) | `Esr.Paths.plugin_global_dir/1` (call signature unchanged — internal only) |
| `runtime/lib/esr/commands/plugin/unset.ex:86` | `Esr.Paths.global_plugins_yaml/0` (calls `delete_layer/3`) | `Esr.Paths.plugin_global_dir/1` |
| `runtime/lib/esr/commands/plugin/list_config.ex:27` | `Esr.Paths.global_plugins_yaml/0` | `Esr.Paths.plugin_global_dir/1` |

**Internal callers — no change required** (`resolve/2` API stays):
- `runtime/lib/esr/plugin/config_snapshot.ex:86` — `Esr.Plugin.Config.resolve/2`. No code change.
- `runtime/lib/esr/plugin/loader.ex:192` — same. No code change.

### 4.6 Alignment with unified-command-grammar (PRs #294 → #307)

`Esr.Adapters` is a **library** module (plain functions returning `{:ok, ...} | {:error, atom_reason}`). User-facing operations are exposed through **command modules** that wrap it, and those command modules MUST follow the conventions established by the 2026-05-09 unified-command-grammar migration ([`docs/superpowers/specs/2026-05-09-unified-command-grammar-and-errors.md`](2026-05-09-unified-command-grammar-and-errors.md)):

- `use Esr.Commands.Meta` and a `command :name do … end` declaration block (declares `slash`, `category`, `description`, `permission`, `arg`, `error` codes)
- Errors returned via `Render.error(__MODULE__.command_meta(), :code, %{detail: ...})`
- No hand-editing of `runtime/priv/slash-routes.default.yaml` — that file is **derived state**, regenerated from `command_meta/0` via the project's grammar generator (introduced by PR #304)
- CI gate `mix esr.check_command_docs` enforces that yaml + module declarations stay in sync

Command modules in scope (review pass #1 surfaced existing modules — corrected):

| Module | Status | Slash | Wraps |
|---|---|---|---|
| `Esr.Commands.Adapter.Disable` | **NEW** | `/adapter:disable name=<n>` | `Esr.Adapters.disable/1` |
| `Esr.Commands.Adapter.Enable`  | **NEW** | `/adapter:enable name=<n>`  | `Esr.Adapters.enable/1`  |
| `Esr.Commands.Adapter.Remove`  | **REFACTOR** (existing) | `/adapter:remove name=<n>` | `Esr.Adapters.remove/1` (replaces inline yaml r/w) |
| `Esr.Commands.Adapter.Rename`  | **REFACTOR** (existing) | `/adapter:rename old=<a> new=<b>` (existing) | `Esr.Adapters.rename/2` (replaces inline yaml r/w) |
| `Esr.Commands.Adapter.List`    | **MOVE+REFACTOR** (`commands/adapters/list.ex` → `commands/adapter/list.ex`) | `/adapter:list` | `Esr.Adapters.list/0` + `list_disabled/0` |
| `Esr.Commands.Adapter.Refresh` | NO CHANGE (does not touch yaml) | unchanged | unchanged |
| `Esr.Commands.Adapter.Start`   | NO CHANGE (does not touch yaml) | unchanged | unchanged |

**Namespace cleanup**: dev currently has `commands/adapter/` (singular: remove, rename, refresh, start) AND `commands/adapters/` (plural: list). This spec collapses to **singular `adapter/`** by moving `adapters/list.ex` → `adapter/list.ex`. Plural directory is removed.

Existing `Esr.Commands.RegisterAdapter` (already DSL-converted) needs only its internal `append_instance_to_yaml/4` body replaced with `Esr.Adapters.add/3` — its DSL `command` block stays unchanged, including `slash :none`.

**Slash discipline** (informal principle for this PR's modules; future amendment to unified-grammar spec may codify it):

> By default, command modules expose **both slash and CLI** — concrete value: discoverability inside chat. The DSL's `slash :none` is reserved for commands whose `arg` set carries credentials or other secrets that should not appear in chat history (`register_adapter` is the canonical example: `app_secret`). The 4 new commands in this spec carry no secrets, so all four expose `slash` + CLI. Note: in current usage `register_adapter` is invoked from admin DM where leak risk is low, but the DSL discipline still favors CLI-only for credential-bearing args.

### 4.7 Cleanup A subsumed

The previously-planned standalone "Cleanup A" PR (drop `app_secret` plugins.yaml fallback) is **fully subsumed** by this spec. Specifically:

- `application.ex:438-486` `defp ensure_app_secret("feishu", config)` — deleted (the fallback path becomes structurally impossible: there is no `plugins.yaml :config` to fall back to)
- `application.ex:424` call site — the `type == "feishu" && missing app_secret` row is **skipped fail-loud** (Logger.error + continue without `spawn_fn`), as Cleanup A specified
- `runtime/test/esr/application_restore_adapters_test.exs` — fallback test replaced with fail-loud + skip-spawn assertion

Do not open a separate Cleanup A PR. The implementation PR for this spec carries the cleanup.

## 5. Test plan

### 5.1 Unit (Elixir, ExUnit)

- `Esr.Adapters` round-trip: `add/3` → `list/0` returns it → `disable/1` → `list/0` excludes, `list_disabled/0` includes → `enable/1` → `list/0` includes again → `remove/1` → `get/1` returns `:not_found`
- `Esr.Adapters.add/3` rejects names: `"_disabled"`, `"_anything"`, `""`, `"with/slash"`, non-ASCII
- `Esr.Adapters.list/0` ignores files at `adapters/<name>/config.yaml.bak`, hidden files, and any directory whose name starts with `_`
- `Esr.Plugin.Config.get/3` 3-layer merge order verified with all 8 combinations (each layer present/absent)
- `Esr.Plugin.Config.get/3` returns default when all 3 layers miss
- Empty `plugins/<name>/` directory → that layer contributes nothing (no error)
- Malformed `plugins/<name>/config.yaml` → `Esr.Plugin.Config.get/3` raises (caller-visible, not silent skip)
- Malformed `plugins.yaml` (e.g., contains `:config`) → `Esr.Plugin.PluginsYaml.list_enabled/0` raises

### 5.2 E2E (bash scenario)

New scenario: `tests/e2e/scenarios/<NN>_yaml_layout_v2.sh`
- Start with empty `$ESRD_HOME` test instance
- `./esr.sh adapter add --type=feishu --name=app_a --app_id=… --app_secret=…`
- Assert `<inst>/adapters/app_a/config.yaml` exists with correct shape
- `./esr.sh adapter disable app_a`
- Assert `<inst>/adapters/_disabled/app_a/config.yaml` exists; original gone
- `./esr.sh adapter enable app_a`
- Assert reverse
- esrd boot: confirm `Esr.Adapters.list/0` picks up app_a; confirm `app_b` (also disabled) does not spawn

## 6. Rollout

**Single PR.** No staging. No backward compatibility shim.

Scope:
1. Add `Esr.Adapters` library module + new `Esr.Paths` helpers
2. Rewrite `Esr.Plugin.Config` and `Esr.Plugin.PluginsYaml` to per-directory layout
3. Switch all consumers (table in § 4.5)
4. Delete `Esr.Paths.adapters_yaml/0` and any code referencing it (CI catches)
5. Update `register_adapter` validation (reserved names: reject `_*`)
6. Add new command modules `Esr.Commands.Adapter.{Disable,Enable,Remove,List}` per § 4.6 (DSL form, structured errors)
7. Regenerate `runtime/priv/slash-routes.default.yaml` via the grammar generator (do NOT hand-edit) — adds `/adapter:disable`, `/adapter:enable`, `/adapter:remove`, `/adapter:list` entries derived from command_meta
8. Tests per § 5
9. Update operator docs: `README.md` "E2E test scenarios" + `docs/dev-guide.md` "esrd home layout" section + `docs/guides/writing-an-agent-topology.md` if it references `adapters.yaml`
10. CI: `mix esr.check_command_docs` must pass on the new modules

If a regression appears post-merge: revert the PR; operators delete `adapters/`, `plugins/` directories and recreate via CLI. No data loss because there is no production data to lose.

## 7. Open questions / future

- **Plugin local state** (cache, sqlite, etc.) — this spec creates the `plugins/<name>/` directory, but only specifies `config.yaml` as the inhabitant. A future spec can add conventions for `plugins/<name>/state/` or `plugins/<name>/cache/` without touching this spec.
- **Schema validation timing** — currently plugin `config_schema` is consulted only on write via `/plugin:set` slash. Whether `Esr.Plugin.Config.get/3` should validate-on-read is left for a separate spec.
- **`adapters/_disabled/` GC** — disabled adapters accumulate. Whether to prune (and when) is left for ops policy, not this spec.
- **Slash discipline codification** — § 4.6's "default slash + CLI; opt-out via `slash :none` for credential-bearing args" rule deserves a small amendment to the unified-command-grammar spec. Deferred to a separate PR.
- **`Esr.Yaml.Writer` atomic-write upgrade** — current `write/2` is plain `File.write` (overwrite). § 4.3's `Esr.Adapters.add/3` either does inline tmp+rename or extracts `Esr.Yaml.Writer.write_atomic/2` (preferred). Promoting *all* yaml writes to atomic is a separate hygiene PR — not blocked on this spec.
