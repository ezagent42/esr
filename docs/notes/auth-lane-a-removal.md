# Auth Lane A removal — migration note

Captured 2026-04-26. Spec: `docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md`.

## What changed

The Python feishu adapter no longer enforces `workspace:<ws>/msg.send`
on inbound messages. The check + the Chinese deny-DM
(`你无权使用此 bot，请联系管理员授权。`) + the 10-min rate-limit all
moved to the Elixir runtime — same yaml grant, same wire-level user
experience, single source of truth.

## What you need to do (operator side)

**Nothing visible.** Stranger DM-ing the bot still sees the same
deny DM under the same rate-limit window. The reply now originates
from Elixir (FAA peer dispatching a directive) instead of Python
(adapter sending directly), but the wire shape is identical.

If you have any of these, update them:

1. **`${ESRD_HOME}/default/capabilities.yaml`** — no longer read.
   Safe to delete after one full deploy cycle confirms nothing is
   missing it. The file at `${ESRD_HOME}/<instance>/capabilities.yaml`
   is the sole source of truth.
2. **Log-scrapers watching `feishu Lane A: deny DM ...`** — those
   lines are gone. The canonical signal is now
   `[:esr, :capabilities, :denied]` telemetry with `lane: :B_inbound`
   plus `principal_id` / `required_perm` / `actor_id` metadata.
   Switch alerts to a telemetry handler.
3. **Test harnesses passing `capabilities_path` into `AdapterConfig`**
   — no longer used (the adapter doesn't load capabilities anymore).
   Drop the kwarg; tests should work unchanged.

## What was removed (code-side, FYI)

- `adapters/feishu/src/esr_feishu/adapter.py`:
  - `_DENY_WINDOW_S` / `_DENY_DM_TEXT` module constants
  - `_load_capabilities_checker` / `_is_authorized` /
    `_should_send_deny` / `_deny_rate_limited` instance methods
  - `self._caps` / `self._last_deny_ts` instance state
  - 3 call sites that gated emission via `if not self._is_authorized:`
- `adapters/feishu/tests/test_lane_a.py` — entire file (343 LOC)
- `adapters/feishu/tests/conftest.py` — `allow_all_capabilities` /
  `write_allow_all_capabilities` fixtures
- `tests/e2e/scenarios/common.sh:seed_capabilities` — the
  `${ESRD_HOME}/default/capabilities.yaml` write (instance-scoped path
  is the only one written now)
- `scripts/scenarios/e2e_capabilities.py` — 3 of 7 tracks (CAP-B
  regular-user-flow, CAP-C deny+rate-limit, CAP-D Lane-A-passes/
  Lane-B-denies cross-lane). 4 tracks (A/E/F/G) survive.

## What was added (code-side, FYI)

- `runtime/lib/esr/peer_server.ex`: deny path now calls
  `dispatch_deny_dm(envelope)` instead of dropping silently. The
  comment at line 272 is updated.
- `runtime/lib/esr/peers/feishu_app_adapter.ex`:
  - `@deny_dm_text` / `@deny_dm_interval_ms` module attributes
  - `deny_dm_last_emit: %{}` state field (per-principal monotonic ms)
  - `handle_info({:dispatch_deny_dm, principal_id, chat_id}, state)`
    clause that emits the directive via the existing
    `{:outbound, _}` → adapter channel
- `runtime/test/esr/peers/feishu_app_adapter_deny_dm_test.exs` —
  5 tests covering rate-limit + per-principal isolation + missing
  args
- `runtime/test/esr/peer_server_lane_b_deny_dispatch_test.exs` —
  4 tests covering deny→FAA dispatch + non-Feishu source guard +
  no-FAA-registered fallback

## Why we did this

Lane A was a duplicate gate. Lane B at `peer_server.ex:236-274`
already ran the same `Capabilities.has?(principal_id,
"workspace:<ws>/msg.send")` check on every inbound and emitted
`[:esr, :capabilities, :denied]` telemetry. Lane A sat in front of
it, doing the same check against the same yaml from a different
file path, and additionally rendering the user-facing deny DM. The
result was a 4-state truth table (allow/allow, allow/deny,
deny/allow, deny/deny) where the two divergent states were latent
bugs:

- **allow/deny** — Lane A passes (Python yaml stale), Lane B denies
  (Elixir yaml fresh). Inbound reaches runtime, gets dropped, no
  user feedback. Confusing.
- **deny/allow** — Lane A denies (Python yaml fresh), Lane B would
  allow (Elixir yaml stale). User sees deny DM, runtime never
  notified the deny happened. Hard to audit.

The dual-write yaml burden also forced operators to keep two paths
synced. After this PR, one path, one gate, one DM dispatcher.

The historical reason Lane A existed: PR-9-era defense-in-depth.
Lane B was the runtime's gate; Lane A was added "to short-circuit
unauthorized inbound at the adapter so esrd doesn't spend a hop on
denied traffic." After Lane B's `[:esr, :capabilities, :denied]`
telemetry was added (real time, no extra hop matters), Lane A's
short-circuit value dropped to zero — but the code stayed.

## Risks (none verified to materialize)

| Risk | Severity | Mitigation |
|------|----------|------------|
| Lane B's deny-DM dispatch fails to fire | Low → Medium | Unit tests cover happy path + missing-FAA + non-Feishu source. Live-Feishu smoke would catch any wire-level gap; tracked at `docs/notes/futures/multi-app-deferred.md` §3. |
| Multi-FAA rate-limit per-FAA, not strict per-principal-globally | Low | Documented at `docs/notes/futures/multi-app-deferred.md` §4. Single-FAA deployments behave identically to today. |
| Operator scrapes `Lane A: deny DM` log lines | Low | This doc + `[:esr, :capabilities, :denied]` telemetry path. |

## See also

- Spec (approved v1.4): `docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md`
- Lane B inbound gate (unchanged): `runtime/lib/esr/peer_server.ex:236-274`
- FAA deny-DM dispatch: `runtime/lib/esr/peers/feishu_app_adapter.ex`
  (search for `@deny_dm_text` / `:dispatch_deny_dm`)
- Telemetry signal: `[:esr, :capabilities, :denied]` with
  `lane: :B_inbound` / `principal_id` / `required_perm` / `actor_id`
