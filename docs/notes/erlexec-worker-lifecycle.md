# erlexec worker lifecycle (PR-21β)

**Filed**: 2026-04-30
**Spec**: [`docs/superpowers/specs/2026-04-30-esrd-worker-lifecycle-design.md`](../superpowers/specs/2026-04-30-esrd-worker-lifecycle-design.md)
**Plan**: [`docs/superpowers/plans/2026-04-30-esrd-worker-lifecycle-plan.md`](../superpowers/plans/2026-04-30-esrd-worker-lifecycle-plan.md)

## What changed

`Esr.WorkerSupervisor` migrated from a `bash & disown` + pidfile + `cleanup_orphans` model to a `:erlexec`-managed `DynamicSupervisor` of `Esr.Workers.{AdapterProcess,HandlerProcess}` peer children. BEAM owns 100% of subprocess lifecycle; orphan accumulation is now structurally impossible.

## The 8x-orphan incident

Symptom (2026-04-30 morning): `/new-workspace default` from operator yielded **8 identical `error: unauthorized` replies** in Feishu. Investigation found 8 live `feishu_adapter_runner` processes for the same prod app `esr_helper`, accumulated over ~10 hours of launchd kickstarts.

Root cause was two compounding bugs:

1. **`spawn_worker.sh` recorded the wrong pid.** Bash `$!` after `& uv run python -m ...` captures the `uv` launcher's pid. `uv` exec's into python (or forks + exits) leaving the python interpreter at a different pid. The pidfile pointed to the dead uv pid; the real adapter (now reparented to launchd via PPID=1) was invisible to all kill / scan logic.
2. **`cleanup_orphans` only scanned pidfiles.** Each `ensure_adapter` overwrote the pidfile with the new (still-wrong) pid. Previous orphans whose pidfile entry got overwritten became permanently invisible. `launchctl kickstart -k` cycled the BEAM but not the children — every cycle accumulated one orphan.

When the operator sent one inbound, the FAA processed it once and broadcast one outbound directive on `adapter:feishu/esr_helper`. All 8 adapters subscribed to that topic, all 8 called Feishu's `send_message` API, all 8 produced a different `directive_ack` — visible in the prod log as 8 separate Feishu message IDs for one logical reply.

## Why the original design existed

Post-hoc rationale was "let adapters survive BEAM restart so the Feishu lark_oapi long-poll WS doesn't reconnect." Real reason was simpler: the early E2E fixtures (`scripts/spawn_scenario_workers.sh`) pre-spawned workers externally, and `WorkerSupervisor` was designed to *adopt* them via pidfile lookup. The "survive BEAM restart" property was never load-bearing for any production behaviour — Feishu WS reconnect cost is ~5s of bot unavailability, dramatically less harmful than 8x duplicates.

## What's different now

- **No pidfile.** State lives in a single in-memory `%{key => beam_pid}` map.
- **No `cleanup_orphans`.** When the previous BEAM exited (clean stop, crash, or `kill -9`), erlexec's C++ port program SIGKILLs all children. Boot starts from a clean slate; nothing to scan.
- **No `bash & disown`.** Workers run as direct children of erlexec, which lives inside BEAM's process tree. `Process.exit/2` cascades correctly.
- **`uv run` bypassed.** `Esr.Workers.AdapterProcess.os_cmd/1` invokes `<repo>/py/.venv/bin/python -m <module>` directly. erlexec tracks the python pid, not a wrapper.
- **`ESR_SPAWN_TOKEN` per-boot guard.** Generated in `Esr.Application.start/2` before `Supervisor.start_link/2`, injected via `os_env/1`. Python `__main__` blocks refuse to start without it. Manual `uv run -m feishu_adapter_runner` exits 2. `__debug__` literal is the documented escape for local debugging.
- **Worker stdout/stderr → main log.** AdapterProcess / HandlerProcess `handle_upstream({:os_stdout, line}, _)` forwards to `Logger.info("[adapter feishu/esr_helper] …")`. Operators get one coherent log instead of N `/tmp/esr-worker-*.log` files.
- **Worker auto-restart on crash.** `Esr.Workers.*Process` children run `:transient` under a DynamicSupervisor with `max_restarts: 3, max_seconds: 60`. Budget-exhausted = supervisor dies = launchd respawns the whole tree.

## Behaviour cost

Every `launchctl kickstart -k` (and every BEAM crash) now drops Feishu WS for ~5s while the new BEAM boots and respawns the adapter. In practice this is invisible to operators — bot replies are generally request/response, no streaming sessions to interrupt. If this becomes a real concern in the future, the right fix is reducing BEAM cold-start time (Mix release, hot code reload), not bypassing erlexec.

## File audit

After PR-21β, `grep -rn 'spawn_worker\|cleanup_orphans\|esr-worker.*\.pid'` in `runtime/lib`, `runtime/test`, `py/src`, `scripts/`, `scenarios/`, `tests/e2e/` should return only this file and the spec/plan it links to.

## Related notes

- [`erlexec-migration.md`](erlexec-migration.md) — the original 2026-04-22 migration to `:erlexec` for tmux + CC. PR-21β extends the same pattern to adapter / handler workers.
- [`actor-role-vocabulary.md`](actor-role-vocabulary.md) — `Esr.Workers.{AdapterProcess,HandlerProcess}` are `*Process` boundary peers per the canonical taxonomy.
