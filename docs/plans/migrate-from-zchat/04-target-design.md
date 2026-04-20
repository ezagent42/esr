# Target Design: ESR Python SDK after absorbing zchat capabilities

This document is sufficient on its own if you only want to know what writing ESR business logic looks like after this work lands. Read [`01-esr-overview.md`](./01-esr-overview.md), [`02-zchat-overview.md`](./02-zchat-overview.md), and [`03-comparison.md`](./03-comparison.md) first if you don't already know the two codebases.

## 1. Goal

Lower cognitive load on Python developers writing ESR business logic, while preserving:

- OTP runtime guarantees (supervision, distribution, ETS-backed concurrency)
- ESR's contract-friendly purity discipline at the function level
- The 4-layer architecture (Adapter / business logic / Topology), with a sharper internal decomposition

The migration target *removes* the actor model from the Python developer's view. Per-actor supervision continues inside the Elixir runtime, but Python authors never write `actor_type=...` again.

## 2. The cognitive-load problem (concrete)

Today, adding a "this channel is in takeover mode" feature in ESR requires:

1. New handler module: directory + `pyproject.toml` + `esr.toml`
2. `@handler_state` Pydantic model
3. `@handler` function pattern-matching on `/hijack` content
4. EDSL Topology declaring when this actor is instantiated
5. Decision: one actor per channel? Per workspace? Global?
6. Bootstrap path: who creates the first instance?
7. Cross-actor query: any handler reading the mode pays a PubSub round-trip

That's roughly 200 LOC and four files. Compare to zchat's [`ModePlugin`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/mode/plugin.py) — 50 LOC, one file, no actor.

The structural cause: ESR exposes the **actor model** to Python developers. Most business logic doesn't actually need actor identity — it just needs "when X happens, do Y, possibly reading shared state Z."

## 3. OTP idiom check (research summary)

A sanity check: how does the Erlang/OTP world handle this same tension? Findings, with sources at the bottom of this document:

1. **ETS public table is the canonical "shared state without ceremony" answer.** Any process reads, owner writes. Already used in ESR (`Esr.Workspaces.Registry`, `Esr.Topology.Registry`).
2. **GenServer + ETS is the textbook write-mediator pattern.** Already used in ESR.
3. **The Elixir community does NOT enforce per-callback purity.** OTP convention: pure logic in plain modules, GenServer callbacks freely call into ETS / `persistent_term` / other processes. ESR's "handler is `(state, event) → (new_state, actions)`" is an ESR-specific design choice for static contract verification, not OTP-mandated.
4. **`persistent_term` for read-mostly, near-immutable data.** Routing config is a candidate (writes happen on file edit, reads happen on every event).
5. **CQRS / Commanded shows projection-as-action at scale.** Projectors consume events, update read models. Our `Project` action is the same idea, lighter weight.
6. **`Phoenix.Registry` already provides "channel-scoped state with metadata"** as a built-in primitive. Worth wrapping rather than reinventing.

**The reframe:** ESR's runtime has all the right OTP plumbing. The cognitive-load gap is in the Python API surface, not the Elixir runtime. We can fix it without touching OTP guarantees.

## 4. The new primitive set

### 4 declarations + 4 actions + 1 read API

| Form | Function signature | Purity | Triggered by |
|---|---|---|---|
| `@adapter(name, allowed_io)` | class | impure | runtime calls or self emits |
| `projection_table(name, default)` | declaration | n/a | declared at module load time |
| `transform(source, fn)` | `(event) → event \| None` | pure | every event from source, in mount order |
| `react(pattern, handler, source=, reads=())` | `(event, ctx) → list[Action]` | pure | events matching pattern, parallel fan-out |

**Action types** (returned by react handlers):

- `Project(table, key, value)` — write to projection table
- `Emit(adapter, action, args)` — call adapter (impure I/O)
- `Route(target, msg)` — forward to another logical entity (target = projection-keyed lookup)
- `InvokeCommand(name, params)` — trigger Layer 4 Topology

**Ctx API** (read-only, frozen snapshot passed into react handlers):

- `ctx.read(table, key) → value` — synchronous read; returns `default` if no entry
- `ctx.list_keys(table) → list[key]` — for iteration scenarios

### What disappears from Python

| Old concept | Replacement |
|---|---|
| `@handler_state(actor_type=...)` | `projection_table(name, ...)` keyed by entity id |
| `@handler(actor_type=...)` | `react(pattern={"event_type": ...}, handler=...)` |
| Per-actor mailbox in Python | Hidden inside Elixir runtime |
| "Bootstrap an actor on first message" | First `Project` to a key creates the entry |
| Pattern-match on event_type inside handler | `pattern=` declarative match in `react` |

### What stays

- `@adapter` and the I/O purity boundary (unchanged)
- Layer 4 Topology / Command (for genuine multi-step orchestration: `feishu-thread-session`, `csat-flow`)
- `InvokeCommand` action for handlers to spawn topologies
- All Elixir runtime: PeerServer, AdapterHub, HandlerRouter, SessionRegistry, OTP supervision

## 5. Boundary clarifications

### transform vs react

| | transform | react |
|---|---|---|
| Function returns | `event` (or `None` to drop) | `list[Action]` |
| Domain | message domain | crosses to effect domain |
| Composition | sequential pipeline (mount order) | parallel fan-out |
| Side effects | none | declares effects via actions |
| State | none | reads via `ctx`, writes via `Project` action |

Mnemonic: **transform 改消息，react 因消息而做事** — transform changes the message; react causes things to happen because of it.

### react vs Topology (Layer 4)

| | react | Topology |
|---|---|---|
| Scope | single event → list of actions | multi-step graph, possibly multi-actor |
| State | via projections (lookup-table style) | per-actor (own ETS row + supervision) |
| Lifecycle | stateless callable | spawned by `InvokeCommand`; supervised; can be torn down |
| Use when | "this event triggers these effects" | "this is a workflow with steps and dependencies" |
| Example | `/hijack` → set mode + emit reaction | `feishu-thread-session` → spawn CC + connect MCP + register |

A `react` handler can return `InvokeCommand(...)` to delegate to a Topology when the work warrants it. This is the canonical glue between the lightweight reactive layer and the heavyweight orchestration layer.

### projection vs handler-state (today)

A projection is a runtime-managed ETS table — named, with a declared default. `Project` actions update it; `ctx.read` reads. No actor identity required — the table key *is* the entity identity.

```python
projection_table("threads", default=None)
projection_table("channel_modes", default="copilot")
projection_table("dedup_seen", default=frozenset)
```

Compare to handler-state today: state is bound to an actor instance. Projections key by string id, no actor required.

## 6. Worked example: `/hijack` (channel-mode)

End-to-end flow demonstrating the four primitives. This is the new equivalent of zchat's [`src/plugins/mode/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/mode/plugin.py).

### File layout

```
handlers/channel_mode/
├── pyproject.toml
├── esr.toml
└── src/
    └── esr_handler_channel_mode/
        ├── __init__.py
        └── handlers.py
```

### `handlers.py` (full source)

```python
"""Channel-mode handlers — copilot/takeover state machine.

Replacement for zchat's plugins/mode/plugin.py. Mode is a channel-scoped
projection: chat_id → "copilot" | "takeover".
"""
from esr import (
    transform, react, projection_table,
    Project, Emit,
)


# ─── 1. Declare the projection table ──────────────────────────
projection_table(
    name="channel_modes",
    default="copilot",
)


# ─── 2. Transform: parse slash commands into structured fields ─
def parse_slash(event, ctx):
    """Pure: enrich event with meta.slash_cmd / meta.slash_args."""
    content = event.args.get("content", "").strip()
    if not content.startswith("/"):
        return event
    parts = content[1:].split(maxsplit=1)
    return event.with_meta(
        slash_cmd=parts[0],
        slash_args=parts[1] if len(parts) > 1 else "",
    )


transform(source="feishu", fn=parse_slash)


# ─── 3. React: hijack and release ────────────────────────────
def on_hijack(event, ctx):
    chat_id = event.args["chat_id"]
    return [
        Project("channel_modes", chat_id, "takeover"),
        Emit("feishu", "react",
             {"msg_id": event.args["msg_id"], "emoji": "lock"}),
    ]


def on_release(event, ctx):
    chat_id = event.args["chat_id"]
    return [
        Project("channel_modes", chat_id, "copilot"),
        Emit("feishu", "react",
             {"msg_id": event.args["msg_id"], "emoji": "unlock"}),
    ]


react(pattern={"meta.slash_cmd": "hijack"},
      handler=on_hijack)

react(pattern={"meta.slash_cmd": ("release", "copilot")},
      handler=on_release)
```

### Thread routing reads the mode

```python
# handlers/feishu_thread/src/esr_handler_feishu_thread/handlers.py
from esr import react, Emit


def on_thread_msg(event, ctx):
    if event.meta.get("slash_cmd"):
        return []                            # commands handled elsewhere

    chat_id = event.args["chat_id"]
    msg_id  = event.args["msg_id"]

    if ctx.read("channel_modes", chat_id) == "takeover":
        # operator drives — don't push to CC
        return [Emit("feishu", "react",
                     {"msg_id": msg_id, "emoji": "eyes"})]

    # copilot mode — forward to CC
    return [
        Emit("feishu", "react", {"msg_id": msg_id, "emoji": "ack"}),
        Emit("cc_tmux", "send_keys",
             {"session_name": _resolve_thread(chat_id, ctx),
              "content": event.args["content"]}),
    ]


react(pattern={"event_type": "feishu_msg_received"},
      handler=on_thread_msg,
      source="feishu",
      reads=["channel_modes"])
```

### Test (pure function — no runtime needed)

```python
def test_takeover_suppresses_cc_send_keys():
    event = Event(event_type="feishu_msg_received",
                  args={"msg_id": "m1", "chat_id": "oc_xxx",
                        "content": "hello"},
                  meta={})
    ctx = Ctx({"channel_modes": {"oc_xxx": "takeover"}})

    actions = on_thread_msg(event, ctx)

    assert all(a.action != "send_keys" for a in actions)
    assert any(a.args.get("emoji") == "eyes" for a in actions)
```

### End-to-end timing diagram

```
1. operator sends "/hijack" in feishu chat
       │
       ▼
2. feishu adapter emits event
       (event_type="feishu_msg_received",
        args={content="/hijack", msg_id=..., chat_id=...})
       │
       ▼
3. Runtime applies transform chain (in mount order):
       │   parse_slash adds meta.slash_cmd="hijack"
       ▼
4. Runtime fans out to all matching reacts (in parallel):
       ├─► on_hijack → returns [Project(channel_modes, chat_id, "takeover"),
       │                         Emit(feishu, react, lock)]
       │   Runtime applies: ETS write + adapter call
       │
       └─► on_thread_msg → meta.slash_cmd present → returns [] (no-op)

5. Customer sends "请帮我退款"
       │  → no slash_cmd in meta
       │  → on_thread_msg sees ctx.read(channel_modes, chat_id) == "takeover"
       │  → returns [Emit(feishu, react, eyes)]
       │  → CC is not invoked

6. operator sends "/release"
       │  → on_release returns [Project(channel_modes, chat_id, "copilot"), ...]
       │  → next customer message resumes copilot routing
```

**Total LOC**: ~50 lines of Python for the entire mode feature, including the thread routing change. Comparable to zchat's plugin (~50 LOC).

## 7. Worked example: `/new-session` (with Topology delegation)

Demonstrates how complex orchestration combines `react` + `InvokeCommand` + Layer 4 Topology + completion-event reacts.

```python
# handlers/feishu_app/src/esr_handler_feishu_app/handlers.py
from esr import react, Emit, InvokeCommand


def on_new_session_request(event, ctx):
    """User typed `/new-session <workspace> tag=<t>`."""
    args_str = event.meta.get("slash_args", "")
    parts = args_str.split() if args_str else []
    if not parts:
        return [Emit("feishu", "react",
                     {"msg_id": event.args["msg_id"], "emoji": "warning"})]

    workspace = parts[0]
    tag = next((p[4:] for p in parts[1:] if p.startswith("tag=")),
               event.args["msg_id"].split("_")[-1][:12])

    return [InvokeCommand(
        name="feishu-thread-session",
        params={
            "workspace": workspace,
            "chat_id":   event.args["chat_id"],
            "tag":       tag,
            "_feedback": {                       # passthrough to completion event
                "msg_id":  event.args["msg_id"],
                "chat_id": event.args["chat_id"],
            },
        },
    )]


react(pattern={"meta.slash_cmd": "new-session"},
      handler=on_new_session_request)


# Topology emits session_created / session_failed when done.
# Two reacts handle the user feedback.

def on_session_created(event, ctx):
    fb = event.args.get("_feedback", {})
    return [Emit("feishu", "send_message",
                 {"chat_id": fb.get("chat_id", ""),
                  "content": f"✅ session `{event.args['tag']}` ready"})]


def on_session_failed(event, ctx):
    fb = event.args.get("_feedback", {})
    err = event.args.get("error", "unknown")
    return [Emit("feishu", "send_message",
                 {"chat_id": fb.get("chat_id", ""),
                  "content": f"❌ session creation failed: {err}"})]


react(pattern={"event_type": "session_created"}, handler=on_session_created)
react(pattern={"event_type": "session_failed"},  handler=on_session_failed)
```

The Topology (`feishu-thread-session`) handles the multi-step work: spawn CC in zellij/tmux, wait for ready, register with `SessionRegistry`, connect MCP bridge. It emits `session_created` or `session_failed` when done, and the `_feedback` passthrough returns to the originating user.

**Total LOC for `/new-session`:** ~25 lines of Python (above) + the existing Layer 4 Topology (unchanged from v0.2). No new framework primitives required.

## 8. Implementation summary on the Elixir side

The runtime needs three additions:

1. **Projection registry** — GenServer + named ETS tables. `Project` actions go through the GenServer for write serialization; reads bypass via `:ets.lookup`. Pattern: same as [`Esr.Workspaces.Registry`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/workspaces/registry.ex) today.
2. **Transform/react dispatcher** — replaces today's per-actor handler dispatch:
   - For each event from each adapter: walk transform chain in mount order
   - For each `react` whose pattern matches the final event: spawn a Task or use a worker pool to invoke the Python react handler
   - Apply returned actions: `Project` → ETS write via projection registry; `Emit` → adapter directive; `Route` → projection lookup → another adapter dispatch; `InvokeCommand` → existing `Esr.Topology.Instantiator`
3. **Pattern matcher** — compile patterns at registration time; runtime match should be O(patterns) per event (acceptable for hundreds of patterns; revisit at thousands).

The `@handler(actor_type=...)` plumbing ([`Esr.HandlerRouter`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/handler_router.ex), per-actor [`PeerServer`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/peer_server.ex)) **continues to exist** for any handler module that hasn't been migrated yet; new code uses the new primitive. Both coexist during P5 of the migration. See [`05-migration-plan.md`](./05-migration-plan.md).

## 9. Sources

OTP / Elixir community references that justify the design choices above:

- [Patterns for managing ETS tables — Johanna Larsson](https://blog.jola.dev/patterns-for-managing-ets-tables) — public ETS reads + GenServer-mediated writes
- [The many states of Elixir — Underjord](https://underjord.io/the-many-states-of-elixir.html) — when to choose each state mechanism
- [Unpacking Elixir: The Actor Model — Underjord](https://underjord.io/unpacking-elixir-the-actor-model.html) — actor model is *not* the dominant code-structure paradigm in Elixir
- [Clever use of persistent_term — Erlang/OTP blog](https://www.erlang.org/blog/persistent_term/) — when persistent_term beats ETS
- [Choosing the Right In-Memory Storage Solution — DockYard](https://dockyard.com/blog/2024/06/18/choosing-the-right-in-memory-storage-solution-part-1) — comparison matrix
- [Commanded — CQRS / Event Sourcing for Elixir](https://github.com/commanded/commanded) — projector pattern at scale
- [Phoenix.Presence behaviour docs](https://hexdocs.pm/phoenix/Phoenix.Presence.html) — channel-scoped metadata as built-in primitive
- [Elixir Registry docs](https://hexdocs.pm/elixir/main/Registry.html) — name + metadata + dispatch
