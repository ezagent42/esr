# Workspace VS-Code-style redesign

**Status**: design (2026-05-06)
**Brainstorm**: in-conversation 2026-05-06
**Estimated implementation**: ~1100-1500 LOC across 1 main PR + docs sweep (revs: + bind-chat/unbind-chat + migrator subcommand from review; + `default` workspace auto-create + `/workspace use` chat-default + immutable session→workspace binding from rev-2 user feedback)
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
- **Capability-string grammar changes.** The current
  `session:<ws_name>/create` form is preserved verbatim. Existing
  `capabilities.yaml` grants continue to work without rewrite. Per-
  workspace cap scoping stays a v1 feature.
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

### Directory layout

```
$ESRD_HOME/<instance>/workspaces/
  <name>/                         # workspace = a directory under $ESRD_HOME
    workspace.json                # primary config (this spec's main artefact)
    sessions/                     # ESR-managed transient state
      <sid>/
        ... (session-scoped files; format defined elsewhere)
    caps.yaml                     # optional: per-workspace cap overrides (v2+)
```

Workspace identity is the directory name. There is no central
registry file; `workspace list` walks the `workspaces/` directory
and reads each `workspace.json`. The directory IS the registry.

### workspace.json schema (v1)

```json
{
  "$schema": "file:///path/to/runtime/priv/schemas/workspace.v1.json",
  "schema_version": 1,

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
| `name` | required | string | identity; must equal directory basename. Loader rejects the workspace if `workspace.json.name != basename(parent_dir)`. The only legal way to change `name` is `/workspace rename`; manual `mv` of the directory will produce a load-time error with operator instructions to either `mv` back or run `/workspace rename`. |
| `owner` | required | string | esr-username; must exist in `users.yaml` |
| `folders` | optional | array of `{path, name?}` | external repo bindings; cwd resolution per below |
| `agent` | optional (default `"cc"`) | string | which `agents.yaml` entry to use |
| `settings` | optional | flat dot-namespaced map | per-workspace agent/runtime overrides |
| `env` | optional | string→string map | env vars threaded into spawned sessions |
| `chats` | optional | array of `{chat_id, app_id, kind?}` | which chats default-route to this workspace |
| `transient` | optional (default `false`) | bool | when `true`, last-session-end auto-removes the whole directory |

### Cwd resolution (folders → session.cwd)

| `folders.length` | Resolved cwd |
|---|---|
| 0 | `$ESRD_HOME/<inst>/workspaces/<name>/` (self-contained scratch) |
| 1 | `folders[0].path` (single-repo) |
| >1 | `$ESRD_HOME/<inst>/workspaces/<name>/`; agent gets `--add-dir <each>` per folder |

For multi-folder workspaces the agent (cc) receives every folder
via its native `--add-dir` mechanism so the LLM can read across
them. Cwd staying inside ESRD_HOME avoids picking an arbitrary
"primary" repo. A `primary_folder: <i>` field can be added in v2 if
operators want explicit cwd selection.

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
| `/new-workspace <name> [folder=<path>] [owner=<user>] [transient=true]` | refactor | Creates `<workspaces>/<name>/workspace.json` with the supplied folder (if any) added to `folders[]`. Auto-binds the current chat. `transient=true` flips the same-named field at creation time. |
| `/workspace list` | **new** | Walks `<workspaces>/`, reads each `workspace.json`, sorts by name. Output: name, owner, folder count, chat count. |
| `/workspace info <name>` | refactor | Reads `workspace.json` + overlays `<folders[0]>/.esr/topology.yaml` if present. Full unfiltered view. |
| `/workspace describe <name>` | refactor | Same as `info` but with security-filtered allowlist (matches `Esr.Resource.Workspace.Describe` from PR-222). LLM-safe. |
| `/workspace sessions <name>` | refactor | Reads `<workspaces>/<name>/sessions/` directory entries. |
| `/workspace edit <name> --set <key>=<value>` | **new** | Updates a single scalar field of workspace.json. `--set settings.cc.model=...` for nested. **Not used for list-valued fields** (`folders[]`, `chats[]`); see dedicated slashes below. |
| `/workspace add-folder <name> --path=<path> [--alias=<name>]` | **new** | Appends `{path, name?}` to `folders[]`. Validates path exists + is a git repo. |
| `/workspace remove-folder <name> --path=<path>` | **new** | Removes the folders entry matching path. Errors if the workspace has live sessions whose cwd resolves there. |
| `/workspace bind-chat <name> <chat_id> [--app=<app_id>] [--kind=<dm\|group>]` | **new** | Appends to `chats[]`. `--app` defaults to the inbound envelope's app_id when invoked from a chat; required when invoked via escript / admin queue. `--kind` defaults to `dm`. |
| `/workspace unbind-chat <name> <chat_id> [--app=<app_id>]` | **new** | Removes the matching `chats[]` entry. Without `--app` removes all chat_id matches across apps; with `--app` scopes to a single (chat_id, app_id) pair. |
| `/workspace remove <name> [--force]` | **new** | Deletes the entire workspace directory + sessions. Without `--force` errors if any session is live. |
| `/workspace rename <old> <new>` | **new** | Atomic: rename directory + update `workspace.json.name` + update any references (sessions/index files). |
| `/workspace use <name>` | **new** | Sets the **current chat's default workspace**. Stored at chat-level (next to chat-current-slot index). Subsequent `/new-session name=<sid>` calls in this chat (no explicit `<ws>` arg) default to `<name>`. Per-chat preference; does not affect other chats. |

`/workspace list` output format (matches escript YAML envelope per
PR-211 conventions):

```
ok: true
data:
  workspaces:
    - name: esr-dev
      owner: linyilun
      folders: 2
      chats: 1
      transient: false
    - name: scratch
      owner: linyilun
      folders: 0
      chats: 0
      transient: true
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

## Migration

Existing operators have `~/.esrd/<inst>/workspaces.yaml` with N
entries. The redesign is not backwards-compatible with the old
yaml format.

Migration is exposed as a **CLI subcommand**, not a boot-shim:

```
runtime/esr daemon migrate-workspaces [--instance=<name>] [--dry-run]
```

Properties:

- **Idempotent per-entry**, not per-run. The migrator iterates yaml
  rows; for each row it skips when `workspaces/<row.name>/workspace.json`
  already exists, otherwise translates and writes. This handles the
  partial-crash case (some entries migrated, then crash) by safely
  resuming on the next invocation.
- **Always runnable.** Operators can re-run after a manual yaml
  edit. No "delete migrator after N months" planned obsolescence;
  the subcommand stays.
- **Dry-run mode** prints the planned writes without touching the
  filesystem. Useful for ops review.
- **Auto-invoked once at boot** for backwards-compatibility with
  current operator workflow (esrd starts, migration just happens).
  Boot-time invocation is exactly the same code path; if all rows
  are already translated, it's a no-op log line.

**Per-entry translation:**

| Old yaml field | New location | Notes |
|---|---|---|
| `name` | `workspace.json.name` (= directory basename) | unchanged |
| `owner` | `workspace.json.owner` | unchanged |
| `start_cmd` | dropped | lives on `agents.yaml.cc.start_cmd` now |
| `role` | dropped — see MIGRATION_NOTES.md | semantic label moves to `<dir>/.esr/topology.yaml` if operator wants it |
| `chats` | `workspace.json.chats` | unchanged (`kind` retained) |
| `env` | `workspace.json.env` | unchanged |
| `metadata` | dropped — written verbatim to MIGRATION_NOTES.md | belongs in `<dir>/.esr/topology.yaml`; operator must manually relocate to keep `describe_topology` populated |
| `neighbors` | dropped — written verbatim to MIGRATION_NOTES.md | same reasoning |
| `root` | `workspace.json.folders: [{path: <root>}]` | only present in pre-PR-22 yaml |

**Visibility of dropped fields** (per reviewer I3):

For each migrated workspace, the migrator writes
`<workspaces>/<name>/MIGRATION_NOTES.md` containing:

```markdown
# Migration notes for workspace `<name>`

Migrated <unix-ts> from `~/.esrd/<inst>/workspaces.yaml`.

## Fields dropped during migration (operator action recommended)

The following fields were not preserved in `workspace.json` because
they belong in `<dir>/.esr/topology.yaml` (per the
2026-05-06-workspace-vs-code-redesign spec). To keep these visible
to LLM via `describe_topology`, copy them by hand into
`<your_repo>/.esr/topology.yaml` and commit.

- `metadata`: <verbatim original yaml>
- `neighbors`: <verbatim original yaml>
- `role`: <verbatim original value>
```

This file is checked by `/workspace info <name>` which surfaces a
"⚠️ migration-pending" indicator if `MIGRATION_NOTES.md` exists.
Operators delete the file (or the migrator self-deletes when
`<dir>/.esr/topology.yaml` exists) when relocation is done.

Per-workspace migration also emits one `WARN` log line per
affected workspace (not summarised at INFO):

```
warning: workspace 'esr-dev' migrated; metadata/neighbors/role
  fields dropped — see ~/.esrd-dev/default/workspaces/esr-dev/MIGRATION_NOTES.md
```

**After-migration archival:**

After migration completes (all rows accounted for), the migrator
archives the original yaml:

```
~/.esrd/<inst>/workspaces.yaml → workspaces.yaml.bak.<unix-ts>
```

If migration is interrupted (crash mid-run), the original is
preserved unchanged and the next run resumes from the per-entry
check.

## Out of scope

- Per-workspace cap scoping. Caps flatten to `session:create` etc.
  Per-workspace policy can return as `caps.yaml` per-workspace
  override file in v2.
- Auto-discovery of workspace from cwd (e.g. `/new-session` with
  no name resolving to "the workspace whose folders contain $PWD").
  YAGNI for now; explicit name avoids ambiguity.
- Multi-root cwd selection (always cwd = workspace dir or
  folders[0]). Add `primary_folder` field in v2 if needed.
- Rich `caps.yaml` per-workspace overrides. v1 leaves caps strictly
  flat at `~/.esrd/<inst>/capabilities.yaml`.
- Project-level `<dir>/.esr/agents.yaml` overrides. v2+.

## Risks and open questions

1. **migrator robustness across very old yaml versions.** If
   operators have workspaces.yaml from before PR-22 (`root`
   present) or PR-21θ (`cwd` present), the migrator must handle
   them gracefully. Implementation should grep all known
   workspaces.yaml shapes ever shipped and translate accordingly.
2. **transient workspace cleanup race.** When `transient: true` and
   the last session ends, the cleanup hook needs to coordinate
   with any concurrent `/new-session` arriving for that workspace.
   Use a registry-level lock during cleanup.
3. **`workspace rename` atomicity.** Renaming touches: directory,
   workspace.json.name, possibly capabilities.yaml grants
   referencing the old name (because cap strings have form
   `session:<ws>/create`), possibly chat-current-slot index. v1
   should validate no live sessions exist before rename, then do
   the directory + json update atomically; defer cap/index
   migration to operator (CLI prints commands to run, including
   the literal `cap revoke / cap grant` lines for the renamed
   workspace).
4. **`<dir>/.esr/topology.yaml` discovery on shared repos.** When
   a teammate clones the repo, ESR sees `.esr/topology.yaml` but
   has no associated workspace.json (different ESRD_HOME). v1
   tolerates this — workspace.json is per-machine, topology.yaml is
   per-repo. The teammate creates their own `/new-workspace` and
   the topology.yaml gets picked up automatically.
5. **Shared-FS multi-host is unsupported.** `$ESRD_HOME` is
   per-host. Symlinking / NFS-mounting / Dropbox-syncing
   `~/.esrd-dev/` between hosts has always been undefined behavior
   (atomic-rename + fsync semantics differ across filesystems;
   process-name registries assume one BEAM owns the directory).
   This redesign does not change that posture. Operators sharing
   one repo across multiple hosts MUST run separate ESRD_HOMEs per
   host. `<dir>/.esr/topology.yaml` is the only file in this design
   that's intentionally repo-shared and version-control-tracked.
6. **Watcher implementation.** The current `Esr.Resource.Workspace.Watcher`
   watches a single yaml file. Post-redesign it must watch the
   workspaces top-level directory recursively (file events at
   depth 2: `<workspaces>/<name>/workspace.json`). FileSystem on
   macOS supports recursive watching natively; on Linux watchers
   may need explicit per-subdirectory subscription. Implementation
   plan must specify which mode is used and verify on both OSes.

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
