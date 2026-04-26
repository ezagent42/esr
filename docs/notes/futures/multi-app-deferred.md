# Multi-app PR-A — deferred items

Tracked here so they don't get lost. None block PR-A merge.

## 1. ETS wipe race window (PR-A spec §9.6)

`Esr.SessionRegistry`'s `init/1` calls `:ets.delete_all_objects/1` on
boot. If an inbound arrives during the ~ms between table-clear and
the first re-register, `lookup_by_chat_thread/3` returns
`:not_found`, triggering auto-create — duplicate sessions for the
mid-flight inbound. Boot is normally quiescent so impact is low.

Fix path: gate inbound dispatch on a "registry ready" signal (e.g.,
`Application.fetch_env(:esr, :registry_ready)` set in `init/1`'s
final return).

## 2. Cross-tenant principal aliasing (PR-A spec §9.5)

A Feishu user has different `open_id` per tenant. PR-A's
authorization gate assumes `state.principal_id` is also a valid
principal in the target workspace's `capabilities.yaml`. This is
true for two apps under one tenant; cross-tenant cross-app would
break.

Fix path: introduce a `principal_alias` table (yaml, ETS-backed)
mapping `(source_open_id, source_tenant) → (target_open_id,
target_tenant)`. Authorization gate checks aliases first, then
direct match.

## 3. Live Feishu smoke gate (PR-A spec §9.1)

mock_feishu simulates app-membership rejection at our discretion.
Real Feishu's exact error code + retry semantics for "app-B not
member of chat-A" are not characterized. Need a manual or scheduled
smoke test against real Feishu before declaring PR-A prod-ready.

Fix path: a `make smoke-live` recipe that runs scenario 04 against
real Feishu credentials (read from `.env.live`). Run on demand,
not in CI.

## 4. Rate-limit map per-FAA, not global per-principal (added 2026-04-26)

The drop-Lane-A PR (post-PR-A) relocates the deny-DM rate-limit
to FAA GenServer state. Each FAA owns its own
`deny_dm_last_emit: %{}` map. Multi-FAA deployments give per-
(principal, instance_id) windows, not strict per-principal-globally.

Single-FAA deployments behave identically to today's Lane A
`_last_deny_ts: dict[str, float]`. Multi-FAA deployments may
emit one extra DM per principal per offending app pair per
10-min window.

Fix path: shared ETS table keyed on `principal_id` if a stronger
global guarantee becomes needed.

## 5. Scenario 04 §5.2/§5.3 still depends on CC cooperating (added 2026-04-26)

PR-A T9 step 2 (cross-app forward happy path) still drives the
cross-app reply via a CC prompt. Real CC has refused this prompt
in some runs as a prompt-injection / lateral-movement signal.
The forbidden + non-member denial paths (§5.4/§5.5) sidestep
this via the `cross_app_test` admin command — same path could
extend to §5.2/§5.3 if the prompt-driven approach proves flaky
in CI.

Fix path: extend `cross_app_test` admin command to take a target
chat membership flag, or accept that §5.2/§5.3 are best-effort
prompt-driven and rely on unit tests
(`runtime/test/esr/peers/feishu_chat_proxy_cross_app_test.exs`)
for the determinism guarantees.

## 6. Local-proxy ephemeral-port-pool exhaustion (added 2026-04-26)

Discovered during PR-A T9 e2e validation: a local proxy on
`127.0.0.1:7897` (Clash / mihomo / similar) can consume the
entire 127.0.0.1 ephemeral port pool with TIME_WAIT sockets
(observed 50k+). All 127.0.0.1 outbound — including
mock_feishu curl probes AND real channel-server connections to
open.feishu.cn — fails with `[Errno 49] Can't assign requested
address` (EADDRNOTAVAIL).

This is a workstation environment issue, not a code defect, but
it makes CI/local e2e flaky. Worth documenting for the runbook.

Mitigations:
- `pkill -9 -f mihomo` / restart the proxy
- Lengthen test waits to allow TIME_WAIT (2*MSL = 30s default
  on macOS) to drain
- Run e2e on a dedicated machine without local proxy churn

Not a fix path so much as a known-issue note for the troubleshooting
guide.
