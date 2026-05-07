# Spec: Metamodel-Aligned ESR — Session-First, Multi-Agent, Colon-Namespace, Plugin-Config-3-Layer

**Date:** 2026-05-07
**Status:** rev-2 (DRAFT — pending user review)
**Branch:** `spec/metamodel-aligned-esr`
**Companion file:** [`2026-05-07-metamodel-aligned-esr.zh_cn.md`](2026-05-07-metamodel-aligned-esr.zh_cn.md)

**Supersedes (content absorbed, branches preserved as reference):**
- `spec/colon-namespace-grammar` branch — `docs/superpowers/specs/2026-05-07-colon-namespace-grammar.md` → content absorbed into §4
- `spec/plugin-set-config` branch — `docs/superpowers/specs/2026-05-07-plugin-set-config.md` → content absorbed into §6 (with corrections)

---

## §0 — Locked Decisions

All decisions below were locked by the user in Feishu dialog on **2026-05-06 to 2026-05-07**. They are cited verbatim; the spec does not re-debate them.

### Round 1 (Q1-Q5, 2026-05-06)

- **Q1=A**: Same agent type, multiple instances are permitted within a session; instances are differentiated by `@<name>` addressing.
- **Q2=A** (later refined to **Q7=B**): `@<agent_name>` mention parsing — plain text simple string match. See Q7 for the final form.
- **Q3=C with twist**: Per-session workspace is the primary workspace. Chat-default workspace is an optional fallback used when no per-session workspace exists.
- **Q4=multi-scope per chat with attach**: One chat may have N parallel scopes (sessions). Use `/session:attach <uuid>` to join an existing session in the current chat. Cross-user attach is capability-gated (requires explicit cap grant).
- **Q5=一气呵成**: Ship all changes in one coherent migration sequence, not as independently-released features.

### Round 2 (Q6-Q10, 2026-05-06)

- **Q6=D**: Operator sets the primary agent via `/session:set-primary <name>`. Default = first agent added to the session.
- **Q7=B**: Plain text `@<name>` uses simple string match in raw message text (no platform mention API). A lone `@` character not followed by an alphanumeric character is treated as plain text and ignored by the mention parser. **Agent names must be globally unique within a session, regardless of agent type.**
- **Q8=A**: Each chat maintains a "currently-attached session" pointer. Plain text that contains no `@<name>` mention is routed to the primary agent of the currently-attached session.
- **Q9=C**: Both imperative form (`/session:share`) and declarative form (capability yaml) are supported for session sharing. The imperative command is syntactic sugar that performs a `/cap:grant` behind the scenes.
- **Q10=C**: Session is a first-class resource. `$ESRD_HOME/<inst>/sessions/<session_uuid>/` IS itself a workspace — the session's auto-transient workspace. Sessions are not workspace-scoped; workspaces are session-referenced.

### Round 3 (Q11 + corrections + Round-3 user decisions, 2026-05-07)

- **Q11=B**: 3-layer plugin config with precedence **workspace > user > global**. Resolution is per-key. The three layers are: global, user, workspace.
- **User insight**: Every user gets a personal workspace. Directory uses **user UUID** (see D1 below).
- **Drop `/session:add-folder`**: Folders are managed at the workspace level.
- **`/key` → `/pty:key`**: PTY resource group, not session.
- **Drop `/workspace:sessions`**: Workspace must not know about sessions.
- **Drop `@deprecated_slashes` map**: Hard cutover with no fallback.
- **feishu manifest must include `app_id` + `app_secret` in `config_schema:`**.
- **`depends_on:` field validated at plugin load** at `Loader.start_plugin/2` time.
- **Per-key merge for config layers**: global → user → workspace.
- **Drop `sensitive:` flag** from `config_schema:` entirely.
- **Only esrd's own env vars in launchd plist**: `ESRD_HOME`, `ESRD_INSTANCE`, `ANTHROPIC_API_KEY`.

### Round-3 User Decisions (D1-D8, 2026-05-07) — Locked

**D1 — User UUID identity: included in this redesign.**
Today users are identified by `username` (string). This phase introduces user UUID identity, parallel to PR-230's workspace UUID model:
- Each user gets a UUID v4 stored in `user.json.id`.
- `username` becomes a mutable display alias (rename allowed; UUID is stable).
- New `Esr.Entity.User.NameIndex` for username ↔ UUID bidirectional lookup.
- User directory path: **`$ESRD_HOME/<inst>/users/<user_uuid>/`** (NOT `<username>/`).
- The directory contains `user.json` (identity + alias + metadata) + `.esr/workspace.json` (the user-default workspace) + `.esr/plugins.yaml` (user-layer plugin config).
- At boot, `users.yaml` is parsed; each entry without a UUID is assigned one and the file is written back atomically.
- A new phase (Phase 1b — User UUID migration) is inserted between Phase 1 (session UUID) and the former Phase 2 (chat-current rewire). See §7.

**D2 — Session naming: human-friendly name + UUID dual-track; caps accept UUID ONLY at input.**
Session has both `id` (UUID, immutable) and `name` (mutable display alias). Critical contract:
- Workspace caps accept BOTH name (translated to UUID at input) and UUID. (PR-230 pattern.)
- **Session caps accept ONLY UUID at input.** Name input is REJECTED at every surface: CLI, slash dispatcher, yaml validation. Reasoning: session names are scoped to `(owner_user, name)` per D6 — not globally unique. UUID-only at input eliminates ambiguity.
- At OUTPUT side (e.g. `/cap:show` rendering), UUID → name translation IS done for human readability (same `UuidTranslator` pattern, output-only for sessions).
- Cap strings: `session:<uuid>/attach`, `session:<uuid>/add-agent`, `session:<uuid>/end`, `session:<uuid>/share` — UUID ONLY at input.

**D3 — `/session:new` auto-attach to creating chat: YES (locked behavior).**
When a session is created, it is automatically attached to the creating chat and set as the attached-current pointer. This is locked behavior, not a proposal.

**D4 — `/session:share` default permission: `perm=attach` (locked).**
`/session:share <session_uuid> <user>` defaults to `perm=attach`. This is the safer default: attach allows use but not management.

**D5 — `esr cap grant` escript: rejects `session:<name>/...` — UUID-only at input (locked).**
The `esr cap grant` CLI escript rejects any cap string of the form `session:<name>/...`. Only `session:<uuid>/...` is accepted. This applies everywhere caps are input: CLI, slash dispatcher, yaml.

**D6 — Session name uniqueness scope: `(owner_user, name)` tuple (locked).**
Session names are unique within the `(owner_user, name)` namespace, not globally. Two different users may each have a session named `esr-dev`. The registry name index uses a composite key: `{owner_user_uuid, name}`.

**D7 — User-layer config path: `users/<user_uuid>/.esr/plugins.yaml` (locked).**
Confirmed. Important consequences:
1. No migration from any prior draft `users/<username>/plugins.config.yaml` path — that was hypothetical, never shipped.
2. Post-deploy `.esrd/` + `.esrd-dev/` wipe required: after this redesign ships, operators must clean their existing `$ESRD_HOME/<inst>/` directories. The new Bootstrap rebuilds from scratch. See §11.

**D8 — Plugin manifest `depends_on.core` version check: included in this batch (Phase 7).**
`Esr.Plugin.Manifest` parses `depends_on.core` as a SemVer constraint string (e.g. `">= 0.1.0"`). At plugin load, compare against ESR's own version (read from `runtime/mix.exs`). Reject load if constraint is not satisfied. A small helper module `Esr.Plugin.Version` wraps Elixir's stdlib `Version` module. Approximately 80 LOC for check + tests. Phase 7 LOC estimate updated accordingly.

### Post-Round-3 Locked Summary (for reference)

- User UUID identity in this batch (round-3 decision 2026-05-07).
- Session caps UUID-only contract at input; name accepted at output only.
- Post-deploy ESRD_HOME wipe required (no in-place migration).
- `depends_on.core` SemVer check in Phase 7.
- `/session:new` auto-attach confirmed (D3).
- `/session:share` default `perm=attach` confirmed (D4).
- `esr cap grant` rejects `session:<name>` (D5).
- Session name unique within `(owner_user, name)` (D6).

---

## §1 — Motivation

### The gap between the metamodel and the implementation

`docs/notes/concepts.md` (rev 9, 2026-05-03) defines ESR's Tetrad Metamodel. The metamodel's four runtime primitives are:

- **Scope** — a bounded domain that holds a membership set of Entities and Resources.
- **Entity** — an actor with identity; uses Resources; implements Interfaces.
- **Resource** — an object used by Entities; finite and countable.
- **Interface** — a contract (trait) implemented by Entities and Resources.

Plus one declarative primitive:

- **Session** — the declarative description (kind + wiring) of a Scope. `use SomeSession` produces a concrete Scope instance.

The metamodel's canonical example (§九) shows a group-chat Scope of kind `GroupChatSession` containing:
- Entities: `user-alice` (human), `user-bob` (human), `agent-cc-α` (AI), `agent-codex-β` (AI future)
- Resources: `channel-shared` (implements ChannelInterface), `dir-/repo/main` (implements DirInterface), capability subset
- Interface contracts: MemberInterface on all Entities, ChannelInterface on the shared channel

This is the target architecture. The implementation diverged from it in four critical ways before this spec.

**Gap 1: workspace-first instead of session-first.**

Today, a workspace must be registered before a session can be created. The operator's bootstrap flow assumes the opposite: `/session:new` → `/workspace:add <path>` → `/agent:add cc name=esr-developer`. PR #230 fixed workspace storage. This spec fixes session primacy.

**Gap 2: one agent per session instead of N.**

Today, `ChatScope.Registry` maps `(chat_id, app_id)` → one `session_id`. Each session has at most one CC process. The metamodel explicitly puts `agent-cc-α` and `agent-codex-β` as peer Entities in the same group-chat Scope.

**Gap 3: inconsistent slash grammar.**

ESR's slash grammar today mixes dash (`/new-session`, `/list-agents`), space (`/workspace info`, `/plugin install`), and no-separator forms. A consistent `<group>:<verb>` form simplifies operator mental load.

**Gap 4: no operator-set plugin config.**

Per-plugin tuning requires editing `scripts/esr-cc.local.sh`, a shell fragment that only works for one operator on one machine and has no multi-user, multi-workspace story.

### What PR #230 fixed (prior art this spec builds on)

PR #230 (workspace UUID redesign) introduced:
- UUID-identified workspaces with a name → UUID index (`Esr.Resource.Workspace.NameIndex`)
- Hybrid storage: ESR-bound and repo-bound workspaces
- The 14 `/workspace:*` slash commands
- `Esr.Resource.Capability.UuidTranslator` for `workspace:<name>` → `workspace:<uuid>` translation at CLI edges (both directions accepted for workspace)
- Two-ETS-table pattern: legacy name-keyed table + new UUID-keyed table

This spec extends the UUID pattern to sessions AND users, adds the 3-layer plugin config, and aligns the full slash surface.

### Goals

1. **Session-first**: session creation produces its own workspace automatically (auto-transient at `sessions/<uuid>/`).
2. **Multi-agent**: each session holds N agent instances; `@<name>` routing; primary-agent fallback.
3. **User UUID identity**: users get UUID-stable identity; username is a mutable alias (D1).
4. **Consistent slash grammar**: one canonical `/<group>:<verb>` form; hard cutover.
5. **Operator plugin config**: 3-layer YAML-backed config; manifest `config_schema:`.
6. **One migration**: all changes shipped as one coordinated sequence of PRs, in dependency order.

### Non-goals (deferred)

- **Hot-reload of plugin config**: restart-required for Phase 1. Hot-reload is Phase 2 and out of scope.
- **Remote plugin install**: `/plugin:install` continues to accept local paths only.
- **Declarative SessionSpec YAML**: the spec defines the `session.json` runtime state file; a higher-level declarative `SessionSpec` YAML is a future phase.
- **Session branching / worktree fork on session:new**: the existing worktree-fork logic is preserved unchanged.

---

## §2 — The New Model

### Mapping metamodel primitives to concrete implementation

| Metamodel Primitive | Concrete Implementation | Status |
|---|---|---|
| **Scope** | Chat-attached session instance, UUID-identified; `Esr.Resource.Session.*` | New (Phase 1) |
| **Entity (human)** | `Esr.Entity.User` (UUID-keyed, `user.json` + `users.yaml` NameIndex) | Extended in Phase 1b |
| **Entity (agent instance)** | `{type, name}` pair within a session; `Esr.Entity.Agent.Instance` | New (Phase 3) |
| **Resource (workspace)** | `Esr.Resource.Workspace.*` (PR-230); session's auto-transient workspace at `sessions/<uuid>/` | Existing; auto-transient pattern is new |
| **Resource (channel)** | Feishu chat (`chat_id` + `app_id` pair); `Esr.Entity.FeishuChatProxy` | Existing |
| **Resource (capability)** | `Esr.Resource.Capability.*`; symbol + grant binding | Existing; new cap scopes in Phase 5 |
| **Interface** | Role traits: `MemberInterface`, `ChannelInterface`, etc. | Defined in `docs/notes/actor-role-vocabulary.md` |
| **Session (declarative)** | `session.json` captures runtime instance state (agents, attached chats, primary, workspace binding) | New (Phase 1) |

### Structural comparison: before and after

**Before (current state on `origin/dev`):**

```
1 chat
└── 1 workspace (registered first)
    └── 1 session (created second)
        └── 1 CC agent (plugin-declared, always of type cc)
```

**After (this spec):**

```
1 chat
└── attached-set: [session_A (current), session_B, ...]
    session_A
    ├── workspace: sessions/<uuid>/ (auto-transient) or workspaces/<name>/ (named)
    ├── agents: [{cc, "esr-dev"} (primary), {codex, "reviewer"}, ...]
    └── attached_chats: [{chat_id, app_id, attached_by, attached_at}, ...]
```

Data flow for incoming message:
```
chat_id + app_id
→ ChatScope.Registry (attached-set lookup)
→ current session_id
→ MentionParser (scan for @<name>)
→ if mention found: route to named agent instance
→ if no mention: route to primary agent
→ agent PID
```

### Diagram: Example chat with 2 sessions and 3 agents

```
chat: oc_xxx  (Feishu DM, app_id=cli_yyy)
│
├── attached-set:
│   │
│   ├── session "esr-dev" (uuid=aaa-111) <- attached-current
│   │   ├── workspace_id -> sessions/aaa-111/  (auto-transient workspace.json)
│   │   ├── agents:
│   │   │   ├── type=cc    name="esr-dev"   pid=<0.123.0>  <- primary
│   │   │   └── type=codex name="reviewer"  pid=<0.124.0>
│   │   ├── owner_user: <user_uuid_of_linyilun>
│   │   ├── primary_agent: "esr-dev"
│   │   └── transient: true
│   │
│   └── session "docs" (uuid=bbb-222)        (attached, not current)
│       ├── workspace_id -> workspaces/docs-ws/  (named, shared)
│       ├── agents:
│       │   └── type=cc    name="docs-writer"  pid=<0.125.0>  <- primary
│       ├── owner_user: <user_uuid_of_linyilun>
│       ├── primary_agent: "docs-writer"
│       └── transient: false
│
└── attached-current pointer -> "aaa-111"

Routing examples:
  plain text "fix the test"         -> session aaa-111 -> agent "esr-dev" (primary)
  "@reviewer look at this"          -> session aaa-111 -> agent "reviewer"
  "/session:attach bbb-222"         -> switches attached-current to bbb-222 (UUID only)
  (after attach) plain text "edit"  -> session bbb-222 -> agent "docs-writer" (primary)
```

### The user-default workspace

Per D1 (locked 2026-05-07): every user has a personal workspace at `$ESRD_HOME/<inst>/users/<user_uuid>/`. This workspace:

- Is auto-created when the user is added via `esr user add <name>`.
- Has `kind: "user-default"` in `.esr/workspace.json` (invisible to `/workspace:list`, readable via `/workspace:info name=<username>`).
- Holds the user-layer plugin config at `.esr/plugins.yaml`.
- The directory also contains `user.json` (UUID + username alias + metadata).

The layers correspond exactly to the directory hierarchy:

```
global layer     -> $ESRD_HOME/<inst>/plugins.yaml
user layer       -> $ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml
workspace layer  -> <current_workspace_root>/.esr/plugins.yaml
```

---

## §3 — Storage Layout

### Full directory tree (post-migration)

```
$ESRD_HOME/<inst>/
│
├── plugins.yaml                              # global: enabled list + global plugin config
│                                             # (enabled: [...], config: {plugin: {key: val}})
│
├── workspaces/                               # ESR-bound named workspaces (PR-230)
│   └── <name>/
│       ├── workspace.json                    # workspace identity + folders + chats
│       └── .esr/
│           └── plugins.yaml                  # workspace-layer plugin config (NEW)
│
├── users/                                    # user-default workspaces (NEW in this spec — D1)
│   └── <user_uuid>/                          # keyed by UUID, NOT username (D1)
│       ├── user.json                         # user identity: id, username alias, metadata
│       └── .esr/
│           ├── workspace.json                # this dir IS a workspace; kind="user-default"
│           └── plugins.yaml                  # user-layer plugin config (NEW)
│
└── sessions/                                 # session-default workspaces (NEW, per Q10=C)
    └── <session_uuid>/
        ├── workspace.json                    # auto-transient workspace for this session
        ├── session.json                      # session state: agents, chats, primary, workspace
        └── .esr/
            └── plugins.yaml                  # session-specific config override (rare)
```

At boot, `users.yaml` (existing file) is the source of the username → UUID index. The `Esr.Entity.User.NameIndex` GenServer builds an ETS table from it.

Repo-bound workspace (PR-230 pattern, unchanged):

```
<repo>/
└── .esr/
    ├── workspace.json                        # workspace identity (PR-230)
    └── plugins.yaml                          # workspace-layer plugin config (NEW)
```

### `Esr.Paths` helpers to add

| New Helper | Resolved Path |
|---|---|
| `Esr.Paths.sessions_dir/0` | `$ESRD_HOME/<inst>/sessions/` |
| `Esr.Paths.session_dir/1` | `$ESRD_HOME/<inst>/sessions/<session_uuid>/` |
| `Esr.Paths.session_json/1` | `$ESRD_HOME/<inst>/sessions/<session_uuid>/session.json` |
| `Esr.Paths.users_dir/0` | `$ESRD_HOME/<inst>/users/` |
| `Esr.Paths.user_dir/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/` |
| `Esr.Paths.user_json/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/user.json` |
| `Esr.Paths.user_workspace_json/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/workspace.json` |
| `Esr.Paths.user_plugins_yaml/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml` |
| `Esr.Paths.workspace_plugins_yaml/1` | `<workspace_root>/.esr/plugins.yaml` |

All helpers take `user_uuid` (UUID string), not `username`.

### `user.json` schema (version 1, new in D1)

```json
{
  "schema_version": 1,
  "id": "<user_uuid>",
  "username": "linyilun",
  "display_name": "林懿伦",
  "created_at": "2026-05-07T12:00:00Z"
}
```

Field semantics:
- `id`: UUID v4, generated at user creation. Stable across username renames.
- `username`: mutable display alias. Must be unique across all users in the instance. `Esr.Entity.User.NameIndex` enforces this uniqueness and keeps the `users.yaml` mapping current.
- `display_name`: optional human-readable name (may be empty string).

### `session.json` JSON schema (version 1)

```json
{
  "schema_version": 1,
  "id": "<session_uuid>",
  "name": "<human-friendly name>",
  "owner_user": "<user_uuid>",
  "workspace_id": "<workspace_uuid>",
  "agents": [
    {
      "type": "cc",
      "name": "esr-dev",
      "config": {}
    },
    {
      "type": "codex",
      "name": "reviewer",
      "config": {}
    }
  ],
  "primary_agent": "esr-dev",
  "attached_chats": [
    {
      "chat_id": "oc_xxx",
      "app_id": "cli_xxx",
      "attached_by": "<user_uuid>",
      "attached_at": "2026-05-07T12:00:00Z"
    }
  ],
  "created_at": "2026-05-07T12:00:00Z",
  "transient": true
}
```

Field semantics:

- `id`: UUID v4, generated at session creation. Stable for the session's lifetime.
- `name`: operator-provided string, or auto-generated as `session-<YYYYMMDD-HHMMSS>` if not provided. Must be unique within `(owner_user, name)` per D6 — not globally unique.
- `owner_user`: the **user UUID** of the user who created the session.
- `workspace_id`: UUID of the workspace this session is bound to.
- `agents`: ordered list of agent instances. First entry is the default primary if `primary_agent` is not set.
- `agents[].type`: the plugin name (e.g. `cc`, `codex`).
- `agents[].name`: operator-assigned name; globally unique within this session regardless of type.
- `agents[].config`: per-agent config overrides.
- `primary_agent`: name of the agent receiving un-addressed plain text (Q8=A).
- `attached_chats`: list of chats that have this session in their attached-set. `attached_by` is the **user UUID** who ran `/session:attach`.
- `transient`: if `true`, the workspace at `sessions/<session_uuid>/` is pruned when the session ends and the workspace is clean.

### `workspace.json` for user-default workspace

```json
{
  "schema_version": 1,
  "id": "<workspace_uuid>",
  "name": "<username>",
  "owner": "<user_uuid>",
  "kind": "user-default",
  "folders": [],
  "chats": [],
  "transient": false,
  "created_at": "2026-05-07T12:00:00Z"
}
```

Stored at `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/workspace.json`. Workspace registry skips `kind: "user-default"` entries in `/workspace:list`; allows direct lookup by username via `/workspace:info name=<username>` (translates username → UUID via NameIndex first).

### Session name uniqueness: `(owner_user, name)` scope (D6)

The session registry name-index ETS table uses a composite key: `{owner_user_uuid, session_name}`. Two users may independently name their sessions `esr-dev`. When the `UuidTranslator` resolves a session name at output-only translation, it must scope the lookup to the session owner.

Session cap strings always use UUID at input (D2, D5). Output rendering may show `<name>` for readability.

### Boot migration: `users.yaml` → UUID assignment (D1)

At boot, `Esr.Entity.User.NameIndex` reads `users.yaml`. For each user entry:
- If `user_uuid` field is present in the entry: load and index.
- If `user_uuid` field is absent: generate UUID v4, write back to `users.yaml` atomically, create `users/<user_uuid>/user.json` and `users/<user_uuid>/.esr/workspace.json` if they do not exist.

This migration is non-destructive and idempotent. Any `users/<username>/` directories from prior draft layouts (none shipped) are ignored.

### Boot migration: `ChatScope.Registry` data format

The current ETS format in `Esr.Resource.ChatScope.Registry` stores:

```elixir
# old format, single slot
{{chat_id, app_id}, session_id}
```

This must migrate to:

```elixir
# new format, attached-set
{{chat_id, app_id}, %{current: session_id, attached_set: [session_id]}}
```

Migration location: `Esr.Resource.ChatScope.FileLoader.load/1`. Non-destructive: old `session_id` becomes `current` and the sole element of `attached_set`.

---

## §4 — Slash Surface (Colon-Namespace, Hard Cutover)

### Grammar rules (locked 2026-05-06, with corrections 2026-05-07)

**Rule 1 — Complete switch, no aliases, no fallback helper.**
All slash commands ship in colon form. Old-form input returns `unknown command: /old-form`. No `@deprecated_slashes` map.

**Rule 2 — Multi-word verbs keep the dash inside the verb.**
`/workspace:add-folder`, `/workspace:bind-chat`, `/workspace:import-repo`.

**Rule 3 — No deprecation period.**
One ship, hard cutover.

**Rule 4 — `/help` and `/doctor` stay bare.**
Meta-system discovery commands. No colon prefix.

**Rule 5 — `/key` → `/pty:key`.**
PTY is the resource group, not session.

**Rule 6 — Drop `/workspace:sessions`.**
Workspace must not depend on session.

**Rule 7 — Session slash commands accept UUID only at input (D2, D5).**
`/session:attach`, `/session:end`, `/session:add-agent`, `/session:share`, and all session-scoped `/cap:grant` calls accept ONLY UUID for session identification. Name input is rejected. This differs from workspace commands which accept both name and UUID.

### Full slash inventory

#### A. Existing slashes renamed to colon form

| Old Form | New Form (post-migration) | Transform Rule |
|---|---|---|
| `/help` | `/help` | bare meta — unchanged |
| `/doctor` | `/doctor` | bare meta — unchanged |
| `/whoami` | `/user:whoami` | bare → colon, group=user |
| `/key` | `/pty:key` | bare → colon, group=pty (user correction) |
| `/new-workspace` | `/workspace:new` | dash → colon |
| `/workspace list` | `/workspace:list` | space → colon |
| `/workspace edit` | `/workspace:edit` | space → colon |
| `/workspace add-folder` | `/workspace:add-folder` | space → colon, dash preserved |
| `/workspace remove-folder` | `/workspace:remove-folder` | space → colon, dash preserved |
| `/workspace bind-chat` | `/workspace:bind-chat` | space → colon, dash preserved |
| `/workspace unbind-chat` | `/workspace:unbind-chat` | space → colon, dash preserved |
| `/workspace remove` | `/workspace:remove` | space → colon |
| `/workspace rename` | `/workspace:rename` | space → colon |
| `/workspace use` | `/workspace:use` | space → colon |
| `/workspace import-repo` | `/workspace:import-repo` | space → colon, dash preserved |
| `/workspace forget-repo` | `/workspace:forget-repo` | space → colon, dash preserved |
| `/workspace info` | `/workspace:info` | space → colon |
| `/workspace describe` | `/workspace:describe` | space → colon |
| `/workspace sessions` | **DROPPED** | workspace must not depend on session |
| `/sessions` | `/session:list` | bare → colon, group=session |
| `/list-sessions` (alias of `/sessions`) | removed | covered by `/session:list` |
| `/new-session` | `/session:new` | dash → colon |
| `/session new` (alias of `/new-session`) | removed | covered by `/session:new` |
| `/end-session` | `/session:end` | dash → colon |
| `/session end` (alias of `/end-session`) | removed | covered by `/session:end` |
| `/list-agents` | `/agent:list` | dash → colon, group=agent |
| `/actors` | `/actor:list` | bare → colon, group=actor |
| `/list-actors` (alias of `/actors`) | removed | covered by `/actor:list` |
| `/attach` | `/session:attach` | bare → colon, group=session |
| `/plugin list` | `/plugin:list` | space → colon |
| `/plugin info` | `/plugin:info` | space → colon |
| `/plugin install` | `/plugin:install` | space → colon |
| `/plugin enable` | `/plugin:enable` | space → colon |
| `/plugin disable` | `/plugin:disable` | space → colon |

#### B. New `/session:*` family (all new in Phase 6)

Note: all session-identification arguments accept **UUID only** (D2, D5). Name-based input is rejected with a structured error.

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/session:new` | `[name=X] [worktree=Y] [workspace=W]` | `session:default/create` | Create session + auto-transient workspace at `sessions/<uuid>/`. Auto-attaches to creating chat (D3, locked); sets attached-current. Primary = first agent added. |
| `/session:attach` | `<uuid>` (required; name REJECTED) | `session:<uuid>/attach` | Join existing session in this chat by UUID; sets attached-current pointer. Cross-user attach requires `session:<uuid>/attach` cap. |
| `/session:detach` | (none) | none | Leave the currently-attached session in this chat. Does not end the session. |
| `/session:end` | `[session=<uuid>]` | `session:<uuid>/end` | Terminate session. Prune transient workspace if git worktree is clean. |
| `/session:list` | (none) | `session.list` | List sessions in this chat: names, UUIDs, agent count, attached-current status, workspace name. |
| `/session:add-agent` | `<type> name=X [config_key=val ...]` | `session:<uuid>/add-agent` | Add an agent instance to the current session. `name` must be globally unique within this session. |
| `/session:remove-agent` | `<name>` | `session:<uuid>/add-agent` | Remove an agent instance from the current session. Cannot remove the primary agent unless another is set as primary first. |
| `/session:set-primary` | `<name>` | `session:<uuid>/add-agent` | Set the primary agent for the current session. |
| `/session:bind-workspace` | `<name>` | `session:<uuid>/end` | Rebind the session's workspace from auto-transient to a named workspace. |
| `/session:share` | `<session_uuid> <user> [perm=attach\|admin]` | `session:<uuid>/share` | Grant the specified user the `session:<uuid>/attach` (or `session:<uuid>/*` for admin) capability. Default `perm=attach` (D4, locked). Session identified by UUID only (D2, D5). Sugar over `/cap:grant`. |
| `/session:info` | `[session=<uuid>]` | `session.list` | Show session details: id, name, owner username (translated), workspace binding, agents list, primary agent, attached chats, created time, transient flag. |

#### C. New `/pty:*` family (replaces bare `/key`)

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/pty:key` | `keys=<spec>` (required) | none | Send special keystrokes (up/down/enter/esc/tab/c-X etc.) to the PTY of the chat-current session. |

#### D. New `/plugin:*` config management (all new in Phase 7)

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/plugin:set` | `<plugin> key=value [layer=global\|user\|workspace]` | `plugin/manage` | Set a config key for the named plugin. Key must be declared in the plugin's `config_schema:`. Writes atomically. Prints restart-required hint. Default layer = global. |
| `/plugin:unset` | `<plugin> key [layer=global\|user\|workspace]` | `plugin/manage` | Delete a config key from the named layer. Idempotent. |
| `/plugin:show` | `<plugin> [layer=effective\|global\|user\|workspace]` | `plugin/manage` | Show config. `layer=effective` returns the per-key merged result. |
| `/plugin:list-config` | (none) | `plugin/manage` | Show effective config for all enabled plugins. |

#### E. New `/cap:*` family (slash form of existing `esr cap` escript)

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/cap:grant` | `<cap> <user>` | `cap.manage` | Grant a capability to a user. For `session:` caps, `<cap>` must use UUID (e.g. `session:<uuid>/attach`). Name form `session:<name>/...` is REJECTED (D5). |
| `/cap:revoke` | `<cap> <user>` | `cap.manage` | Revoke a capability from a user. Same UUID-only rule applies for session caps. |

### Mention parser specification

`Esr.Entity.MentionParser` (new module, Phase 4):

```
Input:  raw message text (binary string)
Output: {:mention, agent_name, rest_of_text} | {:plain, text}
```

Algorithm:

1. Trim leading whitespace from text.
2. Scan for the first occurrence of `@` followed by `[a-zA-Z0-9_-]+`.
3. If found: extract the name. Check if the name matches any agent name in the currently-attached session's agent list (case-sensitive string compare).
4. If name matches an agent: return `{:mention, name, rest_of_text}`.
5. If name does not match any agent: return `{:plain, text}` — route to primary (Q8=A).
6. If no `@<name>` pattern found: return `{:plain, text}` — route to primary.
7. A lone `@` not followed by `[a-zA-Z0-9_-]+`: return `{:plain, text}`.

---

## §5 — Capabilities

### New capability scopes

Building directly on PR-230's `workspace:<uuid>/<verb>` pattern:

| Cap String | Who Needs It | Input Contract |
|---|---|---|
| `session:<uuid>/attach` | Any user wanting to join a session they do not own | UUID ONLY at input (D2, D5) |
| `session:<uuid>/add-agent` | Any user wanting to add/remove/rename agents in a session they do not own | UUID ONLY at input |
| `session:<uuid>/end` | Any user wanting to terminate a session they do not own | UUID ONLY at input |
| `session:<uuid>/share` | Any user wanting to grant session access to a third party | UUID ONLY at input |
| `plugin:<name>/configure` | Any user wanting to set plugin config for a plugin they do not own | n/a |

**Session caps vs. workspace caps — input contract comparison:**

| Resource Type | Name input accepted? | UUID input accepted? | Output display |
|---|---|---|---|
| Workspace cap (`workspace:<x>/...`) | YES — translated at CLI edge (PR-230) | YES | UUID → name translation for readability |
| Session cap (`session:<x>/...`) | **NO — rejected** (D2, D5) | YES | UUID → name translation for readability |

The `esr cap grant` escript and `/cap:grant` slash command both enforce this: a cap string of the form `session:<value>/...` where `<value>` does not match UUID v4 pattern returns `error: session caps require UUID; name input is not accepted (got "<value>")`.

The session creator automatically holds all `session:<uuid>/*` caps at session-create time (seeded in `Esr.Commands.Session.New.execute/1`).

### UUID translation for sessions (output-only)

`Esr.Resource.Capability.UuidTranslator` (PR-230) is extended with a `session_uuid_to_name/2` function for **output-side only** translation:

```elixir
@spec session_uuid_to_name(session_uuid :: String.t(), context :: map()) ::
        {:ok, String.t()} | {:error, :not_found}
def session_uuid_to_name(uuid, context) do
  # Used only at output time (e.g. /cap:show, /session:list rendering)
  # Returns the human-friendly session name for display
end
```

Input-side translation (`session_name_to_uuid`) is intentionally NOT implemented for sessions (D2). If an operator passes a name where a UUID is required, the command module returns a structured error before calling any translation function.

### Session sharing security model (Q9=C)

Cross-user session attach is intentionally not default-open:

1. UserA's session workspace root is `sessions/aaa-111/` and contains code, state, and CC configuration.
2. If UserB can attach without authorization, UserB can send arbitrary commands routed to UserA's CC agent.
3. Defense: `session:<uuid>/attach` cap check at `Esr.Commands.Session.Attach.execute/1`. UUID-only enforcement (D2) means an attacker who knows the session name but not the UUID cannot construct a valid cap string.
4. `/session:share <session_uuid> <user> perm=attach` (D4 default) is the only way for a non-admin to grant the attach cap.
5. `attached_chats` in `session.json` records the audit trail.

---

## §6 — Plugin Config (3-Layer)

### Layer definitions (Q11=B + D7, locked 2026-05-07)

The three layers and their storage locations:

**Layer 1 — Global** (lowest precedence):

```
$ESRD_HOME/<inst>/plugins.yaml
```

Existing file, gains an optional `config:` top-level key.

```yaml
enabled:
  - feishu
  - claude_code
config:
  claude_code:
    http_proxy: "http://proxy.local:8080"
    esrd_url: "ws://127.0.0.1:4001"
  feishu:
    app_id: "cli_a9563cc03d399cc9"
    app_secret: "${FEISHU_APP_SECRET}"
```

**Layer 2 — User** (middle precedence):

```
$ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml
```

New file. Keyed by user UUID, not username (D7). Has only a `config:` key (no `enabled:`).

```yaml
config:
  claude_code:
    anthropic_api_key_ref: "${MY_ANTHROPIC_KEY}"
    http_proxy: "http://user-proxy:8080"
```

**Layer 3 — Workspace** (highest precedence):

```
<workspace_root>/.esr/plugins.yaml
```

New file. `<workspace_root>` is the root of the session's currently-bound workspace.

```yaml
config:
  claude_code:
    http_proxy: ""    # explicit empty = no proxy for this workspace
```

### Resolution algorithm (Elixir pseudocode)

```elixir
def resolve(plugin_name, opts \\ []) do
  user_uuid    = opts[:user_uuid]      # UUID, not username
  workspace_id = opts[:workspace_id]

  schema   = load_schema(plugin_name)
  defaults = schema_defaults(schema)

  global_layer    = read_global(plugin_name)
  user_layer      = if user_uuid,    do: read_user(plugin_name, user_uuid),            else: %{}
  workspace_layer = if workspace_id, do: read_workspace(plugin_name, workspace_id),    else: %{}

  defaults
  |> Map.merge(global_layer)
  |> Map.merge(user_layer)
  |> Map.merge(workspace_layer)
end
```

Key merge semantics (per locked decision 2026-05-07):

| Layer contains key | Value | Effect on effective config |
|---|---|---|
| Present | `"http://proxy:8080"` | Wins; effective = that value |
| Present | `""` | Wins; effective = "" (explicit empty, e.g. disable proxy) |
| Absent | — | Falls through to lower layer or schema default |

### `Esr.Plugin.Config` module (new, Phase 7)

```elixir
defmodule Esr.Plugin.Config do
  @moduledoc """
  3-layer plugin config resolution: global / user / workspace.
  Precedence: workspace > user > global (per-key merge).
  resolve/2 accepts user_uuid (not username) per D1/D7.
  """

  @spec resolve(plugin_name :: String.t(), opts :: keyword()) :: map()
  def resolve(plugin_name, opts \\ [])

  @spec get(plugin_name :: String.t(), key :: String.t()) :: String.t() | nil
  def get(plugin_name, key)

  @spec store(session_id :: String.t(), plugin_name :: String.t(), config :: map()) :: :ok
  def store(session_id, plugin_name, config)

  @spec invalidate(plugin_name :: String.t()) :: :ok
  def invalidate(plugin_name)
end
```

### Manifest `config_schema:` field (new in Phase 7)

**claude_code manifest addition:**

```yaml
config_schema:
  http_proxy:
    type: string
    description: "HTTP proxy URL for outbound Anthropic API requests. Empty string = no proxy."
    default: ""

  https_proxy:
    type: string
    description: "HTTPS proxy URL. Usually same as http_proxy."
    default: ""

  no_proxy:
    type: string
    description: "Comma-separated host/suffix list that bypasses the proxy."
    default: ""

  anthropic_api_key_ref:
    type: string
    description: |
      Env-var reference for the Anthropic API key, e.g. "${ANTHROPIC_API_KEY}".
      The plugin resolves the value at session-start via System.get_env/1.
    default: "${ANTHROPIC_API_KEY}"

  esrd_url:
    type: string
    description: "WebSocket URL of the esrd host. Controls the HTTP MCP endpoint."
    default: "ws://127.0.0.1:4001"
```

**feishu manifest addition:**

```yaml
config_schema:
  app_id:
    type: string
    description: "Feishu app ID (cli_xxx). Required for Feishu API calls."
    default: ""

  app_secret:
    type: string
    description: "Feishu app secret. Required for Feishu API calls. Do not commit to repo."
    default: ""

  log_level:
    type: string
    description: "Log verbosity for the feishu adapter (debug|info|warning|error)."
    default: "info"
```

**Validation rules for `config_schema:` entries:**

- `type:` is required. Phase 1 supports `string` and `boolean`. Unknown type → `{:error, {:config_schema_unknown_type, key, type}}`.
- `description:` is required. Absent → `{:error, {:config_schema_missing_field, key, "description"}}`.
- `default:` is required. Absent → `{:error, {:config_schema_missing_field, key, "default"}}`.
- No `sensitive:` field (dropped entirely per user correction 2026-05-07).

### `depends_on:` enforcement (correction 2026-05-07)

Extend `Esr.Plugin.Loader.start_plugin/2` to call `check_dependencies/2` before `Manifest.validate/1`. If the dependency check fails, `start_plugin/2` returns `{:error, {:missing_dependency, dep_name}}` and the plugin is not started. Let-it-crash.

### `depends_on.core` SemVer check (D8, new in Phase 7)

`Esr.Plugin.Manifest` already parses `depends_on.core` as a string (e.g. `">= 0.1.0"`). Phase 7 now enforces it:

```elixir
defmodule Esr.Plugin.Version do
  @moduledoc """
  SemVer constraint check for depends_on.core.
  Wraps Elixir stdlib Version module.
  """

  @spec satisfies?(constraint :: String.t(), version :: String.t()) :: boolean()
  def satisfies?(constraint, version) do
    Version.match?(version, constraint)
  end

  @spec esrd_version() :: String.t()
  def esrd_version() do
    # Reads from runtime/mix.exs at compile time via @version module attribute
    Application.spec(:esr, :vsn) |> to_string()
  end
end
```

At `Loader.start_plugin/2`, after `check_dependencies/2`:

```elixir
defp check_core_version(manifest) do
  constraint = manifest.depends_on[:core]
  if constraint do
    esrd_vsn = Esr.Plugin.Version.esrd_version()
    if Esr.Plugin.Version.satisfies?(constraint, esrd_vsn) do
      :ok
    else
      {:error, {:core_version_mismatch, constraint, esrd_vsn}}
    end
  else
    :ok  # no core constraint declared
  end
end
```

Estimated ~80 LOC for `Esr.Plugin.Version` module + tests. Phase 7 LOC estimate updated to ~700 (was ~600).

### Shell-script deletion map

`scripts/esr-cc.sh` and `scripts/esr-cc.local.sh` are deleted in Phase 8. Complete responsibility migration:

| Script responsibility | Migration destination |
|---|---|
| `http_proxy`, `https_proxy`, `no_proxy`, `HTTP_PROXY`, `HTTPS_PROXY` exports | `claude_code` plugin config |
| `ANTHROPIC_API_KEY` / `.mcp.env` source | Stays in launchd plist; `claude_code` config uses `anthropic_api_key_ref` |
| `ESR_ESRD_URL` | `claude_code.config.esrd_url` |
| `exec claude` + `CLAUDE_FLAGS` construction | `Esr.Plugins.ClaudeCode.Launcher` (Elixir-native) |
| `session-ids.yaml` resume lookup | Elixir before PTY spawn |
| `.mcp.json` write | `Esr.Plugins.ClaudeCode.Launcher.write_mcp_json/1` before spawn |
| Workspace trust pre-write to `~/.claude.json` | Elixir via `File.write/2` before spawn |
| `mkdir -p "$cwd"` | Elixir `File.mkdir_p/1` before spawn |
| `ESRD_HOME`, `ESRD_INSTANCE` | Launchd plist only |
| `ESR_WORKSPACE`, `ESR_SESSION_ID` | PtyProcess spawn env (already set by BEAM) |

Files referencing `esr-cc.sh` that must be updated in Phase 8:
- `runtime/lib/esr/entity/pty_process.ex:350`
- `runtime/lib/esr/entity/unbound_chat_guard.ex:104`
- `runtime/test/esr/commands/workspace/info_test.exs:22`
- `runtime/test/esr/resource/workspace_registry_test.exs:20`
- `scripts/final_gate.sh:342`
- `tests/e2e/scenarios/07_pty_bidir.sh:48`
- `docs/dev-guide.md:37,212`
- `docs/cookbook.md:74`

---

## §7 — Migration Plan (11 Phases, Hard Cutover)

Each phase is one PR. D1 introduces a new Phase 1b for user UUID migration, inserted between the original Phase 1 and Phase 2.

| Phase | PR Title | Primary Files Changed | Est LOC | Depends On |
|---|---|---|---|---|
| 0 | `spec: metamodel-aligned ESR` (this document) | `docs/superpowers/specs/` | — | — |
| 1 | `feat: session UUID identity + storage layout` | `runtime/lib/esr/resource/session/*` (NEW), `Esr.Paths` helpers, JSON schema helpers | ~800 | Phase 0 |
| 1b | `feat: user UUID identity + NameIndex + user.json migration` | `runtime/lib/esr/entity/user/*`, `Esr.Paths` user helpers, `users.yaml` boot migration | ~600 | Phase 1 |
| 2 | `feat: chat→[sessions] attach/detach state` | `runtime/lib/esr/resource/chat_scope/registry.ex`, `chat_scope/file_loader.ex` | ~600 | Phase 1b |
| 3 | `feat: multi-agent per session` | `runtime/lib/esr/entity/agent/instance.ex` (NEW), `agent/registry.ex` extension | ~700 | Phase 1 |
| 4 | `feat: mention parser + primary-agent routing` | `runtime/lib/esr/entity/mention_parser.ex` (NEW), `entity/slash_handler.ex` | ~400 | Phase 3 |
| 5 | `feat: session cap UUID translation + UUID-only enforcement` | `runtime/lib/esr/resource/capability/uuid_translator.ex`, cap seeding in `Session.New` | ~350 | Phase 1 |
| 6 | `feat: colon-namespace slash cutover + new session/pty/cap slashes` | `runtime/priv/slash-routes.default.yaml`, `slash_handler.ex`, all command modules | ~1200 | Phase 1b + Phase 3 |
| 7 | `feat: plugin-config 3-layer + manifest config_schema + depends_on + core SemVer` | `runtime/lib/esr/plugin/*`, `runtime/lib/esr/plugins/*/manifest.yaml`, `Esr.Plugin.Version` (NEW) | ~700 | Phase 6 |
| 8 | `chore: delete esr-cc.sh + esr-cc.local.sh + elixir-native PTY launcher` | `git rm scripts/esr-cc.sh scripts/esr-cc.local.sh`, `runtime/lib/esr/entity/pty_process.ex`, `runtime/lib/esr/plugins/claude_code/launcher.ex` (NEW) | ~300 deleted + ~400 added | Phase 7 |
| 9 | `docs+test: e2e scenarios 14-16 + docs sweep + obsolete comment cleanup` | `docs/`, `tests/e2e/scenarios/14-16_*.sh` (NEW) | ~400 | Phase 8 |

**Dependency DAG (strictly acyclic):**

```
0 → 1 → 1b → 2
              ↗
         3 → 4
         ↗
    1  → 5
    1b + 3 → 6 → 7 → 8 → 9
```

Full expansion:
- Phase 1: foundation (session UUID identity)
- Phase 1b: user UUID (depends on Phase 1 for Paths conventions)
- Phase 2: chat attached-set (depends on Phase 1b — references user UUIDs in migrations)
- Phase 3: multi-agent (depends on Phase 1 — agent instances reference session IDs)
- Phase 4: mention parser (depends on Phase 3 — agent instances must exist)
- Phase 5: session cap UUID enforcement (depends on Phase 1 — session registry)
- Phase 6: colon-namespace slash cutover (depends on Phase 1b for user commands + Phase 3 for add-agent command)
- Phases 7, 8, 9: strictly sequential after Phase 6

No cycles. All edges are forward.

**Estimated total:** ~6,350 LOC across 11 PRs. Elapsed time: ~1.5-2 weeks with one developer.

### Phase 1 detail: Session UUID identity + storage layout

New modules:

```
runtime/lib/esr/resource/session/
├── struct.ex        (Esr.Resource.Session.Struct)
├── registry.ex      (GenServer; two ETS tables: uuid-keyed + {owner_user_uuid, name} index)
├── file_loader.ex   (load/1; atomic read from sessions/<uuid>/session.json)
├── json_writer.ex   (write/2; atomic temp-rename pattern)
└── supervisor.ex    (started in Esr.Application before ChatScope.Registry)
```

Session registry name-index table key: `{owner_user_uuid, name}` composite (D6).

### Phase 1b detail: User UUID identity + NameIndex

New / extended modules:

```
runtime/lib/esr/entity/user/
├── name_index.ex    (Esr.Entity.User.NameIndex — GenServer; ETS: username→uuid + uuid→username)
├── json_writer.ex   (write user.json atomically)
└── file_loader.ex   (boot walk: users.yaml → assign UUIDs → build index → write back)
```

`Esr.Paths` user helpers added: `user_dir/1`, `user_json/1`, `user_workspace_json/1`, `user_plugins_yaml/1` — all take `user_uuid`.

Boot migration: `users.yaml` entries gain a `uuid:` field. Existing entries without a UUID get one assigned. File written back atomically. `users/<user_uuid>/` directories created as needed.

### Phase 3 detail: Multi-agent per session

`Esr.Entity.Agent.Instance`:

```elixir
defmodule Esr.Entity.Agent.Instance do
  @moduledoc "Agent instance within a session. Name globally unique within session regardless of type."
  defstruct [:session_id, :type, :name, :config, :pid]
end
```

Name uniqueness enforcement in `Esr.Commands.Session.AddAgent.execute/1`:

```elixir
existing_names = Esr.Entity.Agent.Registry.names_for_session(session_id)
if name in existing_names do
  {:error, {:duplicate_agent_name, name,
    "agent name '#{name}' already exists in session (pick a different name)"}}
else
  # proceed with spawn
end
```

### Phase 5 detail: Session cap UUID enforcement

`Esr.Resource.Capability.UuidTranslator` gains:

```elixir
@spec validate_session_cap_input(cap_string :: String.t()) ::
        :ok | {:error, {:session_name_in_cap, String.t()}}
def validate_session_cap_input(cap_string) do
  case Regex.run(~r{^session:([^/]+)/}, cap_string) do
    [_, value] ->
      if uuid_v4?(value) do
        :ok
      else
        {:error, {:session_name_in_cap,
          "session caps require UUID; name input is not accepted (got \"#{value}\")"}}
      end
    _ -> :ok  # not a session cap; pass through
  end
end
```

Called at the entry point of both the `esr cap grant` escript and `/cap:grant` slash handler, before any further processing.

### Phase 6 detail: Colon-namespace slash cutover

Changes to `runtime/priv/slash-routes.default.yaml`:
- Rename all 30 primary slash keys to colon form.
- Remove all `aliases:` fields.
- Delete the `/workspace sessions` entry.
- Add all new slash entries from §4.B, §4.C, §4.D, §4.E.

---

## §8 — Risk Register

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | `ChatScope.Registry` data format change breaks running instances on upgrade | Medium | Boot migration in Phase 2 `file_loader.ex`. Regression test: boot with old format fixture, assert ETS contains new format. |
| R2 | Agent name collision on `/session:add-agent` | Low | Name uniqueness check before insert; structured error with valid names list from `/session:info`. |
| R3 | Cross-user attach security bypass — malicious user guesses UUID | Low | UUID v4 has 2^122 bits of entropy. Cap check at `Esr.Commands.Session.Attach.execute/1` is the hard enforcement gate. UUID-only input (D2) eliminates name-guessing as an attack vector. |
| R4 | Plugin config schema strictness rejects valid operators | Low | Schema validation fires only at write time. Structured error includes the full list of valid keys. |
| R5 | Hard cutover slash names break existing operator bookmarks | Medium | Phase 9 docs sweep updates all documentation. `/help` output shows new names. Announce via Feishu before Phase 6 merges. |
| R6 | Shell-script deletion + Elixir-native PTY launcher regression | Medium | Phase 8 `make e2e` gate: all existing e2e scenarios (01-13) must pass. Announce via Feishu before Phase 8 merges. |
| R7 | User-default workspace auto-creation fails if `users/` directory missing | Low | `Esr.Commands.User.Add` uses `File.mkdir_p/1` before writing `user.json` and `workspace.json`. |
| R8 | `depends_on:` or `depends_on.core` enforcement breaks existing plugins | Low | Both `feishu` and `claude_code` declare `depends_on: {core: ">= 0.1.0", plugins: []}`. Enforcement only fires on declared-but-missing constraints. |
| R9 | User UUID boot migration corrupts `users.yaml` | Low | Atomic write (temp-rename pattern). Boot migration is idempotent: if `users/<uuid>/user.json` already exists, skip creation. |
| R10 | Session cap UUID-only rejection surprises operators used to workspace name acceptance | Medium | Clear structured error message: `"session caps require UUID; name input is not accepted (got \"esr-dev\")"`. `/session:list` output shows UUID alongside name for copy-paste. |

---

## §9 — Test Plan

### Unit tests by phase

**Phase 1 — Session identity and storage:**

| Test | Module | Assertion |
|---|---|---|
| UUID round-trip | `Session.Registry` | Create → persist → reload → struct fields equal |
| Name → UUID index (composite key) | `Session.Registry` | `lookup_by_name({owner_uuid, "esr-dev"})` returns correct UUID |
| FileLoader atomicity | `Session.FileLoader` | Partial write not visible in registry |
| Paths helpers | `Esr.Paths` | `session_dir/1`, `session_json/1` return paths matching `$ESRD_HOME/<inst>/sessions/<uuid>/` |

**Phase 1b — User UUID identity:**

| Test | Module | Assertion |
|---|---|---|
| UUID assignment at boot | `User.FileLoader` | Entry without UUID in `users.yaml` gets assigned UUID; file written back |
| NameIndex lookup | `User.NameIndex` | `username_to_uuid("linyilun")` returns `{:ok, uuid}` |
| NameIndex reverse lookup | `User.NameIndex` | `uuid_to_username(uuid)` returns `{:ok, "linyilun"}` |
| User dir created | `Commands.User.Add` | `esr user add alice` creates `users/<uuid>/user.json` and `users/<uuid>/.esr/workspace.json` |
| User workspace kind | `Commands.User.Add` | `workspace.json` has `kind: "user-default"` |
| User workspace not in list | `Commands.Workspace.List` | `/workspace:list` excludes `kind: "user-default"` entries |
| User workspace in info | `Commands.Workspace.Info` | `/workspace:info name=alice` returns the user-default workspace |
| Idempotent add | `Commands.User.Add` | Adding same user twice: second call is no-op; no duplicate UUID |

**Phase 2 — Chat attached-set:**

| Test | Module | Assertion |
|---|---|---|
| Attach to empty chat | `ChatScope.Registry` | After attach: `current = session_id`, `attached_set = [session_id]` |
| Detach | `ChatScope.Registry` | After detach: session removed from `attached_set`; `current` = nil (or next) |
| Boot migration | `ChatScope.FileLoader` | Old single-slot format → loaded as attached-set; written in new format |
| Multi-attach + pointer switch | `ChatScope.Registry` | Attach A, attach B, detach A → B becomes current |

**Phase 3 — Multi-agent:**

| Test | Module | Assertion |
|---|---|---|
| Name collision — same name different type | `Commands.Session.AddAgent` | `{:error, {:duplicate_agent_name, "esr-dev"}}` |
| Name collision — same name same type | `Commands.Session.AddAgent` | Same error |
| Unique names succeed | `Commands.Session.AddAgent` | `{cc, "dev"}` + `{codex, "reviewer"}` → both in session.agents |
| Remove primary guard | `Commands.Session.RemoveAgent` | Cannot remove primary until set-primary to another agent |

**Phase 4 — Mention parser:**

| Test | Module | Assertion |
|---|---|---|
| `@esr-dev hello` with agent esr-dev | `MentionParser` | `{:mention, "esr-dev", "hello"}` |
| `@ hello` (lone @) | `MentionParser` | `{:plain, "@ hello"}` |
| `@unknown hello` (name not in session) | `MentionParser` | `{:plain, "@unknown hello"}` |
| No @ in text | `MentionParser` | `{:plain, text}` |

**Phase 5 — Cap UUID enforcement:**

| Test | Module | Assertion |
|---|---|---|
| Name → UUID rejected at input | `Capability.UuidTranslator` | `validate_session_cap_input("session:esr-dev/attach")` → `{:error, {:session_name_in_cap, _}}` |
| UUID accepted at input | `Capability.UuidTranslator` | `validate_session_cap_input("session:aaa-11111111-2222-3333-4444-555555555555/attach")` → `:ok` |
| Workspace name accepted at input | `Capability.UuidTranslator` | `validate_session_cap_input("workspace:my-ws/read")` → `:ok` (not a session cap; pass through) |
| Session creator auto-holds caps | `Commands.Session.New` | After session creation, owner has `session:<uuid>/attach`, `/add-agent`, `/end`, `/share` caps |
| Output-side UUID → name | `Capability.UuidTranslator` | `session_uuid_to_name(uuid, ctx)` returns `{:ok, "esr-dev"}` for display |

**Phase 6 — Colon-namespace:**

| Test | Module | Assertion |
|---|---|---|
| All colon forms resolve | `SlashRoute.Registry` | Each new colon-form key `Registry.lookup/1` returns `{:ok, route}` |
| Bare forms kept | `SlashRoute.Registry` | `/help`, `/doctor` still resolve |
| Old form → unknown command | `SlashHandler` | Input `/new-session` returns `unknown command: /new-session` |
| `/session:attach` rejects name | `Commands.Session.Attach` | Input `/session:attach esr-dev` → error referencing UUID requirement |

**Phase 7 — Plugin config + SemVer:**

| Test | Module | Assertion |
|---|---|---|
| Manifest accepts valid config_schema | `Plugin.Manifest` | `parse/1` returns struct with `declares.config_schema` map |
| Manifest rejects missing `type:` | `Plugin.Manifest` | `{:error, {:config_schema_missing_field, key, "type"}}` |
| resolve — global only | `Plugin.Config` | Schema defaults + global; user/workspace absent → global wins |
| resolve — user overrides global on one key | `Plugin.Config` | User value wins; other keys use global |
| resolve — workspace overrides user and global | `Plugin.Config` | Workspace value wins |
| resolve — workspace empty-string wins | `Plugin.Config` | `""` from workspace wins over `"http://proxy"` from global |
| depends_on enforcement | `Plugin.Loader` | Plugin with unmet dependency → `{:error, {:missing_dependency, dep}}` |
| SemVer check passes | `Plugin.Version` | `satisfies?(">= 0.1.0", "0.2.0")` → `true` |
| SemVer check fails | `Plugin.Version` | `satisfies?(">= 1.0.0", "0.2.0")` → `false` |
| core version mismatch at load | `Plugin.Loader` | Plugin declaring `depends_on.core: ">= 99.0.0"` → `{:error, {:core_version_mismatch, ...}}` |
| user_uuid used in resolve | `Plugin.Config` | `resolve/2` reads from `users/<user_uuid>/.esr/plugins.yaml` (not username path) |

### E2E scenarios (new)

**Scenario 14: Multi-agent session**

```bash
esr admin submit session_new name=multi-test submitter=linyilun ...
esr admin submit session_add_agent session_id=$SID type=cc name=alice ...
esr admin submit session_add_agent session_id=$SID type=cc name=bob ...
SESSION_INFO=$(esr admin submit session_info session_id=$SID ...)
assert_contains "$SESSION_INFO" '"primary_agent":"alice"'
assert_contains "$SESSION_INFO" '"name":"bob"'
REPLY=$(send_feishu_text "@alice ping" ...)
assert_contains "$REPLY" "alice received"
REPLY=$(send_feishu_text "@bob hello" ...)
assert_contains "$REPLY" "bob received"
REPLY=$(send_feishu_text "plain message" ...)
assert_contains "$REPLY" "alice received"
```

**Scenario 15: Cross-user session attach (UUID-only)**

```bash
esr admin submit session_new name=shared user=userA ...
SID=$SESSION_UUID
/session:share $SID userB perm=attach   # UUID-only session identification
esr admin submit session_attach session=$SID chat=oc_yyy user=userB ...
assert_attached userB $SID oc_yyy
RESULT=$(esr admin submit session_attach session=$SID chat=oc_zzz user=userC ...)
assert_error "$RESULT" "cap_check_failed"
# Verify that name-based attach is rejected:
RESULT=$(esr admin submit session_attach session=shared chat=oc_www user=userB ...)
assert_error "$RESULT" "session caps require UUID"
```

**Scenario 16: Plugin config 3-layer resolution**

```bash
/plugin:set claude_code http_proxy=http://global.proxy:8080 layer=global
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://global.proxy:8080"'
/plugin:set claude_code http_proxy=http://user.proxy:8080 layer=user
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://user.proxy:8080"'
/plugin:set claude_code http_proxy="" layer=workspace
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = ""'
/plugin:unset claude_code http_proxy layer=workspace
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://user.proxy:8080"'
/plugin:unset claude_code http_proxy layer=user
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://global.proxy:8080"'
```

---

## §10 — Open Questions (CLOSED — All Resolved)

This section records the five open questions from rev-1 and their final resolutions per Round-3 user decisions (2026-05-07). The section is preserved as a decision artifact.

**Q-OQ1 (CLOSED): User UUID identity**
Resolved by D1: user UUID identity IS included in this batch. User dir path uses `<user_uuid>` from the start. No painful migration later.

**Q-OQ2 (CLOSED): Session naming — human-friendly name + UUID dual-track**
Resolved by D2: session has both `name` and `id` (UUID). At INPUT, session caps accept UUID ONLY (not name). At OUTPUT, UUID → name translation is done for readability. This differs from workspace (which accepts both at input).

**Q-OQ3 (CLOSED): Default-attached behavior on `/session:new`**
Resolved by D3: YES, confirmed. `/session:new` automatically attaches to the creating chat and sets the attached-current pointer. This is locked behavior.

**Q-OQ4 (CLOSED): `/session:share` default permission**
Resolved by D4: `perm=attach` is the confirmed default. Safer than `perm=admin`.

**Q-OQ5 (CLOSED): `/cap:grant` name-keyed input for session caps**
Resolved by D5: REJECTED. Session caps require UUID at input. The escript and slash command both reject `session:<name>/...`. This is the opposite of the workspace pattern — session names are not globally unique (D6), so name-keyed input for caps would be ambiguous.

---

## §11 — Post-Deploy Migration Steps (NEW)

Per D7 (locked 2026-05-07): after this redesign ships, there is NO in-place migration of existing `$ESRD_HOME/<inst>/` directories. Operators must wipe and let Bootstrap rebuild.

### Required wipe procedure (per D7)

Before first boot of the new build:

```bash
# WARNING: this destroys all existing sessions, workspaces, and plugin configs.
# Ensure any needed data (workspace folders, plugin keys) is noted elsewhere first.

# For development instance:
rm -rf ~/.esrd-dev/

# For production instance:
rm -rf ~/.esrd/
```

A helper script is provided at `tools/wipe-esrd-home.sh`:

```bash
#!/usr/bin/env bash
# tools/wipe-esrd-home.sh
# Wipe ESRD_HOME before first boot of metamodel-aligned-esr build.
# Usage: ./tools/wipe-esrd-home.sh [--dev | --prod]
set -euo pipefail

MODE=${1:-"--dev"}

if [[ "$MODE" == "--dev" ]]; then
  TARGET="${ESRD_HOME:-$HOME/.esrd-dev}"
elif [[ "$MODE" == "--prod" ]]; then
  TARGET="${ESRD_HOME:-$HOME/.esrd}"
else
  echo "Usage: $0 [--dev | --prod]" >&2
  exit 1
fi

echo "Wiping: $TARGET"
echo "This will destroy all sessions, workspaces, and plugin configs."
read -p "Type 'yes' to confirm: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 1; }

rm -rf "$TARGET"
echo "Wiped. Start esrd to rebuild from Bootstrap."
```

### Bootstrap rebuild (on first boot after wipe)

`Esr.Bootstrap` (existing module) runs on first boot of a fresh `$ESRD_HOME/<inst>/`. After this redesign ships, Bootstrap creates:

1. `plugins.yaml` — global config with `enabled: [feishu, claude_code]` and empty `config:`.
2. `admin` user — `users.yaml` with one entry `{username: "admin", uuid: <generated>}`. Creates `users/<admin_uuid>/user.json` and `users/<admin_uuid>/.esr/workspace.json` (kind: "user-default").
3. Admin caps — `admin` user receives `cap.manage`, `plugin/manage`, `session:default/create`, `workspace:default/create`.
4. `default` workspace — `workspaces/default/workspace.json`.

No sessions are pre-created. Operators run `/session:new name=my-session` to start working.

### Why no in-place migration (D7 rationale)

- The `users/<username>/` path from prior draft layouts was never shipped to production. There is nothing to migrate.
- The `users/<user_uuid>/` structure requires UUID assignment that is cleanest done via the boot-time `users.yaml` migration in Phase 1b, not via an ad-hoc migration script.
- The plugin config files (`users/<username>/.esr/plugins.yaml`) from any prior draft were never written by shipped code. No operator data exists there.
- A clean Bootstrap is the safest and simplest path to a consistent state.

---

## §12 — Cross-References

- `docs/notes/concepts.md` (rev 9, 2026-05-03) — Tetrad Metamodel. Normative source for all primitive definitions.
- `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md` (rev 3) — Workspace UUID prior art. This spec extends the UUID pattern to sessions AND users.
- `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` — Operator pain points. 12-step bootstrap journey; all steps and gaps addressed in §7.
- `runtime/priv/slash-routes.default.yaml` — Current slash inventory baseline. Phase 6 rewrites all 30 primary keys to colon form.
- `runtime/lib/esr/resource/workspace/registry.ex` — Workspace UUID model (PR-230). Session registry follows same two-ETS-table pattern.
- `runtime/lib/esr/resource/chat_scope/registry.ex` — Current chat-current-slot. Phase 2 migrates to attached-set.
- `runtime/lib/esr/entity/user/registry.ex` + `file_loader.ex` — Current user model (username-keyed, `users.yaml` backed). Phase 1b introduces UUID identity and `NameIndex`.
- `runtime/lib/esr/plugin/manifest.ex` + `runtime/lib/esr/plugins/*/manifest.yaml` — Plugin manifest. Phase 7 adds `config_schema:` + `depends_on.core` SemVer enforcement.
- `scripts/esr-cc.sh` + `scripts/esr-cc.local.sh` — Shell scripts deleted in Phase 8.
- `tools/wipe-esrd-home.sh` — New script (Phase 9 or Bootstrap PR). Operator-facing wipe helper.
- (Reference) `spec/colon-namespace-grammar` branch — Absorbed into §4.
- (Reference) `spec/plugin-set-config` branch — Absorbed into §6.

---

## §13 — Self-Review Checklist (rev-2)

### D1-D8 coverage

| Decision | Reflected? | Section |
|---|---|---|
| D1: user UUID in this batch; `users/<user_uuid>/`; NameIndex; boot migration | Yes | §0 locked, §3 storage layout, §7 Phase 1b |
| D2: session name+UUID dual-track; session caps UUID-only at input; name at output | Yes | §0 locked, §4 Rule 7, §4.B, §5 cap table |
| D3: `/session:new` auto-attach — confirmed locked behavior | Yes | §0 locked, §4.B `/session:new` description |
| D4: `/session:share` default `perm=attach` — confirmed | Yes | §0 locked, §4.B `/session:share` description |
| D5: `esr cap grant` rejects `session:<name>` — UUID-only | Yes | §0 locked, §4.E, §5 cap table, §7 Phase 5 |
| D6: session name unique within `(owner_user, name)` | Yes | §3 session.json schema, §3 session name note, §7 Phase 1 |
| D7: `users/<user_uuid>/.esr/plugins.yaml`; no migration; wipe required | Yes | §3 storage layout, §6 layer 2, §11 post-deploy steps |
| D8: `depends_on.core` SemVer check in Phase 7; `Esr.Plugin.Version` | Yes | §6 `depends_on.core` section, §7 Phase 7 |

### Round-1/2/3 Q-decisions coverage

| Decision | Reflected? | Section |
|---|---|---|
| Q1-Q11, all user corrections from rev-1 | Yes | All incorporated in §3-§9 (same as rev-1 baseline, preserved) |

### Structural checks

| Check | Status |
|---|---|
| Storage layout uses `<user_uuid>` not `<username>` for user dirs | Yes — §3 full directory tree |
| §5 explicitly contrasts workspace cap (name+UUID) vs session cap (UUID-only) at input | Yes — §5 cap table with "Input Contract" column |
| §10 marked CLOSED (all 5 open questions resolved) | Yes — §10 header and per-question resolution |
| §11 post-deploy wipe section added | Yes — §11 new section |
| Phase count updated from 10 → 11 (Phase 1b added) | Yes — §7 table |
| Dependency DAG still acyclic | Yes — §7 DAG diagram |
| No emoji in either file | Yes |
| All file paths repo-relative or `$ESRD_HOME/<inst>/`-prefixed | Yes |
| EN + zh_cn paragraph-aligned (same section numbering) | Yes — both files follow §0-§13+§14 order |

---

## §14 — Invariant Tests (Completion Gates)

**Phase 1 invariant — Session storage:**
A session created via `Session.Registry.create/1` must be readable from disk after a process restart. Test: `create → restart simulation → load → assert struct fields match`.

**Phase 1b invariant — User UUID assignment:**
A fresh instance with `esr user add alice` must produce `users/<some_uuid>/user.json` with `username: "alice"` and `users/<some_uuid>/.esr/workspace.json` with `kind: "user-default"`. Test: assert file existence + field values. Also: `User.NameIndex.username_to_uuid("alice")` returns `{:ok, uuid}`.

**Phase 2 invariant — Attached-set atomicity:**
A chat that has had two sessions attached (A and B) and session A detached must have `attached_set = [B]` and `current = B.id`. Test: programmatic attach A, attach B, detach A; assert.

**Phase 3 invariant — Agent name uniqueness:**
A session cannot contain two agents with the same name regardless of type. Test: add `{cc, "esr-dev"}` → add `{codex, "esr-dev"}` → second add must return `{:error, {:duplicate_agent_name, "esr-dev"}}`.

**Phase 4 invariant — Mention routing to unknown agent falls through:**
A message `@nonexistent hello` dispatched to a session with one agent named "alice" must route to alice's input, not return an error.

**Phase 5 invariant — Session cap UUID-only enforcement:**
Any attempt to call `esr cap grant session:esr-dev/attach alice` (where `esr-dev` is a name, not a UUID) must return a structured error. The cap must NOT be written. Test: assert error message contains "session caps require UUID"; assert cap NOT in grants table.

**Phase 6 invariant — No old-form slash in yaml:**
No primary slash entry in `runtime/priv/slash-routes.default.yaml` uses space separator or dash-prefix form (except `/help` and `/doctor`). Test: grep assertion.

**Phase 7 invariant — Per-key merge correctness:**
With global `http_proxy="http://g"`, user `http_proxy="http://u"`, workspace key absent: `Config.resolve("claude_code", user_uuid: uuid, workspace_id: w_id)["http_proxy"]` must equal `"http://u"`.

**Phase 7 invariant — SemVer enforcement:**
A plugin declaring `depends_on.core: ">= 99.0.0"` must fail to load with `{:error, {:core_version_mismatch, ...}}`. Test: synthetic manifest; assert error at `Loader.start_plugin/2`.

**Phase 8 invariant — Shell scripts deleted:**
`scripts/esr-cc.sh` and `scripts/esr-cc.local.sh` must not exist. `make e2e` must pass (scenarios 01-13).

**Phase 9 invariant — Multi-agent and cross-user attach:**
Scenario 14 (multi-agent session) and Scenario 15 (cross-user attach with UUID-only enforcement) must both pass.

---

## §15 — Implementation Notes and Elixir Conventions

### Session registry boot order

`Esr.Resource.Session.Registry` must start before `Esr.Resource.ChatScope.Registry`.

`Esr.Entity.User.NameIndex` must start before `Esr.Resource.Session.Registry` (session structs reference `owner_user` as UUID; NameIndex provides the lookup for any legacy username → UUID resolution at boot).

Add to `Esr.Application.start/2`:

```elixir
{Esr.Entity.User.NameIndex, []},          # Phase 1b: first
{Esr.Resource.Session.Supervisor, []},    # Phase 1: second
{Esr.Resource.ChatScope.Registry, []},    # Phase 2: third
```

### Agent instance lifecycle

When `/session:add-agent` runs:
1. Validate name uniqueness in `Session.Registry`.
2. Update `session.json` atomically.
3. Spawn agent process: call plugin's spawn hook.
4. Update `Agent.Registry` with `{session_id, name}` → `pid` mapping.
5. Reply with confirmation.

### Plugin config ETS cache

After `/plugin:set` writes to disk, `Esr.Plugin.Config.invalidate/1` is called. Running sessions retain their resolved config (resolved at session-create time). Operators must `/session:end` + `/session:new` to pick up changes without full daemon restart.

### `session.json` write atomicity

Write to `<session_dir>/session.json.tmp`, then `File.rename/2` to `session.json`. Same atomic pattern as PR-230 `workspace.json`.

### Error handling conventions (let-it-crash)

- `Session.Registry` startup: `File.mkdir_p!/1` for `sessions_dir/0`.
- `Session.FileLoader.load/1`: malformed `session.json` → log error, skip session (matches workspace registry behavior — single malformed file does not prevent daemon boot).
- `Plugin.Loader.start_plugin/2` with unmet `depends_on` or `depends_on.core` violation: return `{:error, ...}`. Log. Skip that plugin. Operator must fix.

### Summary of new modules to create

| Module | Phase | Purpose |
|---|---|---|
| `Esr.Resource.Session.Struct` | 1 | Session struct matching `session.json` schema |
| `Esr.Resource.Session.Registry` | 1 | GenServer; ETS two-table (`uuid` + `{owner_user_uuid, name}` index) |
| `Esr.Resource.Session.FileLoader` | 1 | Load `session.json` from disk |
| `Esr.Resource.Session.JsonWriter` | 1 | Atomic write `session.json` |
| `Esr.Resource.Session.Supervisor` | 1 | Supervisor for session registry |
| `Esr.Entity.User.NameIndex` | 1b | GenServer; ETS: username → uuid + uuid → username; boot migration |
| `Esr.Entity.User.JsonWriter` | 1b | Atomic write `user.json` |
| `Esr.Entity.Agent.Instance` | 3 | Agent instance struct |
| `Esr.Entity.MentionParser` | 4 | Parse `@<name>` in plain text |
| `Esr.Plugin.Config` | 7 | 3-layer resolution + ETS cache |
| `Esr.Plugin.Version` | 7 | SemVer constraint check for `depends_on.core` |
| `Esr.Commands.Session.New` | 6 | Rename from `Esr.Commands.Scope.New` |
| `Esr.Commands.Session.Attach` | 6 | New: attach to existing session (UUID-only input) |
| `Esr.Commands.Session.Detach` | 6 | New: leave session without ending |
| `Esr.Commands.Session.End` | 6 | Rename from `Esr.Commands.Scope.End` |
| `Esr.Commands.Session.List` | 6 | Rename from `Esr.Commands.Scope.List` |
| `Esr.Commands.Session.AddAgent` | 6 | New: add agent instance |
| `Esr.Commands.Session.RemoveAgent` | 6 | New: remove agent instance |
| `Esr.Commands.Session.SetPrimary` | 6 | New: set primary agent |
| `Esr.Commands.Session.BindWorkspace` | 6 | New: rebind to named workspace |
| `Esr.Commands.Session.Share` | 6 | New: grant attach cap (UUID-only input) |
| `Esr.Commands.Session.Info` | 6 | New: session details |
| `Esr.Commands.Plugin.SetConfig` | 7 | New: write config key to layer |
| `Esr.Commands.Plugin.UnsetConfig` | 7 | New: delete config key from layer |
| `Esr.Commands.Plugin.ShowConfig` | 7 | New: display config (effective or per-layer) |
| `Esr.Commands.Plugin.ListConfig` | 7 | New: display all plugins' effective config |
| `Esr.Plugins.ClaudeCode.Launcher` | 8 | Elixir-native CC launcher (replaces esr-cc.sh) |
