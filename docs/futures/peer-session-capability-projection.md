# Session-scoped Capability Projection

**Status**: future work. Not in v3.1 refactor scope.
**Discovered**: 2026-04-22, during PR #11 test-flake investigation.
**Relates to**: `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.3 / §3.5, `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md` PR-2 / PR-3.

---

## 1. Origin

While triaging flaky tests on PR #11, we traced the symptom to the single-instance `Esr.Capabilities.Grants` GenServer being the write bottleneck under parallel test load (40+ `load_snapshot` call sites × up to 56-way ExUnit concurrency).

That led to a deeper architectural question: **why is capability state centralised at all?**

## 2. The distinction this doc captures

ESR currently has one yaml (`capabilities.yaml`) expressing one concept (principal → [permission]). But there are really **two different capability concepts** being bundled:

| Kind | Content | Lifetime | Who edits it |
|---|---|---|---|
| **A. Principal grants** | `ou_alice → ["workspace:proj/msg.send", ...]` | Changes rarely (admin action) | Admin, once per grant/revoke |
| **B. Context requirements** | `agent "cc" requires [cap.tmux.spawn, ...]` | Static (product decision) | Developer, once per agent type |

v3.1 already separates **B**: `agents.yaml` declares `capabilities_required:` per agent. That's the right home for context requirements.

**A stays global** in the current design — a single `capabilities.yaml` fed into a single ETS table via a single GenServer. The current reads from `Grants.has?/2` are per-peer and lock-free (ETS with `read_concurrency`). The writes are rare in production (boot + yaml-change) and don't contend.

## 3. The bottleneck is test-induced, not production-induced

- Production: ~2 writes to Grants per esrd lifetime
- Tests: 30-40 writes per `mix test` run, default concurrency ≈ 56
- Test writes abuse the production write API as fixture setup

The test abuse is the immediate problem; the architectural discussion is orthogonal. We're addressing the test flakes through improved test isolation (see §4 of this doc), and separately considering the architectural evolution.

## 4. Future direction: Session-scoped capability projection

The cleanest fit with v3.1's Session-centric architecture:

```
capabilities.yaml (global SoT — admin's one place to edit)
     │
     ▼
Esr.Capabilities.FileLoader (boot / fs-event Watcher reload)
     │
     ▼
Esr.Capabilities.Grants (global ETS, source-of-truth snapshot)
     │
     │ on Session.start: push relevant subset
     │ on Session.active: push diff if grants change
     ▼
SessionProcess.grants (per-session in-memory map)
     │
     │ Peer.Stateful.handle_xxx calls SessionProcess.has?(principal, perm)
     ▼
No global contention on the read hot path, no global contention on the write path either (per-session projection pulls its own slice).
```

### Why this is better

1. **No shared mutable singleton on the write path** — each Session gets its own projection; admin writes to global table don't contend with per-session reads.
2. **Session termination = natural GC** — when a Session ends, its projection goes away with the supervisor subtree. No zombie state.
3. **Matches v3.1 semantics** — SessionProcess already holds per-session state (capability grants per D13 spec §1.8, session-scoped dir/agent binding per §3.5). Adding a projection map is a 1-field extension.
4. **Decouples reader concurrency from admin operations** — admin can rewrite `capabilities.yaml` freely; the diff propagates as explicit `{:grant_changed, principal_id, old, new}` messages to each Session, processed serially within that Session.
5. **Solves the current test flake** as a side effect — tests write directly to `SessionProcess.grants` (no cross-test contention), no need for the single-Grants-GenServer path.

### Open questions for the future implementation

- **Propagation latency**: how much delay between admin edit and all active Sessions reflecting the change? Acceptable? (User perspective: "I revoked at T; when do I stop having permission?")
- **Principal not-yet-in-any-Session**: how is a principal's grants stored if they haven't started any Session? Do we need a "future grants" staging area, or does it not matter until a Session spawns?
- **Memory cost**: N sessions × M principals × P grants. For current ESR scale (dozens of sessions max), trivial. For future scale, may need interning or LRU.
- **Watcher semantics**: `Esr.Capabilities.Watcher` currently reloads the whole snapshot on any yaml change. Projection introduces `{:diff, …}` messages. Need a protocol.

## 5. Concrete follow-up task

Add to `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`:

**PR-2 P2-6a (insertion)**: `SessionProcess.grants` field + `SessionProcess.has?/2` helper. For PR-2, this is a pass-through to `Esr.Capabilities.Grants.has?/2` (current global path). Establishes the API surface.

**PR-3 P3-3a (insertion)**: Implement actual projection. `SessionProcess` on init pulls its principal's grants from `Grants`; subscribes to `{:grants_changed, principal_id}` PubSub topic; updates its local map on change. `Grants.has?/2` callers in peer_server etc. migrate to `SessionProcess.has?/2`.

**Post-refactor cleanup (PR-5 or follow-up)**: Once all reads are per-Session, the global ETS stays but becomes only a producer, not a consumer. Could further simplify by removing `Grants.has?/2` entirely.

## 6. Decision: defer to v3.1 implementation window

Not adding PR-2 P2-6a / PR-3 P3-3a to the plan now — they'll be added when we expand PR-2 and PR-3 outlines into bite-sized steps (per the progressive expansion strategy in the plan).

## 7. Quick answer to the original test-flake question

For the PR #11 flake: we accepted as a known issue (pre-existing, not caused by the rename surgery). See `docs/operations/known-flakes.md` in the dev-prod-isolation branch.
