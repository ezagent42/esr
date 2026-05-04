# Plugin Mechanism Design (Spec B)

**Date:** 2026-05-04 (rev 2 — subagent-reviewed; substantive fixes applied)
**Audience:** anyone implementing the plugin mechanism after Spec A's core decoupling lands
**Status:** prescriptive design

---

## 一、Goals + non-goals + core principle

### Goals

> **Allow new functionality to ship as self-contained plugins that core loads via manifest declaration. Plugins extend core's metamodel surface (Capabilities, slash routes, agents, adapters, entities) without core code changes.**

Concretely:
1. Plugin manifest schema covering 17 injection points enumerated in §三.
2. Plugin Loader module that scans `runtime/lib/esr/plugins/*/manifest.yaml`, topologically sorts by dependency, starts each in supervision tree.
3. CLI surface: `/plugin {list, info, enable, disable}` admin commands.
4. Cold-start flow: core boots without any plugin; operator enables plugins via `esr` CLI; restart loads them.
5. Phase 1 build-time include implementation (no runtime hot-load).

### Non-goals

- Runtime hot-code-load (Phase 2 future).
- Hex package distribution (Phase 2 future).
- Third-party / community plugin contribution model (Phase 2 future).
- Core decoupling itself (Spec A handles).

### Core principle

> **Core provides mechanisms; plugins provide specific implementations that consume those mechanisms.** Test: "Could this be reused by a different plugin?" Yes → core; No → plugin.

(Same principle as Spec A.)

---

## 二、Plugin types

A plugin can be any combination of these three types:

| Type | What it provides | Example |
|---|---|---|
| **Component** | One or more Entity / Resource modules implementing core Interfaces | `RateLimitGuard` — a generic CapGuard variant |
| **Topology fragment** | Wiring declarations (agents.yaml fragment) referencing existing components | "feishu-via-cc" — references existing FAA + cc components, declares how they wire |
| **Session declaration** | Full bundle: components + wiring + agent_def + caps + slashes, ready-to-use | plugin/claude_code — ships `cc` agent_def, CCProcess + CCProxy components, cap declarations |

A plugin's manifest declares which subset of types it implements. Most real plugins are Session declarations (highest level), bundling Components and Topology fragments.

**Boundary clarification**:
- **Scope kind** (DaemonScope, AdminScope, future GroupChatScope): **core-only**. Plugins do NOT define new Scope kinds — Scope kinds are metamodel-level, defined by Session module declarations under `Esr.Sessions.*` (Phase 4 core work).
- **Session declaration** (an instance of an agent within a Scope kind): **plugin-extensible** — plugins ship their own agent_def entries.

---

## 三、Plugin → Core injection points (17 enumerated)

| # | Injection point | Core mechanism | Plugin contributes |
|---|---|---|---|
| 1 | Capability declarations | `Esr.Resource.Permission.Registry` | new cap names (e.g., `feishu/notify`, `voice/asr`) |
| 2 | Slash route declarations | `Esr.Resource.SlashRoute.Registry` | new slash kind + command_module mapping |
| 3 | Agent declarations | `Esr.Entity.Agent.Registry` | new agent type + pipeline topology (agents.yaml fragment) |
| 4 | Adapter declarations | adapters.yaml | new adapter instances (feishu app config) |
| 5 | Entity types | `Esr.Entity.Server` host + `Esr.Entity.Factory` | concrete Entity modules implementing `@behaviour Esr.Interface.{Member, Boundary, Agent}` |
| 6 | Topology fragments | agents.yaml + future `Esr.Sessions.*` declarations | inbound/proxies lists referring to plugin Entity modules |
| 7 | Workspace schema fields | `Esr.Resource.Workspace.Registry` | plugin-specific schema additions (e.g., voice plugin adds `voice_lang:`) |
| 8 | PubSub topic namespace | `Phoenix.PubSub` | plugin uses prefix-namespaced topics (`feishu/`, `voice/`, `cc/`) |
| 9 | HTTP routes | `EsrWeb.Router` | plugin adds endpoints (e.g., voice plugin's `/audio/<sid>`) |
| 10 | Phoenix Channel topic | `EsrWeb.{Adapter,Channel,Handler,Pty}Socket.channel/2` (4 distinct sockets, no UserSocket) | plugin registers Channel modules under one of these sockets |
| 11 | AdminScope startup hook | `Esr.Scope.Admin.bootstrap_*` (today: `bootstrap_voice_pools/1`, `bootstrap_slash_handler/0`, `bootstrap_feishu_app_adapters/1` — see `Esr.Application.start/2` lines 192-260) | plugin starts always-on entities at admin scope boot (FAA, voice pool). After Spec A's prep step 4, these calls become conditional on plugin enablement. |
| 12 | Python sidecar registration | `Esr.Resource.Sidecar.Registry` (Spec A §四) | plugin maps `adapter_type → python_module` |
| 13 | OS env / config | `config/runtime.exs` | plugin declares required env vars (FEISHU_APP_ID, ANTHROPIC_BASE_URL) |
| 14 | Doctor health check | `Esr.Admin.Commands.Doctor` | plugin registers health check (FAA WS status, voice ASR connection) |
| 15 | Test fixtures + e2e helpers | `tests/e2e/`, `runtime/test/` | plugin ships fixtures + scenarios under its own dir |
| 16 | Bootstrap principal capabilities | `ESR_BOOTSTRAP_PRINCIPAL_ID` auto-grant | plugin declares default-grant cap list for bootstrap principal |
| 17 | Doc generation | `gen-docs.sh` | plugin's `@moduledoc` flows into the generated reference |
| 18 | User schema fields | `Esr.Entity.User.Registry` schema | plugin contributes platform-id fields (e.g., feishu plugin owns `feishu_id:` field on User entries) |
| 19 | Platform identity hook | `Esr.Entity.SlashHandler` + `Esr.Admin.Commands.{Doctor, Whoami}` (per Spec A's prep step 2-3) | plugin registers a `resolve_external_id(platform, ext_id)` callback so core admin commands don't reference feishu directly |
| 20 | yaml `impl:` module reference resolver | core agents.yaml load path | plugin must declare its Entity modules in manifest so core can validate `impl:` references at boot (fail-fast if a yaml entry references a disabled plugin's module) |

---

## 四、Plugin manifest schema

Each plugin ships a `manifest.yaml` at `runtime/lib/esr/plugins/<name>/manifest.yaml`:

```yaml
# Plugin metadata
name: feishu              # required, kebab-case, unique
version: 0.1.0            # required, semver
description: |            # human-readable
  Feishu (Lark) chat platform integration. Provides webhook adapter,
  chat proxy, capability guards for unbound users.

# Dependencies
depends_on:
  core: ">= 0.1.0"        # required core version
  plugins: []             # other plugins (e.g., voice depends on claude_code)

# What this plugin contributes (subset of injection points 1-17)
declares:
  capabilities:           # injection #1
    - feishu/notify
    - feishu/bind
    - feishu/cap.guard

  slash_routes:           # injection #2
    - kind: notify
      command_module: Esr.Plugins.Feishu.Commands.Notify
      permission: feishu/notify
    - kind: bind_feishu
      command_module: Esr.Plugins.Feishu.Commands.BindFeishu
      permission: feishu/bind

  agent_defs:             # injection #3 — agent_def fragment(s) for agents.yaml
    - file: priv/agents.yaml          # path relative to plugin root

  adapter_defs:           # injection #4 — adapter instance fragment(s)
    - file: priv/adapters.yaml

  entities:               # injection #5 — Entity modules this plugin owns
    - module: Esr.Plugins.Feishu.AppAdapter
      kind: stateful      # :proxy or :stateful
      behaviours: [Esr.Interface.Boundary]
    - module: Esr.Plugins.Feishu.AppProxy
      kind: proxy
      behaviours: []
    - module: Esr.Plugins.Feishu.ChatProxy
      kind: proxy

  workspace_schema_fields: []  # injection #7

  user_schema_fields:     # injection #18 — plugin extends User.Registry schema
    - field: feishu_id
      type: string
      indexed: true       # add to lookup_by_feishu_id-style index

  pubsub_topic_prefixes:  # injection #8
    - "feishu/"

  http_routes:            # injection #9 — Phoenix.Router scopes
    - module: Esr.Plugins.Feishu.WebhookController
      scope: "/webhook/feishu"

  phoenix_channels: []    # injection #10

  admin_scope_children:   # injection #11 — entities the plugin spawns at AdminScope boot
    - module: Esr.Plugins.Feishu.AppAdapter
      args_from: adapters.yaml  # spawn one per adapter instance

  python_sidecars:        # injection #12
    - adapter_type: feishu
      python_module: feishu_adapter_runner

  required_env:           # injection #13
    - FEISHU_APP_ID
    - FEISHU_APP_SECRET

  doctor_checks:          # injection #14
    - module: Esr.Plugins.Feishu.HealthCheck
      function: status/0

  test_fixtures: []       # injection #15

  bootstrap_grants:       # injection #16 — caps auto-granted to ESR_BOOTSTRAP_PRINCIPAL_ID
    - feishu/notify
    - feishu/bind

  identity_hook:          # injection #19 — plugin registers platform identity resolver
    module: Esr.Plugins.Feishu.Identity
    function: resolve_external_id/2  # called by core's slash_handler / doctor / whoami
```

### 4.1 Validation rules

- `name` is unique across all plugins; collision = boot fails
- `depends_on.core` constrains compatible core version (semver)
- `depends_on.plugins` references other plugin names; topo-sort must be acyclic
- All declared module names must exist (compile-time check via `Code.ensure_loaded?/1`)
- All referenced files (agents.yaml, adapters.yaml, …) must exist relative to plugin root
- Capability names must follow `<resource>/<scope>` or `<resource>/<scope>/<perm>` shape (per existing convention)

---

## 五、Loader

### 5.1 Module: `Esr.Plugin.Loader`

Public API:
```elixir
defmodule Esr.Plugin.Loader do
  @doc "Scan plugins/, parse manifests, return loaded-state list."
  def discover() :: [{plugin_name, manifest_map}]

  @doc "Apply enabled-plugins config; return ordered start list."
  def topo_sort_enabled(discovered, enabled_names) :: [{plugin_name, manifest_map}] | {:error, :cycle | :missing_dep}

  @doc "Start a plugin's supervisor + register its contributions in core registries."
  def start_plugin(name, manifest) :: {:ok, supervisor_pid} | {:error, term}

  @doc "Stop a plugin (terminate its supervisor; unregister contributions)."
  def stop_plugin(name) :: :ok
end
```

### 5.2 Boot sequence

In `Esr.Application.start/2`:

```
1. Start core supervision tree (admin queue, registries, http, …) — works with no plugin
2. Esr.Plugin.Loader.discover()                            # scan plugins/ for manifests
3. Read enabled_plugins from config/runtime.exs            # e.g., [:feishu, :claude_code]
4. plugins = Loader.topo_sort_enabled(discovered, enabled) # acyclic check
5. for {name, manifest} <- plugins:
     Loader.start_plugin(name, manifest)                    # registers contributions + starts supervisor
6. Application.put_env(:esr, :plugins_loaded, plugins)     # for /plugin info
```

### 5.3 Shutdown

When the OTP application stops, each plugin supervisor is terminated normally by its parent supervisor (no special unload code needed). Resource Registry entries cleared via `terminate/2` callbacks.

### 5.4 Dependency resolution

Topo sort on `depends_on.plugins` graph; reject cycle. If a plugin's dependency isn't in the enabled list, plugin start fails with explicit error: `{:error, {:missing_dep, plugin_name, dep_name}}`.

---

## 六、Enable / disable mechanism

### 6.1 Config layer

**`enabled_plugins` lives in a yaml file, not in `runtime.exs` directly** — `runtime.exs` is text-evaluated at boot and programmatic rewriting is brittle. Use a yaml file (`~/.esrd-dev/<env>/plugins.yaml`) read by `runtime.exs`.

```yaml
# ~/.esrd-dev/<env>/plugins.yaml (operator-editable + esrd-mutable)
enabled:
  - feishu
  - claude_code
  - voice
```

```elixir
# config/runtime.exs
config :esr,
  enabled_plugins:
    case File.read(Path.join(esrd_home, "plugins.yaml")) do
      {:ok, body} -> YamlElixir.read_from_string!(body)["enabled"] || ["feishu", "claude_code", "voice"]
      _ -> ["feishu", "claude_code", "voice"]   # default = all enabled
    end
```

`/plugin enable <name>` writes to this yaml file (atomic file replace, same pattern as `Esr.Resource.Capability.Grants` does for capabilities.yaml). Operator can also edit the yaml directly.

Default: all three plugins enabled (matches today's behavior). Operator can override via yaml or env.

### 6.2 CLI/slash interface

```
/plugin list
  → outputs: feishu (enabled), claude_code (enabled), voice (disabled)

/plugin info <name>
  → dumps manifest summary (depends, declares, version)

/plugin enable <name>
  → writes new enabled_plugins config + emits "restart required" message
  → does NOT runtime-load (Phase 1)

/plugin disable <name>
  → writes new enabled_plugins config + emits "restart required" message
```

### 6.3 No runtime-toggle in Phase 1

Enabling/disabling requires `esrd restart`. Phase 2 may add hot-load (Mix.Project includes / Code.eval_file / OTP application start).

### 6.4 Admin command modules (new for Spec B)

```
runtime/lib/esr/admin/commands/plugin/
  list.ex       Esr.Admin.Commands.Plugin.List
  info.ex       Esr.Admin.Commands.Plugin.Info
  enable.ex     Esr.Admin.Commands.Plugin.Enable
  disable.ex    Esr.Admin.Commands.Plugin.Disable
```

These are core (the principle: plugin management can't be in a plugin — chicken-and-egg).

---

## 七、Cold-start flow + CLI surface

Operator on a fresh machine:

```
1. esrd start                            # core comes up; admin queue + esr CLI active
2. esr cmd plugin list                   # output: 3 plugins discovered, all enabled per default
3. (optional) esr cmd plugin disable voice    # if voice not needed
4. esrd restart                          # changes take effect
5. From this point, operator/end-user uses Feishu chat (since plugin/feishu is enabled)
   to send slash commands to esrd
```

Zero web UI in Phase 1. CLI suffices for operator use cases.

---

## 八、Phase 1 implementation steps

After Spec A's core decoupling lands. Execute in this order:

### Step 1: Loader skeleton (no actual plugin moves yet)
- Create `runtime/lib/esr/plugin/loader.ex` with `discover/0`, `topo_sort_enabled/2`, `start_plugin/2`, `stop_plugin/1`
- Create `runtime/lib/esr/plugin/manifest.ex` for parsing/validating manifest yaml
- Wire into `Esr.Application.start/2` (after core startup)
- Test: with no `plugins/` dir, application boots cleanly

### Step 2: Plugin manifest for voice (smallest pilot)
- Move voice files per Spec A §6.2 Phase A
- Write `runtime/lib/esr/plugins/voice/manifest.yaml` covering applicable injection points
- Write yaml fragments (agents.yaml fragment, etc.)
- Loader parses manifest at boot; voice supervisor starts; yaml fragments merge into core registries
- e2e: voice-using scenario still passes (or write `09_voice_smoke.sh`)
- Disable voice (`enabled_plugins: []`) → daemon boots without voice; e2e 08 (core-only) still passes

### Step 3: Plugin manifest for feishu
- Move feishu files per Spec A §6.2 Phase A
- Write feishu manifest + yaml fragments
- Test enable/disable combinations: voice + feishu, only feishu, only voice, neither

### Step 4: Plugin manifest for claude_code
- Move cc files per Spec A §6.2 Phase A
- Write cc manifest + yaml fragments
- e2e 06+07 (cc-using) still pass with cc enabled

### Step 5: `/plugin {list,info,enable,disable}` admin commands
- Implement 4 command modules
- Add slash routes to core's slash-routes.yaml
- Test: `/plugin list` returns expected output via admin queue

### Step 6: Final validation
- All e2e scenarios pass: 08 (core-only), 06+07 (cc), voice scenario, feishu webhook scenario
- Disabling any plugin doesn't break the others
- Manifest validation catches bad config (cycle, missing dep, bad cap name)

---

## 九、Phase 2 future extensions

**Hot-load**: Plugin code added without restart. Requires `Mix.Project` runtime mutation OR OTP `application:load/1` + `start/1` orchestration. Defer until clear need.

**Hex package distribution**: `mix esr.plugin.install hex_name` resolves Hex package, fetches into `plugins/`, restarts. Requires versioned core API + plugin sandbox. Defer until third-party plugins exist.

**Third-party / community plugins**: signed manifest, capability sandbox (plugin can't declare `core/admin` caps), opt-in trust model. Defer until use case materializes.

---

## 十、Risks + validation

### Risks

| Risk | Mitigation |
|---|---|
| Plugin manifest gets out of sync with code (declared modules don't exist) | `Esr.Plugin.Manifest.validate/1` checks `Code.ensure_loaded?/1` for every declared module |
| Plugin yaml fragment references modules from a disabled plugin | Boot-time validator: every `impl:` in agents.yaml must resolve to an enabled-plugin's declared module |
| Plugin capabilities collide | Boot-time hard fail; plugin authors should namespace cap names with plugin name prefix |
| Plugin python sidecar shadows core `generic_adapter_runner` | Sidecar.Registry lookup is exact-match-only; fallback to generic only on miss |
| User customization (yaml override) breaks after plugin disable | User yaml refers to plugin-contributed key → boot fails with explicit "unknown agent: cc; plugin claude_code is disabled" |
| Core admin commands (doctor, whoami, slash_handler) have plugin-aware identity-rendering paths today | Migration BLOCKER. Spec A's Step 0.2/0.3 prep work extracts these into the platform-identity-hook (injection #19). Without it, migrating feishu to a plugin breaks doctor/whoami in core-only mode. |
| `bootstrap_feishu_app_adapters` runs unconditionally in `Esr.Application.start/2` | Spec A's Step 0.4 prep work makes this conditional on `enabled_plugins` containing `:feishu`. Same for `bootstrap_voice_pools`. Without it, core-only mode (with feishu plugin disabled) still tries to start FAA → fails. |

### Validation (when this spec is "done")

1. Plugin manifest schema covers all 17 injection points enumerated in §三.
2. Loader's discover/topo-sort/start/stop API is implementable in <300 LOC.
3. CLI surface (`/plugin list/info/enable/disable`) is concrete enough to implement.
4. Phase 1 implementation steps are executable as 6 R-batch-style PRs.
5. Cold-start flow has zero ambiguity (CLI-only, no GUI required).

This spec satisfies all 5.

---

## 十一、Related docs

- `docs/superpowers/specs/2026-05-04-core-decoupling-design.md` (Spec A) — prerequisite work
- `docs/notes/concepts.md` — metamodel
- `docs/notes/structural-refactor-plan-r4-r11.md` — namespace work
- `docs/futures/todo.md` — plugin todo entry
