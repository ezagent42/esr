# Migration Plan: A3 Phased Absorption

Each phase is independently shippable. The migration can stop after any phase if priorities change. Effort estimates are calendar-day rough orders of magnitude assuming one focused engineer.

Open questions per phase are tracked separately in [`06-open-questions.md`](./06-open-questions.md) — settle them before that phase starts.

## Phase summary

| Phase | Goal | Mandatory? | Est. effort |
|---|---|---|---|
| **P1** Schema unification | `routing.toml` schema replaces `workspaces.yaml` + `adapters.yaml` | Yes | 3–5 days |
| **P2** Multiplexer adapter | Add `cc_zellij` adapter alongside `cc_tmux` | Yes | 5–7 days |
| **P3** Auth module | magic-link / device-flow Phoenix Channel auth | Yes | 7–10 days |
| **P4** New Python primitives | `transform / react / projection_table` MVP, side-by-side with `@handler` | Yes | 10–14 days |
| **P5** Plugin port | `mode → react+projection`; `audit / sla / csat / activation / resolve` | Yes | 14–21 days |
| **P6** IRC adapter (optional) | `adapters/irc` for legacy compat | No | 7–10 days |
| **P7** Side / extra plugins (optional) | Operator side messages + remaining zchat features | No | 7–14 days |

Total mandatory work: ~40–60 days of focused engineering.

## P1 — Schema unification

### Goal

Replace ESR's `workspaces.yaml` + `adapters.yaml` with a single `routing.toml` modeled on zchat's V6 schema, extended with ESR-required fields (`cwd / start_cmd / role / env` for workspaces).

### Deliverables

- New schema spec in `docs/superpowers/specs/<date>-routing-toml-schema.md`
- `runtime/lib/esr/routing/parser.ex` — TOML loader (use `toml_elixir` or similar)
- `runtime/lib/esr/routing/registry.ex` — replaces [`Esr.Workspaces.Registry`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/workspaces/registry.ex)
- Migration script: `workspaces.yaml + adapters.yaml → routing.toml`
- CLI: `esr routing reload` (push-based; replaces `cli:workspace/register`)

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
start_cmd = "claude"
role      = "dev"
```

### Acceptance criteria

- [ ] All existing v0.2-channel tests pass against `routing.toml` source of truth
- [ ] `esr routing reload` triggers diff-based re-registration (additions JOIN, removals deactivate topologies)
- [ ] Migration script idempotent: running twice produces identical output
- [ ] `workspaces.yaml` + `adapters.yaml` deprecated with one-version overlap (both formats accepted, new format preferred)
- [ ] Schema validation: missing required fields produce actionable error messages

## P2 — Multiplexer adapter (`cc_zellij`)

### Goal

Add `cc_zellij` adapter as an alternative to `cc_tmux`, parameter-compatible at the directive level. Workspaces choose which to use.

### Why zellij

- Better parallel test fixture support — `zellij action dump-screen --pane-id <id>` enables structured per-agent screenshot capture (see [`tests/pre_release/conftest.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/tests/pre_release/conftest.py))
- More predictable rendering for inspection (less escape-sequence variance vs tmux)
- zchat already operates on this model; reusing its zellij invocation patterns reduces work

### Deliverables

- New adapter package: `adapters/cc_zellij/` mirroring `adapters/cc_tmux/` structure
- Directives: `new_session`, `send_keys`, `kill_session`
- Events: pane-content polling for sentinel-prefixed lines (same as tmux)
- Optional: `dump_pane` directive for evidence capture (used by E2E tests)
- Documentation: when to use zellij vs tmux

### Acceptance criteria

- [ ] All existing tmux-based scenarios pass with `cc_zellij` swap (parameterized at the workspace level: `multiplexer = "zellij" | "tmux"`)
- [ ] `dump_pane` directive captures correct pane contents for at least one test scenario
- [ ] Both adapters can coexist in the same esrd instance (different workspaces use different multiplexers)
- [ ] `cc_zellij` survives zellij version upgrade within the same minor release

## P3 — Auth module

### Goal

Replace v0.2's no-auth Phoenix Channel join with a magic-link / device-flow auth flow. Channel sockets validate a token before allowing join.

### Why now (not later)

- v0.2 explicitly punts auth (per [v0.2 design §3.1](../../superpowers/specs/2026-04-20-esr-v0.2-channel-design.md))
- Once we add multi-bot routing (P1), unauthenticated bridge sockets become a real risk (cross-bot impersonation)
- Magic-link is simple enough to implement before P4–P5 land

### Deliverables

- New module: `runtime/lib/esr/auth.ex` + `runtime/lib/esr/auth/store.ex`
- CLI: `esr auth issue-link --workspace=acme --ttl=10m` → outputs URL
- CLI: `esr auth list` / `esr auth revoke <id>`
- Phoenix Channel `connect/3` callback validates `token` param
- Token storage: ETS, periodic checkpoint to disk (same pattern as `Esr.Workspaces.Registry`)

### Auth model

- **Magic link** for human-driven onboarding (web UI / direct CLI run): `esr auth issue-link` → URL → browser → local web UI obtains token → token stored in `~/.esr/credentials.json`
- **Device flow** for headless bots (CI, agents starting up): adapter requests token → CLI shows pairing code → operator approves via web UI → token returned
- **No password storage, no OAuth provider integration** in v0.3

### Acceptance criteria

- [ ] Phoenix Channel join without valid token returns 401-equivalent
- [ ] Token lifecycle: issue → consume (one-time use for magic-link) / revoke / expire
- [ ] Tokens scoped to workspace (token issued for workspace X cannot join workspace Y's channel)
- [ ] All existing v0.2 tests updated to use issued tokens
- [ ] `esr auth list` shows tokens with workspace + ttl + last-used time

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
- [ ] `/new-session` example from [04-target-design.md §7](./04-target-design.md#7-worked-example-new-session-with-topology-delegation) runs end-to-end (uses InvokeCommand bridge)
- [ ] Existing v0.2 handler modules continue to work without modification
- [ ] Pattern matching benchmarks: ≥10k events/sec on a single dispatcher process with 100 registered patterns

## P5 — Plugin port

### Goal

Port `mode / audit / sla / csat / activation / resolve` plugins from zchat to ESR using the new primitives. Existing `@handler(actor_type=...)` modules in v0.2-channel get rewritten to react form.

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

### Acceptance criteria

- [ ] All zchat plugin scenarios reproduce in ESR (operator hijack, SLA breach, CSAT round-trip)
- [ ] v0.2-channel acceptance suite still passes after handler migration
- [ ] No `@handler(actor_type=...)` references remain in `handlers/` (only Layer 4 topologies retain actor concepts)
- [ ] Total LOC reduction: existing handlers should shrink ≥30 % on average after migration

## P6 — IRC adapter (optional)

Skip unless concrete demand emerges. v0.3 will validate Feishu + simple web IM coverage; if those suffice, IRC stays out.

If needed:

- New `adapters/irc/` adapter wrapping a Python IRC client library
- Treats IRC channels as event sources (events have `source=irc`)
- Inter-agent broadcast still via Phoenix.PubSub (not IRC); IRC is purely a human-facing channel

## P7 — Remaining zchat features (optional)

- **`__side:` operator-only messages** — requires Feishu adapter to support visibility metadata; defer until first concrete request
- Other zchat features as they surface; each one re-evaluated for fit

## Cross-cutting risks

| Risk | Mitigation |
|---|---|
| Pattern matcher becomes hot-path bottleneck at scale | Benchmark in P4; optimize via compiled-pattern lookup tables if needed |
| Coexistence of `@handler` and `react` confuses contributors | Document clearly in CHANGELOG; deprecation warnings on `@handler` after P5 lands |
| Projection schema sprawl (every team adds tables) | Require `projection_table` registration in central manifest in P5; CI fails on unregistered tables |
| Auth module scope creep (people want OAuth, SSO, RBAC) | Hold the line: P3 is magic-link + device-flow only. Anything more = separate spec |
| zellij CLI version drift breaks `cc_zellij` adapter | Pin minimum version; smoke-test against pinned version in CI |
| Migration of existing handlers introduces subtle behavior changes | Per-handler scenario test before and after rewrite must be byte-identical on event traces |

## Decision points

After each phase, reassess:

- **After P1:** Is the routing.toml schema actually clearer than the yaml split? Survey contributors.
- **After P3:** Does the auth model survive a real attack-surface review? (Get external eyes.)
- **After P4:** Are the new primitives ergonomic enough? Try porting one plugin (mode) before committing to P5.
- **After P5:** Did handler LOC actually shrink? If not, the new primitives may not be earning their complexity.
- **Before P6/P7:** Real demand from users?

## What "done" looks like for v0.3

- A new contributor can add a channel-scoped feature (e.g., `/lock_audio`) in <100 LOC, ~1 day of work, by reading [`04-target-design.md`](./04-target-design.md) and following the `/hijack` example
- ESR + zellij can serve a Feishu-driven multi-customer-thread scenario equivalent to zchat's [`tests/pre_release/test_feishu_e2e.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/tests/pre_release/test_feishu_e2e.py)
- All zchat plugin behaviors (mode, sla, audit, csat) reproducible in ESR
- No IRC dependency in production runtime
- Auth required on all Phoenix Channel joins

## Out of scope (explicit anti-goals)

- Full ESR Protocol v0.3 §10.1 conformance (`contract_declaration` + `static_verification`) — those land in a separate spec
- Multi-node BEAM cluster (deferred to ESR v0.4+)
- Replacing `cc-openclaw` in production (this work creates the *substrate* that could replace it later)
- Migrating zchat users — zchat continues to serve its production project; this work has no effect on zchat operation
