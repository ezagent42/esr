# ESR Structural Refactor Plan — R4 through R11+

**Date:** 2026-05-04 (rev 3 — autonomous-execution edition)
**Audience:** anyone reviewing/executing structural splits after R1-R3 (mechanical renames) landed
**Status:** prescriptive plan; companion to `concept-rename-map.md` and `refactor-lessons.md`. The user is AFK from rev-3-final until R11 lands; §十一 (autonomous-decision principles) governs every judgment call until they're back.

---

## 一、Where we are after R1-R3

R1-R3 mechanical renames complete on dev. Four-namespace symmetry mirrors the metamodel's runtime primitives:

```
Esr.Application       (OTP boot; ≡ DaemonScope per concepts.md §🔧-5)
Esr.Scope.*           (Scope primitive: base + infra + kinds e.g. Scope.Admin)
Esr.Entity.*          (Entity primitive: behaviour + infra + base types e.g. Entity.User; also flat concrete instances after R4)
Esr.Resource.*        (Resource type instances)
Esr.Admin.*           (admin subsystem)
Esr.Topology / Esr.Telemetry.* / Esr.Persistence.* / Esr.Yaml.* / Esr.Workers.* / EsrWeb.*  (infra/framework)
```

> Note: R2 created `Esr.Entities.*` (plural) for concrete instance modules. R4 collapses that into `Esr.Entity.*` for namespace symmetry — see §2.6. There is no `Esr.Entities.*`, `Esr.Resources.*`, or `Esr.Scopes.*` after R4.

What's missing: `Esr.Interface.*` — the contract layer that the metamodel calls out (concepts.md §五, session.md §七) but code hasn't extracted yet. R4 introduces it as a **big bang** (all critical Interfaces at once) per user 2026-05-03.

---

## 二、Guiding principles (per user 2026-05-03)

These principles drive every naming/sequencing decision in R4-R11. **§十一** elaborates with concrete defaults for autonomous execution.

### 2.1 "True Resource" criterion

> A "true Resource" is one that can be **consumed by multiple Entity types**. If only one Entity type uses it, it's not a Resource — it lives under that Entity type's namespace.

Applying:
- `Esr.Entity.User.Registry` — only User-Entity consumes → correctly under `Esr.Entity.User.*`
- `Esr.Resource.Capability.Grants` — multi-User, multi-Agent consume → Resource ✓
- `Esr.AdapterSocketRegistry` → must move to `Esr.Resource.*` (multi-Adapter consumer)

### 2.2 "Verb-er ⇒ Interface" criterion

> Any module whose name describes an action (Spawner, Loader, Router, Dispatcher, Watcher) is an **Interface contract** if it has — or will plausibly have — multiple implementers. Declare the Interface even if there's only one implementer today, when the second is foreseen.

Applying:
- `Spawner` — AgentSpawner today, GroupChatSpawner / DaemonSpawner in Phase 4 → Interface
- `Router` — ScopeRouter + HandlerRouter exist today → Interface
- `Dispatcher` / `Operation` — AdminDispatcher today, more dispatchers possible → Interface
- `FileLoader` — already 4 implementers (Cap/SlashRoute/Perm/Workspace) → Interface
- `Watcher` — paired with FileLoader; same Interface family

### 2.3 Nested naming over flat suffix-encoded names

> If "Registry" / "Queue" / "Router" is an Interface name, **don't double-encode** by stuffing it into module names. Use nesting: `Esr.Resource.AdapterSocket.Registry` (the AdapterSocket Resource has a Registry sub-module that implements `Esr.Interface.LiveRegistry`).

R3 left two flat-suffixed names that need cleanup:
- `Esr.Resource.SlashRouteRegistry` → `Esr.Resource.SlashRoute.Registry`
- `Esr.Resource.DeadLetterQueue` → `Esr.Resource.DeadLetter.Queue`

### 2.4 Interface-first sequencing

> Define the contract before the implementer. New modules `@behaviour`-conform from day one; downstream R-batches don't have to backfill.

This is why **R4 is the Interface big bang** — once the contracts exist, R5/R6/R7 use them as new modules ship.

### 2.5 DaemonScope ≡ `Esr.Application`

> No separate `Esr.Scope.Daemon` or `Esr.DaemonScope` module. The OTP application IS the daemon scope. `Esr.Application` stays unrenamed as the runtime root.

(See concepts.md §🔧-5 for the canonical statement.)

### 2.6 All-singular namespace symmetry

> Each metamodel primitive gets exactly one namespace, and that namespace is **singular**. Drop any plural-namespace siblings.

R2 left `Esr.Entities.*` (plural, 14 concrete entity instance modules) sibling to `Esr.Entity.*` (singular, primitive infrastructure + base types). This breaks symmetry — no equivalent `Esr.Resources.*` / `Esr.Scopes.*` exists. Per user 2026-05-03: collapse the asymmetry.

**R4 absorbs this collapse**: `Esr.Entities.{CCProcess, PtyProcess, FeishuAppAdapter, ...}` → `Esr.Entity.{CCProcess, PtyProcess, FeishuAppAdapter, ...}` (flat at `Esr.Entity.*`, alongside `Esr.Entity.User.*` already established by R3).

After R4: `Esr.Entity.*`, `Esr.Resource.*`, `Esr.Scope.*` all singular and mutually consistent. No `Esr.{Entities, Resources, Scopes}.*`.

---

## 三、Registry API surface audit (input to R4)

Audit of the 7 registry-flavored modules surfaces two distinct shapes:

### Shape A: Live-pid registry (runtime register/lookup/unregister)

| Module | API |
|---|---|
| `Esr.Entity.Registry` | `register(actor_id, pid)` / `lookup(actor_id)` / auto-cleanup on pid death; `list_all()` |
| `Esr.AdapterSocketRegistry` (→ `Esr.Resource.AdapterSocket.Registry` after R4) | `register(sid, opts)` / `lookup(sid)` / `mark_offline(sid)` (soft); `list()` / `notify_session/2` |
| `Esr.Scope.Registry` | Elixir kernel `Registry` (no wrapper module — used via `{:via, Registry, ...}`) |

### Shape B: Snapshot / yaml-backed registry (bulk-load + read)

| Module | API |
|---|---|
| `Esr.Entity.User.Registry` | `load_snapshot(map)` / `get(username)` / `lookup_by_feishu_id(id)` / `list()` |
| `Esr.Resource.Workspace.Registry` | `load_from_file(path)` / `put(%Workspace{})` / `get(name)` / `list()` / `workspace_for_chat/2` ¹ |
| `Esr.Resource.Capability.Grants` | `load_snapshot(map)` / `has?(principal, perm)` |
| `Esr.Resource.SlashRouteRegistry` (→ `Esr.Resource.SlashRoute.Registry` after R4) | `load_snapshot(map)` / `lookup(text)` / `permission_for/command_module_for/route_for_kind` / `list_slashes()` |

¹ Hybrid: snapshot via `load_from_file` + per-entry `put/1`. R5's `Esr.Resource.ChatScope.Registry` will follow the same hybrid pattern.

**Co-existence with `Esr.Role.State`**: all 7 modules already declare `@behaviour Esr.Role.State`. R4's new behaviours **stack on top of** `Esr.Role.State`, not replace it.

---

## 四、R-batch plan (sequential, one PR per batch)

### R4 — Interface big bang + Resource naming cleanup

**Scope (combined per user 2026-05-03):**

1. **Create `Esr.Interface.*` namespace** with these modules:
   - `Esr.Interface.LookupRegistry` (`@callback lookup(key) :: {:ok, value} | :error`; `@callback list() :: [{key, value}]`)
   - `Esr.Interface.LiveRegistry` (extends LookupRegistry; `@callback register(key, value) :: :ok | {:error, _}`; `@callback unregister(key) :: :ok`)
   - `Esr.Interface.SnapshotRegistry` (extends LookupRegistry; `@callback load_snapshot(map) :: :ok`)
   - `Esr.Interface.Routing` (`@callback dispatch(envelope, ctx) :: :ok | {:error, _}`)
   - `Esr.Interface.Operation` (`@callback enqueue/execute/report` per session.md §七)
   - `Esr.Interface.FileLoader` (`@callback load(path) :: :ok | {:error, term}`)
   - `Esr.Interface.Spawner` (`@callback spawn(decl, params, ctx) :: {:ok, pid} | {:error, _}`)
   - `Esr.Interface.JobQueue` (`@callback enqueue/dequeue/report` per session.md §七)

2. **Resource naming cleanup** — un-stuff Interface names from module suffixes:
   - `Esr.Resource.SlashRouteRegistry` → `Esr.Resource.SlashRoute.Registry`
   - `Esr.Resource.DeadLetterQueue` → `Esr.Resource.DeadLetter.Queue`
   - `Esr.AdapterSocketRegistry` → `Esr.Resource.AdapterSocket.Registry` (also moves to `Esr.Resource.*` per "true Resource" criterion — this absorbs R8 from rev 2)

2.5. **Entity namespace collapse** (per §2.6) — fold plural `Esr.Entities.*` into singular `Esr.Entity.*`:
   - `Esr.Entities.CCProcess` → `Esr.Entity.CCProcess`
   - `Esr.Entities.PtyProcess` → `Esr.Entity.PtyProcess`
   - `Esr.Entities.FeishuAppAdapter` → `Esr.Entity.FeishuAppAdapter`
   - `Esr.Entities.FeishuAppProxy` → `Esr.Entity.FeishuAppProxy`
   - `Esr.Entities.FeishuChatProxy` → `Esr.Entity.FeishuChatProxy`
   - `Esr.Entities.CCProxy` → `Esr.Entity.CCProxy`
   - `Esr.Entities.SlashHandler` → `Esr.Entity.SlashHandler`
   - `Esr.Entities.CapGuard` → `Esr.Entity.CapGuard`
   - `Esr.Entities.UnboundChatGuard` → `Esr.Entity.UnboundChatGuard`
   - `Esr.Entities.UnboundUserGuard` → `Esr.Entity.UnboundUserGuard`
   - `Esr.Entities.VoiceASR` / `VoiceASRProxy` / `VoiceTTS` / `VoiceTTSProxy` / `VoiceE2E` → `Esr.Entity.{...}`
   - File moves: `runtime/lib/esr/entities/*.ex` → `runtime/lib/esr/entity/*.ex`
   - **15 modules** (15 files in `runtime/lib/esr/entities/`); corresponding test moves: `runtime/test/esr/entities/*.exs` → `runtime/test/esr/entity/*.exs` (14 test files — no `unbound_user_guard_test.exs` exists)
   - **Conflict watch:** `Esr.Entity.User.*` exists (User base type from R3); the 14 concrete instance modules don't collide names with User sub-modules. But future base-type-classification (Agent / Adapter / Handler) might want to nest concrete instances under their type. Defer that classification — flat at `Esr.Entity.*` is fine for now.

3. **Add `@behaviour`** to existing implementers from day one:
   - 7 registry-flavored modules → `@behaviour Esr.Interface.{Live,Snapshot}Registry`
   - 4 FileLoader modules → `@behaviour Esr.Interface.FileLoader`
   - `Esr.Scope.Router` + `Esr.HandlerRouter` → `@behaviour Esr.Interface.Routing`
   - `Esr.Admin.Dispatcher` → `@behaviour Esr.Interface.Operation`
   - `Esr.Resource.DeadLetter.Queue` → `@behaviour Esr.Interface.JobQueue`

4. **lookup return value normalization** — unify on `{:ok, val} | :error` (matches Map.fetch convention). Two modules currently return `:not_found` (`Esr.Entity.User.Registry`, `Esr.Resource.Workspace.Registry`).
   - **Audit caller count first**: if >10 callers pattern-match `:not_found`, defer normalization to a separate post-R4 PR.
   - Otherwise, sweep callers + normalize.

**Out of scope:**
- No new Registry instances (R5+ adds those with the Interface from day one)
- Boundary / SlashParse / Member / Identity / Agent Interfaces (deferred to R11+ — no immediate consumer)

**Files touched:** ~60-80 (8 Interface modules + 3 module renames + 15 entity moves + ~181 caller-ref updates [grep count of `Esr.Entities.` pre-R4] + ~15 `@behaviour` additions). **R4 is the largest R-batch** — be prepared for a partial bail-out (see §六 below).

**Validation:** mix compile --warnings-as-errors clean; mix test no regressions vs dev baseline (12 failures, all pre-existing flakes); e2e 06+07+DOM green; daemon state file sweep + restart.

**Bail-out:** any §六 trigger fires → revert the bad pass + redo the part that broke.

---

### R5 — Split `Esr.SessionRegistry` (329 LOC → 0)

**Prerequisite:** R4 done (uses `Esr.Interface.SnapshotRegistry` + `LiveRegistry` from day one).

**Scope:**
1. Create `Esr.Entity.Agent.Registry` — agents.yaml cache + hot-reload
   - `@behaviour Esr.Interface.SnapshotRegistry` + `Esr.Interface.FileLoader` (the loader sub-module)
   - 4-piece pattern (Registry + FileLoader + Watcher + Supervisor) like Capability/SlashRoute
2. Create `Esr.Resource.ChatScope.Registry` — `(chat_id, app_id) → session_id` routing
   - `@behaviour Esr.Interface.LiveRegistry` (register at session create; unregister at session end)
   - ETS-backed; consumers: Adapter Entities + control-plane (multi-consumer → Resource ✓)
3. Delete `Esr.SessionRegistry`. Migrate all callers to the two new homes + existing `Esr.Entity.Registry` (third concern: `(sid, name) → pid` ≡ actor_id `"<name>:<sid>"` lookup).

**Out of scope:**
- Scope.Router internal split (R6)
- Topology declaration as code modules (Phase 4 future)

**Files touched:** ~30 (delete 1, create 2 with their FileLoader/Watcher 4-piece, migrate ~25 callers)

---

### R6 — Split `Esr.Scope.Router` (799 LOC → ~150 + new modules)

**Prerequisite:** R4 done (uses `Esr.Interface.Spawner` from day one).

**Scope:**
1. Trim `Esr.Scope.Router` to lifecycle coordinator (~150 LOC). Adds `@behaviour Esr.Interface.Routing`.
2. Create `Esr.Session.AgentSpawner` (~400 LOC) with `@behaviour Esr.Interface.Spawner`.
   - Reads agent declaration from `Esr.Entity.Agent.Registry` (R5 output)
   - Spawns Entity instances via `Esr.Entity.Factory.spawn_peer/5`
   - Builds neighbor refs and ctx (current `backwire_neighbors` + `build_ctx`)
3. Fold `parse_channel_adapter/1` + helpers into Spawner as **private helper** (no new module).
4. Move `resolve_workspace_start_cmd/2` + `expand_start_cmd/1` to `Esr.Resource.Workspace.Registry` as a public function `start_cmd_for/1`.
5. Test-only public APIs (`build_ctx_for_test/2`, `stamp_channel_adapter_for_test/2`) — relocate to AgentSpawner test helpers OR drop if they leak production state inappropriately.

**Files touched:** ~15

---

### R7 — Audit + possibly split `Esr.Admin.Dispatcher` (448 LOC)

**Prerequisite:** R4 done (uses `Esr.Interface.Operation` if split happens).

**Scope:**
1. **Audit phase** — inspect Dispatcher's actual concerns. Likely: command-queue consume + result-report + auth-context propagation.
2. **Decide autonomously per §十一**:
   - If concerns are tightly coupled (shared state, hot-path performance critical) → **stay monolithic** + add `@behaviour Esr.Interface.Operation`. Simple PR.
   - If concerns are independent → **split into 2-3 modules**. Each implements relevant Interface.
3. **`Esr.Admin.Commands.Scope.BranchEnd` (453 LOC)** — audit during R7 too. If single-command-bundling, split.

---

### R8 — (absorbed into R4) `AdapterSocketRegistry` move

**Status:** Absorbed into R4 per "Resource naming cleanup" (§四-R4 step 2). No standalone R8 PR.

---

### R9 — Capabilities + Permissions Interface declarations

**Prerequisite:** R4 done.

**Scope:**
1. Create `Esr.Interface.CapabilityDeclaration` — `@callback name/0`, `description/0`, `required_for/0`
2. Create `Esr.Interface.Grant` — `@callback grant/2`, `revoke/2`, `check/2`
3. Add `@behaviour` to `Esr.Resource.Capability.*` and `Esr.Resource.Permission.*` modules as appropriate.

**Out of scope:** Splitting the existing modules (façade stays); zero functional change.

**Files touched:** ~10

---

### R10 — Workspace metamodel role doc clarification (DOC-ONLY)

**Scope:** Add to `concepts.md` and `session.md` a paragraph stating Workspace is a Dir-flavor Resource type with its own schema (owner/start_cmd/role/chats/env), NOT a composition of Dir+Capability.

**Files touched:** 1-2 doc files

---

### R11+ — Other Interfaces (rolling, small PRs)

Per session.md §七, ~10 more Interfaces to extract over time. Each = small standalone PR.

Suggested order:
1. `Esr.Interface.Channel` (publish/subscribe/frame) — used by every actor
2. `Esr.Interface.Boundary` + `Esr.Interface.BoundaryConnection` — Adapter Entity contract
3. `Esr.Interface.Boot` — Application's contract (`Esr.Application` adds `@behaviour`)
4. `Esr.Interface.SlashParse` — SlashHandler's contract
5. `Esr.Interface.Member` — every Scope member's contract
6. `Esr.Interface.Identity` — User-Entity's contract
7. `Esr.Interface.Agent` — Agent-Entity's contract
8. `Esr.Interface.EventHandler` + `Esr.Interface.Purity` — Handler's contracts

Each is one Interface module + adding `@behaviour` to 1-3 implementers.

---

### R-future — Defer `Esr.Entity.Server` (1015 LOC)

Per-Entity host is multi-concern by nature. High split risk, low immediate ROI. Trigger to revisit: any future PR adding a 5th major concern OR Entity.Server hits 1500 LOC.

---

## 五、Sequencing rationale

- **R4 first (Interface big bang)** — every downstream R-batch uses Interfaces. Defining them all up front means R5/R6/R7 don't need follow-up "backfill `@behaviour`" PRs.
- **R5 before R6** — R6's Spawner needs R5's Esr.Entity.Agent.Registry as its data source.
- **R6 before R7** — both are bundled-concern splits; R6 is bigger, building confidence in the Spawner pattern that R7 may reuse.
- **R8 absorbed into R4** — naming cleanup doesn't warrant its own PR; bundle with R4's Interface introduction (same naming convention establishment).
- **R9 after R4** — needs Interfaces in place; can run parallel to R5/R6 if branched correctly (but autonomously: serial is safer).
- **R10 (doc-only)** — anytime; no code dependency.
- **R11+ (rolling)** — start after R10; each independent.

---

## 六、Bail-out criteria (per refactor-lessons.md §五)

Stop and revert the bad pass if any of these triggers fire on any R-batch:

| Trigger | Action |
|---|---|
| `mix test` failures > 10× baseline (>120) | Revert the bad pass; don't point-fix (C1) |
| `mix compile` undefined-function errors in load-bearing modules | Surface first; cascade is likely (C2) |
| Daemon won't restart with new build | Revert; yaml-cache or bootstrap is broken (C3) |
| User-state yaml unparseable after rename | Revert; missed a stringified module reference (C4) |
| BEAM **crashes** during `mix test` (non-zero exit, no failure count emitted) | Revert immediately; treat as worse than C1 (C7) |
| DOM dataset out of range despite e2e green (cols ∉ [100,300] or rows ∉ [30,100]) | Investigate xterm sizing first (PR-22/24 lessons); revert if cause not found in 30 min (C6) |

**R4-specific tiered bail-out:** R4 is the biggest R-batch (60-80 files, ~181 caller refs). If C1 fires on first attempt, **before full revert** try a tiered redo:
1. Interface big-bang only (§四-R4 step 1) — minimal scope
2. + Resource naming cleanup (step 2) — small additive
3. + Entities collapse (step 2.5) — biggest piece
4. + lookup normalization (step 4) — last

If tier-1 alone bails: full revert + escalate per §M2.

Per §十一-M, on bail-out: write incident note → revert → redo smallest piece first → if second attempt also bails → leave PR as WIP and skip to next R-batch.

---

## 七、Open questions — RESOLVED in rev 3

All §七 open questions from rev 2 resolved per user 2026-05-03 + my recommendations (since user is going AFK):

| # | Resolution |
|---|---|
| 1 | Interface design: **Option 2** — separate `Esr.Interface.{LookupRegistry, LiveRegistry, SnapshotRegistry}` modules |
| 2 | lookup return value: **unify on `:error`**, but **audit caller count first**; if >10 callers pattern-match `:not_found`, defer normalization to a follow-up PR |
| 3 | parse_channel_adapter: **fold into Spawner as private helper** (no new module) |
| 4 | R10 + R9 bundling: **keep separate** (R9 is code-touching; R10 is doc-only; mixing makes review harder) |
| 5 | Entity.Server: **defer** unless a R4-R11 PR reveals a real blocker |

---

## 八、Files >400 LOC not directly covered by R4-R11 (appendix)

| File | LOC | Disposition |
|---|---|---|
| `runtime/lib/esr/entities/feishu_chat_proxy.ex` | 682 | **Touched as caller during R4-R11** but no dedicated split PR. e2e covers the full feishu→cc chain; if e2e regresses during a R-batch, the cause is mostly in the new module, not feishu_chat_proxy itself. |
| `runtime/lib/esr/entities/slash_handler.ex` | 627 | R11 will add `@behaviour Esr.Interface.SlashParse` here. No split unless R11 reveals concerns. |
| `runtime/lib/esr/entities/cc_process.ex` | 623 | Same as feishu_chat_proxy: caller-touched only, no dedicated split. |
| `runtime/lib/esr_web/cli_channel.ex` | 638 | R11 may add `@behaviour Esr.Interface.Boundary`. Phoenix Channel; revisit after R11 lands. |
| `runtime/lib/esr/admin/commands/scope/branch_end.ex` | 453 | R7 audit will inspect (single Admin command at 453 LOC suggests bundled concerns). |
| `runtime/lib/esr/application.ex` | 442 | R11 adds `@behaviour Esr.Interface.Boot`. No split — application IS DaemonScope. |
| `runtime/lib/esr/os_process.ex` | 405 | Out of scope — already a base behaviour module for erlexec subprocess hosts. |

---

## 九、e2e test schedule per R-batch

Every R-batch follows this validation flow (matches refactor-lessons.md §四 playbook):

1. **Branch + grep baseline** — capture pre-rename module reference counts
2. **Code substitution + file moves** — long-first regex order
3. **`mix compile --warnings-as-errors`** — must be clean
4. **`mix test`** — count failures; compare to dev baseline (currently ~12)
5. **Per-failure isolation check** — extras over baseline must pass in isolation (= flake), else investigate as real regression
6. **Daemon state file sweep** — `~/.esrd-dev/default/{*.yaml,*.json}` patched + verified no stale module refs
7. **`launchctl unload && launchctl load`** — restart esrd-dev with new build
8. **`bash tests/e2e/scenarios/06_pty_attach.sh`** — HTML shell smoke
9. **`bash tests/e2e/scenarios/07_pty_bidir.sh`** — full BEAM ↔ cc_mcp roundtrip
10. **DOM dataset check** — `cols ∈ 100..300`, `rows ∈ 30..100` via the Chrome incantation in `scripts/hooks/pre-merge-dev-gate.sh`
11. **Open PR** with full validation summary in description
12. **`gh pr merge --admin --squash --delete-branch`** — pre-merge-dev gate hook re-runs steps 8-10 as the final guard
13. **`git checkout dev && git pull`** — sync; verify HEAD

**For doc-only batches (R10):** skip steps 6-10; lib code untouched.

**For pure-Interface batches (R4 step 1, R9, R11+):** still run all 13 steps — even though zero functional change is intended, the @behaviour additions can surface dialyzer-discovered violations.

---

## 十、Related docs

- `docs/notes/concept-rename-map.md` — original R1-R6 rename catalog (rev 6 has DaemonScope ≡ Application + AdminScope under Scope.*)
- `docs/notes/refactor-lessons.md` — R1-R3 lessons
- `docs/notes/concepts.md` / `session.md` / `mechanics.md` — metamodel
- `scripts/hooks/pre-merge-dev-gate.sh` — gate enforcement

---

## 十一、Autonomous-decision principles (R4-R11 execution while user is AFK)

The user will be offline from rev-3-final until R11 completes. These are the defaults I'll use for every judgment call. **If a situation isn't covered here, default to the more conservative / smaller / more reversible option, document the choice in the PR description as "decided autonomously per principle §X", and surface for post-hoc review.**

### A. Naming
- **A1** — Always use nested namespacing: `Esr.Resource.X.Registry`, NOT `Esr.Resource.XRegistry`. Same for Queue/Router/Loader.
- **A2** — Verb-er module names ⇒ Interface contract exists. If a second implementer is foreseen (Phase 4), declare the Interface now.
- **A3** — "True Resource" criterion: data consumed by ≥2 Entity types lives at `Esr.Resource.*`; single-Entity-type data lives at `Esr.Entity.<Type>.*`.
- **A4** — `Esr.Application` ≡ DaemonScope; never create `Esr.Scope.Daemon`.
- **A5** — All-singular namespaces. After R4: `Esr.Entity.*`, `Esr.Resource.*`, `Esr.Scope.*`. **Never** create `Esr.Entities.*`, `Esr.Resources.*`, or `Esr.Scopes.*`.

### B. Sequencing
- **B1** — Interface-first: any new contract gets `Esr.Interface.X` declared **before or with** its first implementer.
- **B2** — Long-first regex order in mass substitutions (lessons §三-2).
- **B3** — One R-batch = one PR. Don't bundle PRs to "save round trips" — that risks R3-style cascade.
- **B4** — If a downstream R-batch needs to extend an Interface defined in a prior R-batch: extend in-place via **additive** `@callback` (additive = back-compat) within the current R-batch; document in PR description as a §B4 extension. Don't open a separate "R4.1 extend Interface" PR.

### C. Bail-out (immediate revert + smaller redo)
- **C1** — `mix test` failures > 10× dev baseline (>120) → revert.
- **C2** — `mix compile` reveals undefined-function errors in lib/ (not test/) load-bearing modules → revert.
- **C3** — Daemon won't restart cleanly after `launchctl load` → revert.
- **C4** — User-state yaml file unparseable after sweep → revert.
- **C5** — On bail-out: don't grind point-fixes. Revert the entire R-batch. Redo with smaller scope (split into 2 R-batches if needed).
- **C6** — DOM dataset out of range despite e2e green (cols ∉ [100,300] or rows ∉ [30,100]) → investigate xterm sizing first (PR-22/24 lessons re: rows/cols swap, ResizeObserver, virtual-time-budget); revert if cause not found in 30 min.
- **C7** — `mix test` **crashes** the BEAM (non-zero exit, no failure count emitted) → revert immediately. Treat as worse than C1 — a crash means an init/1 callback or supervisor child can't start, not a test assertion failure.

### D. Doc handling
- **D1** — Don't rewrite historical docs: `docs/superpowers/{plans,specs,progress}/`, `docs/issues/closed-*`, `docs/notes/{pubsub-audit-pr3,tmux-*,erlexec-migration,feishu-ws-ownership-python,pr7-wire-contracts,manual-e2e-verification,pty-attach-diagnostic,describe-topology-security,capability-name-format-mismatch,yaml-authoring-lessons}.md`, `docs/futures/{esr-attach-cli,cross-workspace-messaging-handler,*}.md`, `docs/operations/dev-prod-isolation.md`, `docs/plans/`. If mass-substitution touches them, revert with `git checkout HEAD -- <path>`.
- **D2** — DO update active docs: `docs/architecture.md`, `docs/notes/{concepts,session,mechanics,concept-rename-map,refactor-lessons,structural-refactor-plan-r4-r11,actor-role-vocabulary}.md`, `docs/futures/todo.md`, `docs/operations/known-flakes.md`, `docs/guides/writing-an-agent-topology.md`.

### E. Daemon state files
- **E1** — After every code rename, sweep `~/.esrd-dev/default/*.{yaml,json}` for stale module names with the same prefix-substitution regex used in lib code. Example for R4 Entity collapse:
  ```bash
  for f in ~/.esrd-dev/default/*.yaml ~/.esrd-dev/default/*.json; do
    grep -l 'Esr\.Entities\.' "$f" 2>/dev/null && \
      perl -i -pe 's/\bEsr\.Entities\./Esr.Entity./g' "$f"
  done
  ```
- **E2** — Always `launchctl unload && sleep 3 && launchctl load /Users/h2oslabs/Library/LaunchAgents/com.ezagent.esrd-dev.plist` after state-file sweep + before e2e.
- **E3** — Verify daemon-up via `curl http://127.0.0.1:4001/sessions/<probe-sid>/attach` returns 200 (NOT /healthz — that route doesn't exist).
- **E4** — Sweep regex MUST use word-boundary or trailing-dot anchor (`\b` or escaped `\.`). Verify post-sweep: `grep -l '<old prefix>' ~/.esrd-dev/default/*.{yaml,json} 2>/dev/null` returns empty. If non-empty: a hypothetical longer module name (e.g., `Esr.EntitiesArchive`) was unintentionally sliced — investigate and patch by hand.

### F. Test gates
- **F1** — `mix compile --warnings-as-errors` MUST be clean. If not: investigate before proceeding.
- **F2** — `mix test` failure count must be ≤ dev baseline (currently 12). Extras over baseline must each pass in isolation (= pre-existing flake). Document confirmed flakes in `docs/operations/known-flakes.md`.
- **F3** — e2e 06 + 07 must both pass against R-built daemon.
- **F4** — DOM dataset cols ∈ [100, 300], rows ∈ [30, 100].
- **F5** — Pre-merge-dev gate (`scripts/hooks/pre-merge-dev-gate.sh`) re-runs F3+F4 on `gh pr merge`.

### G. Subagent review
- **G1** — Every NEW spec/plan/design doc gets a subagent code-reviewer pass before commit.
- **G2** — For mechanical R-batches (Interface @behaviour additions, naming nesting): subagent review optional unless something feels off.
- **G3** — For structural R-batches (R5 SessionRegistry split, R6 Scope.Router split, R7 Dispatcher audit): subagent review of the diff before merge.

### H. Communication pace (Feishu)
- **H1** — Brief at PR open + at merge. Optional: brief at major milestones within an R-batch (e.g., "lib compile clean, running tests now").
- **H2** — Don't ask for routine confirmation while user is AFK. Make the call per these principles, document in PR.
- **H3** — If a HARD blocker hits (3 consecutive R-batches fail or §十一-M triggers): leave WIP PR open, document blocker in `refactor-lessons.md`, send Feishu summary, stop.

### I. PR merge authorization
- **I1** — User authorized admin-bypass merges for ezagent42/esr planned sequences (memory rule). Use `gh pr merge --admin --squash --delete-branch`.
- **I2** — Pre-merge-dev gate must pass before merge attempt. If gate fails: investigate per §六; revert if needed.
- **I3** — After merge: `git checkout dev && git pull --ff-only` and verify HEAD.

### J. Open question default-resolutions
For decisions not pre-answered in §七 or §十一, autonomous defaults:
- **J1** — Naming: pick the more nested + Interface-aligned option.
- **J2** — Scope: smaller PR > bigger PR.
- **J3** — Migration path: one-shot rename > parallel-old-and-new compat layer (compat layers usually stay forever).
- **J4** — When two reasonable options tie: pick the one closer to existing patterns in the codebase.

### K. Pre-existing rules to respect
- **K1** — `session_id` field name: keep grandfathered. Don't rename to `scope_id` in this batch (rename-map §十 Q2).
- **K2** — Telemetry event-name atoms (`:peer`, `:session`): keep backwards-compat. Don't rename in R4-R11 (rename-map §十 Q1).
- **K3** — kind/permission strings (`"session_new"`, `"session.list"`): public API; don't rename.
- **K4** — `Esr.Workers.*`: sibling namespace, infra-only. `use Esr.Entity.Stateful` rewrites mechanically; don't move.

### L. Plugin mechanism
- **L1** — DO NOT start plugin work (per `docs/futures/todo.md` 2026-05-03 entry). Defer until R11 completes.

### M. Stuck escalation
- **M1** — Within an R-batch, if blocked > 2h on a single issue: stop, write note in `refactor-lessons.md`, leave WIP PR open with status, attempt a smaller subset of the same R-batch (e.g., R5 only with `Esr.Entity.Agent.Registry` and skip ChatScope) or move to next independent R-batch.
- **M2** — If 3 consecutive R-batches block: stop entirely, send Feishu, wait for user.
- **M3** — Cumulative time guard: if R4-R11 sequence exceeds 12 hours of execution time without R7 done, stop and send Feishu summary.

### N. Scope creep
- **N1** — Don't expand R-batch scope mid-flight (R3 lesson). If new structural issue surfaces: log in `docs/futures/todo.md` or as a new R-batch entry; do NOT add to current PR.
- **N2** — Exception: if the new issue is BLOCKING the current R-batch, address minimally + document in PR description.

### O. Known-flakes documentation
- **O1** — When confirming a flake (passes in isolation, fails in full suite), add to `docs/operations/known-flakes.md` with: test name, observed in R-batch X, isolation behavior, suspected cause if known.
- **O2** — Future R-batches see the flake list and skip re-investigating.

### P. R-batch dependency check
Before starting any R-batch, verify prerequisites:
- R5 needs R4 (LiveRegistry, SnapshotRegistry, FileLoader Interfaces)
- R6 needs R4 (Spawner, Routing) + R5 (Esr.Entity.Agent.Registry)
- R7 needs R4 (Operation Interface)
- R9 needs R4
- R11+ needs all prior R-batches

If prerequisite missing: stop, do prereq first.

### Q. PR description requirements
Every R-batch PR description must include:
1. Module renames table (old → new)
2. New Interface modules introduced (if any)
3. `@behaviour` additions
4. Untouched-but-touched callers (caller-side patches)
5. Test results (`mix test` count, isolation checks done, e2e green)
6. Bail-out triggers fired (if any) + recovery path taken
7. Decisions made autonomously per §十一 (with principle ID, e.g., "renamed via §A2 verb-er principle")

This makes user's post-hoc review easy.

---

## 十二、Final readiness checklist (before R4 starts)

- [ ] PR #170 (this doc rev 3) merged to dev
- [ ] R4 grep baseline captured to `docs/refactor/r4-grep-pre.txt` via:
  ```bash
  ( for term in 'Esr\.Entities\.' 'Esr\.AdapterSocketRegistry' 'Esr\.SessionRegistry' 'Esr\.Resource\.SlashRouteRegistry' 'Esr\.Resource\.DeadLetterQueue'; do
      count=$(grep -rn "$term" --include='*.ex' --include='*.exs' --include='*.yaml' --include='*.yml' --include='*.json' --include='*.sh' . 2>/dev/null | wc -l | tr -d ' ')
      echo "$term: $count hits"
    done ) > docs/refactor/r4-grep-pre.txt
  ```
- [ ] No PRs blocking the dev branch (current state: clean)
- [ ] esrd-dev confirmed booting from `.worktrees/dev` (PID changes after R-batch restarts validate this)
- [ ] User has acknowledged AFK + autonomous execution (per 2026-05-03 message)
