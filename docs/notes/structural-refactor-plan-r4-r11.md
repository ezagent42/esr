# ESR Structural Refactor Plan — R4 through R11+

**Date:** 2026-05-03
**Audience:** anyone reviewing/executing structural splits after R1-R3 (mechanical renames) landed
**Status:** prescriptive plan (rev 2 — subagent-reviewed); companion to `concept-rename-map.md`. Each R-batch is its own PR with its own subagent review.

---

## 一、Where we are after R1-R3

R1-R3 mechanical renames complete on dev. Four-namespace symmetry mirrors the metamodel's runtime primitives:

```
Esr.Application       (OTP boot; ≡ DaemonScope per concepts.md §🔧-5)
Esr.Scope.*           (Scope primitive: base + infra + kinds e.g. Scope.Admin)
Esr.Entity.*          (Entity primitive: behaviour + infra + base types e.g. Entity.User)
Esr.Entities.*        (concrete Entity instance modules: cc_process, pty_process, …)
Esr.Resource.*        (Resource type instances: Workspace / Capability / Permission / SlashRouteRegistry / DeadLetterQueue)
Esr.Admin.*           (admin subsystem)
Esr.Topology          (topology declaration helpers)
Esr.Telemetry.* / Esr.Persistence.* / Esr.Yaml.* / Esr.Workers.* / EsrWeb.*  (infra/framework)
```

What's missing: `Esr.Interface.*` — the contract layer that the metamodel calls out (concepts.md §五, session.md §七) but code hasn't extracted yet. R4 introduces it.

---

## 二、Guiding principle (per user 2026-05-03)

> **A "true Resource" is one that can be consumed by multiple Entity types.** If only one Entity type uses it, it's not a Resource — it lives under that Entity type's namespace.

Applying:
- `Esr.Entity.User.Registry` — only User-Entity consumes → correctly under `Esr.Entity.User.*`
- `Esr.Resource.Capability.Grants` — multi-User, multi-Agent consume → Resource ✓
- `Esr.Resource.SlashRouteRegistry` — multiple slash-handlers register → Resource ✓
- `Esr.AdapterSocketRegistry` (top-level) — multi-Adapter consumes → should move to `Esr.Resource.*` (R8)

**And** (per user 2026-05-03): Registry itself is not a "type" — it's an Interface (contract). Multiple concrete modules implement it. So Registry-flavor data stores get `@behaviour Esr.Interface.Registry` regardless of which namespace they live under.

---

## 三、Registry API surface audit (input to R4)

Audit of the 7 registry-flavored modules surfaces two distinct shapes:

### Shape A: Live-pid registry (runtime register/lookup/unregister)

| Module | API |
|---|---|
| `Esr.Entity.Registry` | `register(actor_id, pid)` / `lookup(actor_id)` / auto-cleanup on pid death; `list_all()` |
| `Esr.AdapterSocketRegistry` | `register(sid, opts)` / `lookup(sid)` / `mark_offline(sid)` (soft); `list()` / `notify_session/2` |
| `Esr.Scope.Registry` | Elixir kernel `Registry` (no wrapper module — used via `{:via, Registry, ...}`) |

### Shape B: Snapshot / yaml-backed registry (bulk-load + read)

| Module | API |
|---|---|
| `Esr.Entity.User.Registry` | `load_snapshot(map)` / `get(username)` / `lookup_by_feishu_id(id)` / `list()` |
| `Esr.Resource.Workspace.Registry` | `load_from_file(path)` / `put(%Workspace{})` / `get(name)` / `list()` / `workspace_for_chat/2` ¹ |
| `Esr.Resource.Capability.Grants` | `load_snapshot(map)` / `has?(principal, perm)` |
| `Esr.Resource.SlashRouteRegistry` | `load_snapshot(map)` / `lookup(text)` / `permission_for/command_module_for/route_for_kind` / `list_slashes()` |

¹ Hybrid: snapshot via `load_from_file` + per-entry `put/1`. R5's `Esr.Resource.ChatScopeRegistry` will follow the same hybrid pattern (snapshot at boot + per-Scope register/unregister at session create/end).

**Co-existence with `Esr.Role.State`**: all 7 modules already declare `@behaviour Esr.Role.State` (the project's existing actor-role marker). R4's new `Esr.Interface.{Live,Snapshot}Registry` behaviours **layer on top of** `Esr.Role.State`, not replace it. A module can declare multiple `@behaviour` lines.

### Implication for R4 Interface design

**Shape A and Shape B don't share a uniform contract.** Live registries register/unregister per-entry; snapshot registries load in bulk and never per-entry register. Two paths:

**Option 1 — One Interface, optional callbacks:**
```elixir
defmodule Esr.Interface.Registry do
  @callback lookup(key :: term()) :: {:ok, value :: term()} | :error
  @callback list() :: [{key :: term(), value :: term()}]
  @optional_callbacks register: 2, unregister: 1, load_snapshot: 1
end
```

**Option 2 — Two Interfaces (cleaner separation):**
```elixir
defmodule Esr.Interface.LookupRegistry do
  @callback lookup(key :: term()) :: {:ok, value :: term()} | :error
  @callback list() :: [{key :: term(), value :: term()}]
end

defmodule Esr.Interface.LiveRegistry do
  @behaviour Esr.Interface.LookupRegistry
  @callback register(key :: term(), value :: term()) :: :ok | {:error, term()}
  @callback unregister(key :: term()) :: :ok
end

defmodule Esr.Interface.SnapshotRegistry do
  @behaviour Esr.Interface.LookupRegistry
  @callback load_snapshot(snapshot :: map()) :: :ok
end
```

**Recommendation:** Option 2. Cleaner contract; each concrete module declares which behaviour it implements, removing ambiguity. Easier for static analysis / dialyzer.

**Open Q (R4):** lookup return value — `:error` vs `:not_found`. Unify on `:error` (matches Map.fetch/2 / Elixir kernel convention). This is a small API touch-up across the 7 modules.

---

## 四、R-batch plan (sequential, one PR per batch)

### R4 — Introduce `Esr.Interface.Registry` (Interface-first)

**Scope:**
1. Create `runtime/lib/esr/interface/lookup_registry.ex`, `live_registry.ex`, `snapshot_registry.ex` (Option 2 from §三)
2. Add `@behaviour` to all 7 existing registry-flavored modules. **The new behaviours stack on top of the existing `@behaviour Esr.Role.State`** — they don't replace it.
3. Unify `lookup/1` return value to `{:ok, value} | :error` across all modules — see §七 Q2 for the cascade scope (caller-side, not module-side).

**Out of scope:**
- No new Registry instances (R5+ adds those with the Interface from day one)

**Files touched:** ~10 (3 new Interface modules + 7 modules getting `@behaviour` + maybe a few callers if return-value normalization shifts)

**Validation:** mix compile clean, mix test no regressions, dialyzer happy

**Bail-out:** if return-value normalization cascades >10 caller files, split off the normalization to its own PR.

---

### R5 — Split `Esr.SessionRegistry` (329 LOC → 0)

**Scope:**
1. Create `Esr.Entity.Agent.Registry` — agents.yaml cache + hot-reload (Shape B / SnapshotRegistry)
   - Re-uses existing FileLoader.load + Watcher patterns from Capability/SlashRoute
   - `@behaviour Esr.Interface.SnapshotRegistry`
2. Create `Esr.Resource.ChatScopeRegistry` — `(chat_id, app_id) → session_id` routing data
   - ETS-backed; consumers: Adapter Entities + control-plane (multi-Entity-type → Resource ✓)
   - Shape A or hybrid? Probably hybrid: register/unregister at session create/end, lookup at inbound. Implements both `LiveRegistry` + read APIs from `LookupRegistry`.
3. Delete `Esr.SessionRegistry`. Migrate all callers to the two new homes + existing `Esr.Entity.Registry` (for the third concern: `(sid, name) → pid` is already covered by actor_id lookup).

**Out of scope:**
- Scope.Router internal split (deferred to R6)
- Topology declaration as code modules (Phase 4 future)

**Files touched:** ~30 (delete 1, create 2 + their FileLoader/Watcher 4-piece, migrate ~25 callers)

**Validation:** mix compile, mix test, daemon state file sweep + restart, e2e 06+07+DOM

**Bail-out criteria (per refactor-lessons.md §五):**
- `mix test` failures > baseline × 10 → revert
- daemon won't boot → revert (yaml-cache initialization is critical path)

---

### R6 — Split `Esr.Scope.Router` (799 LOC → ~150 + new modules)

**Scope:**
1. Trim `Esr.Scope.Router` to lifecycle coordinator only (~150 LOC):
   - `handle_call({:create_session_sync, …})` / `({:end_session_sync, sid})`
   - `handle_info({:new_chat_thread, …})` / `({:DOWN, …})` / `:agents_yaml_reloaded`
2. Create `Esr.Session.AgentSpawner` (~400 LOC):
   - Reads agent declaration from `Esr.Entity.Agent.Registry` (R5 output)
   - Spawns Entity instances via `Esr.Entity.Factory.spawn_peer/5`
   - Builds neighbor refs and ctx (current `backwire_neighbors` + `build_ctx`)
   - **Why under `Esr.Session.*`:** this is the bridge from declarative Session/Topology → runtime Scope instantiation. Session is the declarative-side namespace.
3. Fold `parse_channel_adapter/1` + helpers into Spawner as private helper (no new module)
4. Move `resolve_workspace_start_cmd/2` + `expand_start_cmd/1` to `Esr.Resource.Workspace.Registry` as a public function `start_cmd_for/1`
5. **Test-only public APIs in current Scope.Router** — `build_ctx_for_test/2` (line 118) and `stamp_channel_adapter_for_test/2` (line 121) — relocate to AgentSpawner test helpers OR expose via the same minimal seam pattern. Audit them before R6 starts; if they leak production state inappropriately, drop them and rely on the new Spawner's narrower test surface instead.

**Out of scope:**
- Adapter target string format change (stays as today's `admin::feishu_app_adapter_<id>` shape)
- Spawner generalization for non-agent Sessions (Phase 4)

**Files touched:** ~15 (Scope.Router shrink, AgentSpawner new, Workspace.Registry +1 fn, ~10 callers updating spawn invocation)

**Validation:** Same as R5 + heavy unit-test focus on AgentSpawner (it's a substantial new module)

---

### R7 — Audit + possibly split `Esr.Admin.Dispatcher` (448 LOC)

**Scope:**
1. Audit Admin.Dispatcher's actual concerns (TBD pre-design)
2. Decide: split into pure dispatcher + result reporter + auth context propagator? Or stay monolithic if concerns are tightly coupled.
3. If split: each new module gets correct namespace placement.

**Out of scope until audit:**
- Specific naming
- Dispatcher API changes

**This batch starts with a brainstorming session before code.**

---

### R8 — Move `Esr.AdapterSocketRegistry` → `Esr.Resource.AdapterSocketRegistry`

**Scope:** Pure mechanical move per "true Resource" criterion (multi-Adapter Entity consumer).

**Files touched:** ~20 (single module move + callers updated)

**Validation:** Same daemon-restart + e2e flow as R3.

**Why separate from R5/R6:** keeps PRs small. Could bundle with R10 (doc-only) for a "polish" PR, but R8 has real code touches so cleaner standalone.

---

### R9 — Capabilities + Permissions add Interface extraction

**Scope:**
1. Create `Esr.Interface.CapabilityDeclaration` — `@callback name/0`, `@callback description/0`, `@callback required_for/0`
2. Create `Esr.Interface.Grant` — `@callback grant/2`, `@callback revoke/2`, `@callback check/2`
3. `Esr.Resource.Capability.*` modules add `@behaviour Esr.Interface.{CapabilityDeclaration, Grant}` as appropriate
4. `Esr.Resource.Permission.*` likewise

**Out of scope:**
- Splitting the existing modules (façade stays); only adds Interface contracts
- Runtime behavior change (zero functional change)

**Files touched:** ~10 (2 new Interface modules + Cap/Perm modules add @behaviour)

**Validation:** mix compile, mix test, no functional change so e2e is a smoke check.

---

### R10 — Workspace metamodel role doc clarification (DOC-ONLY)

**Scope:** Add to `concepts.md` and `session.md` a paragraph explicitly stating Workspace is a Dir-flavor Resource type with its own schema (owner/start_cmd/role/chats/env), NOT a composition of Dir+Capability. Clarifies session.md §六 entry.

**Out of scope:**
- Code change
- New Workspace API

**Files touched:** 1-2 doc files

**Validation:** Doc readability review; no code path.

---

### R11+ — Other Interfaces (Channel/Boundary/Operation/Boot/SlashParse/Member/Identity/Agent)

**Scope:** Per session.md §七, ~10 more Interfaces to extract. Each gets its own PR (small).

Suggested order based on reuse weight:
1. `Esr.Interface.Channel` (publish/subscribe/frame) — used by every actor
2. `Esr.Interface.Boundary` + `Esr.Interface.BoundaryConnection` — Adapter Entity type contract
3. `Esr.Interface.Operation` — Dispatcher's contract
4. `Esr.Interface.Boot` — Application's contract
5. `Esr.Interface.SlashParse` — SlashHandler's contract
6. `Esr.Interface.Member` — every Scope member's contract
7. `Esr.Interface.Identity` — User-Entity's contract
8. `Esr.Interface.Agent` — Agent-Entity's contract
9. `Esr.Interface.EventHandler` + `Esr.Interface.Purity` — Handler's contracts

Each is a small PR (one Interface module + adding `@behaviour` to the 1-3 implementers). Roll out incrementally.

---

### R-future — Defer `Esr.Entity.Server` (1015 LOC, 62 funcs)

**Why defer:** per-Entity host is multi-concern by nature (inbound dispatch + persistence + lifecycle + state machine). Splitting touches every Entity instance. High risk, low immediate ROI. Re-evaluate after R5-R11 land and the Entity surface is more stable.

**Trigger to revisit:** any future PR that needs to add a 5th major concern to Entity.Server, OR if Entity.Server hits 1500 LOC.

---

## 五、Sequencing rationale

Why R4 (Interface-first) before R5 (SessionRegistry split):

- R5 creates two new Registries (`Esr.Entity.Agent.Registry`, `Esr.Resource.ChatScopeRegistry`). With R4 done first, they get `@behaviour Esr.Interface.{Snapshot,Live}Registry` from day one.
- Without R4 first, R5's new Registries would need a follow-up PR to backfill `@behaviour` — wasteful.

Why R7 (Admin.Dispatcher audit) before R9 (Cap/Perm Interface):

- Admin.Dispatcher likely uses `Esr.Resource.Capability.Grants` heavily; auditing the dispatcher first surfaces what Cap/Perm Interface signatures the consumer actually needs.
- If R9 lands first with arbitrary signatures, R7 may need to revisit them.

Why R6 (Scope.Router split) before R7 (Admin.Dispatcher):

- Both are 400-800 LOC bundled-concern splits. Doing the bigger one first (R6) builds confidence in the Spawner pattern that R7 may also use.

Why R8 (AdapterSocketRegistry move) is small/late:

- It's a 1-module mechanical move; can land anytime after R4. Doesn't block any other R-batch. Listed at R8 just to keep numerical ordering.

---

## 六、Bail-out criteria (per refactor-lessons.md §五)

Stop and ask user before grinding through fixes if any of these triggers fire on any R-batch:

| Trigger | Action |
|---|---|
| `mix test` failures > 10× baseline | Revert the bad pass; don't point-fix |
| `mix compile` undefined-function errors in load-bearing modules | Surface first; cascade is likely |
| Daemon won't restart with new build | Revert; yaml-cache or bootstrap is broken |
| User-state yaml unparseable after rename | Revert; missed a stringified module reference |

---

## 七、Open questions (for user to confirm before R4 starts)

1. **Interface design (Option 1 vs Option 2)** — separate `Esr.Interface.{LookupRegistry, LiveRegistry, SnapshotRegistry}` modules (Option 2, my recommendation), OR single `Esr.Interface.Registry` with `@optional_callbacks` (Option 1)?
2. **lookup return value normalization** — unify on `{:ok, val} | :error` (matching Map.fetch/2 convention)? **Two of seven** registries currently return `:not_found` instead of `:error` (`Esr.Entity.User.Registry`'s `get/1` + `lookup_by_feishu_id/1`; `Esr.Resource.Workspace.Registry`'s `get/1` + `workspace_for_chat/2`). The cascade is **caller-side, not module-side**: how many callers pattern-match on `:not_found`? Audit caller count first; if >10 callers, defer normalization to its own PR (matches §六 bail-out).
3. **Scope.Router shrink target** — fold parse_channel_adapter into Spawner private (proposal), or keep public for testability?
4. **R10 (Workspace doc) — bundle with R9 (Cap/Perm Interfaces)?** Both are doc-leaning; one PR could cover both if the Cap/Perm spec needs Workspace mention.
5. **Entity.Server (deferred)** — confirm OK to defer? Or audit it lightly now to surface any quick wins?

---

## 八、Files >400 LOC not directly covered by R4-R11 (appendix)

LOC audit surfaced these large modules that aren't on the explicit R-batch list. Each gets a one-line rationale:

| File | LOC | Disposition |
|---|---|---|
| `runtime/lib/esr/entities/feishu_chat_proxy.ex` | 682 | **Out of scope** — Adapter Entity instance internals; Phase-4 work if Boundary Interface (R11) extraction reveals shared concerns |
| `runtime/lib/esr/entities/slash_handler.ex` | 627 | **Will be touched by R11** — `Esr.Interface.SlashParse` extraction lands `@behaviour` here; module rename/split deferred until shared concerns surface |
| `runtime/lib/esr/entities/cc_process.ex` | 623 | **Out of scope** — Entity instance internals; mirrors feishu_chat_proxy disposition |
| `runtime/lib/esr_web/cli_channel.ex` | 638 | **Future R-batch (TBD)** — Phoenix Channel; arguably Adapter-shaped. Worth a standalone audit after R11 lands and Boundary Interface is concrete |
| `runtime/lib/esr/admin/commands/scope/branch_end.ex` | 453 | **Audit in R7** — single Admin command at 453 LOC suggests bundled concerns; surface as candidate during Admin.Dispatcher audit |
| `runtime/lib/esr/application.ex` | 442 | **Boot Interface implementer (R11)** — `Esr.Interface.Boot` extraction will add `@behaviour` here; no split planned. The application IS DaemonScope per concepts §🔧-5 |
| `runtime/lib/esr/os_process.ex` | 405 | **Out of scope** — already a base behaviour module for erlexec subprocess hosts; metamodel-clean, no R-batch needed |

---

## 九、Related docs

- `docs/notes/concept-rename-map.md` — original R1-R6 rename catalog (this doc supersedes for R4+)
- `docs/notes/refactor-lessons.md` — R1-R3 lessons (alias-collapse traps, daemon state files, bail-out criteria)
- `docs/notes/concepts.md` — metamodel definition (Interface is one of the 4 runtime primitives)
- `docs/notes/session.md` — §七 Common Interfaces table (16 interfaces enumerated)
- `docs/notes/mechanics.md` — runtime essence (5 buckets for new features)
- `scripts/hooks/pre-merge-dev-gate.sh` — gate enforcement (used after every R-batch)
