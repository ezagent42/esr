# Actor / role suffix vocabulary — canonical taxonomy

**Date:** 2026-04-29.
**Why this doc exists:** PR-21q-t introduced "chat-guide" and "user-guide" as inline private functions inside `Esr.Peers.FeishuAppAdapter`. The user pointed out this naming drifted from the rest of the codebase's `*Handler` / `*Adapter` / `*Proxy` convention. This doc cements the taxonomy so future PRs don't drift again.

**Read this before:**
- Adding a new module under `Esr.*`, `Esr.Peers.*`, `Esr.Admin.*`, or `EsrWeb.*`.
- Refactoring inline logic into a dedicated module — the shape of the logic determines which suffix is correct.
- Discussing routing / pipeline architecture in spec docs (use the canonical names, not ad-hoc nicknames).

## Quick reference

| Suffix | Role | When to use |
|---|---|---|
| `*Adapter` | Bridge across IPC / process boundary (Python ↔ Elixir) | Wraps a foreign-process protocol; one per configured `instance_id`. |
| `*Proxy` | Per-entity local representative; forwards on behalf of something remote | One per logical chat / per logical session / per voice peer. Stateful. |
| `*Process` | Wraps an OS process or external-resource lifecycle | Long-lived; spawns, monitors, terminates. |
| `*Handler` | Parses or dispatches one class of inbound | Pure or near-pure transformation; sink for `:slash_cmd`-style messages. |
| `*Server` | Top-level state container (GenServer + ETS) | Singleton; runtime-wide state with read-mostly ETS reads. |
| `*Router` | Picks destination from a config table | Stateless lookup over `agents.yaml` / `routing.yaml` / etc. |
| `*Supervisor` | OTP supervisor | Ordinary OTP-tree primitive. |
| `*Registry` | Read-mostly ETS lookup | Boot-loaded snapshot, atomic refresh on file change. |
| `*Watcher` | FSEvents file-change observer | Subscribed to a `*.yaml` file's directory; calls a `*FileLoader`. |
| `*FileLoader` | YAML parse + atomic snapshot swap | Pure (besides Registry write); validates against a schema. |
| `*Dispatcher` | Async cmd-queue brain | Single GenServer; per-kind required-permission table; spawns per-cmd Tasks. |
| `*Channel` | Phoenix Channel handler | One per protocol topic; `dispatch/2` clause-based message routing. |
| `*Socket` | Phoenix Socket entry point | One per `socket "/path"` declared in `EsrWeb.Endpoint`. |
| `*Guard` | **Inbound gate** — checks condition, drops/passes, optional side effects, rate-limited (PR-21u, NEW) | A pre-routing gate that needs its own state (rate-limit cache, pending entries) and lifecycle. |
| `*Buffer` | Ring buffer / FIFO | Bounded-memory time-series store. |

The remainder of this doc explains each suffix in depth.

## Layered taxonomy

### `Esr.Peers.*` — actor pipeline participants

Peers are GenServers that participate in the inbound/outbound message chain. They implement the `Esr.Peer.Stateful` behavior (or older `Esr.Peer`). The four suffixes here describe their structural role:

#### `*Adapter`

Bridge across IPC or process boundaries. The Adapter speaks both protocols: ESR-internal envelope shape on one side, the foreign protocol (Feishu, MCP, …) on the other.

- **Lifecycle**: one per configured `instance_id` (per `adapters.yaml` row).
- **State**: configuration (`app_id`, `app_secret`, `instance_id`), rate-limit caches per principal/chat, optional reconnection backoff.
- **Examples**: `Esr.Peers.FeishuAppAdapter`.

#### `*Proxy`

Per-entity local representative. The Proxy holds state for ONE remote thing (one chat, one voice channel, one session) and forwards messages on its behalf.

- **Lifecycle**: one per logical entity. Spawned on first inbound; torn down via cleanup.
- **State**: the entity's id, neighbour pids, pending request refs, sometimes pending-action TTL.
- **Examples**: `Esr.Peers.FeishuChatProxy`, `Esr.Peers.FeishuAppProxy`, `Esr.Peers.CCProxy`, `Esr.Peers.VoiceTTSProxy`, `Esr.Peers.VoiceASRProxy`.

#### `*Process`

Wraps an OS process or external-resource lifecycle. The Process module is the Elixir-side handle for something running outside the BEAM.

- **Lifecycle**: spawn → monitor → terminate.
- **State**: OS pid, port, optionally pty descriptor.
- **Examples**: `Esr.Peers.CCProcess` (Claude Code subprocess), `Esr.Peers.TmuxProcess` (tmux session).

#### `*Handler`

Parses or dispatches one class of inbound. Distinguished from Adapter by NOT speaking a foreign protocol — Handlers operate on already-decoded ESR envelopes.

- **Lifecycle**: usually long-lived, AdminSession-scoped or per-chain.
- **State**: pending request refs (correlation refs awaiting Dispatcher reply).
- **Examples**: `Esr.Peers.SlashHandler` (slash-command parser; one per esrd, AdminSession-scoped).

### `Esr.Peers.*` — domain peers (no suffix)

Some peers are named for what they do, not what role they fill, when no role suffix fits cleanly. Used sparingly.

- **Examples**: `Esr.Peers.VoiceTTS`, `Esr.Peers.VoiceASR`, `Esr.Peers.VoiceE2E`.

### Top-level `Esr.*` — runtime infrastructure

#### `*Server`

Top-level state container; usually a GenServer plus ETS. Singletons.

- **Examples**: `Esr.PeerServer` (peer-graph state + reachable_set ACL).

#### `*Router`

Picks destination from a config table. Stateless lookups over loaded yaml.

- **Examples**: `Esr.SessionRouter` (chat→session), `Esr.HandlerRouter` (handler module → channel topic).

#### `*Supervisor`

OTP supervisor. Standard primitive, no special semantics.

- **Examples**: `Esr.WorkerSupervisor`, `Esr.SessionsSupervisor`, `Esr.PeerSupervisor`, `Esr.Workspaces.Supervisor`, `Esr.Capabilities.Supervisor`, `Esr.Users.Supervisor`.

#### `*Registry`

Read-mostly ETS lookup. Boot-loaded from yaml; atomic refresh on file change.

- **Properties**: ETS reads bypass the GenServer for performance (mirrors `Esr.Capabilities.Grants`'s pattern). Writes go through the GenServer for consistency.
- **Examples**: `Esr.SessionRegistry`, `Esr.PeerRegistry`, `Esr.SessionSocketRegistry`, `Esr.Workspaces.Registry`, `Esr.Users.Registry`, `Esr.Permissions.Registry`.

#### `*Process` (top-level variant)

Same role as `Esr.Peers.*Process` but for runtime-level entities not directly in the peer pipeline.

- **Examples**: `Esr.SessionProcess`, `Esr.AdminSessionProcess`, `Esr.OSProcess`, `Esr.PyProcess`.

### `Esr.Admin.*` — admin command subsystem

#### `Dispatcher`

Single central async dispatcher. Receives `{:execute, cmd, reply_to}` casts; checks per-kind cap; spawns a Task that runs the command's implementation module; routes the result back to `reply_to`.

- **Examples**: `Esr.Admin.Dispatcher` (the only one).

#### `Commands.<Kind>`

One module per admin command. Pure (no GenServer).

- **Examples**: `Esr.Admin.Commands.Cap.{Grant,Revoke}`, `Esr.Admin.Commands.Session.{New,End,List}`, `Esr.Admin.Commands.Workspace.{New,Info}`.

### `Esr.{Workspaces,Users,Capabilities}.*` — yaml-backed subsystems

The canonical three-piece pattern: Registry + Watcher + FileLoader, all under a Supervisor.

#### `*FileLoader`

Parses `*.yaml`, validates, swaps the Registry's snapshot atomically. Non-destructive on parse failure (keeps prior snapshot).

- **Examples**: `Esr.Capabilities.FileLoader`, `Esr.Users.FileLoader`.

#### `*Watcher`

FSEvents observer; calls `*FileLoader.load/1` on change events.

- **Examples**: `Esr.Capabilities.Watcher`, `Esr.Workspaces.Watcher`, `Esr.Users.Watcher`, `Esr.Admin.CommandQueue.Watcher`.

### `EsrWeb.*` — Phoenix web layer

#### `*Socket`

Phoenix `socket "/path", EsrWeb.<Name>Socket, ...` declared in `EsrWeb.Endpoint`. Maps URL prefix to channel topic prefix.

- **Examples**: `EsrWeb.AdapterSocket`, `EsrWeb.HandlerSocket`, `EsrWeb.ChannelSocket`.

#### `*Channel`

Phoenix Channel module; `dispatch/2` clause-based topic handler.

- **Examples**: `EsrWeb.AdapterChannel`, `EsrWeb.HandlerChannel`, `EsrWeb.CliChannel`, `EsrWeb.ChannelChannel`.

### Single-point modules (no suffix family)

Used when a module is the only thing of its shape and inventing a one-off suffix would be premature.

- `Esr.Telemetry.Buffer` — ring buffer for telemetry events.
- `Esr.Permissions.Bootstrap` — boot-time Registry population.
- `Esr.Yaml.Writer` — comment-preserving yaml writer.
- `EsrWeb.PendingActions` — TTL state machine for two-step destructive confirms (PR-21e). **NOTE:** under PR-21u's taxonomy, this is gate-shaped and should be renamed to `EsrWeb.PendingActionsGuard` — see "Migration plan" below.

## `*Guard` — new role (PR-21u, formalized)

### Definition

A `*Guard` is an **inbound gate**: it sits in the message-handling path, checks a precondition, and either passes the message through or drops it (with optional side effects like emitting a DM, broadcasting telemetry, or registering a pending state machine).

### Identifying properties

A module is a `*Guard` (and should bear that suffix) when ALL of these hold:

1. **It's invoked per-message** during inbound handling, BEFORE the routing layer decides where the message goes.
2. **It has its own internal state** beyond the GenServer trivium — typically a rate-limit cache, a TTL ledger, or a pending-action map.
3. **It returns one of**: `:passthrough` / `{:guarded, new_state}` / `{:consume, verdict}` / similar — i.e., the caller hands control over for at least the immediate message.
4. **The check is conditional and the conditions can change at runtime** (a binding shows up, a cap is granted, a TTL expires) — distinguishing it from a static permission check (which would be inline in a Handler).

### Examples

`*Guard` examples (some not yet renamed — see Migration plan):

| Module / inline logic | Status | Role |
|---|---|---|
| `EsrWeb.PendingActions` | Exists; **rename to `EsrWeb.PendingActionsGuard` pending** | TTL gate consuming `confirm`/`cancel` words |
| `maybe_emit_unbound_chat_guide/3` (inline in `FeishuAppAdapter`) | **Extract to `Esr.Peers.UnboundChatGuard` pending** | Drops inbound when chat→workspace binding missing; DMs registration guidance |
| `maybe_emit_unbound_user_guide/4` (inline in `FeishuAppAdapter`) | **Extract to `Esr.Peers.UnboundUserGuard` pending** | Drops inbound when user_id→esr-user binding missing; DMs `bind-feishu` instruction |
| Lane B cap check + deny-DM (inline in `Esr.PeerServer`) | **Extract to `Esr.Peers.CapGuard` pending** | Cap-fail emits deny-DM (rate-limited) and drops outbound |

Future Guards likely to be added:
- `Esr.Peers.RateLimitGuard` — generalize the deny-DM and guide-DM rate caches.
- `EsrWeb.MultiAppCollisionGuard` — detect duplicate adapter registrations (PR-A T11b precedent).

### When NOT to use `*Guard`

- **Static cap declarations** (e.g. agent's `capabilities_required:`): these go in yaml, not modules. The check happens inside Dispatcher (`required_permission` table), not a Guard.
- **Pure validators** (e.g. `*FileLoader`'s `validate_cap/2`): they're stateless transforms — `*Loader` / pure helpers in the parent module are fine.
- **Permanent ACL**: handled by `Esr.Capabilities.has?/2` (a pure function over ETS); not gate-shaped.

## Migration plan (for existing gate-shaped logic)

These pieces are gate-shaped today but don't bear the `*Guard` suffix. Future PRs should rename / extract; PR-21u itself does NOT touch any code.

| Current location | Proposed module | Tracking |
|---|---|---|
| `EsrWeb.PendingActions` | `EsrWeb.PendingActionsGuard` | Rename only; ~10 LOC + telemetry rename |
| `maybe_emit_unbound_chat_guide` (in `FeishuAppAdapter`) | `Esr.Peers.UnboundChatGuard` | Extract module; ~80 LOC |
| `maybe_emit_unbound_user_guide` (in `FeishuAppAdapter`) | `Esr.Peers.UnboundUserGuard` | Extract module; ~80 LOC; could share a base behavior with above |
| Inline Lane B cap check (in `Esr.PeerServer`) | `Esr.Peers.CapGuard` | Larger refactor; touches PeerServer state shape |
| `deny_dm_last_emit` / `guide_dm_last_emit` state in FAA | Move into the relevant `*Guard` module | Part of the above two extractions |

PR-21v (next) does the OnboardingGuard extraction (chat + user). PendingActions rename and CapGuard extraction follow as separate PRs.

## When introducing a new suffix

If a new behaviour shape doesn't fit any existing suffix, add a row to this doc BEFORE merging the code that uses the new name. The repo policy:

1. New role suffix needs a one-paragraph definition here, including the identifying properties (analogous to `*Guard`'s 4-point list above).
2. List existing modules that should adopt the new suffix, even if just as a future-work item.
3. PR description references this doc and explicitly says "introduces new suffix `*X`".

This prevents the drift that produced the chat-guide / user-guide naming inconsistency.

## Related

- `docs/notes/esr-uri-grammar.md` — cross-process addressing (the URI scheme that runs alongside actor names).
- `docs/superpowers/glossary.md` — broader project vocabulary (esr user, workspace, session, …).
- `docs/architecture.md` §"Cross-boundary addressing" — high-level pointer.
