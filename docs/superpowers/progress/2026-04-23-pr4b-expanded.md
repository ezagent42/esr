# PR-4b Expanded: adapter_runner Monolith Split (feishu / cc_tmux / generic sidecars + Elixir wrappers)

**Date**: 2026-04-23
**Branch**: `feature/peer-session-refactor` (worktree `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/`)
**Target duration**: 2-3 days (smaller than outline suggested per drift finding D4b-1).

**Prereq reading order:**
1. `docs/superpowers/progress/2026-04-23-pr4a-snapshot.md`
2. `docs/superpowers/progress/2026-04-23-pr3-snapshot.md`
3. `.claude/skills/erlexec-elixir/SKILL.md`
4. `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md` (search `# PR-4b`)
5. `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §8.2
6. Current monolith: `py/src/esr/ipc/adapter_runner.py` (399 lines)
7. Consumers: `runtime/lib/esr/worker_supervisor.ex`, `scripts/spawn_scenario_workers.sh`, `scripts/esrd.sh`
8. `runtime/test/support/tmux_isolation.ex` (PR-4a hygiene)

## Scope / Non-scope

**In**: three Python sidecars (`feishu_adapter_runner`, `cc_adapter_runner`, `generic_adapter_runner`) + `_adapter_common/` shared package + deprecation shim on `esr.ipc.adapter_runner` + `Esr.WorkerSupervisor` dispatch table + scripts update + one E2E integration test.

**Out**: per-sidecar Elixir Peer wrappers (D4b-1 — adapter sidecars speak Phoenix channels, not stdin/stdout; `PyProcess` macro doesn't apply); hard-delete of old `adapter_runner.py` (D4b-2 — shim with `DeprecationWarning`, hard-delete batched into PR-5); `handler_worker.py` consolidation (D4b-3 — deferred to PR-5 as `_ipc_common/`).

## Task quick reference

| # | Task | Feishu? | Depends |
|---|---|---|---|
| P4b-0 | PR-4b start notification | ✅ | — |
| P4b-1 | `_adapter_common/` shared helpers + workspace wiring | — | — |
| P4b-2 | `feishu_adapter_runner` sidecar + pytest | — | P4b-1 |
| P4b-3 | `cc_adapter_runner` sidecar + pytest | — | P4b-1 |
| P4b-4 | `generic_adapter_runner` catch-all + deprecation warning | ✅ milestone | P4b-1 |
| P4b-5 | Allowlist + dispatch negative tests | — | P4b-2..4 |
| P4b-6 | `esr.ipc.adapter_runner` → deprecation shim | — | P4b-5 |
| P4b-7 | `WorkerSupervisor.sidecar_module/1` dispatch table | ✅ milestone | P4b-6 |
| P4b-8 | Scripts + pgrep patterns update | — | P4b-7 |
| P4b-9 | Integration test: real feishu_adapter_runner spawn | — | P4b-8 |
| P4b-10 | Full regression run | ✅ milestone | P4b-9 |
| P4b-11 | Open PR-4b draft | ✅ PR open | P4b-10 |
| P4b-12 | Wait for user review + merge | ✅ merged | P4b-11 |
| P4b-13 | Write PR-4b snapshot | ✅ final | P4b-12 |

Feishu cadence: P4b-0 start + P4b-4 + P4b-7 + P4b-10 + P4b-11 PR + P4b-12 merged + P4b-13 snapshot = ≈7 notifications across 3 days (same cadence as PR-4a).

## Per-task steps (summary — full TDD cycles documented in-line during execution)

### P4b-1 — `_adapter_common/` shared helpers
- Create `py/src/_adapter_common/{__init__.py, runner_core.py, url.py, reconnect.py, main.py}` — lift `process_directive`, `directive_loop`, `event_loop`, `_watch_disconnect`, `run_with_client`, `run_with_reconnect`, `_resolve_url`, `run/_parse_main_args` out of monolith
- Add new `main.build_main(allowed_adapters=None, prog=...)` factory
- Migrate `py/tests/test_adapter_runner*.py` → `py/tests/adapter_runners/test_runner_core.py` with updated imports
- Run `uv --project py run pytest py/tests/adapter_runners/test_runner_core.py -x` — GREEN

### P4b-2 — `feishu_adapter_runner` sidecar
- `py/src/feishu_adapter_runner/{__init__.py, __main__.py, _allowlist.py}` — ~25 LoC glue
- `ALLOWED_ADAPTERS = frozenset({"feishu"})`
- `build_main(allowed_adapters=..., prog="feishu_adapter_runner")`
- `py/tests/adapter_runners/test_feishu_adapter_runner.py` — 3 tests (help exits clean, rejects wrong adapter, delegates to runner_core)

### P4b-3 — `cc_adapter_runner` sidecar
- Same shape as P4b-2
- `ALLOWED_ADAPTERS = frozenset({"cc_tmux", "cc_mcp"})`
- `prog="cc_adapter_runner"`
- Test: `--adapter cc_tmux` + `--adapter cc_mcp` accepted; `--adapter feishu` rejected

### P4b-4 — `generic_adapter_runner` catch-all
- `py/src/generic_adapter_runner/{__init__.py, __main__.py}`
- Prints `DeprecationWarning: generic_adapter_runner is a migration fallback; add --adapter <name> to a dedicated sidecar's allowlist.` on stderr at startup
- `build_main(allowed_adapters=None, ...)` short-circuits allowlist
- 3 pytest cases

### P4b-5 — Allowlist parametrised test
- `py/tests/adapter_runners/test_dispatch_allowlist.py` — 10 parametrised cases covering all 3 sidecars × relevant adapter combos
- Adds `--dry-run` flag to `build_main` for argv validation without socket open

### P4b-6 — deprecation shim for `esr.ipc.adapter_runner`
- Shrink the 399-line monolith to a 20-line shim that re-exports from `_adapter_common` + `warnings.warn(DeprecationWarning)`
- Filter the warning in tests that legitimately still import the shim (`test_ipc_reconnect.py`)

### P4b-7 — `Esr.WorkerSupervisor.sidecar_module/1`
```elixir
@sidecar_dispatch %{
  "feishu"  => "feishu_adapter_runner",
  "cc_tmux" => "cc_adapter_runner",
  "cc_mcp"  => "cc_adapter_runner"
}

def sidecar_module(name) when is_binary(name),
  do: Map.get(@sidecar_dispatch, name, "generic_adapter_runner")
```
- Update `spawn_python` argv: `["-m", sidecar_module(adapter_name), "--adapter", adapter_name, ...]`
- Update `log_path_for/1` pattern-match to accept new module names

### P4b-8 — Scripts update
- `scripts/spawn_scenario_workers.sh` — two `python -m esr.ipc.adapter_runner` invocations → per-type sidecars
- `scripts/kill_scenario_workers.sh:20`, `scripts/esrd.sh:125` — widen pgrep pattern to `'esr\.ipc\.(adapter_runner|handler_worker)|python -m (feishu|cc|generic)_adapter_runner'`
- `scripts/verify_entry_bodies.py:19` — list new `__main__.py` files

### P4b-9 — E2E integration test
- `runtime/test/esr/integration/adapter_runner_split_test.exs`
- `setup :isolated_tmux_socket` (hygiene — zero-cost even though this test doesn't spawn tmux)
- Spawns `feishu_adapter_runner` via `WorkerSupervisor.ensure_adapter/4`; asserts Phoenix channel join + directive_ack round-trip

### P4b-10 — Regression run
- `mix test` + `mix test --include integration` + `uv --project py run pytest py/tests/` + `mix compile --warnings-as-errors`
- Assert 0 `esr_*` tmux leaks (PR-4a hygiene)

### P4b-11..P4b-13 — PR lifecycle + snapshot
- `git push origin feature/peer-session-refactor`
- `gh pr create --draft --title "P4b: split adapter_runner.py into per-adapter-type sidecars"`
- Main agent admin-merges + writes `docs/superpowers/progress/2026-04-23-pr4b-snapshot.md`

## Commits include Co-Authored-By trailer

Every commit body ends with:
```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

## Drift findings (expansion-time)

- **D4b-1**: NO per-sidecar Elixir Peer wrappers. Adapter sidecars speak Phoenix channels (not stdin/stdout), so `PyProcess` macro doesn't apply. `WorkerSupervisor` dispatch table is the only Elixir change. Scope shrinks to 2-3 days (outline said 2-3 days ambiguously).
- **D4b-2**: Deprecation shim, not hard-delete. Callers survive; hard-delete moved to PR-5 cleanup scan.
- **D4b-3**: `handler_worker.py` consolidation into `_ipc_common/` deferred to PR-5 (3-line task description: move `_watch_disconnect` + `_resolve_url` to `_ipc_common/`, update handler_worker imports).

## Known unknowns

- `uv run --project py python -m feishu_adapter_runner` module discovery — mirror `voice_asr` pattern
- Integration test handshake timing — use PR-4a synthetic-injection if flaky
- Tmux isolation defensive setup in the new integration test even though no tmux spawns
