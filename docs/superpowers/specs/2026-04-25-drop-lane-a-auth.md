# Spec — Drop Lane A: Elixir-only auth (post PR-A)

**Status:** **APPROVED v1.4** (2026-04-26, three subagent review rounds: v1.2 / v1.3 / v1.4 all clean of blockers; v1.4 final-pass found 3 prose-only fixes, all applied). Ready for implementation per T0 — branch off `main` after PR-A merges.

### Spec changelog
- **v1.4 (2026-04-26)** — third subagent review. **B-v1.3-1**: my v1.3 invented `Esr.Workspaces.Registry.instance_id_for_app/2` — no such function, and the Workspace struct (`runtime/lib/esr/workspaces/registry.ex:14-16`) has no `instances` field or `instance_id` column on chats. The "FCP same pattern" claim was wrong: FCP at `feishu_chat_proxy.ex:404-406` does direct `Registry.lookup("feishu_app_adapter_#{app_id}")`, only working because PR-A locks `app_id == instance_id`. v1.4 fix: parse `instance_id` directly from `envelope["source"]` (format `esr://localhost/adapter:feishu/<instance_id>` per `runner_core.py:163`). The Feishu-source guard regex I already need becomes the extractor — zero new seams, no Workspaces.Registry detour. **S-v1.3-1**: rate-limit map is per-FAA process; multi-FAA deployments give per-(principal, instance_id) windows, not strict per-principal-globally. Documented as accepted soft-regression in §4 migration. **S-v1.3-2**: commit message test counts updated 4→5 and 2→3 to match v1.3's expanded test list.
- **v1.3 (2026-04-26)** — code-review fixes (subagent code-reviewer, 2 blockers + 4 should-fixes + 1 nit on v1.2). **B1**: registry lookup must use `instance_id`, not `app_id` — FAA registers under `"feishu_app_adapter_#{instance_id}"` per `feishu_app_adapter.ex:70`. PR-A mock setup happens to satisfy `app_id == instance_id` so the bug appears to work in tests but fails open in real Feishu (deny silently has no DM sent — exact regression v1.2 was written to prevent). Fix: stamp `instance_id` onto envelope at AdapterChannel ingress, or resolve `instance_id` from `(chat_id, app_id) → workspace.instances[app_id]` via Workspaces.Registry. **B2**: envelope's `app_id`/`chat_id` live under `payload.args`, not top-level — verified at `py/src/esr/ipc/envelope.py:85-94` (`make_event`) and the existing `feishu_app_adapter.ex:90-97` reader. v1.2 used `envelope["app_id"]` which resolves to `nil`. Spec corrected to `get_in(envelope, ["payload", "args", "chat_id" | "app_id"])`. **S1**: explicit `handle_info({:dispatch_deny_dm, _, _}, state)` clause callout in T1.3. **S2**: Feishu-source guard added — `peer_server.ex` deny path only attempts deny-DM dispatch when source matches Feishu. **S3**: test list expanded — missing-FAA branch and empty-app_id case. **S4**: rate-limit-key open question added to §8 (global-per-principal vs per-(principal, chat)). **N1**: peer_server.ex:272 comment update moved to T1 (not T2).
- **v1.2 (2026-04-26)** — user pushback on v1.1's silent-deny choice. Direct quote: "为什么要沉默？直接转发lane b中的错误信息不是更自然吗？". v1.2 relocates the deny-DM responsibility to Elixir instead of dropping it. New surface: `peer_server.ex` deny path dispatches a directive through the FAA peer (same channel T4's cross-app reply uses); rate-limit (`_last_deny_ts`) migrates from Python adapter to FAA GenServer state. Adapter becomes a thin courier — no auth logic, but still serves as the wire-level message sender via the existing `_send_message_lark` / `_send_message_mock` paths. Net: zero user-visible regression; single source of truth in Lane B. Harness gets 4 surviving tracks + 1 new (verify Lane B's deny-DM path end-to-end).
- **v1.1 (2026-04-25)** — code-review fixes (subagent, 2 blockers + 3 should-fixes). **B1**: added e2e_capabilities.py harness disposition. **B2**: discovered Lane B inbound gate at `peer_server.ex:236-274` already exists; reframed Lane A as user-feedback layer, not gate. **S1**: conftest + 3-test cleanup. **S2**: line numbers corrected. **S3**: capabilities.py keep-as-is decision.
- **v1.0 (2026-04-25)** — initial draft.
**Author:** Claude / 林懿伦
**Branch target:** `feature/drop-lane-a-auth-simplification` off `main` after PR-A (`feature/pr-a-multi-app`) merges.
**Issues addressed:** open task #140 — auth-system simplification.

## 1. Background

ESR currently runs two independent auth lanes against the same `capabilities.yaml`:

| Lane | Where | Trigger | Check |
|------|-------|---------|-------|
| **A — Python** | `adapters/feishu/src/esr_feishu/adapter.py:830,983,1072` | inbound Feishu message → before emitting `msg_received` to runtime | `workspace:<ws>/msg.send` for sender's `open_id` |
| **B — Elixir** | `runtime/lib/esr/capabilities/grants.ex` (`has?/2`) | admin commands; FCP cross-app reply (T4); peer dispatch | various `<prefix>:<name>/<perm>` |

**The cost of two lanes:**

1. **Dual-write yaml.** `tests/e2e/scenarios/common.sh:seed_capabilities` writes the same yaml to both `${ESRD_HOME}/<instance>/capabilities.yaml` (Lane B) and `${ESRD_HOME}/default/capabilities.yaml` (Lane A). Any operator change to caps must touch both.
2. **`handler_hello permissions: []` blocking.** The Python feishu adapter's `handler_hello` declares `permissions: []`, so the Elixir runtime's permissions registry rejects any non-`*` grant against `workspace:e2e/msg.send` with `{:unknown_permission, ...}` and discards the entire snapshot — meaning ou_admin loses its wildcard too. Workaround in current e2e: only ou_admin with `["*"]` is configurable.
3. **Two principal-id concepts that must align.** Lane A reads `sender.sender_id.open_id`; Lane B reads `principal_id` from the upstream envelope (which the Python adapter already populates from the same field at T2). A divergence here would silently produce inconsistent allow/deny.
4. **Non-trivial Python surface.** Lane A is ~125 LOC across `_load_capabilities_checker`, `_is_authorized`, `_should_send_deny`, `_send_deny_dm`, `_deny_rate_limited`, `_last_deny_ts`, `_DENY_DM_INTERVAL_S`, `_DENY_DM_TEXT`, plus the per-call-site dispatch at three emit points. Plus 343 LOC of `tests/test_lane_a.py`.

## 2. Decision: drop Lane A — Lane B owns the gate AND the deny DM

**Architecture after this PR:**

```
inbound msg → AdapterChannel → peer_server (Lane B gate)
                                  │
                                  ├── allow → invoke_handler (CC pipeline)
                                  └── deny  → emit telemetry
                                         + dispatch deny-DM directive to FAA peer
                                         + (FAA → adapter → wire) sends Chinese deny DM
```

Lane A's `_is_authorized` check was a duplicate of `peer_server.ex:236-274`'s gate. Lane A's deny-DM code (`_deny_rate_limited` + `_send_message_lark`/`_mock` invocation + `_last_deny_ts` rate-limit) was the **user-feedback layer** for that gate. Today both layers live in Python; v1.2's plan moves the gate-and-feedback decision wholly into Elixir.

**What this PR removes:**
- Lane A's gate in Python (`_is_authorized`, the `_caps` checker init, the `_load_capabilities_checker`). Functionally redundant with `peer_server.ex:236-274`.
- Lane A's rate-limit bookkeeping in Python (`_last_deny_ts`, `_DENY_DM_INTERVAL_S`, `_should_send_deny`). The state moves to Elixir.
- Lane A's direct DM dispatch in Python (`_deny_rate_limited`'s call into `_send_message_lark`/`_send_message_mock` from the gate path). The decision moves to Elixir; the wire-level send still lives in adapter — but it's now invoked via the same FAA→adapter directive channel T4's cross-app reply uses.

**What this PR adds:**
- `peer_server.ex:266-273` deny path: instead of `Drop silently`, dispatch `{:dispatch_deny_dm, principal_id, chat_id}` to the source app's FAA peer. **Lookup details (v1.4 from review):** The FAA peer registers in `Esr.PeerRegistry` under `"feishu_app_adapter_#{instance_id}"` (see `feishu_app_adapter.ex:70`; docstring 12-22 explicitly distinguishes `instance_id` from `app_id`). The envelope's `source` field already carries `instance_id` literally — format is `esr://<host>/adapter:feishu/<instance_id>` per `py/src/_adapter_common/runner_core.py:163`. Use one regex with a capture group to both gate on Feishu-source AND extract `instance_id`: `Regex.run(~r{^esr://[^/]+/adapter:feishu/([^/]+)$}, source)`. No Workspaces.Registry resolution, no AdapterChannel ingress changes — just parse what's already there.
- A guard so non-Feishu inbounds (cc_tmux, voice, etc.) don't trigger the Feishu-shaped lookup. The single source-regex serves both purposes: when it doesn't match, `dispatch_deny_dm/1` returns `:ok` without trying to lookup an FAA. When it matches, the capture group yields `instance_id` directly.
- FAA peer state: a per-principal rate-limit map (`%{principal_id => last_emit_monotonic_ms}`). The deny-DM directive includes the principal_id; FAA suppresses if last DM to this principal was < 10 min ago. (Open question §8.4: per-principal-globally vs per-(principal, chat).)
- FAA `handle_info({:dispatch_deny_dm, principal_id, chat_id}, state)` clause — explicit new pattern match. Without it the GenServer would crash on the unhandled message.
- `runtime/lib/esr/peers/feishu_app_adapter.ex` module attributes: `@deny_dm_text "你无权使用此 bot，请联系管理员授权。"` and `@deny_dm_interval_ms 10 * 60 * 1000`.

**What stays unchanged:**
- The user experience. A stranger DM-ing the bot still receives the same Chinese deny DM, rate-limited the same way.
- Lane B outbound enforcement (T4's cross-app reply gate; admin command gates).
- Feishu's chat-membership as platform-level outer gate.
- The adapter's wire-level message-send code (`_send_message_lark`, `_send_message_mock`). It just no longer triggers itself from a Lane A gate.

### 2.1 Functional regressions

**None at user level.** The deny DM still fires, with the same text and the same rate-limit window. The only operationally-visible change is:

- **Telemetry name shifts.** `feishu Lane A: deny DM ...` log lines disappear; `[:esr, :capabilities, :denied]` telemetry with `lane: :B_inbound` is now the canonical signal. Anyone scraping the old log line for alerts must update.
- **Latency on deny.** Today: deny decision in adapter is microseconds; DM is sent immediately. After: deny decision in Elixir, dispatch to FAA peer, FAA dispatches to adapter, adapter sends DM. Adds one Elixir-process hop + one Phoenix channel roundtrip ≈ <1ms in practice. Acceptable.

### 2.2 Why this is right

- **One gate, one decision site.** Two lanes meant a 4-state truth table (allow/allow, allow/deny, deny/allow, deny/deny) where 2 of 4 states are bugs. Fold to one lane and the truth table collapses to allow/deny.
- **Adapter responsibility narrows correctly.** Adapters speak the wire protocol; the runtime decides who's allowed. Today the adapter does both, and the runtime is forced to defer to the adapter for user-facing feedback. After this PR the adapter is a thin courier.
- **The dual-write yaml burden disappears.** Lane A and Lane B read the same yaml shape from different paths; any operator inconsistency between `${ESRD_HOME}/default/capabilities.yaml` and `${ESRD_HOME}/<instance>/capabilities.yaml` produces an "allowed in one, denied in the other" mismatch that's painful to debug. After: one path.
- **The `permissions: []` `handler_hello` workaround stops being load-bearing.** Lane B reads the runtime's permissions registry, which `handler_hello` doesn't filter; the e2e can grant `workspace:e2e/msg.send` to ou_e2e without losing ou_admin's wildcard. (TODO that's been tracked since PR-9.)

### 2.3 What is gained

- Single source of truth: one `capabilities.yaml`, one gate, one rate-limit, one deny-DM dispatch decision.
- ~125 LOC of Lane A Python surface + 343 LOC of `test_lane_a.py` + ~70 LOC of common.sh dual-yaml plumbing + 3 tracks (CAP-B/C/D) of the e2e_capabilities harness deleted/rewritten.
- ~50 LOC of Elixir added (FAA deny-DM dispatch + rate-limit map + new test).
- Net: ≈ –450 LOC and an architectural simplification.
- The only Python `CapabilitiesChecker` consumer left after this PR is `py/src/esr/cli/cap.py:104` (`_matches`, used by `esr cap who-can` for offline pattern matching).

## 3. Scope

### In-scope

**Elixir-side addition (new — v1.2):**
- `runtime/lib/esr/peer_server.ex:266-273`: change the deny path. Today it emits telemetry then drops. New behavior: emit telemetry, then call `dispatch_deny_dm(envelope)` which extracts `instance_id` from `envelope["source"]` via a regex (see T1.4 for the implementation block), looks up the FAA pid in `Esr.PeerRegistry` under `"feishu_app_adapter_#{instance_id}"`, and sends `{:dispatch_deny_dm, principal_id, chat_id}` to it. The deny logic lives in a single named seam, `dispatch_deny_dm/1`.
- `runtime/lib/esr/peers/feishu_app_adapter.ex`: handle `{:dispatch_deny_dm, principal_id, chat_id}` — check per-principal rate-limit map (new state field `deny_dm_last_emit: %{}`), if last emit > 10 min ago dispatch a `{:outbound, %{"kind" => "reply", ...}}` directive to the adapter (using the existing outbound channel T4's cross-app reply uses) with the Chinese deny text, and update the rate-limit map.
- Constant: define `@deny_dm_text "你无权使用此 bot，请联系管理员授权。"` and `@deny_dm_interval_ms 10 * 60 * 1000` somewhere reasonable (FAA module or a small `deny_dm.ex` constants file).
- New unit test: `runtime/test/esr/peers/feishu_app_adapter_deny_dm_test.exs` — verify rate-limit semantics + directive shape.
- New peer_server test (or extend existing): `runtime/test/esr/peer_server_lane_b_deny_dispatch_test.exs` — verify deny path sends the message to FAA, allow path doesn't.

**Adapter-side removal:**
- `adapters/feishu/src/esr_feishu/adapter.py`: 3 call sites (lines 825-835, 977-988, 1068-1076 verified post-review) + 5 helper methods (`_load_capabilities_checker` at 189-211; `_is_authorized` at 215; `_should_send_deny` at 233; `_deny_rate_limited` at 252 — DM logic is inlined here, no separate `_send_deny_dm` exists; plus the `_caps` instance init at 134) + 2 module-level constants (`_DENY_DM_INTERVAL_S`, `_DENY_DM_TEXT` at 40-46) + 1 import (line 28) + the `_last_deny_ts` dict.
- `adapters/feishu/src/esr_feishu/adapter.py`: `AdapterConfig.capabilities_path` field becomes unused — remove it from the dataclass and from any consumer (audit `getattr(self._config, "capabilities_path", None)` references).

**Test cleanup:**
- Delete `adapters/feishu/tests/test_lane_a.py` (343 LOC).
- `adapters/feishu/tests/conftest.py:22,48`: `allow_all_capabilities` and `write_allow_all_capabilities` fixtures become dead. Remove them.
- Update `adapters/feishu/tests/test_emit_events.py:37,70`, `test_envelope_principal.py:158,180`, `test_workspaces_load_shapes.py:38`: drop the `capabilities_path` argument they pass into `AdapterConfig`.

**Elixir comment update:**
- `runtime/lib/esr/peer_server.ex:272`: rewrite the `# Drop silently — Lane A handles the user-facing deny response.` comment to reflect that no user-facing deny exists anymore (something like `# Drop silently — capability deny is observable via [:esr, :capabilities, :denied] telemetry.`).

**E2E harness disposition (B1 from review):**
- `scripts/scenarios/e2e_capabilities.py` (7-track harness, 712 LOC). Tracks B (`_is_authorized` direct), C (deny-DM rate-limit), D (Lane A passes / Lane B denies cross-lane semantics) test Lane A directly. **Decision:** delete tracks B/C/D from the harness; keep tracks A (CapabilitiesChecker `_matches` patterns), E (CLI), F (FileLoader log line), G (Lane B witness). Update the harness header comment, the human spec at `docs/superpowers/tests/e2e-capabilities.md`, and the PRD reference at `docs/superpowers/prds/08-capabilities.md:10`.
- If the resulting 4-track harness duplicates `py/tests/test_capabilities.py` coverage too closely, consider deleting the harness entirely and folding the surviving track logic into the unit tests. **Recommendation:** keep the harness with 4 tracks — its component-level shape is hard to reproduce in pytest's per-test isolation.

**Common.sh:**
- `tests/e2e/scenarios/common.sh:seed_capabilities` (lines 282-335 in current head): drop the `${ESRD_HOME}/default/capabilities.yaml` write, drop the `permissions: []` workaround paragraph (305-327), drop the "TODO: Once feishu_adapter_runner declares msg.send in handler_hello" comment.

**Documentation:**
- New: `docs/notes/auth-lane-a-removal.md` — migration note (§4 of this spec, copied + updated).

### Out-of-scope (explicit)

- **~~Adding an Elixir-side replacement for the deny-DM user feedback.~~ Now in-scope (v1.2).**
- **Touching Lane B's outbound checks.** T4's cross-app gate and admin-command gates stay verbatim.
- **Moving `msg.send` semantics into a different cap name.** Renaming is a separate cleanup PR.
- **Deleting `py/src/esr/capabilities.py`.** Explicit decision (S3 from review): **keep as-is**. `CapabilitiesChecker.__init__` / `reload` / `has` become dead methods but `_matches` is still used by `cap.py`. Either trim the file to a module-level `_matches` function or leave the dead methods harmless. Recommendation: **leave as-is** — zero churn for `cap.py`, future PR can do the full simplification once another use-case for `_matches` (or its replacement) clarifies the right shape.
- **`py/tests/test_capabilities.py`.** 15 tests of `has`/`reload`/`__init__` survive the source untouched — they keep passing and continue to validate `CapabilitiesChecker` for the CLI's needs. No deletion this PR.

## 4. Migration path / operator-visible changes

After this PR merges, operators of an existing deployment will see:

1. **User experience unchanged in single-FAA deployments.** A Feishu user without `workspace:<ws>/msg.send` still receives the same Chinese deny DM (`你无权使用此 bot，请联系管理员授权。`) with the same 10-min rate-limit. The DM now originates from Elixir (FAA peer dispatching a directive) instead of Python (adapter sending directly), but the wire-level behavior is identical.
2. **Multi-FAA deployments — soft regression on rate-limit (v1.4 from review).** The rate-limit map lives in each FAA's GenServer state. Today's Python `_last_deny_ts` is also per-adapter-process — same lifetime — so single-app deployments behave identically. PR-A introduces multi-FAA topology: one principal hitting chats bound to two different `instance_id`s (e.g. `feishu_app_dev` and `feishu_app_kanban`) lands in two distinct FAAs, each with its own rate-limit map. Result: that principal can receive *two* deny DMs within 10 min — one per FAA. Pre-PR-A this couldn't happen (single adapter); post-PR-A it would also happen with Python Lane A's `_last_deny_ts` for the same reason. Acceptable: the worst case is one extra DM per principal per offending app pair per window. If a stronger guarantee is needed, T-future moves the rate-limit to a shared ETS table keyed on `principal_id`.
3. **`capabilities.yaml` at `${ESRD_HOME}/default/`** — no longer read. Safe to delete; Lane B reads `${ESRD_HOME}/<instance>/capabilities.yaml` only.
4. **Telemetry name shifts.** `feishu Lane A: deny DM ...` log lines disappear; canonical signal is now `[:esr, :capabilities, :denied]` telemetry with `lane: :B_inbound`. Anyone scraping the old log line for alerts must update.
5. **`esr cap` CLI behavior** — unchanged. It writes to the same file Lane B reads.

A migration note will land at `docs/notes/auth-lane-a-removal.md` summarising the above (especially #2).

## 5. PR ordering

This change MUST land **after** PR-A (`feature/pr-a-multi-app`) merges, because:
- PR-A's spec/plan/tests reference Lane A's behavior in several places.
- PR-A's `seed_capabilities` writes both yaml paths; this PR cleanly removes the second.
- Stacking would conflate two different reviews.

If PR-A ships first, this PR's diff is small and self-contained.

## 6. Acceptance criteria

- All scenarios 01–04 pass (including PR-A's scenario 04 forbidden + non-member tests, which exercise Lane B exclusively).
- `mix test` green (Elixir Lane B unaffected).
- `pytest py/` green.
- `pytest adapters/feishu` green (after `test_lane_a.py` deletion, the remaining adapter tests all pass).
- `pytest adapters/cc_mcp` green (no Lane A dependency).
- A new doc at `docs/notes/auth-lane-a-removal.md` describes the migration.
- Diff line count: net deletion ≥ 400 LOC.

## 7. Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| **R1: ~~Stranger gets silence~~ Lane B's deny-DM dispatch fails to fire.** v1.2 keeps the deny DM but moves it to Elixir. If the FAA peer isn't registered or the directive dispatch path drops, no DM is sent. | Low → Medium | Mitigation: new unit tests in T-elixir (`feishu_app_adapter_deny_dm_test.exs`, `peer_server_lane_b_deny_dispatch_test.exs`) cover the happy path + missing-FAA fallback. The new e2e harness track exercises the full Elixir → adapter → wire path. |
| **R2: Rate-limit migration loses state on FAA restart.** Today the rate-limit map lives in adapter-process memory; same lifetime as the new Elixir map. Both lose state on restart. | Low | No regression — both implementations have the same restart semantics. ETS-backed persistence is a possible follow-up but out of scope. |
| **R3: A test outside `test_lane_a.py` quietly depends on Lane A.** | Low → Medium | Code review found 3 tests passing `capabilities_path` into `AdapterConfig` (`test_emit_events.py`, `test_envelope_principal.py`, `test_workspaces_load_shapes.py`). T1 explicitly removes those args. Plus 3 tracks (CAP-B/C/D) of the e2e_capabilities harness; T-harness explicitly handles. Full suite run before PR. |
| **R4: A future contributor re-adds Lane A out of habit.** | Low | This spec + the migration note + the updated `peer_server.ex:272` comment explain the rationale. |
| **R5: Operator scrapes `Lane A: deny DM` log lines for an alert.** | Low | Migration note calls out the telemetry name shift. Replace with `[:esr, :capabilities, :denied]` telemetry handler. |

## 8. Open questions

1. **~~Does Lane B need a stub equivalent on inbound?~~ Resolved (v1.1).** Lane B already has the inbound `msg.send` gate at `runtime/lib/esr/peer_server.ex:236-274`. v1.2 reframed: gate stays, Lane A's user-feedback role moves to Elixir.
2. **Should `permissions_registry.json` no longer be emitted next to `capabilities.yaml`?** It's used by `esr cap list` (CLI). **Out of scope** — keep emitting; it's free.
3. **Should the e2e harness's 4 surviving tracks fold into pytest?** Discussed in §3 In-scope. Recommendation locked: keep the 5-track harness (4 surviving + 1 new Lane B deny-DM track); component-level wiring is hard to express as unit tests.
4. **Rate-limit key (v1.4 — closed):** per-(principal, instance_id), not per-principal-globally as v1.3 hoped. Reason: rate-limit map lives in each FAA's GenServer state; multi-FAA deployments give per-(principal, instance_id) windows. This **matches today's Python behavior** for single-FAA deployments (the single per-adapter `_last_deny_ts` is the only state) and degrades gracefully for multi-FAA (one extra DM per principal per offending app pair per window — see §4 #2). A future PR can move to ETS-backed shared state keyed on `principal_id` if a stronger global guarantee is needed.

---

# Plan — `feature/drop-lane-a-auth-simplification`

## File map

### Modified
- `adapters/feishu/src/esr_feishu/adapter.py` — remove Lane A surface (3 call sites + 5 helpers + 2 constants + import + dataclass field)
- `adapters/feishu/tests/conftest.py` — remove `allow_all_capabilities` / `write_allow_all_capabilities` fixtures
- `adapters/feishu/tests/test_emit_events.py` — drop `capabilities_path` arg
- `adapters/feishu/tests/test_envelope_principal.py` — drop `capabilities_path` arg
- `adapters/feishu/tests/test_workspaces_load_shapes.py` — drop `capabilities_path` arg
- `tests/e2e/scenarios/common.sh:seed_capabilities` — drop `default/capabilities.yaml` write + workaround comment block
- `runtime/lib/esr/peer_server.ex:272` — comment update only (no logic change)
- `scripts/scenarios/e2e_capabilities.py` — delete tracks B/C/D, update header
- `docs/superpowers/tests/e2e-capabilities.md` — track inventory update
- `docs/superpowers/prds/08-capabilities.md:10` — reference fixup

### New
- `docs/notes/auth-lane-a-removal.md` — operator migration note

### Deleted
- `adapters/feishu/tests/test_lane_a.py` — 343 LOC

## Tasks

### T0 — Branch off `main` after PR-A merge

Don't start until `feature/pr-a-multi-app` is on `main`.

```bash
git fetch origin
git switch main && git pull
git switch -c feature/drop-lane-a-auth-simplification
```

### T1 — Land the Elixir-side deny-DM dispatch (NEW — v1.2)

**Order matters: this lands first, while Lane A is still active.** With both paths firing the user will receive *two* deny DMs per offense — annoying but explicit. T2 then removes Lane A and we're back to one DM.

Why-this-order: lets us validate Lane B's deny-DM path against the existing user-experience baseline (today's Lane A DM) before pulling Lane A. If the Elixir side has a bug, it shows as "wrong text / wrong rate-limit / FAA not registered" rather than as a silent regression.

**T1.1 — Define constants**

Add to `runtime/lib/esr/peers/feishu_app_adapter.ex` (or a small module, picker's choice):

```elixir
@deny_dm_text "你无权使用此 bot，请联系管理员授权。"
@deny_dm_interval_ms 10 * 60 * 1000  # 10 minutes
```

**T1.2 — Extend FAA state with rate-limit map**

In `init/1`, add `deny_dm_last_emit: %{}` to the state map. Keys are `principal_id`, values are monotonic_time/native ms.

**T1.3 — Add FAA `handle_info({:dispatch_deny_dm, _, _}, state)` clause**

**Critical (v1.3 from review):** FAA's existing `handle_info` only matches `{:inbound_event, _}` and `{:outbound, _}` (`feishu_app_adapter.ex:217-221`). Without an explicit new clause, `{:dispatch_deny_dm, _, _}` lands in the implicit default and the GenServer crashes. T1.3 adds the clause as part of the implementation, not as an afterthought.

Write the failing unit test first at `runtime/test/esr/peers/feishu_app_adapter_deny_dm_test.exs` (5 cases — was 4 in v1.2; v1.3 adds the missing-FAA-fallback case is in T1.4's test, here we cover FAA-side behavior):

```elixir
defmodule Esr.Peers.FeishuAppAdapterDenyDmTest do
  use ExUnit.Case, async: false
  alias Esr.Peers.FeishuAppAdapter

  test "first dispatch emits an outbound directive with the deny text"
  test "second dispatch within 10 min is suppressed"
  test "dispatch for different principals don't share rate-limit"
  test "dispatch after 10 min window emits again"
  test "dispatch with empty/missing principal_id is dropped (no DM, no crash)"
end
```

Implementation in FAA: pattern-match on `{:dispatch_deny_dm, principal_id, chat_id}`, read `state.deny_dm_last_emit`, compare with `:erlang.monotonic_time(:millisecond)`, if past window emit outbound directive (`{:outbound, %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => @deny_dm_text}}}` — same shape `feishu_chat_proxy.ex:382-386` uses, which routes through FAA's existing `{:outbound, _}` handler at line 220) + update map.

**T1.4 — Wire peer_server.ex deny path with the correct lookup**

Edit `runtime/lib/esr/peer_server.ex:266-273`. Replace the silent-drop block:

```elixir
:telemetry.execute(...)  # unchanged
dispatch_deny_dm(envelope)
{:noreply, state}
```

Add `defp dispatch_deny_dm(envelope)`. The `source` field on the envelope already carries `instance_id` (`runner_core.py:163` writes `f"esr://{HOST}/adapter:feishu/{instance_id}"`). One regex does both the Feishu-source guard AND the instance_id extraction:

```elixir
@feishu_source_re ~r{^esr://[^/]+/adapter:feishu/([^/]+)$}

defp dispatch_deny_dm(envelope) do
  with source when is_binary(source) <- envelope["source"],
       [_full, instance_id] <- Regex.run(@feishu_source_re, source),
       chat_id when is_binary(chat_id) <- get_in(envelope, ["payload", "args", "chat_id"]),
       principal_id when is_binary(principal_id) <- envelope["principal_id"] do
    case Registry.lookup(Esr.PeerRegistry, "feishu_app_adapter_#{instance_id}") do
      [{faa_pid, _}] when is_pid(faa_pid) ->
        send(faa_pid, {:dispatch_deny_dm, principal_id, chat_id})

      _ ->
        Logger.warning(
          "Lane B deny: no FAA registered for instance_id=#{inspect(instance_id)}; " <>
          "DM not sent (deny still effective; principal=#{inspect(principal_id)})"
        )
    end
  end
  :ok
end
```

**Why this shape (v1.4 from review):** earlier drafts proposed resolving `instance_id` through `Esr.Workspaces.Registry.workspace_for_chat/2` followed by an `instance_id_for_app/2` call. The latter doesn't exist, the Workspace struct (`runtime/lib/esr/workspaces/registry.ex:14-16`) has no `instances` field, and FCP's lookup at `feishu_chat_proxy.ex:404-406` only works because PR-A locks `app_id == instance_id`. v1.4 sidesteps the resolution entirely: `instance_id` is already on the wire — parse it from `source`. No Workspaces.Registry call, no AdapterChannel ingress changes, no new public API.

**T1.4b — Update peer_server.ex:272 comment (NEW in v1.3, was T4 in v1.2)**

In the same commit as T1.4, rewrite the comment from:
```elixir
# Drop silently — Lane A handles the user-facing deny response.
```
to:
```elixir
# Lane B owns deny + user-feedback (see dispatch_deny_dm/1 above).
# The deny-DM dispatch is async via the FAA peer; deny itself is
# observable via the [:esr, :capabilities, :denied] telemetry.
```

Test: `runtime/test/esr/peer_server_lane_b_deny_dispatch_test.exs` — 3 cases (was 2 in v1.2):
1. Deny path sends `{:dispatch_deny_dm, _, _}` to the resolved FAA pid.
2. Allow path doesn't send anything to FAA.
3. Deny path with no FAA registered (or non-Feishu source) logs a warning and doesn't crash.

**T1.5 — Run mix test**

```bash
cd runtime && mix test
```

All green. Both Lane A (still active) and Lane B's new dispatch fire on the same deny — user gets 2 DMs. This is intentional during the T1→T2 transition window.

**T1.6 — Commit**

```
PR drop-lane-a T1: Lane B deny-DM dispatch (Elixir side)

peer_server.ex deny path now dispatches a directive through the
source app's FAA peer, which sends the Chinese deny DM via the
existing outbound channel. Per-principal 10-min rate-limit lives
in FAA state. Lane A is still active in this commit; T2 removes it.

Tests: feishu_app_adapter_deny_dm_test.exs (5),
       peer_server_lane_b_deny_dispatch_test.exs (3).
Note: 2 deny DMs per offense are intentional during this T1→T2
window — Lane A is still active. T2 removes Lane A.
```

### T2 — Remove Lane A from adapter.py

Delete (verified line numbers post-review):
- Line 28: `from esr.capabilities import CapabilitiesChecker` import
- Lines 40-46: `_DENY_DM_INTERVAL_S` / `_DENY_DM_TEXT` constants
- Lines 129-139: Lane A init block (`self._caps`, `self._last_deny_ts`)
- Lines 189-211: `_load_capabilities_checker`
- Lines 215-282 (note: spec v1.0 said 213, correct is 215): `_is_authorized`, `_should_send_deny`, `_deny_rate_limited` — all three. **Note:** `_send_deny_dm` does NOT exist as a separate method; the DM logic is inlined inside `_deny_rate_limited`.
- Lines 825-835: first `if not self._is_authorized(...)` call site
- Lines 977-988 (v1.0 said 981-983, correct is 977-988): second call site
- Lines 1068-1076 (v1.0 said 1069-1075, correct is 1068-1076): third call site

Replace each call site with the bare `payload = self._build_msg_received_envelope(...)` body that was originally guarded — i.e. remove the `if not …: …; return` wrapper, leave the underlying emit untouched.

Also remove `AdapterConfig.capabilities_path` field if dataclass-defined; audit `getattr(self._config, "capabilities_path", None)` references and delete.

KEEP: `_workspace_of` and `_load_workspace_map` — Lane B reads `workspace_name` from envelope.

Verify after edit: `grep -n "_caps\|_is_authorized\|_should_send_deny\|_DENY_DM\|capabilities_checker\|capabilities_path" adapters/feishu/src/esr_feishu/adapter.py` returns nothing.

### T3 — Update tests/conftest + 3 dependent tests

```bash
git rm adapters/feishu/tests/test_lane_a.py
```

In `adapters/feishu/tests/conftest.py`: delete `allow_all_capabilities` and `write_allow_all_capabilities` fixtures (lines 22 and 48 in current head).

In each of `test_emit_events.py:37,70`, `test_envelope_principal.py:158,180`, `test_workspaces_load_shapes.py:38`: remove the `capabilities_path=...` argument from the `AdapterConfig(...)` calls.

Verify: `pytest adapters/feishu/` green after deletions + edits.

### T4 — Update common.sh seed_capabilities

`tests/e2e/scenarios/common.sh:282-335`: drop the second `printf '%s\n' "$caps_yaml" > "${ESRD_HOME}/default/capabilities.yaml"` write. Drop the multi-paragraph workaround comment (the `permissions: []` story + the `ou_e2e` TODO). Keep ou_admin wildcard config.

Optional but recommended: this PR is a good time to land the `ou_e2e workspace:e2e/msg.send` grant the TODO referenced — the `permissions: []` constraint that was blocking it goes away with Lane A. Out-of-scope for this spec; flag as follow-up.

### T5 — Trim e2e_capabilities.py harness + add Lane B deny-DM track (v1.2)

`scripts/scenarios/e2e_capabilities.py` (712 LOC): delete `track_cap_b`, `track_cap_c`, `track_cap_d` and any helpers they uniquely use (audit imports and helpers — `_send_inbound_to_adapter` etc. may go too if no other track uses it).

**Add new track CAP-H (or replace one of the deleted letters):** Lane B deny-DM end-to-end. Spawn esrd + mock_feishu, push an inbound from a principal without `msg.send`, assert mock_feishu's `/sent_messages` shows the deny DM with the Chinese text. Cover both first-emit (DM fires) and within-window (DM suppressed by rate-limit).

Update the module docstring (header says `7 tracks (CAP-A..CAP-G)`) and the exit-message format string.

Update `docs/superpowers/tests/e2e-capabilities.md`: remove tracks B/C/D sections, add the new Lane B deny-DM track section, document the lettering gap.

Update `docs/superpowers/prds/08-capabilities.md:10` (and any other reference grep finds): mark Lane A enforcement as removed; update the architectural diagram if it references Lane A.

Verify: `uv run --project py python scripts/scenarios/e2e_capabilities.py` exits 0 with `5 tracks PASSED` (4 surviving + 1 new).

### T6 — Add migration doc

Create `docs/notes/auth-lane-a-removal.md`. Content: §2.1 (what is lost), §4 (operator-visible changes), R4 (telemetry replacement note). Cross-link to spec.

### T7 — Run full suite

```bash
cd /Users/h2oslabs/Workspace/esr.git  # or wherever the merged main checkout lives
pytest py/                                        # 15+ tests
pytest adapters/feishu                            # ~20 tests after Lane A removal
pytest adapters/cc_mcp                            # 23 tests
cd runtime && mix test                            # ~520 tests
cd .. && uv run --project py python scripts/scenarios/e2e_capabilities.py
ESR_E2E_KEEP_LOGS=0 E2E_TIMEOUT=300 make e2e     # 01-04
```

Acceptance: all green except pre-existing flakes (`AdminSessionBootstrapFeishuTest`, `SessionsSupervisorTest leaked-children`, `EsrWeb.AdapterChannelNewChainTest forward_to_new_chain :error when no FeishuAppAdapter`).

### T8 — Subagent code review

Run `superpowers:code-reviewer` against the diff before opening PR. Specifically verify:
- No Lane A surface remains (`grep -rn "Lane A\|_is_authorized\|_caps\|_DENY_DM" adapters/feishu/ scripts/ tests/`).
- Stale `__pycache__` doesn't mask deleted tests (`find adapters -name __pycache__ -exec rm -rf {} + 2>/dev/null; pytest adapters/feishu` still green).
- common.sh writes only ONE capabilities.yaml path.
- The e2e harness genuinely runs only the surviving tracks.

### T9 — Open PR

Title: `auth: drop Lane A — Elixir runtime is the sole auth surface`

Body:
```
## Summary
- Removes Python-side msg.send gate (Lane A) from feishu adapter.
  Lane B at runtime/lib/esr/peer_server.ex:236-274 was already
  doing the same check — Lane A was a duplicate gate plus a
  user-facing deny-DM layer.
- After this PR: capability denies are silent at the user level,
  observable via [:esr, :capabilities, :denied] telemetry.
- Net diff: ~–500 LOC of Python + 343 LOC of tests + 3 e2e harness
  tracks deleted.
- Spec: docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md.
- Migration note: docs/notes/auth-lane-a-removal.md.

## Test plan
- [ ] pytest py/ green
- [ ] pytest adapters/feishu green (test_lane_a.py deleted, conftest cleanup)
- [ ] pytest adapters/cc_mcp green
- [ ] mix test green
- [ ] uv run scripts/scenarios/e2e_capabilities.py → 5 tracks PASSED (4 surviving + 1 new Lane B deny-DM)
- [ ] e2e 01/02/03/04 PASS
- [ ] grep verifies zero Lane A references

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Net diff: ~–500 LOC (Python + tests + harness) / ~+50 LOC (migration doc + comment update + spec) ≈ –450 LOC.

## Self-review

- **Risk of breaking inbound flow.** Mitigated by full e2e + the fact that Lane A was a *guard*, not a transformation; removing it can only make more messages flow through.
- **Risk of CapabilitiesChecker leftover surfaces.** Mitigated by T4's optional cleanup. Even without T4, the leftover code is dead; future PR can remove.
- **Risk of stale cap.yaml at `default/`** confusing operators who think it's still being read. Mitigated by migration doc.

## Execution handoff

Hand to: any implementer.
Estimate: 1–2h with the subagent-driven workflow (T1+T2 in one TDD cycle, T3+T5 in another, T4 optional, T6+T7+T8 wrap-up).
