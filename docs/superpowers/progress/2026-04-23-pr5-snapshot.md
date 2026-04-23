# PR-5 Snapshot — cleanup + consolidation merged

**Date**: 2026-04-23
**PR**: [ezagent42/esr#18](https://github.com/ezagent42/esr/pull/18)
**Merge commit**: `f116fad`
**Branch**: `feature/peer-session-refactor` (merged, branch deleted)
**Duration**: same day as PR-4b (14 commits across 12 planned tasks + 2 interim fixes)

## Shipped

### Python consolidation

- **`py/src/_ipc_common/`** — new shared package for IPC plumbing used by BOTH adapter sidecars and handler_worker:
  - `url.py` — port-file-aware URL resolution (lifted from `_adapter_common/`).
  - `reconnect.py` — exponential backoff schedule (lifted from `_adapter_common/`).
  - `disconnect.py` — WS disconnect watcher (lifted from `_adapter_common/runner_core.py`).
- **`py/src/esr/ipc/adapter_runner.py`** — **hard-deleted**. All 12 non-doc callers retargeted to `_adapter_common.*` / `_ipc_common.*` APIs. The PR-4b deprecation window is closed.
- **`py/src/esr/ipc/handler_worker.py`** — 381 → 327 lines. Three private duplicates (`_watch_disconnect`, `_resolve_url`, `_RECONNECT_BACKOFF_SCHEDULE`) replaced with `_ipc_common/` imports. Two pyright fixes carried forward from PR-4b commit `d8bd81b`: unused `_pending` destructure renamed, `client_factory` parameter-shadowing pattern normalised to `factory_fn: Any = client_factory or (lambda ...)`.

### Elixir macro fix

- **`runtime/lib/esr/peer/stateful.ex`** — `@callback init/1` removed. GenServer (or `Esr.OSProcess` for OS-process peers) owns that callback natively; the behaviour used to redeclare it which caused every `use Esr.Peer.Stateful` + `use GenServer` module to emit `conflicting behaviours found` on compile.
- **9 peer modules** — `init/1` annotations retagged:
  - `@impl GenServer`: `VoiceASR`, `VoiceTTS`, `VoiceE2E`, `FeishuAppAdapter`, `FeishuChatProxy`, `CCProcess`, `SlashHandler`.
  - `@impl` dropped entirely (OSProcessWorker hosts the real init): `TmuxProcess`, `PyProcess`.
- **`runtime/lib/esr/peers/feishu_chat_proxy.ex:87`** — dead `{:forward, _, ns}` clause pruned. Elixir 1.18's type checker flagged it and it was blocking `mix compile --warnings-as-errors`.

### Docs + perf

- **`docs/architecture.md`** (new) — post-refactor Elixir + Python module tree. All 47 file paths validated against the filesystem.
- **`docs/notes/pr5-perf-baseline.md`** (new) — SessionRouter dispatch-latency baseline at **p50 = 2 µs, p99 = 7 µs** from the new synthetic smoke.
- **`runtime/test/esr/perf/session_router_dispatch_latency_test.exs`** (new) — 1000-iteration synthetic smoke tagged `:perf` (excluded by default). Measures `send(FeishuAppAdapter, {:inbound_event, env})` → `SessionRegistry.lookup_by_chat_thread` → `send(feishu_chat_proxy, {:feishu_inbound, env})` round-trip.
  - **Plan correction captured**: the plan's skeleton sent to `SessionRouter` but that's the *control-plane* GenServer; the real `:inbound_event` dispatcher is `FeishuAppAdapter`. Subagent caught this and adjusted, mirroring `n2_sessions_test.exs`.
- **`USE_NEW_PEER_CHAIN`** stale doc comments — 3 files (`adapter_channel.ex`, `adapter_channel_principal_test.exs`, `adapter_channel_new_chain_test.exs`) rewritten past-tense so future readers don't waste cycles searching for a flag that was removed in P2-16.

## Regression status at merge

| Suite | Result |
|---|---|
| `uv --project py run pytest py/tests/` | **445 passed**, 1 skipped (+10 net vs PR-4b's 435) |
| `cd runtime && mix test` | **385 tests, 0 failures** (21 excluded — includes new `:perf` tag) |
| `cd runtime && mix test --include integration` | **404 tests, 0 failures** |
| `cd runtime && mix test --include os_cleanup` | **386 tests, 0 failures on rerun**. One pre-existing flake at `feishu_app_adapter_test.exs:13` (`:fab_test_sup` name collision) surfaces ~1 in 3 runs; documented as deferred to PR-6. |
| `cd runtime && mix compile --force --warnings-as-errors` | **clean** |
| `uv run --project py python scripts/verify_entry_bodies.py` | **LG-2 PASS** |
| `mix test test/esr/perf/... --only perf` | **p50 = 2 µs, p99 = 7 µs** (stable across 4 runs) |

## Commits (14)

| SHA | Task | Title |
|---|---|---|
| `6b8f392` | — | docs(plans): PR-5 cleanup plan — bite-sized TDD steps |
| `8e11002` | P5-1 | feat(py): add _ipc_common/ package skeleton |
| `fd33a11` | P5-2 | refactor(py): move url.py + reconnect.py to _ipc_common/ |
| `3db779e` | P5-2 fixup | docs(py): fix stale _adapter_common docstring refs |
| `89c198a` | P5-3 | refactor(py): lift watch_disconnect to _ipc_common/ |
| `798eeee` | P5-4 | refactor(py): handler_worker imports from _ipc_common/ |
| `7eaf96f` | interim | fix(shim): re-point esr.ipc.adapter_runner imports to _ipc_common/ |
| `a5a3f6c` | P5-5 | refactor: hard-delete esr.ipc.adapter_runner shim |
| `0195454` | P5-5 fixup | chore: address P5-5 code-review feedback |
| `42211e8` | P5-6 | fix(peer): Esr.Peer.Stateful drops @callback init/1 |
| `5d68efb` | P5-7 | fix(peers): retag init/1 @impl GenServer post-P5-6 |
| `c7b9e55` | P5-7 follow | fix(peer): drop dead forward-clause in FeishuChatProxy.handle_info |
| `4a6f56f` | P5-8 | docs(adapter_channel): past-tense the USE_NEW_PEER_CHAIN references |
| `95ee159` | P5-9 | docs(architecture): post-refactor module tree |
| `3d83bcd` | P5-10 | perf(test): SessionRouter dispatch latency smoke |

Squash-merged to `main` as `f116fad` (PR #18).

## Plan deviations worth documenting

- **P5-2 scope expansion**: plan listed only `_adapter_common/runner_core.py` for the import retargeting, but `py/tests/adapter_runners/test_runner_core.py` had 3 `from _adapter_common.url import resolve_url` lines that also broke on the delete. Subagent added them to the commit; mechanically forced, correctly bundled.
- **P5-4 shim-break surfacing**: deleting `_adapter_common/{url,reconnect}.py` in P5-2 broke the `esr.ipc.adapter_runner` shim's own imports. P5-2's regression check only ran `adapter_runners/` and missed it; P5-4's full pytest revealed 4 failing tests. Interim fix `7eaf96f` re-pointed the shim to `_ipc_common/` for the one-task window until P5-5 hard-deleted it. Small throwaway work, clean between-task tree invariant. Lesson for future tasks: pair the task's regression check with a full `pytest py/tests/` if the task deletes a publicly-exported module.
- **P5-6 + P5-7 ordering**: P5-6 removed `@callback init/1` from `Esr.Peer.Stateful`; P5-7 mopped up the 7 (actually 9 — compiler flagged 2 more than plan listed) peers with stale `@impl` annotations. P5-6 in isolation emitted compile warnings; that was expected and closed in P5-7. Committed separately for clean blame.
- **P5-7 `@impl` dropping for OSProcess peers**: plan said "retag to `@impl GenServer`" universally, but `TmuxProcess` + `PyProcess` don't `use GenServer` — the nested `OSProcessWorker` does. Correct fix was to drop the `@impl` with a clarifying comment. Subagent caught this and did it right.
- **P5-10 dispatch entry correction**: plan's skeleton sent to `Esr.SessionRouter` but that's the control-plane GenServer; the real `:inbound_event` handler is `FeishuAppAdapter`. Subagent read `n2_sessions_test.exs` and corrected the wiring. The resulting test measures the control-plane dispatch exactly as spec §11 calls out, just via the right entry point.

## Known unknowns left for PR-6

1. **Pre-existing test-ordering flake** — `feishu_app_adapter_test.exs:13`'s `DynamicSupervisor.start_link(name: :fab_test_sup)` collides with a leftover-from-earlier-test supervisor about 1 in 3 runs of `mix test --include os_cleanup`. Fix: either drop the `:fab_test_sup` name (let ExUnit auto-generate a unique one) or add a more aggressive `on_exit` teardown that waits for the supervisor's actual termination.
2. **Duplicate `factory_fn` pattern** now in two files (`_adapter_common/runner_core.py` and `esr/ipc/handler_worker.py`). Two copies is under the extraction threshold; if PR-6 adds a third, lift into `_ipc_common/`.
3. **Stale doc references** outside PR-5 scope that still mention the deleted shim:
   - `.claude/skills/project-discussion-esr/scripts/test-py-ipc.sh:9` lists deleted test files.
   - `docs/operations/dev-prod-isolation.md:205` points `_resolve_url` to the dead shim path.
   - `docs/notes/feishu-ws-ownership-python.md:15,40,47,61` diagrams the dead path.
4. **Live Feishu→CC smoke** — runtime unit + integration + perf smoke all green, but a real Feishu message round-trip (user-visible) still hasn't been exercised end-to-end. Needs live esrd + real Feishu app credentials; scheduled for post-PR-7 when esrd itself is dogfooded.

## What changed relative to the outline

- **14 commits, same day** — matches the plan's 12 bite-sized tasks plus 2 interim fixes (shim re-target in P5-4, dead-clause prune in P5-7 follow). One task (P5-11 full regression) didn't need its own commit — the gate was verification only.
- **Net LoC delta: –54 in `handler_worker.py`, –56 in `adapter_runner.py` (deleted), +~150 across new tests + docs + perf smoke.** Aggregate slightly positive on total LoC because the docs and perf smoke added new artifacts, but the production-code surface shrunk as intended.
- **Subagent-driven execution** — 10 implementer dispatches + 5 spec-reviews + 4 quality-reviews + 3 fixup dispatches. Every task cycle ended with both reviewers green before moving on. Estimated main-context savings vs inline: ~60% (the plan + reviews stayed in the main session, the per-task code was isolated).
