# Phase 3 — Plugin physical migration (feishu + claude_code)

**Date:** 2026-05-05
**Status:** Draft for user review.
**Predecessor:** Phase 2 (`docs/superpowers/specs/2026-05-05-slash-cli-repl-elixir-native.md`) establishes the slash/CLI/REPL contract this phase consumes.
**Successor:** Phase 4 cleanup (`docs/superpowers/specs/2026-05-05-phase-4-cleanup.md`) deletes stubs.

---

## 一、Why this phase exists

PR-180 (Phase 1, 2026-05-04) shipped the plugin **mechanism**: Loader, Manifest parser, FragmentMerger, plugins.yaml runtime config, 5 admin commands, three stub manifests for `voice` / `feishu` / `claude_code`. The stubs **declare** modules and python sidecars but the modules themselves still live under `runtime/lib/esr/entity/` and `py/src/`.

Phase 3 physically moves the modules. After Phase 3:

- `runtime/lib/esr/plugins/feishu/` contains all FAA / FCP / FAP Elixir code + python `feishu_adapter_runner` + `agents.yaml` fragments + slash routes.
- `runtime/lib/esr/plugins/claude_code/` contains all CCProcess / CCProxy + python `cc_adapter_runner` (or its successor; see §三 Channel abstraction) + `agents.yaml` fragments.
- `Esr.Application.start/2`'s feishu / cc-specific bootstraps move into plugin-startup code.
- Core no longer references `Esr.Entity.FCP`, `Esr.Entity.CCProcess`, etc. — those names live only inside their plugin dirs.

Voice deletion already happens in Phase 2 PR-2.0; we never used voice and the inventory shows ~3000 LOC of dead Python sitting around it. Phase 3 only handles `feishu` and `claude_code`.

### Goals

1. `feishu` and `claude_code` are physically extracted; core compiles and boots without them when `enabled_plugins: []`.
2. `cc` agent's `agents.yaml` definition no longer hardcodes `feishu_chat_proxy` in its inbound pipeline. The agent_def is platform-agnostic; the platform-specific inbound proxy is **injected by Scope.Router at session_new time** based on the originating chat's platform.
3. `Esr.Entity.CCProcess` no longer hardcodes the string `"feishu"` (today: `Topology.adapter_uri("feishu", app_id)`). Adapter type comes from `proxy_ctx`.
4. `cc_mcp` decoupled from `claude` / `tmux` lifecycle — survives a claude crash without losing its `cli:channel/<sid>` subscription. (Issue 02 from `docs/issues/`.)
5. **Channel abstraction**: a per-session core peer that owns the esr-channel transport, supervised by BEAM, independent of any specific MCP server implementation. Cc plugin's cc_mcp becomes an HTTP MCP server addressable via the channel peer's port allocation; future agent plugins (codex / gemini-cli) reuse the same channel mechanism.
6. Core/plugin boundaries audited and documented: a clean list of "what's in core" (PtyProcess, Channel, Agent metamodel, SlashHandler, etc.) vs "what's in plugins" (platform adapters, agent-specific MCP servers, agent process pipelines).

### Non-goals

- New plugins (e.g. telegram, codex) — the goal is to migrate **existing** functionality cleanly so adding new plugins becomes straightforward, not to add them.
- Hot-load (Phase-2 spec non-goal still holds).
- Reworking auth (Phase 2 carries the existing model forward).

---

## 二、Architecture after Phase 3

### Module placement

```
runtime/lib/esr/                 ← CORE (after Phase 3)
  application.ex                 ← still boots; no plugin-specific logic
  entity/
    server.ex                    ← Entity primitive
    stateful.ex                  ← Stateful behaviour
    pty_process.ex               ← STAYS in core (generic PTY mechanism)
    channel.ex                   ← NEW: per-session esr-channel peer (replaces ad-hoc subscribe)
    factory.ex
    registry.ex
    agent/registry.ex            ← agents.yaml metamodel registry
    user/...                     ← User Entity subtype
    capguard.ex                  ← (current; stays unless extracted to Resource)
    slash_handler.ex             ← single dispatch entry (per Phase 2)
  scope/
    router.ex                    ← gains "platform proxy injection" (see §三)
    admin.ex
    process.ex
  resource/
    capability/
    permission/
    sidecar/registry.ex          ← still core: plugins write into it via Loader
    slash_route/
    chat_scope/
    workspace/
  plugin/
    loader.ex
    manifest.ex
    enabled_list.ex
    plugins_yaml.ex
  plugins/                       ← plugin code lives here (Phase 1's plugins/)
    feishu/
      manifest.yaml
      lib/
        app_adapter.ex           ← Esr.Plugins.Feishu.AppAdapter (was Esr.Entity.FeishuAppAdapter)
        chat_proxy.ex            ← Esr.Plugins.Feishu.ChatProxy
        app_proxy.ex             ← Esr.Plugins.Feishu.AppProxy
      priv/
        agents-fragment.yaml     ← cc-feishu binding: declares feishu as inbound proxy class
        slash-routes-fragment.yaml ← any feishu-specific slashes (currently none, but the seam exists)
      python/
        feishu_adapter_runner/   ← (relocated from py/src/feishu_adapter_runner/)
      test/
        ...
    claude_code/
      manifest.yaml
      lib/
        cc_process.ex            ← Esr.Plugins.ClaudeCode.CCProcess
        cc_proxy.ex
        cc_mcp_process.ex        ← NEW: BEAM-supervised cc_mcp HTTP server (issue 02)
      priv/
        agents-fragment.yaml     ← cc agent_def (platform-agnostic; inbound proxy injected at runtime)
      python/
        cc_adapter_runner/       ← (relocated from py/src/cc_adapter_runner/)
        cc_mcp/                  ← (relocated from py/src/cc_mcp/, now HTTP-mode)
        esr-cc.sh                ← (relocated from runtime-side scripts/esr-cc.sh)
      test/
        ...
```

`Esr.Entity.FeishuAppAdapter` is renamed to `Esr.Plugins.Feishu.AppAdapter` etc. The git mv preserves history; module-name updates are mechanical.

### Channel abstraction

Per `docs/issues/02-cc-mcp-decouple-from-claude.md` (still open as of 2026-05-05). The current model — clarified by review against actual code:

```
session = FCP + CCProcess + PtyProcess     ← all BEAM peers
                            ↓
                          claude binary
                            ↓
                          cc_mcp (Python, parented by claude via stdio MCP)
                            ↓
                          subscribes to cli:channel/<sid> via WebSocket
                            (adapters/cc_mcp/src/esr_cc_mcp/ws_client.py)
```

The subscription lives in **Python cc_mcp's WebSocket client**, NOT in any BEAM peer (review caught the original framing). `Esr.Entity.CCProcess` *broadcasts* to that topic; nobody on the BEAM side subscribes to it (the channel/server bridge in BEAM forwards from the topic out via the WebSocket transport).

So when tmux/claude dies, cc_mcp dies, **cc_mcp's WebSocket dies, and the BEAM-side topic still exists but loses its only consumer** — every subsequent broadcast hits an empty topic and is silently dropped.

After Phase 3:

```
session (BEAM-supervised peers):
  + FCP / CCProxy / CCProcess / PtyProcess        ← existing
  + Channel               ← NEW: per-session core peer; owns cli:channel/<sid> subscription;
                            allocates an HTTP port; routes notifications → MCP server
  + CCMcpProcess          ← plugin-specific; HTTP MCP server (Python),
                            spawned via OSProcess; restartable; lifecycle independent of claude
                            
  esr-cc.sh writes .mcp.json: { mcpServers: { "esr-channel": {type: "http", url: "http://127.0.0.1:<port>" } } }
                            ↓
  claude binary             ← consumes MCP via HTTP
                            ↓
  HTTP requests             → CCMcpProcess → forwards to / from Channel peer
```

`Esr.Entity.Channel` is **core**. It exposes:

- `notify(sid, envelope)` — broadcasts a notification to whatever MCP server is currently bound.
- `register_mcp_server(sid, port)` — plugin's MCP-server peer registers its HTTP port.
- `tool_invoke_callback(sid, fn)` — plugin's MCP server registers a callback for inbound tool invokes from claude (or any other agent backend).

Plugin's MCP-server peer (e.g. cc plugin's `CCMcpProcess`) talks **only to Channel**, not to PubSub directly. Future plugins (codex_mcp / gemini_mcp) implement the same shape — they get their port from BEAM, register with their session's Channel peer, expose the MCP wire format their agent backend expects.

This decouples:
- BEAM-side notification routing (Channel) from MCP wire format (per-plugin).
- Subscription lifetime (Channel, BEAM-supervised) from agent process lifetime (cc_mcp / claude / pty, plugin- or OS-managed).
- Multi-agent type support: one Channel impl, many MCP-server impls.

### agents.yaml decoupling

Today:

```yaml
agents:
  cc:
    pipeline:
      inbound:
        - feishu_chat_proxy   ← hardcoded to feishu
        - cc_proxy
        - cc_process
        - pty_process
```

After Phase 3:

```yaml
agents:
  cc:
    pipeline:
      inbound:
        - cc_proxy
        - cc_process
        - pty_process
    requires_platform_proxy: true   ← AgentSpawner prepends platform proxy at spawn time
```

#### Where the injection actually happens

Subagent review caught that the original draft put injection in `Esr.Scope.Router`, but **Router doesn't compose pipelines post-R6** — `Esr.Session.AgentSpawner` does. Specifically:

1. `Esr.Entity.Agent.Registry.compile_agent/1` (`runtime/lib/esr/entity/agent/registry.ex:139`) parses `agents.yaml` and today ignores unknown keys. **Schema gain in PR-3.0**: parse `requires_platform_proxy: true` and surface it on the compiled agent_def.
2. `Esr.Session.AgentSpawner.spawn_pipeline/3` (`agent_spawner.ex:289`) builds the inbound pipeline. **Spawn-time logic gain in PR-3.5**: when `agent_def.requires_platform_proxy == true`, look up the platform from spawn `params[:source_platform]` (threaded by Scope.Router from the originating chat envelope) and prepend the resolved proxy module.
3. The platform-proxy lookup goes through a new registry (see "Platform-proxy registry" below).

#### Platform-proxy registry placement

Original draft proposed `Esr.Resource.PlatformProxy.Registry`. Subagent review caught this fails the True-Resource criterion (`docs/notes/structural-refactor-plan-r4-r11.md:34`: "consumed by ≥2 Entity types"). Platform-proxy lookup is consumed only by `Esr.Session.AgentSpawner` — a Pipeline-tier coordinator, not an Entity type.

**Better home**: `Esr.Entity.Agent.PlatformProxyRegistry` — sits next to `Esr.Entity.Agent.Registry` (the agents.yaml registry). Same consumer (the agent compilation/spawn path), same lifecycle (boot-loaded from plugin manifests). Mirrors how `Esr.Entity.User.Registry` lives next to user-related concerns.

```elixir
Esr.Entity.Agent.PlatformProxyRegistry.register("feishu", Esr.Plugins.Feishu.ChatProxy)
Esr.Entity.Agent.PlatformProxyRegistry.lookup("feishu") # → Esr.Plugins.Feishu.ChatProxy
```

Plugin manifest grows a new `platform_proxies:` declaration. Phase-1 `Esr.Plugin.Manifest.atomize_declares/1` (`runtime/lib/esr/plugin/manifest.ex:139`) accepts arbitrary `declares:` keys without parser changes — the new key is genuinely zero-cost on the parse side.

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  platform_proxies:
    - platform: feishu
      module: Esr.Plugins.Feishu.ChatProxy
```

Plugin Loader's `start_plugin/2` (Phase-1) gains a `register_platform_proxies/1` step (mirrors the existing `register_python_sidecars/1` and `register_capabilities/2`).

#### Silent-fail guard

Subagent review caught a dangerous existing failure mode: `AgentSpawner.spawn_pipeline/3`'s `resolve_impl/1` uses `String.to_existing_atom/1` which returns nil on miss; `spawn_one` then "swallows silently" (`agent_spawner.ex:447-453`). A test fixture or operator yaml referencing a renamed module compiles + tests pass + production silently spawns an empty pipeline.

**Mitigation in PR-3.2**: `resolve_impl/1` raises (or logs FATAL) on unknown impl. Pre-merge gate adds a grep over fixture yaml files asserting every `impl:` resolves to a known module. CI gate prevents the silent-fail from becoming a production bug during the renaming phases.

### CCProcess hardcoding fix — multi-site, not single-site

Subagent review (2026-05-05) caught the original draft was wrong about scope. There are **at least four** sites in `cc_process.ex` that hardcode "feishu":

1. **Line 131**: `Topology.adapter_uri("feishu", app_id)` in `build_initial_reachable_set` — adapter URI hardcoded.
2. **Line 374**: `Keyword.get(state.neighbors, :feishu_chat_proxy)` — neighbor key hardcoded; `dispatch_action(:reply)` routes preferentially through this.
3. **Line 385**: warning log text mentions `feishu_chat_proxy` — cosmetic but indicates the design assumption.
4. **Line 450**: `"source" => Map.get(ctx, "channel_adapter") || "feishu"` — fallback default to feishu.

And **at least three more sites** outside `cc_process.ex`:
- `Esr.Scope.Router` (line ~259) and `Esr.Resource.ChatScope.Registry`'s `refs` shape — both encode `feishu_chat_proxy` neighbor name in the wire shape.
- `Esr.Session.AgentSpawner.backwire_neighbors` (`runtime/lib/esr/session/agent_spawner.ex:343-389`) wires neighbors by literal atom names like `:feishu_chat_proxy`.
- `EsrWeb.CliChannel` (lines 319, 343, 394, 408) calls `bootstrap_feishu_app_adapters` / `terminate_feishu_app_adapter`.
- `Esr.Admin.Commands.Notify` (line 70) matches on `"feishu_app_adapter_" <> app_id` registry key prefix.
- `Esr.Topology` (line 32) host-string matching.

**Fix surface is multi-module**, not local to CCProcess. The right shape:

- Replace neighbor key `:feishu_chat_proxy` with **role-based key** `:platform_chat_proxy` (or look up by role at the neighbor list, similar to today's `Keyword.get/2` but on a role tag stored in the spec).
- `proxy_ctx` gains `adapter_type` and `platform` fields, threaded by AgentSpawner from the spawn-time params (which carry chat origin via `params[:source_platform]`).
- CCProcess uses `state.proxy_ctx.adapter_type` for `Topology.adapter_uri/2`, falls back to `"unknown"`.
- Notify and CliChannel callers get a generic `"<platform>_app_adapter_" <> app_id` template — but those are FAA-specific paths and stay tied to the feishu plugin (just renamed when the modules move).
- An audit grep `feishu_chat_proxy` / `feishu_app_adapter` is added to PR-3.2's gate so no silent mismatches survive.

This is much bigger than a single-module fix. It's still a single PR (PR-3.2) but the diff touches 5+ files + several test fixtures.

---

## 三、Migration order (PR sequence)

| PR | Scope | Test gate |
|---|---|---|
| **PR-3.0** | `Esr.Resource.PlatformProxy.Registry` (~50 LOC) + Loader's `register_platform_proxies/1` step + manifest schema gains `platform_proxies:`. No behaviour change yet — registry is empty. | unit tests for registry register/lookup |
| **PR-3.1** | `Esr.Entity.Channel` core peer (~150 LOC). Owns `cli:channel/<sid>` subscription; exposes `notify` / `register_mcp_server` / `tool_invoke_callback`. **No plugin yet uses it** — current cc_mcp stays stdio. | unit tests for Channel peer |
| **PR-3.2** | Fix `CCProcess` hardcoded `"feishu"`. `proxy_ctx` gains `adapter_type` field threaded from Scope.Router. | scenario 01/07 still green; new unit test for proxy_ctx threading |
| **PR-3.3** | Move feishu Elixir modules: `runtime/lib/esr/entity/feishu_*.ex` → `runtime/lib/esr/plugins/feishu/lib/`. Module names updated. Manifest's `entities:` declarations updated. Plugin's `priv/agents-fragment.yaml` declares feishu as a `platform_proxies` provider. | scenario 01/07 green |
| **PR-3.4** | Move feishu Python: `py/src/feishu_adapter_runner/` → `runtime/lib/esr/plugins/feishu/python/feishu_adapter_runner/`. Update all sidecar registry references. | sidecar test + scenario 07 green |
| **PR-3.5** | Decouple `agents.yaml`: cc agent's `inbound` no longer hardcodes `feishu_chat_proxy`. Scope.Router injects platform proxy from registry at spawn time. | scenario 01/07 green |
| **PR-3.6** | Move cc Elixir: `runtime/lib/esr/entity/cc_*.ex` → `runtime/lib/esr/plugins/claude_code/lib/`. Module names updated. **Order swapped from earlier draft per review** — Elixir move BEFORE HTTP cc_mcp, so HTTP server is born in its final namespace home. Diff geography is cleaner. | scenario 01/07 green |
| **PR-3.7** | New `Esr.Plugins.ClaudeCode.CCMcpProcess` (BEAM-supervised OSProcess; HTTP MCP server). cc_mcp Python switches to HTTP transport. esr-cc.sh writes the `.mcp.json` with `type: "http"` + the BEAM-allocated port. **Prerequisite: an Issue 02 decision pass (Q1 port publishing, Q3 HTTP transport feature parity esp. streaming, Q4 auth token) must complete BEFORE PR-3.7's diff is opened** — these decisions shape the interface. Recommend: drop a 1-page ADR / decision note into `docs/issues/02-cc-mcp-decouple-from-claude.md` resolving Q1, Q3, Q4 before PR-3.7 starts. | scenario 07 + new "kill claude, verify cc_mcp survives, next inbound reaches restarted claude" e2e at `tests/e2e/scenarios/12_cc_mcp_survives_claude_crash.sh` |
| **PR-3.8** | Move cc Python: `py/src/cc_adapter_runner/`, `adapters/cc_mcp/` → `runtime/lib/esr/plugins/claude_code/python/`. esr-cc.sh moves into plugin too. The `agents.yaml` `proxies:` block (currently `target: "admin::feishu_app_adapter_${app_id}"`) is generalized to use `${platform}_app_adapter_${app_id}` template — addresses the feishu-shaped seam in `agent_spawner.ex:472`'s `build_ctx` for FeishuAppProxy. | sidecar test + scenario 07 green |
| **PR-3.9** | `Esr.Application.start/2` cleanup: remove the feishu / cc fallback registrations (Phase 1 added them as a transition aid). After Phase 3, plugin manifests register everything; the fallbacks are vestigial. | full unit suite + scenario 01/07/08/11 |

PRs are mostly sequential. PR-3.0 / 3.1 / 3.2 are independent and can ship before 3.3. Within feishu (3.3 + 3.4) and within cc (3.6 + 3.7 + 3.8) there's tight ordering.

---

## 四、Risks & mitigations

### Module rename blast radius

`Esr.Entity.FeishuAppAdapter` → `Esr.Plugins.Feishu.AppAdapter` is mechanical but the references are scattered across multiple file types. Subagent review enumerated the concrete touch list:

- **Tests**: 6+ integration tests with `alias Esr.Entity.FeishuAppAdapter` / `FeishuChatProxy` (e.g., `runtime/test/esr/integration/cc_e2e_test.exs:116`, `feishu_react_lifecycle_test.exs:34-35`).
- **Fixtures**: 3 yaml files reference old module strings via `impl:` — `runtime/test/esr/fixtures/agents/{simple,voice,multi_app}.yaml`. These are atom-ified by `String.to_existing_atom/1` — silent miss returns `nil`, which `spawn_one` skips silently (`agent_spawner.ex:447-453`). **A fixture not updated will pass test compilation but silently spawn an empty pipeline.**
- **Documentation**: `runtime/test/esr/fixtures/agents/README.md` documents old names.
- **Cross-namespace callers**: `runtime/lib/esr_web/cli_channel.ex:319,343,394,408` calls `bootstrap_feishu_app_adapters` / `terminate_feishu_app_adapter`; `runtime/lib/esr/admin/commands/notify.ex:70` matches on `"feishu_app_adapter_" <> app_id` registry key prefix; `runtime/lib/esr/topology.ex:32` host-string matching.

**Mitigation**:

1. Use the same approach as R1-R3 mechanical renames (2026-05-04): single-rename-per-PR, full-suite green per PR.
2. Module renames are **namespace-tier** — explicit `alias Esr.Plugins.Feishu.AppAdapter` at every callsite, NOT alias collapse (R3v1 "cascade" failure mode: 118 tests broken from over-aggressive collapse).
3. **Add a CI guard** at PR-3.2 (and re-asserted in PR-3.3, PR-3.7): grep all `runtime/test/esr/fixtures/**.yaml` for `impl:` strings, assert each resolves to a known module via `Code.ensure_loaded?`. Fail the PR if any fixture references a renamed-but-not-updated module. Closes the silent-`nil`-impl path.

### CCMcpProcess HTTP transport correctness

claude's MCP HTTP transport (`type: "http"` in `.mcp.json`) needs a verified compatibility matrix with cc_mcp's tool surface (reply, send_file, react, etc.). Most MCP features work over HTTP equivalently to stdio, but **streaming** semantics differ. Pre-PR-3.6, write a smoke test: stand up a no-op HTTP MCP server, point claude at it, verify tool invocations round-trip. If a feature breaks, fall back to per-feature audit before continuing.

### Operator-facing slash commands

Slash commands today (`/notify`, `/end-session`, etc.) might land on FCP and call into Esr.Entity.SlashHandler — those routes get module-renamed. Phase 2's schema-driven dispatcher absorbs the rename: slash-routes.yaml's `command_module:` field gets the new name, no slash-text change for the operator.

### .mcp.json port lifecycle

`CCMcpProcess` needs to publish its HTTP port BEFORE `esr-cc.sh` runs (esr-cc.sh writes the `.mcp.json` claude reads). The race is real: `CCMcpProcess.init/1` binds + writes port to `Esr.Entity.Registry`; `PtyProcess.os_env` reads from registry; but `os_env` is called inside `OSProcess.init/1` which has its own race with `CCMcpProcess.init/1`.

Mitigation: `CCMcpProcess` is a `:start_link` neighbor of `PtyProcess` declared **earlier** in the agent pipeline. The agent's spawn_args wiring guarantees declaration order; `Entity.Factory.spawn_peer/5` honors it. Add an integration test that starts a session, dumps `os_env`, asserts `ESR_CC_MCP_PORT` is present and points to a live port.

### Auth-less localhost binding

cc_mcp HTTP server binds 127.0.0.1:<port>. Anyone on the host can hit it. Today's stdio model has implicit auth (claude is the only stdio peer). HTTP needs a shared secret OR strict localhost-only check.

Mitigation: a per-session token generated by `CCMcpProcess.init/1` and passed both to claude (via .mcp.json `headers: {"X-Esr-Token": "<token>"}`) and to the HTTP server (env var). Server rejects requests without the matching header. ~30 LOC; common pattern.

### Rollback plan

Each PR is independently reverted via `git revert`. PR-3.6 (HTTP MCP) is the only one that's hard to roll back partially because cc_mcp's stdio path gets rewritten — so PR-3.6 keeps the stdio path commented out (not deleted) until PR-3.9 cleanup.

---

## 五、Out of scope

- Phase 2 deliverables (slash/CLI/REPL unification) — separate spec.
- Hot-load of plugins.
- New plugin types (telegram, codex, etc.).
- Distribution / mix release packaging — Phase 4 cleanup.
- `docs/issues/02`'s discussion of session_ids.yaml write side (claude --resume) — orthogonal to lifecycle decoupling, defer.

---

## 六、Open questions

1. **`platform_proxy` placement** — is a top-level Resource (`Esr.Resource.PlatformProxy.Registry`) the right home, or should it live under `Esr.Scope.Router` since only Router consumes it? Recommend Resource (matches Sidecar.Registry pattern, allows future consumers).
2. **CCMcpProcess port allocation strategy** — bind ephemeral (let kernel pick, capture from getsockname) vs deterministic (hash session_id mod 10000+). Recommend ephemeral; simpler and avoids collisions.
3. **`Esr.Entity.PtyProcess` placement** — stays in core per Phase 1 spec, but is it really "shared" or just "happens to be used by cc"? If only cc uses PtyProcess, it should move into the cc plugin. **Decision needed**: is "shell" agent (bash PTY only, no claude) a real use case we want to support? If yes, PtyProcess stays in core. If no, it moves into cc plugin. Current state: `tools/esr-debug` evidence run used it directly, so non-cc PTY usage exists at minimum for diagnostics.
4. **Channel peer naming** — `Esr.Entity.Channel` reads as too generic. Alternatives: `Esr.Entity.AgentChannel`, `Esr.Entity.EsrChannel`, `Esr.Channel`. Recommend `Esr.Entity.Channel` for now; the metamodel-tier name is fine because the implementation is generic across agent plugins.
5. **`bootstrap_voice_pools/1`** — voice deletion is Phase 2 PR-2.0's scope. Phase 3 PR-3.9 just verifies it's gone, doesn't re-do it.

6. **PtyProcess placement** — STAYS in core. Confirmed by audit: PtyProcess is consumed by `EsrWeb.PtySocket` (line 75, 85), `EsrWeb.DebugController.pty_send/2`, `Esr.Entity.FeishuChatProxy.boot_bridge`, `Esr.Entity.CCProcess`, AND `tools/esr-debug` (`esr-debug send-keys` operator surface). Multi-consumer; meets the True-Resource criterion as a generic mechanism. Open Question §六-3 resolved here.
