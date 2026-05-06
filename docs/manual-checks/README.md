# Manual checks

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
- [`docs/futures/todo.md`](../futures/todo.md) — durable TODO list;
  gaps surfaced here typically land here as "spec needed" items.

## Index

- [`2026-05-06-bootstrap-flow-audit.md`](2026-05-06-bootstrap-flow-audit.md)
  / [`.zh_cn.md`](2026-05-06-bootstrap-flow-audit.zh_cn.md)
  — first-time-operator 12-step bootstrap journey vs current shipped
  surface (CLI, slash commands, plugin abstraction). **Findings:**
  9/12 steps work content-wise; gaps are colon-namespace grammar +
  per-plugin operator config + auto-admin friendliness.
