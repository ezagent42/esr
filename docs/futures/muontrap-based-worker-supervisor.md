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

### Graceful cleanup ordering for adapters that hold external resources

The `cc_tmux` adapter (and any future adapter that holds tmux sessions, remote WebSocket connections, or other external handles) exposes a subtlety that MuonTrap alone does NOT close:

**The Python adapter process and the external resource have independent lifetimes.** A tmux session is a child of the tmux server daemon — not of our Python adapter, not of our BEAM. `MuonTrap.terminate_child/2` kills the Python process; the tmux session keeps running under tmux server. Analogously, a Feishu WebSocket session ID held by `lark_oapi` outlives the adapter process that registered it.

This means the system has three distinct layers of lifecycle management, each requiring a different tool:

```
┌─ Process lifecycle (processes WE spawn) ──→ MuonTrap / OTP Supervisor
│   Examples: Python adapter_runner, handler_worker
│
├─ External resource state monitoring (NOT spawned by us) ──→ regular Elixir GenServer
│   Examples: tmux session, Feishu WS session ID, any remote handle
│
└─ External resource cleanup (imposed by declarative state) ──→ explicit directive + Adapter on_teardown + boot-time reconciliation
    Examples: kill-session on deactivate
```

Forcing layer 2 or 3 into MuonTrap yields anti-patterns. E.g., wrapping a `bash -c "while tmux has-session -t <name>; do sleep 5; done"` watchdog in `MuonTrap.Daemon` makes the supervision tree _look_ richer but provides zero control — `terminate_child` kills the watchdog, not the session; `PR_SET_PDEATHSIG` takes down the watchdog, not the session. The right fix is to recognize that layer 2 doesn't belong in `MuonTrap`.

#### Layer 2: event-driven monitoring via `tmux -C attach` Control Mode

For tmux specifically, the lifecycle-observation mechanism is **tmux Control Mode** (`tmux -C attach`) — a text-protocol long-lived connection designed exactly for external programs that need to observe and control tmux. iTerm2's tmux integration uses this in production; it is mature and well-documented.

Control Mode flips the client-server model inside out: from the single `tmux -C attach` connection we both issue commands and receive asynchronous notifications on the same channel. Notifications arrive with a `%`-prefix:

- `%session-changed`, `%sessions-changed`
- `%window-add`, `%window-close`, `%window-renamed`
- `%output <pane_id> <data>` — real-time pane output streamed as events

Recommended shape:

```elixir
defmodule Esr.TmuxSessionMonitor do
  use GenServer

  # On init: Port.open("tmux", ["-C", "attach"]) — a single long-lived connection
  # Parse stdout lines by "%" prefix; dispatch notifications to interested peers
  # %session-closed → notify peer + trigger business-level recovery or degradation
  # %output pane_id data → replace the cc_tmux adapter's 500ms capture-pane polling
end
```

Wins over a polling GenServer:
- **Zero observation latency.** Session death is known the moment tmux server emits the event, not up to 5s later.
- **Zero poll overhead.** One long connection serves all sessions under all tmux instances on the host.
- **Eliminates `emit_events` polling in `cc_tmux`.** The adapter's 500ms `capture-pane` loop (see `adapters/cc_tmux/src/esr_cc_tmux/adapter.py` around `emit_events/0`) becomes a consumer of `%output` notifications pushed from `TmuxSessionMonitor`, removing one of the noisier hot loops in the codebase.

#### Layer 3: adapter-driven cleanup

Two mechanisms are required to guarantee external resources don't outlive their declaration, regardless of how the adapter exited:

1. **`Registry.deactivate/1` ordering contract.** When an adapter holds external resources, deactivation must issue a cleanup directive to the adapter FIRST (e.g., emit `kill_session` for every tmux session bound to the deactivating peer), wait for acknowledgment or a bounded timeout, and THEN call `Esr.WorkerSupervisor.stop_adapter/2`. If ordering is reversed, the adapter dies before it can run its cleanup logic, and external resources orphan. The spec should make this ordering explicit in every adapter that declares `holds_external_resources: true` in its manifest.

2. **`on_teardown` callback + boot-time reconciliation.** The adapter SDK should expose an `on_teardown` callback invoked on graceful SIGTERM (within the `delay_to_sigkill` grace window — likely tuned up from MuonTrap's 500ms default to ~5s for adapters with external resource cleanup). But graceful termination covers only one path. For the crash / `kill -9 esrd` path, the adapter cannot run any code. The answer is **boot-time reconciliation**: on adapter start, enumerate the external resources matching its naming scheme (e.g., `tmux list-sessions | grep <prefix>`), diff against the declared peer set that just restored from YAML, and kill anything orphaned. This runs exactly once per adapter boot, not periodically — so it is not a `ReconcileLoop` (that pattern was rejected), it is a startup-reconcile.

Closure matrix:

| Termination path | `on_teardown` runs? | Orphan cleaned by |
|---|---|---|
| `Registry.deactivate/1` → SIGTERM | ✓ | `on_teardown` + preceding cleanup directive |
| Adapter crash (Python segfault, OOM) | ✗ | boot-time reconcile on next adapter start |
| `kill -9 esrd` (BEAM death → `PR_SET_PDEATHSIG` cascades) | ✗ | boot-time reconcile on next adapter start |

Together, the ordering contract + `on_teardown` + boot-time reconcile cover all three paths.

## Why tmux Control Mode (not zellij, not a polling GenServer)

[Zellij](https://github.com/zellij-org/zellij) is a more modern terminal multiplexer (written in Rust, WASM plugin system, cleaner programmatic API). Evaluated as an alternative to tmux and rejected for ESR's v1 needs.

Capability comparison for the lifecycle-observation problem:

| Capability | tmux Control Mode | Zellij |
|---|---|---|
| Event stream | `tmux -C attach` stdout lines, `%`-prefixed | `zellij subscribe --pane-id X`, optional NDJSON output |
| Wait for command completion | parse `%exit` / signal reverse-engineering | native `zellij action new-pane --block-until-exit-success -- cmd` |
| Headless / background sessions | `tmux new-session -d` | `zellij --session X action ...` + explicit headless mode |
| Plugin system | custom scripts | first-class WASM plugin system |
| Maturity | 15+ years production, iTerm2 builds on Control Mode | newer, API still evolving between releases |
| User install base | near-universal on dev machines and servers | much smaller |
| ESR migration cost | zero (we already use tmux) | rewrite all `cc_tmux` adapter logic; users must install zellij |

Zellij has legitimately nicer ergonomics on a few specific axes — the `subscribe` + NDJSON output is cleaner than parsing Control Mode's ad-hoc text protocol; `--block-until-exit` is more civilized than signal-based exit tracking. But:

1. **tmux Control Mode is sufficient.** Event-driven session lifecycle + real-time pane output are both native capabilities. Nothing ESR needs is absent.
2. **Migration cost dominates.** Every `subprocess.run(["tmux", ...])` in the cc_tmux adapter would need rewriting. Operators and developers who have tmux baked into their muscle memory would face a retraining tax. No current ESR pain point justifies this.
3. **Maturity asymmetry.** Zellij's API is evolving. tmux's wire format has been stable for over a decade.

### When to revisit zellij

Trigger conditions for re-evaluation:

1. **Rich multi-pane CC TUI interactions** where tmux's Control Mode text protocol becomes the bottleneck (e.g., synchronized scrolling across panes, complex layout directives)
2. **Plugin ecosystem** requirements that would benefit from WASM-based extensibility per adapter
3. **Zellij 1.0 API stabilization** with a documented commitment not to break programmatic interfaces

None present today. Control Mode stays.

### Why not the polling GenServer I initially sketched

Earlier in the brainstorming transcript a polling approach (`Process.send_after(self(), :tick, 5_000)` + `tmux has-session`) was proposed. It works, but it is strictly worse than Control Mode on the dimensions that matter:

- Latency: 0–5s vs 0ms
- Overhead: one `tmux` CLI fork per session per tick vs one long-lived stdio connection total
- Operability: two competing monitoring paths (Control Mode for `%output` events in `cc_tmux`, polling for session existence) would be two code paths to maintain

The polling design is retained here only as a documentation of the rejected path so future readers don't re-propose it.

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
