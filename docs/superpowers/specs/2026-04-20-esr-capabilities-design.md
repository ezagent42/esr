# ESR Capability-Based Access Control Design

Author: brainstorming session with user (linyilun)
Date: 2026-04-20
Status: draft, awaiting user review
Supersedes: nothing (additive; ESR has no permission mechanism today)
Related: `2026-04-20-esr-v0.2-channel-design.md` (workspaces, which become the capability scope)

## 1. Goal & Scope

### 1.1 Problem statement

ESR's Feishu adapter extracts `sender_id.open_id` on every inbound message
(`adapters/feishu/src/esr_feishu/adapter.py:434-436` live path, `:586-588` polling,
`:635` mock) but never consults it for access control. Any user with access to a
bound chat can invoke any operation the handlers expose. This is acceptable for
single-user development but blocks:

- Cross-department / external deployment, where only some users should use ESR
- Future agent-to-agent interoperability, where the "who can invoke what on whom"
  question is native and needs a first-class mechanism
- Admin-only commands like `/broadcast`, `/reset`, capability-grant management

### 1.2 In scope

1. **Permissions Registry** — runtime-aggregated list of permission
   identifiers (action names) that handlers and adapters declare at
   registration time. Any capability file that references a non-registered
   permission is rejected on load (catches typos).
2. **Capabilities Store** — a YAML file at
   `~/.esrd/<instance>/capabilities.yaml` that lists each principal and the
   set of permissions the principal is granted (its capabilities). Manually
   edited; hot-reloaded on file change.
3. **Workspace-scoped permission strings** — syntax
   `workspace:<workspace_name>/<permission>` with `*` wildcards. Default
   deny. Workspaces (`Esr.Workspaces` — see `py/src/esr/workspaces.py`) are
   the natural business-domain boundary: one workspace groups multiple
   chats possibly spanning multiple Feishu apps.
4. **Two enforcement lanes**:
   - **Lane A**: Feishu adapter checks `msg.send` permission on the
     sender's `open_id` before emitting `msg_received` to the runtime.
   - **Lane B**: `ESR.PeerServer` checks the operation-specific permission
     on the sender's `principal_id` before routing `inbound_event` or
     `tool_invoke` to the target actor.
5. **Envelope extension** — every routed envelope gains explicit
   `principal_id` and `workspace_name` top-level fields. Adapters resolve
   workspace from `(chat_id, app_id)` locally; CC sessions inherit
   `principal_id` from the session-register frame.
6. **`esr cap` CLI** — `list`, `show`, `grant`, `revoke`, `who-can` commands
   that read/write `capabilities.yaml` using the same `@cli.group()` pattern
   as `esr adapter` and `esr workspace` (per `py/src/esr/cli/main.py`).
7. **Rename `io_permission`** (Phase CAP-0) — the existing
   `py/src/esr/verify/capability.py` (handler I/O sandbox scan) is renamed
   to `verify/io_permission.py`. This clears the word "capability" for its
   sole meaning in this spec: a principal-holds-permission binding.

### 1.3 Deferred (explicit)

These are **intentionally** not in this spec. The data model accommodates them
but no logic is implemented:

- **Feishu group-membership auto-sync** (cc-openclaw sidecar's event-driven
  `is_user_member` / `is_admin` reconciliation). Manual YAML editing only.
- **Explicit capability delegation** — a principal programmatically granting
  a subset of its capabilities to another principal with time-bound /
  revocable / audited semantics. The current design uses **implicit
  delegation**: a CC session spawned on behalf of a user inherits that user's
  full `principal_id` via `SessionRegistry` (see §6.3 and §6.5). Explicit
  delegation is planned as `capabilities-v2` — see
  `docs/futures/explicit-capability-delegation.md`.
- **Autonomous / persistent agent identity** — a standalone agent that is
  NOT a CC session spawned by a human. Such an agent would need its own
  authenticated `principal_id` (not inherited). The permission check is
  identical to the user case; only the identity-provenance mechanism is
  missing. Deferred with the same timeline as explicit delegation.
- **Audit log** — recording who was denied what, when. Logging goes to the
  standard runtime log, not a structured audit store.
- **Per-chat or per-thread scope** — only `workspace` is a scope-prefix in v1.

### 1.4 Non-goals

- **Replacing cc-openclaw's sidecar**. Sidecar continues to serve its
  production role for cc-openclaw; this spec gives ESR its own, simpler
  mechanism suited to its actor-model architecture.
- **Cryptographic verification of principal identity**. Trust of `open_id`
  comes from Feishu's WebSocket authentication at the adapter boundary; trust
  of agent identity in the future would need its own design.

### 1.5 Terminology

Two words, two distinct meanings, used consistently throughout this spec:

- **Permission** — names an action that *can be performed*. It is a
  string identifier such as `msg.send`, `session.create`, `workspace.read`.
  Declared (registered) by handlers/adapters at boot; enforced wherever
  the action is dispatched.
- **Capability** — the binding `(principal, permission)` asserting that
  *principal P has the right to perform permission X*. Stored in
  `capabilities.yaml`. Runtime checks this binding at every enforcement
  point.

The mental read for API calls: `Esr.Capabilities.has?(principal,
permission)` → "does the capability `(principal, permission)` exist?"

Two systems use these words in ESR after Phase CAP-0:

| System | Permission names | Capability binding | Code |
|---|---|---|---|
| **I/O sandbox** (pre-existing, renamed) | I/O module import prefixes (e.g. `lark_oapi`, `httpx`) declared in `esr.toml` `allowed_io` | static (per adapter manifest) | `py/src/esr/verify/io_permission.py` |
| **Runtime access control** (this spec) | Action names like `msg.send` | dynamic, per principal | `Esr.Permissions` + `Esr.Capabilities` (Elixir); `py/src/esr/permissions.py` + `esr/capabilities.py` (Python) |

The two systems do not share state or code. They share vocabulary
intentionally — the general concept is the same, only the scope differs.

## 2. Architecture

### 2.1 Three components

```
                             ┌─────────────────────────────┐
                             │  Esr.Permissions.Registry   │
                             │  (in-memory, boot-time)     │
                             │  Sources:                   │
                             │  - Handler.permissions/0    │
                             │  - Adapter.permissions/0    │
                             │  - Python @handler(perms=…) │
                             │  - Capability subsystem     │
                             └────────────┬────────────────┘
                                          │ declared permissions
                                          ▼
   ┌───────────────────┐        ┌─────────────────────┐       ┌──────────────┐
   │  Capabilities     │───────▶│  Esr.Capabilities   │◀──────│  CLI         │
   │  File             │ load + │  (ETS + fs_watch)   │ write │  esr cap ... │
   │  capabilities.yaml│ reload │  principal→perms    │       │              │
   └───────────────────┘        └──────────┬──────────┘       └──────────────┘
                                           │ has?(principal, perm)
                           ┌───────────────┴───────────────┐
                           ▼                               ▼
                 ┌──────────────────┐           ┌────────────────────┐
                 │  Lane A          │           │  Lane B            │
                 │  Adapter inbound │           │  PeerServer routing│
                 │  msg_received    │           │  inbound_event /   │
                 │  → check msg.send│           │  tool_invoke       │
                 │                  │           │  → check <op>      │
                 └──────────────────┘           └────────────────────┘
```

### 2.2 Decision flow

```
Principal identity    Required permission         Check
─────────────────     ────────────────────        ───────
Lane A:  open_id      "workspace:<ws>/msg.send"   has?(principal=ou_xxx,
         (from Feishu)                               perm="workspace:proj/msg.send")
Lane B:  open_id OR   derived from msg shape:     has?(principal=ou_xxx,
         session-     tool_invoke →                  perm="workspace:proj/
         registered   "workspace:<ws>/<tool>"        session.create")
         principal    msg_received →
                      "workspace:<ws>/msg.send"
```

## 3. Permission & capability model

### 3.1 Permission names

- **Shape**: `verb.noun` or `namespace.verb` (e.g. `msg.send`,
  `session.create`, `workspace.read`, `cap.manage`). Flat string,
  dot-namespaced. (`workspace.read` here is a permission name — an action
  readable on the workspace data structure — not a scope.)
- **Provenance**: each handler / adapter declares the permissions it
  **implements** at registration time. The Permissions Registry is the
  union of all declarations.
- **Declaration (Elixir handler)**:
  ```elixir
  defmodule Esr.Handler.FeishuAppProxy do
    @behaviour ESR.Handler
    @impl true
    def permissions, do: ["msg.send", "session.create", "session.switch",
                          "workspace.read", "workspace.list"]
    # ... other callbacks
  end
  ```
- **Declaration (Python handler)** — the existing `@handler(actor_type,
  name)` decorator (see `py/src/esr/handler.py:54-68`) gains a `permissions`
  keyword argument; each registration contributes to the handler entry:
  ```python
  @handler("feishu_thread", "on_msg", permissions=["msg.send"])
  def on_msg(state: FeishuThreadState, event: Event) -> Directive: ...

  @handler("feishu_app_proxy", "on_new_thread",
           permissions=["session.create"])
  def on_new_thread(state, event) -> Directive: ...
  ```
  `HANDLER_REGISTRY` entries grow a `permissions: frozenset[str]` field,
  surfaced to the Elixir Permissions Registry via the existing
  handler_hello IPC envelope.

### 3.2 Scope (workspace-qualified permissions)

Every non-wildcard capability binds a permission within a scope. The scope
is always a workspace (per `Esr.Workspaces`):

- **Syntax**: `workspace:<workspace_name>/<permission>` — e.g.
  `workspace:coordinator-prod/msg.send`.
- **Unscoped** (bare permission name) is a YAML syntax error — every
  non-wildcard entry MUST name its scope, to force explicit intent.
- **`*` wildcard** stands alone as "all permissions in all workspaces"
  (admin).
- **Scope wildcard**: `workspace:*/msg.send` — the permission across every
  workspace.
- **Permission wildcard within a scope**: `workspace:coord-prod/*` — all
  permissions within one workspace.
- **Exact**: `workspace:coord-prod/session.create` — single permission in
  a single workspace.

### 3.3 Check algorithm

```python
def has_capability(principal_id: str, required_perm: str) -> bool:
    """
    required_perm is always scope-qualified at the call site,
    e.g. "workspace:coord-prod/session.create".

    Returns True iff there exists a capability (principal_id, p) where p
    matches required_perm under the wildcard rules.
    """
    held = capability_snapshot.get(principal_id, [])
    for p in held:
        if p == "*":
            return True
        if matches(p, required_perm):
            return True
    return False

def matches(held: str, required: str) -> bool:
    # Split both on "/" — allow fnmatch-style "*" in each segment
    held_scope, held_perm = held.split("/", 1)
    req_scope, req_perm = required.split("/", 1)
    return fnmatch(req_scope, held_scope) and fnmatch(req_perm, held_perm)
```

Default deny: unknown principal, or principal holding no matching
permission, returns `False`.

## 4. Permissions Registry

### 4.1 Source of truth

Permissions are discovered at runtime boot by scanning:

- **Elixir handlers**: any module implementing `ESR.Handler` behaviour with
  a `permissions/0` callback.
- **Elixir adapters**: any module registered in `Esr.AdapterHub.Registry`
  that exposes a `permissions/0` callback.
- **Python handlers**: each `@handler(...)` decoration contributes its
  `permissions=[...]` to its `HandlerEntry`; `py/src/esr/handler.py`
  exposes a helper `all_permissions()` that the worker includes in its
  `handler_hello` IPC envelope to the runtime.
- **The Capabilities subsystem itself** declares `cap.manage` (for
  capabilities-file writes) and `cap.read` (for `esr cap
  show/list/who-can`). These are runtime-intrinsic permissions, not
  handler-declared.

The registry is an ETS table keyed by permission name, value =
`{declared_by, description}`. Frozen after boot.

### 4.2 API

- **Elixir**:
  - `Esr.Permissions.Registry.all/0 :: [String.t()]`
  - `Esr.Permissions.Registry.declared?(perm :: String.t()) :: boolean`
- **CLI**:
  - `esr cap list` — dumps all registered permissions, grouped by
    declaring module. (CLI verb stays `cap` because the end user is
    managing capabilities; the underlying display is the permission
    catalog that capabilities reference.)

### 4.3 Validation

When `capabilities.yaml` is loaded, every entry (each line of a
principal's `capabilities:` list) is validated:

- **Bare `*`** (admin wildcard) — always valid; no registry lookup.
- **Scope segment `workspace:<name>`** — the literal `*` is valid;
  otherwise `<name>` is cross-checked against workspace names in
  `workspaces.yaml`. Missing workspace → warning (the workspace may not
  yet be configured), not a load failure.
- **Permission segment** — the literal `*` is valid; `prefix.*` is valid
  if at least one registered permission matches the prefix; an exact name
  must be a registered permission in `Esr.Permissions.Registry`. Unknown
  bare permission name → **refuse to load** the file; runtime keeps the
  previous snapshot, logs the error.

## 5. Capabilities Store

### 5.1 File location

`$ESRD_HOME/default/capabilities.yaml` — where `ESRD_HOME` defaults to
`~/.esrd` per `runtime/lib/esr/application.ex:61`, and `default` is the
hardcoded instance name per v0.2 conventions. Future multi-instance support
(`v0.3+`) will substitute instance name.

### 5.2 Schema

Each principal entry's `capabilities:` list enumerates the (workspace,
permission) pairs that principal holds — i.e., the capability bindings
that exist for that principal.

```yaml
# ~/.esrd/default/capabilities.yaml
# Manually edited; fs-watched and hot-reloaded on change.

principals:
  # Full admin — note the bare "*" wildcard
  - id: ou_6b11faf8e93aedfb9d3857b9cc23b9e7
    kind: feishu_user
    note: 林懿伦 (owner)
    capabilities: ["*"]

  # Regular user, scoped to one workspace
  - id: ou_abc123
    kind: feishu_user
    note: Alice (cross-dept collab)
    capabilities:
      - "workspace:coordinator-prod/msg.send"
      - "workspace:coordinator-prod/session.create"
      - "workspace:coordinator-prod/session.switch"

  # External user, read-only scope
  - id: ou_ext001
    kind: feishu_user
    note: external reviewer
    capabilities:
      - "workspace:coordinator-prod/msg.send"
      - "workspace:coordinator-prod/workspace.read"

  # Agent principal — schema placeholder; runtime doesn't check agents in v1
  - id: ag_coordinator_001
    kind: agent
    note: reserved for future agent-to-agent scenarios
    capabilities: []
```

### 5.3 Hot reload

- A `file_system` watcher (Elixir `FileSystem` library, already a dep of
  Phoenix) monitors the capabilities file.
- On change: validate → swap ETS table atomically → emit `{:telemetry,
  :capabilities_reloaded, %{...}}`.
- On validation failure: keep previous snapshot, log the specific error
  (line number, offending grant), never crash.
- Every Lane A / Lane B check reads the latest snapshot; there is no caching
  beyond the ETS table itself.

### 5.4 Default deny

If `capabilities.yaml` is missing or empty:
- **Bootstrap**: on boot, if missing and `ESR_BOOTSTRAP_PRINCIPAL_ID` is set,
  write a file with that principal holding `["*"]` and log the action.
- **Otherwise**: every check returns `false`. The runtime starts and accepts
  inbound connections, but every operation is denied until an admin edits the
  file (or uses `esr cap grant` if they somehow already hold `cap.manage`
  on a pre-existing principal).

## 6. Principal identity

### 6.1 Current state

`Esr.PeerRegistry` stores `{actor_id, pid}` only — no principal field (see
`runtime/lib/esr/peer_registry.ex:26`). Two kinds of inbound messages need
a principal:

- **Feishu inbound** (`msg_received` events emitted from the adapter)
- **CC-session `tool_invoke`** (requests from a CC session WebSocket at
  `cli:channel/<session_id>`, handled by `runtime/lib/esr_web/channel_channel.ex`)

Neither carries a principal today.

### 6.2 Envelope extension

Every routed envelope gains two top-level fields:
- `principal_id: String.t()` — required for enforcement paths; `"system"`
  for internal bypass (reserved).
- `workspace_name: String.t() | nil` — the workspace this operation
  targets; used as the scope in `workspace:<name>/<permission>`. For
  non-workspace-scoped operations (runtime admin), this is `nil` and the
  check looks for bare `*` or `workspace:*/<permission>`.

### 6.3 Where principal and workspace get set

**Feishu inbound path** (Lane A responsibility):
The feishu adapter loads `workspaces.yaml` at startup and builds an
in-memory `{(chat_id, app_id) → workspace_name}` map. At the three
`msg_received` emit sites, it populates both fields:
```python
env = {
    ...
    "principal_id": open_id,                     # from sender.open_id
    "workspace_name": self._workspace_of(
        chat_id=raw.chat_id, app_id=self.app_id  # local reverse lookup
    ),
    "payload": {"event_type": "msg_received", "args": {...}}
}
```

If a message arrives from a `(chat_id, app_id)` pair not listed in any
workspace, the adapter routes it as `workspace_name=nil` and the Lane A
check will fail closed (admin-only `*` capabilities still work).

**CC-session `tool_invoke` path** (Lane B responsibility):
CC sessions register themselves with the runtime at WebSocket join time
(`channel_channel.ex` on `phx_join`). The registration frame is extended to
include the session's `principal_id` — either:
- Set explicitly by the caller (CC session operator CLI passes
  `--principal=<id>` or `ESR_SESSION_PRINCIPAL_ID` env at CC spawn time), OR
- Derived from the session's bound workspace: if the session was spawned by
  a Feishu user's `/new-thread`, the spawning handler stored the
  originating `open_id` in `SessionRegistry` when creating the session
  record. Subsequent tool_invokes from that session inherit it.
- Fallback: `ESR_BOOTSTRAP_PRINCIPAL_ID` (treated as admin).

`SessionRegistry` grows two new fields per session: `principal_id` and
`workspace_name`. `channel_channel.ex` reads both and injects the principal
into the `{:tool_invoke, ...}` tuple as a 6th element:
```elixir
{:tool_invoke, req_id, tool, args, reply_pid, principal_id}
```
The `workspace_name` is included in `args["workspace_name"]` by the
session at tool_invoke time.

### 6.4 Why no side-table

A side-table (`actor_id → principal_id`) adds a lookup for every
enforcement check with no gain. Every `principal_id` either originates at
the adapter (Feishu path) or at session registration (CC path) — both are
places where the identity is already known. When agent-to-agent scenarios
arrive (deferred), agents will likewise set `principal_id` in their
outgoing envelopes; still no registry required.

### 6.5 Implicit delegation (the CC-session spawner-inherit semantic)

The "CC session inherits the spawner's `principal_id`" behavior in §6.3 is
**a form of capability delegation** — just an implicit one. Worth naming:

- **What is delegated**: the spawner's *entire* capability set. The CC
  session has exactly what the spawner has, no more, no less.
- **When it's delegated**: at session-spawn time. The handler creating the
  session writes `principal_id` into `SessionRegistry`; subsequent
  `tool_invoke` tuples from that session carry that principal through
  Lane B.
- **Duration**: for the lifetime of the session process. No expiration.
- **Revocation**: only by killing the session or editing
  `capabilities.yaml` to reduce the spawner's grants (which takes effect
  on hot-reload within ~2 seconds).
- **Audit**: implicit — the session's actions appear in logs under the
  spawner's `principal_id`, so after-the-fact review shows "Alice did X"
  rather than "Alice's agent Y did X".

**Consequences worth understanding**:

- If Alice holds `cap.manage`, so does her CC session. A prompt-injection
  attack against her agent has the blast radius of Alice's full account.
- Alice cannot spawn a CC session with a *restricted subset* of her caps
  (e.g., "this session can `msg.send` but not `cap.manage`"). She gets
  all-or-nothing.
- Two sessions spawned by Alice cannot be distinguished from each other
  at the capability-check layer — both are just "Alice".

**When implicit delegation is the right tool**: trust boundary = user
boundary. If the operator fully trusts every process running as them on
their host, implicit delegation is the right model and matches common
OS-level assumptions (a process inherits its invoker's privileges).

**When it isn't** (covered by the planned explicit-delegation work,
`docs/futures/explicit-capability-delegation.md`):
- Running an untrusted third-party agent on one's behalf
- Limiting an LLM-driven session to a narrow scope as defense-in-depth
- Time-bound or revocable grants
- Multi-agent systems where delegations form an auditable chain

## 7. Enforcement points

### 7.1 Lane A — Adapter inbound

**Location**: `adapters/feishu/src/esr_feishu/adapter.py`, immediately
before each of the three `msg_received` construction sites (line 427, 579,
628).

**Pseudocode**:
```python
async def emit_events(self):
    async for raw in self._receive():
        open_id = self._extract_open_id(raw)            # existing logic
        chat_id = self._extract_chat_id(raw)
        workspace = self._workspace_of(chat_id, self.app_id)  # local map
        if workspace is None or not self._capabilities.has(
            principal_id=open_id,
            permission=f"workspace:{workspace}/msg.send"
        ):
            await self._deny_rate_limited(open_id)
            continue
        yield self._build_event(
            raw, principal_id=open_id, workspace_name=workspace,
        )
```

**Deny rate-limit (inline; no sidecar dependency)**:
- An in-memory dict `{open_id → last_deny_ts}` inside the adapter.
- On deny: if `now - last_deny_ts[open_id] >= 600s` (10 min), send a
  one-line Feishu reply `"你无权使用此 bot，请联系管理员授权。"` via
  `im.v1.message.create`, update the timestamp, and drop the event.
- Otherwise drop silently.
- Dict is process-local (OK for v1 — restarts clear it, at worst one extra
  deny message per restart).

### 7.2 Lane B — PeerServer routing

**Envelope reshape prerequisite**: the current envelope at
`runtime/lib/esr/peer_server.ex:216-227` has shape
`%{"id", "type" => "event", "source", "payload" => %{"event_type", "args"}}`.
AdapterChannel (`runtime/lib/esr_web/adapter_channel.ex`) is modified to
require both `principal_id` and `workspace_name` on every inbound event
frame it relays to PeerServer. The adapter runner's `push_envelope` shape
is extended accordingly. Envelopes missing these fields are rejected with
an error log — this catches adapters that haven't been migrated to emit
the extended shape.

**Check locations** — two `handle_info` clauses in `peer_server.ex`:

- **`handle_info({:inbound_event, envelope}, state)` at line 216-227** —
  before `invoke_handler/3`, read `envelope["principal_id"]` and
  `envelope["workspace_name"]`, derive required permission, check.
- **`handle_info({:tool_invoke, req_id, tool, args, reply_pid,
  principal_id}, state)` at line 232-264** (arity extended from 5 to 6 per
  §6.3) — before building the emit, read `principal_id` directly. The
  `workspace_name` for the scope is read from `args["workspace_name"]` if
  present, otherwise `nil`.

**Required-permission derivation**:
```elixir
defp required_perm(%{"payload" => %{"event_type" => "msg_received"}},
                   workspace),
  do: "workspace:#{workspace}/msg.send"

defp required_perm_for_tool(tool, args) do
  workspace = Map.get(args, "workspace_name")
  "workspace:#{workspace || "*"}/#{tool}"
end
```

(`handler_call` is runtime → worker, never routed through PeerServer from
external input, so no clause is needed for it.)

**Deny handling**: returns `{:error, :unauthorized}` to the caller. The
caller handler (feishu_app_proxy, feishu_thread_proxy) catches the error
and emits a user-facing `reply` directive: `"❌ 无权限执行
<permission>（请联系管理员授权）"`. Telemetry event
`[:esr, :capabilities, :denied]` is emitted with `principal_id` and
`required_perm` for observability.

### 7.3 Why two lanes (not one)

Lane A cheaply filters out the clear majority of noise (spam DMs from
unapproved users) at the network edge — nothing crosses into the Elixir
runtime. Lane B protects **operation granularity**: an approved user who can
`msg.send` might still not be allowed to `session.create`. Without Lane B,
Lane A would have to pre-derive every possible downstream cap, which is
impossible without executing the handler.

## 8. CLI

Following the `@cli.group` pattern in `py/src/esr/cli/main.py`:

```
esr cap list
  # Show all registered permissions, grouped by declaring handler/adapter
  # e.g.
  #   feishu_app_proxy:
  #     - msg.send
  #     - session.create
  #     - session.switch
  #   feishu adapter:
  #     - msg.send

esr cap show <principal_id>
  # Show one principal's entry from capabilities.yaml
  # e.g.
  #   id: ou_6b11faf8...
  #   kind: feishu_user
  #   note: 林懿伦 (owner)
  #   capabilities:
  #     - "*"

esr cap grant <principal_id> <permission> [--kind=feishu_user] [--note=<text>]
  # Adds a capability (principal holds permission). Creates the
  # principal entry if missing.
  # The permission argument must be scope-qualified, e.g.
  # "workspace:proj-a/msg.send" or "*" for admin.
  # Writes to capabilities.yaml preserving comments via ruamel.yaml.
  # fs_watch picks up the change → snapshot reloads → capability is live.

esr cap revoke <principal_id> <permission>
  # Removes a matching capability. No-op if not present. If principal's
  # capabilities list becomes empty, the principal entry is retained
  # (not auto-deleted) so the note/kind persist.

esr cap who-can <permission>
  # Reverse lookup. permission can be a wildcard.
  # e.g. who-can "workspace:proj-a/session.create"
  # Scans all principals and returns those whose capabilities match.
```

All write commands use `ruamel.yaml` (new dep) to preserve YAML comments,
ordering, and blank lines. They also print a clear diff summary.

## 9. Bootstrap & admin

### 9.1 First-run

Boot sequence with no existing `capabilities.yaml`:
1. Check `ESR_BOOTSTRAP_PRINCIPAL_ID` env var.
2. If set: create `capabilities.yaml` with that principal holding `["*"]`,
   log the action, continue.
3. If unset: runtime starts with an empty capability table; everything is denied.
   Log a prominent WARNING directing the operator to set the env var or edit
   the file manually.

### 9.2 `cap.manage` capability

The write CLI commands (`grant`, `revoke`) require the invoking operator to
hold `cap.manage`. Because CLI runs locally on the host, "the invoking
operator" is the Unix user; the CLI infers principal_id from
`ESR_ADMIN_PRINCIPAL_ID` (or defaults to `ESR_BOOTSTRAP_PRINCIPAL_ID`). This
is soft enforcement — any Unix user with write access to the file can edit it
directly. The CLI check is convenience, not security.

## 10. Worked example

A Feishu user sends `@coordinator /new-thread "hello"` in a chat bound to
workspace `coordinator-prod` (Feishu app `cli_a9563cc03d399cc9`):

1. Lark WebSocket delivers `P2ImMessageReceiveV1` to the feishu adapter.
2. Adapter extracts `open_id = ou_abc123`, `chat_id = oc_foo`.
3. Adapter looks up `workspace_of(oc_foo, cli_a9563cc03d399cc9) →
   "coordinator-prod"`.
4. **Lane A** — check `has(ou_abc123,
   "workspace:coordinator-prod/msg.send")`.
   - Capabilities file says `ou_abc123` holds
     `"workspace:coordinator-prod/msg.send"`. ✅
5. Adapter constructs `msg_received` envelope with `principal_id:
   ou_abc123`, `workspace_name: coordinator-prod` and emits it.
6. `feishu_app_proxy` handler receives it, decides this is `/new-thread`,
   and emits a `tool_invoke` directive. AdapterChannel forwards to
   PeerServer as
   `{:tool_invoke, req_id, "session.create", args, reply_pid,
   "ou_abc123"}` (args include `"workspace_name" =>
   "coordinator-prod"`).
7. PeerServer intercepts in the `handle_info({:tool_invoke, ...})` clause.
8. **Lane B** — check `has(ou_abc123,
   "workspace:coordinator-prod/session.create")`.
   - Capabilities file says `ou_abc123` holds this. ✅
9. Tool runs, new thread session is created. The new session is registered
   with `principal_id: "ou_abc123"` and `workspace_name:
   "coordinator-prod"` (inherited), so any subsequent tool_invoke from
   that session carries both.

**Denial case**: if step 8 fails, PeerServer returns `{:error,
:unauthorized}` to `feishu_app_proxy`. Handler catches, emits a `reply`
directive: `"❌ 无权限执行 session.create（请联系管理员授权）"`.
Adapter sends that to Feishu as a normal reply.

## 11. Error handling & operational concerns

- **Malformed YAML**: refuse to swap snapshot; keep previous; log
  "capabilities file has syntax error at line X; keeping previous
  capabilities".
- **Unknown permission referenced**: same — refuse swap, log which
  permission and which principal.
- **Workspace name referenced but not in `workspaces.yaml`**: warn only,
  keep the capability (the workspace may be added later).
- **Principal with zero capabilities**: valid; effectively a
  notation-only entry (useful to document "this user exists but has no
  access").
- **Log taxonomy** (all via existing `Logger` + `:telemetry`):
  - `info` — snapshot reload, file changed, capability added/revoked via
    CLI
  - `warn` — workspace name not yet configured, principal with empty
    capabilities, bootstrap file created
  - `error` — malformed YAML, unknown permission, refusing to swap

## 12. Acceptance criteria

- [ ] `Esr.Permissions.Registry.all/0` returns the declared permissions
  from every loaded handler & adapter.
- [ ] Loading `capabilities.yaml` with a typo in a permission name logs
  an error and keeps the previous snapshot.
- [ ] Lane A test: a user whose capabilities do not include `msg.send`
  for the target workspace sends a DM; adapter emits no event and sends
  exactly one rate-limited deny DM within a 10-minute window.
- [ ] Lane B test: a user holding `msg.send` but not `session.create`
  sends `/new-thread`; PeerServer denies, handler emits `"❌ 无权限..."`
  reply.
- [ ] Lane B test: an admin (holding `"*"`) can invoke both.
- [ ] Workspace scoping: a user whose capabilities include
  `workspace:proj-a/session.create` cannot create sessions in
  workspace `proj-b`.
- [ ] Editing `capabilities.yaml` on disk takes effect within 2 seconds
  without restart.
- [ ] `esr cap list` shows every permission declared by a registered
  handler/adapter.
- [ ] `esr cap grant ou_xxx workspace:proj-a/session.create` writes the
  YAML, preserves existing comments, and the capability is live within 2
  seconds.
- [ ] `esr cap revoke` on a non-existent capability is a no-op (exit 0,
  message "no matching capability").
- [ ] `esr cap who-can workspace:*/msg.send` lists every principal whose
  capabilities match the pattern.
- [ ] Bootstrap: with empty file + `ESR_BOOTSTRAP_PRINCIPAL_ID=ou_xyz`,
  runtime creates the file on first boot with `ou_xyz` holding `["*"]`.
- [ ] Phase CAP-0 acceptance: all references to
  `esr.verify.capability.scan_adapter` are renamed to
  `esr.verify.io_permission.scan_adapter`; all tests named
  `test_capability.py` are renamed to `test_io_permission.py`; the full
  test suite remains green after rename.

## 13. Open questions

None currently. If one surfaces during planning, it returns here for user
resolution before plan execution begins.

## 14. Touch list (files added / changed)

### 14.1 Phase CAP-0 — rename `capability` → `io_permission`

**Renamed files** (git mv):
- `py/src/esr/verify/capability.py` → `py/src/esr/verify/io_permission.py`
- `py/tests/test_capability.py` → `py/tests/test_io_permission.py`
- `adapters/feishu/tests/test_capability.py` →
  `adapters/feishu/tests/test_io_permission.py`
- `adapters/cc_tmux/tests/test_capability.py` →
  `adapters/cc_tmux/tests/test_io_permission.py`

**Modified files** (import/reference updates, no behavior change):
- `py/src/esr/verify/__init__.py` — update re-export
- `py/src/esr/adapter.py` — update docstring reference
- `py/src/esr/cli/main.py:447,452` — update import
- `py/tests/test_adapter_loader.py` — update import if present
- `docs/superpowers/prds/02-python-sdk.md` — update reference at line 79
- `docs/superpowers/prds/07-cli.md` — update reference at line 33
- `docs/superpowers/prds/04-adapters.md` — rename references
- `docs/superpowers/glossary.md` — rename entry
- `docs/superpowers/traceability.md` — update
- `docs/superpowers/specs/2026-04-18-esr-extraction-design.md` — update
  references (the authoritative spec that introduced the term)
- `docs/superpowers/tests/e2e-platform-validation.md` — update references
- `README.md` — update if it references capability
- `docs/design/*.md` (Socialware-Packaging, ESR-Reposition,
  esrd-reference-implementation, ESR-Protocol, ESR-Governance) — update
  references where relevant
- `adapters/*/esr.toml` — no change (field `allowed_io` is unchanged; the
  file has no "capability" word)

**Note**: the symbol name `scan_adapter` stays; only the module path
changes. Leaves no shim — callers just update their imports.

### 14.2 Capabilities subsystem — new files

**New files**:
- `runtime/lib/esr/permissions.ex` — top-level API for the permissions
  registry
- `runtime/lib/esr/permissions/registry.ex` — ETS-backed permission registry
- `runtime/lib/esr/capabilities.ex` — `has?/2`, check API, telemetry
- `runtime/lib/esr/capabilities/grants.ex` — ETS-backed grant snapshot
- `runtime/lib/esr/capabilities/file_loader.ex` — YAML parse, fs_watch,
  validation (cross-checks workspace names against
  `Esr.Workspaces.Registry`)
- `runtime/lib/esr/capabilities/supervisor.ex` — supervision tree for the
  above
- `py/src/esr/permissions.py` — Python-side helper to aggregate
  `@handler(permissions=[...])` into `all_permissions()` for the IPC
  handshake
- `py/src/esr/capabilities.py` — Python-side check (shared by adapters for
  Lane A)
- `py/src/esr/cli/cap.py` — `@cli.group()` cap commands
- `docs/superpowers/prds/08-capabilities.md` (to be created during
  writing-plans)

### 14.3 Capabilities subsystem — modified files

- `runtime/lib/esr/peer_server.ex` — insert Lane B check in the two
  `handle_info` clauses at lines 216 and 232; extend `{:tool_invoke, ...}`
  tuple arity from 5 to 6 (adds `principal_id`)
- `runtime/lib/esr/application.ex` — start the
  `Esr.Capabilities.Supervisor`
- `runtime/lib/esr_web/adapter_channel.ex` — require `principal_id` and
  `workspace_name` on inbound event frames; relay them onto the envelope
- `runtime/lib/esr_web/channel_channel.ex` — read `principal_id` from
  session registration frame; inject into `{:tool_invoke, ...}`
- `runtime/lib/esr/session_registry.ex` — add `principal_id` and
  `workspace_name` fields to registered session records; propagate on
  session spawn
- `adapters/feishu/src/esr_feishu/adapter.py` — insert Lane A check in the
  three `msg_received` emit sites (lines 427, 579, 628); load
  `workspaces.yaml` at startup for the `(chat_id, app_id) →
  workspace_name` map; add inline deny-rate-limit dict
- `py/src/esr/handler.py` — extend `@handler(...)` decorator with
  `permissions: list[str] | None = None` keyword arg; store on
  `HandlerEntry`; expose `all_permissions()` helper
- `py/src/esr/ipc/adapter_runner.py` — include adapter+handler permissions
  in `handler_hello` IPC envelope
- `py/src/esr/cli/main.py` — register new `@cli.group()` cap
- `runtime/mix.exs` — add `:file_system` to `deps/0` (currently only
  transitive via Phoenix, not directly declared)
- `py/pyproject.toml` — add `ruamel.yaml` for comment-preserving YAML
  writes

### 14.4 Config artifacts

- `~/.esrd/default/capabilities.yaml.example` — seed, ships with the repo at
  `etc/capabilities.yaml.example`

### 14.5 Third-party libraries (decision log)

After surveying the Elixir authz ecosystem (Bodyguard, LetMe, Permit,
Janus, Ash.Policy), none are a drop-in fit: they all assume authorization
rules are expressed as **code at compile time**, whereas this design needs
rules expressed as **data in a hot-reloadable YAML file**, keyed by
`principal_id` with wildcard scope matching. We reuse mature libraries
for infrastructure only.

**Libraries used**:
- `:file_system` (Elixir, pulled in explicitly via `runtime/mix.exs`) —
  fs_watch for capabilities.yaml hot-reload
- `:yaml_elixir` (Elixir, already a direct dep) — YAML parse
- `ruamel.yaml` (Python, new dep in `py/pyproject.toml`) —
  comment-preserving YAML writes for `esr cap grant` / `revoke`

**Libraries evaluated but rejected**:
- **Bodyguard** — policy-based, Phoenix-controller-coupled; embedding our
  real logic inside `authorize/3` callbacks would defeat its value.
- **LetMe** — DSL-based compile-time policy declaration with Dialyzer
  typing and introspection. Closest fit for the *declaration* side (could
  replace the `permissions/0` callback). Rejected for v1 per YAGNI — the
  plain callback is simpler and we can adopt LetMe later if its
  introspection becomes needed. Noted as a future-work option.
- **Permit** (Curiosum) — subject-action-resource model, framework-coupled
  to Phoenix/Ecto/Absinthe; irrelevant to our GenServer routing path.
- **Janus** — Ecto-query-scoping-focused; inapplicable (no Ecto schemas
  in the enforcement path).
- **Ash.Policy** — locked to Ash framework; not in our dependency tree.

**Core logic we write ourselves** (≈200 lines across new modules in
§14.2): ETS-backed capability snapshot, wildcard match function, YAML
loader + validator, supervisor glue. Narrow and fully testable in
isolation.

## 15. Sequencing notes for writing-plans

Phase ordering is **load-bearing for safety**: declarations must be in
place before enforcement flips on, otherwise the default-deny policy
bricks every operation during the gap.

- **Phase CAP-0** — Rename `capability` → `io_permission` across all
  files listed in §14.1. Single coherent commit. Tests stay green.
  **Purpose**: frees the word "capability" for its only meaning in the
  rest of the system.
- **Phase CAP-1** — `Esr.Permissions` + `Esr.Capabilities` scaffold:
  Registry + Grants ETS + file_loader + Supervisor. No enforcement, no
  CLI. Pure unit tests.
- **Phase CAP-2** — Permission declaration migration:
  (a) add `permissions/0` to every Elixir handler/adapter,
  (b) add `permissions=[...]` kwarg to every Python `@handler(...)` site,
  (c) extend `handler_hello` IPC to surface Python permissions. After
  CAP-2 the Registry is populated at boot.
- **Phase CAP-3** — Envelope extension: `principal_id` + `workspace_name`
  required fields on inbound events and `tool_invoke` tuples. No checking
  yet; ensure fields are present end-to-end. Includes SessionRegistry
  new fields and CC-session registration-frame extension.
- **Phase CAP-4** — Lane B in PeerServer. Now that envelopes carry
  `principal_id` and permissions are declared, flip on the check.
  Integration test covers deny path → reply directive.
- **Phase CAP-5** — Lane A in Feishu adapter. Integration test covers
  rate-limited deny DM.
- **Phase CAP-6** — `esr cap` CLI read commands (`list`, `show`,
  `who-can`).
- **Phase CAP-7** — `esr cap` CLI write commands (`grant`, `revoke`)
  using `ruamel.yaml` for comment-preserving writes.
- **Phase CAP-8** — Bootstrap env var + first-run file creation + seed
  `capabilities.yaml.example`.
- **Phase CAP-9** — Acceptance E2E test covering all §12 scenarios
  (lives in a new `docs/superpowers/tests/e2e-capabilities.md` with
  track-by-track scripts, following the v0.1 `e2e-platform-validation.md`
  pattern).
