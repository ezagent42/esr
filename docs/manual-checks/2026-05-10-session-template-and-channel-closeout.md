# SessionTemplate + Channel migration — operator-flow closeout (2026-05-10)

**Audit date:** 2026-05-10 (Phase 8 close of the SessionTemplate + Channel migration)
**Source migration:** `docs/superpowers/specs/2026-05-10-session-template-and-channel.md` + plan
**Predecessor audit:** [`2026-05-08-post-multi-instance-audit.md`](2026-05-08-post-multi-instance-audit.md)
**Companion file:** Chinese version at [`2026-05-10-session-template-and-channel-closeout.zh_cn.md`](2026-05-10-session-template-and-channel-closeout.zh_cn.md).

> **Headline (rev-6):** all 12 operator steps from the 2026-05-06 baseline still ✅ ✅ ✅ post the SessionTemplate + Channel migration. The migration cleaned up the wiring layer (agents.yaml dissolved; channels are first-class; bundles ship SessionTemplates) without changing the operator-facing slash surface that rev-5/5.1 closed. The 12-step path remains 12/12.

## Methodology

Same three-axis scoring as predecessor audits (I = interface, F = function, G = grammar). Symbols: ✅ yes · ⚠️ partial · ❌ no.

Re-scoring is shorter than rev-3/4/5 because the SessionTemplate + Channel migration is a **wiring-level refactor** — operator-facing slashes are unchanged. The two changes operators may notice:

1. `/session:new` accepts an optional `template=<name>` arg (Phase 5). When omitted, `Esr.Session.DefaultTemplate.auto_elect_if_single/0` picks the only registered template (`feishu-cc` on default install) — so the no-arg shape still works without operator config.
2. `/plugin:install --source=<dir>` now accepts a **bundle dir** (with `manifest.yaml` + `template.yaml`) in addition to a plugin dir (Phase 4). The verb + arg names are unchanged; only the accepted artifact shape widens.

Neither change is regression-shaped — old operator muscle memory still works.

## Headline table — re-scored

| # | Operator types | I | F | G | Net | Δ vs rev-5.1 (2026-05-09) |
|---|---|---|---|---|---|---|
| 1 | `esr daemon start` | ✅ | ✅ | ✅ | works | unchanged |
| 2 | `esr add user linyilun` (auto-admin) | ✅ | ✅ | ✅ | works | unchanged |
| 3 | `esr plugin install feishu` | ✅ | ⚠️ | ⚠️ | colon-namespace; install verb still local-path | unchanged (registry deferred) |
| 4 | `esr feishu bind linyilun ou_xxx` | ✅ | ✅ | ✅ | works (PR #263) | unchanged |
| 5 | `esr plugin install claude_code` | ✅ | ⚠️ | ⚠️ | same as #3; built-in by default | unchanged |
| 6 | `esr plugin claude_code set config http_proxy=…` | ✅ | ✅ | ✅ | works (Phase 7 + HR-2) | unchanged |
| 7 | (Feishu) `/help` `/doctor` | ✅ | ✅ | ✅ | works | unchanged |
| 8 | (Feishu) `/session:new` | ✅ | ✅ | ✅ | works (now via SessionTemplate) | **internals migrated**: behind the scenes the agent_def comes from `Esr.SessionTemplate.AgentDefBuilder` (template-driven), not the legacy `Esr.Entity.Agent.Registry` (agents.yaml). External shape unchanged. |
| 9 | (Feishu) `/workspace:add` | ✅ | ✅ | ✅ | works (rev-5.1 vocabulary closeout) | unchanged |
| 10 | (Feishu) `/agent:add type=cc name=esr-developer` | ✅ | ✅ | ✅ | works | **internals migrated**: agent kind metadata now sourced from claude_code plugin's manifest `agent_kinds:` block (Phase 6); dispatch path unchanged. |
| 11 | (Feishu) plain text → reply with cwd | ✅ | ✅ | ✅ | works | unchanged |
| 12 | (Feishu) `/agent:inspect <name>` → URL | ✅ | ✅ | ✅ | works (rev-5 + #314) | unchanged |

**Net (rev-6):** **12/12 fully closed**, same as rev-5.1. The SessionTemplate + Channel migration is a non-regressing refactor at the operator surface.

## What this migration ADDED to the operator surface

These are net-new capabilities, not gaps closed — they don't change rev-5.1's 12/12 score but expand what an operator can do.

### A. Operator-shipped SessionTemplates — **NEW**

Drop a `*.yaml` at `${ESRD_HOME}/<inst>/session_templates/foo.yaml` (conflated manifest+template) → boot's `Esr.Bundle.Loader.load_all/0` registers it as `source: :operator`; `/session:new template=foo` spawns via the operator template; `/plugin:reload session_templates` (future) re-reads on demand. Verified by e2e scenario 26.

### B. Bundle install via `/plugin:install --source=<external-dir>` — **NEW**

External path `/tmp/external_bundle/{manifest,template}.yaml` → `/plugin:install --source=/tmp/external_bundle` copies the bundle dir to `runtime/lib/esr/bundles/<name>/`, registers in `Esr.Bundle.Registry`, parses + registers the template in `Esr.SessionTemplate.Registry`. `/plugin:disable <bundle>` deregisters. Verified by e2e scenario 29.

### C. Multi-session-per-instance — **NEW**

One CC instance can serve two sessions; reply routing is per-incoming-session's chat context (boss session ↔ junior session). On-disk state at `sessions/<sid>/agents/<uuid>.json` carries `session_ids: [<A>, <B>]`. Verified by e2e scenario 28 + the `cc_process_multi_session_test.exs` invariant test.

### D. Two-agent-kind composition — **NEW (proves abstraction)**

The Phase 8 stub_agent plugin + stub-only bundle prove the Channel + agent_kind abstraction isn't CC-specific. Verified by e2e scenario 30: a non-CC plugin ships its own Channel kind + agent kind; a stub-only bundle composes them; `/session:new template=stub-only` succeeds with zero edits to feishu or claude_code plugin code.

## What changed under the hood (operator-invisible)

These items are **architecturally significant** but don't change the operator-typed surface. Listed for traceability:

- `Esr.Channel` behaviour + `Esr.Channel.Registry` — first-class per-session communication peer abstraction
- `Esr.Bundle.{Manifest,Registry,Loader}` — first-class single-template install artifacts
- `Esr.SessionTemplate.{Parser,Registry,AgentDefBuilder,FlowNodeRegistry}` — template materialization layer; replaces hard-coded wiring in `Esr.Entity.FeishuChatProxy` / `Esr.Entity.SlashHandler` / `Esr.Entity.Agent.MentionParser`
- `Esr.Plugin.AgentKindRegistry` (Phase 6) — replaces `Esr.Entity.Agent.Registry` (agents.yaml cache); agent kinds now declared in plugin manifest `agent_kinds:` block
- `mix esr.gen_bundle_docs` + `mix esr.check_bundles` (Phase 8) — auto-gen + drift-gate for bundles, mirrors the unified-grammar pattern
- `agents.yaml` deleted; `git grep -l agents.yaml runtime/lib/` returns zero hits in production code (only moduledoc references)

## Open vs deferred

Same items deferred from rev-5/5.1 carry forward unchanged:

- `esr daemon init` + `esr daemon clear` — first-30-min UX polish
- Plugin install-by-name (registry) — Phase 2 of plugin spec, deferred
- `pty_attach_security_hardening` — already CLOSED 2026-05-09 by PR #314 (carries forward in case of future reviewers reading audits in order)

No new operator-facing gaps surfaced by this migration.

## See also

- [`2026-05-08-post-multi-instance-audit.md`](2026-05-08-post-multi-instance-audit.md) — predecessor audit; rev-5.1 hit 12/12
- [`docs/guides/operator-bootstrap-checklist.md`](../guides/operator-bootstrap-checklist.md) — runnable 12-row checklist; the source of ongoing verification
- [`docs/superpowers/specs/2026-05-10-session-template-and-channel.md`](../superpowers/specs/2026-05-10-session-template-and-channel.md) — source spec for this migration
- [`docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`](../superpowers/plans/2026-05-10-session-template-and-channel-plan.md) — 8-phase implementation plan
- [`docs/grammar/templates.md`](../grammar/templates.md) — auto-generated bundle reference
- [`docs/notes/concepts.md`](../notes/concepts.md) — rev 11 added Bundle as a runtime-tier concept
- [`tests/e2e/scenarios/30_two_agent_kind_composition.sh`](../../tests/e2e/scenarios/30_two_agent_kind_composition.sh) — the abstraction-validation gate
