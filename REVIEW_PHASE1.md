# Phase 1 Review — ESR Elixir Runtime

Performed by `superpowers:code-reviewer` subagent on 2026-04-19.
Scope: `runtime/lib/esr/**`, `runtime/lib/esr_web/**`, `runtime/test/**`, `runtime/mix.exs`, `runtime/config/**`.

## Summary
- Files reviewed: 25 lib + 21 test + mix.exs + 5 config
- Critical findings: 5
- Significant findings: 8
- Minor findings: 11
- Overall: **BLOCK** — two critical findings make the runtime unable to deliver directives to a real adapter or satisfy F06's retry/dead-letter contract.

## Critical Findings (must fix before Phase 2 merges)

### C1 — Emit publishes to bare `adapter:<name>` topic; AdapterChannels join on `adapter:<name>/<instance_id>`
**File:** `runtime/lib/esr/peer_server.ex:229-252`
**Fix:** broadcast on `adapter:<adapter>/<actor_id>` (convention: emitter = bound peer). Update `peer_server_action_dispatch_test.exs` to subscribe long-form topic.

### C2 — Emit does not await `directive_ack`, no correlation state
**File:** `runtime/lib/esr/peer_server.ex:229-252, 170-173`
**Fix:** track `pending_directives: %{id => {action, deadline}}`; `handle_info({:directive_ack, _})` matches id, drops entry, emits completion telemetry, enqueues failures to DeadLetter.

### C3 — F06 retry + dead-letter on handler error is not implemented
**File:** `runtime/lib/esr/peer_server.ex:186-209`
**Fix:** retry once on `:handler_timeout` / `:worker_crashed`; on exhaustion enqueue to DeadLetter and emit `[:esr, :handler, :retry_exhausted]`.

### C4 — Persist-then-emit ordering inverted, AND F18 persistence not wired
**File:** `runtime/lib/esr/peer_server.ex:186-199`, `runtime/lib/esr/persistence/supervisor.ex`
**Fix:** start `Esr.Persistence.Ets` in the supervision tree; rehydrate on boot; reorder to persist → emit; add 30s checkpoint.

### C5 — `invoke_command` action is stubbed (only emits telemetry)
**File:** `runtime/lib/esr/peer_server.ex:267-275`
**Fix:** add artifact store to `Esr.Topology.Registry`; delegate to `Esr.Topology.Instantiator.instantiate/2` via a Task or a dedicated GenServer to avoid blocking PeerServer on init_directive waits.

## Significant Findings

- **S1** `dedup_keys` is unbounded — PRD F05 requires max 1000 LRU (`peer_server.ex:34, 211-216`).
- **S2** `Instantiator.instantiate/2` blocks caller up to 30s; selective-receive leaks unmatched `{:directive_ack, _}` (`topology/instantiator.ex:226-239`).
- **S3** `init_directive` timeout test is flaky — rollback is not synchronous (`test/esr/topology/init_directive_test.exs:144-155`).
- **S4** `DeadLetter` module is implemented but never started or called.
- **S5** `AdapterHub.Registry` ETS lacks `write_concurrency`; no process monitoring for dead bindings.
- **S6** `String.to_atom/1` on template placeholder names (`topology/instantiator.ex:112-119`) — AGENTS.md rule violation.
- **S7** `Topology.Registry.register/3` TOCTOU race; use `:ets.insert_new/2`.
- **S8** PeerServer sets `trap_exit` but has no `{:EXIT, _, _}` handler → unhandled_info warnings.

## Minor Findings

- **M1** `mix format --check-formatted` fails on 4 files; Makefile lint doesn't check format.
- **M2** Several emitted telemetry events missing from `Attach.@events` allow-list (invisible to Buffer).
- **M3** Unused leftover phx.new config: generators/live_view/session.
- **M4** `config :esr, dev_routes: true` nowhere read.
- **M5** Template `@moduledoc` on `Esr` and `EsrWeb`.
- **M6** `@impl true` vs `@impl Name` inconsistency across modules.
- **M7** `toposort/1` can't distinguish cycle from unknown dep.
- **M8** `AdapterSocket.id/1` returns nil — no forced-disconnect support.
- **M9** Commented-out `socket "/live"` block in endpoint.ex.
- **M10** Section-comment style inconsistency across modules.
- **M11** Empty `HandlerRouter.Supervisor` / `Persistence.Supervisor` child lists.

## Notes (non-findings)

1. F13b directive_ack dual-publish is clean design.
2. Kahn toposort implementation is readable (count_indegrees/collect_edges split).
3. Test module splitting matches PRD unit-test matrix well.
4. ETS-as-table-owned-by-named-GenServer is right pattern for `AdapterHub.Registry`.
