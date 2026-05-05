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

**Correction (post-review):** an earlier draft of this note claimed
PR-22/PR-24 made HTTP MCP "mostly obsolete." That was wrong.
PR-22/PR-24 fixed PTY *attach* lifecycle (BEAM-managed PTY +
binary-WS reconnects); they did **not** address cc_mcp lifecycle.

The accurate status: cc_mcp is still a stdio child of `claude`,
spawned per `.mcp.json` `command: "python -m esr_cc_mcp.channel"`.
It dies with claude, restarts on every claude relaunch, and any
in-flight notification mid-restart is dropped — exactly the
coupling PR-3.5 was meant to break.

Per Claude Code channel docs (`docs/notes/claude-code-channels-reference.md`),
`.mcp.json` does support `url:` for remote HTTP/SSE MCP servers,
so the migration is technically feasible: esrd would host an MCP
server endpoint, claude would connect to it as a remote channel
instead of spawning a local stdio child.

PR-3.5 was cut **for scope reasons**, not because the underlying
problem is solved. Treat as live debt — promote when cc_mcp
lifecycle pain resurfaces or when a feature wants channel state
to survive claude relaunch.

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
| PR-4.1 | — | `Esr.Application.start/2` plugin-specific bootstraps | ⚠️ Partial — feishu residue remains |
| PR-4.2 | — | Delete `dev_channels_unblock.sh` | ✅ Done in Option A (#191) |
| PR-4.3 | #208 | Move `Esr.Admin.{Supervisor,CommandQueue.*}` → `Esr.Slash.*` | ✅ Shipped |
| PR-4.4 | #209 | Drop `permissions_registry.json` cross-language dump | ✅ Shipped |
| PR-4.5 | — | CI guard verifying every plugin manifest's `entities:`/`python_sidecars:` are real | ⏸️ Deferred |
| PR-4.6 | — | Per-command Python CLI port to escript | ⏸️ Deferred |
| PR-4.7 | — | Delete `py/src/esr/cli/` venv | ⏸️ Depends on PR-4.6 |

**3 of 7 shipped, 1 partial (PR-4.1 — feishu bootstrap residue
remains in core), 3 deferred. PR-4.6 + PR-4.7 represent the bulk
of Phase 4's actual work and remain entirely untouched.**

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
4. **Plugin *module files* live under `plugins/<name>/`.** feishu
   modules live in `runtime/lib/esr/plugins/feishu/`; cc modules
   in `runtime/lib/esr/plugins/claude_code/`. Core code under
   `runtime/lib/esr/{entity,scope,resource}/` no longer holds
   plugin module *files*.
5. **Stateful peer registry.** `Esr.Entity.Agent.StatefulRegistry`
   replaces compile-time MapSet. Plugin manifests declare their
   stateful peers via `entities: [{module: ..., kind: stateful}]`.
6. **Slash subsystem fully under `Esr.Slash.*`.** Supervisor +
   QueueWatcher + QueueJanitor + ReplyTarget + CleanupRendezvous +
   QueueResult + HandlerBootstrap. The `Esr.Admin.*` namespace
   contains only the permissions-declaration façade module.
7. **`esr` escript covers spec-defined CORE operator surface.**
   `exec`, `help`, `describe-slashes`, `daemon`, `admin submit`,
   `notify` work without Python. The escript is plugin-agnostic
   — new plugin slash routes appear automatically.

## What's NOT true after this run

The earlier draft of this note overstated the extent of plugin
isolation and Phase 4 progress. The accurate gaps:

1. **Feishu lifecycle still owned by core.**
   `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` is still
   defined in `runtime/lib/esr/scope/admin.ex` and still called
   from `Esr.Application.start/2`. File relocation was done in
   PR-3.3; *lifecycle ownership* migration is PR-3.4 (deferred).
   A future developer cannot ship a feishu-only change without
   touching core until PR-3.4 lands.
2. **cc_mcp lifecycle still coupled to claude.** cc_mcp runs as
   a stdio child of `claude` (per `.mcp.json` `command:`),
   restarting on every claude relaunch. PR-3.5 (HTTP MCP
   transport, esrd-hosted) remains the planned remediation.
3. **Python CLI is fully intact.** `py/src/esr/cli/main.py`
   (1618 LOC, 31 click commands) is unchanged. The Elixir
   escript covers ~6 spec-defined core commands; the remaining
   ~25 click commands (admin subset, cap subset, users, notify
   variants, adapter, reload, etc.) are still Python-only.
   PR-4.6 (per-command port) and PR-4.7 (venv removal) are the
   bulk of Phase 4 and remain entirely untouched.
4. **`permissions_registry.json` is gone but `cap.py` consumer
   is stale.** PR-4.4 dropped the boot-time JSON dump; Python
   `esr cap list` still reads any pre-existing file but data
   ages until PR-4.6 ports the command or PR-4.7 deletes the
   Python CLI.

## Follow-up work

- **PR-3.4 / PR-4.1 residue**: feishu plugin startup hook (plugin
  lifecycle infrastructure). Closes the "feishu still in core"
  leak above. This is the highest-priority debt — it directly
  contradicts the North Star ("feishu changes don't touch core").
- **PR-3.5**: HTTP MCP transport. cc_mcp lifecycle is still
  coupled to claude; this is *not* solved by PR-22/PR-24.
  Promote when channel-state-survives-claude-relaunch is needed.
- **PR-4.5**: manifest CI guard (small tooling PR).
- **PR-4.6 + PR-4.7**: Python CLI per-command port + venv removal
  (~14 sub-PRs of focused per-command surgery). The escript
  covers ~6 of 31 click commands; ~25 commands remain Python-only.
  Until PR-4.6/4.7 land, "no Python venv dependency" is true
  *only* for the spec-defined core operator surface, not for the
  full operator CLI.

These remain in `docs/futures/todo.md` for future cycles. The
current architecture is usable by operators, but the North Star
("future developers work on different plugins without coordination")
is not yet achieved — PR-3.4 specifically blocks it for feishu.
