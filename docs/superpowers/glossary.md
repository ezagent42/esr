# ESR v0.1 Glossary

Canonical definitions for terms used across the spec, PRDs, E2E test document, and implementation plan. When a term appears in doc or code, it means what this glossary says it means — nothing more, nothing less. If you find yourself wanting to redefine one, write a new term instead.

---

## Core concepts

### Actor
An identifiable, addressable unit with a stable id, a handler, a state, and optional adapter bindings. One live BEAM GenServer (a **PeerServer**) represents one actor in ESR. Actors have `actor_type` (schema) and `actor_id` (instance).

### PeerServer
The Elixir GenServer that hosts one live actor. State + handler_module + adapter_refs live here. One-to-one with an actor.

### Handler
A **pure Python function** of the signature `(state, event) -> (new_state, [Action])` registered via `@handler(actor_type, name)`. Handlers decide; they do not do I/O. Purity is CI-enforced (import allow-list + frozen-state fixture).

### Adapter
A **Python class bridging ESR to one external system** (Feishu, tmux, LLM API, etc.). Registered via `@adapter(name, allowed_io=...)`. Provides a `factory(actor_id, config)` that is pure and returns an instance whose `on_directive(d)` and `emit_events()` methods are the I/O paths. The `allowed_io` declaration bounds which modules/hosts the adapter may call; enforced via CI capability scan.

### Decision rule: handler vs adapter
> Can this code run in an environment without network, without filesystem, without subprocess? → **Handler**. Otherwise → **Adapter**.

---

## Flow primitives

### Event
A `dataclass(frozen=True)` carrying `source` (esr:// URI), `event_type` (string), `args` (dict). Flows **inbound** from an adapter to the runtime. The runtime routes events to the owning PeerServer, which passes them to the handler.

### Directive
A `dataclass(frozen=True)` carrying `adapter` (instance name), `action` (string), `args` (dict). Flows **outbound** from the runtime to an adapter. The adapter executes it (a side-effecting I/O call) and acks back.

### Action
What a handler returns. Exactly three kinds in v0.1:
- **`Emit(adapter, action, args)`** — instructs the runtime to issue a directive to the named adapter instance
- **`Route(target, msg)`** — instructs the runtime to deliver `msg` to another actor (same esrd instance)
- **`InvokeCommand(name, params)`** — instructs the runtime to instantiate a registered command (sub-topology) with these params (see §InvokeCommand below)

No raw `Spawn` or `Stop` actions in v0.1.

### Emit vs Directive (terminology note)
An `Emit` action is what a handler returns. Once the runtime accepts it and pushes it over IPC, it becomes a `directive` envelope. Two layers, one concept.

---

## Topology primitives

### Command
A named, registered pattern. Authored via `@command(name)` + the EDSL (`node`, `port`, `compose.serial`). Compiles to a canonical YAML **topology artifact**.

### Pattern
Informal synonym for **command source** — the `.py` file with `@command(...)`. "Pattern" describes the structure; "command" is the invocable entity.

### Topology
The compiled artifact — a subset of ESR v0.3 §5.2's topology — describing nodes, edges, ports, params. Stored at `patterns/.compiled/<name>.yaml`. Deterministic, diff-able, what the Elixir runtime consumes.

### Node
A declaration within a command: `{id, actor_type, handler, adapter, params, depends_on, init_directive}`. Instantiates into a live actor.

### Edge
A message-routing declaration between two nodes: `{from, to}`. Produces PubSub subscription wiring when the topology is instantiated.

### Port
A typed in/out boundary on a command, used by `compose.serial` to match patterns. Not used in the two v0.1 patterns (feishu-app-session, feishu-thread-session) but available in the EDSL.

### depends_on
A list of node references a node is lifecycle-dependent on. Spawn order respects depends_on (Kahn); stop order is reverse; parent crash cascades down to dependents. Forms a DAG — cycles rejected at compile time.

### init_directive (new in v0.1)
An optional field on a node declaration: `{action: <str>, args: <dict>}`. When a node is spawned, the Topology Instantiator issues this directive to the node's bound adapter **before** marking the node "active" and before any dependents start spawning. If the directive returns error or times out, the instantiation rolls back (stops predecessor nodes in reverse `depends_on` order). Used e.g. for "create the tmux session" at tmux-proxy actor birth.

### InvokeCommand (action + mechanism)
A handler-returnable Action that instructs the runtime to instantiate a registered command with specific params. Same mechanism as CLI `esr cmd run <name>` — two entry points, one code path. Idempotent: instantiating with identical `(name, params)` a second time is a no-op. Enables dynamic topology growth (`/new-thread foo` in Feishu) without opening a raw-Spawn escape hatch.

### Sub-topology
Informal term for a command that is typically invoked by another handler via `InvokeCommand`, rather than only from the CLI. `feishu-thread-session` is a sub-topology of the feishu-to-cc scenario; `feishu-app-session` is the top-level (singleton).

---

## Delivery semantics

### Dead letter
Inspired by postal service "dead letter office": the holding area for messages that couldn't be delivered. In ESR, three things land here:
- **Unknown target** — a `Route` or `Emit` referenced an actor_id / adapter instance that doesn't exist
- **Handler retry exhausted** — a `HandlerRouter.call` failed twice (timeout or worker crash)
- **Adapter directive failure after retries** — an adapter returned errors on all retry attempts

Stored in `Esr.DeadLetter` (bounded FIFO queue, 10 000 entries). Queryable via `esr deadletter list`; one entry can be re-pushed via `esr deadletter retry <id>`.

### Idempotency (at two layers)
- **Event dedup** (handler level) — an event may carry `msg_id` or `idempotency_key`; the handler's state has a bounded `dedup: frozenset[str]` that rejects duplicates. Used by `feishu_thread` to ignore replayed Feishu messages.
- **InvokeCommand idempotency** (runtime level) — re-invoking a command with identical `(name, params)` returns the existing handle, does not respawn actors.

### Per-actor in-order dispatch
The runtime guarantees events for one actor are processed in arrival order. No ordering guarantees between actors (each is an independent GenServer).

### At-least-once handler retry
On `{:error, :worker_crashed}` or `{:error, :handler_timeout}`, the PeerServer retries once with a fresh worker. Exhaustion → dead letter. Handlers must be deterministic (same `(state, event)` → same result) to make this safe; CI purity guards ensure this.

---

## Instances & addressing

### Instance name
A per-org unique identifier for a configured adapter instance. `esr adapter add feishu-shared --type feishu --app-id ...` creates an instance named `feishu-shared` of type `feishu`. Handlers refer to the instance by name in `Emit(adapter="feishu-shared", ...)`.

### actor_id
Stable string identifier for one live actor, unique within an esrd instance. Typical format `<type-shorthand>:<key>` (e.g. `feishu-app:cli_TEST`, `thread:foo`, `tmux:foo`, `cc:foo`). No `esr://` prefix required when used within one esrd — that's the short-form carve-out in spec §4.4 / §7.5.

### esr:// URI
Canonical cross-boundary address. `esr://[org@]host[:port]/<type>/<id>[?params]`. Host is always required — empty host is a syntax error. Spec §7.5.

---

## Runtime machinery

### AdapterHub
Elixir subsystem that owns the adapter↔runtime Phoenix channels. Maintains `Esr.AdapterHub.Registry` binding `adapter:<name>/<instance_id>` topics to owning actor IDs, so inbound events route to the right PeerServer.

### HandlerRouter
Elixir subsystem that owns the handler↔runtime Phoenix channels and the Python handler worker pool (per handler module). Serialises `(state, event)` into `handler_call`, awaits `handler_reply`.

### Topology Registry / Instantiator
Elixir subsystem storing loaded topology artifacts and instantiating them. Instantiation = spawn actors in `depends_on` order (Kahn) + issue init_directives + bind adapters + open edges. Deactivation = reverse cascade.

### Telemetry Buffer
ETS-backed rolling buffer of `:telemetry` events. Default retention 15 min. Backs `esr trace`.

### Persistence
ETS table mirroring each PeerServer's state on every change; periodic checkpoint to disk (`~/.esrd/<instance>/data/actors.bin`). Restores on Application start, enabling BEAM `kill -9` recovery.

---

## Operations

### esrd
The Elixir/OTP runtime. In v0.1 there is no dedicated `esrd` escript — we use the BEAM release + `iex --remsh` for daemon ops. A dedicated escript is v0.2.

### esr
The Python CLI. Talks to a running esrd via Phoenix channels. Context stored in `~/.esr/context`. `ESR_CONTEXT` env var overrides.

### BEAM REPL
Emergency / deep-inspection interface. `iex --remsh esrd@host`. Uses the cookie at `~/.esrd/<instance>/cookie`.

### Instance (of esrd)
One running BEAM node with its own PeerRegistry, AdapterHub, config dir, cookie. v0.1 expects two instances on one dev machine: `esrd-prod` (daily comms) and `esrd-dev` (development), isolated by default.

---

## Verification

### Purity check 1 — import allow-list
Static scan of a handler module's top-level `import` statements. Only modules in the allow-list (esr, typing, dataclasses, pydantic, enum, + declared helpers in the handler's esr.toml) are permitted. Catches handlers trying to `import requests`.

### Purity check 2 — frozen-state fixture
Every handler has a unit test invoking it with a `frozen=True` pydantic state. Mutation raises `ValidationError`. Catches handlers trying to mutate state in place.

### Capability scan (adapters)
Like purity check 1 but for adapters: scanned imports must match a prefix in the adapter's declared `allowed_io`. Catches adapters exceeding their stated surface.

### E2E gate
The test in `scenarios/e2e-platform-validation.yaml` + the prose spec at `docs/superpowers/tests/e2e-platform-validation.md`. Each of 8 tracks has its own acceptance checklist; v0.1 passes only when all boxes tick.

---

*End of Glossary.*
