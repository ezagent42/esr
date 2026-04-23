# PR-4b Snapshot — adapter_runner split into per-type sidecars

**Date**: 2026-04-23
**PR**: [ezagent42/esr#16](https://github.com/ezagent42/esr/pull/16)
**Merge commit**: `ab86a62`
**Branch**: `feature/peer-session-refactor` (merged, branch deleted)
**Duration**: ~same day as PR-4a (single working day, 10 commits)

## Shipped

- **`py/src/_adapter_common/`** shared package. Lifted from `esr.ipc.adapter_runner`:
  - `runner_core.py` — `process_directive` / `directive_loop` / `event_loop` / `watch_disconnect` / `run_with_client` / `run_with_reconnect` / `run`.
  - `url.py` — `resolve_url` (port-file + launchctl kickstart fallback).
  - `reconnect.py` — `RECONNECT_BACKOFF_SCHEDULE`.
  - `main.py` — `build_main(allowed_adapters=..., prog=...)` factory used by all three sidecars.
- **`py/src/feishu_adapter_runner/`** — ~25 LoC glue. `ALLOWED_ADAPTERS = frozenset({"feishu"})`.
- **`py/src/cc_adapter_runner/`** — same shape. `ALLOWED_ADAPTERS = frozenset({"cc_tmux", "cc_mcp"})`.
- **`py/src/generic_adapter_runner/`** — catch-all fallback. Emits `DeprecationWarning` on stderr at startup (operators: add the adapter to a dedicated sidecar's allowlist instead of relying on the generic fallback).
- **`py/src/esr/ipc/adapter_runner.py`** — 399 → 56 lines. Pure deprecation shim that re-exports the `_adapter_common` public surface plus its own `build_main(allowed_adapters=None, ...)` `main` attribute (invokable as `python -m esr.ipc.adapter_runner` during the migration window). Hard-delete batched into PR-5.
- **`runtime/lib/esr/worker_supervisor.ex`** — new `sidecar_module/1` dispatch table:
  ```elixir
  @sidecar_dispatch %{
    "feishu"  => "feishu_adapter_runner",
    "cc_tmux" => "cc_adapter_runner",
    "cc_mcp"  => "cc_adapter_runner"
  }
  def sidecar_module(name), do: Map.get(@sidecar_dispatch, name, "generic_adapter_runner")
  ```
  `handle_call({:ensure_adapter, ...})` now invokes `python -m #{sidecar_module(name)}` instead of the hard-coded monolith module. `log_path_for/1` pattern-matches all four module names so log file naming remains consistent.
- **Scripts**
  - `scripts/spawn_scenario_workers.sh` — cc_tmux + feishu entries route via `cc_adapter_runner` / `feishu_adapter_runner`.
  - `scripts/kill_scenario_workers.sh:23` + `scripts/esrd.sh:125` — pgrep/pkill patterns widened to `'esr\.ipc\.(adapter_runner|handler_worker)|python -m (feishu|cc|generic)_adapter_runner'`.
  - `scripts/verify_entry_bodies.py` — manifest updated to check `_adapter_common.runner_core.run` + `_adapter_common.main.build_main` (the re-exported `esr.ipc.adapter_runner.run` is not a `FunctionDef`, so the AST walker can't see it).
- **Tests**
  - `py/tests/adapter_runners/test_runner_core.py` — 12 cases, lifted from old `test_adapter_runner*.py`.
  - Per-sidecar tests: 3 feishu + 4 cc + 3 generic.
  - `test_dispatch_allowlist.py` — 10 parametrised cases covering all 3 sidecars × relevant adapter combos.
  - `runtime/test/esr/worker_supervisor_test.exs` — 2 new cases for `sidecar_module/1` (known dispatch + generic fallback).
  - `runtime/test/esr/integration/adapter_runner_split_test.exs` — spawns real `feishu` + `cc_tmux` adapters via `WorkerSupervisor.ensure_adapter/4`, asserts `ps -o command=` argv contains the right sidecar module name and does NOT contain `esr.ipc.adapter_runner`.

## Regression status at merge

| Suite | Result |
|---|---|
| `uv --project py run pytest py/tests/` | 435 passed, 1 skipped |
| `cd runtime && mix test` | 383 tests, 0 failures |
| `cd runtime && mix test --include integration` | 402 tests, 0 failures |
| `uv run --project py python scripts/verify_entry_bodies.py` | LG-2 PASS |

## Commits (10)

| SHA | Task | Title |
|---|---|---|
| `e2fa359` | P4b-1 | refactor(py): extract _adapter_common shared package |
| `d6d4ea4` | P4b-2 | feat(py): feishu_adapter_runner sidecar |
| `69cb2aa` | P4b-3 | feat(py): cc_adapter_runner sidecar |
| `a76001a` | P4b-4 | feat(py): generic_adapter_runner fallback sidecar |
| `7a872e8` | P4b-5 | test(py): parametrised allowlist dispatch table |
| `500e0e5` | P4b-6 | refactor(py): esr.ipc.adapter_runner becomes 56-line deprecation shim |
| `d8bd81b` | — | fix(adapter_runner): resolve Pyright type issues in runner_core |
| `f20180a` | P4b-7 | feat(worker_supervisor): sidecar_module/1 dispatch table |
| `b542c7b` | P4b-8 | chore(scripts): route scenario workers through per-type sidecars |
| `8535525` | P4b-9 | test(integration): verify ensure_adapter routes via per-type sidecars |

Squash-merged to `main` as `ab86a62`.

## Drift findings resolved

- **D4b-1**: no per-sidecar Elixir Peer wrappers needed — adapter sidecars speak Phoenix channels (not stdin/stdout), so `PyProcess` doesn't apply. Scope reduced from "Elixir Peer wrappers per sidecar" to "WorkerSupervisor dispatch table".
- **D4b-2**: `esr.ipc.adapter_runner` is a shim, not deleted. Hard-delete batched into PR-5.
- **D4b-3**: `handler_worker.py` consolidation into `_ipc_common/` deferred to PR-5.

## Known unknowns left for PR-5

1. **Hard-delete `esr.ipc.adapter_runner` shim** — no live callers remain after PR-4b; grep + delete + update the two `scripts/scenarios/e2e_dev_prod_isolation.py` references (lines 703, 717, 725).
2. **`handler_worker.py` consolidation** — lift `_watch_disconnect` + `_resolve_url` into `_ipc_common/` mirroring `_adapter_common/` shape.
3. **`conflicting behaviours` compile warnings** — Voice\* + FeishuAppAdapter + CCProcess all warn about `init/1` being defined by both `Esr.Peer.Stateful` and `GenServer`. Pre-existing from PR-4a (`use Esr.Peer.Stateful` macro generates a default `init/1` that collides with user-defined one). Fix: resolve by picking one source of truth for the `@impl` annotation in the macro-expansion.
4. **E2E live-smoke of the feishu → CC chain** — runtime unit + integration tests pass, but a real Feishu message round-trip (user-visible) has not been exercised end-to-end since PR-2 landed. Worth a dedicated scenario script in PR-5/6.

## What changed relative to the outline

- **10 commits, single day** — matches the expansion doc's "2-3 days" estimate, came in at the optimistic end because the Python split was mostly mechanical lift + the Elixir dispatch was a 20-line table.
- **Pyright fixes landed mid-PR** (`d8bd81b`) — not in the expansion doc. Addressed parameter shadowing (`client_factory` nested `def` obscured the parameter) and a cascading AdapterConfig type mismatch by widening `load_adapter_factory`'s return type to `Callable[..., Any]` and annotating the factory call site with `Any`. Rationale: adapters actually accept `AdapterConfig` for attribute-access ergonomics; the old `dict[str, Any]` type hint was aspirational/wrong.
