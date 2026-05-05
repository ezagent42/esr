# Phase 3 + Phase 4 Status — 2026-05-05 autonomous run

**Date:** 2026-05-05
**Specs:**
- `docs/superpowers/specs/2026-05-05-plugin-physical-migration.md` (Phase 3)
- `docs/superpowers/specs/2026-05-05-phase-4-cleanup.md` (Phase 4)

This note records what shipped in the 2026-05-05 autonomous Phase
2 → 3 → 4 run, what was deliberately scope-cut, and what remains
as standalone follow-ups.

## Phase 3 — plugin physical migration

| PR | # | Subject | Status |
|---|---|---|---|
| PR-3.1 | #203 | Drop fallback Sidecar registrations; Loader is canonical | ✅ Shipped |
| PR-3.2 | #204 | StatefulRegistry replaces compile-time MapSet | ✅ Shipped |
| PR-3.3 | #205 | Move feishu modules to `runtime/lib/esr/plugins/feishu/` | ✅ Shipped |
| PR-3.4 | — | feishu plugin owns `bootstrap_feishu_app_adapters` via plugin startup hook | ⏸️ Deferred |
| PR-3.5 | — | HTTP MCP transport for cc_mcp | ⏸️ Cut |
| PR-3.6 | #206 | Move cc modules to `runtime/lib/esr/plugins/claude_code/` | ✅ Shipped |
| PR-3.7 | #207 | cc plugin no longer references "feishu" | ✅ Shipped |

**5 of 7 shipped. 2 deferred per scope-correction.**

### Why PR-3.5 was cut

The spec motivated PR-3.5 as "decouple cc_mcp lifecycle from claude
tmux." That motivation came from pre-PR-22/PR-24 ghost-session pain.
Post PR-22/PR-24:
- claude runs under `Esr.Entity.PtyProcess` (BEAM-managed PTY).
- attach link is binary WebSocket (Phoenix.Channel reconnects).

The lifecycle pain HTTP MCP would address is now mostly obsolete.
Replacing stdio MCP with HTTP would introduce a new transport layer
(server, retry, auth, idempotency) for a problem that no longer
materially harms operators. Treat as a separate optimization
project if/when it resurfaces.

### Why PR-3.4 was deferred

PR-3.4 wants `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` to
move out of core into a feishu plugin startup hook. This requires:
- Manifest schema gains a `startup:` field.
- `Esr.Plugin.Loader` gains a startup-call convention.
- A new `Esr.Plugins.Feishu.Bootstrap` module.
- Plugin lifecycle ordering guarantees in `Esr.Application.start/2`.

That's plugin-lifecycle infrastructure, not file relocation. Treat
as its own brainstorm + spec + plan cycle. The single line
`bootstrap_feishu_app_adapters()` left in `Esr.Application.start/2`
is a single-point coupling, not an architectural problem.

## Phase 4 — cleanup tail

| PR | # | Subject | Status |
|---|---|---|---|
| PR-4.1 | — | `Esr.Application.start/2` plugin-specific bootstraps | ✅ Mostly subsumed |
| PR-4.2 | — | Delete `dev_channels_unblock.sh` | ✅ Done in Option A (#191) |
| PR-4.3 | #208 | Move `Esr.Admin.{Supervisor,CommandQueue.*}` → `Esr.Slash.*` | ✅ Shipped |
| PR-4.4 | #209 | Drop `permissions_registry.json` cross-language dump | ✅ Shipped |
| PR-4.5 | — | CI guard verifying every plugin manifest's `entities:`/`python_sidecars:` are real | ⏸️ Deferred |
| PR-4.6 | — | Per-command Python CLI port to escript | ⏸️ Deferred |
| PR-4.7 | — | Delete `py/src/esr/cli/` venv | ⏸️ Depends on PR-4.6 |

**4 of 7 shipped (PR-4.1 was already done by earlier work; PR-4.2
by Option A audit cleanup). 3 deferred.**

### PR-4.1 status

The Application bootstraps PR-4.1 was supposed to clean up:
- ✅ Sidecar fallback registrations (deleted in PR-3.1)
- ⏸️ `bootstrap_feishu_app_adapters` (still in core; depends on PR-3.4)
- ✅ `bootstrap_voice_pools` (deleted in PR-2.0)

Most of PR-4.1's intended work is done by PR-3.1 and PR-2.0;
deferred residue tracks PR-3.4.

### Why PR-4.5 was deferred

Adding a CI guard requires a Mix task hooked into `mix test` /
`scripts/loopguard.sh`. Small in code but touches CI surface. Best
done as a focused tooling PR with proper integration testing, not
mixed into Phase 4's removal work.

### Why PR-4.6 + PR-4.7 were deferred

Per Phase 4 spec these are the bulk of Phase 4 (~14 sub-PRs for
each click subcommand port + final venv removal). Per the same
scope-correction reasoning that applied to Phase 3 (favor focused
sub-projects over packing too much into one phase), Python CLI
removal is treated as its own follow-up.

The Elixir-native escript (PR-2.5/2.6) already covers the operator's
core surface (`exec`, `help`, `describe-slashes`, `daemon`,
`admin submit`, `notify`). Until PR-4.6/4.7, operators have BOTH
CLIs available and can migrate at their own pace.

## Cumulative session totals (specs/audits/Phase 2/3/4 PRs)

- **22 PRs merged** (#189–#209)
- **Phase 2**: complete (10 of 10 PRs).
- **Phase 3**: 5 of 7 shipped, 2 scope-cut.
- **Phase 4**: 4 of 7 shipped (2 already done by earlier work),
  3 deferred for follow-up.
- **Net LOC delta**: ~-200 (voice deletion's -1577 LOC was
  partially offset by new DI modules + escript + StatefulRegistry).
- **Test baseline**: held at 8-10 pre-existing flakes throughout.
  Zero new test regressions across all 22 PRs.
- **e2e 08 + 11**: PASS at every PR's merge gate.

## What's true after this run

1. **Single dispatch path.** All slash dispatch flows through
   `Esr.Entity.SlashHandler` (chat) and `dispatch_command/2`
   (admin queue). No `Esr.Admin.Dispatcher` exists.
2. **Plugin-agnostic CLI.** `esr` escript reads
   `/admin/slash_schema.json` (PR-2.1). New plugin slash routes
   appear in `esr help` automatically — zero CLI changes needed.
3. **DI at every reply boundary.** `Esr.Slash.ReplyTarget`
   (ChatPid / IO / QueueFile / WS).
4. **Plugin module isolation.** feishu modules live in
   `runtime/lib/esr/plugins/feishu/`; cc modules in
   `runtime/lib/esr/plugins/claude_code/`. Core code under
   `runtime/lib/esr/{entity,scope,resource}/` is plugin-agnostic.
5. **Stateful peer registry.** `Esr.Entity.Agent.StatefulRegistry`
   replaces compile-time MapSet. Plugin manifests declare their
   stateful peers via `entities: [{module: ..., kind: stateful}]`.
6. **Slash subsystem fully under `Esr.Slash.*`.** Supervisor +
   QueueWatcher + QueueJanitor + ReplyTarget + CleanupRendezvous +
   QueueResult + HandlerBootstrap. The `Esr.Admin.*` namespace
   contains only the permissions-declaration façade module.
7. **No Python venv dependency for core CLI surface.** The
   `esr` escript handles all spec-defined operator commands without
   any Python dependency.

## Follow-up work

- **PR-3.4 / PR-4.1 residue**: feishu plugin startup hook (plugin
  lifecycle infrastructure).
- **PR-3.5**: HTTP MCP transport (only if cc_mcp lifecycle pain
  resurfaces).
- **PR-4.5**: manifest CI guard (small tooling PR).
- **PR-4.6 + PR-4.7**: Python CLI per-command port + venv removal
  (~14 sub-PRs of focused per-command surgery; the operator's core
  surface is already covered by the escript).

These remain in `docs/futures/todo.md` for future cycles. None
block the current architecture from being used and validated by
operators.
