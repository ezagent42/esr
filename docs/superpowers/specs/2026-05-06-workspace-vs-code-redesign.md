# Workspace VS-Code-style redesign

**Status**: design (2026-05-06)
**Brainstorm**: in-conversation 2026-05-06
**Estimated implementation**: ~800-1200 LOC across 1 main PR + docs sweep
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
- Per-workspace cap scoping (`session:<ws>/create` style strings).
  V1 flattens to `session:create`; per-workspace policy can return
  later as a follow-up if real demand surfaces.
- Auto-detecting workspace from cwd. Workspace must be referenced
  by name. (`/new-session <ws_name>` etc.)
- Backwards compatibility with the old `workspaces.yaml` format
  beyond a one-shot migrator (see Migration).

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
  "$schema": "https://esr.local/schema/workspace.v1.json",
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
| `name` | required | string | identity; must equal directory basename |
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
- `routing.*` — reserved for future routing-policy overrides.

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
| `/new-workspace <name> [folder=<path>] [owner=<user>]` | refactor | Creates `<workspaces>/<name>/workspace.json` with the supplied folder (if any) added to `folders[]`. Auto-binds the current chat. |
| `/workspace list` | **new** | Walks `<workspaces>/`, reads each `workspace.json`, sorts by name. Output: name, owner, folder count, chat count. |
| `/workspace info <name>` | refactor | Reads `workspace.json` + overlays `<folders[0]>/.esr/topology.yaml` if present. Full unfiltered view. |
| `/workspace describe <name>` | refactor | Same as `info` but with security-filtered allowlist (matches `Esr.Resource.Workspace.Describe` from PR-222). LLM-safe. |
| `/workspace sessions <name>` | refactor | Reads `<workspaces>/<name>/sessions/` directory entries. |
| `/workspace edit <name> --set <key>=<value>` | **new** | Updates a workspace.json field. `--set settings.cc.model=...` for nested. |
| `/workspace add-folder <name> --path=<path> [--alias=<name>]` | **new** | Appends `{path, name?}` to `folders[]`. Validates path exists + is a git repo. |
| `/workspace remove-folder <name> --path=<path>` | **new** | Removes the folders entry matching path. Errors if the workspace has live sessions whose cwd resolves there. |
| `/workspace remove <name> [--force]` | **new** | Deletes the entire workspace directory + sessions. Without `--force` errors if any session is live. |
| `/workspace rename <old> <new>` | **new** | Atomic: rename directory + update `workspace.json.name` + update any references (sessions/index files). |

All commands write to the workspace directory atomically (write to
`workspace.json.tmp`, fsync, rename). `FileSystem` watcher on the
workspaces directory picks up changes and refreshes the runtime
view (similar to the slash-routes hot-reload in PR-21κ).

## Session integration

When `/new-session <ws_name> name=<sid>` runs:

1. Resolve workspace: `$ESRD_HOME/<inst>/workspaces/<ws_name>/workspace.json`. Error if missing.
2. Resolve cwd per the folders rule above.
3. Build env: merge `agents.yaml.cc.env` + `workspace.json.env` (workspace wins on conflict).
4. Build settings: merge `agents.yaml.cc.*` defaults + `workspace.json.settings.cc.*` (workspace wins).
5. Build agent invocation: cc's `start_cmd` + `--add-dir <folder>` for each `folders[i]` (skip first if cwd already points there).
6. Spawn session under `Scope.Supervisor`; record session state at `$ESRD_HOME/.../workspaces/<ws_name>/sessions/<sid>/`.
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

For multi-folder workspaces v1 reads only `folders[0]/.esr/topology.yaml`.
Multi-folder merge can return as a v2 enhancement if real demand
appears.

The security boundary stays at `Esr.Resource.Workspace.Describe`
(introduced PR-222). The allowlist is unchanged: `name`, `role`,
`chats` (sub-allowlisted), `neighbors_declared`, `metadata`. Owner
/ env / settings stay excluded.

## Migration

Existing operators have `~/.esrd/<inst>/workspaces.yaml` with N
entries. The redesign is not backwards-compatible with the old
yaml format. Migration is one-shot, automatic on first esrd start
under the new code:

1. On boot, if `<inst>/workspaces.yaml` exists AND
   `<inst>/workspaces/` directory does not, run the migrator.
2. For each entry in workspaces.yaml: create
   `<inst>/workspaces/<name>/workspace.json` with translated
   fields:
   - `name` → unchanged
   - `owner` → unchanged
   - `start_cmd` → drop (lives on `agents.yaml.cc.start_cmd` now)
   - `role` → drop (semantic label moves to topology.yaml; not
     auto-populated by migrator since target file lives in user
     repo)
   - `chats` → unchanged (with `kind` retained)
   - `env` → unchanged
   - `metadata` / `neighbors` → drop (these belong in
     `<dir>/.esr/topology.yaml`; emit a warning so operator
     manually copies if they want them preserved)
   - `root` → translates to `folders: [{path: <root>}]` if
     present (PR-22 had already removed `workspace.root`, so this
     branch only matters for very old yaml).
3. After successful translation, archive `workspaces.yaml` →
   `workspaces.yaml.bak.<unix-ts>`.
4. Log migration summary at `INFO`.

Migrator is run unconditionally (no operator opt-in needed). It is
idempotent: if `workspaces/` already has a directory matching a
yaml entry, that entry is skipped.

The migrator is delete-able once all known operators have run it
once. We can target removal in a follow-up PR ~3 months after this
redesign lands.

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
   referencing the old name, possibly chat-current-slot index. v1
   should validate no live sessions exist before rename, then do
   the directory + json update atomically; defer cap/index
   migration to operator (CLI prints commands to run).
4. **`<dir>/.esr/topology.yaml` discovery on shared repos.** When
   a teammate clones the repo, ESR sees `.esr/topology.yaml` but
   has no associated workspace.json (different ESRD_HOME). v1
   tolerates this — workspace.json is per-machine, topology.yaml is
   per-repo. The teammate creates their own `/new-workspace` and
   the topology.yaml gets picked up automatically.

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
