# Future: zchat → ESR Migration Checklist

Status: **planning complete, implementation not started** — future implementation target.
Author: brainstorming session with user (Allen Woods), 2026-04-20 to 2026-04-21.
Relates to: [`docs/plans/migrate-from-zchat/`](../plans/migrate-from-zchat/) (full plan suite, 7 docs).

## Why this document exists

A full brainstorming session over two days produced a complete migration plan for absorbing the [`ezagent42/zchat`](https://github.com/ezagent42/zchat) umbrella repo into ESR. The plan's authoritative home is [`docs/plans/migrate-from-zchat/`](../plans/migrate-from-zchat/) (PR [#2](https://github.com/ezagent42/esr/pull/2)).

This file in `docs/futures/` is a **lightweight checklist** that mirrors the structure used by other future-work docs (e.g. [`cross-workspace-messaging-handler.md`](./cross-workspace-messaging-handler.md), [`explicit-capability-delegation.md`](./explicit-capability-delegation.md)) so the migration shows up in the same discovery surface as other future work, not buried under `docs/plans/`.

If you're looking for the actual migration content, jump directly to:

- [`README.md`](../plans/migrate-from-zchat/README.md) — entry point, TL;DR, decision log
- [`04-target-design.md`](../plans/migrate-from-zchat/04-target-design.md) — what writing ESR Python looks like after this lands
- [`05-migration-plan.md`](../plans/migrate-from-zchat/05-migration-plan.md) — the 6-phase plan

## What's being migrated

`ezagent42/zchat` is an umbrella repo containing:

- `zchat-protocol/` (refactor/v4 branch) — `irc_encoding`, `ws_messages`, `naming`
- `claude-zchat-channel/` — IRC ↔ WS broker + 6 plugins (mode/sla/audit/csat/activation/resolve)
- `weechat-zchat-plugin/` — WeeChat /agent commands + presence
- `zchat-hub-plugin/` — Rust zellij in-pane UI plugins (palette + status)
- `zchat/cli/` — top-level Python CLI (~4000 LOC: agent_manager, irc_manager, auth, zellij, runner, project, doctor, update)
- `ergo-inside/` — local IRC server config

The migration **fully absorbs** zchat capabilities into ESR. zchat retires after migration; no compatibility constraints. See [`02-zchat-overview.md`](../plans/migrate-from-zchat/02-zchat-overview.md) for the full inventory and [`03-comparison.md`](../plans/migrate-from-zchat/03-comparison.md) for the 22-row feature mapping.

## Six mandatory phases (P1–P6)

Each phase is independently shippable. Detailed acceptance criteria + open questions live in [`05-migration-plan.md`](../plans/migrate-from-zchat/05-migration-plan.md) and [`06-open-questions.md`](../plans/migrate-from-zchat/06-open-questions.md).

- [ ] **P1 — Schema unification** (5–7 days). `routing.toml` replaces `workspaces.yaml` + `adapters.yaml`; runner template variable substitution.
- [ ] **P2 — `cc_zellij` adapter** (5–7 days). Borrows zchat's `zellij.py` wrapper; `multiplexer = "zellij" | "tmux"` per workspace.
- [ ] **P3 — Per-adapter CLI + `esr doctor` + scoped naming** (5–7 days). `esr adapter <name> {list,...}` pattern replaces zchat's unified `zchat agent ...`.
- [ ] **P4 — New Python primitives** (10–14 days). `transform / react / projection_table` MVP, side-by-side with `@handler`.
- [ ] **P5 — Plugin port + agent_manager + edit/side** (14–21 days). mode → react+projection; audit → adapter; sla/csat/activation/resolve as topologies; `__edit:` and `__side:` as adapter directives.
- [ ] **P6 — E2E parity** (7–10 days). Reproduce zchat `tests/pre_release/` scenarios in ESR.

Total mandatory: ~46–66 days of focused engineering.

## Two optional phases (P7–P8)

- [ ] **P7 — Hub plugin port** (14–21 days). Only if P6 retrospective surfaces concrete demand for in-zellij UI.
- [ ] **P8 — Distribution** (5–10 days). Homebrew tap + install.sh + self-update; deferred to v0.4+ per [decision ③b](../plans/migrate-from-zchat/README.md#decision-log).

## What is **not** in scope

Documented in detail in [`05-migration-plan.md` "Out of scope"](../plans/migrate-from-zchat/05-migration-plan.md#out-of-scope-explicit-anti-goals); summarized:

- **Auth module** — ESR uses CBAC (already shipped) + Feishu identity as the v0.3 security model. zchat's OIDC device flow (`auth.py`) is informative reference, not absorbed.
- **IRC fabric** — Phoenix.PubSub stays for inter-actor; user-facing IM uses Feishu / future web. No `ergo` dependency.
- **Project ↔ workspace rename** — workspace stays per [decision ①C](../plans/migrate-from-zchat/README.md#decision-log).
- **Message kind primitive** — kind is a zchat protocol artifact (forced by IRC PRIVMSG); edit/side are business semantics handled at handler/adapter level.
- **zchat coexistence** — zchat retires after migration completes.

## Pre-flight: settle these before P1 starts

From [`06-open-questions.md`](../plans/migrate-from-zchat/06-open-questions.md) cross-cutting section:

- [ ] Branch strategy: per-phase short-lived branches or single long-lived `v0.3-migrate-zchat`?
- [ ] Versioning: each phase = tagged release, or all of P1–P6 ship as v0.3.0 final?
- [ ] CHANGELOG ownership for new primitives at P4 land.
- [ ] CBAC capability inventory: which Feishu identity attributes (`open_id`, `app_id`, chat membership) map to which ESR capabilities? Settle in P1 alongside routing.toml schema.

## Proposed trigger

This work becomes ready when:

1. ESR v0.2-channel acceptance lands and stabilizes (currently merged via PR [#1](https://github.com/ezagent42/esr/pull/1)).
2. CBAC v1 deployed and validated against real Feishu identity flows (currently merged via PR [#3](https://github.com/ezagent42/esr/pull/3)).
3. The four pre-flight questions above are answered.

After that, P1 can start as a standalone branch off `main`. Each phase merges back to `main` on its own PR.

## Cross-references

- Migration plan suite: [`docs/plans/migrate-from-zchat/`](../plans/migrate-from-zchat/) (7 markdown files; ~1400 lines total)
- Migration plan PR: [#2](https://github.com/ezagent42/esr/pull/2)
- ESR Protocol v0.3 substrate: [`docs/design/ESR-Protocol-v0.3.md`](../design/ESR-Protocol-v0.3.md)
- v0.1 extraction design (architecture baseline): [`docs/superpowers/specs/2026-04-18-esr-extraction-design.md`](../superpowers/specs/2026-04-18-esr-extraction-design.md)
- v0.2 channel design (most recent ESR iteration the migration builds on): [`docs/superpowers/specs/2026-04-20-esr-v0.2-channel-design.md`](../superpowers/specs/2026-04-20-esr-v0.2-channel-design.md)
- CBAC design (security model the migration assumes): [`docs/superpowers/specs/2026-04-20-esr-capabilities-design.md`](../superpowers/specs/2026-04-20-esr-capabilities-design.md)
- zchat umbrella: <https://github.com/ezagent42/zchat>
