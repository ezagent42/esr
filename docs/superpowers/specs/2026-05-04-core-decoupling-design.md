# Core Decoupling Design (Spec A)

**Date:** 2026-05-04 (rev 2 — subagent-reviewed; substantive fixes applied)
**Audience:** anyone planning to implement the plugin work; companion to `2026-05-04-plugin-mechanism-design.md` (Spec B)
**Status:** prescriptive design

---

## 一、Goals + non-goals

### Goals

> **After this spec lands, esrd boots, runs, and survives e2e with no plugin code present.** Every "external feature" (feishu chat integration, claude-code agent, voice processing) is movable into a plugin without core needing to know about it.

Concretely:
1. Inventory every `.ex` / `.py` file as core or plugin (and which plugin).
2. Design merge mechanisms for `agents.yaml` / `adapters.yaml` / `slash-routes.yaml` / `permissions.yaml` so that core's runtime state is a composition of core + enabled-plugin contributions.
3. Design the Python sidecar registration mechanism so core's `Esr.WorkerSupervisor.sidecar_module/1` doesn't hard-code adapter names.
4. Specify a **core-only e2e scenario** (`tests/e2e/scenarios/08_core_admin.sh`) that validates core works without any plugin loaded.
5. Specify the **migration order** — which feature moves to a plugin first, what's verified at each step, what's the bail-out criterion.

### Non-goals (handled by Spec B)

- Plugin manifest schema, loader, topo sort, enable/disable, `/plugin` slash commands, cold-start CLI flow.
- Plugin distribution (build-time / runtime / hex).
- Third-party / community plugin contributions.

---

## 二、Core / plugin boundary — file-level inventory

### 2.1 Principle (recap)

> **Core provides mechanisms; plugins provide specific implementations that consume those mechanisms.** Test: "Could this be reused by a different plugin?" Yes → core; No → plugin.

### 2.2 Core (stays under `runtime/lib/esr/`)

**Application + Scope primitive:**
- `application.ex` — OTP app (≡ DaemonScope per concepts.md §🔧-5)
- `scope.ex` — top-level Scope module
- `scope/{process,router,supervisor,admin}.ex` — Scope primitive infra + AdminScope kind base
- `scope/admin/process.ex` — AdminScope state GenServer
- (Scope.Registry exists as an Elixir kernel `Registry` process, not a module file)

**Entity primitive (no concrete instances except generic mechanisms):**
- `entity/{entity.ex, server.ex, registry.ex, factory.ex, pool.ex, supervisor.ex, proxy.ex, stateful.ex, py_worker.ex}` — Entity primitive infra
- `entity/pty_process.ex` — **Generic PTY-backed peer**, BUT ⚠️ contains cc-launcher path resolution (`scripts/esr-cc.sh`) and cc-specific bootstrap args. **Migration prep work required**: extract cc-launch concerns into a small `Esr.Plugins.ClaudeCode.PtyLauncher` adapter that PtyProcess delegates to via a `launch_args/1` callback. PtyProcess itself stays core after extraction.
- `entity/slash_handler.ex` — **Slash command dispatcher** (parses + routes), BUT ⚠️ currently contains feishu-aware paths (calls `lookup_by_feishu_id`, references FeishuChatProxy directly). **Migration prep work required**: introduce a "platform identity hook" registered by plugins that slash_handler consults instead of calling feishu-specific functions directly.
- `entity/user/*` — User Entity base type. ⚠️ User schema has a `feishu_id` field that's plugin/feishu-specific — see §三 user_schema_fields injection point.

**Resource primitive:**
- `resource/{capability,permission,workspace}/*` — Resource type Registry + FileLoader + Watcher
- `resource/{slash_route,dead_letter,adapter_socket,chat_scope}/*` — generic Resource instances

**Interface contracts:** all of `interface/*` (R4-R11 declarations)

**Admin subsystem:**
- `admin/{dispatcher.ex, supervisor.ex, command_queue/{watcher.ex, janitor.ex}}` — admin queue + dispatcher
- `admin/commands/scope/*` — Scope lifecycle commands (New/End/BranchNew/BranchEnd/List/Switch)
- `admin/commands/workspace/*` — Workspace management
- `admin/commands/cap/*` — Capability management
- `admin/commands/agent/list.ex` — list available agents (the data lookup is core; agents themselves come from plugins)
- `admin/commands/{help,key,reload}.ex` — operator tools
- `admin/commands/{doctor,whoami}.ex` — operator tools, ⚠️ **currently call `lookup_by_feishu_id` and emit "user bind-feishu" hints**. Migration prep: introduce a "platform identity rendering hook" plugins register; commands call the hook instead of feishu-specific functions. Without this prep, doctor/whoami break in core-only mode.
- `admin/commands/attach.ex` — terminal inspection (consumes core PtyProcess + AdapterSocket)
- **NEW**: `admin/commands/plugin/{list,info,enable,disable}.ex` — plugin management (Spec B)

**Other infrastructure:**
- `handler.ex` + `handler_router.ex` — Handler base + routing
- `topology.ex`
- `os_process.ex`, `py_process.ex` — erlexec subprocess hosts
- `paths.ex`, `ansi_strip.ex`, `worktree.ex`, `pools.ex`
- `workers/{adapter_process,handler_process}.ex` + `worker_supervisor.ex` — subprocess hosts (registration is plugin-contributable; see §三)
- `telemetry/*`, `persistence/*`, `yaml/*`
- `launchd/*`, `dead_letter.ex` (legacy ref — actually moved to `resource/dead_letter/queue.ex`)

**EsrWeb:** all of `esr_web/*` (Phoenix endpoint, channels, sockets — generic web layer).

**Python core packages** (under `py/src/`):
- `esr/*` — public SDK
- `_adapter_common/*` — shared adapter scaffolding
- `_ipc_common/*` — IPC helpers
- `generic_adapter_runner/*` — fallback for unknown adapter types

### 2.3 Plugin/feishu

**Elixir** (currently in `runtime/lib/esr/entity/`, moves to `runtime/lib/esr/plugins/feishu/`):
- `feishu_app_adapter.ex` → `Esr.Plugins.Feishu.AppAdapter`
- `feishu_app_proxy.ex` → `Esr.Plugins.Feishu.AppProxy`
- `feishu_chat_proxy.ex` → `Esr.Plugins.Feishu.ChatProxy`
- `cap_guard.ex` → `Esr.Plugins.Feishu.CapGuard` (deny-DM logic is feishu-specific in the message wording)
- `unbound_chat_guard.ex` → `Esr.Plugins.Feishu.UnboundChatGuard`
- `unbound_user_guard.ex` → `Esr.Plugins.Feishu.UnboundUserGuard`

**Admin commands** (currently in `runtime/lib/esr/admin/commands/`):
- `notify.ex` → `Esr.Plugins.Feishu.Commands.Notify` (notify is feishu-specific outbound)
- `register_adapter.ex` — **audit needed**: if pure adapter-registration, core; if feishu-specific, plugin
- `cross_app_test.ex` — **audit needed**: dev-only, may be deprecated

**Python** (currently in `py/src/`):
- `feishu_adapter_runner/*` → `py/src/plugins/feishu/feishu_adapter_runner/*`

**Yaml fragments** (currently in `runtime/priv/`):
- `adapters.feishu.yaml` (carved out of adapters.yaml)
- `slash-routes.feishu.yaml` fragment (notify route, bind-feishu route)
- `caps.feishu.yaml` fragment (feishu/* capabilities)

### 2.4 Plugin/claude_code

**Elixir** (currently in `runtime/lib/esr/entity/`):
- `cc_process.ex` → `Esr.Plugins.ClaudeCode.Process`
- `cc_proxy.ex` → `Esr.Plugins.ClaudeCode.Proxy`

**Python** (currently in `py/src/`):
- `cc_adapter_runner/*` → `py/src/plugins/claude_code/cc_adapter_runner/*`

**Other plugin/cc-specific assets:**
- `scripts/esr-cc.sh` — claude-launcher script
- `scripts/esr-cc.local.sh.example` — proxy/secret config template
- claude-specific config files

**Yaml fragments:**
- `agents.cc.yaml` fragment — the cc agent_def with PtyProcess + CCProcess + CCProxy pipeline
- `caps.cc.yaml` fragment — cc/* capabilities (if any)

### 2.5 Plugin/voice

**Elixir** (currently in `runtime/lib/esr/entity/`):
- `voice_asr.ex` → `Esr.Plugins.Voice.ASR`
- `voice_asr_proxy.ex` → `Esr.Plugins.Voice.ASRProxy`
- `voice_tts.ex` → `Esr.Plugins.Voice.TTS`
- `voice_tts_proxy.ex` → `Esr.Plugins.Voice.TTSProxy`
- `voice_e2e.ex` → `Esr.Plugins.Voice.E2E`

**Python** (currently in `py/src/`):
- `voice_asr/*` → `py/src/plugins/voice/voice_asr/*`
- `voice_tts/*` → `py/src/plugins/voice/voice_tts/*`
- `voice_e2e/*` → `py/src/plugins/voice/voice_e2e/*`
- `_voice_common/*` → `py/src/plugins/voice/_voice_common/*`

**Yaml fragments:**
- `agents.voice.yaml` fragment
- `caps.voice.yaml` fragment

### 2.6 Edge cases — explicit decisions

| Module | Decision | Reason |
|---|---|---|
| `entity/pty_process.ex` | **core** | Generic PTY mechanism; consumed by Attach (core); reusable by future agent plugins |
| `entity/slash_handler.ex` | **core** | Slash dispatcher mechanism; specific slash routes come from plugins via SlashRoute.Registry |
| `admin/commands/attach.ex` | **core** | Inspect mechanism; not claude-specific |
| `admin/commands/notify.ex` | **plugin/feishu** | Outbound feishu DM; plugin-specific |
| `admin/commands/register_adapter.ex` | **TBD audit** | If generic adapter registration, core; if feishu-specific, plugin/feishu |
| `admin/commands/cross_app_test.ex` | **TBD audit** | Possibly dev-only; may delete instead of moving |
| `cap_guard.ex` | **split: pattern matcher → core, rules → plugin/feishu** | The guard pattern (regex match + lane-B deny dispatch) is a generic mechanism; the specific feishu adapter URI patterns it matches against are feishu-shaped. Split into `Esr.Resource.CapGuard` (core regex mechanism) + `Esr.Plugins.Feishu.CapGuard.Rules` (feishu-shaped routes / deny-DM templates). |
| `unbound_*_guard.ex` | **plugin/feishu** | Onboarding flow is feishu-specific |

---

## 三、Yaml fragment merge mechanism

Today: single `~/.esrd-dev/<env>/{agents,adapters,slash-routes,capabilities}.yaml` files. Edits go directly to those files.

After Spec A: each plugin ships fragments that core merges at boot.

### 3.1 Fragment file locations

```
runtime/lib/esr/plugins/<name>/priv/
  agents.yaml         ← plugin's agent_def contributions
  adapters.yaml       ← plugin's adapter instance contributions  
  slash-routes.yaml   ← plugin's slash command contributions
  capabilities.yaml   ← plugin's cap declarations
```

### 3.2 Merge rules

**For agents.yaml** (per-agent dictionary keyed by `<name>`):
- Plugin contributions add new keys (e.g., plugin/cc adds `cc:` key)
- Conflict on duplicate key → boot fails with explicit error (not silent override)
- User customization layer: `~/.esrd-dev/<env>/agents.user.yaml` overrides per-key after merge
- Final composed in-memory: `Esr.Entity.Agent.Registry` snapshot = merge(core defaults, plugin1, plugin2, …, user)

**For adapters.yaml** (list of instances):
- Each entry has unique `instance_id`; collisions fail boot
- Plugin contributions append; user override file appends + replaces by `instance_id`

**For slash-routes.yaml** (per-kind dictionary):
- Plugin contributions add new kinds; collision fails boot
- User customization can override `permission` (e.g., loosen / tighten an existing route's required cap)

**For capabilities.yaml** (cap declaration list):
- Plugin contributions add new caps; collision on cap name fails boot
- User customization is at the **grants** level (which principal has which cap), not declarations

### 3.3 Implementation approach

A new module `Esr.Yaml.FragmentMerger` (or extend `Esr.Yaml.*`) that:
1. Reads all enabled-plugin fragment paths (from manifest)
2. Merges into a single map per yaml-domain
3. Layer the user override file last
4. Hands the merged result to the existing per-domain Registry's `load_snapshot/1`

**API alignment prerequisite**: most Registries already expose `load_snapshot/1` (Cap.Grants, SlashRoute.Registry, User.Registry — they implement `Esr.Interface.SnapshotRegistry`). However **`Esr.Entity.Agent.Registry` exposes `load_agents(path)` not `load_snapshot/1`** — the moduledoc explicitly notes this asymmetry. Spec A's implementation must add a sub-step **"R12-prep: Esr.Entity.Agent.Registry gains `load_snapshot/1` accepting a pre-built map"** before FragmentMerger has somewhere to hand merged data. This is a 1-PR prep-work item.

**Watch behavior**: when a plugin yaml changes (rare; usually shipped frozen), trigger the same merger + reload. When user yaml changes (common), trigger merge + reload.

### 3.4 Open question — registry layering

Today `Esr.Entity.Agent.Registry` has a single snapshot. To support per-plugin layering with traceability ("which plugin contributed this agent_def"), the snapshot may need a `:source` field per entry. Decision: defer to implementation — start without source tracking, add only if `/doctor` or debugging needs it.

---

## 四、Python sidecar registration

Today `Esr.WorkerSupervisor.sidecar_module/1` hard-codes:
```elixir
def sidecar_module("feishu"), do: "feishu_adapter_runner"
def sidecar_module("cc_mcp"), do: "cc_adapter_runner"
def sidecar_module(_), do: "generic_adapter_runner"
```

After Spec A: plugins declare in their manifest which adapter types map to which python modules. Core's `WorkerSupervisor` looks up via a registered map.

**Mechanism:** `Esr.Resource.Sidecar.Registry` (new core Resource) — populated at boot from plugin manifests. Lookup `sidecar_module(adapter_type)` consults this registry; falls back to `generic_adapter_runner` on miss.

Plugin manifest field:
```yaml
declares:
  python_sidecar:
    - adapter_type: feishu
      python_module: feishu_adapter_runner
```

---

## 五、Core-only e2e scenario — `08_core_admin.sh`

### 5.1 What it tests

Validates core works **without any plugin enabled**:
1. esrd starts (core-only mode: `enabled_plugins: []` in config)
2. Admin queue accepts `/help` command via file write
3. Watcher consumes it, Dispatcher routes to `Esr.Admin.Commands.Help`
4. Help command's response yaml lands in `admin_queue/completed/`
5. Response contains expected help text

### 5.2 Why we need it

- Today's e2e 06/07 use cc → would fail without claude_code plugin
- We need a "still-green" anchor that's truly plugin-independent
- Pre-merge-dev gate should run BOTH 08 (core-only) AND 06/07 (with plugins enabled)

### 5.3 Implementation sketch

```bash
# tests/e2e/scenarios/08_core_admin.sh
# Stage 1: spawn esrd with enabled_plugins=[] env override
# Stage 2: write /help yaml to admin queue pending/
# Stage 3: poll completed/ for response
# Stage 4: assert response contains "/help" and "/doctor" (core slash routes that exist today)
```

(Verified core slashes in `runtime/priv/slash-routes.default.yaml`: `/help, /whoami, /key, /doctor, /new-workspace, /workspace info, /workspace sessions, /sessions, /new-session, /end-session, /list-agents, /attach`. Use `/help` and `/doctor` for assertion — they're permission-free admin tools.)

Doesn't need PtyProcess, doesn't need any external adapter. Pure admin queue exercise.

---

## 六、Migration order

To avoid R3-style cascade, migrate one plugin at a time, in this order:

### 6.1 Order: prep → voice → feishu → claude_code

**Step 0 — prerequisite extractions** (before any plugin migration):

1. `Esr.Entity.Agent.Registry` gains `load_snapshot/1` (per §3.3 prereq)
2. `Esr.Entity.SlashHandler` extracts feishu-aware paths into a "platform identity hook"; plugins register implementations
3. `Esr.Admin.Commands.{Doctor, Whoami}` switch from direct `lookup_by_feishu_id` calls to the platform identity hook
4. `Esr.Application.start/2` `bootstrap_feishu_app_adapters` / `bootstrap_voice_pools` calls become conditional on plugin enablement (no-op if plugin disabled)
5. `Esr.Resource.CapGuard` extracts the regex/lane-B mechanism out of `Esr.Entity.CapGuard` (which becomes a feishu-specific Rules module)
6. `Esr.Entity.PtyProcess` extracts cc-launcher path resolution into `Esr.Plugins.ClaudeCode.PtyLauncher`

These are 6 small PRs that decouple core's plugin-aware code paths BEFORE any file moves. Without step 0, the file moves themselves break core-only mode.

**Why voice first** (after Step 0): simplest, fewest cross-cutting concerns. No PtyProcess dependency. No webhook lifecycle. Validates the plugin mechanism on a low-risk feature.

**Why feishu second**: medium complexity. Has external WS connection lifecycle, but no PTY. Validates yaml merger handles real adapter instance config.

**Why claude_code last**: highest complexity. Depends on PtyProcess (already core after Step 0.6). Pipeline involves CCProcess + CCProxy + cc_mcp + esr-cc.sh script + claude binary. Validates plugin can ship Elixir + Python + bash + binary all together.

### 6.2 Per-plugin migration substeps

For each plugin (executed as one PR-batch, similar to R-series):

**Phase A (file moves only, no behavior change)**:
1. Branch off `dev`
2. `git mv` Elixir files to `runtime/lib/esr/plugins/<name>/*.ex`; rename modules `Esr.Entity.X` → `Esr.Plugins.<Name>.X`
3. `git mv` Python packages to `py/src/plugins/<name>/*`
4. Sweep call sites — `grep -rln 'Esr\.Entity\.\(FeishuAppAdapter\|...\)'` → substitute
5. Compile + test — should pass with same baseline as before
6. Daemon state files: agents.yaml's `impl:` entries pointing to old `Esr.Entity.*` need update; sweep `~/.esrd-dev/default/agents.yaml`
7. Restart esrd-dev + e2e 06/07 + DOM check
8. Open PR + admin-squash merge

**Phase B (plugin manifest)** — done as part of Spec B implementation, after Spec A's file moves are clean.

### 6.3 Bail-out criteria (per plugin migration PR)

Same as R-series (refactor-lessons.md §五):
- mix test failures > 10× baseline → revert
- daemon won't restart → revert
- e2e 06/07 fail → revert (especially 07 if claude_code plugin is involved)
- DOM dataset out of range → revert

---

## 七、Open questions

1. **`register_adapter.ex` and `cross_app_test.ex` audit**: are they generic or feishu-specific? Audit during plugin/feishu migration.
2. **`Esr.Workers.*` location after plugin work**: stays core (subprocess infrastructure). But how do plugin-specific adapter types register? Via the Sidecar.Registry from §四. No code move.
3. **e2e 08 environment**: how do we tell e2e 08 to run with `enabled_plugins=[]`? Via env var `ESR_ENABLED_PLUGINS=` empty? Defined in §五 implementation.
4. **User customization layering**: do we need `~/.esrd-dev/<env>/agents.user.yaml` separately, or is editing the merged file (and re-merging on watch) enough? Defer decision to first migration; revisit if friction.
5. **Plugin manifest format**: yaml or Elixir module? Spec B decides; Spec A doesn't depend on the answer.
6. **Capability merge collision policy** (e.g., what if two plugins declare the same cap name?): boot-time hard fail. Reasonable per-plugin namespace prefix (cap names include plugin name) prevents this in practice.
7. **`Esr.Resource.Sidecar.Registry` schema**: keep simple (`adapter_type → python_module` string map) or richer (per-sidecar config / health checks)? Start simple; extend on need.

---

## 八、Validation criteria (this spec is "done" when …)

1. Every `.ex` and `.py` file is classified core-or-plugin (with concrete plugin name).
2. Yaml fragment merge mechanism is concrete enough to implement (file paths, merge rules, conflict policy).
3. Python sidecar registration mechanism is concrete enough to implement.
4. `08_core_admin.sh` e2e scenario design is implementable.
5. Migration order + bail-out criteria are unambiguous.

This spec satisfies all 5.

---

## 九、Related docs

- `docs/notes/concepts.md` / `session.md` / `mechanics.md` — metamodel
- `docs/notes/structural-refactor-plan-r4-r11.md` — R4-R11 (the metamodel namespace work this spec builds on)
- `docs/notes/refactor-lessons.md` — R1-R11 lessons
- `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` (Spec B) — the second half: plugin loader, manifest, /plugin commands, cold-start
- `docs/futures/todo.md` — future work
