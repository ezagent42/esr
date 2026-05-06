# Workspace VS-Code-style redesign

**Status**: design (2026-05-06)
**Brainstorm**: in-conversation 2026-05-06
**Estimated implementation**: ~1300-1700 LOC across 1 main PR + docs sweep (rev-3: + UUID identity + name↔id index + cap UUID translation layer + hybrid storage discovery + registered_repos.yaml + 2 new slashes `/workspace import-repo` & `forget-repo`; − migrator entirely; − file watcher entirely)
**Related**: deferred from `esr daemon init` PR (see `docs/futures/todo.md`)

## Goal

Redesign the `workspace` Resource so its data form matches operator
mental model and removes the schema-drift class of bug we hit with
`/help` after PR-198. Replace the single `workspaces.yaml` file with
per-workspace directories under `$ESRD_HOME/<instance>/workspaces/`,
each containing a `workspace.json` modeled after VS Code's
`.code-workspace` schema. Keep workspace as an application-level
Resource (its place in the metamodel does not change); change only
its data form, file layout, and CLI surface.

## Non-goals

- Removing the `workspace` concept entirely (we discussed and
  rejected; it still serves identity, cap scoping, multi-app
  routing, and metadata anchoring).
- Auto-detecting workspace from cwd. Workspace must be referenced
  by name. (`/new-session <ws_name>` etc.)
- Backwards compatibility with the old `workspaces.yaml` format
  beyond a one-shot migrator (see Migration).
- **Manual-edit-friendly capabilities.yaml.** Caps are stored
  internally by workspace UUID (`session:<uuid>/create`) and
  rendered to operators by name through CLI translation. Hand-
  editing capabilities.yaml is not the supported workflow.
  Operators use `/cap grant`, `/cap revoke`, etc. exclusively.
- **Reassigning a session to a different workspace.** A session's
  workspace binding is **immutable after spawn**. There is no
  `/session switch-workspace` command. Operators who want a
  different workspace must `/end-session <sid>` then
  `/new-session <new_ws> name=<sid>` (`claude --resume` recovers
  conversation context across the respawn). This avoids mid-session
  cwd / env / settings divergence between the cc process state and
  the workspace's current config.

## Problem

`workspace` today is a yaml row in `~/.esrd/<inst>/workspaces.yaml`.
Three issues drove this redesign:

1. **Schema drift bug class.** The yaml is operator-edited yet
   carries fields whose semantics are owned by core code. When core
   evolves (e.g. PR-198 renamed `Esr.Admin.Commands.*` →
   `Esr.Commands.*`), older yaml goes stale and is silently
   rejected by the loader. The `slash-routes.yaml` instance of this
   broke `/help` for an operator and was hard to diagnose.
2. **Missing operator concepts.** Operators want VS Code-like
   per-workspace settings (cc model override, allowed tools,
   logging level). Yaml row layout doesn't accommodate this.
3. **Multi-root projects.** Real work spans multiple repos
   (`Workspace/esr` + `Workspace/cc-openclaw` + tooling repo).
   Today workspace ties to one repo path. VS Code's `folders[]`
   array models this naturally.

## Design

### Hybrid storage: workspace.json can live in two places

A workspace's `workspace.json` lives in **one of two locations**.
The runtime treats both forms uniformly — same code path, same
`Workspace` Resource, only the discovery layer differs.

**(A) Repo-bound** — workspace travels with a git repo:

```
<repo>/.esr/                       # in user's git repo (committed)
  workspace.json                   # workspace identity + config
  topology.yaml                    # project-shareable metadata (also committed)
```

When teammate clones the repo, they get the workspace too. This is
the **default mode** for project workspaces.

**(B) ESR-bound** — workspace lives only in ESRD_HOME:

```
$ESRD_HOME/<instance>/workspaces/
  <name>/                          # ESR-managed; no git repo
    workspace.json                 # workspace identity + config
```

Reserved for system workspaces that have no project repo:
- `default` — auto-created by `esr daemon init`, fallback for
  `/new-session name=<sid>` when no workspace is implied
- transient workspaces (created with `transient: true`)
- ad-hoc scratch workspaces operators want without registering a
  repo

### Session state always lives in ESRD_HOME

Session runtime state — pid, port, transient logs, scope-internal
files — stays under ESRD_HOME regardless of whether the workspace
is repo-bound or ESR-bound:

```
$ESRD_HOME/<instance>/sessions/<sid>/
  ... (session-scoped files; format defined elsewhere)
```

This keeps the user's git repo clean (no `.esr/sessions/<sid>/`
churn polluting their working tree) and means a `git status` on
the repo never shows ESR runtime state as untracked.

### Workspace identity: UUID

Every workspace gets a **UUID v4** at creation time, stored as
`workspace.json.id`. This UUID is the canonical identity for all
internal references:

- `capabilities.yaml` stores cap grants by UUID
  (`session:<uuid>/create`, `workspace:<uuid>/manage`)
- session→workspace binding is stored by UUID
- chat-current-slot's "default workspace for this chat" is stored
  by UUID

**Operator-visible names are looked up via name↔id index.** When an
operator types `/cap grant linyilun session:esr-dev/create`, the
runtime resolves `esr-dev` → UUID and persists the UUID form. When
`/cap list` renders output, UUIDs are translated back to names.

This decoupling makes `/workspace rename` essentially **free** —
update `workspace.json.name` and the in-memory name↔id index, no
cap-yaml rewrite, no session migration. References never go stale.

If a workspace is removed, lingering caps that reference its UUID
are rendered as `workspace:<UNKNOWN-7b9f...>/manage` so operators
can clean them up via `/cap revoke`.

### Discovery and registration

ESR discovers workspaces from three sources, all on boot and on
explicit operator action:

1. **ESR-bound**: walk `$ESRD_HOME/<inst>/workspaces/`, read each
   subdirectory's `workspace.json`. Always discovered.
2. **Repo-bound**: walk a list of registered repo paths, read each
   `<repo>/.esr/workspace.json`. The list lives at
   `$ESRD_HOME/<inst>/registered_repos.yaml` (created on demand;
   contains absolute paths and optional human-friendly names).
3. **Auto-detect on `/new-session ... cwd=<path>`**: when a slash
   command supplies an explicit `cwd=<path>` and ESR finds
   `<path>/.esr/workspace.json` but the path is not yet in
   `registered_repos.yaml`, the path is auto-registered (added to
   the list, workspace loaded into the registry).

**Repo registration is per-machine.** Operator B who clones a repo
must either run `/workspace import-repo <path>` once or rely on
auto-detect when they invoke `/new-session ... cwd=<path>`. The
registered-repos list is not synced across machines.

### After the registry is built

Once both sources are merged into the in-memory registry, the
runtime treats all workspaces uniformly. Slash commands reference
workspaces by name; the lookup translates to UUID and reads the
backing `workspace.json` regardless of where it lives.

If the same UUID appears in both sources (operator copy-pasted a
workspace.json), boot fails loudly with a duplicate-id error
naming both files. Operators must resolve before esrd starts.

### workspace.json schema (v1)

```json
{
  "$schema": "file:///path/to/runtime/priv/schemas/workspace.v1.json",
  "schema_version": 1,

  "id": "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
  "name": "esr-dev",
  "owner": "linyilun",

  "folders": [
    { "path": "/Users/h2oslabs/Workspace/esr", "name": "esr" },
    { "path": "/Users/h2oslabs/Workspace/cc-openclaw", "name": "cc-openclaw" }
  ],

  "agent": "cc",
  "settings": {
    "cc.model": "claude-opus-4-7",
    "cc.system_prompt_extra": "Project: ESR. Be concise.",
    "cc.allowed_tools": ["Bash", "Edit", "Read", "Grep"],
    "logging.level": "debug"
  },
  "env": {
    "PROJECT_ENV": "dev"
  },

  "chats": [
    { "chat_id": "oc_b7a242b742855d469be27b601abb693b", "app_id": "cli_a97ae5a8d4e39bdd", "kind": "dm" }
  ],

  "transient": false
}
```

| Field | Required | Type | Purpose |
|---|---|---|---|
| `$schema` | recommended | URL | editor autocomplete + JSON Schema validation |
| `schema_version` | required | integer | migration anchor; v1 must be `1` |
| `id` | required | UUID v4 string | canonical identity. Generated at `/new-workspace` time. All internal references use this. **Never changes**. Storage shape is `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` (RFC 4122 §4.4). |
| `name` | required | string | display name. Operator-visible. Translated to/from `id` via in-memory name↔id index. May be renamed (`/workspace rename`); the `id` stays put. Two workspaces in the same registry must have unique names; uniqueness check on registration. |
| `owner` | required | string | esr-username; must exist in `users.yaml` |
| `folders` | optional | array of `{path, name?}` | external repo bindings; cwd resolution per below |
| `agent` | optional (default `"cc"`) | string | which `agents.yaml` entry to use |
| `settings` | optional | flat dot-namespaced map | per-workspace agent/runtime overrides |
| `env` | optional | string→string map | env vars threaded into spawned sessions |
| `chats` | optional | array of `{chat_id, app_id, kind?}` | which chats default-route to this workspace |
| `transient` | optional (default `false`) | bool | when `true`, last-session-end auto-removes the workspace's storage. **Only valid for ESR-bound workspaces**; setting `transient: true` on a repo-bound workspace is rejected at write time (because we won't `rm -rf` a user's git repo). |

### Cwd resolution (folders → session.cwd)

The cwd that a session inherits depends on `folders.length` and on
whether the workspace is repo-bound or ESR-bound:

| `folders.length` | Repo-bound workspace | ESR-bound workspace |
|---|---|---|
| 0 | (impossible — repo-bound implies at least one folder, which is the repo itself; `folders[0]` is auto-populated to the repo path on `/workspace import-repo`) | `$ESRD_HOME/<inst>/workspaces/<name>/` (self-contained scratch) |
| 1 | `folders[0].path` (the repo) | `folders[0].path` |
| >1 | `folders[0].path`; agent gets `--add-dir <each>` for `folders[1..N]` | `$ESRD_HOME/<inst>/workspaces/<name>/`; agent gets `--add-dir <each>` for all folders |

For multi-folder workspaces the agent (cc) receives every
non-cwd folder via its native `--add-dir` mechanism so the LLM can
read across them. A `primary_folder: <i>` field can be added in v2
if operators want explicit cwd selection.

For repo-bound workspaces the repo path is always `folders[0]` —
the `.esr/workspace.json` file is inside it. Adding additional
folders puts them in `folders[1..N]`.

### settings dot-namespace convention

```
<scope>.<key>: <value>
```

Reserved scopes:

- `cc.*` — overrides for `agents.yaml` `cc` entry. Example:
  `cc.model`, `cc.allowed_tools`, `cc.system_prompt_extra`.
- `<future-agent>.*` — per-agent namespace as new agent_defs land.
- `logging.*` — per-workspace logger level / format overrides.

`settings` keys are flat dot-strings (matching VS Code) rather than
nested objects. This makes JSON Schema validation more direct and
matches operator muscle memory from `.vscode/settings.json`.

### `<dir>/.esr/topology.yaml` (project-shareable metadata)

Optional companion file living **inside** the user's git repo
(not in `$ESRD_HOME`). Holds metadata that should travel with the
project — committed to git, shared with team members on clone.

```yaml
schema_version: 1

description: >
  ESR — agent runtime that bridges Feishu chats to Claude Code
  sessions. Elixir (Phoenix) supervisor tree + Python adapter
  sidecars.

role: dev

metadata:
  language: elixir
  domain: agent-orchestration
  pipeline_position: head

neighbors:
  - cc-openclaw
  - cc-mcp-tools
```

Schema:

| Field | Type | Purpose |
|---|---|---|
| `schema_version` | integer | migration anchor |
| `description` | string | free-form, exposed to LLM via `describe_topology` |
| `role` | string | semantic label (dev / diagnostic / ...) — UI hint |
| `metadata` | free-form map | exposed verbatim to LLM (security-filtered allowlist still applies) |
| `neighbors` | array of strings | other workspaces this project relates to (LLM hint, not ESR routing) |

### Split rule (workspace.json vs topology.yaml)

| Data kind | Lives in | Rationale |
|---|---|---|
| Operational state (sessions, transient files) | `$ESRD_HOME/.../<name>/sessions/` | ESR runtime ledger; doesn't pollute user repo |
| Workspace identity (name, owner, folders, agent) | `workspace.json` | required for ESR routing/auth; cannot depend on external repo presence |
| Runtime settings (cc.model, env, chats) | `workspace.json` | operational config; ESR consumes |
| Project-shareable metadata (description, neighbors) | `<dir>/.esr/topology.yaml` | travels with code; team members benefit on clone |
| Project agent overrides | `<dir>/.esr/agents.yaml` (v2+) | same logic as topology |

ESR's routing and auth never depend on a folder being present —
the operator can `rm -rf /Users/h2oslabs/Workspace/esr` and ESR can
still cleanly tear down the workspace because workspace.json
contains everything needed for cleanup.

### Metamodel relationship

`workspace` remains an application-level **Resource** (per
`docs/notes/concepts.md` tetrad: Scope / Entity / Resource /
Interface). Its metamodel role does not change — workspaces are
finite-countable, used by Entities (cc agent, session etc.). What
changes:

- **Data form**: yaml row → directory + workspace.json
- **Storage**: single yaml file → per-workspace directories
- **CLI surface**: handful of slashes for full lifecycle (see
  below)

A session continues to be a **Scope** spawned against a workspace
(Resource). The Resource → Scope relationship is unchanged.

`docs/notes/concepts.md` requires no edits as part of this
redesign; it correctly describes workspace's role at the metamodel
level without committing to a specific data form.

## CLI surface

All workspace mutations go through slash commands. Hand-editing
`workspace.json` is allowed for emergency recovery but not the
expected workflow; the CLI is the canonical interface.

| Slash | Status | Behavior |
|---|---|---|
| `/new-workspace <name> [folder=<path>] [owner=<user>] [transient=true]` | refactor | Creates a new workspace. **Storage location depends on `folder=`**: if `folder=<path>` is supplied and `<path>` is a git repo, creates `<path>/.esr/workspace.json` (repo-bound); auto-registers the path in `registered_repos.yaml`. Without `folder=`, creates `$ESRD_HOME/<inst>/workspaces/<name>/workspace.json` (ESR-bound). Generates a fresh UUID for `id`. Auto-binds the current chat. `transient=true` rejected for repo-bound workspaces. |
| `/workspace list` | **new** | Reads the in-memory registry (merged from ESR-bound walk + registered_repos.yaml). Output: name, owner, folder count, chat count, location (`repo:<path>` or `esr:<dir>`). |
| `/workspace info <name>` | refactor | Reads `workspace.json` + overlays `<folders[0]>/.esr/topology.yaml` if present. Full unfiltered view. |
| `/workspace describe <name>` | refactor | Same as `info` but with security-filtered allowlist (matches `Esr.Resource.Workspace.Describe` from PR-222). LLM-safe. |
| `/workspace sessions <name>` | refactor | Lists sessions whose `workspace_id` matches this workspace's `id`. (Sessions are stored under `$ESRD_HOME/<inst>/sessions/`, indexed by their workspace UUID, not under each workspace's directory.) |
| `/workspace edit <name> --set <key>=<value>` | **new** | Updates a single scalar field of workspace.json. `--set settings.cc.model=...` for nested. **Not used for list-valued fields** (`folders[]`, `chats[]`); see dedicated slashes below. |
| `/workspace add-folder <name> --path=<path> [--alias=<name>]` | **new** | Appends `{path, name?}` to `folders[]`. Validates path exists + is a git repo. |
| `/workspace remove-folder <name> --path=<path>` | **new** | Removes the folders entry matching path. Errors if the workspace has live sessions whose cwd resolves there. For repo-bound workspaces, removing `folders[0]` (the repo itself) is rejected; use `/workspace remove` to delete the workspace entirely. |
| `/workspace bind-chat <name> <chat_id> [--app=<app_id>] [--kind=<dm\|group>]` | **new** | Appends to `chats[]`. `--app` defaults to the inbound envelope's app_id when invoked from a chat; required when invoked via escript / admin queue. `--kind` defaults to `dm`. |
| `/workspace unbind-chat <name> <chat_id> [--app=<app_id>]` | **new** | Removes the matching `chats[]` entry. Without `--app` removes all chat_id matches across apps; with `--app` scopes to a single (chat_id, app_id) pair. |
| `/workspace remove <name> [--force]` | **new** | Removes a workspace from the registry. **For ESR-bound**: deletes the directory + sessions. **For repo-bound**: deletes `<repo>/.esr/workspace.json` + `<repo>/.esr/topology.yaml` + un-registers from `registered_repos.yaml`; the `<repo>` itself is **never touched**. Without `--force` errors if any session is live. |
| `/workspace rename <name> <new_name>` | **new** | Updates `workspace.json.name` + the in-memory name↔id index. Caps + sessions reference by UUID and do not change. **Cheap operation**. (For ESR-bound also `mv`'s the directory; for repo-bound `<repo>/.esr/` directory keeps the same path because it lives in the repo.) |
| `/workspace use <name>` | **new** | Sets the **current chat's default workspace**. Stored at chat-level (next to chat-current-slot index, by UUID). Subsequent `/new-session name=<sid>` calls in this chat (no explicit `<ws>` arg) default to `<name>`. Per-chat preference; does not affect other chats. |
| `/workspace import-repo <path> [--name=<name>]` | **new** | Adds `<path>` to `registered_repos.yaml` and loads `<path>/.esr/workspace.json` into the registry. Errors if `<path>/.esr/workspace.json` does not exist. `--name` is optional override (unused except for renaming on import). |
| `/workspace forget-repo <path>` | **new** | Removes `<path>` from `registered_repos.yaml`. The repo's `.esr/workspace.json` is not touched. The workspace disappears from `/workspace list` until re-imported or auto-detected. |

`/workspace list` output format (matches escript YAML envelope per
PR-211 conventions):

```
ok: true
data:
  workspaces:
    - name: esr-dev
      id: 7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71
      owner: linyilun
      folders: 2
      chats: 1
      location: repo:/Users/h2oslabs/Workspace/esr
      transient: false
    - name: default
      id: 11111111-2222-4333-8444-555555555555
      owner: linyilun
      folders: 0
      chats: 0
      location: esr:/Users/h2oslabs/.esrd-dev/default/workspaces/default
      transient: false
```

All commands write to the workspace directory atomically (write to
`workspace.json.tmp`, fsync, rename). `FileSystem` watcher on the
workspaces directory picks up changes and refreshes the runtime
view (similar to the slash-routes hot-reload in PR-21κ).

## Session integration

### Workspace resolution order for `/new-session`

`/new-session [<ws_name>] name=<sid>` resolves the workspace in
this order (first match wins):

1. **Explicit argument**: `/new-session esr-dev name=<sid>` — uses
   `esr-dev` workspace.
2. **Chat default**: if the inbound chat has had `/workspace use
   <ws>` set, use that workspace.
3. **Global default**: fall back to the `default` workspace.

The `default` workspace is auto-created by `esr daemon init` (and
by the migrator if no workspace named `default` was present in old
yaml). It's a self-contained workspace with empty `folders[]`,
empty `chats[]`, owner = the bootstrap admin user. Operators can
configure it via `/workspace edit default --set ...` or remove
folders / use a different workspace as their preferred default via
`/workspace use <other>`.

### Spawn sequence

Once workspace is resolved, `/new-session` runs:

1. Read `$ESRD_HOME/<inst>/workspaces/<ws_name>/workspace.json`. Error if missing or `name` ≠ basename.
2. Resolve cwd per the folders rule above.
3. Build env: merge `agents.yaml.cc.env` + `workspace.json.env` (workspace wins on conflict).
4. Build settings: merge `agents.yaml.cc.*` defaults + `workspace.json.settings.cc.*` (workspace wins).
5. Build agent invocation: cc's `start_cmd` + `--add-dir <folder>` for each `folders[i]` (skip first if cwd already points there).
6. Spawn session under `Scope.Supervisor`; record session state at `$ESRD_HOME/.../workspaces/<ws_name>/sessions/<sid>/`. **The session's workspace binding is recorded at this point and is immutable** (per Non-goals — no `/session switch-workspace`).
7. If `transient: true`, attach a watch so the workspace directory is removed when its last session ends.

`/end-session <sid>` runs the inverse — terminate scope, archive
session state, optionally trigger transient cleanup.

## describe_topology integration

`describe_topology(workspace_name)` MCP tool merges three sources
in this order, then applies the security-filtered allowlist
(unchanged from PR-222):

1. **workspace.json identity** — name, owner, role hint
2. **`<folders[0]>/.esr/topology.yaml`** — description, metadata,
   neighbors (if folders[0] exists and the file is present)
3. **chats** — workspace.json.chats[] mapped to LLM-readable form

**Multi-folder behavior**: `folders[0]` is the **canonical primary
folder** for project metadata. `describe_topology` reads only
`folders[0]/.esr/topology.yaml`. If operators want different
metadata per folder, they should structure their workspace so the
canonical metadata lives in the first-listed folder.

Why folders[0] specifically (not multi-folder merge):

- Merging across folders introduces last-write-wins ambiguity that
  operators must reason about. v1 picks "first" deterministically
  to avoid surprise.
- Multi-folder merge can land as a v2 enhancement if real demand
  surfaces (`primary_folder: <i>` field + per-folder merge order).

This is intentionally asymmetric with `chats[]` (which exposes
all entries to LLM): `chats` are operator-routing data with
no merge semantics ("here are the chats that route here"), while
topology files are layered metadata where conflicts have to be
resolved.

The security boundary stays at `Esr.Resource.Workspace.Describe`
(introduced PR-222). The allowlist is unchanged: `name`, `role`,
`chats` (sub-allowlisted), `neighbors_declared`, `metadata`. Owner
/ env / settings stay excluded.

## Capabilities + UUID translation

This section spells out the cap storage / translation that the
"Workspace identity: UUID" section in Design references.

### Storage form (capabilities.yaml)

Caps are persisted by UUID. operators never read this file
directly:

```yaml
schema_version: 1

principals:
  - id: linyilun
    capabilities:
      - "session:7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71/create"
      - "session:7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71/end"
      - "workspace:7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71/manage"
      - "user.manage"          # global perms have no UUID; unchanged
      - "adapter.manage"       # same
```

Resource-scoped caps (`<resource>:<scope>/<perm>`) where the scope
is a workspace use the workspace's UUID. Non-workspace-scoped caps
(`user.manage`, `adapter.manage`, `runtime.deadletter`, etc.) are
unchanged from today.

### Read path (CLI output translation)

When `/cap list` or `/cap show <principal>` runs, the rendering
layer translates UUIDs back to names:

```bash
$ runtime/esr exec /cap list
ok: true
data:
  - principal: linyilun
    capabilities:
      - "session:esr-dev/create"          # 7b9f3c1a-... → "esr-dev"
      - "session:esr-dev/end"
      - "workspace:esr-dev/manage"
      - "user.manage"
      - "adapter.manage"
```

If a UUID in the persisted form does not match any registered
workspace (e.g. workspace was removed but caps lingered), the
rendered string is `<resource>:<UNKNOWN-7b9f3c1a-...>/<perm>` so
operators can see + clean it up via `/cap revoke`.

### Write path (CLI input translation)

When `/cap grant <principal> session:<name>/create` runs:

1. Resolve `<name>` → UUID via the in-memory registry. Error if
   `<name>` doesn't exist.
2. Persist as `session:<uuid>/create`.

`/cap revoke` similarly translates name → UUID before matching.

### Cap matching during runtime checks

When ESR checks "does principal P have cap `session:<uuid>/create`",
the matching happens entirely in UUID-land — no name involved. The
`Esr.Resource.Capability.Grants` matcher is unchanged from today
except its inputs are UUID strings instead of name strings.

### Why this works for free rename

After `/workspace rename esr-dev esr-prod`:

1. `workspace.json.name` flips from `"esr-dev"` to `"esr-prod"`.
2. The in-memory name↔id index is rebuilt (`esr-dev` row removed,
   `esr-prod` row added; `id` is the same UUID).
3. capabilities.yaml is **not touched**. The persisted UUIDs
   continue to reference the same workspace — its name just
   happens to display differently now.
4. Subsequent `/cap list` shows `session:esr-prod/create` (because
   the renderer translates UUID → "esr-prod" via the new index).

No file rewrites. No atomic transactions. No lock coordination.
The whole rename is two writes (workspace.json + index) and the
cap layer doesn't notice.

### Other UUID-using subsystems

- **session→workspace binding**: stored at session creation. Format
  is `session.workspace_id = "<uuid>"`. Sessions never carry the
  workspace name.
- **chat-current-slot's "default workspace"**: stored by UUID per
  (chat_id, app_id). `/workspace use <name>` resolves name → UUID
  before persisting.
- **Slash-command admin queue payloads**: arguments use the operator-
  facing name. The name → UUID resolution happens at the slash
  dispatch layer, before the command module sees the args.

## Removal of old `workspaces.yaml`

There is **no migrator**. The old single-file `workspaces.yaml`
format is incompatible with the new layout, and translating its
contents is not worth the engineering / surface-area cost.

On first esrd boot under the new code:

1. Detect `$ESRD_HOME/<inst>/workspaces.yaml` (legacy file).
2. **Delete it** (`rm`). Log `WARN` with the deleted path so
   operator has audit trail.
3. Create `$ESRD_HOME/<inst>/workspaces/default/workspace.json`
   (the system `default` workspace, ESR-bound, owner = bootstrap
   admin).
4. Operator must re-create their previous workspaces:
   - For each project repo: `cd <repo> && /workspace import-repo .`
     (or use `/new-workspace <name> folder=<path>` from a chat)
   - For each chat-binding: `/workspace bind-chat <name> <chat_id>`
   - For each non-trivial setting (env, settings.cc.*): re-set
     via `/workspace edit`

This is more work for the operator than a migrator would have
been, but:

- The current operator base is small (the user's two instances:
  `~/.esrd-dev` and `~/.esrd`).
- Each instance has a handful of workspaces (the user's `dev` env
  has 2: `default` and `esr-dev`; same scale on prod).
- A migrator would need separate code paths for every legacy yaml
  shape (pre-PR-22 with `root:`, pre-PR-21θ with `cwd:`, current
  shape) — easily 200+ LOC of code that runs once.
- The "delete + re-create" approach forces operators through the
  new CLI, which is exactly the workflow we want to validate.

Before merging the implementation PR, the operator must take note
of any non-default settings on existing workspaces (run
`runtime/esr exec /workspace info <name>` for each, copy values
into a notepad). Post-merge, recreate those settings via the new
CLI.

The implementation PR adds a one-time `WARN`-level log line at
boot listing the deleted yaml's path so an operator who somehow
missed the heads-up has a paper trail.

## Out of scope

- Auto-discovery of workspace from cwd (e.g. `/new-session` with
  no name resolving to "the workspace whose folders contain $PWD").
  YAGNI for now; explicit name avoids ambiguity. (Note: a different
  kind of auto-detect is in scope — `/new-session ... cwd=<path>`
  silently registers `<path>/.esr/workspace.json` if present. That's
  registration, not workspace identity inference.)
- Multi-root cwd selection (always cwd = workspace's `folders[0]`
  for repo-bound, ESRD_HOME dir for ESR-bound multi-folder). Add
  `primary_folder` field in v2 if needed.
- Project-level `<dir>/.esr/agents.yaml` overrides. v2+.
- Cross-machine syncing of registered_repos.yaml. Each machine
  registers repos independently.
- Filesystem watcher / hot-reload of workspace.json. **All workspace
  mutations go through CLI**; the CLI invalidates the in-memory
  registry inline. Hand-editing workspace.json is allowed for
  emergency recovery, but operators must run `runtime/esr daemon
  restart` (or `/workspace reload <name>` in v2) to pick up the
  change.

## Risks and open questions

1. **First-boot data loss.** The new code unconditionally deletes
   `~/.esrd/<inst>/workspaces.yaml` on first boot. Operators must
   note their workspace settings (run `/workspace info <name>` for
   each, or `cat workspaces.yaml`) **before** upgrading. The PR
   description must call this out prominently. Sample operator
   pre-upgrade procedure is in the implementation plan.
2. **`transient: true` + concurrent `/new-session` race.** When
   the last session under a transient workspace ends, the cleanup
   hook must coordinate with any concurrent `/new-session` arriving
   for that workspace. Use the `Esr.Resource.Workspace.Registry`
   GenServer's serialised state machine — cleanup and registration
   are both `handle_call`s, so they're naturally serialised on the
   same process.
3. **`/workspace remove` of a repo-bound workspace.** Spec says we
   delete `<repo>/.esr/workspace.json` + `topology.yaml` and
   un-register from `registered_repos.yaml`, but never touch the
   `<repo>` itself. Edge case: what if `<repo>/.esr/` was already
   gitignored or had other ESR-related files (future v2: agents.yaml
   override)? The implementation should `rm <repo>/.esr/workspace.json`
   and `rm <repo>/.esr/topology.yaml` specifically, not `rm -rf
   <repo>/.esr/`. Verify with implementation tests.
4. **Shared-FS multi-host is unsupported.** `$ESRD_HOME` is
   per-host. Symlinking / NFS-mounting / Dropbox-syncing
   `~/.esrd-dev/` between hosts is undefined behavior (atomic-rename
   + fsync semantics differ across filesystems; process-name
   registries assume one BEAM owns the directory). This redesign
   does not change that posture. Repo-bound workspace.json + the
   project's `.esr/topology.yaml` ARE intentionally repo-shared
   and version-control-tracked, but `registered_repos.yaml` and
   the in-memory registry remain per-host.
5. **UUID collision.** UUID v4 has a ~5×10⁻³⁶ collision probability
   per pair. With our scale (single-digit workspaces per machine)
   collisions are statistically impossible, but the registry merge
   step still validates: if two `workspace.json` files load with
   the same UUID, esrd boot fails loudly with both file paths in
   the error. Operators resolve by editing one file's `id`.
6. **Repo-bound workspace.json on a remote (non-local) repo.** If
   operator opens an ESR-managed repo over a shared filesystem
   (sshfs, etc.), file-locking semantics may not survive. v1
   recommends only local repos; remote scenarios fall under
   risk #4 (shared-FS).

## Docs sweep

The implementation plan's checklist must include updating the
following docs to reflect the new shape:

- `README.md` (EN + 中文 zh) — workspace section
- `docs/dev-guide.md` — getting-started workspace creation step
- `docs/cookbook.md` — recipes mentioning workspace
- `docs/notes/concepts.md` — **no change needed** (metamodel layer
  unaffected; documented above)
- `docs/notes/actor-topology-routing.md` — workspace routing notes
- `docs/futures/todo.md` — close the workspace-redesign entry,
  reopen "init redesign" with updated dependencies
- Any `docs/superpowers/specs/*` files referencing workspace.yaml
  format
- `docs/architecture.md` — workspace section if present

## References

- Brainstorm conversation 2026-05-06 (Feishu transcript)
- VS Code workspace schema: `https://code.visualstudio.com/docs/editor/workspaces`
- PR-222 (`Esr.Resource.Workspace.Describe` security boundary —
  preserved verbatim by this redesign)
- PR-22 (removed `workspace.root` — partial precursor)
- PR-21θ (derived cwd from `<root>/.worktrees/<branch>` — also a
  precursor)
- `docs/notes/concepts.md` (metamodel tetrad)
