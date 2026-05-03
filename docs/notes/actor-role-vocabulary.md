# Actor / role suffix vocabulary — canonical taxonomy

**Date:** 2026-04-29 (PR-21u, restructured PR-21v).
**Why this doc exists:** PR-21q-t introduced "chat-guide" / "user-guide" inline functions that drifted from the rest of the codebase's `*Handler` / `*Adapter` convention. PR-21v formalized the answer: every ESR-specific module belongs to **exactly one of 5 role categories**, marked at compile time via `@behaviour Esr.Role.<Category>`.

**Read this before:**
- Adding any new module under `Esr.*`, `Esr.Entities.*`, `Esr.Admin.*`, `Esr.Workspaces.*`, `Esr.Users.*`, `Esr.Capabilities.*`, or `EsrWeb.*` (except Phoenix framework imports).
- Refactoring inline logic into a dedicated module — pick the right suffix based on the category your module sits in.
- Discussing routing / pipeline architecture in spec docs (use canonical names).

## The 5 categories

| Category | What it does | Suffixes | Behavior marker |
|---|---|---|---|
| **Boundary** | Crosses ESR ↔ outside-world (foreign protocols, networks) | `*Adapter` | `@behaviour Esr.Role.Boundary` |
| **State** | Holds long-lived state (singleton / registry / OS resource) | `*Server`, `*Registry`, `*Process`, `*Buffer` | `@behaviour Esr.Role.State` |
| **Pipeline** | Inbound/outbound message-chain participant | `*Proxy`, `*Handler`, `*Guard`, `*Router` | `@behaviour Esr.Role.Pipeline` |
| **Control** | Admin / configuration / lifecycle ops | `*Dispatcher`, `*Watcher`, `*FileLoader`, `Commands.<Kind>`, `*Bootstrap`, `*Writer` | `@behaviour Esr.Role.Control` |
| **OTP** | Pure OTP plumbing (supervisors) | `*Supervisor` | `@behaviour Esr.Role.OTP` |

Every ESR-specific module declares its category via `@behaviour Esr.Role.<Category>` near the top. Run:

```bash
grep -rln '@behaviour Esr.Role.Pipeline' runtime/lib/
```

to enumerate every module of a given category. The behaviors themselves are empty (one optional `__role__/0` callback) — they're compile-time markers, not enforcement. Future PRs may upgrade a category to active enforcement (e.g. require all `*Guard` modules to implement `check/2`); the marker is the migration path.

## Out of scope (NOT tagged with `Esr.Role.*`)

These are framework imports or generic OTP, not ESR-invented roles. They keep their conventional names but don't get a category marker:

- **`*Channel`** — Phoenix Channels (`EsrWeb.AdapterChannel`, `HandlerChannel`, `CliChannel`, `ChannelChannel`). Pure Phoenix.
- **`*Socket`** — Phoenix Sockets (`EsrWeb.AdapterSocket`, `HandlerSocket`, `ChannelSocket`). Pure Phoenix.
- **`Endpoint`, `Router`** under `EsrWeb` — Phoenix machinery.
- **`Esr.Application`** — OTP Application module.
- **`Esr.Entity.Stateful`** behavior itself — defines a callback contract for Pipeline peers, but is structural plumbing, not a role.

## Each category in depth

### Boundary

**Identifying property:** speaks BOTH the ESR envelope shape (spec §7.5) on one side AND a foreign protocol (Feishu lark_oapi, MCP stdio, etc.) on the other. One per configured remote endpoint / `instance_id`.

**Examples:**
- `Esr.Entities.FeishuAppAdapter` — one per `adapters.yaml` `instances:` row of `type: feishu`.

**Future Boundary modules likely:**
- `Esr.Entities.SlackAdapter`, `Esr.Entities.MattermostAdapter`, `Esr.Entities.MCPAdapter` (any new chat platform).

### State

**Identifying property:** holds state that persists across many inbound messages. Sub-shapes:

| Suffix | Shape | Examples |
|---|---|---|
| `*Server` | Singleton with mutation-heavy state (often GenServer + ETS) | `Esr.Entity.Server` |
| `*Registry` | Read-mostly ETS snapshot; reads bypass GenServer | `Esr.SessionRegistry`, `Esr.Entity.Registry`, `Esr.AdapterSocketRegistry`, `Esr.Workspaces.Registry`, `Esr.Users.Registry`, `Esr.Permissions.Registry`, `Esr.Capabilities.Grants` |
| `*Process` | Wraps an OS process or external-resource lifecycle | `Esr.Scope.Process`, `Esr.Scope.Admin.Process`, `Esr.OSProcess`, `Esr.PyProcess`, `Esr.Entities.CCProcess`, `Esr.Entities.TmuxProcess` |
| `*Buffer` | Bounded ring buffer / FIFO | `Esr.Telemetry.Buffer` |

### Pipeline

**Identifying property:** invoked once per inbound message; transforms or routes the message; output goes to the next pipeline node. Sub-shapes:

| Suffix | Shape | Examples |
|---|---|---|
| `*Proxy` | Per-entity local representative; forwards on its behalf | `Esr.Entities.FeishuChatProxy`, `Esr.Entities.FeishuAppProxy`, `Esr.Entities.CCProxy`, `Esr.Entities.VoiceTTSProxy`, `Esr.Entities.VoiceASRProxy` |
| `*Handler` | Parses or dispatches one class of inbound | `Esr.Entities.SlashHandler` |
| `*Guard` | **Inbound gate** — checks condition, drops/passes, optional side effects, has its own rate-limit/TTL state | (TBD — see Migration plan) |
| `*Router` | Picks destination from a config table | `Esr.Scope.Router`, `Esr.HandlerRouter` |
| (no suffix) | Domain peer when no role suffix fits | `Esr.Entities.VoiceTTS`, `Esr.Entities.VoiceASR`, `Esr.Entities.VoiceE2E` |

#### `*Guard` identification (4-point checklist)

A module is a `*Guard` (and should bear that suffix) when ALL of these hold:

1. **Invoked per-message** during inbound handling, BEFORE the routing layer decides where the message goes.
2. **Has its own internal state** beyond GenServer trivium — typically a rate-limit cache, a TTL ledger, or a pending-action map.
3. **Returns one of:** `:passthrough` / `{:guarded, new_state}` / `{:consume, verdict}` / similar — i.e., the caller hands control over for the immediate message.
4. **The check is conditional on runtime state** (a binding shows up, a cap is granted, a TTL expires) — distinguishing it from a static permission check (which would be inline in a Handler or in the cap system).

### Control

**Identifying property:** operates on configuration / runtime state out-of-band from the inbound message chain.

| Suffix | Shape | Examples |
|---|---|---|
| `*Dispatcher` | Async cmd-queue brain; per-kind required-permission table; spawns per-cmd Tasks | `Esr.Admin.Dispatcher` |
| `*Watcher` | FSEvents file-change observer; calls a `*FileLoader` | `Esr.Capabilities.Watcher`, `Esr.Workspaces.Watcher`, `Esr.Users.Watcher` |
| `*FileLoader` | YAML parse + atomic snapshot swap; non-destructive on parse failure | `Esr.Capabilities.FileLoader`, `Esr.Users.FileLoader` |
| `Commands.<Kind>` | Single admin-command implementation (pure module) | `Esr.Admin.Commands.{Cap.Grant, Cap.Revoke, Session.New, Session.End, Session.List, Workspace.New, Workspace.Info, Notify, Reload, …}` |
| `*Bootstrap` | Boot-time initialization | `Esr.Permissions.Bootstrap` |
| `*Writer` | YAML / config file writers (round-trip safe) | `Esr.Yaml.Writer` |

### OTP

**Identifying property:** pure OTP supervisor — manages child process tree.

**Examples:** `Esr.WorkerSupervisor`, `Esr.Scope.Supervisor`, `Esr.Entity.Supervisor`, `Esr.Workspaces.Supervisor`, `Esr.Users.Supervisor`, `Esr.Capabilities.Supervisor`, `Esr.Admin.Supervisor`.

Convention: only Supervisor modules get the OTP marker. If a GenServer also happens to start child processes, it picks the category that describes its primary role (usually State or Control).

## Migration plan (gate-shaped logic that should adopt `*Guard`)

These are gate-shaped today but don't yet bear the `*Guard` suffix. PR-21v added `Esr.Role.Pipeline` markers but did NOT extract them into Guard modules — that follows in PR-21w.

| Current location | Proposed module | Tracking |
|---|---|---|
| `EsrWeb.PendingActions` | `EsrWeb.PendingActionsGuard` | Rename only; ~10 LOC |
| `maybe_emit_unbound_chat_guide` (inline in `Esr.Entities.FeishuAppAdapter`) | `Esr.Entities.UnboundChatGuard` | Extract module; ~80 LOC |
| `maybe_emit_unbound_user_guide` (inline in `FeishuAppAdapter`) | `Esr.Entities.UnboundUserGuard` | Extract module; ~80 LOC; could share base behavior with above |
| Inline Lane B cap check (in `Esr.Entity.Server`) | `Esr.Entities.CapGuard` | Larger refactor; touches PeerServer state shape |
| `deny_dm_last_emit` / `guide_dm_last_emit` state in FAA | Move into the relevant `*Guard` module | Part of the above two extractions |

## When introducing a new suffix

If a new behaviour shape doesn't fit any existing suffix, add a row to this doc BEFORE merging the code that uses the new name. **Repo policy:**

1. New role suffix needs a one-paragraph definition here, including the identifying properties (analogous to `*Guard`'s 4-point list).
2. Decide which **category** it belongs to, OR justify creating a new one.
3. List existing modules that should adopt the new suffix, even if just as a future-work item.
4. PR description references this doc and explicitly says "introduces new suffix `*X` under category `<Y>`".

This prevents the drift that produced the chat-guide / user-guide naming inconsistency.

## Verifying compliance

Two greps to keep the codebase honest:

```bash
# 1. Every ESR-specific module should have ONE @behaviour Esr.Role.X marker.
#    (Find untagged modules — investigate; either tag them or document why exempt.)
diff <(grep -rln '@behaviour Esr.Role' runtime/lib/esr | sort) \
     <(find runtime/lib/esr -name '*.ex' | sort)

# 2. Per-category module inventory.
for cat in Boundary State Pipeline Control OTP; do
  echo "=== $cat ==="
  grep -rln "@behaviour Esr.Role.$cat" runtime/lib/ | sort
done
```

Phoenix `*Channel` / `*Socket` / `EsrWeb.{Endpoint, Router}` and `Esr.Application` / `Esr.Entity.Stateful` are intentional exemptions (framework imports / structural plumbing).

## Related

- `docs/notes/esr-uri-grammar.md` — cross-process addressing (the URI scheme that runs alongside actor names).
- `docs/superpowers/glossary.md` — broader project vocabulary (esr user, workspace, session, …).
- `docs/architecture.md` §"Cross-boundary addressing" — high-level pointer.
