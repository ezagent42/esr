# Spec: Operator-Set Per-Plugin Config

**Date:** 2026-05-07
**Branch:** `spec/plugin-set-config`
**Status:** draft — awaiting operator approval before PR

> **Companion file:** Chinese version lives at
> [`2026-05-07-plugin-set-config.zh_cn.md`](2026-05-07-plugin-set-config.zh_cn.md).

---

## §1 — Scope & Motivation

The 2026-05-06 bootstrap-flow audit (`docs/manual-checks/2026-05-06-bootstrap-flow-audit.md`)
surfaced two structural gaps. **Step 6** found that no `/plugin … set config` verb exists —
the manifest's `required_env:` declares what env vars are needed at compile-time but exposes
no operator-writable surface at runtime. **Cross-cutting #2** confirmed the gap is
intentional debt: the TODO "agent (cc) startup config first-class" anticipated it but no
spec was ever filed. Today's only mechanism for per-plugin tuning is a gitignored bash
fragment (`scripts/esr-cc.local.sh`) that is sourced before `exec claude`. This works for
one operator on one machine; it does not compose across user accounts, repositories, or
future plugin authors who have no shell-script entry-point.

The user locked the following decisions on 2026-05-06 (referenced throughout as "locked"):

1. Extend `plugins.yaml` with an optional `config:` map (no new file at the global layer).
2. Each plugin's `manifest.yaml` gains a `config_schema:` block declaring every legal key.
3. Slash commands use colon-namespace form (`/plugin:set`, `/plugin:unset`, `/plugin:show`)
   matching the audit's task 3 recommendation.
4. Restart-required reload semantics. Hot-reload is Phase 2 (out of scope here).
5. Plugin code reads config via `Esr.Plugin.Config.get(plugin_name, key)`, ETS-backed.
6. Three config layers resolved at session-create time: global / user / project
   (precedence: project > user > global, per-key merge).
7. `scripts/esr-cc.sh` and `scripts/esr-cc.local.sh` are deleted once the migration ships.
8. `tests/e2e/scenarios/common.sh` and dependent scenarios are updated to use plugin config.

**Out of scope:** hot-reload (Phase 2); per-environment overrides beyond the three layers
above; plugin-to-plugin config sharing; fetching config from external secret stores (e.g.
Vault).

---

## §2 — Storage Layout

### 2.1 Global layer — `$ESRD_HOME/<inst>/plugins.yaml`

The existing file gains an optional `config:` map at the top level:

```yaml
# $ESRD_HOME/<inst>/plugins.yaml
enabled:
  - feishu
  - claude_code
config:
  claude_code:
    http_proxy: "http://proxy.local:8080"
    https_proxy: "http://proxy.local:8080"
    no_proxy: "localhost,127.0.0.1,::1,.feishu.cn,.larksuite.com"
    anthropic_api_key_ref: "${ANTHROPIC_API_KEY}"
    esrd_url: "ws://127.0.0.1:4001"
  feishu:
    log_level: "info"
```

`PluginsYaml.read_explicit/0` is extended to also read `config:` (keyed by plugin name).
`PluginsYaml.write/2` receives both the enabled list and the config map so they are
serialised atomically to a temp file then renamed (existing atomicity guarantee preserved).

Backward compatibility: a file with only `enabled:` and no `config:` key is valid; the
config map defaults to `%{}`.

### 2.2 User layer — `$ESRD_HOME/<inst>/users/<username>/plugins.config.yaml`

New file, one per user per instance. Path rationale: mirrors the existing per-user data
directory that `Esr.Users.Registry` already owns under `$ESRD_HOME/<inst>/users/`.
The file is gitignored by adding `**/.esrd/` to `.gitignore` (or the operator's
`$ESRD_HOME` is already outside the repo). This replaces the function that
`scripts/esr-cc.local.sh` currently serves for per-operator overrides.

```yaml
# $ESRD_HOME/<inst>/users/linyilun/plugins.config.yaml
config:
  claude_code:
    anthropic_api_key_ref: "${USER_ANTHROPIC_KEY}"
```

No `enabled:` key; this file is config-only. An absent file is equivalent to `config: {}`.

### 2.3 Project layer — `<repo>/.esr/plugins.config.yaml`

New file, one per repository. Present only when the current workspace is **repo-bound**
(i.e., has a non-empty `root:` field in `workspaces.yaml`). Operators commit this file to
the repo to share project-scoped config (e.g. proxy bypass for a specific network
environment) with teammates. Secrets must not go in this file — use `anthropic_api_key_ref`
with an env-var reference instead of a literal value.

```yaml
# <repo>/.esr/plugins.config.yaml
config:
  claude_code:
    http_proxy: ""            # repo wants direct connection (overrides global)
    project_specific_setting: "some_value"
```

The `.esr/` directory at repo root is added to `.gitignore` only if the operator wants to
keep it local; otherwise the file is intentionally tracked.

### 2.4 Manifest `config_schema:` — shape

Each plugin's `manifest.yaml` gains a `config_schema:` map. Every key a plugin reads must
be declared here. An operator-supplied key absent from the schema is rejected at write time
with an explicit error.

```yaml
# runtime/lib/esr/plugins/claude_code/manifest.yaml  (proposed addition)
config_schema:
  http_proxy:
    type: string
    description: "HTTP proxy URL for outbound Anthropic API requests. Empty string = no proxy."
    default: ""
    sensitive: false

  https_proxy:
    type: string
    description: "HTTPS proxy URL. Usually same as http_proxy."
    default: ""
    sensitive: false

  no_proxy:
    type: string
    description: "Comma-separated hosts / suffixes that bypass the proxy."
    default: ""
    sensitive: false

  anthropic_api_key_ref:
    type: string
    description: |
      Env-var reference for the Anthropic API key, e.g. "${ANTHROPIC_API_KEY}".
      The plugin resolves the value at session-start via System.get_env/1.
      The literal key must never be placed in this field directly.
    default: "${ANTHROPIC_API_KEY}"
    sensitive: true   # /plugin:show masks the resolved value by default

  esrd_url:
    type: string
    description: "WebSocket URL of the esrd host. Controls the HTTP MCP endpoint. Default: ws://127.0.0.1:4001."
    default: "ws://127.0.0.1:4001"
    sensitive: false
```

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml  (proposed addition)
config_schema:
  log_level:
    type: string
    description: "Log verbosity for feishu adapter (debug|info|warning|error)."
    default: "info"
    sensitive: false
```

**Type system (Phase 1):** Only `string` and `boolean` are recognised. Integer / list
support is deferred to Phase 2 (not needed for the current migration targets).

**Validation rules:**
- `type:` is required; unknown type → reject manifest parse.
- `description:` is required (forces plugin authors to document every key).
- `default:` is required; may be empty string `""`. The default is used when the key
  is absent from all three config layers.
- `sensitive: true` → `/plugin:show` renders the value as `***` unless the caller
  holds `plugin/show-secrets` capability and passes `--show-secrets`.

---

## §3 — Resolution Algorithm

Resolution happens at **session-create time** (inside `Esr.Commands.Session.New` or the
equivalent session-bootstrap call). The resolved map is stored in the session's ETS row
under key `{:plugin_config, plugin_name}` and is readable at any later point via
`Esr.Plugin.Config.get/2`.

### 3.1 Module `Esr.Plugin.Config`

```elixir
defmodule Esr.Plugin.Config do
  @moduledoc """
  3-layer plugin config resolution: global / user / project.

  Resolved at session-create time; stored in ETS keyed by
  {session_id, plugin_name}. Readable at any point via get/2.

  Precedence: project > user > global (per-key merge).
  A key present in an upper layer always wins over the same key in a
  lower layer, including empty-string values. An *absent* key (the
  layer's map does not have the key at all) does NOT win — it falls
  through to the next layer. This avoids the ambiguity: project layer
  setting http_proxy="" intentionally clears the proxy; project layer
  simply not setting http_proxy inherits from global.
  """

  @doc """
  Resolve the effective config for `plugin_name` given session context.

  opts:
    username:     String.t() | nil  — required to read user layer
    workspace_id: String.t() | nil  — required to read project layer

  Returns a map of String key → String value, with schema defaults
  applied for any key absent from all three layers.
  """
  @spec resolve(plugin_name :: String.t(), opts :: keyword()) :: map()
  def resolve(plugin_name, opts \\ []) do
    username     = opts[:username]
    workspace_id = opts[:workspace_id]

    schema   = load_schema(plugin_name)
    defaults = schema_defaults(schema)

    global       = read_global(plugin_name)
    user_layer   = if username,     do: read_user(plugin_name, username),     else: %{}
    project_layer = if workspace_id, do: read_project(plugin_name, workspace_id), else: %{}

    # Per-key merge: lower layers first; each higher layer wins on
    # explicit presence (Map.merge/2 semantics: right-side wins).
    defaults
    |> Map.merge(global)
    |> Map.merge(user_layer)
    |> Map.merge(project_layer)
  end

  @doc """
  Read effective config for plugin_name from the session-scoped ETS cache.
  Returns the value or the schema default when the key is absent.
  """
  @spec get(plugin_name :: String.t(), key :: String.t()) :: String.t() | nil
  def get(plugin_name, key) do
    session_id = Esr.Session.current_id()
    case :ets.lookup(:plugin_config_cache, {session_id, plugin_name, key}) do
      [{_, value}] -> value
      [] -> schema_default(plugin_name, key)
    end
  end

  @doc """
  Populate the ETS cache for this session. Called by session-create
  after resolve/2.
  """
  @spec store(session_id :: String.t(), plugin_name :: String.t(), config :: map()) :: :ok
  def store(session_id, plugin_name, config) do
    Enum.each(config, fn {k, v} ->
      :ets.insert(:plugin_config_cache, {{session_id, plugin_name, k}, v})
    end)
    :ok
  end

  @doc """
  Invalidate cached entries for a plugin after /plugin:set writes new values.
  Called by the Set command after persisting to disk.
  """
  @spec invalidate(plugin_name :: String.t()) :: :ok
  def invalidate(plugin_name) do
    # Match-delete all entries for this plugin across all sessions.
    :ets.match_delete(:plugin_config_cache, {{:_, plugin_name, :_}, :_})
    :ok
  end

  # --- private readers ------------------------------------------------

  defp read_global(plugin_name) do
    case File.read(Esr.Paths.plugins_yaml()) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"config" => config}} when is_map(config) ->
            Map.get(config, plugin_name, %{})
          _ -> %{}
        end
      _ -> %{}
    end
  end

  defp read_user(plugin_name, username) do
    path = Path.join([Esr.Paths.instance_dir(), "users", username, "plugins.config.yaml"])
    read_config_yaml(path, plugin_name)
  end

  defp read_project(plugin_name, workspace_id) do
    with {:ok, root} <- Esr.Resource.WorkspaceRegistry.root_for(workspace_id),
         path = Path.join([root, ".esr", "plugins.config.yaml"]),
         {:ok, _} <- File.stat(path) do
      read_config_yaml(path, plugin_name)
    else
      _ -> %{}
    end
  end

  defp read_config_yaml(path, plugin_name) do
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"config" => config}} when is_map(config) ->
            Map.get(config, plugin_name, %{})
          _ -> %{}
        end
      _ -> %{}
    end
  end

  defp load_schema(plugin_name) do
    case Esr.Plugin.Loader.manifest_for(plugin_name) do
      {:ok, manifest} -> Map.get(manifest.declares, :config_schema, %{})
      _ -> %{}
    end
  end

  defp schema_defaults(schema) do
    for {key, spec} <- schema,
        is_map(spec),
        Map.has_key?(spec, "default"),
        into: %{} do
      {key, spec["default"]}
    end
  end

  defp schema_default(plugin_name, key) do
    schema = load_schema(plugin_name)
    get_in(schema, [key, "default"])
  end
end
```

### 3.2 Session-create integration

In `Esr.Commands.Session.New.execute/1`:

```elixir
# After workspace lookup, before spawning PtyProcess:
enabled_plugins = Application.get_env(:esr, :enabled_plugins, [])

Enum.each(enabled_plugins, fn plugin_name ->
  config = Esr.Plugin.Config.resolve(plugin_name,
    username: cmd["submitter"],
    workspace_id: workspace.id
  )
  Esr.Plugin.Config.store(session_id, plugin_name, config)
end)
```

### 3.3 Merge semantics — empty-string vs absent

| Layer provides key | Value | Effect |
|---|---|---|
| Present | `"http://proxy.local:8080"` | Wins; proxy is set |
| Present | `""` | Wins; proxy is explicitly cleared (direct connection) |
| Absent | — | Falls through to lower layer or schema default |

An operator who wants to "unset" a global proxy for their project sets `http_proxy: ""`
in the project layer. An operator who simply has no opinion on the proxy does not include
the key at all, and the global value propagates.

---

## §4 — Slash Commands (colon-namespace)

All four commands use `plugin:` namespace per audit task 3. They are added to
`runtime/priv/slash-routes.default.yaml`.

### 4.1 Command table

| Slash | Args | Default layer | Behaviour |
|---|---|---|---|
| `/plugin:set <plugin> key=value [layer=global\|user\|project]` | `plugin`, `key`, `value`, optional `layer` | `global` | Validate key against manifest `config_schema:`; atomic write; print restart hint; invalidate ETS cache. |
| `/plugin:unset <plugin> key [layer=global\|user\|project]` | `plugin`, `key`, optional `layer` | `global` | Delete key from named layer; idempotent (no error if absent); atomic write; invalidate ETS cache. |
| `/plugin:show <plugin> [layer=effective\|global\|user\|project]` | `plugin`, optional `layer` | `effective` (merged) | Render all keys. Sensitive values shown as `***` unless caller holds `plugin/show-secrets` cap and passes `--show-secrets`. |
| `/plugin:list-config` | — | — | Show effective config for every enabled plugin; sensitive values masked. |

### 4.2 slash-routes.default.yaml entries

```yaml
"/plugin:set":
  kind: plugin_set_config
  permission: "plugin/manage"
  command_module: "Esr.Commands.Plugin.SetConfig"
  requires_workspace_binding: false
  requires_user_binding: false
  category: "Plugins"
  description: "Set a per-plugin config key (restart required to apply)"
  args:
    - { name: plugin,  required: true  }
    - { name: key,     required: true  }
    - { name: value,   required: true  }
    - { name: layer,   required: false }   # default: global

"/plugin:unset":
  kind: plugin_unset_config
  permission: "plugin/manage"
  command_module: "Esr.Commands.Plugin.UnsetConfig"
  requires_workspace_binding: false
  requires_user_binding: false
  category: "Plugins"
  description: "Remove a per-plugin config key from the named layer"
  args:
    - { name: plugin,  required: true  }
    - { name: key,     required: true  }
    - { name: layer,   required: false }

"/plugin:show":
  kind: plugin_show_config
  permission: "plugin/manage"
  command_module: "Esr.Commands.Plugin.ShowConfig"
  requires_workspace_binding: false
  requires_user_binding: false
  category: "Plugins"
  description: "Show plugin config (effective or per-layer); sensitive values masked"
  args:
    - { name: plugin,  required: true  }
    - { name: layer,   required: false }
    - { name: show_secrets, required: false }  # requires plugin/show-secrets cap

"/plugin:list-config":
  kind: plugin_list_config
  permission: "plugin/manage"
  command_module: "Esr.Commands.Plugin.ListConfig"
  requires_workspace_binding: false
  requires_user_binding: false
  category: "Plugins"
  description: "Show effective config for all enabled plugins (sensitive masked)"
  args: []
```

### 4.3 Behaviour notes

**`/plugin:set`**
- Parses `key=value` (or accepts `key` and `value` as separate named args in the routes
  yaml — both forms are spec'd; route yaml form shown above).
- Validates `key` against the plugin's `config_schema:`. Unknown key → error, no write.
- Determines the target file path for the given `layer`.
- Reads existing YAML, merges the new key, writes atomically (tmp rename).
- Calls `Esr.Plugin.Config.invalidate(plugin_name)` after write so the running instance
  reflects the change on the next `get/2` call (note: the running session's config is
  already resolved at session-create; invalidation matters for future sessions and for
  admin-facing `get` calls).
- Prints: `"config written: claude_code.http_proxy = \"…\" [global layer]\nrestart esrd to apply."`

**`/plugin:unset`**
- If the key is absent in the target file, returns success silently (idempotent).
- Invalidates ETS cache after write.

**`/plugin:show`**
- `layer=effective` (default): renders the merged result of `Config.resolve/2` using the
  caller's current session context (username from `cmd["submitter"]`; workspace_id from
  the chat's bound workspace if any).
- `layer=global|user|project`: renders only that layer's raw map (no merge applied).
- Sensitive keys (`sensitive: true` in schema) are always rendered as `***` unless the
  caller holds the `plugin/show-secrets` capability and passed `--show-secrets=true`.

---

## §5 — Shell-Script Deletion Plan

### 5.1 `scripts/esr-cc.sh` — line inventory

| Lines | Content | Migration destination |
|---|---|---|
| 1-8 | Header comment, `set -euo pipefail` | Removed with file |
| 10-11 | `ESR_WORKSPACE` + `ESR_SESSION_ID` guards | These are PtyProcess env vars set by BEAM, not operator config — stay as PtyProcess spawn args |
| 13-21 | `SCRIPT_DIR`, `REPO_ROOT`, `ESRD_INSTANCE`, `ESRD_HOME_DIR`, `WORKSPACES_YAML` | Derived from system env already set by launchd plist (`ESRD_HOME`, `ESRD_INSTANCE`) — not plugin config |
| 27 | `export PATH=...` | Moved into the replacement Elixir-native session launcher (PtyProcess spawn env) or launchd plist `EnvironmentVariables` |
| 30 | `source esr-cc.local.sh` | **Deleted.** Operator-specific overrides move to user-layer `plugins.config.yaml` |
| 33 | `source .mcp.env` | **Deleted.** Secrets move to `anthropic_api_key_ref` in plugin config; key itself stays in system env / launchd plist |
| 36-39 | `yq` check | Absorbed into Elixir workspace lookup (no yq needed) |
| 41-44 | `workspaces.yaml` existence check | Elixir already owns workspace lookup |
| 46-67 | Workspace root resolution via yq | Replaced by `Esr.Resource.WorkspaceRegistry.root_for/1` call inside BEAM before PTY spawn |
| 70-71 | `mkdir -p "$cwd"` | Elixir can do this before spawning |
| 74-85 | `ESR_ESRD_URL` → HTTP URL derivation | Elixir PtyProcess already knows the HTTP endpoint; pass it as an env var to the claude subprocess |
| 87-96 | `.mcp.json` write | Elixir PtyProcess (or a helper module) writes `.mcp.json` before `exec claude` |
| 99-106 | `session-ids.yaml` resume lookup | Move to Elixir before PTY spawn; pass `--resume <id>` as part of `CLAUDE_FLAGS` array built in BEAM |
| 117-125 | `CLAUDE_FLAGS` array (permission-mode, dev-channels, mcp-config, add-dir) | Elixir builds the argument list and passes it via `erlexec` `args:` |
| 124-125 | `settings_file` lookup | Elixir reads workspace role; passes `--settings` arg |
| 138-151 | `claude_state` workspace-trust pre-write | Elixir can do this via `File.write/2` before spawn |
| 155 | `exec claude ...` | `erlexec` PTY spawn replaces the shell entirely |

**esr-cc.local.sh exports (5 lines):**

| Export | Migration destination |
|---|---|
| `http_proxy=http://127.0.0.1:7897` | `claude_code.config.http_proxy` via `/plugin:set claude_code http_proxy=http://127.0.0.1:7897 layer=user` |
| `https_proxy=http://127.0.0.1:7897` | `claude_code.config.https_proxy` via `/plugin:set claude_code https_proxy=http://127.0.0.1:7897 layer=user` |
| `no_proxy=localhost,...` | `claude_code.config.no_proxy` via `/plugin:set claude_code no_proxy=… layer=user` |
| `HTTP_PROXY=$http_proxy` | Same as `http_proxy` above (duplicate upper-case form; plugin sets both) |
| `HTTPS_PROXY=$https_proxy` | Same as `https_proxy` above |

**esr-cc.local.sh.example** extras (commented-out line 12–13):

| Variable | Migration |
|---|---|
| `ESR_ESRD_URL=ws://127.0.0.1:4001` | `claude_code.config.esrd_url` via `/plugin:set` |

### 5.2 Files that reference `esr-cc.sh` and must be updated

| File | Line(s) | Change |
|---|---|---|
| `runtime/lib/esr/entity/pty_process.ex` | 350 | `default_start_cmd/0` returns path to `esr-cc.sh`. Replace with the new Elixir-native launcher or an in-process build of the `exec claude` command line. |
| `runtime/lib/esr/entity/unbound_chat_guard.ex` | 104 | Hint text references `--start-cmd scripts/esr-cc.sh`. Update hint to show the new invocation. |
| `runtime/test/esr/commands/workspace/info_test.exs` | 22 | Fixture uses `start_cmd: "scripts/esr-cc.sh"`. Update to reflect new default or make start_cmd optional. |
| `runtime/test/esr/resource/workspace_registry_test.exs` | 20 | Same fixture. Update. |
| `scripts/final_gate.sh` | 342 | References `start_cmd=scripts/esr-cc.sh`. Update or remove that line when the workspace fixture no longer needs it. |
| `tests/e2e/scenarios/07_pty_bidir.sh` | 48 | Comment "session dir must exist before esr-cc.sh tries to chdir". Update comment; ensure dir creation moves to Elixir side. |
| `docs/dev-guide.md` | 37, 212 | Line 37 shows `start_cmd=scripts/esr-cc.sh` in an example command; line 212 notes that `esr-cc.sh` writes `session-ids.yaml`. Both must be updated to reflect the Elixir-native launcher. |
| `docs/cookbook.md` | 74 | Shows `--start-cmd scripts/esr-cc.sh` in a `workspace add` example. Update to omit `--start-cmd` (default now auto-derived). |
| `docs/futures/todo.md` | 56 | TODO entry "Spec: agent (cc) startup config first-class" references `scripts/esr-cc.sh` and `scripts/esr-cc.local.sh`. Mark as resolved (replaced by this spec) after Sub-phase D lands. |
| `docs/notes/pty-attach-diagnostic.md` | 177 | References `scripts/esr-cc.sh` pre-trusting workspace. Update or remove that note. |

### 5.3 Launchd plist (stays as system env)

`ESRD_INSTANCE` and `ESRD_HOME` are set in the launchd plist
(`scripts/launchd/com.ezagent.esrd-*.plist.template`) and read by both the BEAM and
(previously) by `esr-cc.sh`. These remain as system env vars — they are instance-identity,
not per-plugin config.

`ANTHROPIC_API_KEY` stays as a system env var in the launchd plist. The plugin config
mechanism does **not** store the key value — it stores `anthropic_api_key_ref`, which is a
reference string like `"${ANTHROPIC_API_KEY}"`. At session-create the plugin resolves this
ref via `System.get_env("ANTHROPIC_API_KEY")`. This keeps the secret in the OS keychain /
launchd plist and out of any yaml file.

---

## §6 — E2E Migration

### 6.1 `tests/e2e/scenarios/common.sh`

This file sets the following env vars:

| Var | Set at | Moves to plugin config? |
|---|---|---|
| `ESR_E2E_RUN_ID` | Line 8 | No — test-infra |
| `ESRD_INSTANCE` | Line 9 | No — instance identity |
| `ESR_INSTANCE` | Line 13 | No — CLI rail |
| `ESRD_HOME` | Line 15 | No — instance home |
| `MOCK_FEISHU_PORT` | Line 16 | No — test-infra |
| `ESR_E2E_BARRIER_DIR` | Line 17 | No — test-infra |
| `ESR_E2E_UPLOADS_DIR` | Line 18 | No — test-infra |
| `ESR_E2E_TMUX_SOCK` | Line 19 | No — test-infra |
| `ESR_OPERATOR_PRINCIPAL_ID` | Line 24 | No — test principal |
| `ESR_BOOTSTRAP_PRINCIPAL_ID` | Line 32 | No — capability bootstrap |

**Finding:** `common.sh` itself does not source `esr-cc.sh` or set proxy/API-key vars.
It does not need to change for the proxy migration. However, `start_esrd` on line 421 calls
`scripts/esrd.sh start`, which starts the BEAM. After Sub-phase C ships (claude_code reads
proxy from plugin config), any `e2e` test that exercises a real `claude` subprocess must
have the relevant plugin config keys pre-seeded in the test's instance
`$ESRD_HOME/<inst>/plugins.yaml`. Add a `seed_plugin_config` helper to `common.sh`:

```bash
seed_plugin_config() {
  # Write claude_code proxy config (if CI sets ESR_E2E_HTTP_PROXY).
  # In the default case (no proxy needed for e2e mocks), this is a no-op.
  local cfg_file="${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml"
  mkdir -p "$(dirname "${cfg_file}")"
  # Preserve existing enabled: list; append or merge config: section.
  # For simplicity in shell, write a fresh file with both sections.
  local proxy="${ESR_E2E_HTTP_PROXY:-}"
  local api_key_ref="${ESR_E2E_ANTHROPIC_KEY_REF:-\${ANTHROPIC_API_KEY}}"
  cat >> "${cfg_file}" <<YAML
config:
  claude_code:
    http_proxy: "${proxy}"
    https_proxy: "${proxy}"
    anthropic_api_key_ref: "${api_key_ref}"
YAML
}
```

### 6.2 Scenario-by-scenario impact

| Scenario | Touches esr-cc.sh? | Action required |
|---|---|---|
| `01_single_user_create_and_end.sh` | No direct reference | No change needed for shell-script deletion; after Sub-phase C, add `seed_plugin_config` call if the scenario starts a real CC session |
| `02_two_users_concurrent.sh` | No direct reference | Same as 01 |
| `04_multi_app_routing.sh` | No direct reference | Same as 01 |
| `05_topology_routing.sh` | No direct reference | Same |
| `06_pty_attach.sh` | Implicit (starts esrd which spawns PtyProcess → esr-cc.sh) | After Sub-phase D, PtyProcess no longer calls esr-cc.sh; scenario continues to work if Elixir side builds the claude command correctly |
| `07_pty_bidir.sh` | Line 48 comment; implicit via session_new → PtyProcess | Update comment on line 48; verify scenario still passes after Sub-phase D replaces esr-cc.sh |
| `08_plugin_core_only.sh` | No direct reference | No change |
| `11_plugin_cli_surface.sh` | No direct reference | Add assertions for new `/plugin:set` `/plugin:unset` `/plugin:show` commands once Sub-phase B ships |

### 6.3 Makefile / CI impact

The `Makefile` does not reference `esr-cc.sh` directly; it invokes scenario scripts which
call `start_esrd` which calls `esrd.sh start`. After Sub-phase D the chain works without
`esr-cc.sh`. No changes required to the Makefile itself.

The `scripts/final_gate.sh` references `start_cmd=scripts/esr-cc.sh` at line 342 as part
of a workspace fixture. After Sub-phase D this must be updated to use the new default
start_cmd value (or omit start_cmd if the default is auto-derived in Elixir).

---

## §7 — Implementation Plan

### Sub-phase A — Manifest + Storage (~200 LOC)

**Goal:** schema is parsed; `plugins.yaml` reads/writes the `config:` section; no user-facing slash yet.

- `Esr.Plugin.Manifest`:
  - Add `config_schema` field to the struct.
  - `parse/1`: read `config_schema:` map from YAML; store as `declares.config_schema`.
  - Add validation: every `config_schema` entry must have `type`, `description`, `default`, `sensitive` fields; reject unknown types.
- `Esr.Plugin.PluginsYaml`:
  - `read_config(plugin_name)` → reads `config:<plugin>` from plugins.yaml.
  - `write_config(plugin_name, key, value, layer)` → atomic write to the appropriate file.
  - `delete_config(plugin_name, key, layer)` → atomic delete.
- New module `Esr.Plugin.Config`:
  - `resolve/2`, `get/2`, `store/3`, `invalidate/1` as specified in §3.1.
  - ETS table `:plugin_config_cache` created at `Esr.Application.start/2`.

**Independent shippable gate:** `Esr.Plugin.Config.resolve/2` unit tests pass for all layer
combinations (global-only, user+global, project+user+global, absent layers).

---

### Sub-phase B — Slash Commands (~250 LOC)

**Goal:** operators can set/unset/show config via Feishu slash commands.

**Depends on:** Sub-phase A (manifest schema + `Esr.Plugin.Config`).

- `Esr.Commands.Plugin.SetConfig` — validate key, write, print restart hint, invalidate cache.
- `Esr.Commands.Plugin.UnsetConfig` — delete key idempotently.
- `Esr.Commands.Plugin.ShowConfig` — render merged or per-layer view; mask sensitive.
- `Esr.Commands.Plugin.ListConfig` — show all enabled plugins' effective config.
- Update `runtime/priv/slash-routes.default.yaml` with the four new routes (colon-namespace).

**Independent shippable gate:** `/plugin:set claude_code http_proxy=http://test:8080` writes
to plugins.yaml; `/plugin:show claude_code` renders `http_proxy = "http://test:8080"`;
`/plugin:unset claude_code http_proxy` removes it.

---

### Sub-phase C — claude_code Plugin Migration (~150 LOC + config_schema addition)

**Goal:** `claude_code` plugin reads proxy and API-key config from `Esr.Plugin.Config` instead of relying on shell env vars.

**Depends on:** Sub-phase A.

- Add `config_schema:` to `runtime/lib/esr/plugins/claude_code/manifest.yaml` (as specified in §2.4).
- `Esr.Entity.PtyProcess` or a new `Esr.Plugins.ClaudeCode.Launcher` module:
  - Before `exec claude`, resolve env vars from `Esr.Plugin.Config.get("claude_code", "http_proxy")` etc.
  - Pass resolved values as environment variables to the erlexec spawn (e.g. `{:env, [{"HTTP_PROXY", val}]}`).
  - Build the `--resume` arg from Elixir (move out of esr-cc.sh lines 99-106).
  - Build the `.mcp.json` write from Elixir (move out of lines 87-96).
  - Build `CLAUDE_FLAGS` in Elixir (move out of lines 117-125).
  - Pre-trust workspace in `~/.claude.json` from Elixir (move out of lines 138-151).
- Session-create calls `Esr.Plugin.Config.resolve("claude_code", …)` + `store/3` (§3.2).

**Independent shippable gate:** a new `mix test` unit test verifies that when
`claude_code.config.http_proxy = "http://proxy.test:8080"` is set in the instance
`plugins.yaml`, `PtyProcess.build_env/1` includes `{"HTTP_PROXY", "http://proxy.test:8080"}`.

---

### Sub-phase D — Shell Script Deletion + E2E Update (~300 LOC deleted / modified)

**Goal:** `esr-cc.sh` and `esr-cc.local.sh` are deleted; e2e suite continues to pass.

**Depends on:** Sub-phase C (all logic migrated to Elixir side).

- `git rm scripts/esr-cc.sh scripts/esr-cc.local.sh scripts/esr-cc.local.sh.example`
- Update `runtime/lib/esr/entity/pty_process.ex`:
  - Remove `default_start_cmd/0` pointing at `esr-cc.sh`.
  - `PtyProcess` now directly builds the `exec claude` invocation inside BEAM.
- Update `runtime/lib/esr/entity/unbound_chat_guard.ex`: remove shell-script hint text.
- Update test fixtures: `workspace/info_test.exs` + `workspace_registry_test.exs`.
- Update `scripts/final_gate.sh:342`.
- Update `tests/e2e/scenarios/07_pty_bidir.sh:48` (comment only).
- Add `seed_plugin_config` to `tests/e2e/scenarios/common.sh`.
- Update `CLAUDE.md` and any operator docs referencing `esr-cc.local.sh`.

**Independent shippable gate:** `make e2e` (all six scenarios) passes after deletion.
Also: `make e2e-07` specifically, since 07 has the strongest coupling to PtyProcess.

---

### Sub-phase E — Feishu Plugin Migration (optional, ~50 LOC)

**Goal:** feishu plugin reads `log_level` and any other operator-tunable config from plugin
config rather than hardcoded defaults.

**Depends on:** Sub-phase A.

- Add `config_schema:` to `runtime/lib/esr/plugins/feishu/manifest.yaml`.
- Feishu adapter reads `Esr.Plugin.Config.get("feishu", "log_level")` at startup.

**Gate:** feishu e2e scenarios unaffected. This sub-phase is skipped if feishu has no
operator-tunable config today.

---

## §8 — Risk Register

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | Removing `esr-cc.sh` breaks launchd plist / operator muscle memory | Medium | Update all docs before deletion; send Feishu announcement before Sub-phase D merges. |
| R2 | Empty-string vs absent-key resolution ambiguity in project layer | Low | Spec is explicit: empty string wins (§3.3 table). Unit tests cover the empty-string case. |
| R3 | ETS cache staleness after `/plugin:set` | Medium | `invalidate/1` is called synchronously after every write (§3.1 `store`/`invalidate` design). Future sessions always call `resolve/2` fresh from disk. Running session retains its resolved config (acceptable until restart). |
| R4 | Schema drift — operator adds unknown key to plugins.yaml by hand | Low | Validation runs at `/plugin:set` write time. Boot-time warning (Logger.warning) for unknown keys found in plugins.yaml that are not in the schema. |
| R5 | Sensitive value leakage in logs | Medium | `sensitive: true` keys are never logged by `Esr.Plugin.Config` module. `inspect(config_map)` in debug logs must be guarded or filtered. Add a `sanitize/1` helper that replaces sensitive values with `"***"` before logging. |
| R6 | Project-layer `.esr/plugins.config.yaml` accidentally committed with secrets | Low | Schema's `sensitive: true` field carries a description warning. Operator docs explicitly warn: never put literal API keys in the project layer. |
| R7 | `yq` dependency removed but some operator script still calls `esr-cc.sh` | Low | After deletion, the file is gone; any stale script fails immediately with a clear error. |

---

## §9 — Test Plan

### Unit tests

| Test | Module under test | Assertion |
|---|---|---|
| Manifest parser accepts valid `config_schema:` | `Esr.Plugin.Manifest` | `parse/1` returns struct with `declares.config_schema` map |
| Manifest parser rejects `config_schema:` entry with missing `type` | `Esr.Plugin.Manifest` | `parse/1` returns `{:error, {:config_schema_missing_field, …}}` |
| Manifest parser rejects unknown type `integer` (Phase 1) | `Esr.Plugin.Manifest` | `parse/1` returns `{:error, {:config_schema_unknown_type, …}}` |
| `resolve/2` global-only | `Esr.Plugin.Config` | Returns global map; user + project absent → defaults + global |
| `resolve/2` user overrides global on one key | `Esr.Plugin.Config` | User value wins on that key; global value used for other keys |
| `resolve/2` project overrides user and global | `Esr.Plugin.Config` | Project value wins on all keys it provides |
| `resolve/2` project layer empty-string overrides global non-empty | `Esr.Plugin.Config` | `""` from project wins over `"http://proxy.test"` from global |
| `resolve/2` absent project layer does not override global | `Esr.Plugin.Config` | Key absent from project file → global value propagates |
| `/plugin:set` validates key against schema; rejects unknown key | `Esr.Commands.Plugin.SetConfig` | Returns error text; plugins.yaml unchanged |
| `/plugin:set` valid key writes to correct file | `Esr.Commands.Plugin.SetConfig` | `File.read` of target file shows updated key |
| `/plugin:show` masks sensitive value without `--show-secrets` | `Esr.Commands.Plugin.ShowConfig` | Rendered output contains `***` for `anthropic_api_key_ref` |
| `/plugin:show --show-secrets` requires `plugin/show-secrets` cap | `Esr.Commands.Plugin.ShowConfig` | Caller without cap gets error; caller with cap sees real value |
| `/plugin:unset` idempotent on absent key | `Esr.Commands.Plugin.UnsetConfig` | Returns `:ok`; file unchanged |

### E2E tests

| Test | Scenario | Gate |
|---|---|---|
| Smoke: CC agent calls Anthropic API with proxy set via plugin config | New scenario or extension of `07_pty_bidir.sh` | `ESR_E2E_HTTP_PROXY` set → session resolves proxy → PtyProcess passes `HTTP_PROXY` env to claude subprocess |
| Post-deletion regression: `make e2e` passes without `esr-cc.sh` | All six Makefile scenarios | Sub-phase D gate |
| Plugin CLI surface includes new slash commands | `11_plugin_cli_surface.sh` | `/plugin:set`, `/plugin:unset`, `/plugin:show` return expected output |

---

## Open Questions for Operator Review

1. **User-layer path**: `$ESRD_HOME/<inst>/users/<username>/plugins.config.yaml` — is this naming acceptable, or prefer `plugins.yaml` (matching the global file)?

2. **Project layer scope**: currently spec'd as "only when workspace is repo-bound (non-empty `root:` field)". Should ESR-bound workspaces (no git root, e.g. a scratch workspace) also read a project-layer file from some directory?

3. **Per-key vs whole-map merge**: spec selects per-key override (deep merge). Confirm this is correct; the alternative (project-layer replaces the entire plugin block) is simpler but less flexible.

4. **Sensitive masking in `/plugin:show`**: default-masked, unmask requires `plugin/show-secrets` cap + `--show-secrets` flag. Is the capability name `plugin/show-secrets` correct, or should it fold into `plugin/manage`?
