# Phase 2 → 3 → 4 Execution Plan + AFK Operating Principles

**Date:** 2026-05-05
**Status:** Draft for user pre-approval before going AFK.
**Prereq complete:** Channel-port debt audit (PR #190); Option A cleanup (PR #191).
**Specs this plan executes:**
- Phase 2: `docs/superpowers/specs/2026-05-05-slash-cli-repl-elixir-native.md` (Elixir-native CLI/REPL/admin unification)
- Phase 3: `docs/superpowers/specs/2026-05-05-plugin-physical-migration.md` (voice delete + feishu/cc_mcp extract)
- Phase 4: `docs/superpowers/specs/2026-05-05-phase-4-cleanup.md` (cleanup tail)

This document combines (a) the **PR-by-PR sequence** I'll execute and (b) the **operating principles** I'll apply when execution hits problems. User pre-approves both, then I run the plan with periodic Feishu progress reports.

---

## 一、PR sequence

### Phase 2 — Slash / CLI / REPL Elixir-native unification (~9 PRs)

| PR | Scope | Spec ref | Risk |
|---|---|---|---|
| **PR-2.0** | Delete `runtime/lib/esr/voice/` + agents.yaml entries + voice plugin manifest | spec §6.0 | Low — never used |
| **PR-2.1** | Extract `Esr.Slash.CleanupRendezvous` + `Esr.Slash.QueueResult` modules from `Esr.Admin.Dispatcher` (single split, no behaviour change) | spec §3.1 | Medium — touches core admin path |
| **PR-2.2** | Delete `Esr.Admin.Dispatcher`; route admin file submissions through `Esr.Slash.QueueWatcher` → `SlashHandler.dispatch/3` | spec §3.2 | Medium |
| **PR-2.3** | Rename `Esr.Admin.Commands.*` → `Esr.Commands.*` (mechanical, follow-the-types) | spec §3.3 | Low — find/replace + test |
| **PR-2.4** | Add `Esr.Slash.ReplyTarget` behaviour with `ChatPid` / `QueueFile` / `IO` impls; `SlashHandler.dispatch/3` delegates reply via behaviour | spec §3.4 | Medium |
| **PR-2.5** | Mix escript skeleton: `runtime/escript/esr_cli.ex` entry + dist-Erlang RPC to running esrd | spec §4.1 | Medium — new build artefact |
| **PR-2.6** | Implement `esr {plugin,actor,cap,scope,workspace} *` subcommands as escript routes calling SlashHandler.dispatch/3 with `IO` ReplyTarget | spec §4.2 | Medium |
| **PR-2.7** | `runtime.exs` reads `enabled_plugins:` from `plugins.yaml`; `Esr.Application.start/2` no longer needs plugin-specific bootstraps | spec §5 | Low (already done in Track 0; verify gate) |
| **PR-2.8** | `mix escript.install` instructions in dev-guide.md; deprecation notice on Python `esr` | spec §6 | Low |

**Phase 2 done when:** `esr plugin list` from escript matches Python output, full e2e suite green, `Esr.Admin.Dispatcher` does not exist.

### Phase 3 — Plugin physical migration (~7 PRs)

| PR | Scope | Spec ref | Risk |
|---|---|---|---|
| **PR-3.1** | `Esr.Plugin.Loader` start-link order: manifests load BEFORE `Esr.Application` registers fallback Sidecar mappings; remove fallbacks | spec §3 | Medium |
| **PR-3.2** | `Esr.Entity.Agent.PlatformProxyRegistry` — extract from current AgentSpawner inline logic, declared in plugin manifest | spec §4.1 | Medium |
| **PR-3.3** | Move feishu modules from `runtime/lib/esr/{entity,scope,resource}/...feishu*` → `runtime/lib/esr/plugins/feishu/<same-substructure>/`, update manifest, update agents.yaml refs | spec §5.1 | High — multi-module rename + cross-namespace callers |
| **PR-3.4** | feishu plugin owns `bootstrap_feishu_app_adapters/0` via plugin startup hook; `Esr.Scope.Admin` loses the function | spec §5.2 | Medium |
| **PR-3.5** | HTTP MCP transport for cc_mcp: replace stdio with HTTP POST so cc_mcp lifecycle decouples from claude tmux session | spec §6.1, [docs/issues/02 channel-abstraction] | High — new transport |
| **PR-3.6** | Move cc_mcp modules from `runtime/lib/esr/entity/cc_*` → `runtime/lib/esr/plugins/claude_code/...`, update manifest | spec §6.2 | High |
| **PR-3.7** | Remove the 4 feishu-named hardcodings in `cc_process.ex` + 5 cross-namespace callers; cc plugin no longer references "feishu" anywhere | spec §6.3 | High — multi-module surgery |

**Phase 3 done when:** every line under `runtime/lib/esr/{entity,scope,resource}/` is plugin-agnostic core; feishu/cc each fully owns its plugin dir; full e2e suite green; `tools/esr-debug term-text` shows the same PTY content as before.

### Phase 4 — Cleanup tail (~7 PRs)

Per the Phase 4 spec — Group A through G as PR-4.1 → PR-4.7. Lower-risk than Phase 2/3 (purely removal). Will only kick this off after Phase 3 lands cleanly.

---

## 二、AFK operating principles

These are the rules I'll follow when something unexpected happens. User pre-approves these; I apply them without ping unless the situation matches the **WAKE USER** column.

### Principle 1 — Plan-time gates

| Gate | Action |
|---|---|
| Spec is unambiguous about a PR's scope | Just do the PR (use subagent-driven-development, two-stage review per skill) |
| Spec leaves a design point open ("TBD" / "decide at impl time") | **WAKE USER** — Feishu with the open point + my recommended choice |
| Mid-Phase plan changes recommended (e.g., found that PR-3.5 should land before PR-3.3) | **WAKE USER** — Feishu with the proposed reorder + reasoning |

### Principle 2 — Implementation-time gates

| Situation | Action |
|---|---|
| Implementer subagent asks a clarifying question I can answer from the spec | Answer, continue |
| Implementer subagent asks a question that requires user judgment (e.g., naming choice not fixed in spec) | **WAKE USER** — Feishu with the question + my recommendation |
| Spec-reviewer subagent finds non-compliance | Implementer fixes, re-review (per subagent-driven-development skill) |
| Code-quality reviewer finds important issues | Implementer fixes, re-review |
| Reviewer finds the spec is wrong (not just the implementation) | **WAKE USER** — Feishu with the contradiction + which side I'd pick |

### Principle 3 — E2E and CI gates

| Situation | Action |
|---|---|
| e2e fails with a known flake (claude latency, network) | Re-run up to 2× more; if still flaky, mark the PR as "passed with known flake" in the merge comment, continue |
| e2e fails with a regression | Block PR, RCA via `tools/esr-debug` + agent-browser screenshot, fix, re-run |
| pre-merge-dev-gate fails on agent-browser content assertion | Block PR, RCA — this is the unshakeable bar (Standard 1+2). **WAKE USER** if RCA takes >30 min |
| Test suite hits an unrelated flaky test | Re-run the failing test only (not the whole suite); if pattern repeats across PRs, **WAKE USER** with the pattern |

### Principle 4 — Branch and merge gates

| Situation | Action |
|---|---|
| PR-N depends on PR-M; PR-M not yet merged | Wait for M; do not stack speculatively |
| Branch protection blocks merge ("REVIEW_REQUIRED") | Use `gh pr merge --admin --squash --delete-branch` (memory rule: admin bypass authorized for ezagent42/esr) |
| GitHub or `gh` CLI returns network error | Retry up to 3×; if still failing, **WAKE USER** |
| Merge conflict against dev | Rebase locally; if conflicts touch unfamiliar files, **WAKE USER** |

### Principle 5 — Resource and time gates

| Situation | Action |
|---|---|
| Claude weekly rate limit triggers a pause | **WAKE USER** immediately with current PR-X of Y status, time of expected resume |
| Single PR takes > 60 min of wall time | **WAKE USER** with what's stuck and my plan to unstick |
| Phase as a whole exceeds my estimate by >50% | **WAKE USER** with revised ETA |

### Principle 6 — Communication cadence

- **Per-PR**: one Feishu reply on merge with `[N% — PR-X of Y of Phase-Z]` + 1-line summary.
- **Per-phase**: at start, "starting Phase Z"; at end, "Phase Z complete (M PRs, K LOC delta)".
- **On WAKE**: clear `🚨 ATTENTION` prefix in the Feishu reply.
- **On routine progress**: short, scannable, no need for user response.

### Principle 7 — Hard stop conditions

I will stop and wake the user **regardless of recommendation logic** if:
1. A destructive operation is needed against shared state (e.g., dropping a registry, force-pushing to main).
2. I find evidence the spec's foundational assumption is wrong (e.g., HTTP MCP transport breaks cc_mcp's auth; feishu plugin extraction reveals 20+ cross-namespace callers, not the 5 documented).
3. e2e Standards 1+2 fail and I cannot fix them within 30 min.
4. The user sends a Feishu message — I check, respond, then continue.

---

## 三、What I will NOT auto-decide

- **Cross-cutting refactors not in the spec**: even if they look obviously beneficial.
- **Renaming public API surface**: e.g., the `mcp__esr-channel__reply` tool name — even if Phase 3 would benefit.
- **Adding new dependencies** (mix deps, npm packages, py packages): each requires user approval.
- **Skipping subagent review** because "the change is small": memory rule says all specs and plans get reviewer-pass; same applies to material PRs.
- **Touching files outside the spec's scope** without flagging.

---

## 四、Approval form

User picks one:

**A) Approve as written.** I execute Phase 2 → 3 → 4 per the PR sequence with the operating principles applied.

**B) Approve with amendments.** Tell me which principles to change.

**C) Defer.** Pause execution; user wants to review the spec details before authorizing.

After approval (A or B), I'll:
1. Use the `superpowers:writing-plans` skill to expand each Phase into a TDD plan file (with subagent code-review per memory rule).
2. Send each phase's plan path to user via Feishu before starting that phase's implementation.
3. Execute under `superpowers:subagent-driven-development` skill, one PR at a time.

---

## 五、Estimates (honest)

- **Phase 2 (~9 PRs)**: 4–8 hours of wall time depending on subagent iteration cycles. Most uncertain part: PR-2.5 (escript build) and PR-2.6 (subcommand routing).
- **Phase 3 (~7 PRs)**: 6–10 hours. Most uncertain: PR-3.5 (HTTP MCP transport) and PR-3.7 (cc_process feishu de-coupling).
- **Phase 4 (~7 PRs)**: 2–4 hours. Mostly mechanical removal.

Total ~12–22 hours wall time. Will be punctuated by claude weekly-limit pauses; I'll Feishu when I hit one.

If user approves now, I won't pre-write the Phase-2 detailed plan in this same response — that goes through writing-plans + subagent review and lands as a separate file. Would deliver to Feishu within 30 min of approval.
