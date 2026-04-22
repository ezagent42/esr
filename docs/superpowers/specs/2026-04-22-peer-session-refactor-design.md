# ESR Peer/Session Refactor Design (v3.1)

Author: brainstorming session with user (linyilun)
Date: 2026-04-22
Status: draft v3.1, awaiting user review
Relates to:
- `docs/superpowers/specs/2026-04-21-esr-dev-prod-isolation-design.md` (v2.2) — complementary, **not** replaced
- PR #11 (feature/dev-prod-isolation) — will receive rename surgery (PR-0) before merge
- GitHub issue #7 (MuonTrap/erlexec OS process wrapping) — absorbed into this refactor

**Change log**:
- v3.0 (initial): Peer/Session refactor scope; Peer behaviour layer + OSProcess底座; AdminSession model with PeerProxy pattern; SessionRouter as control plane; SessionRegistry as yaml-compiled topology + mapping source of truth; Python sidecar split (S3 scope). Replaces the misplaced SessionRouter from v2.2 Task 17.
- v3.1 (this doc): Code-reviewer subagent fact-check corrections to §2.9 broadcast table (3 topic names). Decisions Log added (§1.8) resolving all open questions. `Esr.PeerPool` default = 128 added. `SessionsSupervisor.max_children = 128` cap. `capabilities_required:` field added to `agents.yaml` schema (linked to existing capabilities v1). `--dir` mandatory at all layers (no auto-fill). Slash commands clarified as channel-agnostic (not Feishu-specific). Per-PR acceptance gates in §10.

---

## 1. Background & Scope

### 1.1 Why refactor

Implementing PR #11 (v2.2 spec) surfaced an architectural misalignment. Task 17's `Esr.Routing.SessionRouter` subscribes to a PubSub `msg_received` topic that no current publisher emits, making it a dead observer. The name "SessionRouter" also conflicts with its actual behaviour — it's a slash-command parser, not a routing actor.

Deeper investigation showed the underlying abstractions had drifted:

| Concept | Current reality | User's intended model |
|---|---|---|
| `PeerServer` | Per-peer GenServer frame with no Peer behaviour typing | Peer behaviour defining contracts (Stateful vs Proxy) |
| `SessionRegistry` | CC session ↔ WebSocket pid/metadata map | YAML-compiled topology + mapping single-source-of-truth |
| `SessionRouter` | Does not truly exist (feishu_app_proxy and Topology.Instantiator do half the job) | Control-plane decision-maker spawning/terminating peer chains |
| "Session" | Ambiguously = "CC-tmux instance" or "Feishu chat binding" | A complete human-AI collaboration workflow, composed of peers |
| Global peers | Special-cased ("singletons") scattered across supervisors | All peers belong to a Session; AdminSession holds global-scope peers |

This spec documents the target architecture, the migration path, and the decommissioning list.

### 1.2 Relationship to v2.2 spec and PR #11

v3.0 **does not replace** v2.2. The two are complementary:

- **v2.2 scope remains valid**: launchd plists, `esr-branch.sh`, Admin subsystem shape, `Esr.Paths`, `admin_queue/` layout, queue file atomic transitions. These ship via PR #11 as currently implemented.
- **v3.0 scope**: Peer/Session abstractions, OSProcess底座, SessionRouter/Registry/Factory control plane, AdminSession + PeerProxy pattern, Python sidecar split. Ships via PR-1..PR-5 after PR #11 merges.
- **PR #11 transitional change (PR-0)**: rename misplaced `Esr.Routing.SessionRouter` → `Esr.Routing.SlashHandler` (behaviour unchanged). This prevents "architecturally wrong name" from landing on `main`.

### 1.3 In scope

1. **Peer behaviour layer**: `Esr.Peer`, `Esr.Peer.Proxy`, `Esr.Peer.Stateful` behaviours. `Esr.PeerServer` is retained as one implementation; new Peer types (`FeishuChatProxy`, `CCProxy`, etc.) are added atop the behaviour.
2. **OSProcess底座**: `Esr.OSProcess` behaviour + `Esr.TmuxProcess` + `Esr.PyProcess` implementations via MuonTrap.
3. **Control plane**: three modules with strict separation — `Esr.PeerFactory` (creation mechanics), `Esr.SessionRouter` (lifecycle decisions), `Esr.SessionRegistry` (yaml compiler + mapping queries).
4. **AdminSession model**: global-scope peers belong to AdminSession; user Sessions access them via PeerProxy.
5. **Agent definitions**: `agents.yaml` describing composable agents (`cc`, `cc-voice`, `voice-e2e`, future `gemini-cli`). `/new-session --agent <name>` spawns the declared peer pipeline.
6. **Python sidecar split (S3 scope)**: `voice-gateway` → `voice-asr` / `voice-tts` / `voice-e2e`; `adapter_runner` → per-adapter-type sidecars. All Python processes wrapped by `Esr.PyProcess`底座.
7. **Decommissioning**: `AdapterHub.Registry`, `Workspaces.Registry` / `Topology.Instantiator` overlapping responsibilities, `feishu_app_proxy`-like ad-hoc forwarders, old session-id-from-ws-pid `SessionRegistry` (rename to `SessionSocketRegistry` or absorb into Session.state), and all free `Phoenix.PubSub.broadcast` sites that bypass control plane.

### 1.4 Out of scope (permanent)

- **Cross-esrd peer routing**: redirecting a message to a peer hosted in a different esrd process. `routing.yaml`'s `principals.targets` schema is allowed at the config layer but the runtime **must not** execute cross-esrd dispatch.
- **Replacing the sidecar IPC mechanism**: JSON-over-stdin with MuonTrap stays. No move to gRPC / Unix sockets / shared memory in this refactor.
- **GUI / admin web panel**: CLI + channel-delivered slash commands remain the only interfaces.
- **New adapter types or handler types**: this is a refactor, not a feature. Adding gemini-cli, codex, or other agent implementations happens in follow-up specs.

### 1.5 Out of scope (deferred to follow-up)

- **Multi-agent sessions**: one esr-session owns exactly one agent type. Compositions like "CC + voice" are handled by declaring a new agent (e.g., `cc-voice`), not by layering.
- **Cross-session peer interactions** (e.g., a hypothetical `/fork-session` that copies state from A to B): out of this refactor. If introduced later, the PeerProxy pattern is the natural hook.
- **Persistence of session state to disk for warm restart**: SessionProcess snapshots are future work; within this refactor, a crashed esrd loses session state on restart (existing behaviour).

### 1.6 Non-goals

- **Zero-downtime migration**: the refactor lands in a sequence of PRs. Between PR-2 and PR-3, Feishu paths use the new chain while CC paths use the old chain — brief transitional state is acceptable.
- **Backwards-compatible API for Admin commands**: `session_new` Admin command's shape changes (gains `agent` field). CLI users who invoked `esr session new` pre-refactor will see a breaking change and a new `--agent` requirement.

### 1.7 Terminology

- **Peer**: an actor (GenServer or Supervisor-of-GenServer) that implements one of the `Esr.Peer.*` behaviours. Every Peer belongs to exactly one Session.
- **Peer.Proxy**: a Peer subtype that is a stateless forwarder. Compile-time restricted to `forward/2` semantics; cannot hold business state.
- **Peer.Stateful**: a Peer subtype that owns state (mailbox, in-memory data, optionally an OS process).
- **OSProcess底座**: `Esr.OSProcess` behaviour providing OS-process lifecycle (spawn via MuonTrap, monitor, signal, kill). Used via composition: `defmodule TmuxProcess, do: use Esr.Peer.Stateful; use Esr.OSProcess, kind: :tmux`.
- **esr-session** (or just "Session"): a supervisor subtree representing one complete human-AI collaboration workflow. Identified by a ULID (`session_id`). Contains a `SessionProcess` GenServer + the Peer subtree defined by the session's agent.
- **AdminSession**: the one always-on Session (`session_id = "admin"`) that hosts global-scope peers (FeishuAppAdapter, SlashHandler, voice pools, etc.).
- **Agent**: a user-facing composite primitive declared in `agents.yaml`. One agent name → one peer pipeline. Examples: `cc`, `cc-voice`, `voice-e2e`.
- **Peer chain / peer pipeline**: the ordered list of peers that make up a session, declared by the session's agent.
- **PeerProxy**: a `Peer.Proxy` instance inside a user Session whose `target` is a peer living in AdminSession (or, in future, another user Session). It is the only way a session reaches outside its own subtree.
- **Control plane**: the three modules `PeerFactory`, `SessionRouter`, `SessionRegistry`. They manage Peers. They are **not** themselves Peers.
- **Data plane**: every runtime message that flows Peer→Peer. Control plane is never on the data plane hot path.

### 1.8 Decisions Log

Resolved during brainstorming; frozen for this spec.

| # | Topic | Decision |
|---|---|---|
| D1 | OSProcess placement | Composition底座 (`use Esr.OSProcess`), not a sibling Peer subtype. See §3.2. |
| D2 | PR #11 fate | Rename surgery (SessionRouter → SlashHandler) then merge, main refactor on new branch. See §9 PR-0. |
| D3 | Refactor depth | Full: merge AdapterHub.Registry into SessionRegistry, ban free PubSub broadcasts (except listed sites), introduce OSProcess底座 now. See §2.9. |
| D4 | Session structure | User Sessions = Supervisor subtrees with private peers; AdminSession holds globals. No "global peer" category. See §3.4. |
| D5 | Issue #7 scope | Absorbed into this refactor. TmuxProcess + all Python sidecars get MuonTrap-based OSProcess底座. See §3.2 + §8. |
| D6 | Python sidecar split (S3) | Split `voice-gateway` → voice-asr / voice-tts / voice-e2e; split `adapter_runner` → per-adapter-type. See §8. |
| D7 | `cc_adapter_runner` lifecycle | **Per-session**, not per-esrd. One Session → one tmux → one cc_adapter_runner Python process. See §8.2. |
| D8 | PeerFactory / SessionRouter / SessionRegistry separation | Three modules, strict role separation. See §3.3. |
| D9 | PeerProxy pattern | All cross-session peer access via local `Peer.Proxy`; static target resolved at session spawn. See §3.6. Two exceptions: voice pool (§4.1) and slash-handler fallback (§5.3). |
| D10 | Agent definitions | User-facing primitive. One agent = one declared peer pipeline in `agents.yaml`. No flag-based composition (e.g., no `--voice`). Example: to add "CC with voice I/O", define a `cc-voice` agent, not a `--voice` flag on `cc`. See §3.5. |
| D11 | `/new-session` default agent | None. `--agent` is mandatory; missing it returns an error with hint "see /list-agents". |
| D12 | `/new-session` single-agent | One agent per session. Multi-agent sessions out of scope. |
| D13 | `--dir` required at all layers | CLI does NOT auto-fill `$pwd`. Feishu does not auto-fill. Admin.Dispatcher rejects commands without `--dir` when agent declares `dir` required. |
| D14 | Slash is channel-agnostic | `/new-session`, `/end-session`, `/list-*` are slash commands processed by `AdminSession.SlashHandler` regardless of inbound channel. Each channel's ChatProxy detects slash syntax and forwards to `SlashHandler`. Current channels: Feishu. Future channels (Slack, CLI tty): same SlashHandler, different ChatProxy. |
| D15 | `session_new` Admin command | Breaking change accepted; gains `agent` field; no backwards-compat shim. |
| D16 | PeerPool default size | **128** workers per pool (in `Esr.PeerPool` module). `pools.yaml` is optional; absent pool entries inherit the default. yaml only appears when overriding. |
| D17 | SessionsSupervisor max_children | **128** concurrent user Sessions per esrd (`max_children: 128` on DynamicSupervisor). Each user Session owns one tmux → tmux count ≤ 128. |
| D18 | `capabilities_required` in agents.yaml | Linked to existing capabilities v1. Declaring the capability set an agent needs is **mandatory** per agent entry. Admin.Dispatcher verifies the invoking principal holds all listed capabilities before creating the Session. Permissions use the canonical `prefix:name/perm` shape enforced by `Esr.Capabilities.Grants.matches?/2` — e.g. `session:default/create`, `tmux:default/spawn`, `handler:cc_adapter_runner/invoke`, `peer_proxy:feishu/forward`, `peer_pool:voice_asr/acquire`. The dotted `cap.*` form from earlier drafts is not supported. See §3.5 and `docs/notes/capability-name-format-mismatch.md`. |
| D19 | Reserved field names in agents.yaml | `rate_limits`, `timeout_ms`, `allowed_principals` are reserved. Schema validator warns if they appear (not implemented yet). Prevents future schema-break when these features arrive. |
| D20 | TmuxProcess mode | Use `tmux -C` control mode (per issue #7 recommendation). TmuxProcess parses tmux control protocol events (`%output`, `%window-close`, `%exit`). See §3.2 + §4.1 TmuxProcess card. |
| D21 | Per-PR acceptance gates | Each PR has explicit test gates (§10.5). CI must pass each gate before PR is mergeable. |

### 1.9 Out-of-scope (deferred, may revisit)

Listed for transparency — these came up in brainstorming and were judged out-of-scope for this refactor:

- **Schema evolution tooling for `agents.yaml`** — migrating user's agents.yaml when schema changes. Today: add new field + reserved-names policy + tests. Future: a `esr agents migrate` CLI command.
- **Session persistence across esrd restart** — snapshot SessionProcess state to disk, reattach OS processes on boot.
- **Dynamic capability grants mid-session** — today capabilities are checked at session creation; runtime grant changes apply to new sessions only.
- **Per-session resource quotas** (CPU/memory/disk) — relies on OS cgroups, out of current scope.
- **Cross-session message forwarding** (e.g., `/fork-session A B`) — PeerProxy pattern is the natural hook if ever needed.

---

## 2. Gap Analysis (current → target)

Each row: what exists today, its location, what changes.

### 2.1 Per-peer actors

| Aspect | Current (`runtime/lib/esr/peer_server.ex`) | Target |
|---|---|---|
| Identity | GenServer with `actor_id`, `actor_type`, `handler_module` | Same identity, but typed via `Esr.Peer.Stateful` behaviour |
| Supervision | `Esr.PeerSupervisor` (DynamicSupervisor, `:one_for_one`) | Per-peer-type DynamicSupervisors under `GlobalPeersSupervisor` (AdminSession) or under each Session's Supervisor |
| Behaviour contract | None — `handler_module` is a duck-typed dispatch target | `@behaviour Esr.Peer.Stateful` with typed callbacks (`handle_peer_msg/2`, `handle_upstream/2`, `handle_downstream/2`) |
| Broadcasts | `peer_server.ex` uses `EsrWeb.Endpoint.broadcast/3` to `adapter:<name>/<instance_id>` topics for directive emit; subscribes to `directive_ack:<id>` on PubSub for correlation | Only telemetry broadcasts allowed freely; Peer→Peer messages flow via direct `send/cast` on neighbor refs (injected at spawn); directive_ack correlation retained for Python worker interaction |

### 2.2 Peer registry

| Aspect | Current (`Esr.PeerRegistry`) | Target |
|---|---|---|
| Purpose | `actor_id` → `pid` via Elixir `Registry` | Same mechanism, but keyed by `(session_id, peer_name)` tuple; global keys under `session_id = "admin"` |
| Scope | Global flat namespace | Two-level: session-scoped + admin-scoped |
| Drift risk | Actor IDs are strings generated per caller — possible collisions | Spec-mandated convention: `{session_id}::{peer_name}` (colons reserved) |

### 2.3 Session registry (the name conflict)

| Aspect | Current (`Esr.SessionRegistry`) | Target |
|---|---|---|
| Purpose | `actor_id` → `{ws_pid, chat_ids, app_ids, workspace, principal_id, status, last_seen_ms}` | Rename to **`Esr.SessionSocketRegistry`** (same role, clearer name); the name `Esr.SessionRegistry` is freed for the new yaml-compiler role |
| New role for freed name | — | `Esr.SessionRegistry`: holds `agents.yaml`-compiled agent definitions, `(chat_id, thread_id) → session_id` mapping, `(session_id, peer_name) → peer_ref` lookup, yaml hot-reload |
| Consumers | CC-side channel (`runtime/lib/esr_web/cc_channel.ex`), `notify_session/2` | CC channel uses renamed `SessionSocketRegistry`; new `SessionRegistry` consumed by `SessionRouter` + Peers (neighbor-ref lookup) |

### 2.4 AdapterHub

| Aspect | Current (`runtime/lib/esr/adapter_hub/`) | Target |
|---|---|---|
| `AdapterHub.Registry` | `adapter:<name>/<instance_id>` → `actor_id` binding (GenServer + ETS) | **Removed**. Its function (mapping adapter instances to actors) is subsumed by `SessionRegistry` (peer_ref lookup) |
| `AdapterHub.Supervisor` | Scaffolds `Registry` (and future children) | Removed; any retained children move under `AdminSession` supervisor |

### 2.5 Workspaces

| Aspect | Current (`runtime/lib/esr/workspaces/registry.ex`) | Target |
|---|---|---|
| Purpose | In-memory cache of `workspaces.yaml` | Kept as-is for workspace metadata (dir, name, policy flags). No structural refactor — workspace is data, not a peer |
| Rename | — | None |

### 2.6 Topology

| Aspect | Current (`runtime/lib/esr/topology/`) | Target |
|---|---|---|
| `Topology.Registry` | Tracks live topology instantiations by `(name, params)` | Merged into `SessionRegistry` (a Session is the unit that Topology used to track) |
| `Topology.Instantiator` | Spawn pipeline: validate params → substitute `{{param}}` → Kahn toposort → spawn PeerServers in order → bind adapters | Role absorbed by `SessionRouter.create_session/2` + `PeerFactory`. Topology yaml evolves into `agents.yaml` with per-agent peer pipelines |
| `Topology.Supervisor` | — | Removed |

### 2.7 Routing

| Aspect | Current (`runtime/lib/esr/routing/session_router.ex`) | Target |
|---|---|---|
| Actual role | Slash-command parser + forwarder to `Admin.Dispatcher`; subscribes `msg_received` (no publisher exists) | **PR-0 rename**: → `Esr.Routing.SlashHandler`, behaviour unchanged |
| New `Esr.SessionRouter` (control plane) | — | Created fresh. Not under `Esr.Routing.*`; sits at top-level `Esr.SessionRouter`. Listens for topology events (new chat arrives, session end) and invokes `PeerFactory` to spawn/terminate peer chains |
| Forward semantics | Non-slash messages: lookup `routing.yaml` → broadcast `{:forward, envelope}` on `route:<esrd_url>` topic | **Removed**. Non-slash routing lives in FeishuChatProxy + chain; cross-esrd routing is permanently out of scope |

### 2.8 Handler router

| Aspect | Current (`runtime/lib/esr/handler_router.ex`) | Target |
|---|---|---|
| Purpose | Dispatches `handler_call` to Python workers via Phoenix channels, awaits reply by ID | Retained for Python handler invocations but consumed by specific Peer types (e.g., CCProcess may call HandlerRouter). It is not itself a Peer |
| Rename | — | None (HandlerRouter is an internal utility, not a structural component) |

### 2.9 Free PubSub broadcasts

Current data-plane broadcasts (outside telemetry) are enumerated here and must be collapsed:

| Site | Mechanism + topic | Purpose | Target |
|---|---|---|---|
| `peer_server.ex` | `EsrWeb.Endpoint.broadcast/3` on `adapter:<name>/<instance_id>` | Emit directive to Python adapter worker via Phoenix channel | Retained (worker still reachable via Phoenix channel) — but the Peer-side initiating the broadcast moves into the appropriate Peer module (CCProcess, etc.) |
| `peer_server.ex` | `Phoenix.PubSub.subscribe/broadcast` on `directive_ack:<id>` | Correlate directive acknowledgements from workers | Retained — correlation protocol between Peer and Python worker |
| `handler_router.ex` | `EsrWeb.Endpoint.broadcast` on `handler:<module>/<worker_id>` + PubSub `handler_reply:<id>` | RPC to Python handler + reply correlation | Retained (HandlerRouter stays as worker RPC utility) |
| `routing/session_router.ex` | `Phoenix.PubSub.subscribe` on `msg_received` (no publisher); `broadcast` on `route:<esrd_url>` + fixed topic `feishu_reply` | Parse slash + forward | `SlashHandler` keeps only `feishu_reply` broadcast for slash results (for now) |
| `topology/instantiator.ex` | Python-callback coordination via PubSub | Spawn pipeline async signalling | Removed with Topology module; PeerFactory's `spawn_peer/5` is synchronous |

After refactor, the legitimate broadcast patterns are:
- Telemetry (`:telemetry` preferred; `PubSub` allowed for dev dashboards)
- `HandlerRouter` RPC: `EsrWeb.Endpoint.broadcast` on `handler:<module>/<worker_id>` + PubSub `handler_reply:<id>`
- `PeerServer.ex`-style `Endpoint.broadcast` to `adapter:<name>/<instance_id>` for Python worker communication (the site moves into specific Peer modules like `CCProcess`; the pattern is retained)
- `SlashHandler` slash-result broadcast on fixed topic `feishu_reply` (for CLI display)

Every other broadcast must be converted to Peer-to-Peer `send/cast` via neighbor refs. In particular, the `msg_received` PubSub subscription in `session_router.ex` is deleted (no publisher exists; it's inert), and `route:<esrd_url>` is deleted (cross-esrd routing is permanently out of scope).

### 2.10 Estimated footprint

- **Files deleted**: ~6 (AdapterHub.Registry + Supervisor, Topology.Registry + Instantiator + Supervisor, old feishu_app_proxy-like pieces)
- **Files added**: ~20 (Peer behaviours ×3, OSProcess底座 ×3, PeerFactory, SessionRegistry (new role), SessionRouter (new), AdminSession, Session, 10 peer implementations)
- **Files modified**: ~15 (PeerServer, SessionRegistry-renamed, cc_channel, feishu endpoints, Admin.Commands.Session.*, application.ex, etc.)
- **Test files touched**: ~60 (existing test suite references renamed modules; N>1 scaling tests added)

---

## 3. Target Architecture

### 3.1 Peer behaviour layer

Three behaviours define the Peer contract. Each peer module declares exactly one.

**`Esr.Peer` (base, private)** — shared macros, metadata. Not declared directly by user modules; accessed via `use Esr.Peer.Proxy` or `use Esr.Peer.Stateful`.

**`Esr.Peer.Stateful`** — Peers with state and/or side effects.

```elixir
@callback init(peer_args :: map()) :: {:ok, state :: term()} | {:stop, reason :: term()}
@callback handle_upstream(msg :: term(), state :: term()) ::
  {:forward, [msg :: term()], new_state :: term()}
  | {:reply, msg :: term(), new_state :: term()}
  | {:drop, reason :: atom(), new_state :: term()}
@callback handle_downstream(msg :: term(), state :: term()) ::
  {:forward, [msg :: term()], new_state :: term()}
  | {:drop, reason :: atom(), new_state :: term()}
```

`upstream` = closer to external systems (Feishu, user-facing). `downstream` = closer to the agent core (tmux, CC). Every Peer.Stateful knows its neighbor refs (injected at spawn) and calls `send/2` on them directly. No centralised router reads these messages.

**`Esr.Peer.Proxy`** — stateless forwarder with compile-time restricted surface.

```elixir
@callback forward(msg :: term(), proxy_ctx :: map()) :: :ok | {:drop, reason :: atom()}
```

A Peer.Proxy module **must not** define `handle_call/3`. The `use Esr.Peer.Proxy` macro emits a compile error if one is present. This enforces "proxies never accumulate state".

**Authorisation hook**: every Peer.Proxy automatically wraps `forward/2` in a capability check — the `proxy_ctx.principal_id` must hold the permission declared by the Peer.Proxy module's `@required_cap` attribute (canonical `prefix:name/perm` shape, e.g. `peer_proxy:feishu/forward`). The check happens per-call, using `Esr.Capabilities.has?/2`.

### 3.2 OSProcess底座

`Esr.OSProcess` is a behaviour (not a Peer type — it is a **composition mixin** used alongside `Peer.Stateful`).

```elixir
@callback start_os_process(opts :: keyword()) ::
  {:ok, pid :: pid(), os_pid :: non_neg_integer()} | {:error, reason :: term()}
@callback os_cmd(state :: term()) :: [String.t()]
@callback os_env(state :: term()) :: [{String.t(), String.t()}]
@callback on_os_exit(exit_status :: non_neg_integer(), state :: term()) ::
  {:restart, new_state :: term()} | {:stop, reason :: term()}
```

Implementation backs onto MuonTrap:

- `Esr.TmuxProcess` — wraps `tmux -C new-session -d -s <name> -c <dir>` (control mode, per D20). Control mode gives a bi-directional protocol with tagged events (`%output`, `%window-close`, `%exit`) instead of raw ANSI escape parsing. MuonTrap owns the stdin/stdout to the control-mode client and guarantees OS cleanup on actor exit.
- `Esr.PyProcess` — wraps `uv run python -m <sidecar_module>`. Provides stdin/stdout JSON-line protocol to Python code. One `PyProcess` = one Python OS process.

Composition pattern inside a Peer:

```elixir
defmodule Esr.Peers.TmuxProcess do
  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :tmux

  @impl Esr.Peer.Stateful
  def handle_downstream({:send_input, text}, state) do
    # Control-mode command: send-keys to the active pane
    cmd = "send-keys -t #{state.session_name} \"#{escape(text)}\" Enter\n"
    :ok = os_write(state, cmd)
    {:forward, [], state}
  end

  @impl Esr.OSProcess
  def os_cmd(state) do
    ["tmux", "-C", "new-session", "-d", "-s", state.session_name, "-c", state.dir]
  end

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state) when status > 0, do: {:stop, {:tmux_crashed, status}}

  # Parse tmux control protocol events from MuonTrap stdout
  def handle_info({:os_stdout, line}, state) do
    case parse_control_event(line) do
      {:output, pane_id, bytes} -> {:forward, [{:tmux_output, bytes}], state}
      {:exit, _status}          -> {:stop, :tmux_exited}
      _other                    -> {:forward, [], state}
    end
  end
end
```

The `use Esr.OSProcess, kind: :tmux` macro injects MuonTrap child-spec handling, monitors, and provides `os_write/2` / `os_signal/2` helpers.

**Scope clarification**: every Python sidecar (per §7 S3 split) uses `PyProcess`; tmux uses `TmuxProcess`. Other OS processes (launchd-launched esrd itself, voice-gateway as a whole) are NOT wrapped by OSProcess底座 — they are at a different lifecycle tier (launchd-supervised, not Elixir-supervised).

### 3.3 Control plane: three separated modules

```
Esr.PeerFactory      — creation mechanics (thin DynamicSupervisor.start_child wrapper)
Esr.SessionRouter    — control-plane decisions (when/what to spawn/terminate)
Esr.SessionRegistry  — yaml-compiled data + mappings (single source of truth)
```

**Hard rules**:

1. `PeerFactory` **must not** contain any routing/lookup/decision logic. Only: validate args, consult `SessionRegistry` for neighbor refs to inject, call `DynamicSupervisor.start_child/2`, emit telemetry. If a function in PeerFactory reads a peer's mailbox or decides what peer to spawn next, it has drifted.
2. `SessionRouter` **must not** be on the data-plane hot path. It reacts to events (topology changes, session lifecycle), not to per-message traffic.
3. `SessionRegistry` **must not** hold mutable session state that belongs to `SessionProcess`. It holds: compiled yaml artifacts, `(chat_id, thread_id) → session_id` mapping, `(session_id, peer_name) → pid` lookup, subscriptions to yaml file changes. Read-heavy; writes happen only on spawn/terminate events.

**Interaction pattern** (creating a session):

```
External trigger (new Feishu chat, /new-session slash command)
  → SessionRouter.create_session(agent_name, params)
    → SessionRegistry.lookup_agent(agent_name) → {:ok, agent_def}
    → generate session_id (ULID)
    → SessionRouter:
        - DynamicSupervisor.start_child(SessionsSupervisor, {Session, session_id})
        - For each peer in agent_def.pipeline.inbound (topologically ordered):
            PeerFactory.spawn_peer(session_id, peer_name, peer_impl, neighbor_refs)
        - SessionRegistry.register_session(session_id, peer_refs, chat_thread_key)
  → return {:ok, session_id}
```

### 3.4 AdminSession model

There is no "global peer" category. Every peer belongs to a Session. AdminSession is the one always-on Session that hosts peers serving session-less concerns (external edge, cross-session handlers, shared pools).

```
AdminSession (Supervisor, :one_for_one, :permanent)
├── AdminSessionProcess (GenServer)
│   └── holds: admin-level capabilities, bootstrap metadata
├── FeishuAppAdapter_<app_id>         (Peer.Stateful, one per app in adapters.yaml)
├── SlashHandler                       (Peer.Stateful, one, channel-agnostic)
├── VoiceASR pool supervisor           (Esr.PeerPool, max=128 default)
│   └── dynamically allocated VoiceASR (Peer.Stateful + PyProcess)
├── VoiceTTS pool supervisor           (Esr.PeerPool, max=128 default)
│   └── dynamically allocated VoiceTTS (Peer.Stateful + PyProcess)
```

**Bootstrap invariant**: `AdminSession` is the one Session started **outside** SessionRouter/PeerFactory. It is a child of `Esr.Supervisor` (top-level application supervisor) and starts at boot with hardcoded children. This is the only exception to "all sessions created via SessionRouter".

**AdminSession never terminates under normal operation.** If it crashes, the entire esrd crashes (intentional — loss of external edge is unrecoverable without restart).

**`Esr.PeerPool` module (new)**: provides a DynamicSupervisor-based pool for `Peer.Stateful` workers.
- Default `max_workers: 128` (compile-time constant in `Esr.PeerPool`).
- Optional `pools.yaml` (same directory as `agents.yaml`) can override per-pool limits. Entries are merged with defaults; unnamed pools use the default without appearing in yaml.
- Pool members are interchangeable (no sticky session); clients acquire via `PeerPool.acquire/2` and release via `PeerPool.release/2`.
- Overflow strategy default: `:block` with 5s timeout → `{:error, :pool_exhausted}`.

**`SessionsSupervisor` concurrency cap**: started as a `DynamicSupervisor` with `max_children: 128`. A `/new-session` beyond the cap returns `{:error, :session_limit_reached}` (surfaced to the user as a slash reply). Each user Session owns exactly one tmux, so this cap also bounds concurrent tmux sessions at 128.

### 3.5 esr-session composition and Agent definitions

A user Session is a structured supervisor subtree declared by its agent's pipeline in `agents.yaml`.

```
Session_<ulid> (Supervisor, :one_for_all, :transient)
├── SessionProcess (GenServer, :permanent)
│   └── holds: session_id, agent_name, dir binding, chat_thread_key, capability grants, session state
├── <peers per agent.pipeline>          (Peer.Stateful / Peer.Proxy, :transient)
```

**Restart policy**:
- `SessionProcess` is `:permanent` — if it dies the supervisor restarts it (core state recovered from its `init_args`).
- Other peers are `:transient` — abnormal exit does NOT auto-restart; instead SessionRouter observes the crash (via `Process.monitor`) and decides whether to rebuild the chain. Reason: peer chain state is interdependent; partial restart breaks invariants.
- `:one_for_all` strategy means if any `:permanent` child dies beyond restart intensity, the entire Session dies, taking its subtree (and its OS processes via MuonTrap) with it. Session-owned OS processes thus have guaranteed cleanup.

**`agents.yaml` schema** (proposed):

```yaml
# ${ESRD_HOME}/${ESR_INSTANCE}/agents.yaml
agents:
  cc:
    description: "Claude Code in tmux, text I/O"
    capabilities_required:                   # mandatory; verified at /new-session time
      - session:default/create
      - tmux:default/spawn
      - handler:cc_adapter_runner/invoke
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Peers.FeishuChatProxy
        - name: cc_proxy
          impl: Esr.Peers.CCProxy
        - name: cc_process
          impl: Esr.Peers.CCProcess
        - name: tmux_process
          impl: Esr.Peers.TmuxProcess
      outbound:
        - tmux_process
        - cc_process
        - cc_proxy
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Peers.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
    params:
      - name: dir
        required: true                       # must be provided at /new-session
        type: path
      - name: app_id
        required: false
        default: "${primary_feishu_app}"
        type: string

  cc-voice:
    description: "CC + voice I/O (voice in → ASR → CC → TTS → voice out)"
    capabilities_required:
      - session:default/create
      - tmux:default/spawn
      - handler:cc_adapter_runner/invoke
      - peer_pool:voice_asr/acquire
      - peer_pool:voice_tts/acquire
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Peers.FeishuChatProxy
        - name: voice_asr
          impl: Esr.Peers.VoiceASR
        - name: cc_proxy
          impl: Esr.Peers.CCProxy
        - name: cc_process
          impl: Esr.Peers.CCProcess
        - name: tmux_process
          impl: Esr.Peers.TmuxProcess
      outbound:
        - tmux_process
        - cc_process
        - cc_proxy
        - voice_tts
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Peers.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
      - name: voice_asr
        impl: Esr.Peers.VoiceASRProxy
        target: "admin::voice_asr_pool"
      - name: voice_tts
        impl: Esr.Peers.VoiceTTSProxy
        target: "admin::voice_tts_pool"
    params:
      - name: dir
        required: true
        type: path

  voice-e2e:
    description: "End-to-end voice LLM; agent as side-input, no CC"
    capabilities_required:
      - session:default/create
      - handler:voice_e2e/invoke
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Peers.FeishuChatProxy
        - name: voice_e2e
          impl: Esr.Peers.VoiceE2E
      outbound:
        - voice_e2e
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Peers.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
    params: []
```

**Key properties of the schema**:
- `capabilities_required` is **mandatory** for every agent. Admin.Dispatcher calls `Esr.Capabilities.has_all?/2` against the invoking principal before creating the Session. If any capability is missing, `/new-session` fails with `{:error, {:missing_capabilities, [cap_names]}}` and the Session is NOT created.
- `inbound` and `outbound` are **separate ordered lists**. Non-symmetric chains (cc-voice) require this.
- `proxies` declares every cross-session peer access. `target` is a static string (not a runtime-evaluated expression). `${app_id}` and similar are expanded at session-spawn time, not at each message.
- `params` are validated at `/new-session` time against the session's requested agent. `required: true` params must be present; no auto-fill by any layer.
- Adding a new agent = adding a yaml entry (and the necessary `Esr.Peers.*` implementation modules if they don't exist). No SessionRouter code changes.

**Reserved field names (not implemented, warned-on-presence)**:
- `rate_limits` — per-session rate limiting. Reserved for future.
- `timeout_ms` — session idle timeout. Reserved for future.
- `allowed_principals` — principal allowlist (separate from capability system). Reserved for future.

The schema validator logs a WARN if any of these appears in a user's agents.yaml (prevents name squatting before feature lands).

**Slash commands (channel-agnostic)**: slash syntax is processed by `AdminSession.SlashHandler` regardless of inbound channel. Each channel's ChatProxy detects slash syntax (e.g., `FeishuChatProxy` detects leading `/` in Feishu text messages) and forwards to `SlashHandler`. Future Slack/Discord/CLI-tty channels will each supply their own ChatProxy but share the same `SlashHandler`.

```
/new-session --agent cc --dir /path/to/work
/new-session --agent cc-voice --dir /path/to/repo
/new-session --agent voice-e2e
/new-session                        # ERROR: --agent is required (hint: /list-agents)
/new-session --agent cc             # ERROR: agent 'cc' requires --dir (hint: /list-agents)
/list-agents                        # lists agent names + descriptions from agents.yaml
/list-sessions                      # lists active sessions (session_id, agent, status)
/end-session <session_id>           # terminates by id regardless of agent type
```

**No default agent; no auto-fill of `--dir`**: `/new-session` without `--agent` returns an error. Missing `--dir` for an agent that declares it as required also returns an error. The CLI entry (`esr session new`) does NOT auto-fill `--dir` with `$pwd` — this is deliberate to prevent accidental sessions rooted in surprising directories (e.g., `/tmp`). Users must explicitly specify `--dir`.

### 3.6 PeerProxy pattern (cross-session access)

A Peer.Proxy in a user Session whose `target` is a peer in AdminSession is called a "PeerProxy" (the pattern, not a distinct type — structurally it is just `Peer.Proxy`). Every outbound call from a user Session to an AdminSession peer goes through a local PeerProxy.

**Example — user Session reaches FeishuAppAdapter**:

```
User Session_<id>:
  CCProcess → CCProxy → FeishuChatProxy
    → FeishuAppProxy (Peer.Proxy, target="admin::feishu_app_adapter_${app_id}")
      → AdminSession.FeishuAppAdapter_<app_id>
        → Feishu API
```

Properties:
- **Per-session mailbox**: if FeishuAppAdapter is slow, only the owning session's FeishuAppProxy backs up. Other sessions unaffected.
- **Capability check hook**: FeishuAppProxy declares `@required_cap "peer_proxy:feishu/forward"`; the injected `forward/2` wrapper calls `Esr.Capabilities.has?(principal_id, "peer_proxy:feishu/forward")` before each forward. Per-session grants are enforced at the proxy boundary. (Runtime target-scoping — e.g. per-app_id — is a future extension; today the permission is a single scope-free string.)
- **Static target binding**: FeishuAppProxy's `target` string is resolved once at session spawn (substitution happens in `SessionRouter.create_session/2`) and stored in `proxy_ctx`. Runtime forward is either a direct `send/cast` to a stored PID or a pool-acquire operation against a supervisor named in `proxy_ctx`. Arbitrary runtime lookups against SessionRegistry (or any other registry) on the hot path are disallowed. Two narrow exceptions — pool-acquire for voice peers (§4.1 VoiceASRProxy/VoiceTTSProxy) and the slash-handler fallback lookup (§5.3) — are documented where they appear.
- **Missing-target handling**: if `target` resolves to a dead PID, the forward returns `{:drop, :target_unavailable}` and the owning Session gets a monitor DOWN notification. SessionRouter decides whether to rebuild or tear down the Session.

### 3.7 Data-plane principle: neighbor-ref injection

When `PeerFactory.spawn_peer/4` creates a Peer, it receives the Peer's neighbor refs (upstream PID, downstream PID, proxies) as part of its init args. These refs are PIDs + metadata computed by `SessionRouter` from the agent pipeline yaml.

Once spawned, the Peer holds neighbor refs in its GenServer state. All message forwarding is a direct `send(neighbor_ref, msg)` or `GenServer.cast(neighbor_ref, msg)`. No PubSub broadcast, no registry lookup, no central router dispatch.

This pushes routing decisions to topology-instantiation time (once per session lifecycle) instead of per-message. Result: the data plane has O(1) dispatch cost and is fully decentralised.

**Exception**: the very first message into a Session (the FeishuChatProxy's first inbound) comes from AdminSession.FeishuAppAdapter. FeishuAppAdapter does need to look up "which session for this chat_id+thread_id" — this lookup goes through `SessionRegistry.lookup_by_chat_thread/2`. But this is only the first hop for each session, not every message. Subsequent messages within a session's lifetime use the already-established neighbor ref.

---

## 4. Module Tree

Full supervision tree after refactor:

```
Esr.Application
└── Esr.Supervisor (:one_for_one)
    ├── Esr.PeerRegistry                     (Elixir Registry, unique keys)
    ├── Esr.SessionRegistry                  (GenServer — yaml compiler + mappings)
    ├── Esr.SessionSocketRegistry            (renamed from SessionRegistry; CC WS bindings)
    ├── Esr.PeerFactory                      (GenServer — creation mechanics)
    ├── Esr.SessionRouter                    (GenServer — control plane)
    ├── Esr.Workspaces.Registry              (kept; workspaces.yaml cache)
    ├── Esr.Admin.Supervisor                 (from v2.2 — admin queue, dispatcher)
    │   ├── Esr.Admin.Dispatcher
    │   ├── Esr.Admin.CommandQueue.Watcher
    │   └── Esr.Admin.Janitor
    ├── Esr.HandlerRouter.Supervisor         (handler RPC to Python)
    ├── Esr.Telemetry.Supervisor             (existing)
    ├── Esr.AdminSession                     (Supervisor, :one_for_one, :permanent)
    │   ├── Esr.AdminSessionProcess          (GenServer)
    │   ├── Esr.Peers.GlobalPeers            (Supervisor for one-per-kind global peers)
    │   │   ├── FeishuAppAdapter_<app_id>    (one per adapters.yaml feishu_app entry)
    │   │   └── SlashHandler                 (exactly one)
    │   └── Esr.Peers.SharedPools            (Supervisor for pooled peers)
    │       ├── VoiceASRPoolSupervisor       (DynamicSupervisor, pool of VoiceASR)
    │       └── VoiceTTSPoolSupervisor       (DynamicSupervisor, pool of VoiceTTS)
    └── Esr.SessionsSupervisor               (DynamicSupervisor, :one_for_one, transient)
        └── Session_<ulid_1> (Supervisor, :one_for_all, :transient)
            ├── SessionProcess                (GenServer, :permanent)
            ├── FeishuChatProxy               (Peer.Stateful)
            ├── FeishuAppProxy                (Peer.Proxy, target AdminSession)
            ├── CCProxy                       (Peer.Proxy, depending on agent)
            ├── CCProcess                     (Peer.Stateful)
            ├── TmuxProcess                   (Peer.Stateful + OSProcess)
            ├── VoiceASRProxy                 (Peer.Proxy, only if cc-voice agent)
            └── VoiceTTSProxy                 (Peer.Proxy, only if cc-voice agent)
```

### 4.1 Peer implementation cards

One card per Peer type; each lists its role, behaviour, scaling axis, crash policy, and notable interactions.

---

**`Esr.Peers.FeishuAppAdapter`**
- **Role**: terminate Feishu WebSocket for one app_id; handle inbound frames; translate outbound replies to Feishu API calls.
- **Behaviour**: `Peer.Stateful`.
- **Scaling axis**: one per Feishu app (`app_id` in `adapters.yaml`). Today = 1 (two apps total but only one active per esrd instance).
- **Crash policy**: `:permanent` under `AdminSession`. Crash cascades to esrd restart.
- **OSProcess**: none (pure Elixir WebSocket via Mint).
- **Free broadcasts**: none. Inbound frames are routed to sessions via `SessionRegistry.lookup_by_chat_thread/2` + `send(session_feishu_chat_proxy, ...)`.

---

**`Esr.Peers.FeishuChatProxy`**
- **Role**: session-level inbound entry from Feishu; slash/non-slash dispatch decision; outbound exit to FeishuAppProxy.
- **Behaviour**: `Peer.Stateful` (holds `chat_id`, `thread_id`, `session_id`, `slash_handler_proxy_ref`).
- **Scaling axis**: one per Session (= one per `(chat_id, thread_id)`).
- **Crash policy**: `:transient`. If crashes, SessionSupervisor's `:one_for_all` tears down the whole Session.
- **Slash dispatch**: on inbound, inspect first token; if starts with `/`, `send(state.slash_handler_proxy_ref, {:slash_cmd, ...})` and do NOT forward downstream. Non-slash forwards downstream along the `inbound` pipeline.

---

**`Esr.Peers.FeishuAppProxy`**
- **Role**: session's single outbound door to FeishuAppAdapter; capability check on forward.
- **Behaviour**: `Peer.Proxy`. Target resolved at spawn.
- **Scaling axis**: one per Session.
- **Failure handling**: if target PID is dead (DOWN monitor), returns `{:drop, :target_unavailable}`; SessionProcess observes and may request SessionRouter to tear down the session.

---

**`Esr.Peers.SlashHandler`**
- **Role**: parse slash commands arriving via `SlashHandlerProxy`; validate args; cast into `Esr.Admin.Dispatcher` with correlation ref; relay Dispatcher reply back to sender's FeishuChatProxy.
- **Behaviour**: `Peer.Stateful` (holds correlation-ref → `sender_chat_proxy_ref` map).
- **Scaling axis**: one, global (AdminSession).
- **Replaces**: `Esr.Routing.SlashHandler` (the PR-0 rename of misplaced `SessionRouter`). After PR-3, slash-related code is fully under `Esr.Peers.SlashHandler`, and `Esr.Routing.SlashHandler` is deleted.

---

**`Esr.Peers.CCProxy`**
- **Role**: stateless pass-through between FeishuChatProxy's downstream and CCProcess. Exists to provide a composition point (future hook for rate limiting, capability enforcement between Feishu and CC layers).
- **Behaviour**: `Peer.Proxy`. Target = local CCProcess (within same Session).
- **Scaling axis**: one per Session.

---

**`Esr.Peers.CCProcess`**
- **Role**: CC-specific business actor. Holds CC session state (current turn, pending tool invocations, directive queue). Invokes Python handler code via `HandlerRouter.call/3`.
- **Behaviour**: `Peer.Stateful`. Possibly composes `Esr.PyProcess` if there is a CC-specific Python sidecar; otherwise interacts with shared `cc_adapter_runner` sidecar (pre-S3 split) or dedicated `cc_adapter_runner` sidecar (post-S3 split).
- **Scaling axis**: one per Session.
- **Interactions**: sends input to `TmuxProcess` downstream; receives output from `TmuxProcess` upstream; invokes Python for tool calls via HandlerRouter.

---

**`Esr.Peers.TmuxProcess`**
- **Role**: own exactly one tmux session (OS-level). Speak tmux control protocol (`-C` mode, D20). Provide `send_input`, `read_output`, and future multi-window primitives. Guarantee OS cleanup on Peer exit.
- **Behaviour**: `Peer.Stateful` + `OSProcess` (composition).
- **Scaling axis**: one per user Session (each esr-session runs exactly one tmux). `SessionsSupervisor.max_children = 128` implicitly caps concurrent tmux sessions at 128.
- **Crash policy**: `:transient`. If tmux exits unexpectedly, `on_os_exit/2` returns `{:stop, :tmux_crashed}`, Session `:one_for_all` policy tears down the entire chain.
- **Control protocol**: TmuxProcess parses `%output`, `%window-close`, `%exit` events from tmux's stdout (MuonTrap pipes these as `{:os_stdout, line}` messages). Commands to tmux (send-keys, list-windows, etc.) are written as plain-text protocol lines to stdin.

---

**`Esr.Peers.VoiceASR` (pool worker)**
- **Role**: receive audio bytes, return transcribed text. Wraps `voice-asr` Python sidecar.
- **Behaviour**: `Peer.Stateful` + `OSProcess` (via PyProcess).
- **Scaling axis**: pool size (e.g., N=4) managed by `VoiceASRPoolSupervisor`.
- **Lifetime**: long-lived; Python model stays loaded.

---

**`Esr.Peers.VoiceTTS` (pool worker)**
- Mirrors VoiceASR but for TTS.

---

**`Esr.Peers.VoiceE2E`**
- **Role**: full-duplex bidirectional voice-to-voice stream. Holds session conversational state on the Python side; Elixir side is a thin pipe.
- **Behaviour**: `Peer.Stateful` + `PyProcess` composition.
- **Scaling axis**: one per Session (each session has its own VoiceE2E with its own Python process and conversational state).

---

**`Esr.Peers.VoiceASRProxy` / `Esr.Peers.VoiceTTSProxy`**
- **Role**: session-local doors to pool workers; request a worker from the pool supervisor on each call.
- **Behaviour**: `Peer.Proxy` with `target` resolved by pool-acquire semantics (not a single fixed PID).
- **Note**: one of the two documented exceptions to the "static target" rule (§3.6). A pool member is selected per forward. The pool-acquire function itself is declared in yaml, so the proxy doesn't consult SessionRegistry at runtime — it asks the pool supervisor named at spawn time. The other documented exception is the slash-handler fallback in §5.3.

---

## 5. Data Flows

### 5.1 Inbound (Feishu → user Session)

```
Feishu WebSocket frame
  ↓
AdminSession.FeishuAppAdapter_<app_id>        (receives frame, decodes envelope)
  ↓ (lookup)
SessionRegistry.lookup_by_chat_thread(chat_id, thread_id)
  ├── hit  → {session_id, feishu_chat_proxy_pid}
  └── miss → emit event :new_chat_thread → SessionRouter creates session, returns new pid
  ↓
send(feishu_chat_proxy_pid, {:inbound, envelope})
  ↓
Session_<id>.FeishuChatProxy.handle_upstream({:inbound, envelope}, state)
  ├── slash? → send(state.slash_handler_proxy_ref, {:slash_cmd, env})   (short-circuit)
  └── non-slash → {:forward, [{:text, env.text}], state} (continues downstream)
  ↓
Session_<id>.CCProxy.forward({:text, ...}) → cc_process_pid
  ↓
Session_<id>.CCProcess.handle_upstream({:text, ...}, state)
  ├── handler dispatch (HandlerRouter.call/3 for tools)
  └── {:forward, [{:send_input, ...}], state}
  ↓
Session_<id>.TmuxProcess.handle_downstream({:send_input, text}, state)
  └── os_write(state, text <> "\n")
```

### 5.2 Outbound (Session → Feishu)

```
TmuxProcess  (receives tmux output via MuonTrap stdout)
  ↓ (monitor pushes)
Session_<id>.TmuxProcess.handle_upstream({:tmux_output, bytes}, state)
  → {:forward, [{:text, bytes}], state}
  ↓
Session_<id>.CCProcess.handle_upstream({:text, ...}, state)
  → (business logic, formatting)
  → {:forward, [{:reply, markdown_str}], state}
  ↓
Session_<id>.CCProxy.forward({:reply, ...})
  ↓
Session_<id>.FeishuChatProxy.handle_downstream({:reply, ...}, state)
  → {:forward, [{:send_feishu, chat_id, thread_id, text}], state}
  ↓
Session_<id>.FeishuAppProxy.forward({:send_feishu, ...})
  → cap check → send(admin_feishu_app_adapter_pid, {:outbound, ...})
  ↓
AdminSession.FeishuAppAdapter_<app_id>.handle_downstream({:outbound, ...}, state)
  → HTTP POST to Feishu API
```

### 5.3 Slash command dispatch

Slash is channel-agnostic (D14). The flow below uses Feishu as the concrete example; for future channels, substitute the channel's ChatProxy (e.g., `SlackChatProxy`) — everything from `SlashHandler` downward is identical.

```
FeishuChatProxy sees slash token in inbound
  → send(SlashHandlerProxy.pid, {:slash_cmd, envelope})
  ↓
Session_<id>.SlashHandlerProxy.forward({:slash_cmd, env})    (NOTE: only if agent declares SlashHandlerProxy;
                                                              for sessions that don't, FeishuChatProxy
                                                              short-circuits to AdminSession.SlashHandler
                                                              via SessionRegistry lookup)
  → send(admin_slash_handler_pid, {:slash_cmd, env, reply_to=feishu_chat_proxy_pid})
  ↓
AdminSession.SlashHandler.handle_call/cast parses command
  → cast Esr.Admin.Dispatcher: {:enqueue, %{kind: :session_new, args: %{agent: "cc", dir: "..."}}, ref}
  ↓
Esr.Admin.Dispatcher processes via queue (per v2.2 spec)
  → on completion: PubSub broadcast reply on `slash:<ref>` topic
  ↓
SlashHandler subscribed to `slash:<ref>`, receives reply, sends it to original FeishuChatProxy
  ↓
FeishuChatProxy sends reply text to FeishuAppProxy → FeishuAppAdapter → Feishu
```

Notes on the slash path:
- For simplicity in PR-3, sessions without an explicit `SlashHandlerProxy` in their pipeline (i.e., most user sessions) use a fallback: `FeishuChatProxy` looks up `admin::slash_handler` via `SessionRegistry` and sends directly. This avoids needing every Session yaml to declare a SlashHandlerProxy. The fallback lookup IS allowed because SlashHandler is a genuinely special-case "meta" peer that exists outside the data-plane agent pipeline.
- Per-session capability check on slash commands still happens in `Esr.Admin.Dispatcher` (existing v2.2 behaviour), not in the FeishuChatProxy.

### 5.4 Session lifecycle

```
Creation:
  Trigger: /new-session slash OR AdminSession.FeishuAppAdapter.lookup_by_chat_thread miss
  → SessionRouter.create_session(agent_name, params)
    → SessionRegistry.lookup_agent(agent_name)      (agent_def from agents.yaml)
    → generate ULID session_id
    → DynamicSupervisor.start_child(SessionsSupervisor, {Session, [session_id, agent_def, params]})
    → Session supervisor starts:
       1. SessionProcess (holds metadata)
       2. For each peer in agent_def.pipeline.inbound ∪ agent_def.proxies (topo-ordered by neighbor deps):
          PeerFactory.spawn_peer(session_id, name, impl, peer_args, neighbor_refs)
    → SessionRegistry.register(session_id, %{chat_thread_key, peer_refs})
    → notify caller with session_id

Termination:
  Trigger: /end-session slash OR SessionProcess.terminate message OR peer crash beyond restart budget
  → SessionRouter.end_session(session_id)
    → DynamicSupervisor.terminate_child(SessionsSupervisor, session_supervisor_pid)
    → Session supervisor's :one_for_all termination: every peer in the subtree stops
       - TmuxProcess.on_exit → MuonTrap SIGTERM → wait → SIGKILL (OS process guaranteed cleanup)
       - VoiceE2E.on_exit → MuonTrap cleanup for Python process
    → SessionRegistry.unregister(session_id)
    → notify caller :session_ended
```

---

## 6. Drift Risk Mitigations

### Risk A: PeerFactory accumulates decision logic

**Mitigation**:
- `PeerFactory` module exports exactly three public functions: `spawn_peer/5`, `terminate_peer/2`, `restart_peer/2`. Review rejects any PR adding other public functions or adding routing/lookup logic to existing ones.
- Compile-time test: enumerate `PeerFactory.__info__(:functions)` at compile and fail the test if the set changes without a review-gate file (`runtime/.peer_factory_surface.md`) being updated.

### Risk B: Peer.Proxy accumulates business logic

**Mitigation**:
- `use Esr.Peer.Proxy` macro generates a compile-time check that scans the using module's AST for `def handle_call/3`, `def handle_cast/2`, `@impl Esr.Peer.Stateful`. If any of these appear, compilation fails with a clear error: `Esr.Peer.Proxy modules cannot define stateful callbacks; use Esr.Peer.Stateful instead`.
- Unit test for the macro: write a fixture Proxy module with an illegal callback, assert compile error.

### Risk C: Scaling-axis mapping drift

**Mitigation**:
- `SessionRegistry` is the single source for all mappings:
  - `agents.yaml → agent_defs`
  - `(chat_id, thread_id) → session_id`
  - `(session_id, peer_name) → pid`
- **No other module may maintain a copy of these mappings.** Enforcement: grep-based pre-commit hook for patterns like `%{chat_id => session_id}` in files outside `session_registry.ex` (false positives accepted; reviewer notes intent in commit).
- Tests for SessionRegistry cover: mapping invalidation on session termination, chat+thread key uniqueness, yaml hot-reload.

### Risk D: N=1 special-case leak

**Mitigation**:
- Every integration test spins up **two** Feishu apps and **two** sessions as a baseline. A test that sets up only one session is allowed only for unit-level peer tests, not for integration tests.
- Test fixtures include a "two-of-everything" config file (`test/fixtures/multi_config.yaml`).

### Risk E: SessionRouter on the data plane

**Mitigation**:
- `SessionRouter` module's `handle_info/handle_cast` clauses accept only these message kinds: `:new_chat_thread`, `:session_end_requested`, `:peer_crashed`, `:agents_yaml_reloaded`, `:create_session_sync`, `:end_session_sync`. No `:inbound_msg`, `:outbound_msg`, `:forward`, or anything carrying a user-message payload.
- Test: attempt to send an unexpected message to SessionRouter and assert it lands in dead_letters / is explicitly dropped with a WARN log, not handled.

### Risk F: AdminSession coupling with SessionRouter during boot

**Mitigation**:
- AdminSession's `start_link/1` does NOT call SessionRouter (which doesn't exist yet at boot). It invokes `PeerFactory.spawn_peer_bootstrap/4` which bypasses SessionRouter and directly calls `DynamicSupervisor.start_child`. The word `bootstrap` in the function name + a module doc note makes this the explicit exception.
- Test: boot sequence test verifies AdminSession starts even when SessionRouter's init_arg points to a nonexistent module — demonstrating no hard dependency.

---

## 7. OTP Patterns Applied

**one_for_all for user Sessions** — rationale: peer chain state is interdependent (CCProcess expects TmuxProcess to exist; FeishuChatProxy routes to CCProxy whose crash invalidates in-flight messages). Restarting the whole Session from a clean slate is safer than partial restart with stale refs.

**one_for_one for AdminSession** — rationale: AdminSession's peers (FeishuAppAdapter, SlashHandler, pool supervisors) are independent. FeishuAppAdapter crash shouldn't kill SlashHandler.

**:permanent SessionProcess, :transient others inside Session** — SessionProcess holds session identity; losing it means losing the session anyway. Other peers are replaceable; a crash should trigger chain rebuild via SessionRouter, not auto-restart-with-stale-state.

**DynamicSupervisor per peer type in AdminSession** — allows pool mode for voice peers; future additions (new global peer types) can be isolated.

**Uniqueness at the edge** — FeishuAppAdapter enforces "one WebSocket per app" as a structural invariant (started with `start_link` once by AdminSession's supervisor), never as an `if not running then start` check. The OSProcess底座 similarly enforces "one OS process per Peer" by `init/1`-time `start_os_process` with a monitor; if the OS process already exists for this session, that's a programming error (test coverage required).

**Bootstrap exception** — AdminSession starts before PeerFactory/SessionRouter. This is documented as the single boot-order exception; no circular deps are allowed elsewhere.

---

## 8. Python Sidecar Split (S3 scope)

### 8.1 voice-gateway decomposition

Current: `py/voice_gateway/` (monolithic Python service).

Target: three Python modules, each runnable as a standalone sidecar:

| Sidecar | Purpose | Elixir Peer |
|---|---|---|
| `py/voice_asr/` | Receive audio bytes → return text; wraps Volcengine ASR API | `Esr.Peers.VoiceASR` |
| `py/voice_tts/` | Receive text → return audio bytes; wraps Volcengine TTS API | `Esr.Peers.VoiceTTS` |
| `py/voice_e2e/` | Bidirectional voice-to-voice stream with side-input agent channel | `Esr.Peers.VoiceE2E` |

Each sidecar entry-point: `uv run python -m voice_asr.main` (etc.).

**IPC protocol** (JSON lines over stdin/stdout):
- stdin receives `{"id": "...", "kind": "request", "payload": {...}}` per request
- stdout emits `{"id": "...", "kind": "reply", "payload": {...}}` per response
- For streaming (voice_e2e), replace request/reply with `{"kind": "stream_chunk", ...}` and explicit stream-close marker
- stderr reserved for logs; Elixir side pipes stderr to `:stdio` with a sidecar-name prefix

### 8.2 adapter_runner decomposition

Current: `py/src/esr/ipc/adapter_runner.py` — shared entry-point loaded with per-adapter-type classes.

Target: split into:

| Sidecar | Responsibility |
|---|---|
| `py/feishu_adapter_runner/` | Feishu-specific adapter logic (message parsing, media upload, attachment handling) |
| `py/cc_adapter_runner/` | CC-specific logic (tmux interaction wrappers, prompt formatting, slash-command local preprocessing) |
| `py/generic_adapter_runner/` | Catch-all for adapters that haven't been split out yet; deprecated on arrival |

The `cc_adapter_runner` is consumed by `Esr.Peers.CCProcess`; `feishu_adapter_runner` may be consumed by a CCProcess-like peer if future CC adapter needs Python logic beyond what's in cc_adapter_runner. (For `FeishuAppAdapter`, no Python sidecar — it's pure Elixir Mint WebSocket.)

### 8.3 MuonTrap wiring

Each Python sidecar is started via `MuonTrap.Daemon`:

```elixir
defmodule Esr.PyProcess do
  defmacro __using__(opts) do
    quote do
      @impl Esr.OSProcess
      def start_os_process(init_args) do
        cmd = ["uv", "run", "python", "-m", unquote(opts[:module])]
        child_spec = MuonTrap.Daemon.child_spec(cmd, [
          name: unquote(opts[:module]),
          log_output: :debug,
          env: unquote(opts[:env]) || []
        ])
        DynamicSupervisor.start_child(__MODULE__.OSProcessSup, child_spec)
      end
    end
  end
end
```

MuonTrap guarantees:
- Child OS process receives SIGTERM on BEAM exit (`cgroup` on Linux, equivalent on macOS via `kqueue`).
- Elixir Peer's exit cleans up the OS process within ~5 seconds.
- On macOS (development), `MuonTrap` uses `kqueue` + `PR_SET_PDEATHSIG` equivalent to ensure no orphans.

**Testing OS cleanup**: each OSProcess peer has an integration test that (a) spawns the peer, (b) kills the Elixir process with `Process.exit/2`, (c) asserts the OS process exits within 10 seconds via `:os.cmd("pgrep -f <sidecar_name>")`.

### 8.4 Decommissioning old voice-gateway

The monolithic `py/voice_gateway/` is removed once all three split sidecars are functional and integration-tested end-to-end with `Esr.Peers.VoiceASR/TTS/E2E`. This happens in PR-4a. Migration strategy:

- PR-4a introduces the three new sidecars in parallel modules; old `voice_gateway` stays unused.
- Integration tests for new sidecars must pass before PR-4a is merged.
- A cleanup commit (final commit of PR-4a) deletes `py/voice_gateway/` and its test fixtures.

---

## 9. Migration Phases / PR Split

### PR-0: PR #11 rename surgery + merge (≤1d)

Scope:
- `Esr.Routing.SessionRouter` → `Esr.Routing.SlashHandler` (file rename + module reference updates)
- Doc cross-references updated
- Test file renames (no test logic changes)

Acceptance: `mix test` passes; PR #11 CI green; ready to squash-merge.

### PR-1: Peer behaviours + OSProcess底座 + SessionRegistry skeleton (3-4d)

Scope:
- Add `Esr.Peer`, `Esr.Peer.Proxy`, `Esr.Peer.Stateful` behaviours + macros
- Add `Esr.OSProcess` behaviour + `Esr.TmuxProcess` + `Esr.PyProcess` implementations
- Add MuonTrap dependency (hex package)
- Add `Esr.PeerFactory` (creation wrapper, not yet called by production code)
- Rename old `Esr.SessionRegistry` → `Esr.SessionSocketRegistry`; create new `Esr.SessionRegistry` skeleton (empty yaml compiler)
- Unit tests for each behaviour, OSProcess cleanup test
- No production code uses the new modules yet

Acceptance: all tests pass; `mix compile --warnings-as-errors` clean; OSProcess integration test shows OS cleanup works.

### PR-2: Feishu chain migration + AdminSession (4-5d)

Scope:
- Add `Esr.AdminSession` + `Esr.AdminSessionProcess`
- Move FeishuAppAdapter (current pieces of `peer_server.ex` dealing with feishu) into `Esr.Peers.FeishuAppAdapter` under AdminSession
- Add `Esr.Peers.FeishuChatProxy`, `Esr.Peers.FeishuAppProxy`
- Add `Esr.Peers.SlashHandler` (new Peer-based); the `Esr.Routing.SlashHandler` from PR-0 delegates to it temporarily
- Add `Esr.SessionsSupervisor`, `Esr.Session` (Supervisor module)
- Add `Esr.SessionRouter` (control plane, first real version)
- Add `agents.yaml` reader in `Esr.SessionRegistry`; define minimal `cc` agent only
- Webhook endpoint (`esr_web/feishu_controller.ex` or equivalent) updated to route through `AdminSession.FeishuAppAdapter`
- Feature flag `USE_NEW_PEER_CHAIN=true|false` allows switching between old and new pipelines; default `false` until E2E smoke works
- Feature flag flipped to `true` and old Feishu code deleted once tests pass

Acceptance: `/new-session --agent cc --dir .` works end-to-end via Feishu; old `feishu_app_proxy` and related code removed; AdapterHub.Registry removed.

### PR-3: CC chain migration + OSProcess MuonTrap + Topology removal (4-5d)

Scope:
- Add `Esr.Peers.CCProxy`, `Esr.Peers.CCProcess`, `Esr.Peers.TmuxProcess` (with MuonTrap OSProcess底座)
- Delete `Esr.Topology.Registry`, `Esr.Topology.Instantiator`, `Esr.Topology.Supervisor`
- Existing `cc_tmux_adapter` logic migrated into `CCProcess` + `TmuxProcess` pair
- `Esr.Routing.SlashHandler` (from PR-0) is fully replaced by `Esr.Peers.SlashHandler`; `Esr.Routing.*` directory removed
- `Esr.SessionSocketRegistry` still exists for CC Phoenix channel bindings (not affected by this refactor; retained)
- Remove all free `Phoenix.PubSub.broadcast` sites per §2.9
- `session_new` Admin command updated to require `agent` field

Acceptance: full E2E from Feishu webhook through new chain to tmux tty; PubSub broadcast audit clean (only telemetry + HandlerRouter + slash-reply remain); `session_new` accepts `--agent cc`.

### PR-4a: voice-gateway split (3-4d, parallel with PR-3)

Scope:
- Add `py/voice_asr/`, `py/voice_tts/`, `py/voice_e2e/` modules with JSON-line IPC
- Add `Esr.Peers.VoiceASR`, `Esr.Peers.VoiceTTS`, `Esr.Peers.VoiceE2E` (using PyProcess底座)
- Add `voice-e2e` and `cc-voice` agents to `agents.yaml`
- Add `VoiceASRPoolSupervisor`, `VoiceTTSPoolSupervisor` under AdminSession
- Integration tests: full E2E voice session (can simulate audio in/out via fixtures)
- Delete `py/voice_gateway/`

Acceptance: `/new-session --agent cc-voice --dir .` and `/new-session --agent voice-e2e` both work end-to-end.

### PR-4b: adapter_runner split (2-3d, parallel with PR-3)

Scope:
- Split `py/src/esr/ipc/adapter_runner.py` into `py/feishu_adapter_runner/`, `py/cc_adapter_runner/`, `py/generic_adapter_runner/`
- Each with its own PyProcess-based Elixir-side peer
- Existing callers updated to target the split sidecars
- `adapter_runner.py` monolithic file deleted

Acceptance: existing CC and Feishu flows work without invoking the deleted monolithic runner.

### PR-5: Cleanup + docs + full regression (2-3d)

Scope:
- Delete feature flags (USE_NEW_PEER_CHAIN etc.)
- Delete any transitional code
- Update `docs/architecture.md` with new module tree
- Run full regression test suite (unit + integration + E2E)
- Performance smoke: measure FeishuWebhook → tmux latency; compare to pre-refactor baseline; reject if >20% regression

Acceptance: no stale references; docs current; full regression green.

### Total timeline

14-21 days. Parallelisable: PR-3 (5d) and PR-4a/PR-4b (3-5d combined) can run concurrently if two engineers are available. Serial critical path: PR-0 → PR-1 → PR-2 → PR-3 → PR-5 ≈ 14d. PR-4a/b on a side branch rebasing on PR-3 as it lands.

---

## 10. Testing Strategy

### 10.1 Test categories

- **Unit tests per Peer**: mock neighbor refs; drive each `handle_upstream` / `handle_downstream` / `init` callback; assert outputs and state transitions.
- **Unit tests per behaviour**: `Esr.Peer.Proxy`'s macro (fixture modules, compile-error expectations); `Esr.OSProcess`'s cleanup guarantee (spawn + Process.exit + pgrep loop).
- **Unit tests per control-plane module**: `PeerFactory` with mocked DynamicSupervisor; `SessionRouter` with mocked PeerFactory + SessionRegistry; `SessionRegistry` yaml parse/compile + hot-reload triggers.
- **Integration tests per Session type**: boot AdminSession + spawn one Session per agent type; drive inbound message through chain; assert outbound emerges correctly; terminate session; assert cleanup.
- **Multi-session (N>1) integration tests**: two Sessions live simultaneously; messages must not cross-contaminate; terminating one must not affect the other.
- **OS cleanup regression**: kill BEAM with SIGKILL, assert all tmux/Python processes die within 10s (cleanup via MuonTrap). Requires actually killing the BEAM process in the test, so run as a separate mix task not bundled into `mix test`.
- **End-to-end smoke**: real (or mocked) Feishu webhook → full chain → tmux stdin receives expected command. One smoke test per agent type.

### 10.2 Fixtures

- `test/fixtures/agents/*.yaml` — declarative agent definitions covering all agent types.
- `test/fixtures/multi_session.yaml` — sets up two Feishu apps + two CC-worktree bindings for N>1 tests.
- `test/support/mock_feishu_adapter.ex` — an `Esr.Peer.Stateful` that records inbound messages and emits stubbed outbound; stands in for real Feishu WS during unit tests of downstream peers.
- `test/support/peer_harness.ex` — helper for building a single-peer test rig with configurable neighbors.

### 10.3 Property tests (where valuable)

- `SessionRegistry` chat_thread_key uniqueness under concurrent registrations (stream of random keys → assert no duplicate session ids).
- `Esr.Peer.Stateful` forward semantics: given any sequence of upstream/downstream messages, the peer's state converges to a consistent snapshot.

### 10.4 CI additions

- Existing `mix test` runs all unit + integration tests.
- New `mix test.e2e.os_cleanup` (named) runs OS-cleanup regression; gated to a nightly or manual trigger due to SIGKILL drama.
- New `mix test.e2e.agents` boots an in-memory esrd and drives each agent's golden-path flow end-to-end.
- GH Actions: PR-required tests = `mix test` + `mix test.e2e.agents`; nightly = `mix test.e2e.os_cleanup`.

### 10.5 Per-PR acceptance gates

Every PR **must** pass the gates in its column before it can be merged. Gates are additive per PR (PR-3 must pass its gates AND keep PR-0..PR-2 gates green).

**PR-0 — rename surgery**
- `mix test` fully green (no test files renamed yet)
- `rg "Esr.Routing.SessionRouter"` returns only comments/docs (module references replaced by `SlashHandler`)
- No new test files added

**PR-1 — behaviours + OSProcess底座 + SessionRegistry skeleton**
- `Esr.Peer.Proxy` macro compile-error test: fixture module with `handle_call/3` must fail to compile with message matching `/cannot define stateful callbacks/`
- Peer.Stateful callback dispatch unit tests (handle_upstream / handle_downstream paths)
- OSProcess cleanup integration test: spawn peer → `Process.exit(pid, :kill)` → within 10s `pgrep -f <sidecar_name>` returns empty
- TmuxProcess integration test: start tmux in control mode, parse `%output` event, cleanly terminate
- PyProcess integration test: start dummy Python sidecar echoing JSON lines, assert round-trip
- SessionRegistry: parse valid `agents.yaml`, reject invalid, hot-reload on file change
- PeerFactory: `spawn_peer/5` with mocked DynamicSupervisor returns `{:ok, pid}`; invalid args return `{:error, reason}`
- MuonTrap dep added to `mix.exs`

**PR-2 — Feishu chain + AdminSession**
- AdminSession boot test: `Supervisor.which_children/1` returns expected set (FeishuAppAdapter, SlashHandler, VoiceASRPool, VoiceTTSPool)
- FeishuAppAdapter inbound test: fake WS frame → envelope decoded → `SessionRegistry.lookup_by_chat_thread/2` called → correct FeishuChatProxy pid receives message
- FeishuChatProxy slash detection test: inbound with leading `/` → forwards to SlashHandler; without `/` → forwards downstream
- FeishuAppProxy capability-check test: principal missing `peer_proxy:feishu/forward` → `{:drop, :cap_denied}`; with cap → forward succeeds
- Session supervisor boot test: spawn `{Session, [id, agent_def, params]}` → supervision tree matches `agents.yaml` declaration
- **N=2 concurrent sessions test** (covers Risk D): create two sessions (different chat_ids), send message to session A, assert session B's FeishuChatProxy mailbox is untouched
- E2E smoke: `/new-session --agent cc --dir /tmp/test` via simulated Feishu → Session created → tree shape correct
- Decommissioning check: `Esr.AdapterHub.Registry` file deleted; `rg "AdapterHub.Registry"` returns no code references

**PR-3 — CC chain + SessionRouter + Topology removal**
- CCProcess unit tests (tool invocation dispatch, directive queue)
- CCProxy unit test (stateless forward, no state accumulation)
- TmuxProcess full integration test with real tmux: spawn → send-keys → receive `%output` → terminate cleanly
- SessionRouter control-plane boundary test: attempting to send `{:inbound_msg, _}` (data-plane shape) to SessionRouter lands in dead-letter or explicit warn-drop; only `:new_chat_thread` / `:session_end_requested` / etc. are handled
- PubSub broadcast audit: automated grep over `runtime/lib/` for `Phoenix.PubSub.broadcast` reports only allowed sites (§2.9 post-refactor list)
- Full E2E: Feishu inbound → FeishuAppAdapter → FeishuChatProxy → CCProxy → CCProcess → TmuxProcess stdin; reply path reverses
- **N=2 concurrent tmux test**: two sessions with independent tmux; kill tmux-A's session, assert tmux-B still running and responsive
- OS cleanup regression: `kill -9 <beam_pid>` → within 10s no stray tmux or Python processes (`pgrep -f esr-cc`)
- `session_new` Admin command rejects calls without `agent` field (unit test)
- `session_new` with `agent: "cc"` + missing `dir` returns `{:error, {:missing_param, :dir}}`
- Decommissioning check: `Esr.Topology.*` modules deleted; `Esr.Routing.*` directory deleted

**PR-4a — voice-gateway split**
- Python unit tests for each sidecar (`voice-asr`, `voice-tts`, `voice-e2e`): JSON-line protocol, request/response, stream handling
- VoiceASR / VoiceTTS / VoiceE2E Elixir peer unit tests (mock PyProcess, assert message shapes)
- VoiceASRPoolSupervisor / VoiceTTSPoolSupervisor: acquire from pool, release, pool exhaustion behaviour
- E2E: `/new-session --agent cc-voice --dir /tmp/test` → inbound audio (fixture) → ASR → CC → TTS → outbound audio (fixture)
- E2E: `/new-session --agent voice-e2e` → bidirectional voice stream (fixture)
- `py/voice_gateway/` directory deleted

**PR-4b — adapter_runner split**
- Python unit tests: `feishu_adapter_runner`, `cc_adapter_runner`, `generic_adapter_runner`
- Existing Feishu and CC integration tests pass unchanged (regression)
- `py/src/esr/ipc/adapter_runner.py` monolithic file deleted

**PR-5 — cleanup + docs**
- `rg "USE_NEW_PEER_CHAIN|USE_OLD_"` returns zero matches (feature flags removed)
- `docs/architecture.md` updated with new module tree diagram
- Full regression suite: `mix test` + `mix test.e2e.agents` + `mix test.e2e.os_cleanup` all green
- Performance smoke: measure Feishu-webhook → tmux-stdin latency p50/p99; compare to pre-refactor baseline (captured in PR-0); fail if p99 > baseline × 1.20

---

## 11. Decommissioning Checklist

| Component | Location | When | Why |
|---|---|---|---|
| `Esr.Routing.SessionRouter` (misplaced) | `runtime/lib/esr/routing/session_router.ex` | PR-0 | Renamed to SlashHandler |
| `Esr.Routing.SlashHandler` (transitional) | `runtime/lib/esr/routing/` directory | PR-3 | Superseded by `Esr.Peers.SlashHandler` |
| `Esr.AdapterHub.Registry` | `runtime/lib/esr/adapter_hub/registry.ex` | PR-2 | Role subsumed by `Esr.SessionRegistry` |
| `Esr.AdapterHub.Supervisor` | `runtime/lib/esr/adapter_hub/supervisor.ex` | PR-2 | No children left after Registry removal |
| `Esr.Topology.Registry` | `runtime/lib/esr/topology/registry.ex` | PR-3 | Merged into `Esr.SessionRegistry` |
| `Esr.Topology.Instantiator` | `runtime/lib/esr/topology/instantiator.ex` | PR-3 | Logic absorbed into `SessionRouter.create_session` + `PeerFactory` |
| `Esr.Topology.Supervisor` | `runtime/lib/esr/topology/` | PR-3 | No children left |
| Old `Esr.SessionRegistry` (socket bindings) | `runtime/lib/esr/session_registry.ex` | PR-1 (rename) | Name freed for new role; content moves to `SessionSocketRegistry` |
| Misc free PubSub broadcast sites | per §2.9 | PR-3 | Converted to neighbor-ref `send/cast` |
| `py/voice_gateway/` (monolithic) | `py/voice_gateway/` | PR-4a | Split into three sidecars |
| `py/src/esr/ipc/adapter_runner.py` | `py/src/esr/ipc/` | PR-4b | Split into per-adapter-type sidecars |
| Feature flag `USE_NEW_PEER_CHAIN` | runtime config | PR-5 | Transitional; removed after full migration |

---

## 12. Appendix: out-of-scope with explicit pointers

| Topic | Why out | Link / follow-up |
|---|---|---|
| Cross-esrd peer routing | Permanent: each esrd is a sovereign process boundary | No follow-up planned; if ever needed, new spec |
| IPC mechanism change (gRPC, UDS) | Stability/simplicity of JSON-over-stdin; MuonTrap supports it natively | `docs/futures/ipc-evolution.md` (not written; create if needed) |
| Multi-agent sessions (CC + voice-e2e in one session) | One agent per session covers known use cases via composed agents like `cc-voice` | Reassess if a use case emerges |
| Session persistence across esrd restarts | Requires serialisation of PyProcess state, MuonTrap reattach semantics | `docs/futures/session-warm-restart.md` (not written) |
| GUI / admin panel | CLI + Feishu are sufficient | — |
| Auto-sleep of idle sessions | Existing `/end-session` sufficient for now; auto-eviction is YAGNI | Track via issue if user demand appears |
