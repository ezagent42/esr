# Future: MuonTrap-based Worker Supervisor

Status: **not started** — follow-up to [issue #7](https://github.com/ezagent42/esr/issues/7).
Author: brainstorming session with user (linyilun), 2026-04-21.
Relates to:
- GitHub issue #7 — YAML 声明式状态 vs 运行时对账 / Python orphan workers
- `runtime/lib/esr/worker_supervisor.ex` — introduced in Phase 8f (commit `f43baff`, 2026-04-20)
- `docs/superpowers/specs/2026-04-21-esr-dev-prod-isolation-design.md` — in-progress branch whose `Commands.RegisterAdapter` routes through today's `ensure_*` API

## Why this document exists

Issue #7 catalogs four drift scenarios where Python worker subprocesses become orphans — live processes with no corresponding entry in `adapters.yaml` or `Esr.Topology.Registry`. The reporter's framing ("YAML as declarative source of truth vs runtime reconciliation") suggests adding a periodic `ReconcileLoop` that diffs declared vs actual state.

Triage rejected that framing. The problem is not that we lack reconciliation; it is that `Esr.WorkerSupervisor` half-owns the Python process lifecycle in a way that doesn't parse as OTP:

- Tracks OS PIDs in a GenServer memory map, not in an OTP supervisor tree
- Detaches children via `setsid` (`scripts/spawn_worker.sh`) so the OS parent-child signal chain is deliberately broken
- Public API is asymmetric: `ensure_adapter/4` + `ensure_handler/3` for creation, no `stop_*` counterpart
- Deactivation paths (`Registry.deactivate/1`, `Instantiator.rollback_spawned/2`, `restore_adapters_from_disk/2`) don't call it

Both the OTP monitoring chain and the deactivation wiring chain are broken. A `ReconcileLoop` would be periodic after-the-fact cleanup at the wrong layer.

The origin of the current shape is captured plainly in the Phase 8f commit message (`f43baff`):

> final_gate.sh --live is SHA-pinned and cannot run a setup step analogous to scripts/spawn_scenario_workers.sh. **This commit makes the runtime launch them itself.**

A test-engineering shortcut, not an architectural decision. The name `ensure_*` was only meant to express idempotent creation; the subsequent private `kill_pid/1`, state map, and pidfile management drifted the behavior toward ownership without updating the naming or the supervision semantics to match.

The correct fix is to delegate physical process supervision to OTP proper: wrap each `uv run python …` invocation in `MuonTrap.Daemon` under a `DynamicSupervisor`. This converts each Python subprocess into a genuine OTP child — observable via `Process.monitor`, terminated via `DynamicSupervisor.terminate_child/2`, automatically reaped when the BEAM exits (via `prctl(PR_SET_PDEATHSIG)` on Linux, `kqueue` on macOS).

## Scope

**In scope:**

- Replace `Esr.WorkerSupervisor` internals with a `DynamicSupervisor` whose children are `MuonTrap.Daemon` specs
- Rename public API from `ensure_adapter/4` / `ensure_handler/3` to OTP-standard `start_adapter/4` / `stop_adapter/2` / `start_handler/3` / `stop_handler/2`
- Wire `Registry.deactivate/1` and `Instantiator.rollback_spawned/2` to call the new `stop_*`
- Add `AdapterSocket.connect/3` authorization (closes TC4): reject registrations whose `(adapter, instance)` is not in the current declaration set
- Retire `scripts/spawn_worker.sh`, the `setsid` detachment, the private `kill_pid/1`, and the `/tmp/esr-worker-*.pid` probe mechanism
- Update `scripts/spawn_scenario_workers.sh` (E2E fixture) to use the public supervisor API instead of racing on pidfiles

**Out of scope:**

- Migrating handlers to Pythonx NIF embedding (evaluated and rejected — see §"Why not Pythonx")
- Adding a Python-side reverse-observation protocol (evaluated and rejected — see §"Why not a Python-side reverse-observation protocol")
- Adding a `ReconcileLoop` GenServer (unnecessary once OTP owns termination)
- Moving adapter spawn to launchd / systemd at the OS level (separate concern; `feature/dev-prod-isolation` already delegates `esrd` itself to launchd; adapters stay under OTP)

## How issue #7's four testcases close

| TC | Today's behavior | Under MuonTrap + AdapterSocket authz |
|---|---|---|
| 1. `esr cmd stop` leaves Python running | `Registry.deactivate/1` stops only the Elixir PeerServer | `Registry.deactivate/1` also calls `stop_adapter/2`; `DynamicSupervisor.terminate_child/2` issues SIGTERM→SIGKILL with configurable grace (`delay_to_sigkill`) |
| 2. Rollback on partial instantiation leaves Python running | `Instantiator.rollback_spawned/2` unwinds only Elixir side | Calls `stop_*` for every previously-started `Daemon`; OTP makes cleanup synchronous |
| 3. YAML edit removes an entry; esrd restart leaves old Python | `restore_adapters_from_disk/2` only starts what YAML declares | Same logic, but the old `Daemon` no longer exists at restart — BEAM death already killed its child via `PR_SET_PDEATHSIG` / `kqueue` at the kernel level |
| 4. Manually-started Python worker registers as unauthorized adapter | `AdapterSocket.connect/3` has no authz | Authz check against current declaration set; unknown `(adapter, instance)` rejected at the `connect/3` callback |

All four close. No `ReconcileLoop` required.

## Proposed shape

### API surface

```elixir
# runtime/lib/esr/worker_supervisor.ex (after migration)

@spec start_adapter(String.t(), String.t(), map() | String.t(), String.t()) ::
        {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}
def start_adapter(adapter_name, instance_id, config, url)

@spec stop_adapter(String.t(), String.t()) :: :ok | {:error, :not_found}
def stop_adapter(adapter_name, instance_id)

@spec start_handler(String.t(), String.t(), String.t()) ::
        {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}
def start_handler(handler_module, worker_id, url)

@spec stop_handler(String.t(), String.t()) :: :ok | {:error, :not_found}
def stop_handler(handler_module, worker_id)

@spec list() :: [{:adapter | :handler, String.t(), String.t(), erlang_pid :: pid(), os_pid :: integer()}]
def list()
```

Changes vs today:

- Returns the Erlang pid of the `MuonTrap.Daemon` GenServer (usable for `Process.monitor`), not just `:ok`
- `stop_*` becomes first-class
- `list/0` returns both the Erlang pid (for BEAM-level observation) and the OS pid (for operator `ps` / `kill` visibility)
- The `:already_running` return disappears; idempotency becomes the standard OTP `{:error, {:already_started, pid}}` convention

### Internal shape

```elixir
defmodule Esr.WorkerSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_adapter(name, id, config, url) do
    spec = %{
      id: {:adapter, name, id},
      start: {MuonTrap.Daemon, :start_link, [
        "uv",
        ["run", "--project", "py", "python",
         "-m", "esr.ipc.adapter_runner",
         "--adapter", name,
         "--instance-id", id,
         "--url", url,
         "--config-json", normalise_config(config)],
        [cd: repo_root(),
         name: via_tuple({:adapter, name, id}),
         exit_status_to_reason: true,
         stderr_to_stdout: true,
         log_output: :info]
      ]},
      restart: :temporary,
      shutdown: 5_000
    }
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  # analogous start_handler/3, stop_adapter/2, stop_handler/2, list/0
end
```

Retires (deleted in the same PR):

- `scripts/spawn_worker.sh` — the `setsid` wrapper
- Private `kill_pid/1` with manual SIGTERM→SIGKILL bookkeeping
- `state.workers` map and all `handle_info({:EXIT, _port, _}, state)` noise
- `/tmp/esr-worker-*.pid` probe logic (`external_alive?/1`, `record_external/3`)

Restart strategy is deliberately `:temporary`: the declarative system (YAML + Admin commands) decides whether to restart a dead worker, not OTP's auto-restart. This preserves the semantic that `stop_adapter/2` means "kill for real, don't resurrect."

### Call-site changes

- `runtime/lib/esr/topology/registry.ex` (`deactivate/1`, around lines 89-105): after stopping each peer, look up its `(adapter, instance)` or `(handler, worker_id)` binding and call the corresponding `Esr.WorkerSupervisor.stop_*/2`
- `runtime/lib/esr/topology/instantiator.ex` (`rollback_spawned/2`, around lines 338-350): after `PeerSupervisor.stop_peer`, call `stop_*` for the Python worker that was spawned in the same spawn-loop iteration
- `runtime/lib/esr/application.ex` (`restore_adapters_from_disk/2`, around lines 101-137): logic unchanged — OTP supervision makes "stale `Daemon` at restart" impossible by construction

### AdapterSocket authz (TC4)

```elixir
# runtime/lib/esr_web/adapter_socket.ex
def connect(%{"adapter" => name, "instance" => id} = params, socket, _info) do
  case Esr.Admin.AdapterAuthz.verify(name, id, params) do
    :ok ->
      {:ok, assign(socket, :adapter_binding, {name, id})}

    {:error, _reason} ->
      :error
  end
end
```

Authz mechanism for v1 (single-host) leans toward "declaration-set membership is sufficient proof" — `AdapterAuthz.verify/3` checks that `(name, id)` is present in the current `Esr.Topology.Registry` / `adapters.yaml` snapshot, and trusts that the WS socket + YAML are already gatekept by OS file permissions. A shared-secret token mechanism is available as a later hardening step but not needed for v1.

## Why not erlexec

[saleyn/erlexec](https://github.com/saleyn/erlexec) is a mature, feature-rich alternative (battle-tested in finance and telecom Erlang systems for 15+ years). It is strictly more capable than MuonTrap on several axes: run-as-user (setuid/setgid), cross-platform `setrlimit` resource caps, PTY allocation, bidirectional stdin streaming, and explicit process-group kill semantics. It was evaluated and rejected for ESR's v1 needs.

Comparison on axes relevant to ESR:

| Axis | MuonTrap | erlexec | ESR need |
|---|---|---|---|
| Kill on BEAM exit | `PR_SET_PDEATHSIG` (Linux) / `kqueue` (BSD/macOS), kernel-level | `exec-port` watchdog process monitors BEAM and kills children | both sufficient |
| Process-group kill (uv→python fork chain) | default (new session group per daemon) | explicit `kill_group` option | MuonTrap zero-config |
| OTP supervisor integration | `MuonTrap.Daemon` is a GenServer, drops directly into `DynamicSupervisor` | can be used but runs its own supervision model in parallel with OTP | MuonTrap cleaner |
| Elixir API ergonomics | Elixir-native, idiomatic | Erlang API, usable from Elixir but feels like borrowed clothing | MuonTrap cleaner |
| Dependency weight | one C helper + small Elixir module | C++ port program + Erlang modules + parallel supervision model | MuonTrap lighter |
| Resource limits (cgroups/rlimit) | cgroups, **Linux only** | `setrlimit`, **cross-platform** | not needed v1 |
| Run as different OS user | not supported | first-class | not needed v1 |
| PTY allocation | not supported | first-class | **NOT needed by the subprocess wrapper** — see below |
| Dynamic stdin writes | limited (fixed at spawn time) | full `exec:send/2` bidirectional | not needed (WebSocket handles all runtime I/O) |

### About the PTY question specifically

ESR does have a PTY somewhere in its stack — CC TUI runs inside tmux — but the PTY lives at a different layer than the subprocess wrapper we are choosing. Evidence from `adapters/cc_tmux/src/esr_cc_tmux/adapter.py`:

- `tmux new-session -d -s <name> <cmd>` (line 117) is invoked via `subprocess.run(argv, capture_output=True, text=True)` — the `-d` flag is **detached mode**, which does not require the invoker to have a TTY. The tmux server internally calls `forkpty()` to allocate a PTY for CC.
- `tmux send-keys`, `tmux capture-pane -p`, and `tmux kill-session` are all headless tmux CLI commands that operate on the running tmux server via its control socket. None require a TTY on the invoker.

Layer diagram:

```
MuonTrap.Daemon → uv run python -m esr.ipc.adapter_runner    ← plain process, no PTY
                    ↓ internal subprocess.run
                  tmux new-session -d / send-keys / capture-pane  ← plain CLI commands, no PTY
                    ↓ tmux server internally
                  forkpty() + exec(claude)                   ← PTY lives here, owned by tmux
```

tmux is a purpose-built PTY multiplexer. It already handles the PTY layer better than any subprocess wrapper could (persistent sessions, detached by default, `capture-pane` for polling output, `send-keys` for input injection — all battle-tested semantics). Neither MuonTrap nor erlexec ever sees a PTY; this axis does not differentiate them.

### When the erlexec choice should be revisited

The following triggers — none present in current ESR roadmap — would flip the evaluation toward erlexec:

1. **Multi-tenant adapter deployment** where different adapters must run under different OS users for permission isolation (e.g., Feishu adapter as `esr-feishu`, CC-MCP adapter as `esr-cc`). erlexec's `{user, "..."}` option is a one-line config; MuonTrap would require wrapping with `sudo -u` and accepting the ergonomic cost.
2. **Cross-platform resource limits** in production (per-adapter CPU or memory caps enforced on both macOS dev machines and Linux servers). MuonTrap's cgroups support is Linux-only; erlexec's `setrlimit` works on both.
3. **Third-party adapter ecosystem** where adapters are written and distributed by external developers. setuid + rlimit + finer I/O isolation become real security requirements, not optional features.
4. **Architectural shift away from tmux delegation** to ESR directly spawning TUI applications while holding their PTY (e.g., running `claude` under direct ESR supervision without tmux in the middle). erlexec's PTY allocation would become directly relevant.

For the current ESR architecture (single-host, single-OS-user, internal-only adapters, tmux-delegated TUI hosting), erlexec is strictly more power than we use. Unused capability becomes maintenance burden ("why does this code path use erlexec's supervision while that one uses `DynamicSupervisor`?"). MuonTrap's smaller surface matches our needs without leaving dead feature weight.

**Decision: MuonTrap for v1. Re-evaluate when any of the four triggers above becomes real.**

## Why not Pythonx

Evaluated during brainstorming. [livebook-dev/pythonx](https://github.com/livebook-dev/pythonx) embeds CPython into the BEAM process via NIF (`Py_Initialize` / `PyRun_SimpleString`). Three disqualifiers for ESR:

1. **Crash isolation lost.** Any C extension segfault in `aiohttp`, `lark_oapi`, numpy, or similar takes down the entire BEAM. Today's isolation boundary ("Python dies → supervisor restarts") becomes "Python dies → whole esrd dies". This is strictly worse than any subprocess-based model.

2. **GIL serializes everything.** All Python calls route through a single GIL in a single Python interpreter. A long-running adapter event loop (e.g., a Feishu websocket connection) monopolizes the GIL, blocking every other Python call across the system. Multi-adapter deployments would deadlock.

3. **Wrong design target.** Pythonx is optimized for "call function, get value back" — the Livebook compute-cell use case. It is not built for persistent `asyncio` event loops holding remote websockets.

For handlers specifically (model (a) — pure function pool), Pythonx *would* be a better fit in isolation. But under MuonTrap the remaining IPC overhead is local WebSocket frames (sub-ms), and ESR handler latency is dominated by business logic (10-50ms). The theoretical µs savings do not justify a dual architecture or the loss of crash isolation.

**Decision: do not build handler-on-Pythonx. Do not keep it as a "future option."**

## Why not a Python-side reverse-observation protocol

Considered during brainstorming. Would be required under an alternative architecture where Python processes are spawned externally (launchd / systemd / operator-managed) and the Elixir side only tracks registrations passively. Under that model, each Python adapter needs to self-check "am I still declared?" and exit when orphaned — effectively pushing v0.2-channel §6.6b's 30-second MCP self-destruct from a CC-only mechanism to a universal SDK contract.

Under MuonTrap this protocol is redundant. OTP owns termination; there is no window during which Python can be running while Elixir believes it shouldn't be. Keeping the protocol as "defensive in depth" is possible but adds implementation cost without a corresponding failure mode to defend against in the single-host OTP-supervised model.

**Decision: do not build in v1.** If a future architectural shift (multi-host adapters, cross-machine deployment) reintroduces the divergence window, revisit then.

## Relationship to `feature/dev-prod-isolation`

That branch (mid-implementation as of 2026-04-21) explicitly leaves `worker_supervisor.ex` untouched — its plan states:

> `worker_supervisor.ex` — unchanged API; `Commands.RegisterAdapter` calls existing `ensure_adapter/4`

This is fine. The MuonTrap migration is orthogonal and should land **after** `feature/dev-prod-isolation` merges, to avoid conflicts in `application.ex` and at the `Commands.RegisterAdapter` call site. The migration PR replaces `ensure_adapter/4` call sites with `start_adapter/4` atomically.

Idempotency semantics that `Commands.RegisterAdapter` currently relies on (re-registering the same `(name, instance)` is a no-op) are preserved: the `{:error, {:already_started, pid}}` return is straightforward to translate back to the caller's expected `:already_running`-equivalent.

## Rough implementation sketch (non-binding)

Roughly six logical commits:

1. Add `{:muontrap, "~> 1.5"}` dependency; confirm it builds on macOS + Linux CI
2. Rewrite `Esr.WorkerSupervisor` internals to `DynamicSupervisor` + `MuonTrap.Daemon`; public API renamed to `start_*/stop_*`; keep a thin `ensure_*` shim delegating to `start_*` temporarily to avoid breaking any in-flight branches during the transition window
3. Wire `Registry.deactivate/1` and `Instantiator.rollback_spawned/2` to call `stop_*`
4. Delete `scripts/spawn_worker.sh`; update `scripts/spawn_scenario_workers.sh` to use the public API
5. Remove pidfile mechanism (`external_alive?`, `record_external`, `/tmp/esr-worker-*.pid`); clean up affected tests
6. Add `Esr.Admin.AdapterAuthz` module + wire `AdapterSocket.connect/3` to verify declarations; add the missing auth-rejection tests and the `pgrep`-based reverse-scenario E2E assertions for TC1/TC2/TC3

Rough net change: 200-400 lines deleted after additions (more code retired than added). Migration is a green-state-preserving refactor modulo tests that assert on the old pidfile behavior.

## Open questions (resolve at implementation time)

- **AdapterSocket authz token mechanism.** "Declaration-set membership is sufficient" is the leaning for v1 on single-host. Shared-secret token or mutual-TLS are hardening options to revisit if threat model changes.
- **MuonTrap cgroup features (Linux-only).** Worth configuring per-adapter resource limits? Probably not for v1. Revisit if OOM or CPU-runaway incidents emerge.
- **Handler model consequences.** User has committed to model (a) — shared function pool — which implies the `worker_id` concept in YAML should be phased out as a separate follow-up. Not part of this migration.
- **Coverage-matrix backfill.** The reverse scenarios (`esr cmd stop` / rollback / YAML-delete → `pgrep esr.ipc.adapter_runner` empty) can be added as P0 gaps **now**, independent of the MuonTrap work. That is already valuable even against the current code, because it will fail reproducibly and document the gap.

## References

- MuonTrap: <https://github.com/fhunleth/muontrap> · <https://hexdocs.pm/muontrap>
- Pythonx: <https://github.com/livebook-dev/pythonx>
- Issue #7: <https://github.com/ezagent42/esr/issues/7>
- Phase 8f introduction commit: `f43baff9bb6c63702d358a4f8e9b7eb297b694b0`
- OTP `DynamicSupervisor` docs: <https://hexdocs.pm/elixir/DynamicSupervisor.html>
