# esrd Worker Lifecycle Migration — Design

**Date**: 2026-04-30
**Author**: linyilun (via brainstorm with Claude Opus 4.7)
**Status**: design — subagent review pass 1 complete (2026-04-30); pending user sign-off
**Related**: PR-21m (`#96` cleanup_orphans), PR-21x (`#101` CapGuard)

## Background

On 2026-04-30 we observed eight live `feishu_adapter_runner` processes for the same Feishu app (`esr_helper`), each connected to Feishu Open Platform with shared credentials. A single inbound `/new-workspace default` produced eight bot replies — the FAA processed the inbound once (it broadcasts an outbound directive on `adapter:feishu/<instance_id>`), and all eight orphan adapters received the broadcast and called Feishu's `send_message` API.

### Why orphans accumulated

`Esr.WorkerSupervisor.spawn_python/1` calls `scripts/spawn_worker.sh`, which uses bash `&` + `disown` to detach the child from BEAM's process group. The bash `$!` captures the **`uv run` launcher's pid**, not the actual Python interpreter pid. Concrete evidence from the prod incident:

- Pidfile `/tmp/esr-worker-adapter-feishu-esr_helper.pid` contained `46509`
- `kill -0 46509` → process not found (uv exited after exec)
- `kill -0 46510` → alive (the python adapter, now parented to launchd via PPID=1)

Two independent bugs compounded:

1. **Pidfile records the wrong pid.** Records the wrapper, not the target.
2. **`cleanup_orphans` only scans pidfiles.** Each `ensure_adapter` overwrites the pidfile, so orphans whose pidfile was overwritten become permanently invisible. With launchd `KeepAlive=true`, every esrd respawn cycle accumulates one more orphan.

Why dev was unaffected: the dev launchd hadn't restarted since 22:14 yesterday. Multiple prod restarts (visible in `ps -ef` timestamps: 22:08, 23:46, 00:19, 00:31, 00:37, 08:30) accumulated 8.

### Why the design was originally this way

The `& disown` + pidfile + `cleanup_orphans` apparatus was justified post-hoc as "letting Python adapters survive BEAM restart so the Feishu lark_oapi long-poll WS doesn't reconnect." Audit shows:

- Test fixtures (`scripts/spawn_scenario_workers.sh`) pre-spawn workers externally for E2E scenarios; `WorkerSupervisor` was designed to *adopt* them via pidfile.
- The "survive BEAM restart" property is incidental, not load-bearing for any production behaviour. Feishu WS reconnect cost is ~5s of bot unavailability per esrd restart, which is rare and acceptable.
- A 5s reconnect blip is dramatically less harmful than the 8x duplicate-message symptom we just observed.

The design choice should be reversed.

## Goals

After this PR is shipped:

1. **BEAM owns 100% of subprocess lifecycle.** When BEAM dies (clean stop, SIGKILL, OOM), every Python adapter and handler it spawned dies before the next BEAM boot.
2. **Zero pidfiles, zero `cleanup_orphans`.** Orphan management apparatus deleted.
3. **Operator can't accidentally create rogue adapters.** Manual `uv run -m feishu_adapter_runner` is rejected by Python-side fail-fast guard.
4. **Stdout/stderr from workers is in esrd's main log.** Operators don't need to grep `/tmp/esr-worker-*.log`.
5. **Worker auto-restart on crash.** Currently absent (a worker crash leaves a permanent gap until the next `ensure_adapter` call); after migration, erlexec exit notification triggers limited-rate respawn.

## Non-goals

- `/new-session` tmux + CC lifecycle (already on erlexec via `Esr.OSProcess`/`Esr.Peers.TmuxProcess`/`Esr.Peers.CCProcess`)
- launchd plist redesign (KeepAlive vs OnDemand) — separate question
- E2E coverage gap audit for "1 inbound → N replies" assertions — task #222
- Structured error/notification response system — task #220
- Slash command yaml unification — task #221

## Architecture changes

### Before

```
Esr.Application
└── WorkerSupervisor (singleton GenServer)
    ├── state.workers = %{key => %{pid: 46509, pidfile: "/tmp/...pid", url: "..."}}
    ├── spawn → scripts/spawn_worker.sh → bash & disown → uv run python -m ...
    │   ├── /tmp/esr-worker-<slug>.pid     ← out-of-sync with reality
    │   └── /tmp/esr-worker-<slug>.log     ← grep target for diagnosis
    └── cleanup_orphans (boot + on-demand)
        └── pidfile-only scan (misses overwritten orphans)
```

### After

```
Esr.Application
└── WorkerSupervisor (DynamicSupervisor)
    └── for each (adapter|handler) key:
        Esr.AdapterProcess / Esr.HandlerProcess
        (use Esr.OSProcess, wrapper: :plain)
        ├── erlexec port — direct python (NOT uv run)
        ├── os_env: ESR_SPAWN_TOKEN + PYTHONUNBUFFERED=1
        ├── stdout/stderr: forwarded to Logger
        └── on_os_exit: limited-rate respawn or escalate
```

`WorkerSupervisor` becomes a thin `DynamicSupervisor` plus a small in-memory map keyed by `{:adapter, name, instance_id}` / `{:handler, module, worker_id}` for `ensure_*/3` idempotency. No file state. State dies with BEAM.

### Two new peer modules

`Esr.AdapterProcess` and `Esr.HandlerProcess` both `use Esr.OSProcess, wrapper: :plain`. The split exists because adapters take `--adapter`, `--instance-id`, `--url`, `--config-json` while handlers take `--module`, `--worker-id`, `--url`. The two modules differ only in their `os_cmd/1` implementation.

Both share:

- `os_env/1` — injects `ESR_SPAWN_TOKEN` + `PYTHONUNBUFFERED=1`
- `os_cwd/1` — returns the repo's `py/` directory (mirrors `Esr.PyProcess.os_cwd/1`); needed so `python -m <module>` resolves the package
- `handle_upstream({:os_stdout, line}, state)` — forwards to `Logger.info("[#{key_label(state)}] #{line}")`
- `handle_upstream({:os_stderr, line}, state)` — forwards to `Logger.warning(...)`
- `on_os_exit/2` — exit-status-aware policy (see below)

### `ESR_SPAWN_TOKEN` design

**Generation**: in `Esr.Application.start/2`, generate a random per-boot token **before `Supervisor.start_link/2`** so any worker spawned inside the supervision tree finds the token in `Application.get_env/2`:

```elixir
def start(_type, _args) do
  apply_tmux_socket_env()

  token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  Application.put_env(:esr, :spawn_token, token)

  children = [...]
  Supervisor.start_link(children, opts)
end
```

**Injection**: `Esr.AdapterProcess.os_env/1` and `Esr.HandlerProcess.os_env/1` read from the app env:

```elixir
[{"ESR_SPAWN_TOKEN", Application.get_env(:esr, :spawn_token)},
 {"PYTHONUNBUFFERED", "1"}]
```

**Python guard** (in each of the four entry-point `__main__` blocks: `feishu_adapter_runner`, `cc_adapter_runner`, `generic_adapter_runner`, `handler_worker`):

```python
import os, sys

token = os.environ.get("ESR_SPAWN_TOKEN")
if not token:
    sys.stderr.write(
        "feishu_adapter_runner: must be spawned by esrd via erlexec; "
        "manual `uv run` invocation is unsupported (would create orphan "
        "adapter competing for Feishu app credentials).\n"
        "To debug locally:\n"
        "  esr daemon stop\n"
        "  ESR_SPAWN_TOKEN=__debug__ uv run --project py python -m "
        "feishu_adapter_runner ...\n"
    )
    sys.exit(2)
```

`__debug__` literal is a debug escape hatch, not a real token. The guard is a fail-fast safety check, not a security boundary — if a malicious caller can read `ps aux` they have other access.

### Stdout / stderr routing

erlexec `:stdout` / `:stderr` options accept a pid that receives `{:stderr, exec_pid, line}` / `{:stdout, exec_pid, line}` messages. `Esr.OSProcess` already wires these into `handle_upstream({:os_stdout, line}, state)` / `handle_upstream({:os_stderr, line}, state)` callbacks. Each new peer module forwards to `Logger`:

```
[info] [worker {:adapter, "feishu", "esr_helper"}] heartbeat ok
[warning] [worker {:adapter, "feishu", "esr_helper"}] reconnect attempt 2
```

Operators get a single coherent log file (`launchd-stdout.log` for prod / dev) instead of N `/tmp/esr-worker-*.log` files.

### Shutdown timing

| Trigger | Behaviour |
|---|---|
| Normal stop (`Application.stop(:esr)`) | Supervisor stops top-down → `WorkerSupervisor` stops children → each `*Process` runs `terminate/2` → `:exec.stop/1` (SIGTERM, then SIGKILL after `kill_timeout`). All children dead before BEAM exits. |
| BEAM hard crash | erlexec port program detects parent disconnect via socket close → SIGKILL all tracked children. Independent of esrd's clean shutdown. |
| `launchctl bootout` | launchd SIGTERM → BEAM sigterm handler → `Application.stop` → same as normal stop. |
| `launchctl kickstart -k` | launchd SIGTERM existing BEAM, waits for exit (clean stop path), spawns new BEAM. New BEAM spawns fresh workers. ~5s of Feishu WS reconnect. |
| Manual `kill -9 <esrd_pid>` | Same as BEAM hard crash. erlexec C++ port handles cleanup. |

The boot path no longer needs orphan scanning, because the previous shutdown (whichever path) already cleaned up.

### Worker exit policy

**Important — pinned by spec review (2026-04-30)**: `Esr.OSProcess.handle_info` currently returns `{:stop, :restart_not_yet_implemented, s}` from both `:DOWN` and `:EXIT` branches (`runtime/lib/esr/os_process.ex:189–203`). The `{:restart, _}` return value from `on_os_exit/2` is not yet honoured. Two clean options:

- **(a) Extend `Esr.OSProcess`** to actually re-spawn on `{:restart, new_state}` from `on_os_exit/2`. Adds new contract surface; requires careful state-reset semantics.
- **(b) Lean on `DynamicSupervisor`'s built-in restart policy**. Each `*Process` child is `:transient` (restarts only on abnormal exit) under the `WorkerSupervisor` DynamicSupervisor, which carries `max_restarts: 3, max_seconds: 60`. `on_os_exit/2` always returns `{:stop, :normal}` for status=0 and `{:stop, {:py_crashed, status}}` otherwise — same as `Esr.PyProcess` does today. The supervisor handles respawn; budget exceeded → supervisor dies → cascades to esrd shutdown → launchd respawns the whole tree.

We pick **(b)** — simpler, no behaviour change to `Esr.OSProcess`, leverages OTP semantics correctly. The escalation path (cascade to launchd) is acceptable because budget exhaustion (4 crashes in 60s) indicates a systemic problem that a fresh BEAM is more likely to resolve than further per-worker thrashing.

```elixir
# In AdapterProcess/HandlerProcess
@impl Esr.OSProcess
def on_os_exit(0, _state), do: {:stop, :normal}
def on_os_exit(status, _state), do: {:stop, {:py_crashed, status}}
```

Net improvement over today's `spawn_worker.sh` path which has zero respawn behaviour.

## Failure modes & risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| erlexec port startup overhead (~50ms) | low | imperceptible vs Phoenix's 3s boot | accepted |
| erlexec port program crashes | extremely rare | all children orphan briefly | monitor port via `Process.monitor`; on `:DOWN` log and `Application.stop(:esr)` to let launchd respawn full tree |
| Python adapter slow to start (~3s) | medium | bot offline ~5s after esrd restart | accepted; launchd `ThrottleInterval=10` prevents storms |
| Python stdout buffering | medium | log delay, hard to diagnose | `PYTHONUNBUFFERED=1` set in `os_env` |
| Token leak via `ps aux` | low | no privilege gained | accepted; token is fail-fast not security |
| `uv run` interaction with erlexec | medium | could repeat today's wrong-pid bug | bypass uv: invoke `<repo>/py/.venv/bin/python -m <module>` directly. erlexec then manages the actual python pid. |
| Mid-message SIGTERM | medium | outbound Feishu API call lost | `:kill_timeout` → 10s grace; Python adapter's `signal.SIGTERM` handler flushes outbound queue, closes WS |
| Multi-esrd (prod + dev) collision | low | none — different ESRD_HOME / port / token | unchanged |

## Edge cases

1. **`scripts/spawn_scenario_workers.sh` is invalidated.** Search shows it's only referenced by `tests/e2e/` mock scenarios. Either delete (let esrd's `restore_adapters_from_disk` boot path spawn naturally) or refactor scenarios to drive spawn via `cli:adapter/ensure` (similar to other admin commands). Recommend **delete**; the boot path becomes the single spawn entry point.

2. **`/tmp/esr-worker-*.pid` and `*.log` residue.** Migration leaves these files on disk. One-shot cleanup at the migration commit's first boot: `Esr.Application.start/2` removes any matching files (idempotent). Subsequent boots find nothing; the call becomes a no-op.

3. **`esr daemon doctor --cleanup-orphans` flag.** No longer meaningful. Flag removed. Underlying `cli:daemon/cleanup_orphans` topic also removed. `esr daemon doctor` (no flag) keeps working but `workers_tracked` field semantics change from "pidfile entries" to "live erlexec-managed peers" (more accurate).

4. **Local debugging path.** Operator wants to run an adapter manually to test a lark_oapi call:
   ```
   ESR_SPAWN_TOKEN=__debug__ uv run --project py python -m feishu_adapter_runner ...
   ```
   The debug literal is documented in the guard's error message itself.

5. **erlexec dependency**. Already in `mix.exs` (used by `Esr.OSProcess`/`Esr.PyProcess`/`Esr.Peers.TmuxProcess`). No new dep.

## Death-list

```
Code:
  scripts/spawn_worker.sh                                     [DELETE]
  runtime/lib/esr/worker_supervisor.ex                        [REWRITE]
    - @pidfile_dir
    - defp pidfile_path/1, read_pidfile/1
    - defp external_alive_for_url?/2, external_alive_any_url?/1
    - defp record_external/3
    - defp tracked_alive_for_url?/3, tracked_alive?/2
    - defp ensure (cond chain → simple case via DynamicSupervisor)
    - handle_call(:cleanup_orphans, _, _)
    - public cleanup_orphans/0
    - defp pid_alive?/1, kill_pid/1
    - defp spawn_python/1 (replaced by AdapterProcess/HandlerProcess spawn)
    - defp log_path_for/1
    - terminate/2 SIGTERM loop (DynamicSupervisor handles it)
  runtime/lib/esr/application.ex                              [EDIT]
    - try/catch block calling cleanup_orphans deleted
    - one-shot tmp cleanup of /tmp/esr-worker-* added
  py/src/feishu_adapter_runner/__main__.py                    [GUARD]
  py/src/cc_adapter_runner/__main__.py                        [GUARD]
  py/src/generic_adapter_runner/__main__.py                   [GUARD]
  py/src/esr/ipc/handler_worker.py (__main__ block)           [GUARD]
  py/src/esr/cli/daemon.py                                    [EDIT]
    - daemon_doctor: remove --cleanup-orphans flag
  runtime/lib/esr_web/cli_channel.ex                          [EDIT]
    - cli:daemon/cleanup_orphans dispatch removed

New code:
  runtime/lib/esr/peers/adapter_process.ex                    [NEW ~80 LOC]
  runtime/lib/esr/peers/handler_process.ex                    [NEW ~80 LOC]

Tests:
  runtime/test/esr/worker_supervisor_test.exs                 [REWRITE]
  runtime/test/esr/peers/adapter_process_test.exs             [NEW]
  runtime/test/esr/peers/handler_process_test.exs             [NEW]
  py/tests/test_spawn_token_guard.py                          [NEW]
  scripts/spawn_scenario_workers.sh                           [DELETE]
  tests/e2e/scenarios/<scenarios using above>                 [EDIT]

Docs:
  docs/operations/esrd-orphan-cleanup.md (if exists)          [DELETE]
  docs/cli-reference.md                                       [REGEN via gen-docs.sh]
  docs/runtime-channel-reference.md                           [REGEN]
```

## Testing strategy

| Layer | Case | File |
|---|---|---|
| Unit (Elixir) | `WorkerSupervisor.ensure_adapter/4` idempotent — 5 calls = 1 child | `worker_supervisor_test.exs` (rewritten) |
| Unit (Elixir) | spawn → `Application.stop(:esr)` → child OS pid not in `kill -0` list | `worker_supervisor_test.exs` |
| Unit (Elixir) | `AdapterProcess.on_os_exit/2` respawn budget: 4th crash within 60s = `:stop` | `adapter_process_test.exs` |
| Unit (Python) | token absent → exit 2 + stderr mentions "esrd" "erlexec" | `test_spawn_token_guard.py` |
| Unit (Python) | `ESR_SPAWN_TOKEN=__debug__` → continues past guard | `test_spawn_token_guard.py` |
| Integration | spawn → `Process.exit(beam, :kill)` simulated → erlexec C++ kills child | `worker_supervisor_test.exs` |
| E2E | New scenario `tests/e2e/scenarios/0X_no_duplicate_replies.sh`: send 1 inbound, count `directive_ack` in adapter log = 1 | new file (overlap with task #222) |
| Smoke | `bash scripts/esrd.sh start && sleep 3 && pgrep -af 'feishu_adapter_runner.*esr_helper'` returns 1 line. Then `launchctl kickstart -k com.ezagent.esrd && sleep 5 && pgrep ...` still returns 1 line. | manual checklist in PR description |

## Rollout (commit-by-commit)

1. **Commit 1** — `Esr.AdapterProcess` + `Esr.HandlerProcess` modules (new code, no callers yet)
2. **Commit 2** — `WorkerSupervisor` gains erlexec spawn path behind feature flag `:esr_use_erlexec_workers`. Old path still default.
3. **Commit 3** — Python entry-point token guards (4 files, ~5 LOC each).
4. **Commit 4** — Flip flag default to `true`. Add tmp/* one-shot cleanup at boot. Verify locally.
5. **Commit 5** — Delete `spawn_worker.sh`, pidfile machinery, `cleanup_orphans` API, feature flag. Boot smoke + E2E.
6. **Commit 6** — Delete `spawn_scenario_workers.sh` and update E2E scenarios.
7. **Commit 7** — `esr daemon doctor --cleanup-orphans` flag removal + cli:daemon/cleanup_orphans topic removal + regen `docs/cli-reference.md` + `docs/runtime-channel-reference.md`.

Commits 1–4 are additive (safe to revert); commits 5–7 are net-deletion (require commit 4 verification first). If the diff is too large, the natural cut is between commit 4 and commit 5 — two PRs.

## Open questions

1. **Should `AdapterProcess` and `HandlerProcess` live under `Esr.Peers.*`?** They aren't peers in the Esr.Peer sense (don't participate in the inbound/outbound chain), but they do compose `Esr.OSProcess`. Lean toward `Esr.Workers.AdapterProcess` / `Esr.Workers.HandlerProcess` (new namespace) so reviewers don't confuse them with FAA/FCP-style peers.

2. **What's the erlexec `:kill_timeout` value?** Default 5s. For Feishu adapters mid-WS-call, 10s gives more grace but also slows clean shutdown. Recommend 10s for adapters, 5s for handlers.

3. **Should `WorkerSupervisor` itself become `Esr.Workers.Supervisor`?** Spec review verified ~13 non-test call sites: `cli_channel.ex` (7 references including the 5 now-deleted ones), `register_adapter.ex` (3), `application.ex` (3). After deletions in commits 5–7 land, only ~6 remain. **Recommend deferring the rename to a follow-up PR** — keeps this PR focused on lifecycle correctness; rename PR is then a pure mechanical sed-style change against a smaller surface.

4. **Need an `exec_pid/1` accessor on `Esr.OSProcess`-generated worker?** `os_pid/1` exists today (returns OS pid). The new respawn-via-DynamicSupervisor design doesn't need exec_pid externally, but the AdapterProcess/HandlerProcess test suites likely will (e.g. to assert "this exec port is dead after BEAM stop"). Add `exec_pid/1` accessor in commit 1 — small change, mirrors the existing `os_pid/1` shape.
