# Spec: Metamodel-Aligned ESR — Session-First, Multi-Agent, Colon-Namespace, Plugin-Config-3-Layer

**Date:** 2026-05-07
**Status:** rev-1 (DRAFT — pending user review)
**Branch:** `spec/metamodel-aligned-esr`
**Companion file:** [`2026-05-07-metamodel-aligned-esr.zh_cn.md`](2026-05-07-metamodel-aligned-esr.zh_cn.md)

**Supersedes (content absorbed, branches preserved as reference):**
- `spec/colon-namespace-grammar` branch — `docs/superpowers/specs/2026-05-07-colon-namespace-grammar.md` → content absorbed into §4
- `spec/plugin-set-config` branch — `docs/superpowers/specs/2026-05-07-plugin-set-config.md` → content absorbed into §6 (with corrections)

---

## §0 — Locked Decisions

All decisions below were locked by the user in Feishu dialog on **2026-05-06 to 2026-05-07**. They are cited verbatim; the spec does not re-debate them. Unlocked design choices made by the spec author are flagged explicitly as `[SPEC AUTHOR DECISION]` for user confirmation.

### Round 1 (Q1-Q5, 2026-05-06)

- **Q1=A**: Same agent type, multiple instances are permitted within a session; instances are differentiated by `@<name>` addressing.
- **Q2=A** (later refined to **Q7=B**): `@<agent_name>` mention parsing — plain text simple string match. See Q7 for the final form.
- **Q3=C with twist**: Per-session workspace is the primary workspace. Chat-default workspace is an optional fallback used when no per-session workspace exists.
- **Q4=multi-scope per chat with attach**: One chat may have N parallel scopes (sessions). Use `/session:attach <name_or_uuid>` to join an existing session in the current chat. Cross-user attach is capability-gated (requires explicit cap grant).
- **Q5=一气呵成**: Ship all changes in one coherent migration sequence, not as independently-released features.

### Round 2 (Q6-Q10, 2026-05-06)

- **Q6=D**: Operator sets the primary agent via `/session:set-primary <name>`. Default = first agent added to the session.
- **Q7=B**: Plain text `@<name>` uses simple string match in raw message text (no platform mention API). A lone `@` character not followed by an alphanumeric character is treated as plain text and ignored by the mention parser. **Agent names must be globally unique within a session, regardless of agent type.** Example: if agent `esr-dev` of type `cc` exists, adding agent `esr-dev` of type `codex` is rejected — the name collision is detected before type is checked.
- **Q8=A**: Each chat maintains a "currently-attached session" pointer. Plain text that contains no `@<name>` mention is routed to the primary agent of the currently-attached session.
- **Q9=C**: Both imperative form (`/session:share`) and declarative form (capability yaml) are supported for session sharing. The imperative command is syntactic sugar that performs a `/cap:grant` behind the scenes.
- **Q10=C**: Session is a first-class resource. `$ESRD_HOME/<inst>/sessions/<session_uuid>/` IS itself a workspace — the session's auto-transient workspace. Sessions are not workspace-scoped; workspaces are session-referenced.

### Round 3 (Q11 + corrections, 2026-05-07)

- **Q11=B**: 3-layer plugin config with precedence **workspace > user > global**. Resolution is per-key (not whole-plugin-block replacement). The three layers are: global (`$ESRD_HOME/<inst>/plugins.yaml` → `config:` section), user (`$ESRD_HOME/<inst>/users/<username>/.esr/plugins.yaml` → `config:` section), workspace (`<workspace_root>/.esr/plugins.yaml` → `config:` section).
- **User insight (structural decision, 2026-05-07)**: Every user gets a personal workspace at `$ESRD_HOME/<inst>/users/<username>/`. This directory IS a workspace — auto-created at `esr user add` time, auto-managed, of `kind: "user-default"`. The user layer of plugin config is stored in `.esr/plugins.yaml` within that user-default workspace.
- **Drop `/session:add-folder`**: Folders are managed at the workspace level, not the session level. Operators use `/workspace:add-folder` to add folders to the workspace that the session references.
- **`/key` → `/pty:key`**: The slash command that sends keystrokes to a PTY belongs to the `pty` resource group, not `session`. `/pty:key` is correct. `/session:key` is incorrect.
- **Drop `/workspace:sessions`**: Workspace must not know about sessions. Only the session → workspace direction is valid in the dependency graph. `/workspace:sessions` is removed with no replacement.
- **Drop `@deprecated_slashes` map**: Hard cutover with no fallback. Unknown commands return `unknown command: /old-form`. The `@deprecated_slashes` helper proposed in the colon-namespace-grammar spec branch is dropped per this correction.
- **feishu manifest must include `app_id` + `app_secret` in `config_schema:`**: The Feishu app credentials currently live in shell scripts. They move to plugin config. The feishu manifest's `config_schema:` must declare `app_id` and `app_secret`.
- **`depends_on:` field validated at plugin load**: `Esr.Plugin.Manifest` already parses `depends_on`. `Esr.Plugin.Loader.topo_sort_enabled/2` already reads `manifest.depends_on.plugins` for ordering. However, the Loader does not currently fail-fast when a declared dependency is absent. This spec requires enforcement at `Loader.start_plugin/2` time.
- **Per-key merge for config layers**: The merge order is global → user → workspace. Each key is resolved independently: walk from the most-specific layer (workspace) to the least-specific (global), stop at the first layer that contains the key. "Contains" means the key appears in the map — even if the value is empty string. A key absent from all three layers falls back to the manifest's `default:`.
- **Drop `sensitive:` flag**: Removed from `config_schema:` entirely. There is no masking in `/plugin:show`. If an operator can set a config key, they can read it. Equivalent to editing a file — the access control is at the capability level, not at the value display level.
- **Only esrd's own env vars in launchd plist**: `ESRD_HOME`, `ESRD_INSTANCE`, and `ANTHROPIC_API_KEY` remain in the launchd plist. Everything else — HTTP proxies, per-plugin API keys, custom CC flags, Feishu credentials — moves to plugin config yaml files.

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

This is the target architecture. The implementation diverged from it in two critical ways before this spec.

**Gap 1: workspace-first instead of session-first.**

Today, a workspace must be registered before a session can be created. `Esr.Commands.Scope.New` requires a `workspace` argument; it looks up the workspace UUID from `Esr.Resource.Workspace.Registry`, then creates the session under that workspace. The mental model is:

```
register workspace → bind chat → create session (workspace-scoped)
```

The metamodel says the opposite: a Session instantiates a Scope, and the Scope references Resources (one of which is a workspace). The workspace is a Resource the Scope holds — not the Scope's parent. The operator's bootstrap flow (step 8 → step 9 → step 10 in the audit) also assumes this order:

```
/session:new → /workspace:add <path> → /agent:add cc name=esr-developer
```

PR #230 fixed workspace storage. This spec fixes session primacy.

**Gap 2: one agent per session instead of N.**

Today, `ChatScope.Registry` maps `(chat_id, app_id)` → one `session_id`. Each session has at most one CC process (spawned by `Esr.Entity.CCProcess`). The metamodel explicitly puts `agent-cc-α` and `agent-codex-β` as peer Entities in the same group-chat Scope.

The bootstrap-flow audit (`docs/manual-checks/2026-05-06-bootstrap-flow-audit.md`) confirmed that the operator's proposed step 10 (`/agent:add cc name=esr-developer`) had no surface at all — the grammar dimension failed entirely.

**Gap 3: inconsistent slash grammar.**

The audit's Cross-cutting gap #1: "The single biggest source of grammar mismatches. ESR's slash grammar today mixes dash (`/new-session`, `/list-agents`), space (`/workspace info`, `/plugin install`), and no-separator forms. A consistent `<group>:<verb>` form would simplify mental load."

Steps 8, 9, 10, and 12 all failed the Grammar dimension because the operator's natural expectations (`/session:new`, `/workspace:add`, `/agent:add`, `/agent:inspect`) did not match shipped forms.

**Gap 4: no operator-set plugin config.**

Audit step 6 (`/plugin claude-code set config {http_proxy=...}`) failed Interface, Function, and Grammar dimensions — no verb existed. Today per-plugin tuning requires editing `scripts/esr-cc.local.sh`, a shell fragment that only works for one operator on one machine and has no multi-user, multi-workspace story.

### What PR #230 fixed (prior art this spec builds on)

PR #230 (workspace UUID redesign) introduced:
- UUID-identified workspaces with a name → UUID index (`Esr.Resource.Workspace.NameIndex`)
- Hybrid storage: ESR-bound (`$ESRD_HOME/<inst>/workspaces/<name>/workspace.json`) + repo-bound (`<repo>/.esr/workspace.json`)
- The 14 `/workspace:*` slash commands (using space-separator — this spec converts them to colon form)
- `Esr.Resource.Capability.UuidTranslator` for `workspace:<name>` → `workspace:<uuid>` translation at CLI edges
- Two-ETS-table pattern: legacy name-keyed table + new UUID-keyed table for transition

This spec extends the UUID pattern to sessions, adds the 3-layer plugin config, and aligns the full slash surface.

### Goals

1. **Session-first**: session creation produces its own workspace automatically (auto-transient at `sessions/<uuid>/`); workspace registration is not a prerequisite.
2. **Multi-agent**: each session holds N agent instances, each with a globally-unique name; `@<name>` routing in plain text; primary-agent fallback.
3. **Consistent slash grammar**: one canonical `/<group>:<verb>` form for all resource-scoped commands; hard cutover.
4. **Operator plugin config**: 3-layer (global / user / workspace) YAML-backed config, replacing shell script workaround; manifest `config_schema:` declares allowed keys.
5. **One migration**: all changes shipped as one coordinated sequence of 10 PRs, in dependency order.

### Non-goals (deferred)

- **Hot-reload of plugin config**: restart-required for Phase 1. Hot-reload (`Esr.Plugin.Config.reload/1`) is Phase 2 and out of scope.
- **User UUID identity**: users are currently keyed by username (string). This spec defaults to `users/<username>/` paths. The question of whether to introduce user UUIDs (parallel to PR-230's workspace UUIDs) is flagged in §10 Open Questions and deferred.
- **Remote plugin install**: `/plugin:install` continues to accept local paths only in Phase 1. Hex-registry or git-remote plugin installs are Phase 2.
- **Declarative SessionSpec YAML**: the spec defines the `session.json` runtime state file. A higher-level declarative `SessionSpec` YAML (equivalent to writing `use GroupChatSession` as a config file) is a future phase — the metamodel concept, not yet an operator-facing file.
- **Session branching / worktree fork on session:new**: the existing worktree-fork logic (`args["worktree"]` in `Esr.Commands.Scope.New`) is preserved. This spec does not change worktree handling.

---

## §2 — The New Model

### Mapping metamodel primitives to concrete implementation

The following table maps every concept from `docs/notes/concepts.md` to the concrete module or storage path that implements it after this spec ships.

| Metamodel Primitive | Concrete Implementation | Status |
|---|---|---|
| **Scope** | Chat-attached session instance, UUID-identified; `Esr.Resource.Session.*` | New (Phase 1) |
| **Entity (human)** | `Esr.Entity.User` (username-keyed, `users.yaml` backed) | Existing; extended in Phase 1 |
| **Entity (agent instance)** | `{type, name}` pair within a session; `Esr.Entity.Agent.Instance` | New (Phase 3) |
| **Resource (workspace)** | `Esr.Resource.Workspace.*` (PR-230); session's auto-transient workspace at `sessions/<uuid>/` | Existing; auto-transient pattern is new |
| **Resource (channel)** | Feishu chat (`chat_id` + `app_id` pair); `Esr.Entity.FeishuChatProxy` | Existing |
| **Resource (capability)** | `Esr.Resource.Capability.*`; symbol + grant binding | Existing; new cap scopes in Phase 5 |
| **Interface** | Role traits: `MemberInterface`, `ChannelInterface`, etc. | Defined in `docs/notes/actor-role-vocabulary.md` |
| **Session (declarative)** | `session.json` captures runtime instance state (agents, attached chats, primary, workspace binding) | New (Phase 1); full declarative YAML deferred |

### Structural comparison: before and after

**Before (current state on `origin/dev`):**

```
1 chat
└── 1 workspace (registered first)
    └── 1 session (created second)
        └── 1 CC agent (plugin-declared, always of type cc)
```

Data flow for incoming message:
```
chat_id + app_id → ChatScope.Registry → session_id → CCProcess → agent
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
│   ├── session "esr-dev" (uuid=aaa-111) ← attached-current
│   │   ├── workspace_id → sessions/aaa-111/  (auto-transient workspace.json)
│   │   ├── agents:
│   │   │   ├── type=cc    name="esr-dev"   pid=<0.123.0>  ← primary
│   │   │   └── type=codex name="reviewer"  pid=<0.124.0>
│   │   ├── owner_user: linyilun
│   │   ├── primary_agent: "esr-dev"
│   │   └── transient: true
│   │
│   └── session "docs" (uuid=bbb-222)        (attached, not current)
│       ├── workspace_id → workspaces/docs-ws/  (named, shared)
│       ├── agents:
│       │   └── type=cc    name="docs-writer"  pid=<0.125.0>  ← primary
│       ├── owner_user: linyilun
│       ├── primary_agent: "docs-writer"
│       └── transient: false
│
└── attached-current pointer → "aaa-111"

Routing examples:
  plain text "fix the test"         → session aaa-111 → agent "esr-dev" (primary)
  "@reviewer look at this"          → session aaa-111 → agent "reviewer"
  "/session:attach docs"            → switches attached-current to bbb-222
  (after attach) plain text "edit"  → session bbb-222 → agent "docs-writer" (primary)
```

### The user-default workspace

Per the locked user insight (2026-05-07): every user has a personal workspace at `$ESRD_HOME/<inst>/users/<username>/`. This workspace:

- Is auto-created when the user is added via `esr user add <name>`.
- Has `kind: "user-default"` in `workspace.json` (invisible to `/workspace:list`, readable via `/workspace:info name=<username>`).
- Holds the user-layer plugin config at `.esr/plugins.yaml`.
- Does NOT hold folders, chats, or sessions in the normal sense — it is primarily a config anchor.
- Is the `workspace_id` pointed to by the user's personal-scope sessions when no named workspace is bound.

This means the user-default workspace IS the user layer of the 3-layer config. The layers correspond exactly to the workspace hierarchy:

```
global layer  → $ESRD_HOME/<inst>/plugins.yaml
user layer    → $ESRD_HOME/<inst>/users/<username>/.esr/plugins.yaml
                (inside the user-default workspace)
workspace layer → <current_workspace_root>/.esr/plugins.yaml
                  (inside the session's bound workspace)
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
├── users/                                    # user-default workspaces (NEW in this spec)
│   └── <username>/
│       ├── workspace.json                    # this dir IS a workspace; kind="user-default"
│       └── .esr/
│           └── plugins.yaml                  # user-layer plugin config (NEW)
│
└── sessions/                                 # session-default workspaces (NEW, per Q10=C)
    └── <session_uuid>/
        ├── workspace.json                    # auto-transient workspace for this session
        ├── session.json                      # session state: agents, chats, primary, workspace
        └── .esr/
            └── plugins.yaml                  # session-specific config override (rare)
```

Repo-bound workspace (PR-230 pattern, extends to include `.esr/plugins.yaml`):

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
| `Esr.Paths.user_workspace_dir/1` | `$ESRD_HOME/<inst>/users/<username>/` |
| `Esr.Paths.user_workspace_json/1` | `$ESRD_HOME/<inst>/users/<username>/workspace.json` |
| `Esr.Paths.user_plugins_yaml/1` | `$ESRD_HOME/<inst>/users/<username>/.esr/plugins.yaml` |
| `Esr.Paths.workspace_plugins_yaml/1` | `<workspace_root>/.esr/plugins.yaml` |

All helpers read `$ESRD_HOME` and `$ESRD_INSTANCE` from environment (or from `Esr.Paths.instance_dir/0` which already exists).

### `session.json` JSON schema (version 1)

```json
{
  "schema_version": 1,
  "id": "<session_uuid>",
  "name": "<human-friendly name>",
  "owner_user": "<username>",
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
      "attached_by": "<username>",
      "attached_at": "2026-05-07T12:00:00Z"
    }
  ],
  "created_at": "2026-05-07T12:00:00Z",
  "transient": true
}
```

Field semantics:

- `schema_version`: integer. `1` for this spec's format. Increment on breaking schema changes.
- `id`: UUID v4, generated at session creation. Stable for the session's lifetime.
- `name`: operator-provided string, or auto-generated as `session-<YYYYMMDD-HHMMSS>` if not provided. Must be unique within the owner user's sessions in the same instance.
- `owner_user`: the username of the user who created the session. Used for capability defaults.
- `workspace_id`: UUID of the workspace this session is bound to. At creation, this is the UUID of the auto-transient workspace at `sessions/<session_uuid>/`. After `/session:bind-workspace <name>`, it points to the named workspace's UUID.
- `agents`: ordered list of agent instances. First entry is the default primary if `primary_agent` is not set.
- `agents[].type`: the plugin name (e.g. `cc`, `codex`). Must match a plugin name in the enabled plugins list.
- `agents[].name`: operator-assigned name; globally unique within this session regardless of type.
- `agents[].config`: per-agent config overrides merged over the workspace-layer plugin config at agent-start time. Usually empty `{}`.
- `primary_agent`: name of the agent receiving un-addressed plain text (Q8=A). Validated to be a name present in `agents`.
- `attached_chats`: list of chats that have this session in their attached-set. `attached_by` is the username who ran `/session:attach` (or `/session:new` for the creating user). Used for auditing cross-user attach events.
- `transient`: if `true`, the workspace at `sessions/<session_uuid>/` is pruned when the session ends and the workspace is clean (no uncommitted git changes, no running processes). If `false`, the workspace persists.

### `workspace.json` for user-default workspace

```json
{
  "schema_version": 1,
  "id": "<uuid>",
  "name": "<username>",
  "owner": "<username>",
  "kind": "user-default",
  "folders": [],
  "chats": [],
  "transient": false,
  "created_at": "2026-05-07T12:00:00Z"
}
```

The `kind: "user-default"` field is new. Existing workspaces created by PR-230 have no `kind` field (treat as `kind: "esr-bound"` for backward compat). Workspace registry must:
- Skip `kind: "user-default"` entries in `/workspace:list` output.
- Allow direct lookup by name via `/workspace:info name=<username>`.

### Boot migration: `ChatScope.Registry` data format

The current ETS format in `Esr.Resource.ChatScope.Registry` stores:

```elixir
# old format, single slot
{{chat_id, app_id}, session_id}
```

This must migrate to the attached-set format:

```elixir
# new format, attached-set
{{chat_id, app_id}, %{current: session_id, attached_set: [session_id]}}
```

Migration location: `Esr.Resource.ChatScope.FileLoader.load/1`. If the persisted format uses the old single-slot shape, convert it to the new shape before loading into ETS. Write the new shape back to disk immediately so subsequent boots don't re-trigger migration.

The migration is non-destructive: old `session_id` becomes `current` and is the sole element of `attached_set`. The session's own `session.json` (Phase 1) records the same chat in `attached_chats`.

### Path collision analysis (no ambiguity between user/session/workspace dirs)

```
$ESRD_HOME/<inst>/workspaces/<name>/    ← ESR-bound workspaces, name is operator string
$ESRD_HOME/<inst>/users/<username>/     ← user-default workspaces, keyed by username
$ESRD_HOME/<inst>/sessions/<uuid>/      ← session workspaces, keyed by UUID v4
```

UUID v4 strings match `[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`. Usernames match `[A-Za-z0-9][A-Za-z0-9_-]*`. Workspace names are operator strings. These three keyspaces do not overlap — the directory segments (`workspaces/`, `users/`, `sessions/`) are distinct. No path collision is possible.

---

## §4 — Slash Surface (Colon-Namespace, Hard Cutover)

### Grammar rules (locked 2026-05-06, with corrections 2026-05-07)

**Rule 1 — Complete switch, no aliases, no fallback helper.**
All slash commands ship in colon form. Old-form input returns `unknown command: /old-form`. No `@deprecated_slashes` map (user correction 2026-05-07).

**Rule 2 — Multi-word verbs keep the dash inside the verb.**
`/workspace:add-folder`, `/workspace:bind-chat`, `/workspace:import-repo`. The colon separates group from verb; the dash is within the verb.

**Rule 3 — No deprecation period.**
One ship, hard cutover. All existing docs, tests, and scripts must be updated in Phase 9.

**Rule 4 — `/help` and `/doctor` stay bare.**
These are meta-system discovery commands. Colon-prefixing them would add friction at the most critical discovery moment (when the operator does not yet know the command surface). `[SPEC AUTHOR DECISION]`.

**Rule 5 — `/key` → `/pty:key`.**
The `/key` command sends keystrokes to the PTY of the currently-attached session. PTY is the resource; the resource group is `pty`. NOT `session:key` — that would imply the action is session-management. (User correction, 2026-05-07.)

**Rule 6 — Drop `/workspace:sessions`.**
Workspace must not have a dependency on session. The graph direction is session → workspace (session references workspace as a Resource). A `/workspace:sessions` command would invert that direction. Removed with no replacement. (User correction, 2026-05-07.)

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

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/session:new` | `[name=X] [worktree=Y] [workspace=W]` | `session:default/create` | Create session + auto-transient workspace at `sessions/<uuid>/`. Auto-attaches to creating chat; sets attached-current. Primary = first agent added. |
| `/session:attach` | `<name\|uuid>` (required) | `session:<uuid>/attach` | Join existing session in this chat; sets attached-current pointer. If session is owned by a different user, caller must hold `session:<uuid>/attach` cap. |
| `/session:detach` | (none) | none | Leave the currently-attached session in this chat. Does not end the session. Chat's attached-current pointer becomes nil or the next attached session if one exists. |
| `/session:end` | `[session=X]` | `session:<uuid>/end` | Terminate session. Prune transient workspace if the git worktree is clean. If `session=X` is omitted, uses the chat-current session. |
| `/session:list` | (none) | `session.list` | List sessions in this chat: their names, UUIDs, agent count, attached-current status, workspace name. |
| `/session:add-agent` | `<type> name=X [config_key=val ...]` | `session:<uuid>/add-agent` | Add an agent instance to the current session. `type` is the plugin name (e.g. `cc`, `codex`). `name` must be globally unique within this session. Config overrides are per-key; merged over workspace-layer plugin config at agent-start. |
| `/session:remove-agent` | `<name>` | `session:<uuid>/add-agent` | Remove an agent instance from the current session by name. Cannot remove the primary agent unless another agent has been set as primary first (guard: returns structured error). |
| `/session:set-primary` | `<name>` | `session:<uuid>/add-agent` | Set the primary agent for the current session. The named agent must exist in the session. |
| `/session:bind-workspace` | `<name>` | `session:<uuid>/end` | Rebind the session's workspace from the auto-transient workspace to a named workspace. The named workspace must already exist. The auto-transient workspace at `sessions/<uuid>/` is then a dangling directory (not automatically deleted — operator may prune manually). |
| `/session:share` | `<session> <user> [perm=attach\|admin]` | `session:<uuid>/share` | Grant the specified user the `session:<uuid>/attach` (or `session:<uuid>/*` for admin) capability. Defaults to `perm=attach`. Sugar over `/cap:grant`. |
| `/session:info` | `[session=X]` | `session.list` | Show session details: id, name, owner, workspace binding, agents list, primary agent, attached chats, created time, transient flag. |

#### C. New `/pty:*` family (replaces bare `/key`)

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/pty:key` | `keys=<spec>` (required) | none | Send special keystrokes (up/down/enter/esc/tab/c-X etc.) to the PTY of the chat-current session. Same functional behavior as the old `/key`; only the slash name changes. |

#### D. New `/plugin:*` config management (all new in Phase 7)

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/plugin:set` | `<plugin> key=value [layer=global\|user\|workspace]` | `plugin/manage` | Set a config key for the named plugin. Key must be declared in the plugin's `config_schema:`. Writes atomically to the appropriate layer file. Prints restart-required hint. Default layer = global. |
| `/plugin:unset` | `<plugin> key [layer=global\|user\|workspace]` | `plugin/manage` | Delete a config key from the named layer. Idempotent: no error if key is absent. Default layer = global. |
| `/plugin:show` | `<plugin> [layer=effective\|global\|user\|workspace]` | `plugin/manage` | Show config for the named plugin. `layer=effective` (default) returns the per-key merged result using the caller's session context. `layer=global|user|workspace` shows only that layer's raw map. |
| `/plugin:list-config` | (none) | `plugin/manage` | Show effective config for all enabled plugins, one section per plugin. |

#### E. New `/cap:*` family (slash form of existing `esr cap` escript)

| Slash | Args | Permission | Description |
|---|---|---|---|
| `/cap:grant` | `<cap> <user>` | `cap.manage` | Grant a capability to a user. Slash-form of `esr cap grant <cap> <user>`. |
| `/cap:revoke` | `<cap> <user>` | `cap.manage` | Revoke a capability from a user. Slash-form of `esr cap revoke`. |

### YAML entries for key new slashes (sample)

```yaml
"/session:new":
  kind: session_new
  permission: "session:default/create"
  command_module: "Esr.Commands.Session.New"
  requires_workspace_binding: false
  requires_user_binding: true
  category: "Sessions"
  description: "Create session + auto-transient workspace; auto-attaches to this chat"
  args:
    - { name: name,      required: false }
    - { name: worktree,  required: false }
    - { name: workspace, required: false }

"/session:attach":
  kind: session_attach
  permission: "session:default/attach"
  command_module: "Esr.Commands.Session.Attach"
  requires_workspace_binding: false
  requires_user_binding: true
  category: "Sessions"
  description: "Join existing session in this chat; sets attached-current pointer"
  args:
    - { name: session, required: true }

"/session:add-agent":
  kind: session_add_agent
  permission: "session:default/add-agent"
  command_module: "Esr.Commands.Session.AddAgent"
  requires_workspace_binding: false
  requires_user_binding: true
  category: "Sessions"
  description: "Add an agent instance to the current session"
  args:
    - { name: type, required: true  }
    - { name: name, required: true  }

"/pty:key":
  kind: key
  permission: null
  command_module: "Esr.Commands.Key"
  requires_workspace_binding: false
  requires_user_binding: false
  category: "PTY"
  description: "Send special keystrokes (up/down/enter/esc/tab/c-X etc.) to session PTY"
  args:
    - { name: keys, required: true }

"/plugin:set":
  kind: plugin_set_config
  permission: "plugin/manage"
  command_module: "Esr.Commands.Plugin.SetConfig"
  requires_workspace_binding: false
  requires_user_binding: false
  category: "Plugins"
  description: "Set a per-plugin config key (restart required to apply)"
  args:
    - { name: plugin, required: true  }
    - { name: key,    required: true  }
    - { name: value,  required: true  }
    - { name: layer,  required: false }
```

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
4. If name matches an agent: return `{:mention, name, rest_of_text}`. The `rest_of_text` is the message with the `@name` token removed.
5. If name does not match any agent: return `{:plain, text}` — route to primary (Q8=A).
6. If no `@<name>` pattern found: return `{:plain, text}` — route to primary.
7. A lone `@` not followed by `[a-zA-Z0-9_-]+`: return `{:plain, text}` — treated as plain text.

The mention parser is invoked by `Esr.Entity.SlashHandler` after determining the message is not a slash command. The handler dispatches to the result.

### Registry lookup compatibility note

`Esr.Resource.SlashRoute.Registry.keys_in_text/1` splits on `\s+` only (confirmed at `registry.ex:297-316`). A colon-form key like `/session:new` is a single whitespace-separated token and resolves atomically. No registry logic change is needed for the colon-namespace migration.

---

## §5 — Capabilities

### New capability scopes

Building directly on PR-230's `workspace:<uuid>/<verb>` pattern:

| Cap String | Who Needs It | Granted By |
|---|---|---|
| `session:<uuid>/attach` | Any user wanting to join a session they do not own | Session creator via `/session:share` or admin |
| `session:<uuid>/add-agent` | Any user wanting to add/remove/rename agents in a session they do not own | Session creator or admin |
| `session:<uuid>/end` | Any user wanting to terminate a session they do not own | Session creator or admin |
| `session:<uuid>/share` | Any user wanting to grant session access to a third party | Session creator or admin |
| `plugin:<name>/configure` | Any user wanting to set plugin config for a plugin they do not own | Admin |

The session creator automatically holds all `session:<uuid>/*` caps for their own sessions at session-create time. This is seeded in `Esr.Commands.Session.New.execute/1` analogously to how workspace creation seeds `workspace:<uuid>/*` caps.

The existing `session:default/create` cap (currently used by `/new-session`) is retained as the gate for `/session:new`.

### UUID translation for sessions

`Esr.Resource.Capability.UuidTranslator` (PR-230) is extended with a `session_name_to_uuid/2` function:

```elixir
@spec session_name_to_uuid(session_name :: String.t(), context :: map()) ::
        {:ok, String.t()} | {:error, :not_found}
def session_name_to_uuid(name, context) do
  # context includes chat_id and app_id for scoping lookup
  # looks up by name in ChatScope.Registry attached-set
  # returns the UUID or :not_found
end
```

Usage: at slash-dispatch time, when the operator types `/session:share esr-dev linyilun`, `SlashHandler` calls `UuidTranslator.session_name_to_uuid("esr-dev", context)` to resolve the UUID before constructing the cap string.

### Session sharing security model (Q9=C)

Cross-user session attach is intentionally not default-open. The attack surface:

1. UserA's session workspace root is `sessions/aaa-111/` and contains code, state, and CC configuration that UserA controls.
2. If UserB can attach without authorization, UserB can send arbitrary plain text or slash commands that are routed to UserA's CC agent. This could exfiltrate the repository contents, execute destructive git operations, or modify CC's `~/.claude.json` configuration.
3. Defense layer 1: `session:<uuid>/attach` cap check at `Esr.Commands.Session.Attach.execute/1`. The check fires before any dispatch to the session's agents.
4. Defense layer 2: `/session:share <session> <user> perm=attach` is the only way for a non-admin to grant the attach cap. The caller must hold `session:<uuid>/share`, which only the session creator and admins hold.
5. Defense layer 3: `attached_chats` in `session.json` records the audit trail of who attached when.

The `perm=admin` variant of `/session:share` grants `session:<uuid>/*` (all verbs). This should be used only for trusted collaborators.

---

## §6 — Plugin Config (3-Layer)

### Layer definitions (Q11=B, locked 2026-05-07)

The three layers and their storage locations:

**Layer 1 — Global** (lowest precedence):

```
$ESRD_HOME/<inst>/plugins.yaml
```

Existing file, gains an optional `config:` top-level key:

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

Backward compat: a file with only `enabled:` and no `config:` key is valid; the config map defaults to `%{}`.

**Layer 2 — User** (middle precedence):

```
$ESRD_HOME/<inst>/users/<username>/.esr/plugins.yaml
```

New file, one per user per instance. Lives inside the user-default workspace directory. Has only a `config:` key (no `enabled:` key — the user layer cannot enable/disable plugins).

```yaml
config:
  claude_code:
    anthropic_api_key_ref: "${MY_ANTHROPIC_KEY}"
    http_proxy: "http://user-proxy:8080"
```

An absent file is equivalent to `config: {}`.

**Layer 3 — Workspace** (highest precedence):

```
<workspace_root>/.esr/plugins.yaml
```

New file. `<workspace_root>` is the root of the session's currently-bound workspace:
- For auto-transient sessions: `$ESRD_HOME/<inst>/sessions/<session_uuid>/`
- For ESR-bound named workspaces: `$ESRD_HOME/<inst>/workspaces/<name>/`
- For repo-bound workspaces: `<repo>/`

Operators may commit this file to the repo to share project-specific config (e.g. proxy bypass or project-specific `esrd_url`) with teammates.

```yaml
config:
  claude_code:
    http_proxy: ""    # explicit empty = no proxy for this workspace
```

### Resolution algorithm (Elixir pseudocode)

```elixir
def resolve(plugin_name, opts \\ []) do
  username     = opts[:username]
  workspace_id = opts[:workspace_id]

  # 1. Load schema defaults
  schema   = load_schema(plugin_name)        # from manifest.config_schema
  defaults = schema_defaults(schema)         # {key => default_value}

  # 2. Load each layer (absent file = %{})
  global_layer    = read_global(plugin_name)
  user_layer      = if username,     do: read_user(plugin_name, username),          else: %{}
  workspace_layer = if workspace_id, do: read_workspace(plugin_name, workspace_id), else: %{}

  # 3. Per-key merge: lower layers first, higher layers override
  #    Map.merge/2: right-side wins on key collision
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
| Present | `""` | Wins; effective = "" (explicit empty string, e.g. to disable proxy) |
| Absent (key not in map) | — | Falls through to lower layer or schema default |

An operator who wants to "clear" the global proxy for a specific workspace sets `http_proxy: ""` in the workspace layer. An operator who has no opinion on proxy simply omits the key, and the global value propagates.

### `Esr.Plugin.Config` module (new, Phase 7)

```elixir
defmodule Esr.Plugin.Config do
  @moduledoc """
  3-layer plugin config resolution: global / user / workspace.

  Resolved at session-create time via resolve/2; stored in ETS keyed by
  {session_id, plugin_name, key}. Readable at any later point via get/2.

  Precedence: workspace > user > global (per-key merge).
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

ETS table `:plugin_config_cache` created at `Esr.Application.start/2`. Keyed by `{session_id, plugin_name, key_string}` → `value_string`.

Session-create integration (in `Esr.Commands.Session.New.execute/1`):

```elixir
# After workspace lookup, before spawning agent processes:
enabled_plugins = Esr.Plugin.EnabledList.get()

Enum.each(enabled_plugins, fn plugin_name ->
  config = Esr.Plugin.Config.resolve(plugin_name,
    username: cmd["submitter"],
    workspace_id: workspace.id
  )
  Esr.Plugin.Config.store(session_id, plugin_name, config)
end)
```

### Manifest `config_schema:` field (new)

Added to `Esr.Plugin.Manifest` struct as `declares.config_schema` (stored in the `declares` map under the `:config_schema` atom key, following the existing `atomize_declares/1` convention).

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
      Do not place the literal API key value in this field — use the env-var
      reference form and keep the actual key in the launchd plist or OS keychain.
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
    description: "Feishu app ID (cli_xxx). Required for Feishu API calls. Currently the shared app is cli_a9563cc03d399cc9."
    default: ""

  app_secret:
    type: string
    description: "Feishu app secret. Required for Feishu API calls. Keep this in the user-layer or global config; do not commit to repo."
    default: ""

  log_level:
    type: string
    description: "Log verbosity for the feishu adapter (debug|info|warning|error)."
    default: "info"
```

**Validation rules for `config_schema:` entries:**

- `type:` is required. Phase 1 supports `string` and `boolean`. Unknown type → `Manifest.parse/1` returns `{:error, {:config_schema_unknown_type, key, type}}`.
- `description:` is required. Absent → `{:error, {:config_schema_missing_field, key, "description"}}`.
- `default:` is required. Absent → `{:error, {:config_schema_missing_field, key, "default"}}`.
- No `sensitive:` field (user correction 2026-05-07 — dropped entirely).

**Operator protection on write:**

`Esr.Commands.Plugin.SetConfig.execute/1` validates `key` against `manifest.declares.config_schema` before writing. Unknown key → error message:

```
unknown config key 'http-proxy' for plugin claude_code
valid keys: http_proxy, https_proxy, no_proxy, anthropic_api_key_ref, esrd_url
```

### `depends_on:` enforcement (correction 2026-05-07)

Extend `Esr.Plugin.Loader.start_plugin/2`:

```elixir
defp check_dependencies(manifest, loaded_manifests) do
  missing = Enum.reject(manifest.depends_on.plugins, fn dep ->
    Map.has_key?(loaded_manifests, dep)
  end)
  case missing do
    [] -> :ok
    [_ | _] -> {:error, {:missing_dependency, hd(missing)}}
  end
end
```

Called before `Manifest.validate/1`. If the dependency check fails, `start_plugin/2` returns `{:error, {:missing_dependency, dep_name}}` and the plugin is not started. Let-it-crash: no workaround, no default fallback.

### Shell-script deletion map

`scripts/esr-cc.sh` and `scripts/esr-cc.local.sh` are deleted in Phase 8. Complete responsibility migration:

| Script responsibility | Migration destination |
|---|---|
| `http_proxy`, `https_proxy`, `no_proxy`, `HTTP_PROXY`, `HTTPS_PROXY` exports | `claude_code` plugin config; operator uses `/plugin:set claude_code http_proxy=... layer=user` |
| `ANTHROPIC_API_KEY` / `.mcp.env` source | Stays in launchd plist as system env var; `claude_code` config uses `anthropic_api_key_ref: "${ANTHROPIC_API_KEY}"` |
| `ESR_ESRD_URL` | `claude_code.config.esrd_url` |
| `exec claude` + `CLAUDE_FLAGS` construction | `Esr.Entity.PtyProcess` or `Esr.Plugins.ClaudeCode.Launcher` (Elixir-native; args built before erlexec spawn) |
| `session-ids.yaml` resume lookup + `--resume <id>` | Elixir before PTY spawn; passed as element of the `args:` list to erlexec |
| `.mcp.json` write | `Esr.Plugins.ClaudeCode.Launcher.write_mcp_json/1` before spawn |
| Workspace trust pre-write to `~/.claude.json` | Elixir via `File.write/2` before spawn |
| `mkdir -p "$cwd"` | Elixir `File.mkdir_p/1` before spawn |
| `ESRD_HOME`, `ESRD_INSTANCE` | Launchd plist only — esrd's own env vars |
| `ESR_WORKSPACE`, `ESR_SESSION_ID` | PtyProcess spawn env (already set by BEAM) |

Files referencing `esr-cc.sh` that must be updated in Phase 8:
- `runtime/lib/esr/entity/pty_process.ex:350` — `default_start_cmd/0` points at shell script; replace with Elixir-native launcher
- `runtime/lib/esr/entity/unbound_chat_guard.ex:104` — hint text references shell script path
- `runtime/test/esr/commands/workspace/info_test.exs:22` — fixture uses `start_cmd: "scripts/esr-cc.sh"`
- `runtime/test/esr/resource/workspace_registry_test.exs:20` — same fixture
- `scripts/final_gate.sh:342` — references `start_cmd=scripts/esr-cc.sh`
- `tests/e2e/scenarios/07_pty_bidir.sh:48` — comment references shell script
- `docs/dev-guide.md:37,212` — shell script in examples
- `docs/cookbook.md:74` — shell script in example command

---

## §7 — Migration Plan (10 Phases, Hard Cutover)

Each phase is one PR. The table shows primary file scope; full file lists are in each PR description.

| Phase | PR Title | Primary Files Changed | Est LOC | Depends On |
|---|---|---|---|---|
| 0 | `spec: metamodel-aligned ESR` (this document) | `docs/superpowers/specs/` | — | — |
| 1 | `feat: session UUID identity + storage layout` | `runtime/lib/esr/resource/session/*` (NEW), `Esr.Paths`, JSON schema helpers | ~800 | Phase 0 |
| 2 | `feat: chat→[sessions] attach/detach state` | `runtime/lib/esr/resource/chat_scope/registry.ex`, `chat_scope/file_loader.ex` | ~600 | Phase 1 |
| 3 | `feat: multi-agent per session` | `runtime/lib/esr/entity/agent/instance.ex` (NEW), `agent/registry.ex` extension, session-create integration | ~700 | Phase 1 |
| 4 | `feat: mention parser + primary-agent routing` | `runtime/lib/esr/entity/mention_parser.ex` (NEW), `entity/slash_handler.ex` routing | ~400 | Phase 3 |
| 5 | `feat: session cap UUID translation` | `runtime/lib/esr/resource/capability/uuid_translator.ex`, session-scoped cap seeding in `Session.New` | ~300 | Phase 1 |
| 6 | `feat: colon-namespace slash cutover + new session/pty/cap slashes` | `runtime/priv/slash-routes.default.yaml`, `slash_handler.ex`, all command modules, all test fixtures | ~1200 | Phase 1 + Phase 3 |
| 7 | `feat: plugin-config 3-layer + manifest config_schema + depends_on enforcement` | `runtime/lib/esr/plugin/manifest.ex`, `runtime/lib/esr/plugin/loader.ex`, `runtime/lib/esr/plugin/config.ex` (NEW), `runtime/lib/esr/plugins/*/manifest.yaml` | ~600 | Phase 6 |
| 8 | `chore: delete esr-cc.sh + esr-cc.local.sh + elixir-native PTY launcher` | `git rm scripts/esr-cc.sh scripts/esr-cc.local.sh`, `runtime/lib/esr/entity/pty_process.ex`, `runtime/lib/esr/plugins/claude_code/launcher.ex` (NEW), `tests/e2e/scenarios/` | ~300 deleted + ~400 added | Phase 7 |
| 9 | `docs+test: e2e scenarios 14-16 + docs sweep + obsolete comment cleanup` | `docs/`, `tests/e2e/scenarios/14-16_*.sh` (NEW), `tests/e2e/scenarios/common.sh` | ~400 | Phase 8 |

**Dependency DAG (strictly acyclic):**

```
0 → 1 → 2
         ↘ 3 → 4
              ↘ 5
     (1 + 3) → 6 → 7 → 8 → 9
```

Phase 1 is the foundation: session UUID identity and storage layout. Phases 2, 3, 5 all depend on Phase 1. Phase 4 depends on Phase 3 (agent instances must exist before mention parser can reference them). Phase 6 depends on Phase 1 (session commands need session registry) and Phase 3 (session add-agent command needs agent instance model). Phases 7, 8, 9 are strictly sequential.

**Estimated total:** ~5300 LOC across 10 PRs. Elapsed time: ~1-2 weeks with one developer.

### Phase 1 detail: Session UUID identity + storage layout

New modules required:

```
runtime/lib/esr/resource/session/
├── struct.ex        (Esr.Resource.Session.Struct — session.json schema as Elixir struct)
├── registry.ex      (GenServer; two ETS tables: uuid-keyed + name-keyed index)
├── file_loader.ex   (load/1; atomic read from sessions/<uuid>/session.json)
├── json_writer.ex   (write/2; atomic temp-rename pattern, matches PR-230 workspace pattern)
└── supervisor.ex    (started in Esr.Application before ChatScope.Registry)
```

`Esr.Resource.Session.Struct`:

```elixir
defmodule Esr.Resource.Session.Struct do
  defstruct [
    :id,
    :name,
    :owner_user,
    :workspace_id,
    :primary_agent,
    :created_at,
    agents: [],
    attached_chats: [],
    transient: true
  ]
end
```

Session registry boot: walks `Esr.Paths.sessions_dir/0`, parses every `session.json`, builds two ETS tables: `{:esr_sessions_uuid, uuid, struct}` and `{:esr_sessions_name, {owner_user, name}, uuid}`.

User-default workspace creation: extend `Esr.Commands.User.Add.execute/1` to call `create_user_workspace/1` after writing `users.yaml`. If `users/<username>/workspace.json` already exists, skip creation (idempotent).

### Phase 3 detail: Multi-agent per session

`Esr.Entity.Agent.Instance`:

```elixir
defmodule Esr.Entity.Agent.Instance do
  @moduledoc """
  An agent instance within a session.
  Name is globally unique within the session regardless of type.
  """
  defstruct [:session_id, :type, :name, :config, :pid]
  @type t :: %__MODULE__{}
end
```

Agent registry extension: `Esr.Entity.Agent.Registry` gains `{session_id, name} → Instance` index. Current per-plugin-type index is preserved for backward compat.

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

### Phase 6 detail: Colon-namespace slash cutover

Changes to `runtime/priv/slash-routes.default.yaml`:
- Rename all 30 primary slash keys to colon form (mechanical string edits).
- Remove all `aliases:` fields.
- Delete the `/workspace sessions` entry entirely.
- Add all new slash entries from §4.B, §4.C, §4.D, §4.E.

`Esr.Resource.SlashRoute.Registry` logic: confirmed no change needed. Key-agnostic ETS lookup.

`Esr.Resource.SlashRoute.FileLoader.validate_slash_key/1`: validates key starts with `/`. Colon-form keys still start with `/` — no change needed.

Test files with slash literals requiring updates (full list):
- `runtime/test/esr/entity/slash_handler_dispatch_test.exs`
- `runtime/test/esr/resource/slash_route/registry_test.exs`
- `runtime/test/esr/commands/help_test.exs`
- `runtime/test/esr/integration/new_session_smoke_test.exs`
- `runtime/test/esr/integration/feishu_slash_new_session_test.exs`
- `runtime/test/esr/plugins/feishu/feishu_app_adapter_test.exs`

New test files in Phase 6:
- `runtime/test/esr/resource/slash_route/colon_form_test.exs` — verifies all colon forms resolve via `Registry.lookup/1`
- `runtime/test/esr/entity/session_slash_test.exs` — integration: `/session:new`, `/session:attach`, `/session:add-agent`

---

## §8 — Risk Register

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | `ChatScope.Registry` data format change breaks running instances on upgrade | Medium | Boot migration in Phase 2 `file_loader.ex`: detect old single-slot format at load time, convert to attached-set, persist new format immediately. Verified at boot — not lazily. Regression test: boot with old format fixture, assert ETS contains new format. |
| R2 | Agent name collision on `/session:add-agent` — user confused by rejection | Low (design surface) | Name uniqueness check before insert; structured error: "agent name 'esr-dev' already exists in session (type: cc); choose a different name." Clear guidance on what names are taken via `/session:info`. |
| R3 | Cross-user attach security bypass — malicious user guesses UUID | Low (UUIDs are unguessable; cap is enforced) | UUID v4 has 2^122 bits of entropy. Cap check at `Esr.Commands.Session.Attach.execute/1` is the hard enforcement gate — UUID guess alone is insufficient. Audit trail in `attached_chats`. |
| R4 | Plugin config schema strictness rejects valid operators | Low | Schema validation fires only at write time (`/plugin:set`). Reads from disk for existing keys that predate the schema are accepted as-is (no retroactive schema enforcement at boot). Structured error on write includes the full list of valid keys. |
| R5 | Hard cutover slash names break existing operator bookmarks, Feishu history | Medium | No mitigation for Feishu history — operators must re-type. Phase 9 docs sweep updates all documentation. `/help` output shows new names; `/doctor` hints use new names. Announce via Feishu before Phase 6 merges. |
| R6 | Shell-script deletion + Elixir-native PTY launcher regression | Medium | Phase 8 `make e2e` gate: all existing e2e scenarios (01-13) must pass after deletion. Phase 8 specifically requires `make e2e-07` to pass (07_pty_bidir.sh has the strongest PTY coupling). Announce via Feishu before Phase 8 merges. |
| R7 | User-default workspace auto-creation fails if `users/` directory missing | Low | `Esr.Commands.User.Add` uses `File.mkdir_p/1` before writing `workspace.json`. Same atomic pattern as Phase 1 session creation. Unit test: add user to fresh instance, assert `users/<username>/workspace.json` exists. |
| R8 | `depends_on:` enforcement breaks existing plugins | Low | Both `feishu` and `claude_code` declare `depends_on: {core: ">= 0.1.0", plugins: []}`. Empty `plugins:` list means no inter-plugin dependency; enforcement only fires when a plugin explicitly lists a missing dependency. Regression: existing plugin boot test continues to pass. |

---

## §9 — Test Plan

### Unit tests by phase (write-failing-test-then-impl pattern)

**Phase 1 — Session identity and storage:**

| Test | Module | Assertion |
|---|---|---|
| UUID round-trip | `Session.Registry` | Create session → persist → reload → struct fields equal |
| Name → UUID index | `Session.Registry` | `lookup_by_name({owner, "esr-dev"})` returns correct UUID |
| FileLoader atomicity | `Session.FileLoader` | Partial write (simulated via tmp file left open) is not visible in registry |
| Paths helpers | `Esr.Paths` | `session_dir/1`, `session_json/1` return paths matching `$ESRD_HOME/<inst>/sessions/<uuid>/` |
| User-default workspace creation | `Commands.User.Add` | `esr user add alice` creates `users/alice/workspace.json` with `kind: "user-default"` |
| User workspace not in list | `Commands.Workspace.List` | `/workspace:list` does not include entries with `kind: "user-default"` |
| User workspace in info | `Commands.Workspace.Info` | `/workspace:info name=alice` returns the user-default workspace |

**Phase 2 — Chat attached-set:**

| Test | Module | Assertion |
|---|---|---|
| Attach to empty chat | `ChatScope.Registry` | After attach: `current = session_id`, `attached_set = [session_id]` |
| Detach | `ChatScope.Registry` | After detach: session removed from `attached_set`; `current` = nil (or next if multi) |
| Boot migration | `ChatScope.FileLoader` | Old single-slot format fixture → loaded as attached-set; file written in new format |
| Multi-attach + pointer switch | `ChatScope.Registry` | Attach session A, attach session B, detach A → B becomes current |
| Cross-session routing | `SlashHandler` | Plain text → current session's primary; `/session:attach B` → B's primary |

**Phase 3 — Multi-agent:**

| Test | Module | Assertion |
|---|---|---|
| Name collision — same name different type | `Commands.Session.AddAgent` | `{:error, {:duplicate_agent_name, "esr-dev"}}` |
| Name collision — same name same type | `Commands.Session.AddAgent` | Same error |
| Unique names succeed | `Commands.Session.AddAgent` | `{cc, "dev"}` + `{codex, "reviewer"}` → both in session.agents |
| Remove primary guard | `Commands.Session.RemoveAgent` | Cannot remove primary until set-primary to another agent |
| Set primary | `Commands.Session.SetPrimary` | `primary_agent` field updated; persisted to `session.json` |

**Phase 4 — Mention parser:**

| Test | Module | Assertion |
|---|---|---|
| `@esr-dev hello` with agent esr-dev | `MentionParser` | `{:mention, "esr-dev", "hello"}` |
| `@ hello` (lone @) | `MentionParser` | `{:plain, "@ hello"}` |
| `@unknown hello` (name not in session) | `MentionParser` | `{:plain, "@unknown hello"}` (routes to primary) |
| No @ in text | `MentionParser` | `{:plain, text}` |
| @mention in middle of text | `MentionParser` | Extracts name; rest is original text with token removed |

**Phase 5 — Cap UUID translation:**

| Test | Module | Assertion |
|---|---|---|
| Name → UUID translation | `Capability.UuidTranslator` | `session_name_to_uuid("esr-dev", ctx)` returns `{:ok, "aaa-111"}` |
| Unknown session name | `Capability.UuidTranslator` | `{:error, :not_found}` |
| Session creator auto-holds caps | `Commands.Session.New` | After session creation, owner has `session:<uuid>/attach`, `/add-agent`, `/end`, `/share` caps |

**Phase 6 — Colon-namespace:**

| Test | Module | Assertion |
|---|---|---|
| All colon forms resolve | `SlashRoute.Registry` | Each new colon-form key `Registry.lookup/1` returns `{:ok, route}` |
| Bare forms kept | `SlashRoute.Registry` | `/help`, `/doctor` still resolve |
| Old form → unknown command | `SlashHandler` | Input `/new-session` returns `unknown command: /new-session` |
| New session:new dispatch | Integration | `/session:new name=test` creates session, attaches to chat |
| New pty:key dispatch | Integration | `/pty:key keys=enter` dispatches to `Esr.Commands.Key` |

**Phase 7 — Plugin config:**

| Test | Module | Assertion |
|---|---|---|
| Manifest accepts valid config_schema | `Plugin.Manifest` | `parse/1` returns struct with `declares.config_schema` map |
| Manifest rejects missing `type:` | `Plugin.Manifest` | `{:error, {:config_schema_missing_field, key, "type"}}` |
| Manifest rejects unknown type | `Plugin.Manifest` | `{:error, {:config_schema_unknown_type, key, "integer"}}` |
| resolve — global only | `Plugin.Config` | Schema defaults + global layer; user/workspace absent → global wins |
| resolve — user overrides global on one key | `Plugin.Config` | User value wins; other keys use global |
| resolve — workspace overrides user and global | `Plugin.Config` | Workspace value wins |
| resolve — workspace empty-string wins | `Plugin.Config` | `""` from workspace wins over `"http://proxy"` from global |
| resolve — absent workspace falls through | `Plugin.Config` | Key absent from workspace → global value propagates |
| SetConfig rejects unknown key | `Commands.Plugin.SetConfig` | Error with valid key list; file unchanged |
| SetConfig writes to correct file | `Commands.Plugin.SetConfig` | Global layer: `$ESRD_HOME/<inst>/plugins.yaml` updated |
| depends_on enforcement | `Plugin.Loader` | Plugin with unmet dependency → `{:error, {:missing_dependency, dep}}` |

### E2E scenarios (new)

**Scenario 14: Multi-agent session**

Purpose: verify that two agents of possibly different types can coexist in a session and that `@<name>` routing works correctly.

```bash
# Setup: create session with two agents
esr admin submit session_new name=multi-test submitter=linyilun ...
esr admin submit session_add_agent session_id=$SID type=cc name=alice ...
esr admin submit session_add_agent session_id=$SID type=cc name=bob ...
# Assert session has two agents and primary = alice (first added)
SESSION_INFO=$(esr admin submit session_info session_id=$SID ...)
assert_contains "$SESSION_INFO" '"primary_agent":"alice"'
assert_contains "$SESSION_INFO" '"name":"bob"'

# Send @-addressed messages
REPLY=$(send_feishu_text "@alice ping" ...)
assert_contains "$REPLY" "alice received"
REPLY=$(send_feishu_text "@bob hello" ...)
assert_contains "$REPLY" "bob received"

# Plain text → primary (alice)
REPLY=$(send_feishu_text "plain message" ...)
assert_contains "$REPLY" "alice received"
```

**Scenario 15: Cross-user session attach**

Purpose: verify capability-gated cross-user attach; verify unauthorized attach is rejected.

```bash
# UserA creates session
esr admin submit session_new name=shared user=userA ...
SID=$SESSION_UUID

# Grant userB attach cap
/session:share shared userB perm=attach

# UserB attaches in a different chat
esr admin submit session_attach session=$SID chat=oc_yyy user=userB ...
assert_attached userB $SID oc_yyy

# UserC (no cap) tries to attach — should fail
RESULT=$(esr admin submit session_attach session=$SID chat=oc_zzz user=userC ...)
assert_error "$RESULT" "cap_check_failed"
```

**Scenario 16: Plugin config 3-layer resolution**

Purpose: verify that workspace layer wins over user, user wins over global, and empty-string wins over non-empty.

```bash
# Set http_proxy at global
/plugin:set claude_code http_proxy=http://global.proxy:8080 layer=global
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://global.proxy:8080"'

# User layer overrides
/plugin:set claude_code http_proxy=http://user.proxy:8080 layer=user
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://user.proxy:8080"'

# Workspace layer overrides to empty (disable proxy)
/plugin:set claude_code http_proxy="" layer=workspace
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = ""'

# Unset workspace → user re-emerges
/plugin:unset claude_code http_proxy layer=workspace
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://user.proxy:8080"'

# Unset user → global re-emerges
/plugin:unset claude_code http_proxy layer=user
EFFECTIVE=$(/plugin:show claude_code layer=effective)
assert_contains "$EFFECTIVE" 'http_proxy = "http://global.proxy:8080"'
```

---

## §10 — Open Questions (for User Round-3+)

The following questions are not decided in this spec. They are explicitly flagged as open to avoid embedding hidden assumptions. The user should answer these before or alongside Phase 1 implementation begins.

**Q-OQ1: User UUID identity**

Today users are keyed by username (string) in `users.yaml`. This spec defaults to `users/<username>/` paths and `username`-keyed ETS tables. The question: should we introduce user UUIDs in a follow-up phase, parallel to PR-230's workspace UUID redesign? A user UUID would allow username renames without breaking capability references (caps today use username in the grantee field). Spec does not block on this — default is username paths — but the decision affects whether to design the user-layer storage path as `users/<username>/` or `users/<uuid>/` (with a name → UUID index).

If the answer is yes (introduce user UUID), the Phase 1 work on user-default workspace creation should use a UUID-keyed path from the start, to avoid a painful migration later.

**Q-OQ2: Session naming — human-friendly name + UUID dual-track**

PR-230 gives workspaces both a human-friendly name and a UUID. This spec proposes the same for sessions: `/session:new name=X` provides the name; the UUID is auto-generated. Should session-scoped cap strings accept the human name as input (e.g. `session:esr-dev/attach` resolved to UUID at CLI edges via `UuidTranslator`), or require UUID always?

**Q-OQ3: Default-attached behavior on `/session:new`**

When a session is created, should it be automatically attached to the creating chat and set as the attached-current pointer? This spec proposes YES (operator expectation based on audit step 8 → 9 flow). But it means the first `/session:new` immediately sets the chat-current session, possibly surprising operators who create multiple sessions before working in any of them. Please confirm.

**Q-OQ4: `/session:share` default permission**

`/session:share <session> <user>` defaults to `perm=attach`. The alternative is `perm=admin`. Spec proposes `perm=attach` as the safer default (attach allows use but not management; admin allows full control). Please confirm.

**Q-OQ5: `/cap:grant` name-keyed input for session caps**

Existing `esr cap grant` escript command today requires cap strings in the form `session:<uuid>/attach`. Should it also accept `session:<name>/attach` (resolving via `UuidTranslator`)? This matches the workspace pattern (`workspace:my-ws/read` is translated to `workspace:<uuid>/read` at the CLI edge). Spec proposes yes — name-keyed input at CLI edges, UUID-keyed internally.

---

## §11 — Cross-References

- `docs/notes/concepts.md` (rev 9, 2026-05-03) — Tetrad Metamodel. The normative source for all primitive definitions (Scope, Entity, Resource, Interface, Session) used in this spec. §九 of that document is the canonical multi-agent group-chat example this spec implements.
- `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md` (rev 3) — Workspace UUID prior art. This spec extends the UUID pattern (UUID-keyed registry, name→UUID index, `UuidTranslator`) to sessions. The 3-layer plugin config adds `.esr/plugins.yaml` as a new file within workspaces.
- `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` — Operator pain points. The 12-step bootstrap journey and 5 cross-cutting gaps that motivated this redesign. Every step and gap is addressed by phases in §7.
- `runtime/priv/slash-routes.default.yaml` — Current slash inventory baseline (30 primary entries + internal_kinds). Phase 6 rewrites all 30 primary keys to colon form, removes all aliases, drops `/workspace sessions`, and adds the new session/pty/plugin/cap slashes.
- `runtime/lib/esr/resource/workspace/registry.ex` — Workspace UUID model (PR-230). Session registry follows the same two-ETS-table pattern (legacy name-keyed + new UUID-keyed).
- `runtime/lib/esr/resource/chat_scope/registry.ex` — Current chat-current-slot (`(chat_id, app_id)` → `session_id`). Phase 2 migrates to attached-set (`{current: session_id, attached_set: [session_id]}`).
- `runtime/lib/esr/entity/user/registry.ex` + `file_loader.ex` — Current user model (username-keyed, `users.yaml` backed, no UUID). Phase 1 extends `Esr.Commands.User.Add` to create user-default workspace on user creation.
- `runtime/lib/esr/plugin/manifest.ex` + `runtime/lib/esr/plugins/*/manifest.yaml` — Plugin manifest struct and in-tree plugins. Phase 7 adds `config_schema:` field to manifest parsing and adds `config_schema:` blocks to both `claude_code/manifest.yaml` and `feishu/manifest.yaml`.
- `scripts/esr-cc.sh` + `scripts/esr-cc.local.sh` — Shell scripts deleted in Phase 8. Full responsibility migration map in §6 under "Shell-script deletion map."
- (Reference) `spec/colon-namespace-grammar` branch, `docs/superpowers/specs/2026-05-07-colon-namespace-grammar.md` — Absorbed into §4. Note that §3.4 of that spec proposed a `@deprecated_slashes` map; this has been dropped per user correction.
- (Reference) `spec/plugin-set-config` branch, `docs/superpowers/specs/2026-05-07-plugin-set-config.md` — Absorbed into §6. Key corrections from user dialog: (a) `sensitive:` flag dropped; (b) "project layer" renamed to "workspace layer" to match Q10 locked decision; (c) feishu manifest gets `app_id` + `app_secret`; (d) user-layer path is `users/<username>/.esr/plugins.yaml`, not `users/<username>/plugins.config.yaml` (consistent with user-default workspace as the container).

---

## §12 — Self-Review Checklist

This section documents the spec author's verification pass against the prompt requirements. It is included in the document so code-reviewers and the user can audit the same checklist.

### Locked decisions coverage

| Decision | Reflected in Spec? | Section |
|---|---|---|
| Q1=A: same type, multiple instances | Yes | §2, §4.B `/session:add-agent` |
| Q2 refined to Q7=B: plain text `@<name>` simple string match | Yes | §4 mention parser spec, §4.B note on Q7 |
| Q3=C with twist: per-session workspace primary, chat-default fallback | Yes | §2 before/after comparison, §3 `session.json` `workspace_id` |
| Q4: 1 chat = N parallel sessions with attach | Yes | §2 diagram, §3 attached-set format, §4.B `/session:attach` |
| Q5=一气呵成: one coherent migration | Yes | §7 10-phase plan; §1 Goals item 5 |
| Q6=D: operator-set primary, default=first | Yes | §4.B `/session:set-primary`, §3 `session.json` `primary_agent` field |
| Q7=B: globally unique agent names within session, no type prefix | Yes | §3 `session.json` notes, §7 Phase 3 detail, §8 R2 |
| Q8=A: attached-current pointer per chat | Yes | §2 diagram, §4 mention parser fallback to primary |
| Q9=C: imperative + declarative session sharing | Yes | §5 session sharing security model |
| Q10=C: session IS a workspace (`sessions/<uuid>/`) | Yes | §3 storage layout `sessions/<uuid>/workspace.json` |
| Q11=B: 3-layer config global→user→workspace | Yes | §6 layer definitions |
| User insight: user-default workspace at `users/<username>/` | Yes | §2 user-default workspace section, §3 storage layout |

### User corrections coverage

| Correction | Reflected in Spec? | Section |
|---|---|---|
| Drop `/session:add-folder` | Yes | §4.B — not listed; §4 note "folders stay on `/workspace:add-folder`" |
| `/key` → `/pty:key` (not `/session:key`) | Yes | §4 inventory table (old→new row), §4.C new `/pty:*` family |
| Drop `/workspace:sessions` | Yes | §4 inventory table "DROPPED", §4 grammar rule 6 |
| Drop `@deprecated_slashes` map | Yes | §4 grammar rule 1, §7 Phase 6 detail last paragraph |
| feishu manifest: `app_id` + `app_secret` in `config_schema:` | Yes | §6 feishu manifest addition block |
| `depends_on:` enforce at `Loader.start_plugin/2` | Yes | §6 `depends_on:` enforcement section |
| Per-key merge, first-set-wins at most-specific layer | Yes | §6 resolution algorithm and key merge semantics table |
| Drop `sensitive:` flag entirely | Yes | §6 `config_schema:` design notes (no `sensitive:` in any snippet) |
| Only esrd's own env vars in launchd plist | Yes | §6 shell-script deletion map; ANTHROPIC_API_KEY stays, everything else moves |

### Structural checks

| Check | Status |
|---|---|
| Storage layout includes `users/<username>/` user-default workspace | Yes — §3 full directory tree |
| Plugin config 3-layer with workspace as "project-equivalent" | Yes — §6; "project layer" explicitly renamed to "workspace layer" per user correction |
| feishu manifest `config_schema:` includes `app_id` + `app_secret` | Yes — §6 feishu manifest addition |
| User-UUID flagged as open question, NOT silently committed to | Yes — §10 Q-OQ1 |
| EN + zh_cn paragraph-aligned (same sections, same order) | Yes — both files written in §0-§11 order |
| Migration plan has 10 phases with DAG, no cycles | Yes — §7 table + DAG diagram |
| No emoji in either file | Yes |
| All file paths repo-relative or `$ESRD_HOME/<inst>/`-prefixed | Yes — reviewed all paths in §3 and §6 |

### Potential concerns (for code-reviewer and user)

1. **`/session:new` auto-attach behavior (Q-OQ3)**: spec proposes auto-attach as YES (auto-sets attached-current pointer to the created session). This is a `[SPEC AUTHOR DECISION]` — not in the user-locked set. If the answer is NO, Phase 2 must not set attached-current on creation.

2. **`/session:attach` two-level cap check**: YAML sample shows `permission: "session:default/attach"` as a pre-check, with the specific `session:<uuid>/attach` checked inside the command module. This mirrors how workspace commands work (generic `workspace.create` as gate + UUID-level cap inside). Needs explicit documentation in Phase 5 spec PR description.

3. **User-layer config file path change from prior spec**: Prior `spec/plugin-set-config` used `users/<username>/plugins.config.yaml`. This spec uses `users/<username>/.esr/plugins.yaml`. Operators migrating from the prior draft must use the new path. The `.esr/` subdirectory is consistent with workspace-layer config (`<workspace>/.esr/plugins.yaml`).

4. **`session.json` `name` uniqueness scope**: scoped to `(owner_user, name)` tuple, not globally. Two different users may each have a session named "esr-dev". The UuidTranslator must use chat context (which user is the session owner) to resolve names. This is fine but must be documented in Phase 5 implementation.

5. **`depends_on.core` version check**: manifest struct stores `depends_on.core` as a version constraint string (e.g. `">= 0.1.0"`). This spec only requires enforcing `depends_on.plugins` (inter-plugin dependencies). The `core` version constraint is not enforced in Phase 7 (deferred — would require semantic version comparison logic). Document this explicitly in the Phase 7 PR description.

---

## §13 — Invariant Tests (Completion Gates)

Per the project principle (MEMORY.md: "never claim a multi-PR phase 'done' on PR-merge + tests-pass alone; define a test that fails when the architectural goal is unmet"): the following invariant tests define the completion gate for each phase.

**Phase 1 invariant — User-default workspace creation:**
A fresh instance with `esr user add alice` must produce `users/alice/workspace.json` with `kind: "user-default"`. Test: `assert File.exists?(Esr.Paths.user_workspace_json("alice"))` and `assert workspace.kind == "user-default"`.

**Phase 1 invariant — Session storage:**
A session created via `Session.Registry.create/1` must be readable from disk after a process restart (simulate by calling `Session.FileLoader.load/1` fresh). Test: `create → restart simulation → load → assert struct fields match`.

**Phase 2 invariant — Attached-set atomicity:**
A chat that has had two sessions created (A and B) and session A detached must have `attached_set = [B]` and `current = B.id`. Test: programmatic attach A, attach B, detach A; `assert attached_set == [b_uuid]`.

**Phase 3 invariant — Agent name uniqueness:**
A session cannot contain two agents with the same name regardless of type. Test: add `{cc, "esr-dev"}` → add `{codex, "esr-dev"}` → second add must return `{:error, {:duplicate_agent_name, "esr-dev"}}`.

**Phase 4 invariant — Mention routing to unknown agent falls through:**
A message `@nonexistent hello` dispatched to a session with one agent named "alice" must route to alice's input, not return an error. Test: dispatch; assert alice's CCProcess received the text.

**Phase 5 invariant — Session creator cap auto-seeding:**
Immediately after `/session:new`, the creator must hold `session:<uuid>/attach`, `session:<uuid>/add-agent`, `session:<uuid>/end`, `session:<uuid>/share` without any explicit grant call. Test: `assert Esr.Resource.Capability.Grants.has?(creator_username, "session:#{uuid}/attach")`.

**Phase 6 invariant — No old-form slash in yaml:**
No primary slash entry in `runtime/priv/slash-routes.default.yaml` uses space separator or dash-prefix form (except `/help` and `/doctor` which are bare). Test: `grep -E '^  "/(new-|end-|list-|[a-z]+ [a-z])' slash-routes.default.yaml | wc -l` must equal 0.

**Phase 7 invariant — Per-key merge correctness:**
With global `http_proxy="http://g"`, user `http_proxy="http://u"`, workspace key absent: `Config.resolve("claude_code", username: "alice", workspace_id: w_id)["http_proxy"]` must equal `"http://u"` (user wins over global). Test: write fixtures; assert resolved value.

**Phase 8 invariant — Shell scripts deleted:**
`scripts/esr-cc.sh` and `scripts/esr-cc.local.sh` must not exist. Test: `assert not File.exists?("scripts/esr-cc.sh")`. `make e2e` must pass (all scenarios 01-13).

**Phase 9 invariant — Multi-agent and cross-user attach:**
Scenario 14 (multi-agent session) and Scenario 15 (cross-user attach) must both pass. These are the behavioral gates for the core architectural goals of this spec.

---

## §14 — Implementation Notes and Elixir Conventions

### Session registry boot order

`Esr.Resource.Session.Registry` must start before `Esr.Resource.ChatScope.Registry`. Rationale: the Phase 2 boot migration in `ChatScope.FileLoader.load/1` may need to look up session UUIDs from `Session.Registry` to verify that chat-attached session IDs refer to valid sessions. If a session UUID is not found in `Session.Registry`, the migration treats the chat-current slot as stale and clears it.

Add to `Esr.Application.start/2`:

```elixir
# After workspace registry, before chat_scope registry:
{Esr.Resource.Session.Supervisor, []},
{Esr.Resource.ChatScope.Registry, []},
```

### Agent instance lifecycle

When `/session:add-agent` runs, the flow is:

1. Validate name uniqueness in `Session.Registry`.
2. Update `session.json` (add agent entry, write atomically).
3. Spawn the agent process: call the plugin's spawn hook (e.g. `Esr.Entity.CCProcess.start_link/1` for `type=cc`). The process receives `session_id`, `agent_name`, resolved plugin config.
4. Update `Agent.Registry` with the new `{session_id, name}` → `pid` mapping.
5. Reply to the slash command with confirmation.

On `/session:remove-agent`:

1. Validate name exists and is not primary (guard).
2. Kill the agent process: `GenServer.stop/1` or `Process.exit(pid, :shutdown)`.
3. Remove from `Agent.Registry`.
4. Update `session.json` (remove agent entry).

### Plugin config ETS cache invalidation

After `/plugin:set` writes to disk, `Esr.Plugin.Config.invalidate/1` is called. This match-deletes all ETS entries for the plugin across all sessions:

```elixir
:ets.match_delete(:plugin_config_cache, {{:_, plugin_name, :_}, :_})
```

Running sessions retain their resolved config (resolved at session-create time). The next session to be created will resolve fresh from disk. This is the acceptable behavior for restart-required semantics.

If a running session operator runs `/plugin:set` and then expects the change to apply to the current session without restart, they must `/session:end` the current session and `/session:new` to start a new one.

### `Esr.Entity.MentionParser` — integration point

The mention parser is called from `Esr.Entity.SlashHandler.handle_cast/2` in the non-slash branch (after `registry.ex` returns `:not_found`). The current non-slash path routes all non-slash text to the session's single CC process. After Phase 4, it calls `MentionParser.parse(text, session_agents)` and dispatches based on the result.

The `session_agents` argument is a list of `{name, pid}` pairs. The parser compares the extracted `@<name>` against names in this list. PID lookup for dispatch uses the same list.

### `session.json` write atomicity

Follows the pattern established in PR-230 for `workspace.json`:

1. Write new content to a temp file at `<session_dir>/session.json.tmp`.
2. `File.rename/2` to replace `session.json` atomically (POSIX guarantee on same filesystem).
3. On error, delete the temp file and return `{:error, reason}`.

This prevents partial writes from corrupting the session state.

### `workspace.json` for sessions — workspace_id self-reference

The auto-transient workspace at `sessions/<session_uuid>/workspace.json` has a `workspace_id` field that is a separate UUID (the workspace UUID, not the session UUID). This may look redundant since the directory is already named by the session UUID. The design reason: session UUID ≠ workspace UUID. After `/session:bind-workspace`, the session's `workspace_id` changes to the named workspace UUID. The `sessions/<session_uuid>/workspace.json` file then becomes the stale auto-transient workspace (not deleted automatically — operator prunes or it is pruned on session end if transient=true and clean). The session's `workspace_id` always points to the active workspace UUID.

The workspace registry must recognize `sessions/<uuid>/workspace.json` files and load them as workspaces of `kind: "session-transient"`. These should not appear in `/workspace:list` (filter by kind).

### Error handling conventions (let-it-crash)

Per the user principle: no workarounds, no defaults that paper over structural errors, no `:warning`+degrade paths. Concrete rules for this spec's new modules:

- `Session.Registry` startup: if `sessions_dir/0` does not exist, create it with `File.mkdir_p/1`. If creation fails → crash (`File.mkdir_p!/1`).
- `Session.FileLoader.load/1`: if `session.json` is malformed → `{:error, {:parse_failed, ...}}`. The registry skips the malformed session and logs an error. Other sessions continue to boot. (Exception to let-it-crash: a single malformed session file should not prevent the daemon from booting — this matches the workspace registry's existing behavior.)
- `Plugin.Config.resolve/2`: if the user-layer file cannot be read (permissions) → log warning, treat as absent (`{}`). Do not crash. (The user may not have set any user-layer config yet, and file absence is the normal case.)
- `Plugin.Loader.start_plugin/2` with unmet `depends_on`: return `{:error, {:missing_dependency, dep}}`. The Loader logs the error and skips that plugin. This IS a crash-worthy condition for production — the operator must enable the dependency.

### Test fixture conventions

Phase 1 tests that need a `session.json` fixture should use the `Esr.Resource.Session.Struct` builder, not raw JSON strings. Phase 6 tests that need slash routes should use `Esr.Resource.SlashRoute.Registry.test_mode!/1` to load a minimal yaml. Phase 7 tests that need manifest fixtures should use `Esr.Plugin.Manifest.parse/1` with a temp dir containing a minimal `manifest.yaml`.

All Phase 1-9 tests follow the project pattern: ExUnit with `setup` blocks that create a temp `$ESRD_HOME` dir, populate it, run assertions, then delete it in `on_exit`.

### Feature flag consideration

None of the 10 phases require a feature flag. The dependency ordering ensures each phase is internally consistent and shippable without breaking existing behavior. Phase 6 (colon-namespace cutover) is the most disruptive, but since E2E scenarios use internal kind names (not slash text), the cutover does not break the automated test suite. Manual Feishu testing must be done before Phase 6 merges.

### Handling the `workspace_id` bootstrap in `session.json`

A chicken-and-egg problem exists at session creation: the auto-transient workspace at `sessions/<uuid>/workspace.json` needs a UUID, and the `session.json` needs the workspace UUID. Resolution: generate both UUIDs before writing either file.

```elixir
def execute(cmd) do
  session_uuid   = UUID.uuid4()
  workspace_uuid = UUID.uuid4()

  session_dir   = Esr.Paths.session_dir(session_uuid)
  workspace_dir = session_dir  # same directory

  # Create directory first
  :ok = File.mkdir_p!(session_dir)

  # Write workspace.json for the auto-transient workspace
  workspace = %Esr.Resource.Workspace.Struct{
    id:         workspace_uuid,
    name:       session_uuid,   # use session UUID as workspace name for uniqueness
    owner:      cmd["submitter"],
    kind:       "session-transient",
    transient:  true,
    created_at: DateTime.utc_now()
  }
  :ok = Esr.Resource.Workspace.JsonWriter.write(workspace_dir, workspace)

  # Write session.json
  session = %Esr.Resource.Session.Struct{
    id:           session_uuid,
    name:         cmd["name"] || "session-#{DateTime.to_iso8601(DateTime.utc_now())}",
    owner_user:   cmd["submitter"],
    workspace_id: workspace_uuid,
    agents:       [],
    primary_agent: nil,
    attached_chats: [],
    transient:    true,
    created_at:   DateTime.utc_now()
  }
  :ok = Esr.Resource.Session.JsonWriter.write(session_dir, session)

  # Register both in their respective registries
  Esr.Resource.Workspace.Registry.put(workspace)
  Esr.Resource.Session.Registry.put(session)

  {:ok, session}
end
```

This pattern eliminates any ordering dependency between workspace and session creation: both are generated atomically within the same command execution.

### Summary of new modules to create

For implementors, the complete list of new Elixir modules this spec requires:

| Module | Phase | Purpose |
|---|---|---|
| `Esr.Resource.Session.Struct` | 1 | Session struct matching `session.json` schema |
| `Esr.Resource.Session.Registry` | 1 | GenServer; ETS two-table (uuid + name index) |
| `Esr.Resource.Session.FileLoader` | 1 | Load `session.json` from disk |
| `Esr.Resource.Session.JsonWriter` | 1 | Atomic write `session.json` |
| `Esr.Resource.Session.Supervisor` | 1 | Supervisor for session registry |
| `Esr.Entity.Agent.Instance` | 3 | Agent instance struct |
| `Esr.Entity.MentionParser` | 4 | Parse `@<name>` in plain text |
| `Esr.Plugin.Config` | 7 | 3-layer resolution + ETS cache |
| `Esr.Commands.Session.New` | 6 | Rename from `Esr.Commands.Scope.New` |
| `Esr.Commands.Session.Attach` | 6 | New: attach to existing session |
| `Esr.Commands.Session.Detach` | 6 | New: leave session without ending |
| `Esr.Commands.Session.End` | 6 | Rename from `Esr.Commands.Scope.End` |
| `Esr.Commands.Session.List` | 6 | Rename from `Esr.Commands.Scope.List` |
| `Esr.Commands.Session.AddAgent` | 6 | New: add agent instance |
| `Esr.Commands.Session.RemoveAgent` | 6 | New: remove agent instance |
| `Esr.Commands.Session.SetPrimary` | 6 | New: set primary agent |
| `Esr.Commands.Session.BindWorkspace` | 6 | New: rebind to named workspace |
| `Esr.Commands.Session.Share` | 6 | New: grant attach cap |
| `Esr.Commands.Session.Info` | 6 | New: session details |
| `Esr.Commands.Plugin.SetConfig` | 7 | New: write config key to layer |
| `Esr.Commands.Plugin.UnsetConfig` | 7 | New: delete config key from layer |
| `Esr.Commands.Plugin.ShowConfig` | 7 | New: display config (effective or per-layer) |
| `Esr.Commands.Plugin.ListConfig` | 7 | New: display all plugins' effective config |
| `Esr.Plugins.ClaudeCode.Launcher` | 8 | Elixir-native CC launcher (replaces esr-cc.sh) |
