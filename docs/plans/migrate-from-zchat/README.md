# Migrating zchat capabilities into ESR

**Status:** Planning (no implementation started)
**Created:** 2026-04-20
**Owner:** Brainstorming session — Allen Woods

## TL;DR (v2 — full merger)

1. **ESR will fully absorb [`ezagent42/zchat`](https://github.com/ezagent42/zchat) umbrella** — not just the channel server. zchat will be retired after migration; no compatibility constraints. Scope expanded based on dev's pointer that significant business code lives in `zchat-protocol` (refactor/v4 branch) + the top-level `zchat/cli/` package + Rust `zchat-hub-plugin/` + WeeChat plugin.
2. **IRC-as-fabric is *not* absorbed.** ESR keeps Phoenix.PubSub for inter-actor messaging. User-facing chat stays on Feishu (and a future simple web IM) without an IRC layer in between. WeeChat plugin's *user-facing functionality* is absorbed via the per-adapter CLI pattern.
3. **The Python SDK gains a smaller, more orthogonal primitive set** — `@adapter` + `projection_table` + `transform` + `react`. The current `@handler(actor_type=...)` discipline retires from the Python layer in favor of state-via-projections; per-actor mailbox supervision continues inside the Elixir runtime, invisible to Python authors.
4. **Migration follows a 6-phase plan** — P1 schema → P2 zellij adapter → P3 per-adapter CLI + doctor → P4 primitives → P5 plugin port + agent_manager + edit/side → P6 E2E parity. P7 (hub plugin) and P8 (distribution) are optional.
5. **Security via CBAC + Feishu identity** (recently landed in ESR) — no auth phase in v0.3. zchat's OIDC device flow (`auth.py`) is informative reference but not absorbed.
6. **No external coordination required for v0.3.** The zchat repository is referenced for inspiration and for verbatim borrowing where useful (e.g., `zellij.py` wrapper), but no PR or issue lands there as part of this work.

## Files in this directory

| File | Contents |
|---|---|
| [`README.md`](./README.md) | This file — entry, TL;DR, links, decision log |
| [`01-esr-overview.md`](./01-esr-overview.md) | ESR v0.2-channel current state — architecture, key files, what gets preserved |
| [`02-zchat-overview.md`](./02-zchat-overview.md) | zchat refactor/v4 architecture, schema, plugin model, want/don't-want lists |
| [`03-comparison.md`](./03-comparison.md) | Routing-functionality overlap matrix between the two codebases |
| [`04-target-design.md`](./04-target-design.md) | Future Python SDK shape; worked examples for `/hijack` and `/new-session` |
| [`05-migration-plan.md`](./05-migration-plan.md) | A3 phased plan P1–P7 with acceptance criteria, cost estimates, decision points |
| [`06-open-questions.md`](./06-open-questions.md) | Per-phase open questions; settle each before starting that phase |

## Cross-references

### ESR design substrate

- v0.1 Extraction Design — [`docs/superpowers/specs/2026-04-18-esr-extraction-design.md`](../../superpowers/specs/2026-04-18-esr-extraction-design.md) (4-layer architecture)
- v0.2 Channel + MCP Bridge Design — [`docs/superpowers/specs/2026-04-20-esr-v0.2-channel-design.md`](../../superpowers/specs/2026-04-20-esr-v0.2-channel-design.md) (current iteration)
- ESR Protocol v0.3 — [`docs/design/ESR-Protocol-v0.3.md`](../../design/ESR-Protocol-v0.3.md)

### zchat repo (read-only reference for this work)

- Repo: <https://github.com/ezagent42/claude-zchat-channel>
- Active branch: [`refactor/v4`](https://github.com/ezagent42/claude-zchat-channel/tree/refactor/v4)
- Routing schema: [`routing.example.toml`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/routing.example.toml)
- Plugin model: [`src/channel_server/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/plugin.py)
- Mode plugin: [`src/plugins/mode/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/mode/plugin.py)
- SLA plugin: [`src/plugins/sla/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/sla/plugin.py)
- E2E zellij capture pattern: [`tests/pre_release/conftest.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/tests/pre_release/conftest.py)

### OTP / CQRS / Phoenix research backing the design

- [Patterns for managing ETS tables — Johanna Larsson](https://blog.jola.dev/patterns-for-managing-ets-tables)
- [The many states of Elixir — Underjord](https://underjord.io/the-many-states-of-elixir.html)
- [Unpacking Elixir: The Actor Model — Underjord](https://underjord.io/unpacking-elixir-the-actor-model.html)
- [Clever use of persistent_term — Erlang/OTP blog](https://www.erlang.org/blog/persistent_term/)
- [Choosing the Right In-Memory Storage Solution — DockYard](https://dockyard.com/blog/2024/06/18/choosing-the-right-in-memory-storage-solution-part-1)
- [Commanded — CQRS / Event Sourcing for Elixir](https://github.com/commanded/commanded)
- [Phoenix.Presence behaviour docs](https://hexdocs.pm/phoenix/Phoenix.Presence.html)
- [Elixir Registry docs](https://hexdocs.pm/elixir/main/Registry.html)

## Decision log

| Date | Decision | Reason |
|---|---|---|
| 2026-04-20 | Approach **A** (absorb into ESR), not A2 (coexist) or A3 (extract shared lib) | Simplest single-runtime story; zchat's IRC fabric isn't load-bearing for ESR |
| 2026-04-20 | Phased rollout | Risk minimization; each phase independently valuable; can stop mid-way |
| 2026-04-20 | New Python primitive: `transform` + `react` + `projection_table` | Lowers cognitive load while preserving OTP guarantees; aligns with CQRS read-model + Plug pipeline idioms |
| 2026-04-20 | IRC-as-fabric *not* absorbed | Inter-actor uses Phoenix.PubSub (already in ESR); user-facing IM uses Feishu / future web adapter |
| 2026-04-20 | `workflow=` parameter in `react` deferred to v0.4+ | Existing Layer 4 Topology + `InvokeCommand` + completion-event chain covers complex flows without new primitives |
| 2026-04-20 | `transform` and `react` as separate verbs (not unified `subscribe`) | Distinguishes by function return type: `transform` returns `event` (message domain); `react` returns `list[Action]` (effect domain) |
| 2026-04-21 | **Scope: full merger** of zchat umbrella into ESR (not selective absorption) | Dev pointer revealed significant business code in `zchat-protocol` (refactor/v4) + top-level `zchat/cli/` + Rust `zchat-hub-plugin/`. Targeting complete absorption; zchat retires after migration |
| 2026-04-21 | workspace stays (no rename to project) — decision ①C | Minimal disruption; project becomes optional aggregation view in routing.toml, not v0.3 critical path |
| 2026-04-21 | zellij in-pane UI deferred — decision ②C | CLI-first for v0.3 via `esr adapter cc_zellij list`; in-zellij Rust plugin re-evaluated v0.4 (web UI is an alternative) |
| 2026-04-21 | Distribution / install / update deferred — decision ③b | Independent workstream; should align with ESR project's broader release roadmap, not zchat-driven |
| 2026-04-21 | **Auth removed entirely from v0.3** | ESR uses CBAC (already landed) + Feishu identity as the security model; zchat's OIDC device flow is informative reference but not absorbed |
| 2026-04-21 | Message *kind* concept *not* introduced in ESR Event | kind is a zchat protocol artifact (forced by IRC PRIVMSG); edit/side are business semantics handled at handler/adapter level |
| 2026-04-21 | Per-adapter CLI (`esr adapter <name> ...`) instead of unified `esr agent ...` | ESR actors are heterogeneous (feishu_app_proxy / cc_zellij session / audit / ...); per-adapter CLI surfaces adapter-specific verbs cleanly |

## How to read these documents

- Reading **only** [`04-target-design.md`](./04-target-design.md) is sufficient if you just want to know what writing ESR Python looks like after this work lands.
- Reading [`01-esr-overview.md`](./01-esr-overview.md) + [`02-zchat-overview.md`](./02-zchat-overview.md) + [`03-comparison.md`](./03-comparison.md) is required if you're new to either codebase.
- Reading [`05-migration-plan.md`](./05-migration-plan.md) is required for anyone executing the migration or sequencing it against other roadmap work. Pair with [`06-open-questions.md`](./06-open-questions.md) — each phase's gating questions live there.
