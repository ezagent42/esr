# Plugin Implementation Plan — feature-track structure

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-05-04 (rev 3 — added /plugin install command + CLI-surface e2e scenario per user 2026-05-04 08:20)
**Audience:** anyone implementing the plugin work; combines specs A (`2026-05-04-core-decoupling-design.md`) and B (`2026-05-04-plugin-mechanism-design.md`)
**Goal:** extract feishu / claude_code / voice as plugins; core boots and runs without any plugin loaded
**Architecture:** feature-track structure (per user 2026-05-04) — each plugin's extraction is a self-contained track. Foundation work first (loader skeleton + new core APIs), then voice (smallest pilot), then feishu, then cc.
**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / OTP 28 / Python 3.11+ / yaml / mix

---

## Why feature-track instead of "core-decouple → plugin-build" sequencing

Core and plugin code paths are tightly intertwined today (PtyProcess has cc-specific paths; doctor/whoami call `lookup_by_feishu_id`; bootstrap_feishu_app_adapters runs unconditionally). A two-phase plan would leave a long "core decoupled but no plugins yet" intermediate state where dev is in a half-broken shape and there's no validation gate per change.

Feature-track structure: **each track ends with that one plugin fully extracted + core able to run without it**. Every merge to dev keeps the project coherent.

---

## Track ordering

```
Track 0: Foundation       (loader skeleton + new core APIs + e2e 08)
   ↓
Track 1: Voice plugin     (simplest; fewest core touchpoints)
   ↓
Track 2: Feishu plugin    (medium; most C→P hooks: identity, bootstrap, schema)
   ↓
Track 3: Claude Code plugin (largest; PtyProcess strip + python cc_mcp move)
```

Each track produces 1-3 PRs. Each PR ends with `mix test` green + e2e 06+07+08 + DOM check (per refactor-lessons.md §四).

---

## Track 0 — Foundation

**Goal:** core gains the APIs + machinery that plugins will use, without moving any feature code yet.

### Task 0.1 — `Esr.Entity.Agent.Registry.load_snapshot/1`

**Files:**
- Modify: `runtime/lib/esr/entity/agent/registry.ex` — add `load_snapshot(map) :: :ok` callback (per `Esr.Interface.SnapshotRegistry` contract)

- [ ] **Step 1: Write the failing test** in `runtime/test/esr/entity/agent/registry_test.exs`:
```elixir
test "load_snapshot/1 atomically replaces the in-memory agent map" do
  snapshot = %{"foo" => %{name: "foo", impls: []}}
  assert :ok = Esr.Entity.Agent.Registry.load_snapshot(snapshot)
  assert {:ok, %{name: "foo"}} = Esr.Entity.Agent.Registry.agent_def("foo")
end
```

- [ ] **Step 2: Run + verify failure**: `(cd runtime && mix test test/esr/entity/agent/registry_test.exs)` → expect `function load_snapshot/1 is undefined`.

- [ ] **Step 3: Implement** in `agent/registry.ex`. **Critical: preserve existing `:path` and other state fields** — current state is `%{agents: %{}, path: nil}` (see registry.ex line 88), and `load_agents/1` mutates `:path`. Don't drop fields:
```elixir
@behaviour Esr.Interface.SnapshotRegistry
def load_snapshot(snapshot) when is_map(snapshot) do
  GenServer.call(__MODULE__, {:load_snapshot, snapshot})
end

def handle_call({:load_snapshot, snapshot}, _from, state) do
  # Preserve :path and any other state fields; only swap :agents.
  {:reply, :ok, %{state | agents: snapshot}}
end
```
Then add a thin adapter so `load_agents/1` keeps working: parse the path, build the snapshot, and call `load_snapshot/1` internally — instead of duplicating in-memory mutation logic.

- [ ] **Step 4: Run + verify pass**.

- [ ] **Step 5: Commit** as `feat(agent-registry): add load_snapshot/1 per SnapshotRegistry contract`.

### Task 0.2 — `Esr.Resource.Sidecar.Registry`

**Files:**
- Create: `runtime/lib/esr/resource/sidecar/registry.ex` — new `Esr.Resource.Sidecar.Registry` module

- [ ] **Step 1: Write failing test** asserting registration + lookup of `adapter_type → python_module` mappings.

- [ ] **Step 2: Implement** module with `register/2`, `lookup/1`, `list/0` (implementing `Esr.Interface.LiveRegistry`), backed by ETS.

- [ ] **Step 3: Wire into `Esr.Application.start/2` supervision tree** alongside the other Resource registries.

- [ ] **Step 4: Modify `Esr.WorkerSupervisor.sidecar_module/1`** to consult `Esr.Resource.Sidecar.Registry.lookup(adapter_type)`, falling back to `"generic_adapter_runner"` on miss. Remove the hardcoded `feishu` / `cc_mcp` clauses.

- [ ] **Step 5: Add fallback registrations** in Application start (until plugin manifests handle this) so existing tests don't break: register `feishu → feishu_adapter_runner` and `cc_mcp → cc_adapter_runner`.

- [ ] **Step 6: Run tests** + commit.

### Task 0.3 — Yaml fragment merger

**Files:**
- Create: `runtime/lib/esr/yaml/fragment_merger.ex`
- Test: `runtime/test/esr/yaml/fragment_merger_test.exs`

- [ ] **Step 1: Write test** for merging N agents.yaml fragments + an `agents.user.yaml` override; assert: collisions raise; user override wins.

- [ ] **Step 2: Implement** `merge(fragments :: [path], user_override :: path | nil) :: {:ok, merged_map} | {:error, reason}`. Pure-function.

- [ ] **Step 3: Wire into `Esr.Resource.{Workspace,SlashRoute,Capability}.FileLoader` + `Esr.Entity.{Agent,User}.Registry`** so each loader composes from `[core_default_path, plugin1_fragment, plugin2_fragment, …, user_override_path]` instead of single path.
  - Plugin paths come from `Application.get_env(:esr, :enabled_plugins)` + manifest scan.
  - Phase 0 has no plugins enabled by default in tests; merger receives empty fragment list; behavior identical to today.

- [ ] **Step 4: Run full test suite** + commit.

### Task 0.4 — Plugin manifest parser + Loader skeleton

**Files:**
- Create: `runtime/lib/esr/plugin/manifest.ex` — yaml schema validation
- Create: `runtime/lib/esr/plugin/loader.ex` — discover + topo-sort + start/stop
- Create: `runtime/lib/esr/plugins/.gitkeep` (empty plugins dir)

- [ ] **Step 1: Implement `Esr.Plugin.Manifest`** with `parse(path) :: {:ok, struct} | {:error, reason}`. Validate fields per Spec B §四. Boot-time module existence check via `Code.ensure_loaded?/1`. Cap-namespace-prefix enforcement.

- [ ] **Step 2: Implement `Esr.Plugin.Loader`**:
  - `discover() :: [{name, manifest}]` scans `runtime/lib/esr/plugins/*/manifest.yaml`.
  - `topo_sort_enabled(discovered, enabled_names) :: [{name, manifest}] | {:error, ...}`.
  - `start_plugin(name, manifest) :: {:ok, sup_pid} | {:error, ...}` — registers contributions in core registries (cap, slash, sidecar, etc.) + starts plugin's own supervisor as a child of `Esr.Supervisor` via `Supervisor.start_child/2`.
  - `stop_plugin(name) :: :ok` (Phase 1: requires restart; this is a no-op stub).

- [ ] **Step 3: Wire into `Esr.Application.start/2`** AFTER core supervisor is up: discover → topo-sort → start each enabled plugin. With no plugins on disk, this is a no-op.

- [ ] **Step 4: Test:** boot esrd with empty `plugins/`; expect zero plugin starts; full test suite green.

- [ ] **Step 5: Commit**.

### Task 0.4.1 — Reorder note

**Critical sequencing**: Task 0.6 (runtime.exs reads plugins.yaml) must land **before** Task 0.5 step 3 ("write to plugins.yaml, restart, verify enabled_plugins changed"). Either:
- (a) execute 0.6 before 0.5, OR
- (b) split 0.5 step 3 into 0.5 (commit the commands) + a follow-up after 0.6 to add the integration test

This plan picks (a): swap 0.5 and 0.6 ordering. Re-numbered below.

### Task 0.5 — `runtime.exs` reads `plugins.yaml` (was 0.6)

**Files:**
- Modify: `runtime/config/runtime.exs`

- [ ] **Step 1: Add yaml read logic** to populate `:enabled_plugins` from `~/.esrd-dev/<env>/plugins.yaml`. **Edge case**: empty/missing file or empty `enabled:` list must produce `[]`, not `[""]`. Test `String.split("", ",", trim: true) == []`.
- [ ] **Step 2: Default to `[:feishu, :claude_code, :voice]` if file missing** (so today's behavior is preserved).
- [ ] **Step 3: Commit**.

### Task 0.6 — Core admin commands `/plugin {list,info,install,enable,disable}` (was 0.5)

**Files:**
- Create: `runtime/lib/esr/admin/commands/plugin/{list,info,install,enable,disable}.ex` (5 modules)
- Modify: `runtime/priv/slash-routes.default.yaml` — add 5 new routes

- [ ] **Step 1: Implement 5 command modules**:
  - `list` — consumes `Esr.Plugin.Loader.discover/0` + reads `enabled_plugins` config
  - `info <name>` — dumps manifest summary
  - `install <local_path | git_url>` — Phase 1 implementation: copy/clone source into `runtime/lib/esr/plugins/<name>/`; validate `manifest.yaml`; run `mix compile`; report success + restart-required hint. Reject if plugin already exists at target path. Phase 2 may add hex/remote registry support.
  - `enable <name>` — writes `~/.esrd-dev/<env>/plugins.yaml` (atomic file replace); reports restart-required
  - `disable <name>` — same write pattern

- [ ] **Step 2: Add 5 slash routes** with `permission: "plugin/manage"` (declare new core cap `plugin/manage` in capabilities.yaml).

- [ ] **Step 3: Test each command** in isolation:
  - `list` — discoverable plugin enumeration with enabled-status flag
  - `info` — manifest dump for a known plugin
  - `install` — local-path install creates files at expected location, manifest validation rejects malformed plugin
  - `enable`/`disable` — plugins.yaml write produces expected file content

- [ ] **Step 4: Integration test** — write to plugins.yaml, restart, verify `Application.get_env(:esr, :enabled_plugins)` reflects the change (this depends on Task 0.5 having landed).

- [ ] **Step 5: Commit**.

### Task 0.7 — e2e 08 core-only scenario

**Files:**
- Create: `tests/e2e/scenarios/08_core_admin.sh`
- Modify: `Makefile` — add `e2e-08` target + include in `e2e` aggregate

- [ ] **Step 1: Write scenario** that:
  - Spawns esrd with `ESR_ENABLED_PLUGINS=` (empty)
  - Writes `/help` admin yaml to admin queue
  - Polls completed/ for response
  - Asserts response contains both `/help` and `/doctor` strings

- [ ] **Step 2: Run** + verify green.

- [ ] **Step 3: Update `scripts/hooks/pre-merge-dev-gate.sh`** to also run scenario 08.

- [ ] **Step 4: Commit**.

### Task 0.8 — e2e 11 CLI surface scenario

**Files:**
- Create: `tests/e2e/scenarios/11_cli_surface.sh`
- Modify: `Makefile` — add `e2e-11` target + include in `e2e` aggregate

End-to-end coverage of the `esr cmd plugin {list,info,install,enable,disable}` CLI surface: the operator's only interaction path before any plugin is loaded.

- [ ] **Step 1: Set up an isolated test plugin** — `tests/e2e/_helpers/dummy_plugin/` with a minimal valid manifest (declares one cap `dummy/test`, no entities, no slash routes).

- [ ] **Step 2: Write scenario** that:
  - Spawns esrd with `ESR_ENABLED_PLUGINS=` (empty)
  - Runs `esr cmd plugin list` → asserts exit 0 + output mentions zero enabled plugins
  - Runs `esr cmd plugin install tests/e2e/_helpers/dummy_plugin` → asserts exit 0 + dummy plugin files exist at `runtime/lib/esr/plugins/dummy/`
  - Runs `esr cmd plugin info dummy` → asserts manifest dump output
  - Runs `esr cmd plugin enable dummy` → asserts plugins.yaml updated
  - Runs `esr cmd plugin disable dummy` → asserts plugins.yaml reverted
  - Cleanup: removes the dummy plugin files

- [ ] **Step 3: Run** + verify green.

- [ ] **Step 4: Update `scripts/hooks/pre-merge-dev-gate.sh`** to also run scenario 11.

- [ ] **Step 5: Commit + open Track 0 PR**.

**Track 0 done criteria:**
- mix test green (no test regressions vs dev baseline)
- e2e 06 / 07 / 08 / 11 all green
- Plugin loader infrastructure exists but no real plugins enabled yet
- Application boots cleanly with `enabled_plugins: []`
- 5 `/plugin` admin commands functional (list / info / install / enable / disable)

---

## Track 1 — Voice plugin (simplest pilot)

**Goal:** voice extracted as plugin/voice; e2e 08 (core-only) still green; voice e2e green when plugin enabled.

### Task 1.1 — Make `bootstrap_voice_pools` conditional

**Files:**
- Modify: `runtime/lib/esr/application.ex`

- [ ] **Step 1: Find** the `bootstrap_voice_pools` call in `Esr.Application.start/2`.
- [ ] **Step 2: Wrap** with `if :voice in Application.get_env(:esr, :enabled_plugins)`.
- [ ] **Step 3: Test** with voice disabled → no voice pool start; with voice enabled → voice pool starts (existing behavior).
- [ ] **Step 4: Commit**.

### Task 1.2 — Voice file move

**Files (Elixir):**
- Move: `runtime/lib/esr/entity/voice_asr.ex` → `runtime/lib/esr/plugins/voice/asr.ex`
- Move: `voice_asr_proxy.ex` → `plugins/voice/asr_proxy.ex`
- Move: `voice_tts.ex` → `plugins/voice/tts.ex`
- Move: `voice_tts_proxy.ex` → `plugins/voice/tts_proxy.ex`
- Move: `voice_e2e.ex` → `plugins/voice/e2e.ex`
- Module rename: `Esr.Entity.Voice*` → `Esr.Plugins.Voice.*`
- Move tests: `runtime/test/esr/entity/voice_*_test.exs` → `runtime/test/esr/plugins/voice/*_test.exs` (5 files: voice_asr, voice_asr_proxy, voice_tts, voice_tts_proxy, voice_e2e)
- Move integration test: `runtime/test/esr/integration/voice_e2e_test.exs` → `runtime/test/esr/plugins/voice/integration/voice_e2e_test.exs` (voice-only integration; clear ownership)
- **Cross-plugin integration test**: `runtime/test/esr/integration/cc_voice_test.exs` exercises BOTH cc and voice. **Decision**: keep at `runtime/test/esr/integration/cc_voice_test.exs` (core integration test; tests cross-plugin contract via Channel/PubSub Interface), but tag with `@moduletag :requires_plugins, [:claude_code, :voice]` so the test runner skips it when either plugin is disabled.
- Move fixture: `runtime/test/esr/fixtures/agents/voice.yaml` → `runtime/lib/esr/plugins/voice/test/fixtures/agents.yaml`
- **Helper to move**: `Esr.Paths.pools_yaml/0` (voice-specific path helper) — move to `Esr.Plugins.Voice.Paths.pools_yaml/0` (plugin owns its own paths). Update callers.

**Files (Python):**
- Move: `py/src/voice_asr/`, `voice_tts/`, `voice_e2e/`, `_voice_common/` → `py/src/plugins/voice/`

**Scope.Admin ripple**: `runtime/lib/esr/scope/admin.ex` contains `bootstrap_voice_pools/1`. **Decision**: keep `bootstrap_voice_pools` definition at `Esr.Scope.Admin` for now (it's the C→P invocation point per Spec B injection #11), but `Esr.Application.start/2`'s call to it is already gated by `if :voice in enabled_plugins` (Task 1.1). Consider future cleanup: move pool-spawning logic into the plugin itself, with `bootstrap_voice_pools` becoming a thin shim. Out of scope for Track 1.

- [ ] **Step 1: Capture grep baseline** in `docs/refactor/voice-plugin-pre.txt`.
- [ ] **Step 2: `git mv` files + sweep call sites** with `perl -i -pe 's/\bEsr\.Entity\.Voice/Esr.Plugins.Voice./g'` (long-first if other Voice prefixes exist).
- [ ] **Step 3: Update agents.yaml** if voice agent defs are referenced. Daemon state file sweep per refactor-lessons §三-2.
- [ ] **Step 4: Update Python sidecar registration** — register `voice_*` adapter types via Sidecar.Registry (today: hardcoded; after Task 0.2: registry-based).
- [ ] **Step 5: Compile + test** + e2e 06/07/08 + DOM check + restart daemon.
- [ ] **Step 6: Commit**.

### Task 1.3 — Voice manifest

**Files:**
- Create: `runtime/lib/esr/plugins/voice/manifest.yaml`
- Create: `runtime/lib/esr/plugins/voice/priv/agents.yaml` (extracted voice agent fragment)
- Create: `runtime/lib/esr/plugins/voice/priv/capabilities.yaml` (voice/* caps)

- [ ] **Step 1: Write manifest** declaring entities, capabilities, agent_defs, python_sidecars per Spec B §四.
- [ ] **Step 2: Carve voice entries out of `runtime/priv/agents.yaml`** into the plugin fragment.
- [ ] **Step 3: Loader picks up the manifest** at boot; voice components register; voice still works.
- [ ] **Step 4: Test enable/disable**: with `ESR_ENABLED_PLUGINS=feishu,cc` (no voice), voice doesn't start; e2e 08 still green.
- [ ] **Step 5: Commit + open PR (Track 1 PR)**.

**Track 1 done criteria** (concretely scriptable):
- `find runtime/lib/esr/plugins/voice -name '*.ex' | wc -l` = 5
- `cat runtime/lib/esr/plugins/voice/manifest.yaml` parses + validates
- `ESR_ENABLED_PLUGINS=feishu,claude_code bash tests/e2e/scenarios/08_core_admin.sh` exits 0
- `ESR_ENABLED_PLUGINS=feishu,claude_code,voice bash tests/e2e/scenarios/06_pty_attach.sh` and `07_pty_bidir.sh` both exit 0
- New voice e2e scenario `tests/e2e/scenarios/09_voice_smoke.sh` (runs ASR/TTS exchange with plugin enabled) exits 0

---

## Track 2 — Feishu plugin

**Goal:** feishu extracted; doctor / whoami work in core-only mode; e2e 08 green without feishu.

### Task 2.1 — Platform identity hook (Step 0 prep #2-#3)

**Files (call sites — verified):**
- `runtime/lib/esr/entity/slash_handler.ex:508` — direct `lookup_by_feishu_id` call
- `runtime/lib/esr/admin/commands/doctor.ex:46` — direct `lookup_by_feishu_id` call
- `runtime/lib/esr/admin/commands/whoami.ex:28` — direct `lookup_by_feishu_id` call

- [ ] **Step 1: Define** `Esr.Resource.Identity.Hook` registry — plugins call `register(platform_atom, module, function)`; core lookup reverse-resolves external IDs.
- [ ] **Step 2: Refactor** slash_handler.ex:508 / doctor.ex:46 / whoami.ex:28 to call `Identity.Hook.resolve_external/2` instead of `lookup_by_feishu_id` directly.
- [ ] **Step 3: Default fallback** if no plugin registered: return `:not_found`.
- [ ] **Step 4: Test core-only mode**: doctor/whoami don't crash when feishu plugin absent; just don't render platform IDs.
- [ ] **Step 5: Commit**.

### Task 2.2 — Make `bootstrap_feishu_app_adapters` conditional

Same pattern as Task 1.1 for voice.

- [ ] **Step 1**: Find call in `Esr.Application.start/2`.
- [ ] **Step 2**: Wrap with `if :feishu in Application.get_env(:esr, :enabled_plugins)`.
- [ ] **Step 3**: Commit.

### Task 2.3 — CapGuard split

**Files:**
- Create: `runtime/lib/esr/resource/cap_guard.ex` — `Esr.Resource.CapGuard` (core regex / lane-B mechanism)
- Move: `runtime/lib/esr/entity/cap_guard.ex` → `runtime/lib/esr/plugins/feishu/cap_guard_rules.ex` — `Esr.Plugins.Feishu.CapGuard.Rules` (feishu-shaped routes + deny-DM templates)

- [ ] **Step 1: Identify** the regex/dispatch logic vs the feishu-specific patterns inside today's CapGuard.
- [ ] **Step 2: Split** with the rules module calling into the core matcher.
- [ ] **Step 3: Test** existing CapGuard tests still pass.
- [ ] **Step 4: Commit**.

### Task 2.4 — User schema field hook

**Files:**
- Modify: `runtime/lib/esr/entity/user/registry.ex` (or schema)

- [ ] **Step 1: Allow plugin-contributed schema fields** in User entries (today's `feishu_id` field becomes plugin-contributed).
- [ ] **Step 2: Plugin manifest declares the field**; merger composes the schema at boot.
- [ ] **Step 3: Test** user yaml with/without feishu_id field both validate cleanly.
- [ ] **Step 4: Commit**.

### Task 2.5 — Feishu file move

**Files (Elixir) — verified count: 3 entity files + 3 guards + 1 admin command + 2 audit-required**:
- Move 3 entity files: `feishu_app_adapter.ex`, `feishu_app_proxy.ex`, `feishu_chat_proxy.ex` → `runtime/lib/esr/plugins/feishu/`
- Move 3 guard files: `cap_guard.ex` (split per Task 2.3), `unbound_chat_guard.ex`, `unbound_user_guard.ex` → `runtime/lib/esr/plugins/feishu/`
- Move admin command: `notify.ex` → `plugins/feishu/commands/notify.ex`
- Audit + decide: `register_adapter.ex` and `cross_app_test.ex` — move feishu-specific bits to plugin; keep generic in core; delete cross_app_test if dev-only
- Module rename pass: `Esr.Entity.Feishu*` / `Esr.Entity.{CapGuard, UnboundChatGuard, UnboundUserGuard}` → `Esr.Plugins.Feishu.*`

**Files (Test):**
- Move: `runtime/test/esr/entity/feishu_*_test.exs` (5 files)
- Move: `runtime/test/esr/entity/cap_guard_deny_dm_test.exs`
- Move: `runtime/test/esr/scope_admin_bootstrap_feishu_test.exs` → `runtime/test/esr/plugins/feishu/bootstrap_test.exs`
- Move: `runtime/test/esr/integration/feishu_react_lifecycle_test.exs` → `runtime/test/esr/plugins/feishu/integration/react_lifecycle_test.exs`
- Move: `runtime/test/esr/integration/feishu_slash_new_session_test.exs` → `runtime/test/esr/plugins/feishu/integration/slash_new_session_test.exs`

**Files (Python):**
- Move: `py/src/feishu_adapter_runner/` → `py/src/plugins/feishu/feishu_adapter_runner/`

- [ ] **Step 1: grep baseline + file moves + sweep** (R-batch playbook).
- [ ] **Step 2: Daemon state file sweep**.
- [ ] **Step 3: Compile + test + e2e + DOM**.
- [ ] **Step 4: Commit**.

### Task 2.6 — Feishu manifest

Same pattern as Task 1.3.

- [ ] **Step 1: Write manifest** with all relevant injection points.
- [ ] **Step 2: Carve adapters.yaml + agents.yaml fragments**.
- [ ] **Step 3: Identity hook registration** in manifest.
- [ ] **Step 4: Test enable/disable**.
- [ ] **Step 5: Commit + open Track 2 PR**.

**Track 2 done criteria** (concretely scriptable):
- `find runtime/lib/esr/plugins/feishu -name '*.ex' | wc -l` ≥ 7 (3 entity + 3 guard + 1 notify command)
- `cat runtime/lib/esr/plugins/feishu/manifest.yaml` parses + validates
- `ESR_ENABLED_PLUGINS=claude_code bash tests/e2e/scenarios/08_core_admin.sh` exits 0; in addition the e2e asserts `/doctor` output does NOT contain a Feishu-binding error (proves Identity.Hook fallback works)
- `ESR_ENABLED_PLUGINS=feishu,claude_code bash tests/e2e/scenarios/06_pty_attach.sh` and `07_pty_bidir.sh` both exit 0
- New feishu webhook scenario `tests/e2e/scenarios/10_feishu_webhook.sh` exits 0

---

## Track 3 — Claude Code plugin

**Goal:** cc extracted; core-only mode works without any agent; e2e 06+07 green with cc enabled.

### Task 3.1 — Strip cc-specific paths from PtyProcess

**Files:**
- Modify: `runtime/lib/esr/entity/pty_process.ex`

- [ ] **Step 1: Identify** all cc-specific hardcoded paths (`scripts/esr-cc.sh`, `--dangerously-load`, env vars).
- [ ] **Step 2: Refactor** to accept generic `cmd:` parameter via start_link. Plugin/cc passes its own command.
- [ ] **Step 3: Update existing callers** (CCProcess.start/...) to pass `cmd:` explicitly.
- [ ] **Step 4: Test** PtyProcess works with generic cmd (e.g., `bash -c 'sleep 60'`).
- [ ] **Step 5: e2e 06+07** still green.
- [ ] **Step 6: Commit**.

### Task 3.2 — CC file move

**Files (Elixir):**
- Move: `cc_process.ex` + `cc_proxy.ex` → `plugins/claude_code/`
- Module rename `Esr.Entity.{CCProcess, CCProxy}` → `Esr.Plugins.ClaudeCode.{Process, Proxy}`

**Files (Test):**
- Move: `runtime/test/esr/entity/cc_*_test.exs` → `runtime/test/esr/plugins/claude_code/*_test.exs`
- Move: `runtime/test/esr/integration/cc_e2e_test.exs` → `runtime/test/esr/plugins/claude_code/integration/e2e_test.exs`
- (`cc_voice_test.exs` stays at `runtime/test/esr/integration/` per Task 1.2 cross-plugin decision)

**Files (Python) — corrected**:
- Move: `py/src/cc_adapter_runner/` → `py/src/plugins/claude_code/cc_adapter_runner/`
- **`cc_mcp` lives at `adapters/cc_mcp/` (NOT `py/src/`)** — has its own `pyproject.toml` and `esr.toml`. Decision: move whole `adapters/cc_mcp/` directory to `runtime/lib/esr/plugins/claude_code/cc_mcp/` AND keep its standalone `pyproject.toml` (let the plugin own its own python deps). Plugin manifest's `python_sidecars:` declares the path: `python_module: cc_mcp` + `path: cc_mcp/` (relative to plugin root).

**Other assets:**
- `scripts/esr-cc.sh` stays in `scripts/` (operator-facing tool); **manifest references it via path relative to plugin root**:
  ```yaml
  scripts:
    - name: esr-cc.sh
      path: ../../../../scripts/esr-cc.sh   # plugin root → runtime/lib/esr/plugins/claude_code → up 4 to repo root
  ```
  Or **simpler**: copy the script into the plugin: `runtime/lib/esr/plugins/claude_code/scripts/esr-cc.sh` (plugin owns its launcher script). Update the cc plugin's launch logic to use this path. **Picking copy** for simplicity — matches "plugin self-contained" principle. Keep `scripts/esr-cc.sh` as operator-facing convenience symlink/wrapper if desired.
- `scripts/esr-cc.local.sh.example` likewise

- [ ] **Step 1: grep baseline + file moves + sweep**.
- [ ] **Step 2: Daemon state file sweep** (esrd-dev's agents.yaml, slash-routes.yaml).
- [ ] **Step 3: Compile + test + e2e + DOM**.
- [ ] **Step 4: Commit**.

### Task 3.3 — CC manifest

Same pattern as Tasks 1.3 / 2.6.

- [ ] **Step 1: Write manifest** including HTTP routes (PtySocket) if cc owns any.
- [ ] **Step 2: Carve cc agent fragment** out of agents.yaml.
- [ ] **Step 3: Test enable/disable**.
- [ ] **Step 4: Commit + open Track 3 PR**.

**Track 3 done criteria** (concretely scriptable):
- `find runtime/lib/esr/plugins/claude_code -name '*.ex' | wc -l` ≥ 2 (cc_process + cc_proxy)
- `find runtime/lib/esr/plugins/claude_code/cc_mcp -name '*.py' | head -1` returns at least one file
- `cat runtime/lib/esr/plugins/claude_code/manifest.yaml` parses + validates
- `ESR_ENABLED_PLUGINS= bash tests/e2e/scenarios/08_core_admin.sh` exits 0 (with NO plugins enabled)
- `ESR_ENABLED_PLUGINS= esr cmd plugin list` returns expected output (3 plugins discovered, 0 enabled)
- `ESR_ENABLED_PLUGINS= esr cmd plugin enable claude_code` writes `~/.esrd-dev/<env>/plugins.yaml` with `enabled: [claude_code]`
- After daemon restart, `ESR_ENABLED_PLUGINS=` env unset, plugins.yaml takes over → claude_code loads → e2e 06+07 exit 0
- All other e2e scenarios still pass with their respective plugins enabled

**Foundation polish (after Track 3)**:
- `pre-merge-dev-gate.sh` updated to run scenarios 06, 07, 08, 09 (voice), 10 (feishu)
- `tests/e2e/_helpers/` agent-browser screenshot helper exists for future e2e content checks (per refactor-lessons §6.2)

---

## Per-track validation checklist (every PR within a track)

```
- [ ] mix compile --warnings-as-errors clean
- [ ] mix test failure count ≤ dev baseline (currently ~10)
- [ ] daemon state file sweep complete (~/.esrd-dev/default/*.yaml + ~/.esrd-dev/default/*.json — including `permissions_registry.json` which caches module names)
- [ ] esrd-dev restart successful
- [ ] e2e 06 (HTML shell smoke) green
- [ ] e2e 07 (BEAM↔cc_mcp roundtrip) green if cc is enabled in test config
- [ ] e2e 08 (core-only admin) green
- [ ] DOM dataset cols∈[100,300] rows∈[30,100] via agent-browser (not raw chrome screenshot per refactor-lessons §6.2)
- [ ] PR description lists module renames + manifest summary + decisions made autonomously
```

---

## Bail-out criteria (per PR; same as R-series)

| Trigger | Action |
|---|---|
| `mix test` failures > 10× baseline | Revert; don't point-fix |
| Daemon won't restart | Revert |
| User-state yaml unparseable | Revert |
| BEAM crashes during `mix test` | Revert |
| DOM dataset out of range despite e2e green | Investigate xterm sizing; revert if cause not found in 30 min |
| Plugin manifest validation fails after edits | Fix manifest in same PR (it's the immediate cause) |
| Test failures appear over baseline but pass in isolation | NOT a regression — pre-existing flake from test-ordering, surfaced by file moves (refactor-lessons §三-3). Document in `docs/operations/known-flakes.md` if not already; do NOT block PR. |
| Empty xterm screenshot during DOM check | Per refactor-lessons §6.1: this means page didn't render OR tool is wrong. Don't excuse as "headless limitation". Use `agent-browser` (per memory rule §K), which captures WS-streamed content correctly. |

---

## Open questions (resolved per user 2026-05-04)

| # | Decision |
|---|---|
| PtyProcess split mechanism | **Plugin → Core**: plugin/cc directly calls PtyProcess.start_link with its own cmd args. No intermediate "PtyLauncher" module. |
| User customization layer | Separate `*.user.yaml` override files (clear boundary; merge order: core defaults → plugin1 → plugin2 → ... → user override). |
| Cap namespace prefix | **Enforced** at boot — plugin's caps must start with `<plugin_name>/`. |
| Plugin manifest format | **yaml only** (Phase 1). Phase 2 may add Elixir module variant. |
| Plan structure | **Single combined plan** organized by feature track (this doc). |

---

## Related docs

- `docs/superpowers/specs/2026-05-04-core-decoupling-design.md` (Spec A rev 3)
- `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` (Spec B rev 3)
- `docs/notes/refactor-lessons.md` — R-series + e2e lessons (apply to all plugin migrations)
- `docs/notes/structural-refactor-plan-r4-r11.md` — namespace work this builds on
- `docs/futures/todo.md` — plugin todo entry
