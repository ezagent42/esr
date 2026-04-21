# ESR Dev/Prod Isolation + Session Routing Design

Author: brainstorming session with user (linyilun)
Date: 2026-04-21
Status: draft, awaiting user review
Relates to:
- `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md` (capabilities v1, merged as commit `29d92b4`)
- `docs/futures/docker-isolation.md` (to be added — full-isolation alternative)

## 1. Goal & Scope

### 1.1 Problem statement

Today ESR runs as a single `mix phx.server` on port 4001 against `~/.esrd/default/`. A developer working on ESR has to choose between:

- Editing code and losing production-like state (their WIP breaks their own bot)
- Freezing their bot and being unable to iterate

This is the classic "eating your own dogfood while modifying the dogfood" problem. The E2E developer workflow this design enables:

1. `main` branch runs as **prod** (always-on, connected to "ESR 助手" Feishu app, serves as owner's daily-driver assistant).
2. `dev` branch runs as **dev** (always-on, connected to "ESR 开发助手" Feishu app, integration target for WIP merges).
3. WIP branches run as **ephemeral** esrd instances (spawned on demand via a Feishu command in ESR 开发助手, live at `/tmp/esrd-<branch>/`, torn down when done).
4. Multi-user: the same ESR 开发助手 bot dispatches messages to the right (user, branch) tuple so two developers can iterate in parallel.
5. Code updates reload via admin-triggered `/reload` command — no auto-reload on file change.
6. Breaking changes surfaced proactively via Conventional Commits scanning in a post-merge git hook → DM to admin.

### 1.2 In scope

Five artifact categories delivered together:

1. **Shell artifacts**: `esrd.sh` enhancements (random port + port file), `esrd-launchd.sh` (launchd-front wrapper), `esr-branch.sh` (worktree + ephemeral esrd lifecycle).
2. **launchd plists**: prod + dev user LaunchAgents with install/uninstall scripts.
3. **Python CLI**: `ESRD_HOME` helper refactor (9 hardcoded sites), `esr reload`, `esr notify`, `esr adapter feishu create-app`, client-side auto-reconnect audit + fixes.
4. **Elixir runtime**: one new handler (`Esr.Routing.SessionRouter`) + supporting supervision.
5. **Data files**: `routing.yaml`, `branches.yaml`, `last_reload.yaml` schemas; git hook templates.

### 1.3 Out of scope

- **v0.3 multi-instance CLI awareness**: CLI keeps hardcoding instance name `default`; env var switches the `ESRD_HOME` root only. Proper `--instance=<name>` flag support deferred.
- **True blue-green zero-downtime reload**: reload in this design has a 10–30s reconnection window. See §13 for the follow-up spec target (`Esr.Reload.BlueGreen`).
- **Automated Feishu app lifecycle**: Feishu has no public API for creating/deleting OpenPlatform apps — see §5.4. We ship an interactive paste-based wizard, not full automation.
- **Docker isolation**: separate future spec `docs/futures/docker-isolation.md`. Current reason to defer: cc_tmux adapter spawns host tmux, MCP bridge launch order, macOS fsnotify across bind mounts.
- **Schema-aware breaking-change detection**: we use Conventional Commits markers (`!:`, `BREAKING CHANGE:`) as the signal, not automated diff of GenServer state schemas or protocol envelopes.
- **Branch esrd idle auto-sleep**: an ephemeral esrd stays running until explicitly `/end-session`-ed. Time-based eviction is future work.

### 1.4 Non-goals

- **Replace launchd**: we embrace it; this design assumes macOS LaunchAgent as the supervisor.
- **Full-disk state encryption / secrets hardening**: `.env.local` holds Feishu app secrets in plain text; we rely on macOS file permissions and `.gitignore`.
- **Multi-machine deployment**: the design assumes single-host. Sessions cross-user, never cross-host.

### 1.5 Terminology

- **prod esrd**: long-running esrd at `ESRD_HOME=~/.esrd`, serves "ESR 助手".
- **dev esrd**: long-running esrd at `ESRD_HOME=~/.esrd-dev`, serves "ESR 开发助手" and orchestrates branch esrds.
- **ephemeral / branch esrd**: short-lived esrd at `ESRD_HOME=/tmp/esrd-<branch>/`, spawned from dev esrd's routing handler.
- **routing target**: for a given `(principal_id, active_branch)`, the esrd URL + CC session identifier that messages route to.
- **admin**: a principal that holds `cap.manage` in the relevant capabilities.yaml; can issue `/reload`, `/end-session`, etc.

### 1.6 Workspaces.Registry vs Routing — no overlap

Two subsystems share superficially similar vocabulary; they do not
overlap:

- `Esr.Workspaces.Registry` (existing, `runtime/lib/esr/workspaces/registry.ex`) stores **workspace identity**: `%Workspace{name, cwd, start_cmd, role, chats, env}` — static config declared in `workspaces.yaml`. A "workspace" is a logical business domain binding chats to app_ids.
- `Esr.Routing.SessionRouter` (new) stores **session target**: `(principal_id, active_branch) → esrd_url + cc_session_id` — dynamic runtime state declared in `routing.yaml`. It answers "where do this user's next message dispatch to?"

The Router reads Workspaces.Registry to know which chats the dev bot
serves; the Registry knows nothing about routing state.

## 2. Architecture (Approach E)

### 2.1 Responsibility boundaries

| Concern | Owner | Why |
|---|---|---|
| Process supervision (start, restart-on-crash) | launchd | macOS-native supervisor; already the pattern we want |
| Port selection (random, per-startup) | `scripts/esrd.sh` (shell) | Pre-bind selection + port-file write happens before exec |
| Worktree creation, esrd spawn for a branch | `scripts/esr-branch.sh` (shell) | Pure OS/filesystem/git — no Python/API logic |
| Feishu API (create-app wizard, notify DM) | Python CLI (`esr adapter feishu create-app`, `esr notify`) | Needs `lark_oapi` SDK + `ruamel.yaml` + interactive prompts |
| `launchctl kickstart` + breaking-change safety gate | Python CLI (`esr reload`) | Mixes shell-out with yaml/git diff logic; Python keeps it testable |
| Per-user message routing | Elixir runtime (`Esr.Routing.SessionRouter`) | Actor-system native: message dispatch decision |
| Config data files | Filesystem | yaml is the lingua franca; fs_watch drives reloads |

**ESR runtime does not know "dev" from "prod"**. It reads its `ESRD_HOME` at boot and treats the data files it finds as the complete world. The routing handler behaves identically in prod (where it probably has one user → one session mapping) and dev (where it has N users × M branches).

### 2.2 Topology

```
macOS user session
│
├── launchd (user LaunchAgent)
│   ├── com.ezagent.esrd.plist       → runs scripts/esrd-launchd.sh
│   │   └── beam.smp (prod)           → PORT=$(random), ESRD_HOME=~/.esrd
│   │       └── Phoenix Endpoint      → writes ~/.esrd/default/esrd.port
│   │           └── Feishu Adapter    → ESR 助手 app (cli_prod_xxx)
│   │
│   └── com.ezagent.esrd-dev.plist   → runs scripts/esrd-launchd.sh
│       └── beam.smp (dev)            → PORT=$(random), ESRD_HOME=~/.esrd-dev
│           └── Phoenix Endpoint      → writes ~/.esrd-dev/default/esrd.port
│               ├── Feishu Adapter    → ESR 开发助手 app (cli_dev_xxx)
│               └── Esr.Routing.SessionRouter
│                   ├── reads ~/.esrd-dev/default/routing.yaml
│                   ├── reads ~/.esrd-dev/default/branches.yaml
│                   └── shells out to scripts/esr-branch.sh for /new-session
│
├── /tmp/esrd-feature-foo/             ← ephemeral, spawned by esr-branch.sh
│   └── beam.smp (branch)             → PORT=$(random), ESRD_HOME=/tmp/esrd-feature-foo
│       └── Phoenix Endpoint          → writes /tmp/esrd-feature-foo/default/esrd.port
│           └── (inherits ESR 开发助手 creds, shares Feishu app with dev)
│
└── CC sessions (one per (user, active_branch))
    ├── ou_linyilun @ dev      → connects to ~/.esrd-dev via MCP bridge
    ├── ou_linyilun @ feature-foo → connects to /tmp/esrd-feature-foo via MCP bridge
    └── ou_yaoshengyue @ dev   → connects to ~/.esrd-dev (separate CC process from linyilun's)
```

Code checkouts:
```
~/Workspace/esr/                        # prod — stays on main
~/Workspace/esr/.claude/worktrees/dev/  # dev — stays on dev branch
~/Workspace/esr/.claude/worktrees/<branch>/  # ephemeral, one per branch in progress
```

> **Caveat on `.claude/worktrees/`**: this path is adopted as **a convention** (user preference for CC workspace discoverability), not a built-in Claude Code feature. Verify during implementation that CC's workspace-discovery walks subdirectories under `.claude/` or require explicit workspace opens per branch. If it doesn't, the convention is still useful (one canonical location for dev worktrees) but won't yield automatic CC workspace activation — the implementer should document the CC-side setup step.

## 3. Shell artifacts

### 3.1 `scripts/esrd.sh` enhancements

Existing script at `scripts/esrd.sh` (136 lines) handles start/stop/status with `--instance=<name>`. Adds:

- `--port=<N>` CLI flag. When absent: **prefer `PORT=0` + Phoenix post-bind read-back** (no race), **fall back to Python pre-bind** (small race).
- Writes the chosen/bound port to `$ESRD_HOME/$instance/esrd.port`.
- Sets `PORT=$PORT` in the environment passed to `mix phx.server`.
- The port file is the source of truth; `pid` file semantics unchanged.
- On crash/restart the port file is overwritten — clients detect drift by checking mtime.

**Port-resolution strategy** (preferred → fallback):

1. **Phoenix post-bind read-back (preferred, no race)**: `PORT=0` tells Bandit to ask the OS for a free port. After Phoenix boots, an Application start hook (new module `Esr.Launchd.PortWriter`, called from `Esr.Application.start/2` after Endpoint is up) reads the actually-bound port via `Bandit.ThousandIsland`-level introspection (Phoenix 1.8 + Bandit exposes listener info via the supervision tree) and writes `$ESRD_HOME/$instance/esrd.port`. Zero race.
2. **Python pre-bind (fallback)**: if `PORT=0` proves impractical in Bandit introspection, the shell script picks a free port via `python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); print(p)'`, writes the port file, then `exec`s `mix phx.server` with `PORT=$port`. ~100ms race window; launchd (`ThrottleInterval=10`) restarts on `:eaddrinuse`.

Plan task should try (1) first. If a working Bandit introspection path is found, drop (2); otherwise ship (2) with race acknowledged.

### 3.2 `scripts/esrd-launchd.sh`

New. launchd's `ProgramArguments` points at this. It:

1. Reads `ESRD_HOME` + instance from plist-supplied env.
2. Cleans any stale pidfile.
3. Pre-selects a port (same logic as §3.1).
4. Writes port + pid files.
5. `cd` to the associated code checkout directory (supplied via env: `ESR_REPO_DIR`).
6. `exec mix phx.server` — `exec` replaces the shell process so launchd supervises `beam.smp` directly, not a detached grandchild.

`KeepAlive` semantics therefore work as expected: beam exits (crash or explicit shutdown) → launchd starts a new `esrd-launchd.sh` → new random port.

### 3.3 `scripts/esr-branch.sh`

New. Entry point for ephemeral esrd lifecycle. Called by the dev esrd's routing handler via `System.cmd/3`.

Subcommands:

- `esr-branch.sh new <branch_name> [--worktree-base=.claude/worktrees] [--repo-root=.]`
  - `git -C <repo-root> worktree add <worktree-base>/<branch_name> -b <branch_name>` (or existing branch if present)
  - Compute `ESRD_HOME=/tmp/esrd-<sanitized_branch_name>`
  - Run `scripts/esrd.sh start --instance=default` with that ESRD_HOME + `ESR_REPO_DIR=<worktree_path>`
  - Wait up to 30s for `esrd.port` to appear
  - Append entry to `~/.esrd-dev/default/branches.yaml` (atomic: write temp, rename):
    ```yaml
    branches:
      feature-foo:
        esrd_home: /tmp/esrd-feature-foo
        worktree_path: /Users/h2oslabs/Workspace/esr/.claude/worktrees/feature-foo
        port: 54321              # read back from port file
        spawned_at: 2026-04-21T04:00:00Z
        status: running
    ```
  - Print newline-delimited JSON result to stdout for the handler to parse:
    `{"ok": true, "branch": "feature-foo", "port": 54321, "worktree_path": "..."}`

- `esr-branch.sh end <branch_name>`
  - Look up branches.yaml entry
  - Run `scripts/esrd.sh stop` with that ESRD_HOME
  - `git -C <repo_root> worktree remove <worktree_path>` (only if clean — add `--force` in caller if user explicitly requested)
  - Remove entry from branches.yaml
  - Print `{"ok": true, "branch": "feature-foo"}` or `{"ok": false, "error": "..."}`

Branch name sanitization: replace `/` with `-` for directory paths (so `feature/foo` becomes directory `feature-foo`).

## 4. launchd plists

### 4.1 Plist templates

**`scripts/launchd/com.ezagent.esrd.plist`** (prod):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ezagent.esrd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/h2oslabs/Workspace/esr/scripts/esrd-launchd.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>WorkingDirectory</key>
  <string>/Users/h2oslabs/Workspace/esr</string>
  <key>StandardOutPath</key>
  <string>/Users/h2oslabs/.esrd/default/logs/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/h2oslabs/.esrd/default/logs/launchd-stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ESRD_HOME</key><string>/Users/h2oslabs/.esrd</string>
    <key>ESR_REPO_DIR</key><string>/Users/h2oslabs/Workspace/esr</string>
    <key>MIX_ENV</key><string>prod</string>
    <key>ESR_BOOTSTRAP_PRINCIPAL_ID</key>
    <string>ou_6b11faf8e93aedfb9d3857b9cc23b9e7</string>
  </dict>
</dict>
</plist>
```

**`scripts/launchd/com.ezagent.esrd-dev.plist`** (dev): identical structure, differences:

- `Label` → `com.ezagent.esrd-dev`
- `ESRD_HOME` → `/Users/h2oslabs/.esrd-dev`
- `ESR_REPO_DIR` → `/Users/h2oslabs/Workspace/esr/.claude/worktrees/dev`
- `MIX_ENV` → `dev`
- Log paths under `/Users/h2oslabs/.esrd-dev/default/logs/`

### 4.2 Install / uninstall scripts

**`scripts/launchd/install.sh [--env=prod|dev|both]`**:

- Defaults to `both`
- For each env:
  - Template-fill the plist (substitute `$HOME` / username if not root)
  - Copy to `~/Library/LaunchAgents/com.ezagent.esrd{-dev}.plist`
  - `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/...`
  - Check initial port file appearance to verify launch success
- Detect `~/.esrd/default/` pre-existing data on first prod install and print migration guidance (does NOT auto-migrate).

**`scripts/launchd/uninstall.sh [--env=prod|dev|both]`**:

- `launchctl bootout gui/$UID/com.ezagent.esrd{-dev}`
- Remove plist
- Print instructions to manually clean up `~/.esrd{-dev}/` if the user wants a clean slate

## 5. Python CLI changes

### 5.1 `ESRD_HOME` helper

`py/src/esr/cli/paths.py` **already exists** (introduced in the capabilities
work) with `esrd_home()` + `capabilities_yaml_path()`. Extend it with two
new helpers:

```python
# Additions to existing py/src/esr/cli/paths.py
def current_instance() -> str:
    """Current instance name. Honors $ESR_INSTANCE; defaults to 'default'."""
    return os.environ.get("ESR_INSTANCE", "default")

def runtime_home() -> Path:
    """ESRD_HOME / instance, e.g. ~/.esrd-dev/default."""
    return esrd_home() / current_instance()

def adapters_yaml_path() -> Path:
    return runtime_home() / "adapters.yaml"

def workspaces_yaml_path() -> Path:
    return runtime_home() / "workspaces.yaml"

def commands_compiled_dir() -> Path:
    return runtime_home() / "commands" / ".compiled"
```

Refactor the **7 real code sites** (docstring references at lines 289,
325, 455, 514, 823 are unchanged — they describe the layout in prose):

| Line | Current | Becomes |
|---|---|---|
| 290 | `Path(...) / ".esrd" / "default" / "adapters.yaml"` | `paths.adapters_yaml_path()` |
| 343 | same | `paths.adapters_yaml_path()` |
| 834 | `... / "commands" / ".compiled"` | `paths.commands_compiled_dir()` |
| 947 | same | `paths.commands_compiled_dir()` |
| 1251 | `... / "workspaces.yaml"` | `paths.workspaces_yaml_path()` |
| 1281 | same | `paths.workspaces_yaml_path()` |
| 1295 | same | `paths.workspaces_yaml_path()` |

Each helper honors `ESRD_HOME` + `ESR_INSTANCE` automatically, so every
call site becomes env-respecting without further per-site plumbing.

### 5.2 `esr reload`

New Python CLI command group `esr reload`:

```bash
esr reload                            # defaults: read ESRD_HOME → prod or dev
esr reload --acknowledge-breaking     # ack any unhandled breaking commits
esr reload --dry-run                  # show what would happen
```

Logic:

1. Resolve target env from `ESRD_HOME` (`~/.esrd` → `com.ezagent.esrd`, `~/.esrd-dev` → `com.ezagent.esrd-dev`).
2. Read `paths.runtime_home() / "last_reload.yaml"` for `last_reload_sha`.
3. Shell out `git log <last_sha>..HEAD --grep='^[^:]*!:' --grep='BREAKING CHANGE:' --format='%h %s'`.
4. If hits exist and `--acknowledge-breaking` is NOT passed:
   - Print the list + message `Unacknowledged breaking changes. Run --acknowledge-breaking to proceed.`
   - Exit 1 (non-zero — caller shell/handler can detect).
5. If clean (or acknowledged):
   - Print "Reloading <label>..."
   - `launchctl kickstart -k gui/$UID/com.ezagent.esrd{-dev}`
   - Wait up to 30s for new `esrd.port` mtime to change
   - Update `last_reload.yaml`:
     ```yaml
     last_reload_sha: <current HEAD>
     last_reload_ts: <ISO now>
     by: <current operator principal_id, from $ESR_OPERATOR_PRINCIPAL_ID or $USER>
     acknowledged_breaking: [list of commit SHAs acknowledged this reload]
     ```

### 5.3 `esr notify`

New Python CLI command:

```bash
esr notify --type=breaking --since=<sha> --details='<text>'
esr notify --type=info --to=ou_xxx --text='<text>'
esr notify --type=reload-complete
```

Logic:

1. Load adapter creds: `ruamel.yaml` read `paths.runtime_home() / "adapters.yaml"`, find first entry with `type: feishu`, read its `config.app_id` + `.env.local` for `app_secret`.
2. Init `lark_oapi.Client` (same pattern as feishu adapter).
3. For `--to=<open_id>`: direct DM to that user.
4. For no `--to`: DM every admin principal (everyone in `capabilities.yaml` holding `"*"`).
5. Message template varies by `--type`:
   - `breaking`: "⚠️ <env> 分支包含破坏性更新: <details>\n执行 `/reload --acknowledge-breaking` 或终端运行 `esr reload --acknowledge-breaking`"
   - `info` / `reload-complete`: passed-through `--text`.

### 5.4 `esr adapter feishu create-app`

New Python CLI command. Interactive wizard — L3 (paste-based) approach since Feishu has no public app-creation API and `backend_oneclick` URL still requires browser click-through with no callback.

```bash
esr adapter feishu create-app --name "ESR 开发助手" --target-env dev
```

Logic:

1. Build the `backend_oneclick` URL with query params encoding the ESR-required scopes and events:
   - Scopes: `im:message`, `im:message:send_as_bot`, `im:chat`, `contact:user.base:readonly`, `im:message.file:readonly`
   - Events: `im.message.receive_v1`, `im.chat.access_event.bot.p2p_chat_create_v1`, `im.message.reaction.created_v1`
2. Print the URL (use plain print, not `open` — stays in L3).
3. Prompt (via `click.prompt`):
   - `粘贴 App ID: `
   - `粘贴 App Secret: ` (hidden input via `hide_input=True`)
4. Validate by calling `tenant_access_token` with the creds. Fail loudly if 4xx.
5. On success:
   - Write adapter entry to `paths.runtime_home() / "adapters.yaml"` (via `ruamel.yaml`, preserve comments)
   - Write `app_secret` to `paths.runtime_home() / ".env.local"` (mode 0600)
   - Print "Feishu app '<name>' configured for <env>."

### 5.5 Client-side auto-reconnect audit

Touch list (review + fix; no new modules):

- `py/src/esr/ipc/adapter_runner.py` — already has `url` arg; verify it honors env/port-file override and reconnects with exponential backoff on WS close.
- `py/src/esr/ipc/handler_worker.py` — same audit.
- `adapters/cc_mcp/src/esr_cc_mcp/channel.py:141` — change the default from hardcoded `ws://127.0.0.1:4001` to "read `$ESRD_HOME/default/esrd.port` then fall back". Add reconnect loop on disconnect.
- Expected outcome: after `launchctl kickstart`, clients see WS close, wait ~200ms, re-read port file (new port), reconnect. Normal operation resumes within 10–30s.

## 6. Elixir runtime changes

### 6.1 `Esr.Routing.SessionRouter`

New handler module; registered as an `Esr.Handler` behavior and supervised under a new `Esr.Routing.Supervisor`.

**Note on `permissions/0`**: this callback **already exists** on `Esr.Handler` behaviour (declared `@optional_callbacks permissions: 0` in `runtime/lib/esr/handler.ex:20-22`, introduced in the capabilities work). `SessionRouter` implements it; no behaviour extension needed.

**Non-blocking shell-outs (architectural)**: `SessionRouter` is a
GenServer. Blocking `System.cmd/3` calls that can take up to 30s
(`esr-branch.sh new` waits for port file) MUST NOT happen in the
handler's receive loop — that would starve the mailbox and break
other users' message routing. Follow the existing precedent in
`runtime/lib/esr/peer_server.ex:702-707` (`Task.start` with a
correlation ref, result returned asynchronously):

```elixir
def handle_info({:msg_received, envelope}, state) do
  case parse_command(envelope) do
    {:new_session, branch, opts} ->
      ref = make_ref()
      Task.start(fn ->
        result = System.cmd("scripts/esr-branch.sh", ["new", branch, ...])
        send(self_pid, {:branch_spawn_result, ref, result})
      end)
      {:noreply, %{state | pending: Map.put(state.pending, ref, envelope)}}
    ...
  end
end

def handle_info({:branch_spawn_result, ref, {output, 0}}, state) do
  # parse JSON, update routing.yaml, emit reply directive to user
  envelope = Map.fetch!(state.pending, ref)
  ...
end
```

Every shell-out in data flows §7.3 / §7.5 / §7.6 uses this pattern.

State (Pydantic-style, but in Elixir):

```elixir
defmodule Esr.Routing.SessionRouter do
  @behaviour Esr.Handler

  defstruct routing: %{},   # principal_id → %{active: branch, targets: %{branch => %{esrd_url, cc_session_id}}}
            branches: %{}   # branch_name → %{esrd_url, worktree_path, port, status}

  @impl true
  def permissions, do: [
    "session.create",
    "session.switch",
    "session.end",
    "session.list",
    "runtime.reload",
    "branch.signal_cleanup"   # CC → runtime signal channel
  ]
end
```

Behavior:

- Listens for `msg_received` events in the dev Feishu workspace (configured via workspace binding).
- Parses leading slash commands:
  - `/new-session <branch> [--new-worktree]` — requires `session.create`
  - `/switch-session <branch>` — requires `session.create`
  - `/end-session <branch> [--force]` — requires `session.end`
  - `/sessions` or `/list-sessions` — requires `session.list`
  - `/reload [--acknowledge-breaking]` — requires `runtime.reload`
- Non-command messages: look up `routing[principal_id].active` → dispatch to that target.
- State persisted to `routing.yaml` on every change (via `ruamel.yaml`-equivalent Elixir YAML writer).
- `branches.yaml` is read-only from the handler's perspective — it's written by `esr-branch.sh`. Handler fs-watches it for updates.

### 6.2 `routing.yaml` schema

Path: `$ESRD_HOME/default/routing.yaml` (each runtime has its own).

```yaml
# Per-principal routing state. Managed by Esr.Routing.SessionRouter.
# Manual editing is supported but not required.

version: 1
principals:
  ou_6b11faf8e93aedfb9d3857b9cc23b9e7:
    active: dev               # which branch is currently receiving this user's messages
    display: linyilun
    targets:
      dev:
        esrd_url: ws://127.0.0.1:54321/adapter_hub/socket/websocket?vsn=2.0.0
        cc_session_id: ou_6b11faf8-dev
        created_at: 2026-04-21T04:00:00Z
      feature-foo:
        esrd_url: ws://127.0.0.1:54399/adapter_hub/socket/websocket?vsn=2.0.0
        cc_session_id: ou_6b11faf8-feature-foo
        created_at: 2026-04-21T05:30:00Z
```

For prod esrd, this file looks the same structurally but will usually have one principal with one active target. The prod routing is still needed because **different users of ESR 助手 each get their own CC session** (matches cc-openclaw's per-principal-agent pattern).

### 6.3 `branches.yaml` schema

Path: `$ESRD_HOME/default/branches.yaml` (only populated on dev esrd; prod has empty/no file).

```yaml
version: 1
branches:
  dev:
    esrd_home: /Users/h2oslabs/.esrd-dev
    worktree_path: /Users/h2oslabs/Workspace/esr/.claude/worktrees/dev
    port: 54321
    spawned_at: 2026-04-21T00:00:00Z
    status: running
    kind: permanent            # vs ephemeral
  feature-foo:
    esrd_home: /tmp/esrd-feature-foo
    worktree_path: /Users/h2oslabs/Workspace/esr/.claude/worktrees/feature-foo
    port: 54399
    spawned_at: 2026-04-21T05:30:00Z
    status: running
    kind: ephemeral
```

The `dev` entry is bootstrapped at install time by `install.sh`; thereafter it's read-only within its own runtime.

### 6.4 Feishu command grammar

All commands scoped to the ESR 开发助手 Feishu app's chat context (DM or group where bot is added).

| Command | Required capability | Effect |
|---|---|---|
| `/new-session <branch> [--new-worktree]` | `session.create` | (Bot → esr-branch.sh new → routing.yaml update → reply with port info) |
| `/switch-session <branch>` | `session.create` | Update `routing[principal_id].active = branch`; no process spawn |
| `/end-session <branch> [--force]` | `session.end` | Bot sends cleanup-check to CC; on `WORKTREE_CLEANED` → esr-branch.sh end → routing.yaml prune |
| `/sessions` or `/list-sessions` | `session.list` | Reply with branches.yaml + routing.yaml contents scoped to the user |
| `/reload [--acknowledge-breaking]` | `runtime.reload` | Bot shells `esr reload [--acknowledge-breaking]`; reply with result |

Parsing: leading-slash recognition only at message start; argparse-style with `--flag`. Unrecognized command → send help reply listing valid commands for the user's capability set.

### 6.5 CC cleanup-check tool primitive

New MCP tool `session.signal_cleanup` exposed by the runtime (callable by CC via MCP bridge). CC invokes this to signal its worktree state before `/end-session` completes.

Payload shape:

```json
{
  "session_id": "ou_xxx-feature-foo",
  "worktree_path": "/Users/h2oslabs/.../.claude/worktrees/feature-foo",
  "status": "CLEANED | DIRTY | UNPUSHED | STASHED",
  "details": {
    "dirty_files": ["runtime/lib/foo.ex"],       # if DIRTY
    "unpushed_commits": 3,                        # if UNPUSHED
    "stash_entries": ["WIP on feature-foo: ..."]  # if STASHED
  }
}
```

Handler flow:

1. `/end-session feature-foo` arrives
2. Handler sends a `cleanup-check` tool invocation to the target CC session
3. CC runs `git status --porcelain`, `git log @{u}..`, `git stash list`, composes status
4. CC invokes `session.signal_cleanup` with payload
5. Handler receives via `tool_invoke`, branches on status:
   - `CLEANED` → proceed with `esr-branch.sh end`
   - else → reply to user with details, offer `--force` or `/commit` / `/push` / `/stash drop` next steps
6. If CC does not respond in 30s, handler sends follow-up to user: "check 未完成，点 [强制关闭] [再等] [取消]" interactive prompt

## 7. Data flows

### 7.1 Cold start (prod or dev)

```
launchd (RunAtLoad=true)
  → esrd-launchd.sh
    → pre-select port (Python one-liner)
    → write port + pid files
    → exec mix phx.server with PORT=$port
  → Phoenix boots
    → Esr.Application starts supervision tree
      → Esr.Permissions.Registry populated from handler.permissions/0
      → Esr.Capabilities.Grants loaded from capabilities.yaml
      → Esr.Workspaces.Registry from workspaces.yaml
      → Esr.AdapterHub.Registry restores adapters from adapters.yaml
        → Feishu adapter connects to Lark WebSocket (cred from .env.local)
      → Esr.Routing.SessionRouter loads routing.yaml + branches.yaml
    → Phoenix Endpoint listening, esrd.port is stable
```

### 7.2 `p2p_chat_create` → auto /new-session

```
New user ou_alice creates P2P chat with ESR 开发助手
  → Lark pushes im.chat.access_event.bot.p2p_chat_create_v1
  → Feishu adapter emits inbound_event with event_type="p2p_chat_create"
  → Esr.Routing.SessionRouter.handle_event/2 matches
    → Check capabilities: does ou_alice hold workspace:dev/session.create?
      → YES: fire internal `auto_new_session("ou_alice-dev", default_branch="dev")`
      → NO: reply "抱歉，你无权使用此 bot。请联系管理员授权。"
    → auto_new_session updates routing.yaml:
        ou_alice:
          active: dev
          targets:
            dev: {esrd_url: <dev's url>, cc_session_id: ou_alice-dev}
    → Reply "欢迎。你已连接到 dev 环境的 ou_alice-dev session。"
```

### 7.3 `/new-session feature/foo --new-worktree`

```
User ou_linyilun sends /new-session feature/foo --new-worktree
  → Esr.Routing.SessionRouter parses command
    → Check capability: session.create on workspace:dev
      → YES
    → System.cmd("scripts/esr-branch.sh", ["new", "feature/foo", "--worktree-base=.claude/worktrees"])
      → esr-branch.sh:
          git worktree add .claude/worktrees/feature-foo -b feature/foo
          scripts/esrd.sh start --instance=default (with ESRD_HOME=/tmp/esrd-feature-foo)
            → new esrd process, new port, port file written
          append to branches.yaml (dev esrd's file)
          print JSON {ok: true, branch: "feature-foo", port: 54399}
      → handler parses JSON
    → Update routing.yaml:
        ou_linyilun.active = "feature-foo"
        ou_linyilun.targets["feature-foo"] = {esrd_url: ..., cc_session_id: ou_linyilun-feature-foo}
    → Reply "feature/foo worktree created at .claude/worktrees/feature-foo; session active."
  → User's next non-slash message routes to ephemeral esrd at /tmp/esrd-feature-foo
```

### 7.4 `/switch-session dev`

Pure routing.yaml update — no process work. Update `ou_linyilun.active = "dev"`; reply ack.

### 7.5 `/end-session feature/foo`

```
User ou_linyilun sends /end-session feature/foo
  → handler checks capability
  → handler sends cleanup-check tool_invoke to CC at /tmp/esrd-feature-foo
  → CC runs git status / log / stash checks
  → CC invokes session.signal_cleanup with status=CLEANED (best case)
  → handler:
    System.cmd("scripts/esr-branch.sh", ["end", "feature/foo"])
      → scripts/esrd.sh stop (ESRD_HOME=/tmp/esrd-feature-foo)
      → git worktree remove
      → prune branches.yaml entry
    update routing.yaml:
      remove ou_linyilun.targets["feature-foo"]
      if ou_linyilun.active == "feature-foo" → fall back to "dev" (or first remaining)
    reply "session feature/foo closed."

[30s timeout branch]
  → CC did not respond
  → handler pushes interactive prompt "check 未完成，点 [强制关闭] [再等] [取消]"
  → user picks:
    强制关闭 → handler calls esr-branch.sh end with --force, skips cleanup-check
    再等 → handler waits another 30s
    取消 → handler aborts /end-session, leaves ephemeral running
```

### 7.6 `/reload`

```
Admin sends /reload in ESR 开发助手
  → handler checks capability runtime.reload
  → handler: System.cmd("esr", ["reload"]) (shells out to Python CLI)
    → esr reload reads ESRD_HOME, resolves to com.ezagent.esrd-dev
    → git log since last_reload.yaml.last_reload_sha
    → breaking commits found → exit 1 with details
  → handler reply "⚠️ 自上次 reload 以来有 2 个破坏性 commit: ...\n`/reload --acknowledge-breaking` 确认"

[user re-sends /reload --acknowledge-breaking]
  → handler: System.cmd("esr", ["reload", "--acknowledge-breaking"])
    → esr reload: launchctl kickstart -k gui/$UID/com.ezagent.esrd-dev
    → wait for new port file mtime
    → update last_reload.yaml
  → handler reply "重启完成。新 port: <N>. 用户连接将自动重连。"
  → (dev esrd process killed, new one starts; clients auto-reconnect to new port)
```

## 8. Breaking-change notification

### 8.1 Conventional Commits detection

Markers (either form triggers "breaking"):
- Subject line: `<type>(<scope>)!: <message>` — the `!` before `:`
- Commit body: any line matching `^BREAKING CHANGE: ` (case-sensitive per spec)

Detection command:
```bash
git log <since>..HEAD \
  --grep='^[^:]*!:' \
  --grep='^BREAKING CHANGE:' \
  --format='%h|%s|%an|%ae'
```

### 8.2 `post-merge` git hook

Installed by `install.sh` into the dev worktree at `.git/hooks/post-merge`. (The prod worktree also gets it but in practice prod is usually fast-forwarded from already-merged main, so it rarely triggers.)

```bash
#!/usr/bin/env bash
set -u

# Only run on the dev worktree (or any ESR worktree where esrd-dev should be reloaded)
repo_root="$(git rev-parse --show-toplevel)"
[[ "$repo_root" != *"/esr"* ]] && exit 0

prev_head="$(git rev-parse HEAD@{1} 2>/dev/null || echo '')"
[[ -z "$prev_head" ]] && exit 0

breaking="$(git log "$prev_head"..HEAD --grep='^[^:]*!:' --grep='^BREAKING CHANGE:' --format='%h %s')"

if [[ -n "$breaking" ]]; then
  # Use esr notify (Python CLI) to DM admins
  esr notify --type=breaking --since="$prev_head" --details="$breaking" || true
fi
```

The `|| true` ensures a notify failure never blocks the merge.

### 8.3 `last_reload.yaml` schema

Path: `$ESRD_HOME/default/last_reload.yaml`.

```yaml
version: 1
last_reload_sha: a1b2c3d4
last_reload_ts: 2026-04-21T03:00:00Z
by: ou_6b11faf8...
acknowledged_breaking:
  - a1b2c3d4        # commit acknowledged during this reload
  - ef012345
```

Rules:
- `last_reload_sha` is the HEAD at the moment of successful reload.
- `acknowledged_breaking` lists commits that the reload operator explicitly acknowledged via `--acknowledge-breaking`.
- New breaking commits landed after `last_reload_sha` → must be acknowledged on the NEXT reload (or `--acknowledge-breaking` will pass them transparently).

## 9. Error handling

### 9.1 Port collision

Pre-selection race window (~100 ms between `s.bind(0)` and `exec mix`). If another process grabs the port in that window:
- `mix phx.server` crashes with `:eaddrinuse`
- launchd (`KeepAlive=true, ThrottleInterval=10`) restarts after 10s
- New random port, new port file, clients reconnect

This is the self-healing path. No explicit retry inside the start script.

### 9.2 Orphan `/tmp/esrd-*` processes

On dev esrd boot, `Esr.Routing.SessionRouter.init/1` scans `/tmp/esrd-*/`:
- For each directory, read `esrd.pid`
- If pid exists and is running: adopt — ensure branches.yaml has an entry (add if missing)
- If pid does not exist or is dead: clean up — remove the directory, prune branches.yaml

### 9.3 CC WS reconnect

Triggered by a WS close event (normal close after `launchctl kickstart`, or network blip).

- Python client's WS loop catches close, enters reconnect state
- Exponential backoff: 200ms, 400ms, 800ms, 1600ms... capped at 5s
- Each attempt re-reads `$ESRD_HOME/default/esrd.port` (mtime may indicate a new port)
- Max reconnect window: 2 minutes, after which the client exits with error (handled by parent process policy — launchd for the adapter, CC session for the MCP bridge)

### 9.4 Feishu credential drift

Adapter on startup calls `tenant_access_token`:
- 400/401/403 on boot → adapter logs a loud error and exits; launchd restart after ThrottleInterval
- If persistent: operator runs `esr adapter feishu create-app --name "<existing name>" --target-env=<env>` to re-bootstrap and overwrite creds

### 9.5 git worktree conflict

If `/new-session feature/foo --new-worktree` is invoked but `feature/foo` is already checked out as a worktree:
- `git worktree add` fails with a specific error
- `esr-branch.sh new` returns `{"ok": false, "error": "worktree for feature-foo already exists at <path>"}`
- Handler replies "branch feature/foo 已存在 worktree at <path>。/switch-session 切换过去，或 /end-session --force 清理后重来。"

## 10. Acceptance criteria

- [ ] `scripts/esrd.sh --port=54321 ...` respects the override; absence of `--port` picks a random free port and writes it to `esrd.port`.
- [ ] Two LaunchAgents (`com.ezagent.esrd` + `com.ezagent.esrd-dev`) can coexist, each on its own random port.
- [ ] `esr cap list` (CLI already existing) works under `ESRD_HOME=~/.esrd-dev esr cap list` and shows the dev runtime's registered permissions.
- [ ] `esr adapter feishu create-app --name "ESR 开发助手" --target-env dev` writes `adapters.yaml` + `.env.local` successfully after paste.
- [ ] New user first DM to ESR 开发助手 auto-creates `<open_id>-dev` session and replies the welcome message.
- [ ] `/new-session feature/foo --new-worktree` creates worktree at `.claude/worktrees/feature-foo`, spawns `/tmp/esrd-feature-foo/` esrd, updates routing.yaml + branches.yaml, replies ack.
- [ ] `/switch-session dev` is O(1) — only updates routing.yaml.
- [ ] `/end-session feature/foo` sends cleanup-check; clean state → closes and removes worktree; dirty state → prompts for next action.
- [ ] `/end-session` with CC unresponsive >30s → interactive prompt displayed.
- [ ] `/reload` without breaking commits → triggers launchctl kickstart; client reconnects within 30s.
- [ ] `/reload` with unacknowledged breaking commits → replies with list + instruction.
- [ ] post-merge hook on dev worktree fires `esr notify` when breaking commits land.
- [ ] `last_reload.yaml` updated after each successful reload.
- [ ] dev esrd reboot (via kickstart) adopts or cleans orphan `/tmp/esrd-*/` processes.
- [ ] Feishu credentials rotated via re-running `create-app` → new boot succeeds.

## 11. Touch list

### 11.1 New files

**Shell**:
- `scripts/esrd-launchd.sh`
- `scripts/esr-branch.sh`
- `scripts/launchd/com.ezagent.esrd.plist`
- `scripts/launchd/com.ezagent.esrd-dev.plist`
- `scripts/launchd/install.sh`
- `scripts/launchd/uninstall.sh`

**Python**:
- `py/src/esr/cli/reload.py` (new CLI subcommand module)
- `py/src/esr/cli/notify.py`
- `py/src/esr/cli/adapter/__init__.py` (new adapter subcommand group)
- `py/src/esr/cli/adapter/feishu.py` (create-app wizard)
- `py/tests/test_cli_reload.py`
- `py/tests/test_cli_notify.py`
- `py/tests/test_cli_adapter_feishu.py`

**Elixir**:
- `runtime/lib/esr/routing.ex`
- `runtime/lib/esr/routing/supervisor.ex`
- `runtime/lib/esr/routing/session_router.ex`
- `runtime/test/esr/routing/session_router_test.exs`

**Git hooks**:
- `scripts/hooks/post-merge` (template installed by `install.sh`)

**Docs**:
- `docs/operations/dev-prod-isolation.md` (post-implementation operator guide)

### 11.2 Modified files

- `scripts/esrd.sh` — add `--port` and port pre-selection
- `py/src/esr/cli/main.py` — register new subcommands; refactor 9 hardcoded paths to `paths.runtime_home()`
- `py/src/esr/cli/paths.py` — add `esrd_home()`, `current_instance()`, `runtime_home()`
- `py/src/esr/ipc/adapter_runner.py` — audit reconnect logic
- `py/src/esr/ipc/handler_worker.py` — audit reconnect logic
- `adapters/cc_mcp/src/esr_cc_mcp/channel.py:141` — read port from port file + reconnect
- `runtime/lib/esr/application.ex` — add `Esr.Routing.Supervisor` (and `Esr.Launchd.PortWriter` if port-resolution path 1 lands) to supervision tree
- `runtime/lib/esr/peer_server.ex` — register `session.signal_cleanup` as an MCP tool at lines **762-825** (the `build_emit_for_tool/3` clause region; the earlier citation of 680-740 was wrong, that range is `dispatch_action` not tool handling)
- `runtime/lib/esr/handler.ex` — no change; `permissions/0` is already an optional callback
- `adapters/feishu/src/esr_feishu/adapter.py` — **add `register_p2_im_chat_access_event_bot_p2p_chat_create_v1` dispatcher** at the existing event-registration site (near line 663 alongside the existing `register_p2_im_message_receive_v1`). Emit a corresponding `inbound_event` with `event_type="p2p_chat_create"` so `SessionRouter` can consume it per §7.2. (The reviewer flagged this as missing from the original touch list.)

### 11.3 Dependencies

No new library deps. Uses existing `:yaml_elixir`, `:file_system`, `lark_oapi`, `ruamel.yaml`, `click`.

## 12. Sequencing (for writing-plans)

Phase ordering respects dependency topology and allows partial ship:

- **Phase DI-1** — Shell + port-file base: `esrd.sh --port`, `esrd-launchd.sh`. Testable in isolation; proves random-port + port-file mechanism.
- **Phase DI-2** — Python CLI refactor: `paths.py` helper + migrate 9 hardcoded sites. Unit-test only.
- **Phase DI-3** — Client-side reconnect audit + fix: adapter_runner / handler_worker / cc_mcp channel. Integration test.
- **Phase DI-4** — launchd plists + install.sh: prod first (current `~/.esrd` keeps working), then dev. Manual smoke test.
- **Phase DI-5** — `esr adapter feishu create-app`: interactive wizard. Unit test the CLI flow; real Feishu test manually.
- **Phase DI-6** — `Esr.Routing.SessionRouter` + routing.yaml + basic slash commands (`/new-session`, `/switch-session`, `/sessions`). Permission integration uses the existing capabilities subsystem.
- **Phase DI-7** — `esr-branch.sh` + ephemeral esrd lifecycle + branches.yaml + orphan adoption.
- **Phase DI-8** — `session.signal_cleanup` tool primitive + `/end-session` full flow with cleanup coordination + 30s timeout UX.
- **Phase DI-9** — `esr reload` + `last_reload.yaml` + breaking-change safety gate.
- **Phase DI-10** — `esr notify` + post-merge git hook template + install hook into dev worktree.
- **Phase DI-11** — E2E acceptance scenarios + operator docs.

Phases DI-1 through DI-5 produce a working prod esrd + dev esrd pair (no branching yet). Phases DI-6 onward layer the dev workflow on top.

## 13. Future work

- **`Esr.Reload.BlueGreen`** (separate spec): true zero-downtime reload via double-binding, connection migration, and atomic cutover. Target when the 10–30s reconnect gap becomes a product problem.
- **v0.3 CLI instance awareness**: `esr --instance=<name>` flag across all commands; retires the `ESR_INSTANCE` env var approach.
- **Docker isolation**: `docs/futures/docker-isolation.md` — for when users run completely different ESR code versions in parallel (main branch vs experimental rewrite).
- **Branch esrd auto-sleep**: idle >N minutes → pause the esrd (or kill entirely); next message wakes it. Requires state checkpointing.
- **Explicit capability delegation**: already tracked in `docs/futures/explicit-capability-delegation.md`. Relevant here because per-session capability restriction (Alice's CC-linyilun-dev has `msg.send` only, not `*`) would strengthen the multi-user story.
- **Cross-app user-to-user messaging handler**: `docs/futures/cross-workspace-messaging-handler.md` — enables "Alice via App1 pings Bob via App2" flows.
