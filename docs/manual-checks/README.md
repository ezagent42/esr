# Manual checks

> **Status (2026-05-09):** the 12-step bootstrap journey hits 12/12 ✅
> as of the unified-command-grammar migration + PTY hardening series.
> The audits in this directory are now a **historical record** of how
> the gaps closed.
>
> **For ongoing verification, use the standing checklist:**
> [`docs/guides/operator-bootstrap-checklist.md`](../guides/operator-bootstrap-checklist.md)
> ([zh_cn](../guides/operator-bootstrap-checklist.zh_cn.md)).
> The guide distills the audit methodology into a runnable
> 12-row checklist; future grammar / bootstrap changes update the
> guide first, and re-audit (creating a new dated file here) only
> when the surface drifts far enough that step-by-step rescoring is
> warranted again.

---

This directory holds operator-driven flow audits — checklists comparing
a *proposed* user journey against the *current* implementation, scored
on three dimensions:

1. **Interface present** — does an entry point exist (CLI command,
   slash command, module) that *could* serve this step?
2. **Function works** — does the entry point actually deliver the
   expected behaviour end-to-end (verified by code inspection or test)?
3. **Grammar matches** — does the wording / argument shape exactly
   match what the operator was told to type?

The point is to surface gaps between the **mental model an operator
holds** and the **shipped surface**, before they hit them in a live
chat. Each audit is dated; old audits are kept as a historical record
of how the surface evolved.

## Bilingual convention

Following the project precedent (e.g.
`docs/superpowers/specs/2026-05-05-plugin-physical-migration.md` +
`.zh_cn.md`), each audit ships **two files**:

- `<date>-<topic>.md` — English original.
- `<date>-<topic>.zh_cn.md` — Chinese mirror. Cross-references the
  English at the top via a "配套文件" callout.

Both files mirror each other section-for-section. Code identifiers,
file paths, and quoted code stay in English in both versions; only
the narrative differs.

## Relationship to other docs

- [`docs/notes/manual-e2e-verification.md`](../notes/manual-e2e-verification.md)
  — manual *post-release* verification of an already-running system.
  Complements `make e2e`. Assumes esrd / adapters / capabilities are
  configured.
- [`tests/e2e/scenarios/`](../../tests/e2e/scenarios/) — automated
  regression scenarios derived from these manual checks once the gap
  is closed.
- [`docs/guides/operator-bootstrap-checklist.md`](../guides/operator-bootstrap-checklist.md)
  — the runnable distillation of these audits. Use this for ongoing
  verification; the dated audits below are the historical record.
- [`docs/futures/todo.md`](../futures/todo.md) — durable TODO list;
  gaps surfaced here typically land here as "spec needed" items.

## Index

- [`2026-05-10-session-template-and-channel-closeout.md`](2026-05-10-session-template-and-channel-closeout.md)
  / [`.zh_cn.md`](2026-05-10-session-template-and-channel-closeout.zh_cn.md)
  — operator-flow re-score after the SessionTemplate + Channel migration
  (PRs #324–#330 + Phase 8 closeout). **Findings:** 12/12 still ✅ ✅ ✅
  post-migration; the migration is a wiring-level refactor (Channel
  behaviour, Bundle artifacts, SessionTemplate loader, agents.yaml
  dissolved) that adds capabilities (operator-shipped templates, external
  bundle install, multi-session-per-instance, two-agent-kind composition)
  without touching the operator-typed slash surface.
- [`2026-05-08-post-multi-instance-audit.md`](2026-05-08-post-multi-instance-audit.md)
  / [`.zh_cn.md`](2026-05-08-post-multi-instance-audit.zh_cn.md)
  — same 12 operator steps re-scored against `origin/dev` `a69fd6a`
  (post Phase 6 colon-namespace, Phase 7 plugin config, HR-1..HR-4,
  PR #248 `/session:*`, PR #261 multi-instance routing cleanup).
  **Findings:** 9/12 fully closed (was 7/12); colon-namespace + plugin
  config closed; one regression (Step 12 `/attach` URL deleted in
  cutover); five new gaps surfaced by the multi-instance work
  (`/session:list`, attach-by-name, TUI URL returner, multi-instance
  helpers, `@mention` e2e harness).
- [`2026-05-06-bootstrap-flow-audit.md`](2026-05-06-bootstrap-flow-audit.md)
  / [`.zh_cn.md`](2026-05-06-bootstrap-flow-audit.zh_cn.md)
  — first-time-operator 12-step bootstrap journey vs current shipped
  surface (CLI, slash commands, plugin abstraction). **Findings:**
  9/12 steps work content-wise; gaps are colon-namespace grammar +
  per-plugin operator config + auto-admin friendliness.
