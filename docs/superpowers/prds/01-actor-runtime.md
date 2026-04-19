# PRD 01 — Actor Runtime (Elixir)

**Spec reference:** `docs/superpowers/specs/2026-04-18-esr-extraction-design.md` §3 + §7
**Glossary:** `docs/superpowers/glossary.md` — definitive definitions for every term used here
**E2E tracks:** A (registration), B (scheduling), C (bidirectional), D (isolation), E (observability), F (operations), G (debug), H (correctness)
**Plan phase:** Phase 1

---

## Goal

Build an Elixir/OTP runtime that owns actor lifecycle, message transport, topology execution, and IPC endpoints. This is the substrate every Python handler and adapter talks to; it carries no business logic and no domain vocabulary. Every piece is named and supervised per OTP best practices (elixir-phoenix-helper references: otp-core.md, phoenix-web.md, realtime.md).

## Non-goals

- Business logic (lives in Python handlers)
- External I/O (lives in Python adapters)
- Socialware packaging, contract verifier, multi-node cluster (all v0.2+)
- Phoenix REST/HTML/LiveView (this runtime uses Channels only)

## Functional Requirements

### F01 — Project scaffold
The runtime is generated via `mix phx.new runtime --module Esr --app esr --no-ecto --no-html --no-assets --no-dashboard --no-mailer --no-gettext` with Phoenix **1.8+** and Elixir **1.19+**. The `mix.exs` deps list includes `phoenix`, `phoenix_pubsub`, `jason`, `telemetry`, `bandit`, plus dev-only `credo` and `dialyxir`. **Unit test:** `mix compile --warnings-as-errors` succeeds from a fresh clone.

### F02 — Supervision tree
`Esr.Application.start/2` starts, in order: `Phoenix.PubSub` (name `EsrWeb.PubSub`), `Registry` (keys: :unique, name `Esr.PeerRegistry`), `Esr.PeerSupervisor` (DynamicSupervisor), `Esr.AdapterHub.Supervisor`, `Esr.HandlerRouter.Supervisor`, `Esr.Topology.Supervisor`, `Esr.Persistence.Supervisor`, `Esr.Telemetry.Supervisor`, `EsrWeb.Endpoint`. Strategy: `:one_for_one`. **Unit test:** `Esr.ApplicationTest` asserts `Process.whereis/1` returns a pid for each.

### F03 — PeerRegistry
`Esr.PeerRegistry` exposes `register(actor_id, pid)`, `lookup(actor_id)` returning `{:ok, pid} | :error`, and `list_all()` returning `[{actor_id, pid}]`. Thin wrapper over Elixir's Registry. **Unit test:** `Esr.PeerRegistryTest` covers register/lookup/list/unknown-id.

### F04 — PeerSupervisor
`Esr.PeerSupervisor` is a DynamicSupervisor. `start_peer(opts)` spawns a PeerServer with `restart: :transient` (normal exit does not restart). `stop_peer(actor_id)` terminates the child via PeerRegistry lookup. Strategy: `:one_for_one` — one actor crashing does not affect siblings (enforces Track D isolation). **Unit test:** `Esr.PeerSupervisorTest` asserts start/stop; asserts crash of one peer does not kill a co-spawned peer.

### F05 — PeerServer state
`Esr.PeerServer` is a GenServer with state `%{actor_id, actor_type, handler_module, adapter_refs, state, metadata, dedup_keys, paused}`. `handler_module` is a string module name (no worker PID pinning — see F14). `dedup_keys` is a bounded MapSet (max 1000 entries, LRU-evicted) used for idempotency. `paused` defaults to `false`; when `true`, `handle_cast({:inbound_event, _})` queues events for post-resume processing. **Unit test:** `Esr.PeerServerTest` covers state initialisation, dedup-set bound, and pause-queue behaviour.

### F06 — PeerServer event handling
`{:inbound_event, event}` is cast to the owning PeerServer by AdapterHub. PeerServer calls `Esr.HandlerRouter.call/3` with current state and event, awaits `{:ok, new_state, actions}` or error. On success: persist state to ETS checkpoint, enumerate actions and dispatch each (see F07); emit `[:esr, :handler, :called]` telemetry. On error `{:error, :handler_timeout}` or `{:error, {:worker_crashed, _}}`: retry once with a fresh worker (at-least-once); on exhaustion, route the event to dead letter and emit `[:esr, :handler, :retry_exhausted]`. **Unit test:** happy path, timeout path, worker-crashed-retry path.

### F07 — Action dispatch
PeerServer validates and dispatches each action returned by the handler:
- `Emit{adapter, action, args}` → push a `directive` envelope on the adapter's Phoenix channel; await `directive_ack`.
- `Route{target, msg}` → send `{:inbound_route, msg}` to the target's PeerServer via PeerRegistry. Actor IDs that do not resolve dead-letter the message.
- `InvokeCommand{name, params}` → call `Esr.Topology.Registry.instantiate/2`; idempotent — if an instantiation with identical `(name, params)` exists, no-op. Emits `[:esr, :topology, :activated]` on new instantiation.
Any action type outside `Emit | Route | InvokeCommand` is rejected with `[:esr, :handler, :violation]` telemetry and the handler call is treated as if it returned `[]` after the state update.
**Unit test:** one test per action type; one test per rejection case.

### F08 — AdapterHub.Registry
`Esr.AdapterHub.Registry` binds adapter Phoenix topic `adapter:<name>/<instance_id>` to a specific owning actor ID. `bind(topic, actor_id)` / `unbind(topic)` / `lookup(topic)` returning `{:ok, actor_id} | :error`. **Unit test:** bind / unbind / lookup / multi-binds-fail.

### F09 — AdapterHub channel handling
`EsrWeb.AdapterChannel` joins on `adapter:<name>/<instance_id>`. Incoming `event` messages are routed via AdapterHub.Registry to the owning PeerServer as `{:inbound_event, event}`. Incoming `directive_ack` messages are routed by correlation id to the PeerServer that issued the directive. **Unit test:** Phoenix ChannelTest `subscribe_and_join/3` + `push/3` + assertion that the target PeerServer's mailbox received the event.

### F10 — HandlerRouter.Pool
`Esr.HandlerRouter.Pool` manages a pool of Python worker OS processes per handler module. Each worker is started via `Port.open/2` with `{:spawn_executable, "uv"}` and arguments `["run", "python", "-m", "esr.ipc.handler_worker", <url>, <module>]`. Default pool size 2 (configurable per module via `handlers/<name>/esr.toml`). On worker exit (`{port, {:exit_status, _}}`), respawn; emit `[:esr, :handler, :crashed]`. **Unit test:** pool spawns N workers; one worker dies → respawned; pool size drops and recovers.

### F11 — HandlerRouter.call
`Esr.HandlerRouter.call(handler_module, %{state, event}, timeout)` picks any free worker from the pool, pushes a `handler_call` envelope on its channel, awaits `handler_reply` with matching id. Timeout default 5s (per spec §7.3). Returns `{:ok, new_state, actions} | {:error, :handler_timeout} | {:error, {:worker_crashed, reason}} | {:error, {:purity_violation, detail}}`. **Unit test:** happy call, timeout, crash, purity violation detected server-side.

### F12 — HandlerChannel
`EsrWeb.HandlerChannel` joins on `handler:<module>/<worker_id>`. Receives `handler_reply` from Python workers, correlates by id to pending `HandlerRouter.call` responses. **Unit test:** round-trip `handler_call → handler_reply` with mocked Python worker.

### F13 — Topology.Registry + Topology.Instantiator
`Esr.Topology.Registry` stores loaded artifact structs keyed by `(name, params)` for idempotency. `Esr.Topology.Instantiator.instantiate(artifact, params)` validates, substitutes params, spawns actors in `depends_on` topological order (Kahn's algorithm), binds adapters, **issues each node's `init_directive` if declared** (see F13b), opens routes. Returns `{:ok, handle}` where `handle` is the canonical `(name, params)`. Rejects if params are missing or if any referenced adapter/handler module is not installed. **Unit test:** happy spawn, params-missing, dep-missing, DAG ordering correct, cycle detection.

### F13b — `init_directive` handling (adapter initialisation)
A node declaration may include an optional `init_directive: {action: <str>, args: <dict>}` field. When that node is spawned, the Topology Instantiator — after binding the adapter — sends a `Directive(adapter=<bound_adapter>, action=..., args=<substituted_args>)` and awaits the ack. Semantics:

- A node is **not considered "active"** (and no dependent in `depends_on` starts spawning) until its init_directive has acked ok.
- If the init_directive times out (default 30 s, override via node metadata) or acks with `{"ok": false, ...}`, the whole instantiation rolls back: already-spawned predecessor nodes stop in reverse `depends_on` order; the overall `instantiate/2` returns `{:error, {:init_directive_failed, node_id, reason}}`.
- Node `args` can reference topology params with `{{param_name}}` substitution (same substitution as node `id` and `params`).
- A node without `init_directive` needs no adapter-side initialisation; it is "active" as soon as the PeerServer is running.

**Unit test:** `Esr.Topology.InstantiatorTest`
- Happy: node with init_directive acks ok, dependent spawns
- Fail: init_directive acks error → rollback predecessors
- Fail: init_directive times out → rollback
- Substitution: `{{thread_id}}` in args resolved correctly

### F14 — Topology stop cascade
`Esr.Topology.Registry.deactivate(handle)` stops actors in **reverse** `depends_on` order. A parent's stop waits for all dependents to be in `:stopped` before stopping itself. Emits `[:esr, :topology, :deactivated]`. **Unit test:** spawn a 3-node depends_on chain, stop, assert reverse order via telemetry timestamps.

### F15 — Telemetry buffer
`Esr.Telemetry.Buffer` is a GenServer wrapping an ETS table (`:ordered_set`, named). `record(event, measurements, metadata)` appends; `query(opts)` returns events within a time window. Retention default 15 minutes, configurable via `config :esr, :telemetry_buffer_retention_minutes`. A prune task runs every `retention_minutes` minutes, dropping entries older than the window. **Unit test:** record + query, prune evicts old entries.

### F16 — Telemetry attach
On application start, the runtime attaches to `:telemetry` events matching `[:esr, :*, :*]` and writes them into `Esr.Telemetry.Buffer`. **Unit test:** trigger a synthetic event via `:telemetry.execute/3`, assert it appears in `Buffer.query/1`.

### F17 — URI parser
`Esr.Uri.parse/1` accepts `esr://[org@]host[:port]/<type>/<id>[?params]` and returns `{:ok, %Esr.Uri{}} | {:error, atom()}`. Empty host → `{:error, :empty_host}`. Unknown type → `{:error, :unknown_type}`. `Esr.Uri.build/3` constructs a canonical URI. **Unit test:** Task 1.6 tests in the plan.

### F18 — Persistence
`Esr.Persistence.Ets` owns an ETS table storing each PeerServer's state on every change, keyed by `actor_id`. A periodic checkpoint task (every 30 s) flushes the table to `~/.esrd/<instance>/data/actors.bin` via `:erlang.term_to_binary/1`. On Application start, if the file exists, load it into the ETS table so restarts can re-hydrate state (verified in E2E Track G-4). **Unit test:** persist → restart simulation → reload; state identical.

### F19 — Dead letter
`Esr.DeadLetter` (GenServer) receives events that fail to route (unknown actor, handler retry exhaustion). Stored in a bounded queue (max 10 000 entries, FIFO-evicted). Queryable via `esr deadletter list` CLI (PRD 07). **Unit test:** synthetic unreachable target + assertion entry appears.

### F20 — Pause / resume
PeerServer accepts `{:pause}` and `{:resume}`. While paused, `{:inbound_event, _}` is queued in an internal list (bounded 1000, FIFO); on resume, events dispatch in arrival order before new inputs. Emits `[:esr, :actor, :paused]` / `[:esr, :actor, :resumed]`. **Unit test:** pause / inject / resume / assert processing order.

### F21 — OTP supervision survives `kill -9`
The release built via `mix release` starts the `Esr.Application`; a systemd / launchd unit (specified in Phase 0 plan, referenced here) restarts the release after `SIGKILL`. On restart, ETS state is rehydrated from the persistence file (F18). **Integration test (manual):** E2E Track G-4.

## Non-functional Requirements

- **Latency:** handler call round-trip p95 < 20 ms (warm); < 2 000 ms cold-start. Per §9.3.
- **Resilience:** BEAM `kill -9` → messageable within 5 s.
- **Observability:** every public operation emits `:telemetry` with standardised metadata keys (actor_id, handler_module, adapter, topic, msg_id where applicable).
- **Lint:** `mix credo --strict` clean; `mix dialyzer` clean (unless using `@dialyzer {:nowarn_function, ...}` with a comment explaining why).
- **Style:** per the elixir-phoenix-helper skill — `@impl true` on every behaviour callback, `@moduledoc` + `@spec` on public modules, pattern match in function heads over `if/case`, `with` for happy-path chains.

## Dependencies

- PRD 02 (Python SDK): the HandlerRouter and AdapterHub can't be meaningfully tested end-to-end without at least a stub Python worker/adapter. Unit tests within this PRD mock the Python side.
- PRD 03 (IPC) is largely subsumed into this PRD's F09–F12 because the Elixir side of the IPC lives here.
- Plan Phase 0 bootstrap (skills + .gitignore + README) must be done first.

## Unit-test matrix

| FR | Test file (Elixir) | Test name |
|---|---|---|
| F01 | — | manual: `mix compile --warnings-as-errors` |
| F02 | `runtime/test/esr/application_test.exs` | all supervisors started |
| F03 | `runtime/test/esr/peer_registry_test.exs` | register / lookup / list / unknown |
| F04 | `runtime/test/esr/peer_supervisor_test.exs` | start_peer / stop_peer / crash isolation |
| F05 | `runtime/test/esr/peer_server_test.exs` | state init / dedup bound / pause queue |
| F06 | `runtime/test/esr/peer_server_test.exs` | inbound_event happy / timeout / crash-retry |
| F07 | `runtime/test/esr/peer_server_action_test.exs` | emit / route / invoke_command / rejection |
| F08 | `runtime/test/esr/adapter_hub_registry_test.exs` | bind / unbind / lookup |
| F09 | `runtime/test/esr_web/adapter_channel_test.exs` | subscribe / push / PeerServer mailbox |
| F10 | `runtime/test/esr/handler_router/pool_test.exs` | spawn N / respawn on exit |
| F11 | `runtime/test/esr/handler_router_test.exs` | call happy / timeout / crash / purity |
| F12 | `runtime/test/esr_web/handler_channel_test.exs` | call round-trip |
| F13 | `runtime/test/esr/topology/instantiator_test.exs` | spawn / params-missing / dep-missing / DAG / cycle |
| F13b | `runtime/test/esr/topology/init_directive_test.exs` | happy / ack-error rollback / timeout rollback / args substitution |
| F14 | `runtime/test/esr/topology/instantiator_test.exs` | stop reverse order |
| F15 | `runtime/test/esr/telemetry/buffer_test.exs` | record / query / prune |
| F16 | `runtime/test/esr/telemetry/attach_test.exs` | synthetic event roundtrip |
| F17 | `runtime/test/esr/uri_test.exs` | parse / build / error cases |
| F18 | `runtime/test/esr/persistence/ets_test.exs` | persist / reload |
| F19 | `runtime/test/esr/dead_letter_test.exs` | unknown target lands here |
| F20 | `runtime/test/esr/peer_server_pause_test.exs` | pause / queue / resume |
| F21 | — | manual per E2E Track G |

## Acceptance

- [x] All 21 FRs (+ F13b) have passing unit tests — 19/22 unit-complete; F10 pool and F21 kill-9 deferred to live integration
- [x] `mix test` green (105 tests); `mix credo --strict` clean; `mix dialyzer` deferred tooling
- [x] Integration test: spawn → inject event → handler mock returns → actions dispatched → telemetry observed (peer_server_action_dispatch_test.exs + peer_server_event_handling_test.exs)
- [x] PRD 01 unit-test count ≥ 50 — 105 achieved
- [ ] Manual: E2E Track G-4 recovery ≤ 5 s (gated by Phase 8 — live systemd run deferred)

---

*End of PRD 01.*
