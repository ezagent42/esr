# Open Questions

Each question must be settled **before** the corresponding phase in [`05-migration-plan.md`](./05-migration-plan.md) starts. Recommendations are the brainstorming-session default; document the actual decision (and reason) in [`README.md`](./README.md) `Decision log` once made.

## Already decided (2026-04-21)

These questions are settled; kept here for context. See [`README.md`](./README.md) decision log for canonical record.

- ✅ Migration approach: **Approach A** (absorb into ESR), full merger
- ✅ workspace vs project concept: **C** — keep ESR `workspace`; no rename, no project layer (project becomes optional aggregation view, not in v0.3 critical path)
- ✅ zellij in-pane UI: **C** — defer; CLI-first for v0.3 via `esr adapter cc_zellij list`
- ✅ Distribution / install / update: **b** — defer to v0.4+
- ✅ Auth: **removed entirely** — ESR uses CBAC + Feishu identity as the v0.3 security model
- ✅ Message kind concept: **not introduced** — kind is a zchat protocol artifact; edit/side are business semantics handled at handler/adapter level
- ✅ Agent CLI: **per-adapter** (`esr adapter <name> ...`) instead of unified `esr agent ...` — supports heterogeneous actor lifecycles

## Cross-cutting (settle before P1 starts)

- [ ] **Branch strategy for the migration:** single long-lived `v0.3-migrate-zchat` branch, or per-phase short-lived branches off `main`? Recommendation: per-phase branches; each merges back to main on phase completion.
- [ ] **Versioning:** does each phase bump a version (v0.3.0-p1, v0.3.0-p2, …), or all of P1–P6 ship as v0.3.0 final? Recommendation: each phase = a tagged release for visibility; v0.3.0 is the final tag after P6.
- [ ] **CHANGELOG discipline:** new primitives need user-facing docs at P4 land. Who owns drafting? Recommendation: same engineer who lands P4.
- [ ] **CBAC capability inventory:** which Feishu identity attributes (open_id, app_id, chat membership) map to which ESR capabilities? Recommendation: define in P1 alongside routing.toml schema; settle before P3 CLI lands so CLI commands inherit capability checks.

## P1 — Schema unification

- [ ] **Bridge process granularity:** should bridge processes still be 1:1 with bots, or can a single ESR adapter instance handle multiple `app_id`s?
  - Recommendation: per-app adapter instances for fault isolation, matching zchat's model.
  - Decide before: P1 deliverable `runtime/lib/esr/routing/registry.ex`.
- [ ] **File watcher vs CLI push:** zchat-style mtime poll, or CLI push only?
  - Recommendation: CLI push primary; optional watcher behind feature flag for ops convenience.
  - Decide before: P1 deliverable `esr routing reload` design.
- [ ] **`workspace_overrides` placement:** keep nested under `[channels.X.workspace_overrides]`, or move to a flat `[channel_overrides.<chan>]` block?
  - Recommendation: nested form (current sketch). Reason: keeps related fields colocated; readable for ops.
  - Decide before: schema spec write-up.
- [ ] **Runner template engine:** Jinja2-style (`{{ tag }}`), simple string format (`{tag}`), or something custom?
  - Recommendation: Jinja2 minimal subset (variables + `default` filter). Familiar; battle-tested; minimal dep cost.
  - Decide before: P1 implementation.
- [ ] **`multiplexer` field default:** if a workspace doesn't specify, is it `cc_tmux` (current ESR default) or `cc_zellij` (new)?
  - Recommendation: `cc_tmux` for one minor release after P2 lands; flip default in v0.4 if no regressions.
  - Decide before: P1 schema spec.

## P2 — Multiplexer adapter (`cc_zellij`)

- [ ] **zellij version floor:** which is the minimum supported zellij version? (`dump-screen --pane-id` exists from 0.x onwards but the JSON output of `list-panes --json` evolved.)
  - Recommendation: pin to whatever zchat's `tests/pre_release/conftest.py` is currently exercising; document in adapter README.
  - Decide before: P2 implementation starts.
- [ ] **Borrow strategy for `zellij.py`:** vendor verbatim into `adapters/cc_zellij/`, or import from a shared `esr-zellij` PyPI package, or rewrite?
  - Recommendation: vendor verbatim; ~180 LOC isn't worth a separate package, and zchat's shape is exactly what we need.
  - Decide before: P2 implementation.

## P3 — Per-adapter CLI + doctor + naming

- [ ] **CLI verb namespace conflict:** if two adapters declare the same verb (e.g., both `cc_zellij` and `cc_tmux` have `list`), how does the CLI dispatch? Hard rule: must specify adapter name (`esr adapter cc_zellij list`)? Or allow shorthand if unambiguous?
  - Recommendation: require explicit adapter name always; no shorthand. Reason: prevents future ambiguity when more adapters land.
  - Decide before: P3 CLI design.
- [ ] **Mandatory verbs across all adapters:** should every adapter implement `list` at minimum? Other shared verbs?
  - Recommendation: `list` is mandatory (returns adapter-instance status). `stop` is recommended where lifecycle exists. Adapter declares its full verb set explicitly.
  - Decide before: P3 CLI spec.
- [ ] **Output format:** human-readable table by default, `--json` for machine parsing? Or always JSON with optional `--pretty`?
  - Recommendation: human table default + `--json` flag; consistent with `kubectl` / `gh` conventions.
  - Decide before: P3 implementation.
- [ ] **`scoped_name` adoption breadth:** adopt for agent IDs only, or extend to channels (`<workspace>-<channel>`) and topologies?
  - Recommendation: agents only for now; broader adoption considered in v0.4 if it improves readability.
  - Decide before: P3 naming spec.

## P4 — New Python primitives

- [ ] **`Ctx` snapshot semantics:** lazy (read on first access, possibly seeing a half-updated table) or eager (snapshot all `reads=` at dispatch time)?
  - Recommendation: eager. Predictable; no surprise on partial-table changes mid-handler. Maps to "single read point" CQRS discipline.
  - Decide before: dispatcher implementation starts.
- [ ] **Pattern syntax:** dict-based (`{"meta.slash_cmd": "hijack"}`) vs callable (`lambda e: e.meta.slash_cmd == "hijack"`) vs both?
  - Recommendation: dict-based primary (compileable, fast to match, declarative); callable as escape hatch for complex predicates.
  - Decide before: pattern compiler implementation.
- [ ] **Worker pool sizing per react:** fixed pool size, configurable per-react, or auto-tuned?
  - Recommendation: configurable; default to system core count. Document tuning guidance.
  - Decide before: dispatcher implementation.
- [ ] **Pattern conflict policy:** if two reacts match the same event, run both in parallel (current default), or warn at registration if patterns overlap heavily?
  - Recommendation: run both in parallel; expose telemetry counter for "events matched by N reacts" so operators can spot accidental overlap.
  - Decide before: dispatcher implementation.

## P5 — Plugin port + agent_manager + edit/side

- [ ] **Migration order:** `mode` first (smallest, exercises full primitive set) → then `audit` → then `sla` → then `csat / activation / resolve` → finally `agent_manager.py` shape absorption. OK?
  - Recommendation: yes; `mode` is the validation case for the new primitives. If `mode` doesn't fit cleanly, pause and revisit P4 design before continuing.
  - Decide before: P5 kickoff.
- [ ] **`@handler` deprecation timeline:** keep silent compat for 1 minor release, warn-on-load for 1 minor, then error?
  - Recommendation: warn-on-load starting in v0.3.0 (the release that lands P4 + P5); error in v0.5.
  - Decide before: P4 deliverable for the deprecation warning shim.
- [ ] **Projection table central manifest:** require all `projection_table` calls to be registered in `py/esr/projections.toml` (or similar) for CI enforcement?
  - Recommendation: yes — prevents schema sprawl; gives a single place to audit ESR-managed state.
  - Decide before: P5 (the manifest is needed at this phase to keep handler porting honest).
- [ ] **`__side:` Feishu API mapping:** does Feishu OpenAPI support per-message visibility, or do we need a separate operator chat as the sink?
  - Recommendation: investigate during early P5; pick whichever Feishu actually supports. Document the choice.
  - Decide before: implementing the side semantic.
- [ ] **`agent_manager.py send()` replacement:** zchat's `send` is "IRC PRIVMSG to agent's nick"; ESR has no IRC. Should `esr adapter cc_zellij send <session> <msg>` use zellij `write_chars` (typing), MCP notification, or both?
  - Recommendation: MCP notification (preferred per v0.2-channel design); fall back to `write_chars` if the session isn't MCP-connected.
  - Decide before: P5 agent_manager port.

## P6 — E2E parity verification

- [ ] **Evidence capture:** ESR-side equivalent of `capture_zellij_screenshot`. Reuse zchat's exact mechanism, or build a more structured event-trace dump?
  - Recommendation: reuse zellij `dump-screen` mechanism for consistency with zchat fixtures; supplement with telemetry trace export.
  - Decide before: P6 fixture setup.
- [ ] **Acceptance scope:** all 9 zchat scenarios, or a subset that covers the critical paths?
  - Recommendation: all 9 — they map to documented user-facing behaviors. Skipping risks regressions.
  - Decide before: P6 kickoff.

## P7 — Hub plugin (optional)

- [ ] **Trigger criteria for actually doing P7:** what concrete user request would unlock the work?
  - Recommendation: P6 retrospective surfaces "operators want in-pane status" as a real ask, not speculation.
  - Decide before: anyone proposes starting P7.

## P8 — Distribution (optional)

- [ ] **Distribution path:** Homebrew tap (matching zchat), uv tool install, system package (apt/rpm), or Mix release?
  - Recommendation: defer entirely; v0.3 doesn't need a public distribution story. Decide as part of v0.4 broader release planning.
  - Decide before: anyone proposes starting P8.

## Decision log conventions

When a question is settled, record in [`README.md`](./README.md) `Decision log` table:

| Date | Decision | Reason |
|---|---|---|
| YYYY-MM-DD | (the choice made) | (the reason; reference any tickets / discussions) |

…and check the box here. Don't delete settled questions — keep the answers visible for future reference.
