# Migration Plan: phased absorption (v2 — full merger)

The migration target is **complete absorption** of zchat capabilities into ESR. zchat will not run side-by-side with ESR; no compatibility constraints.

Each phase is independently shippable. The migration can stop after any phase if priorities change. Effort estimates are calendar-day rough orders of magnitude assuming one focused engineer.

Open questions per phase are tracked separately in [`06-open-questions.md`](./06-open-questions.md) — settle them before that phase starts.

## Phase summary

| Phase | Goal | Mandatory? | Est. effort |
|---|---|---|---|
| **P1** Schema unification | `routing.toml` schema replaces `workspaces.yaml` + `adapters.yaml`; runner template support | Yes | 5–7 days |
| **P2** Multiplexer adapter | `cc_zellij` adapter alongside `cc_tmux` (borrows zchat's `zellij.py` wrapper) | Yes | 5–7 days |
| **P3** Per-adapter CLI + doctor | `esr adapter <name> {list,...}` pattern + `esr doctor` + scoped agent naming | Yes | 5–7 days |
| **P4** New Python primitives | `transform / react / projection_table` MVP, side-by-side with `@handler` | Yes | 10–14 days |
| **P5** Plugin port + agent_manager | Port mode/sla/audit/csat/activation/resolve; absorb agent_manager.py shape; edit/side as adapter directives | Yes | 14–21 days |
| **P6** E2E parity | Reproduce zchat `tests/pre_release/` scenarios in ESR | Yes | 7–10 days |
| **P7** Hub plugin (optional) | Rust zellij in-pane UI port — only if CLI feedback says it's needed | No | 14–21 days |
| **P8** Distribution (optional) | Homebrew tap + install.sh + esr update | No | 5–10 days |

Total mandatory work (P1–P6): **~46–66 days** of focused engineering.

## Things explicitly **removed** from v1 plan

- ~~P3 auth (magic-link / device-flow)~~ — ESR uses CBAC + Feishu identity as the v0.3 security model. No auth phase.
- ~~Project ↔ workspace rename~~ — workspace stays per [decision ①C]. Project becomes optional aggregation view in routing.toml; not in v0.3 critical path.
- ~~zchat-hub-plugin port~~ — deferred per [decision ②C]. CLI-first; in-zellij UI re-evaluated in v0.4.
- ~~Distribution (homebrew + install.sh + update)~~ — deferred per [decision ③b]. Belongs to ESR project's broader distribution roadmap.
- ~~Kind concept in ESR Event~~ — kind is a zchat *protocol* artifact (forced by IRC PRIVMSG limitations), not a *business semantic*. edit/side are handler/adapter concerns, not framework primitives.

## P1 — Schema unification

### Goal

Replace ESR's `workspaces.yaml` + `adapters.yaml` with a single `routing.toml` modeled on zchat's V6 schema, extended with ESR-required fields. Add runner template variable substitution per zchat's `runner.py` shape.

### Deliverables

- New schema spec in `docs/superpowers/specs/<date>-routing-toml-schema.md`
- `runtime/lib/esr/routing/parser.ex` — TOML loader (use `toml_elixir` or similar)
- `runtime/lib/esr/routing/registry.ex` — replaces [`Esr.Workspaces.Registry`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/workspaces/registry.ex)
- Migration script: `workspaces.yaml + adapters.yaml → routing.toml`
- CLI: `esr routing reload` (push-based; replaces `cli:workspace/register`)
- Runner template support: `start_cmd = "claude --resume {{ tag }}"` style substitution

### Schema sketch

```toml
[bots."customer"]
adapter            = "feishu"               # references @adapter class
app_id             = "cli_..."
credential_file    = "credentials/customer.json"
default_template   = "fast-agent"
lazy_create        = true

[channels."conv-001"]
bot              = "customer"
external_chat_id = "oc_客户群A"
workspace        = "acme"                   # ESR-required reference
[channels."conv-001".workspace_overrides]   # ESR-required: per-channel overrides
cwd       = "/path/to/repo"
start_cmd = "claude --resume"
role      = "dev"
env       = { CC_LOG_LEVEL = "debug" }

[workspaces."acme"]                         # default workspace block
cwd       = "/default/path"
start_cmd = "claude {{ tag | default(\"\") }}"   # template variables
role      = "dev"
multiplexer = "zellij"                      # NEW: zellij | tmux per workspace
```

### Acceptance criteria

- [ ] All existing v0.2-channel tests pass against `routing.toml` source of truth
- [ ] `esr routing reload` triggers diff-based re-registration (additions JOIN, removals deactivate topologies)
- [ ] Migration script idempotent: running twice produces identical output
- [ ] `workspaces.yaml` + `adapters.yaml` deprecated with one-version overlap (both formats accepted, new format preferred)
- [ ] Schema validation: missing required fields produce actionable error messages
- [ ] Runner template variables (`{{ tag }}`, `{{ chat_id }}`, env vars) resolve correctly

## P2 — Multiplexer adapter (`cc_zellij`)

### Goal

Add `cc_zellij` adapter as an alternative to `cc_tmux`, parameter-compatible at the directive level. Workspace-level choice via `multiplexer = "zellij" | "tmux"`.

### Why zellij (recap from research)

- Better parallel test fixture support — `zellij action dump-screen --pane-id <id>` enables structured per-agent screenshot capture (see [`tests/pre_release/conftest.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/tests/pre_release/conftest.py))
- More predictable rendering for inspection (less escape-sequence variance vs tmux)
- zchat already operates on this model; reusing its [`zellij.py`](https://github.com/ezagent42/zchat/blob/main/zchat/cli/zellij.py) (180 LOC) wrapper code reduces work

### Deliverables

- New adapter package: `adapters/cc_zellij/` mirroring `adapters/cc_tmux/` structure
- Borrow [`zchat/cli/zellij.py`](https://github.com/ezagent42/zchat/blob/main/zchat/cli/zellij.py) wrapper functions (`ensure_session`, `new_tab`, `write_chars`, `list_panes`)
- Directives: `new_session`, `send_keys`, `kill_session`, `dump_pane` (used by E2E tests)
- Events: pane-content polling for sentinel-prefixed lines (same as tmux)
- Documentation: when to use zellij vs tmux

### Acceptance criteria

- [ ] All existing tmux-based scenarios pass with `cc_zellij` swap (parameterized at workspace level: `multiplexer = "zellij" | "tmux"`)
- [ ] `dump_pane` directive captures correct pane contents for at least one test scenario
- [ ] Both adapters can coexist in the same esrd instance (different workspaces use different multiplexers)
- [ ] `cc_zellij` survives zellij version upgrade within the same minor release

## P3 — Per-adapter CLI + doctor + naming

### Goal

Establish the per-adapter CLI surface as the **canonical replacement** for zchat's unified `zchat agent ...` commands. Plus `esr doctor` env check and `scoped_name` naming convention adoption.

### Why per-adapter (not unified `esr agent`)

zchat's agents are homogeneous (all are IRC nicks running in zellij panes), so a single `zchat agent ...` CLI is sufficient. ESR's actors are **heterogeneous**: `feishu_app_proxy` / `feishu_thread_proxy` / `cc_tmux` session / `cc_zellij` session — each has its own lifecycle shape. A single `esr agent ...` would force them into one mold and lose adapter-specific verbs (e.g., `zellij focus` doesn't apply to feishu).

### CLI pattern

```bash
esr adapter feishu list                      # list feishu instances per app_id
esr adapter cc_zellij list                   # list zellij CC sessions
esr adapter cc_zellij focus <session>        # zellij-specific verb
esr adapter cc_tmux list                     # list tmux CC sessions
esr adapter audit dump --since=1h            # audit-specific query verb
```

Each `@adapter` declares its CLI verbs:

```python
@adapter(
    name="cc_zellij",
    allowed_io={"zellij": "*"},
    cli_verbs={
        "list":   list_sessions,
        "focus":  focus_pane,
        "stop":   stop_session,
    },
)
class CCZellijAdapter:
    ...
```

ESR runtime collects all adapter CLI declarations at startup and auto-routes `esr adapter <name> <verb> [args...]` to the appropriate handler.

### Deliverables

- `py/esr/adapter.py` extension: `cli_verbs` parameter on `@adapter`
- `py/esr/cli/adapter_router.py` — runtime CLI dispatcher
- `runtime/lib/esr/cli/adapter_query.ex` — Elixir-side state query for `list` verbs
- `cc_tmux` and `cc_zellij` adapters declare CLI verbs (P2 dependency)
- `feishu` adapter declares `list` verb (returns per-app status)
- New `esr doctor` command — parallel to [`zchat/cli/doctor.py`](https://github.com/ezagent42/zchat/blob/main/zchat/cli/doctor.py); checks Erlang/Elixir/Python/zellij/Feishu credential paths
- Adopt `scoped_name(name, username)` from [`zchat-protocol/naming.py`](https://github.com/ezagent42/zchat-protocol/blob/refactor/v4/zchat_protocol/naming.py) for agent identifier display

### Acceptance criteria

- [ ] `esr adapter <name>` listing for all built-in adapters returns structured JSON + table view
- [ ] Adapter-specific verbs (e.g., `cc_zellij focus`) work end-to-end
- [ ] `esr doctor` returns non-zero exit on missing dependency, prints actionable diagnostic
- [ ] Agent IDs in CLI output use `scoped_name` format (`<user>-<agent>`)

## P4 — New Python primitives (MVP)

### Goal

Land `@adapter / projection_table / transform / react` as the new Python SDK surface. Coexists with existing `@handler / @handler_state` during P5 migration.

### Deliverables

- `py/esr/primitives.py` — public API: `transform`, `react`, `projection_table`, `Project`, `Emit`, `Route`, `InvokeCommand`, `Ctx`
- `py/esr/runtime/dispatcher.py` — Python-side: walks transform chain, dispatches to matching reacts, sends actions to Elixir runtime via existing PubSub envelope
- `runtime/lib/esr/projections/registry.ex` — Elixir-side: GenServer + named ETS tables; applies `Project` actions
- `runtime/lib/esr/dispatcher.ex` — Elixir-side: drives the transform/react cycle by consuming events from adapters and pushing via PubSub envelope to Python workers
- Pattern compiler: declarative `pattern={...}` → fast match function
- Tests:
  - Unit: each primitive in isolation (~50 tests)
  - Integration: end-to-end `/hijack` flow in a test esrd
  - Property: transform chain associativity; react fan-out independence

### Coexistence rule

- Existing `@handler(actor_type=...)` modules continue to work unchanged
- New modules use `react(...)`
- A single esrd instance can host both styles
- P5 migrates existing handlers one at a time

### Acceptance criteria

- [ ] `/hijack` example from [04-target-design.md §6](./04-target-design.md#6-worked-example-hijack-channel-mode) runs end-to-end
- [ ] `/new-session` example from [04-target-design.md §7](./04-target-design.md#7-worked-example-new-session-with-topology-delegation) runs end-to-end (uses `InvokeCommand` bridge)
- [ ] Existing v0.2 handler modules continue to work without modification
- [ ] Pattern matching benchmarks: ≥10k events/sec on a single dispatcher process with 100 registered patterns

## P5 — Plugin port + agent_manager + edit/side

### Goal

Port `mode / audit / sla / csat / activation / resolve` plugins from zchat to ESR using the new primitives. Absorb `agent_manager.py` shape into per-adapter CLI + topology patterns. Implement edit/side as adapter directives (not protocol kinds).

### Per-plugin migration plan

#### `mode` (copilot/takeover)

- **Source:** [`src/plugins/mode/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/mode/plugin.py)
- **Target:** `handlers/channel_mode/` (new package, see [`04-target-design.md §6`](./04-target-design.md#6-worked-example-hijack-channel-mode))
- **Effort:** 1–2 days

#### `audit` (conversation logging)

- **Source:** `src/plugins/audit/plugin.py`
- **Target:** New `adapters/audit/` writing to SQLite + react that subscribes to all events
- **Why adapter not pure react:** writing to SQLite is impure I/O — adapter is the right layer
- **Effort:** 3–5 days

#### `sla` (takeover-timeout, help-timeout)

- **Source:** [`src/plugins/sla/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/sla/plugin.py)
- **Target:** `handlers/sla/` — react on `mode_changed` event spawns a topology with a timer; topology emits `sla_breach` when timer fires; another react handles the breach
- **Why topology not pure react:** timers are stateful long-running things; topology supervision handles cleanup on cancellation
- **Effort:** 5–7 days

#### `csat` (resolution survey)

- **Source:** `src/plugins/csat/plugin.py`
- **Target:** `handlers/csat/` — react on `channel_resolved` event triggers a `csat-survey` topology
- **Effort:** 3–5 days

#### `activation` + `resolve` (lifecycle)

- Same pattern as csat; lifecycle hooks via reacts that emit topology invocations
- **Effort:** 2–3 days each

### Migration of v0.2-channel handlers

| Old | New |
|---|---|
| [`feishu_app_proxy/on_msg.py`](https://github.com/ezagent42/esr/blob/v0.2-channel/handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py) | Split into multiple reacts (one per command, one for default routing) |
| [`feishu_thread_proxy/on_msg.py`](https://github.com/ezagent42/esr/blob/v0.2-channel/handlers/feishu_thread/src/esr_handler_feishu_thread/on_msg.py) | react with `reads=["channel_modes", "threads"]` |
| `FeishuAppState.active_thread_by_chat` | `projection_table("active_threads", ...)` |
| `FeishuThreadState.dedup` | `projection_table("dedup_seen", default=frozenset)` |
| `FeishuAppState.bound_threads` | `projection_table("bound_threads", default=frozenset)` |

### agent_manager.py absorption

[`zchat/cli/agent_manager.py`](https://github.com/ezagent42/zchat/blob/main/zchat/cli/agent_manager.py) (370 LOC) provides agent CRUD over zellij tabs + state file. The ESR equivalent is split:

| zchat agent_manager.py | ESR equivalent |
|---|---|
| `create()` — spawn agent in zellij tab | `InvokeCommand(name="agent-spawn", ...)` → topology that calls `cc_zellij.new_session` |
| `list()` — read state JSON + check IRC presence | `esr adapter cc_zellij list` (P3) — queries SessionRegistry + zellij list-panes |
| `stop(name)` — send kill + remove from state | `esr adapter cc_zellij stop <name>` → topology deactivation |
| `restart(name)` — stop + create | composition of above |
| `send(name, msg)` — IRC PRIVMSG to agent's nick | **N/A** in ESR (no IRC); replaced by `Route(target="thread:<tag>", msg=...)` action |
| State file `~/.local/state/zchat/agents.json` | ETS-backed `SessionRegistry` (already in ESR) |

### edit/side as business semantics (not protocol kinds)

| zchat | ESR equivalent |
|---|---|
| `__edit:<uuid>:<text>` IRC prefix | `Emit("feishu", "edit_message", {message_id, content})` action — handler decides; adapter knows the Feishu API |
| `__side:<text>` IRC prefix (operator-only) | Two options: (a) `Emit("feishu", "send_message", {chat_id, content, visibility="operator_only"})` if Feishu API supports per-message visibility; (b) separate sink `Emit("feishu_operator", "send_message", ...)` to a dedicated operator chat |

Decide between (a) and (b) during P5 based on actual Feishu API capability.

### Acceptance criteria

- [ ] All zchat plugin scenarios reproduce in ESR (operator hijack, SLA breach, CSAT round-trip)
- [ ] v0.2-channel acceptance suite still passes after handler migration
- [ ] No `@handler(actor_type=...)` references remain in `handlers/` (only Layer 4 topologies retain actor concepts)
- [ ] Total LOC reduction: existing handlers should shrink ≥30 % on average after migration
- [ ] `esr adapter cc_zellij {list,create,stop,restart}` works end-to-end (replaces `zchat agent` UX)
- [ ] Edit a previously-sent Feishu message via handler action
- [ ] Operator-side message visible only to operator chat (per the chosen approach)

## P6 — E2E parity verification

### Goal

Reproduce zchat's pre-release scenarios in ESR. This phase doesn't add features; it validates the migration is complete.

### Deliverables

- E2E scenario suite mirroring [`tests/pre_release/test_feishu_e2e.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/tests/pre_release/test_feishu_e2e.py):
  - Customer onboarding (#01)
  - Squad card notification (#02)
  - Placeholder edit (#03)
  - Auto-hijack on SLA breach (#04)
  - Operator message reaches customer (#05)
  - Side message not in customer chat (#06)
  - Resolve + CSAT (#07)
  - Admin status / dispatch / review (#08)
  - SLA breach explicit trigger (#09)
- Per-scenario evidence capture (zellij `dump_pane`-based, parallel to zchat's `capture_zellij_screenshot`)
- Telemetry comparison: ESR vs zchat behavior trace on same input

### Acceptance criteria

- [ ] All 9 zchat scenarios pass in ESR with equivalent behavior
- [ ] Evidence dumps captured for each scenario
- [ ] No regression in existing v0.2-channel acceptance suite

## P7 — Hub plugin (optional)

Skip unless P6 feedback indicates in-zellij UI is required. Per [decision ②C], CLI-first for v0.3.

If needed:

- Rust workspace under `runtime/priv/zellij_plugins/` (or separate repo)
- Port [`zchat-hub-plugin/zchat-palette`](https://github.com/ezagent42/zchat/tree/main/zchat-hub-plugin/zchat-palette) verbatim, retarget to ESR projection state
- Port [`zchat-hub-plugin/zchat-status`](https://github.com/ezagent42/zchat/tree/main/zchat-hub-plugin/zchat-status) similarly

## P8 — Distribution (optional)

Per [decision ③b], deferred to v0.4+. Not part of v0.3 critical path.

If needed:

- Homebrew tap `ezagent42/esr/esr`
- `install.sh` one-liner
- `esr update` (release / main channels) per [`zchat/cli/update.py`](https://github.com/ezagent42/zchat/blob/main/zchat/cli/update.py) shape

## Cross-cutting risks

| Risk | Mitigation |
|---|---|
| Pattern matcher becomes hot-path bottleneck at scale | Benchmark in P4; optimize via compiled-pattern lookup tables if needed |
| Coexistence of `@handler` and `react` confuses contributors | Document clearly in CHANGELOG; deprecation warnings on `@handler` after P5 lands |
| Projection schema sprawl (every team adds tables) | Require `projection_table` registration in central manifest in P5; CI fails on unregistered tables |
| Per-adapter CLI verb conflicts (e.g., two adapters both define `list` differently) | Namespace by adapter name (`esr adapter <name> <verb>`); no global verb registry |
| zellij CLI version drift breaks `cc_zellij` adapter | Pin minimum version; smoke-test against pinned version in CI |
| Migration of existing handlers introduces subtle behavior changes | Per-handler scenario test before and after rewrite must be byte-identical on event traces |
| edit/side Feishu API limitations force operator-channel approach (option b) | Acceptable fallback; document; surface in P5 retrospective |

## Decision points

After each phase, reassess:

- **After P1:** Is the routing.toml schema actually clearer than the yaml split? Survey contributors.
- **After P3:** Is per-adapter CLI ergonomic, or do operators ask for unified `esr agent`?
- **After P4:** Are the new primitives ergonomic enough? Try porting one plugin (mode) before committing to P5.
- **After P5:** Did handler LOC actually shrink? If not, the new primitives may not be earning their complexity.
- **After P6:** Does P7 (hub plugin) get user pull? Or is CLI sufficient long-term?
- **Before P8:** Real demand for self-update / Homebrew?

## What "done" looks like for v0.3

- A new contributor can add a channel-scoped feature (e.g., `/lock_audio`) in <100 LOC, ~1 day of work, by reading [`04-target-design.md`](./04-target-design.md) and following the `/hijack` example
- ESR + zellij can serve a Feishu-driven multi-customer-thread scenario equivalent to zchat's [`tests/pre_release/test_feishu_e2e.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/tests/pre_release/test_feishu_e2e.py)
- All zchat plugin behaviors (mode, sla, audit, csat) reproducible in ESR
- All zchat agent CRUD behaviors covered by `esr adapter <name> ...` CLI
- No IRC dependency in production runtime
- Security model: CBAC + Feishu identity (no auth module)

## Out of scope (explicit anti-goals)

- Full ESR Protocol v0.3 §10.1 conformance (`contract_declaration` + `static_verification`) — those land in a separate spec
- Multi-node BEAM cluster (deferred to ESR v0.4+)
- Replacing `cc-openclaw` in production (this work creates the *substrate* that could replace it later)
- zchat coexistence — zchat will be retired after migration completes; no compatibility constraints
