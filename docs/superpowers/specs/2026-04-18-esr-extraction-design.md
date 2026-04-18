# ESR Extraction Design (v0.1)

**Status:** Draft for review
**Date:** 2026-04-18
**Implements:** ESR Protocol v0.3 (partial); Socialware Packaging Spec v0.3 (partial)
**Source of extraction:** `cc-openclaw` (private working codebase)

---

## 0. Abstract

ESR v0.1 extracts cc-openclaw's actor networking core into an ESR-conforming structure. It splits today's Python monolith into four disciplined layers: an **Elixir/OTP Actor Runtime** that owns actor lifecycle and message transport, and three Python layers — **Handler**, **Adapter**, **Command** — that encode business decisions, external integration, and topology composition respectively. The feishu↔CC pipeline that cc-openclaw already supports becomes the reference E2E platform-validation scenario.

This spec fixes the architecture, per-layer contracts, IPC protocol, project skeleton, E2E scope, and the migration map from cc-openclaw. Implementation PRDs, unit tests, and the migration sequence are produced by the implementation plan (separate artifact, `writing-plans` phase).

---

## 1. Background

### 1.1 Motivation

cc-openclaw today couples actor routing, message processing, external I/O, and CLI commands in one Python codebase (`channel_server/`). The coupling:

- Blocks ESR-style governance (contracts, topologies, verification)
- Makes handler side-effects structurally possible (any handler may `requests.post`)
- Binds business logic to a single-process runtime without OTP-grade supervision

Extracting the generic substrate gives:

- An Elixir runtime inheriting OTP supervision, distribution, and telemetry
- Business logic confined to disciplined Python primitives with CI-enforced purity
- A compiler pipeline from business-level patterns to a validated actor execution graph

### 1.2 Scope (v0.1)

**In scope:**

- Four-layer architecture (§2)
- Handler / Adapter / Command primitives and the Python SDK (§4–§6)
- IPC between Elixir runtime and Python processes (§7)
- `esr/` project skeleton (§8)
- E2E platform validation using feishu-to-cc as the exercise vehicle (§9)
- Migration map from cc-openclaw to esr/ (§10)

**Out of scope — deferred:**

- Parallel / feedback composition operators (v0.2)
- Advanced optimization passes — operator fusion, placement, batching (v0.2+)
- Socialware packaging, governance workflow, external-interface exposure (separate specs)
- Multi-node BEAM cluster (v0.2)
- Natural-language → YAML front-end (after EDSL stabilizes)
- Full contract verifier infrastructure (borrow from esrd spec when the EDSL is proven)

### 1.3 Relation to ESR v0.3

This spec is a practical subset of ESR v0.3, targeted at running feishu-to-cc. It does not yet implement contract declaration YAML, topology validation, or governance proposals. Those remain aligned with ESR v0.3 semantics and fold in as subsequent specs.

---

## 2. Architecture

### 2.1 Four Layers

```
┌───────────────────────────────────────────────────────────┐
│  LAYER 4: Command (Python)                                 │
│  Typed open-graph pattern compiler. Authored via Python    │
│  EDSL; canonical output is YAML artifact.                  │
└───────────────────────────────────────────────────────────┘
                            │ compile
                            ▼
┌───────────────────────────────────────────────────────────┐
│  LAYER 3: Adapter (Python)                                 │
│  Pure factory → impure inner fn. Bridges one external      │
│  system (Feishu, CC tmux, LLM, …). Driven by runtime       │
│  directives; emits events on external input.               │
└───────────────────────────────────────────────────────────┘
                            │ directive / event over IPC
                            ▼
┌───────────────────────────────────────────────────────────┐
│  LAYER 1: Actor Runtime (Elixir / OTP)                     │
│  PeerServer per actor; Phoenix.PubSub messaging;           │
│  AdapterHub for Python IPC; HandlerRouter for dispatch.    │
│  Supervises Python worker processes.                       │
└───────────────────────────────────────────────────────────┘
                            │ handler_call / handler_reply over IPC
                            ▼
┌───────────────────────────────────────────────────────────┐
│  LAYER 2: Handler (Python)                                 │
│  Pure function (state, event) → (new_state, [actions]).    │
│  Registered via `@esr.handler`. Purity CI-enforced.        │
│  Called by runtime per event; actions dispatched by        │
│  runtime.                                                  │
└───────────────────────────────────────────────────────────┘
```

### 2.2 Elixir / Python Boundary

| Concern | Layer |
|---|---|
| Actor identity, lifecycle, restart | Elixir |
| Message routing, PubSub | Elixir |
| Actor state persistence | Elixir (ETS + periodic checkpoint) |
| Topology execution (graph reconciliation) | Elixir |
| Handler business logic (pure compute) | Python |
| Adapter I/O (Feishu API, tmux, …) | Python |
| Command authoring (EDSL → YAML) | Python |
| Command compilation (YAML → optimized artifact) | Python |
| CLI (`esr` command) | Python |

Elixir has no domain vocabulary. Python has no ownership of actor state.

### 2.3 Canonical Flow: One External Event

```
External event (e.g. feishu WS frame)
 → Adapter emits {event, source, event_type, args} over IPC
 → Elixir AdapterHub receives, finds owning PeerServer
 → PeerServer calls HandlerRouter with (state, event)
 → Python handler worker returns (new_state, [actions])
 → PeerServer persists new_state, dispatches each action:
    • Directive → AdapterHub pushes to target adapter
    • Route     → PubSub publishes to target actor
    • Spawn/Stop → PeerSupervisor reconciles topology
 → Adapter executes directives; observable side-effects occur
 → Telemetry events emitted at every boundary
```

One Elixir GenServer (`PeerServer`) per live actor. Python handler workers are stateless, pooled per module.

---

## 3. Layer 1 — Actor Runtime (Elixir)

### 3.1 Supervision Tree

```
Esr.Application
├── Esr.PeerRegistry                (Registry)
├── Esr.PeerSupervisor              (DynamicSupervisor)
│   └── Esr.PeerServer              (one per live actor)
├── Esr.AdapterHub.Supervisor
│   ├── EsrWeb.Endpoint             (Phoenix, /adapter_hub/socket)
│   └── Esr.AdapterHub.Registry
├── Esr.HandlerRouter.Supervisor
│   ├── Esr.HandlerRouter.Pool      (tracks Python worker pools)
│   └── Esr.HandlerRouter.Registry
├── Esr.Topology.Supervisor
│   └── Esr.Topology.Registry       (loaded artifacts, active state)
├── Esr.Persistence.Supervisor      (ETS + periodic checkpoint)
└── Esr.Telemetry.Supervisor
```

### 3.2 PeerServer (per actor)

State: `%{actor_id, actor_type, handler_ref, adapter_refs, state, metadata}`

Handles:

- `{:inbound_event, event}` — call HandlerRouter with current state; apply resulting actions
- `{:inbound_route, msg}` — message from peer actor; same path as inbound_event
- `{:directive_ack, id, result}` — adapter acknowledged a prior directive
- `{:shutdown, reason}` — graceful stop; emit telemetry; persist final state

Emits telemetry at every transition. Never encodes business decisions.

### 3.3 AdapterHub

One Phoenix Channels endpoint (`/adapter_hub/socket`). Each Python adapter process joins a topic per instance:

```
adapter:feishu/<instance_id>
adapter:cc_tmux/<instance_id>
adapter:llm/<instance_id>
```

Inbound events from channels become `{:inbound_event, ...}` to owning PeerServer. Outbound directives from Elixir are pushed on the same channel with an `id` for ack correlation.

### 3.4 HandlerRouter

Each handler module is served by a Python worker pool. Elixir's call:

```elixir
HandlerRouter.call(handler_ref, %{state: state, event: event}, timeout: 5_000)
# → {:ok, new_state, actions}
# | {:error, :handler_timeout}
# | {:error, {:purity_violation, details}}
```

Transport: Phoenix Channels, separate topic namespace `handler:<module>/<worker_id>`.

### 3.5 Topology.Registry

Stores compiled Command artifacts. On `esr cmd run <name> <params>`:

1. Parse the artifact, substitute params
2. Spawn required PeerServers under PeerSupervisor
3. Bind adapters and handlers to each actor
4. Open routing edges

Topology is first-class; actors reconcile to match it. `esr cmd stop` → deactivate artifact → cleanup.

### 3.6 Telemetry Events

Standardised `:telemetry` events consumable by observers, verifier, `esr trace`:

- `[:esr, :actor, :spawned]`
- `[:esr, :actor, :stopped]`
- `[:esr, :message, :received]`
- `[:esr, :message, :dispatched]`
- `[:esr, :directive, :issued]`
- `[:esr, :directive, :completed]`
- `[:esr, :handler, :called]`
- `[:esr, :handler, :violation]` (purity/timeout/invalid-action)
- `[:esr, :topology, :activated]`
- `[:esr, :topology, :deactivated]`

### 3.7 Management Surfaces

Three layers, each with a distinct responsibility:

**`esrd` — Elixir escript (operator-level, bundled with the release)**

Manages the daemon itself: lifecycle, cluster, version.

- `esrd init --org-name "..."` — initialise an org
- `esrd start` / `esrd stop` / `esrd restart`
- `esrd status` — node health, BEAM version, cluster members, uptime
- `esrd console` — attach `iex --remsh esrd@host`
- `esrd release info` — build / version info

Transport: `:erl_call` or BEAM RPC (no Phoenix).

**`esr` — Python CLI (user / developer level, primary)**

Manages what runs *inside* esrd: adapters, handlers, commands, actors.

- `esr use <host:port>` — set context
- `esr adapter / handler / cmd install <source>` — install modules (see §5.6, §6.8)
- `esr adapter add <name> <config>` — configure an adapter instance (see §5.4)
- `esr cmd run / stop <name>`
- `esr actors list / tree / inspect / logs`
- `esr trace`, `esr telemetry subscribe`, `esr debug ...`
- `esr status` — what's configured and running in the org

Transport: Phoenix Channels over WebSocket.

**BEAM REPL — `iex --remsh esrd@host`**

Emergency diagnostic and deep inspection. Not for everyday use.

- `:observer.start()` — visual process tree
- `:sys.get_state(pid)` — raw GenServer state
- `recon`, `Phoenix.LiveDashboard`
- Hot code reload (rare)

**Two `status` commands — different questions:**

- `esrd status`: infrastructure view — daemon up/down, nodes, CPU/memory, uptime, version
- `esr status`: organisation view — installed adapters/handlers/commands, live actor count, dead-letter count, active topologies

They do not overlap.

### 3.8 Multi-App Hosting & Dogfooding

**One esrd instance can host many apps and projects.** An esrd instance maps one-to-one to an *organisation* (ESR spec §1.1). Within that organisation the instance can host:

- Many adapter instances (multiple Feishu apps, multiple CC substrates, etc.) — each a configured instance of an installed adapter type
- Many registered commands and handler modules
- Many live topologies in parallel

A second Feishu app is **not** a second organisation — it is a second adapter instance:

```bash
esr adapter add feishu-shared  --app-id cli_aaaa --app-secret ...
esr adapter add feishu-dev     --app-id cli_bbbb --app-secret ...
```

Commands that need to disambiguate refer to instances by name (`feishu-shared` vs `feishu-dev`).

**Dogfooding esrd: developing esrd while using esrd.**

Restarting esrd to try a code change breaks any live connection owned by that instance. While esrd itself is churning (v0.1, v0.2), run **two instances**:

| Instance | Feishu app | Port | Purpose |
|---|---|---|---|
| `esrd-prod` | shared (daily comms) | 4000 | stays up for the daily channel |
| `esrd-dev`  | dev app              | 4001 | restarted freely during development |

Developer workflow:

1. `esr use localhost:4001` — target the dev instance
2. Modify esrd code, `esrd restart` — only dev is affected; prod Feishu connection unbroken
3. Test feishu-to-cc on the dev Feishu app
4. When verified, release to prod on the next deploy window

Once esrd is stable enough for in-place changes, graceful restart (state checkpoint + reconnect) replaces the two-instance split. v0.1 **does not** attempt graceful hot upgrade.

**Per-instance configuration storage:**

```
~/.esrd/<instance-name>/
├── config.yaml         # org name, port, logger, cluster settings, ...
├── adapters.yaml       # registered adapter instances (names, configs, refs)
├── commands.yaml       # registered command names → compiled artifact paths
├── secrets/            # app secrets; filesystem-permission protected
└── data/               # ETS snapshots, telemetry archive
```

Secrets are filesystem-permission protected in v0.1; OS keychain integration is v0.2+.

---

## 4. Layer 2 — Handler (Python)

### 4.1 Definition

A handler is a pure function:

```python
def handler(state: State, event: Event) -> tuple[State, list[Action]]:
    ...
```

Registered via decorator:

```python
from esr import handler, Event, Action, Emit, Route, Spawn, Stop

@handler(actor_type="cc_session", name="on_msg")
def on_msg(state: CCSessionState, event: Event) -> tuple[CCSessionState, list[Action]]:
    if event.type == "feishu_msg_received":
        if event.msg_id in state.dedup:
            return state, []
        return (
            state.with_dedup_added(event.msg_id),
            [
                Emit(adapter="feishu", action="react",
                     args={"msg_id": event.msg_id, "emoji": "ack"}),
                Emit(adapter="cc_tmux", action="send_keys",
                     args={"session": state.session, "content": event.content}),
            ],
        )
    if event.type == "cc_output":
        return state, [Route(target=state.feishu_peer, msg=event.content)]
    return state, []
```

### 4.2 Purity Contract

A handler must:

- Depend only on its arguments
- Return a new `State` value (state is frozen; mutation raises)
- Emit side-effects exclusively via `Action` objects

### 4.3 Purity Enforcement (CI)

Three combined checks:

**Check 1 — Module import allow-list.** Static scan of handler-module top-level imports. Allowed: `esr`, typing, dataclasses, pydantic, declared helper modules. Disallowed: `requests`, `urllib`, `socket`, `subprocess`, `os.system`, `sys.exit`, any stdlib network / file-write module. Violations fail `esr-lint handlers/`.

**Check 2 — Frozen-state invocation.** Every handler is unit-tested with a frozen `State` (pydantic `frozen=True` or `dataclass(frozen=True)`). Any attempted mutation raises `FrozenInstanceError`, failing the test.

**Check 3 — Cleared-globals invocation.** In a dedicated purity test the handler is copied into a module where `globals()` is restricted to a whitelist. If the handler body references anything outside the whitelist, it fails at call time with `NameError`.

Failing any of the three blocks merge.

### 4.4 Action Types

```python
Action = Emit | Route | Update | Spawn | Stop

@dataclass(frozen=True)
class Emit:
    adapter: str       # adapter ref name, e.g. "feishu"
    action: str        # adapter-level action name, e.g. "react"
    args: dict         # opaque to runtime, validated by adapter

@dataclass(frozen=True)
class Route:
    target: str        # actor_id to receive
    msg: Any           # payload (must be JSON-serialisable)

@dataclass(frozen=True)
class Update:
    # Explicit state update marker (rare — returning new State is default)
    patch: dict

@dataclass(frozen=True)
class Spawn:
    actor_type: str
    id: str
    adapter: str
    handler: str
    params: dict = field(default_factory=dict)

@dataclass(frozen=True)
class Stop:
    actor_id: str
```

> Terminology: `Emit` (an Action class, handler-authored) instructs the runtime to issue a "directive" (the IPC-envelope type, §7). They are the same concept at different layers — the `Emit` action, once accepted, becomes a `directive` over IPC.

### 4.5 State Shape

Per-actor state is a frozen pydantic model, declared alongside the handler:

```python
from esr import handler_state
from pydantic import BaseModel

@handler_state("cc_session")
class CCSessionState(BaseModel, frozen=True):
    session: str
    dedup: frozenset[str] = frozenset()
    feishu_peer: str | None = None

    def with_dedup_added(self, msg_id: str) -> "CCSessionState":
        return self.model_copy(update={"dedup": self.dedup | {msg_id}})
```

Runtime serialises state via pydantic for IPC and persistence.

---

## 5. Layer 3 — Adapter (Python)

### 5.1 Definition

An adapter is a pure factory that returns a stateful I/O object. The factory layer is testable as pure; the inner I/O is declared and bounded.

```python
from esr import adapter, AdapterConfig, Directive, Event

@adapter(name="feishu", allowed_io={"lark_oapi": "*", "http": ["open.feishu.cn"]})
class FeishuAdapter:

    @staticmethod
    def factory(actor_id: str, config: AdapterConfig) -> "FeishuAdapter":
        # factory MUST be pure: no network, no filesystem I/O.
        return FeishuAdapter(actor_id, config.app_id, config.app_secret)

    def __init__(self, actor_id: str, app_id: str, app_secret: str):
        self.actor_id = actor_id
        self._app_id = app_id
        self._app_secret = app_secret
        self._client = None  # lazy

    def client(self):
        if self._client is None:
            self._client = LarkClient(self._app_id, self._app_secret)
        return self._client

    async def on_directive(self, d: Directive) -> dict:
        match d.action:
            case "send_message":
                return await self.client().im.create(...)
            case "react":
                return await self.client().im.create_reaction(...)
            case _:
                raise UnknownDirective(d.action)

    async def emit_events(self):
        async for raw in self.client().ws_events():
            yield Event(source="feishu",
                        event_type=parse_type(raw),
                        args=parse_args(raw))
```

### 5.2 Capability Declaration

`allowed_io` declares every network host, every library used for I/O. CI scans the adapter module's actual imports and network calls; anything outside `allowed_io` fails the build. This replaces runtime sandboxing — the escape surface is narrowed to declared I/O, not zero I/O.

### 5.3 Directive / Event Semantics

- **Directive** (runtime → adapter): "perform this I/O". Adapter must execute or return error. Acked with `{id, result|error}`.
- **Event** (adapter → runtime): "external world did this". Has `source`, `event_type`, `args`. Fire-and-forget from adapter perspective; runtime persists before dispatch.

### 5.4 Lifecycle

`Esr.AdapterSupervisor` (Elixir) starts adapter processes. Each adapter instance serves one or more actors; the same Python module can run multiple instances with different configs (multiple Feishu apps, multiple tmux sessions).

Configure an instance via CLI:

```bash
esr adapter add feishu --app-id ... --app-secret ...
```

This records a named instance bound to the installed adapter type; the runtime spawns the corresponding process.

### 5.5 No Adapter Nesting — Use Topology

Adapters are **flat**. No adapter wraps another. When a scenario requires layered transport (e.g. "CC running inside a zellij pane"), express it at the **topology** level: declare two peer actors with an explicit `depends_on` dependency.

```python
@command("cc-on-zellij")
def cc_on_zellij():
    z_port = port.input("zellij_session", type="zellij_session")
    cc_port = port.output("cc_session", type="cc_session")

    z = node(id=z_port, actor_type="zellij_session",
             adapter="zellij", handler="zellij.on_msg")
    cc = node(id=cc_port, actor_type="cc_session",
              adapter="cc_in_zellij",       # a dedicated "CC inside zellij" adapter
              handler="cc_session.on_msg",
              depends_on=[z])                # explicit lifecycle dependency
    z >> cc
```

The "CC in zellij" case uses a dedicated `cc_in_zellij` adapter — peer to `cc_tmux`, `cc_docker`, etc. All belong to the same family (CC integration) but target different substrates. Choosing which variant to use is a topology-level decision, not an adapter-level stacking.

Rationale: transport stacking explodes complexity (infinite layering, hidden ordering, multiplied error handling). Topology composition already expresses the intent cleanly and matches ESR's graph-first model.

### 5.6 Installation & Registration

Install an adapter **module** (the type, not an instance) via:

```bash
esr adapter install <source>
```

`<source>` is one of:

- Local path: `./my-adapter/`
- Git URL: `https://github.com/org/esr-feishu-adapter.git`
- Python package name: `esr-feishu-adapter` (resolved via `uv` / `pip`)

Install flow:

1. Fetch / copy source into `adapters/`
2. Import module and validate `@adapter(...)` registration
3. Verify capability declaration (`allowed_io`) passes the CI scan
4. Register type in the project registry

After install, configure instances with `esr adapter add <name> <config>` (§5.4).

Symmetric ops: `esr adapter uninstall <name>`, `esr adapter upgrade <name>`, `esr adapter list --installed`.

Handler modules follow the same pattern via `esr handler install <source>`; there is no per-instance `add` step for handlers because they are stateless modules.

---

## 6. Layer 4 — Command (Python)

### 6.1 Definition

A Command is a named typed open-graph pattern:

- **Ports** — typed in/out boundaries, used for composition
- **Nodes** — actor declarations (type, handler, optional adapter, params)
- **Edges** — routing between nodes
- **Params** — variables substituted at instantiation

Commands are the unit of business-level composition. Running a Command instantiates and reconciles an actor graph.

**Command resolution by name.** The string passed to `@command(...)` is the canonical name used by all CLI operations (`esr cmd compile <name>`, `esr cmd run <name>`, etc.). The `.py` file location is implementation detail. Names are project-scoped and must be unique; duplicates fail registration with a clear error.

### 6.2 Authoring (Python EDSL — primary surface)

```python
from esr import command, node, port, compose

@command("feishu-to-core")
def feishu_to_core():
    src = port.input("src", type="feishu_chat")
    mid = port.output("mid", type="core_actor")

    n_src = node(
        id=src,
        actor_type="feishu_chat",
        adapter="feishu",
        handler="feishu_inbound.on_msg",
        params={"chat_id": "{{src.chat_id}}"},
    )
    n_mid = node(
        id=mid,
        actor_type="core_actor",
        handler="core_router.on_msg",
        params={"proxy_for": "{{src.chat_id}}"},
    )
    n_src >> n_mid


@command("core-to-cc")
def core_to_cc():
    mid = port.input("mid", type="core_actor")
    trg = port.output("trg", type="cc_session")

    n_mid = node(id=mid, actor_type="core_actor", handler="core_router.on_msg")
    n_trg = node(
        id=trg,
        actor_type="cc_session",
        adapter="cc_tmux",
        handler="cc_session.on_msg",
        params={"session": "{{trg.session_name}}"},
    )
    n_mid >> n_trg


@command("feishu-to-cc")
def feishu_to_cc():
    compose.serial(feishu_to_core, core_to_cc)


@command("cc-to-feishu")
def cc_to_feishu():
    # symmetric reverse path (cc_tmux → core_actor → feishu_chat)
    ...
```

### 6.3 Canonical YAML Artifact

`esr cmd compile feishu-to-cc` produces:

```yaml
# patterns/.compiled/feishu-to-cc.yaml
schema_version: esr/v0.1
name: feishu-to-cc
params:
  - {name: "src.chat_id",       type: string, required: true}
  - {name: "trg.session_name",  type: string, required: true}
ports:
  in:  [{name: src, type: feishu_chat}]
  out: [{name: trg, type: cc_session}]
nodes:
  - id: "feishu:{{src.chat_id}}"
    actor_type: feishu_chat
    adapter: feishu
    handler: feishu_inbound.on_msg
  - id: "core:{{src.chat_id}}-proxy"
    actor_type: core_actor
    handler: core_router.on_msg
  - id: "cc:{{trg.session_name}}"
    actor_type: cc_session
    adapter: cc_tmux
    handler: cc_session.on_msg
edges:
  - {from: "feishu:{{src.chat_id}}",        to: "core:{{src.chat_id}}-proxy"}
  - {from: "core:{{src.chat_id}}-proxy",    to: "cc:{{trg.session_name}}"}
```

**Optional node fields:**

- `depends_on: [<node_id>, ...]` — explicit lifecycle dependency. Listed nodes must be spawned before this one and must stay alive for its lifetime. Used for adapter substrate scenarios (§5.5). Dependencies form a DAG; cycles fail compilation.

Two artifacts per command:

- `patterns/<name>.py` — EDSL source, human-edited, diff-reviewed
- `patterns/.compiled/<name>.yaml` — CI-generated, reproducible, Elixir-consumed

### 6.4 Composition: Serial (v0.1 only)

`compose.serial(A, B)` matches A's output ports with B's input ports by name + type.

Rules:

- For each shared port name, types must be equal (or structurally compatible — subtype rules are a v0.2 concern)
- Shared ports merge into one node (CSE — §6.7)
- A's unmatched outputs and B's unmatched inputs become the composite's outputs/inputs respectively
- Unmatched ports at the top level of a runnable command are an error

Parallel and feedback are explicit non-goals for v0.1 (see `CHECKLIST.md`).

### 6.5 Instantiation

```
esr cmd run feishu-to-cc {
  "src.chat_id": "oc_abc",
  "trg.session_name": "alice-work"
}
```

Runtime:

1. Loads `feishu-to-cc.compiled.yaml`
2. Substitutes params; rejects if required params are missing
3. Sends the instantiated artifact to the Elixir runtime
4. Elixir spawns actors, binds adapter/handler, opens routes
5. Returns a handle for `esr cmd stop`

### 6.6 Compilation Pipeline

```
Python EDSL
    ↓
Pattern IR (in-memory graph)
    ↓  validate: type-check ports, no cycles (v0.1), all params declared
    ↓  optimize: dead-node elimination, CSE
Canonical YAML (source artifact)     ← diff-reviewed, committed
    ↓  (same output — no additional transform in v0.1)
Compiled YAML (.compiled)            ← CI-generated, reproducible
    ↓
Elixir runtime
```

Source and compiled differ only when optimisations introduce structural change (v0.1 rarely will; v0.2+ more).

### 6.7 Optimisation Passes (v0.1)

**Dead-node elimination** — any internal node (not a port) with no in-degree or no out-degree is removed.

**CSE (common subexpression elimination)** — when composing, nodes declared in both sub-patterns with identical (id, actor_type, handler) are merged into one. Required for correctness when two sub-patterns name the same middle node.

No other passes in v0.1.

### 6.8 Pattern Installation & Registration

Install a pattern module via:

```bash
esr cmd install <source>
```

`<source>` can be:

- Local path: `./my-pattern.py` or `./my-patterns/`
- Git URL: `https://github.com/org/my-patterns.git`
- Python package name: `esr-patterns-feishu`

Install flow:

1. Fetch source into `patterns/`
2. Import module; validate `@command(...)` registration exists
3. Resolve dependencies — every referenced adapter and handler must already be installed, otherwise fail with an actionable message (e.g. "command X references adapter `feishu` which is not installed; run `esr adapter install esr-feishu-adapter` first")
4. Compile: produce `patterns/.compiled/<name>.yaml`
5. Register name in the project registry

`esr cmd list` scans the registry and shows installed commands. `esr cmd run <name> <params>` resolves by name, loads the compiled artifact, instantiates.

Symmetric operations: `esr cmd uninstall <name>`, `esr cmd upgrade <name>`, `esr cmd show <name>` (pretty-prints the compiled artifact).

---

## 7. IPC Protocol

### 7.1 Transport

Phoenix Channels over WebSocket. One WS per Python process; many channels per WS, one topic per adapter/handler instance.

Topic taxonomy:

- `adapter:<name>/<instance_id>` — adapter ↔ runtime
- `handler:<module>/<worker_id>` — handler RPC ↔ runtime
- `telemetry:<bucket>` — read-only subscription for observers

### 7.2 Envelope

All payloads are JSON. Common fields: `id` (uuid), `ts` (RFC 3339), `type`, `payload`.

**directive (runtime → adapter):**

```json
{"id":"d-...","ts":"...","type":"directive",
 "payload":{"adapter":"feishu","action":"send_message",
            "args":{"chat_id":"oc_abc","content":"hi"}}}
```

**directive_ack (adapter → runtime):**

```json
{"id":"d-...","type":"directive_ack",
 "payload":{"ok":true,"result":{...}}}
```

**event (adapter → runtime):**

```json
{"id":"e-...","type":"event",
 "payload":{"source":"feishu","event_type":"msg_received",
            "args":{"chat_id":"oc_abc","content":"hi","sender":"ou_xxx"}}}
```

**handler_call (runtime → handler):**

```json
{"id":"h-...","type":"handler_call",
 "payload":{"handler":"cc_session.on_msg",
            "state":{...}, "event":{...}}}
```

**handler_reply (handler → runtime):**

```json
{"id":"h-...","type":"handler_reply",
 "payload":{"new_state":{...},
            "actions":[{"type":"emit","adapter":"feishu",...}]}}
```

### 7.3 Timeouts & Errors

- Handler call: default 5s (configurable per handler)
- Directive: default 30s (I/O heavy)
- Timeout → runtime emits `[:esr, :handler/directive, :timeout]`, returns error path to parent actor
- Connection loss: worker reconnects with exponential backoff; runtime queues pending work up to a cap; overflow logs and drops with telemetry

### 7.4 Ordering, Delivery, Dedup

- Runtime guarantees per-actor in-order dispatch
- Events may carry `idempotency_key`; runtime drops duplicates at ingestion
- Handler actions apply transactionally: state update + action emission = one unit; if persistence fails, actions are not emitted

### 7.5 Unified Naming (`esr://` URI)

Every addressable resource — actor, adapter, handler, command, interface — has a canonical URI. Short strings (e.g. `cc:sess-A`) are used internally for handler pattern-matching and compact logging. All cross-boundary references (remote adapter bindings, cross-process logs, debug output, future cross-org exposure) use the full `esr://` form.

**Grammar:**

```
esr://[org@]<host>[:port]/<type>/<id>[?params]

host: REQUIRED. Either a network name (e.g. "host.example", "laptop-2.local")
      or the literal "localhost". Empty host is NOT allowed — there is no
      implicit default. This rule avoids ambiguity when logs or config files
      cross machines.
type: ∈ {actor, adapter, handler, command, interface}
```

**Examples:**

```
esr://localhost/actor/cc:sess-A                   # local actor, host explicit
esr://localhost/adapter/feishu-shared             # local adapter instance
esr://localhost:4001/command/feishu-to-cc         # local, non-default port
esr://laptop-2.local:4000/adapter/zellij-5        # remote adapter over Phoenix channel
esr://allens-lab@host.example/interface/customer_inquiry  # cross-org (v0.2+)
```

Any URI with an empty host component is a syntax error and is rejected by the parser.

**v0.1 requirements:**

- URI parser + canonicaliser in `py/src/esr/uri.py`
- Types supported: `actor`, `adapter`, `command`
- Host is always explicit; `localhost` is the accepted name for the current machine
- `esr://<host>[:port]/adapter/<id>` addresses an adapter reachable via Phoenix channel on that host
- Two-way mapping: `uri_to_internal(uri) → {type, id}` and inverse `internal_to_uri(type, id, host="localhost") → uri` (caller supplies host)
- All public CLI output and telemetry fields that reference resources emit full URIs

**Deferred (v0.2+):**

- `@org` authentication semantics
- Cross-org interface exposure (Reposition §4 mode B, §5 `esr expose`)
- `?params` query-string semantics (e.g. `?ver=2` for versioning, `?node=N` for specific cluster node)
- `interface` type addressing

This section is normative: the canonical URI is what every cross-boundary component must speak. Short internal strings remain legal only inside a single process.

---

## 8. Project Structure

### 8.1 Top-level Layout

```
esr/
├── CHECKLIST.md                   # project goals + status (already created)
├── README.md
├── LICENSE
│
├── docs/
│   ├── design/                    # ESR v0.3 reference (read-only)
│   └── superpowers/specs/         # design specs (this file)
│
├── runtime/                       # Elixir application
│   ├── mix.exs
│   ├── config/
│   ├── lib/esr/
│   │   ├── application.ex
│   │   ├── peer_server.ex
│   │   ├── peer_supervisor.ex
│   │   ├── peer_registry.ex
│   │   ├── adapter_hub/
│   │   ├── handler_router/
│   │   ├── topology/
│   │   └── telemetry/
│   ├── lib/esr_web/               # Phoenix channels endpoint
│   └── test/
│
├── py/                            # Python SDK + CLI
│   ├── pyproject.toml
│   ├── src/esr/
│   │   ├── __init__.py
│   │   ├── handler.py             # @handler, State, Action types
│   │   ├── adapter.py             # @adapter, Directive, Event
│   │   ├── command.py             # @command, EDSL, compiler
│   │   ├── ipc/                   # Phoenix channels client
│   │   ├── cli/                   # `esr` command
│   │   └── verify/                # CI purity / capability checks
│   ├── tests/
│   └── examples/
│
├── handlers/                      # Shipped handler modules
│   ├── feishu_inbound/
│   ├── cc_session/
│   ├── core_router/
│   └── forward/
│
├── adapters/                      # Shipped adapter modules
│   ├── feishu/
│   ├── cc_tmux/
│   ├── llm/
│   └── voice/                     # (v0.2)
│
├── patterns/                      # Shipped command patterns
│   ├── feishu-to-core.py
│   ├── core-to-cc.py
│   ├── feishu-to-cc.py
│   ├── cc-to-feishu.py
│   └── .compiled/                 # CI-generated YAML artifacts
│
└── scenarios/                     # E2E test scenarios
    └── e2e-platform-validation.yaml
```

### 8.2 Packaging

- Elixir: `mix release --name esrd`
- Python: `uv build` for `esr` (SDK + CLI)
- Handlers / adapters / patterns: separate Python distributions, installable via `uv add esr-feishu-adapter` etc.

### 8.3 Deployment (single-node, v0.1)

```
one machine:
 - esrd release (Elixir) running
 - Phoenix endpoint at :4000
 - esr CLI on PATH
 - handlers / adapters launched as subprocesses by esrd (prod) or manually (dev)
```

---

## 9. E2E Platform Validation

### 9.1 Purpose

Validate the **platform**, not just a business scenario. Covers registration, scheduling, observability, operations, debugging, plus the bidirectional business round-trip and multi-session concurrency.

### 9.2 Tracks

Eight tracks. Each track gets one or more acceptance tests, defined in the implementation plan.

**Track A — Component Registration & Discovery**

- Register feishu + cc-tmux adapters via CLI
- Register handlers (feishu_inbound, cc_session, core_router)
- Register commands (feishu-to-cc, cc-to-feishu)
- `esr adapter list`, `esr handler list`, `esr cmd list`, `esr status` reflect expected state

**Track B — Scheduling & Multi-session Concurrency**

- Spawn 3 concurrent sessions with distinct (chat_id, session_name)
- `esr actors list` shows 9 actors (3 × {feishu, core, cc})
- `esr actors tree` shows 3 independent sub-trees

**Track C — Bidirectional Flow**

- Feishu → CC: a message in Feishu chat reaches the bound tmux session
- CC → Feishu: tmux output returns to the same Feishu chat
- Multiple round-trips within a single session remain causal and ordered

**Track D — Session Isolation**

- Message to session A is invisible to B, C
- Killing B's session tree does not affect A, C
- Contract violation (if induced) in A does not contaminate B, C traces

**Track E — Observability**

- `esr trace <cmd> --session <id>` produces time-ordered causal chain
- `esr telemetry subscribe "<topic>"` streams live events
- `esr actor inspect <id>` shows current state
- `esr actor logs <id> --follow` tails actor-scoped logs

**Track F — Operations**

- Stop single session cleanly
- Graceful `esr drain` for all sessions
- `esr restart <cmd> --session <id>` preserves state on restart

**Track G — Debug**

- `esr debug replay <message_id>` reproduces prior behaviour
- `esr debug inject --to <actor_id> <json>` pushes test messages
- `esr debug pause <actor_id>` and `resume` suspend/resume the actor
- `kill -9 <BEAM pid>` → OTP restarts; messageability restored within 5s

**Track H — Correctness & Consistency**

- For each session, `esr trace` shows exactly the edges declared in the compiled artifact — no extra, no missing
- `esr deadletter list` empty after run
- Every handler call's returned action list is a subset of the handler's declared action set (runtime-level check, not full contract verifier — see §11)
- Instantiating `patterns/<name>.py` and `patterns/.compiled/<name>.yaml` with the same params produces the same sequence of spawn / link calls

### 9.3 Success Gate

E2E passes when:

- Every track has at least one acceptance test passing
- 100 messages across 3 concurrent sessions: no loss, no duplicate
- Registration latency < 100 ms
- Message end-to-end p95 < 500 ms
- BEAM `kill -9` recovery to messageable ≤ 5 s
- `esr trace` produces full causal chain for each session
- Every handler emits only declared actions; `esr deadletter list` stays empty throughout

**Latency posture.** The numeric targets above are sanity checks (breach implies a likely defect), not SLOs. v0.1 **monitors** latency via telemetry timestamps at every IPC boundary, but does not **optimise** for it. Instrument from day one, sample p50/p95/p99 during each E2E run, archive results for trend analysis. Only trigger profiling and optimisation when a sanity threshold is breached. No preemptive latency work (batching, co-location, cost model, adapter placement) in v0.1 — YAGNI per §1.2.

Expected rough magnitudes (revise after measurement):

| Path | Target |
|---|---|
| Handler RPC round-trip (pydantic ser/de + Phoenix channel) | 3–20 ms |
| Adapter directive round-trip (excluding external I/O) | 2–10 ms |
| BEAM-internal message | < 0.1 ms |
| feishu-to-cc end-to-end (includes Feishu API) | 100–400 ms |

Bottlenecks are expected on the Python side (JSON ser/de, pydantic validation), not BEAM. Do not optimise until measurement contradicts this.

### 9.4 Reference Scenario File

`scenarios/e2e-platform-validation.yaml` describes setup, per-track steps, expected observations, and assertions. Runnable via `esr scenario run e2e-platform-validation`.

---

## 10. Migration Map (cc-openclaw → esr/)

### 10.1 Source → Destination

| cc-openclaw source | New location | Treatment |
|---|---|---|
| `channel_server/core/runtime.py` | `runtime/lib/esr/peer_server.ex`, `peer_supervisor.ex` | Rewritten in Elixir |
| `channel_server/core/actor.py` | Elixir structs under `Esr.Peer` | Rewritten |
| `channel_server/core/persistence.py` | `Esr.Persistence` (ETS + checkpoint) | Rewritten |
| `channel_server/core/handler.py` | `py/src/esr/handler.py` | Protocol reshaped to pure-fn signature |
| `channel_server/core/handlers/feishu.py` | `handlers/feishu_inbound/` | Refactored to pure fn |
| `channel_server/core/handlers/cc.py` | `handlers/cc_session/` | Refactored to pure fn |
| `channel_server/core/handlers/voice.py` | `handlers/voice_session/` | v0.2 |
| `channel_server/core/handlers/forward.py` | `handlers/forward/` | Refactored |
| `channel_server/adapters/feishu/*` | `adapters/feishu/` | Strip decision logic; keep I/O |
| `channel_server/adapters/cc/*` | `adapters/cc_tmux/` | Strip decision logic |
| `channel_server/commands/registry.py`, `dispatcher.py`, `scope.py`, `parse.py`, `context.py` | `py/src/esr/command.py` + `py/src/esr/cli/` | Reimplemented as EDSL + compiler + CLI |
| `channel_server/commands/builtin/spawn.py` | `patterns/feishu-to-cc.py` (+ reverse) | Reimagined as patterns |
| `channel_server/commands/builtin/kill.py` | `esr cmd stop` CLI | |
| `channel_server/commands/builtin/sessions.py` | `esr actors list` CLI | |
| `sidecar/*` | **unchanged in v0.1** | Runs alongside; migrate to ESR handlers in v0.2 |
| `voice_gateway/*` | **unchanged in v0.1** | Same |

### 10.2 Phasing

1. Elixir runtime skeleton (peer server, supervisor, registry, telemetry)
2. Python SDK (handler/adapter/command decorators) + CLI bones
3. IPC (Phoenix channels endpoint + Python client) + smoke test round-trip
4. Feishu adapter + CC-tmux adapter
5. Handlers: feishu_inbound, core_router, cc_session
6. Patterns: feishu-to-core, core-to-cc, feishu-to-cc, cc-to-feishu
7. CLI surface for Tracks A–H
8. E2E scenario file + run it; iterate until every Track passes

Exact PRDs and unit-test decomposition are the next artifact (implementation plan).

---

## 11. Open Questions (non-blocking)

These do not block v0.1 but need resolution before they bite:

- **Handler worker pool sizing.** One-per-handler-module vs shared pool? Default one-per-module for isolation; revisit under load.
- **State size limits.** State is serialised per handler call. Soft limit 64 KB; hard fail 1 MB? Needs measurement.
- **Explicit contract YAML.** v0.1 declares allowed actions inline via code. When does YAML contract per ESR §4 land?
- **Telemetry storage.** v0.1 uses BEAM memory only. When to persist externally? Likely when `esr trace` retention must exceed a process lifetime.
- **CLI auth.** No auth in v0.1 (single-user local). JWT / mTLS when multi-user.
- **Handler hot-reload.** In-place code swap without losing state? Deferred; restart is fine for v0.1.

Each becomes a follow-up spec when it starts mattering.

---

## 12. References

- [ESR Reposition v0.3 Final](../../design/ESR-Reposition-v0.3-Final.md)
- [ESR Protocol v0.3](../../design/ESR-Protocol-v0.3.md)
- [Socialware Packaging Spec v0.3](../../design/Socialware-Packaging-Spec-v0.3.md)
- [esrd Reference Implementation v0.3](../../design/esrd-reference-implementation-v0.3.md)
- [ESR Governance Guide v0.3](../../design/ESR-Governance-Guide-v0.3.md)

---

*End of ESR v0.1 Extraction Design.*
