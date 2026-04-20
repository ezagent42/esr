# Open Questions

Each question must be settled **before** the corresponding phase in [`05-migration-plan.md`](./05-migration-plan.md) starts. Recommendations are the brainstorming-session default; document the actual decision (and reason) in [`README.md`](./README.md) `Decision log` once made.

## Cross-cutting (settle before P1 starts)

- [ ] **Branch strategy for the migration:** single long-lived `v0.3-migrate-zchat` branch, or per-phase short-lived branches off `main`? Recommendation: per-phase branches; each merges back to main on phase completion.
- [ ] **Versioning:** does each phase bump a version (v0.3.0-p1, v0.3.0-p2, …), or all of P1–P5 ship as v0.3.0 final? Recommendation: each phase = a tagged release for visibility; v0.3.0 is the final tag after P5.
- [ ] **CHANGELOG discipline:** new primitives need user-facing docs at P4 land. Who owns drafting? Recommendation: same engineer who lands P4.

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

## P2 — Multiplexer adapter (`cc_zellij`)

- [ ] **zellij version floor:** which is the minimum supported zellij version? (`dump-screen --pane-id` exists from 0.x onwards but the JSON output of `list-panes --json` evolved.)
  - Recommendation: pin to whatever zchat's `tests/pre_release/conftest.py` is currently exercising; document in adapter README.
  - Decide before: P2 implementation starts.
- [ ] **Default multiplexer for new workspaces:** should new workspaces default to `cc_zellij` or stay on `cc_tmux`?
  - Recommendation: keep `cc_tmux` as default for one minor release after P2 lands; flip default in v0.4 if no regressions.
  - Decide before: P2 acceptance.

## P3 — Auth module

- [ ] **Token transport:** HTTP `Authorization: Bearer ...` header, or `?token=...` query param?
  - Recommendation: header-only. Query params leak in logs and proxy server access logs.
  - Decide before: Phoenix `connect/3` callback implementation.
- [ ] **Service-account concept:** add long-lived bot tokens for headless bot↔bot communication?
  - Recommendation: yes — bot↔bot communication needs durable creds. Track as a P3 follow-up; NOT blocking P3 acceptance.
  - Decide before: P3 retrospective; commit to v0.3.x or defer to v0.4.
- [ ] **Workspace scoping enforcement:** is a token issued for workspace X *technically* unable to join workspace Y's channel, or is it a soft check?
  - Recommendation: hard check at `connect/3` — token's workspace claim must match the joined channel's workspace, otherwise reject.
  - Decide before: token claim schema design.

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

## P5 — Plugin port

- [ ] **Migration order:** `mode` first (smallest, exercises full primitive set) → then `audit` → then `sla` → then `csat / activation / resolve`. OK?
  - Recommendation: yes; `mode` is the validation case for the new primitives. If `mode` doesn't fit cleanly, pause and revisit P4 design before continuing.
  - Decide before: P5 kickoff.
- [ ] **`@handler` deprecation timeline:** keep silent compat for 1 minor release, warn-on-load for 1 minor, then error?
  - Recommendation: warn-on-load starting in v0.3.0 (the release that lands P4 + P5); error in v0.5.
  - Decide before: P4 deliverable for the deprecation warning shim.
- [ ] **Projection table central manifest:** require all `projection_table` calls to be registered in `py/esr/projections.toml` (or similar) for CI enforcement?
  - Recommendation: yes — prevents schema sprawl; gives a single place to audit ESR-managed state.
  - Decide before: P5 (the manifest is needed at this phase to keep handler porting honest).

## P6 — IRC adapter (optional)

- [ ] **Trigger criteria for actually doing P6:** what concrete user request would unlock the work?
  - Recommendation: a deployment scenario where IRC clients (WeeChat, irssi) are required for human ops staff to debug live conversations, AND that team has tried and rejected a Feishu-side equivalent.
  - Decide before: anyone proposes starting P6.

## P7 — Remaining zchat features (optional)

- [ ] **Operator side messages (`__side:`):** which Feishu API supports message visibility? Lark's "private message in chat" or thread-only-visible messages?
  - Recommendation: investigate during a future spike; don't speculate now.
  - Decide before: P7 spike.

## Decision log conventions

When a question is settled, record in [`README.md`](./README.md) `Decision log` table:

| Date | Decision | Reason |
|---|---|---|
| YYYY-MM-DD | (the choice made) | (the reason; reference any tickets / discussions) |

…and check the box here. Don't delete settled questions — keep the answers visible for future reference.
