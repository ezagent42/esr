# ESR Dev/Prod Isolation + Admin Subsystem + Session Routing Design

Author: brainstorming session with user (linyilun)
Date: 2026-04-21
Status: draft v2, awaiting user review
Relates to:
- `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md` (capabilities v1, merged as commit `29d92b4`)
- `docs/futures/docker-isolation.md` (to be added — full-isolation alternative)

**Change log**:
- v1 (initial): Minimal-runtime approach; `esr notify` / `esr reload` directly shell-out or call Feishu API, bypassing the actor model.
- v2 (this): Introduces `Esr.Admin` subsystem as the single execution path for all administrative operations. CLI becomes a thin UX+queue-writer; `Esr.Routing.SessionRouter` becomes a command parser that forwards to the Dispatcher. `esr adapter feishu create-app` also flows through the Dispatcher (clarified: esrd runs even with empty adapters.yaml).

## 1. Goal & Scope

### 1.1 Problem statement

Today ESR runs as a single `mix phx.server` on port 4001 against `~/.esrd/default/`. A developer working on ESR has to choose between:

- Editing code and losing production-like state (their WIP breaks their own bot)
- Freezing their bot and being unable to iterate

This is the classic "eating your own dogfood while modifying the dogfood" problem. The E2E developer workflow this design enables:

1. `main` branch runs as **prod** (always-on, connected to "ESR 助手" Feishu app, serves as owner's daily-driver assistant).
2. `dev` branch runs as **dev** (always-on, connected to "ESR 开发助手" Feishu app, integration target for WIP merges).
3. WIP branches run as **ephemeral** esrd instances (spawned on demand via a Feishu slash command in ESR 开发助手, live at `/tmp/esrd-<branch>/`, torn down when done).
4. Multi-user: the same ESR 开发助手 bot dispatches messages to the right (user, branch) tuple so two developers can iterate in parallel.
5. Code updates reload via admin-triggered `/reload` command — no auto-reload on file change.
6. Breaking changes surfaced proactively via Conventional Commits scanning in a post-merge git hook → DM to admin.
7. **All administrative operations** (notify, reload, session lifecycle, capability grants, adapter registration) flow through a single in-runtime dispatcher so there is one execution path with consistent authorization, logging, and audit.

### 1.2 In scope

Six artifact categories delivered together:

1. **Shell artifacts**: `esrd.sh` enhancements (random port + port file), `esrd-launchd.sh` (launchd-front wrapper), `esr-branch.sh` (worktree + ephemeral esrd lifecycle).
2. **launchd plists**: prod + dev user LaunchAgents with install/uninstall scripts.
3. **Python CLI**: `ESRD_HOME` helper extension (7 hardcoded sites); all admin CLI commands (`esr reload`, `esr notify`, `esr adapter feishu create-app`, `esr cap grant/revoke/…` migration) become thin "local UX + write to admin queue" clients; client-side auto-reconnect audit + fixes.
4. **Elixir runtime — Admin subsystem** (primary addition): `Esr.Admin.Supervisor`, `Esr.Admin.Dispatcher` (GenServer), `Esr.Admin.CommandQueue.Watcher` (GenServer), and a set of `Esr.Admin.Commands.*` handler modules (Notify, Reload, RegisterAdapter, Session.New/Switch/End/List, Cap.Grant/Revoke).
5. **Elixir runtime — Routing subsystem** (secondary): `Esr.Routing.SessionRouter` parses Feishu slash commands and forwards to the Admin Dispatcher. Also owns `routing.yaml` (per-user active branch lookup).
6. **Data files**: `admin_queue/` directory layout (`pending/`, `processing/`, `completed/`, `failed/`), `routing.yaml`, `branches.yaml`, `last_reload.yaml`; git hook templates.

### 1.3 Out of scope

- **Same-root multi-instance topology**: running two beam.smp processes simultaneously under *one* `ESRD_HOME` root at different instance names (e.g. `~/.esrd/prod/` + `~/.esrd/dev/`). This requires cross-instance port discovery and shared-config-boundary rules. This design uses **different ESRD_HOME roots** for isolation instead (`~/.esrd/` + `~/.esrd-dev/`, each with `instance=default`), which sidesteps the complexity. Proper same-root multi-instance remains future work.
- **True blue-green zero-downtime reload**: reload has a 10–30s reconnection window. See §13 for the follow-up target (`Esr.Reload.BlueGreen`).
- **Automated Feishu app lifecycle**: Feishu has no public API for creating/deleting OpenPlatform apps. We ship an interactive paste-based wizard, not full automation.
- **Docker isolation**: separate future spec. Current reason to defer: cc_tmux adapter spawns host tmux, MCP bridge launch order, macOS fsnotify across bind mounts.
- **Schema-aware breaking-change detection**: we use Conventional Commits markers (`!:`, `BREAKING CHANGE:`) as the signal, not automated diff of GenServer state schemas or protocol envelopes.
- **Branch esrd idle auto-sleep**: an ephemeral esrd stays running until explicitly `/end-session`-ed. Time-based eviction is future work.
- **Migrating already-merged `esr cap` CLI** to the Admin dispatcher path in this spec: we keep the existing direct-yaml-write path working during rollout and migrate in a follow-up (see §13).

### 1.4 Non-goals

- **Replace launchd**: we embrace it; this design assumes macOS LaunchAgent as the supervisor.
- **Full-disk state encryption / secrets hardening**: `.env.local` holds Feishu app secrets in plain text; we rely on macOS file permissions and `.gitignore`.
- **Multi-machine deployment**: the design assumes single-host. Sessions cross-user, never cross-host.

### 1.5 Terminology

- **prod esrd**: long-running esrd at `ESRD_HOME=~/.esrd`, serves "ESR 助手".
- **dev esrd**: long-running esrd at `ESRD_HOME=~/.esrd-dev`, serves "ESR 开发助手" and orchestrates branch esrds.
- **ephemeral / branch esrd**: short-lived esrd at `ESRD_HOME=/tmp/esrd-<branch>/`, spawned by an Admin command.
- **admin**: a principal that holds `cap.manage` in the relevant capabilities.yaml; can enqueue administrative commands.
- **admin command**: a structured request (kind + args) processed by `Esr.Admin.Dispatcher`. Arrives via fs-watched queue directory (from CLI) or in-process (from Routing handler).
- **Admin subsystem**: the collection of Elixir modules under `Esr.Admin.*` that together provide the single execution path for admin operations. See §1.6 for how this relates to OTP Supervisors.

### 1.6 Admin subsystem vs OTP Supervisor, and relation to other subsystems

The word "subsystem" in this spec is informal — it denotes a coherent grouping of related modules (a namespace + its actors + its data files). An OTP Supervisor is a structural mechanism (a process that restarts its children per a strategy). The Admin subsystem *includes* an OTP Supervisor (`Esr.Admin.Supervisor`) as the structural glue, but the business brain is `Esr.Admin.Dispatcher` — a regular GenServer.

Relationship to other ESR subsystems:

- `Esr.Workspaces.Registry` (existing) — static workspace *identity* declared in `workspaces.yaml`. Read-only lookups.
- `Esr.Capabilities` (existing) — principal → permission bindings read from `capabilities.yaml`. The Admin subsystem calls `Esr.Capabilities.has?/2` to authorize every command.
- `Esr.Routing.SessionRouter` (new, secondary) — parses Feishu slash commands, looks up "where does this user's next message dispatch to?" Forwards administrative commands to `Esr.Admin.Dispatcher` for execution.
- `Esr.Admin` (new, primary) — single execution path for all state-mutating operations.

No overlap: Workspaces = static config; Routing = runtime dispatch state; Admin = mutation engine.

## 2. Architecture (Approach E+ / Admin-centric)

### 2.1 Responsibility boundaries

| Concern | Owner | Why |
|---|---|---|
| Process supervision (start, restart-on-crash) | launchd | macOS-native supervisor; already the pattern we want |
| Port selection (random, per-startup) | Phoenix post-bind read-back (preferred) OR `scripts/esrd.sh` pre-select (fallback) | See §3.1 |
| Worktree creation, esrd spawn for a branch | `scripts/esr-branch.sh` (shell) | Pure OS/filesystem/git |
| Feishu-app interactive wizard (URL print + paste prompt) | Python CLI (`esr adapter feishu create-app`) | Needs stdin/stdout interaction, not runtime's job |
| **Every state mutation** (adapters, capabilities, routing, branches, last_reload, notifications) | `Esr.Admin.Dispatcher` + `Esr.Admin.Commands.*` | Single execution path → single cap check, single log, single audit |
| Feishu slash-command parsing | `Esr.Routing.SessionRouter` | Forwards to Dispatcher after parsing |
| Per-user message routing (non-admin Feishu messages) | `Esr.Routing.SessionRouter` | Actor-system native message dispatch |
| `launchctl kickstart` call | `Esr.Admin.Commands.Reload` via `Task.start` | Happens as a side effect of the reload command |
| Config data files | Filesystem, written only by Dispatcher commands | fs_watch drives reloads of side channels |

### 2.2 Topology

```
macOS user session
│
├── launchd (user LaunchAgent)
│   ├── com.ezagent.esrd.plist       → runs scripts/esrd-launchd.sh (prod)
│   │   └── beam.smp (prod esrd)      → PORT=picked, ESRD_HOME=~/.esrd
│   │       ├── Phoenix Endpoint      → writes ~/.esrd/default/esrd.port
│   │       ├── Esr.Capabilities.*    (existing)
│   │       ├── Esr.Routing.*         (new)
│   │       ├── Esr.Admin.*           (new)
│   │       └── Feishu Adapter        → ESR 助手
│   │
│   └── com.ezagent.esrd-dev.plist   → runs scripts/esrd-launchd.sh (dev)
│       └── beam.smp (dev esrd)       → PORT=picked, ESRD_HOME=~/.esrd-dev
│           ├── (same supervision tree as prod)
│           └── Feishu Adapter        → ESR 开发助手
│
├── /tmp/esrd-feature-foo/             ← ephemeral, spawned by Admin.Commands.Session.New
│   └── beam.smp (branch esrd)        → PORT=picked, ESRD_HOME=/tmp/esrd-feature-foo
│       └── (shares Feishu adapter creds with dev, different CC sessions)
│
└── CC sessions (one per (user, active_branch))
    ├── ou_linyilun @ dev            → connects to ~/.esrd-dev via MCP bridge
    ├── ou_linyilun @ feature-foo   → connects to /tmp/esrd-feature-foo
    └── ou_yaoshengyue @ dev        → connects to ~/.esrd-dev (separate CC process)
```

Code checkouts:
```
~/Workspace/esr/                        # prod — stays on main
~/Workspace/esr/.claude/worktrees/dev/  # dev — stays on dev branch
~/Workspace/esr/.claude/worktrees/<branch>/  # ephemeral, one per branch in progress
```

> **Caveat on `.claude/worktrees/`**: this path is adopted as **a convention** (user preference for CC workspace discoverability), not a built-in Claude Code feature. Verify during implementation that CC's workspace-discovery walks subdirectories under `.claude/` or require explicit workspace opens per branch. If it doesn't, the convention is still useful (one canonical location for dev worktrees) but won't yield automatic CC workspace activation — document the CC-side setup step in the operator guide.

### 2.3 Three entry points, one execution path

```
  Feishu slash command             CLI (via admin_queue/)        Internal (handler)
  (/new-session, /reload,          (esr reload, esr notify,      (e.g., p2p_chat_create
   /end-session, ...)                esr adapter feishu            auto-invokes
          │                          create-app, ...)               session.new)
          │                              │                               │
          ▼                              ▼                               ▼
  Esr.Routing.SessionRouter     Esr.Admin.CommandQueue.Watcher      (direct call)
  parses command →              fs_watch admin_queue/pending →
  GenServer.cast(Dispatcher,    GenServer.cast(Dispatcher,
    reply_to: {:pid, ref})          reply_to: {:file, path})

                           │ │ │
                           ▼ ▼ ▼
               ┌─────────────────────────────────┐
               │      Esr.Admin.Dispatcher       │
               │  1. Authorize (Esr.Capabilities)│
               │  2. Dispatch to Commands.<Kind> │
               │  3. Record result               │
               │  4. Emit telemetry              │
               └────────────────┬────────────────┘
                                │
                                ▼
                 ┌───────────┴────────────┐
                 │  Esr.Admin.Commands.*  │
                 │  Notify / Reload /     │
                 │  RegisterAdapter /     │
                 │  Session.* / Cap.*     │
                 └────────────────────────┘
                                │
                                ▼
                  mutations to yaml files,
                  calls to Feishu adapter,
                  Task.start(launchctl kickstart),
                  etc.
```

Every admin operation passes through `Esr.Admin.Dispatcher`. There is no code path that mutates `adapters.yaml`, `capabilities.yaml`, `routing.yaml`, or `branches.yaml` outside of a Dispatcher command.

## 3. Shell artifacts

### 3.1 `scripts/esrd.sh` enhancements

Existing script at `scripts/esrd.sh` (136 lines) handles start/stop/status with `--instance=<name>`. Adds:

- `--port=<N>` CLI flag. When absent: **prefer `PORT=0` + Phoenix post-bind read-back** (no race), **fall back to Python pre-bind** (small race).
- Writes the chosen/bound port to `$ESRD_HOME/$instance/esrd.port`.
- Sets `PORT=$PORT` in the environment passed to `mix phx.server`.
- On crash/restart the port file is overwritten — clients detect drift by checking mtime.

**Port-resolution strategy** (preferred → fallback):

1. **Phoenix post-bind read-back (preferred, no race)**: `PORT=0` tells Bandit to ask the OS for a free port. After Phoenix boots, a new `Esr.Launchd.PortWriter` GenServer (started from `Esr.Application.start/2` after Endpoint is up) reads the actually-bound port via Bandit listener introspection and writes `$ESRD_HOME/$instance/esrd.port`. Zero race.
2. **Python pre-bind (fallback)**: shell script picks a free port via `python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); print(p)'`, writes the port file, then `exec`s `mix phx.server` with `PORT=$port`. ~100ms race window; launchd restarts on `:eaddrinuse`.

Implementation tries (1) first; if Bandit introspection proves impractical, ship (2) with the race acknowledged.

### 3.2 `scripts/esrd-launchd.sh`

New. launchd's `ProgramArguments` points at this. It:

1. Reads `ESRD_HOME` + instance from plist-supplied env.
2. Cleans any stale pidfile.
3. Sets `PORT=0` (or pre-selects per §3.1 fallback).
4. `cd` to `ESR_REPO_DIR` (supplied via plist env).
5. `exec mix phx.server` — `exec` replaces the shell process so launchd supervises `beam.smp` directly.

`KeepAlive` semantics therefore work as expected: beam exits → launchd starts a new `esrd-launchd.sh` → new port.

### 3.3 `scripts/esr-branch.sh`

New. Entry point for ephemeral esrd lifecycle. Called by `Esr.Admin.Commands.Session.New` and `Esr.Admin.Commands.Session.End` via `System.cmd/3` inside a `Task.start`.

Subcommands:

- `esr-branch.sh new <branch_name> [--worktree-base=.claude/worktrees] [--repo-root=.]`
  - `git -C <repo-root> worktree add <worktree-base>/<branch_name> -b <branch_name>`
  - Compute `ESRD_HOME=/tmp/esrd-<sanitized_branch_name>`
  - Run `scripts/esrd.sh start --instance=default` with that ESRD_HOME + `ESR_REPO_DIR=<worktree_path>`
  - Wait up to 30s for `esrd.port` to appear
  - Print JSON to stdout: `{"ok": true, "branch": "feature-foo", "port": 54321, "worktree_path": "..."}`
  - (Does NOT write to `branches.yaml` directly — the Admin command does that.)

- `esr-branch.sh end <branch_name> [--force]`
  - Look up branches.yaml entry (read-only)
  - Run `scripts/esrd.sh stop` with that ESRD_HOME
  - `git -C <repo_root> worktree remove <worktree_path>` (with `--force` if passed)
  - Print JSON: `{"ok": true, "branch": "feature-foo"}` or `{"ok": false, "error": "..."}`

Branch name sanitization: replace `/` with `-` for directory paths.

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
  - If dev: also install `.git/hooks/post-merge` into `<dev-worktree>/.git/hooks/` (see §8.2)
- Detect `~/.esrd/default/` pre-existing data on first prod install and print migration guidance (does NOT auto-migrate).

**`scripts/launchd/uninstall.sh [--env=prod|dev|both]`**:

- `launchctl bootout gui/$UID/com.ezagent.esrd{-dev}`
- Remove plist
- Remove git hook (if this env installed it)
- Print instructions for cleaning up `~/.esrd{-dev}/` manually

## 5. Python CLI changes

All admin commands follow the same pattern: **local UX + submit to admin queue**. CLI never writes to `adapters.yaml`, `capabilities.yaml`, `routing.yaml`, `branches.yaml`, or `last_reload.yaml` directly. The one exception is `esr adapter feishu create-app`'s interactive UX (URL print + paste prompt), which stays in the CLI; the state mutation still flows through the Dispatcher.

### 5.1 `paths.py` extension — remove the `"default"` hardcode

`py/src/esr/cli/paths.py` **already exists** with `esrd_home()` + `capabilities_yaml_path()`. The core fix: **instance name is no longer hardcoded `"default"` — it becomes env-var-driven**. `capabilities_yaml_path()` currently hardcodes `/ "default" /`; this is changed to use `current_instance()`.

Add:

```python
def current_instance() -> str:
    """Runtime instance name. Honors $ESR_INSTANCE; defaults to 'default'."""
    return os.environ.get("ESR_INSTANCE", "default")

def runtime_home() -> Path:
    """$ESRD_HOME/$ESR_INSTANCE (e.g. ~/.esrd-dev/default)."""
    return esrd_home() / current_instance()

def adapters_yaml_path() -> Path:
    return runtime_home() / "adapters.yaml"

def workspaces_yaml_path() -> Path:
    return runtime_home() / "workspaces.yaml"

def commands_compiled_dir() -> Path:
    return runtime_home() / "commands" / ".compiled"

def admin_queue_dir() -> Path:
    return runtime_home() / "admin_queue"
```

And **modify** the existing `capabilities_yaml_path()` to drop its hardcoded `"default"` segment:

```python
def capabilities_yaml_path() -> str:
    return str(runtime_home() / "capabilities.yaml")
```

### 5.1.1 Top-level CLI flags — sugar for env vars

Add `--instance` and `--esrd-home` as global flags on the `cli` group in `py/src/esr/cli/main.py`. They forward into env vars so all subsequent `paths.*` lookups benefit automatically:

```python
@click.group()
@click.option("--instance", default=None, envvar="ESR_INSTANCE",
              help="Runtime instance name (default: 'default').")
@click.option("--esrd-home", default=None, envvar="ESRD_HOME",
              help="Override ESRD_HOME root (default: ~/.esrd).")
def cli(instance, esrd_home):
    if instance:
        os.environ["ESR_INSTANCE"] = instance
    if esrd_home:
        os.environ["ESRD_HOME"] = esrd_home
```

No per-subcommand changes needed — existing subcommands access paths via `paths.runtime_home()` which reads the env.

### 5.1.2 Elixir-side `"default"` removal — full sweep

Introduce `Esr.Paths` module (the Elixir mirror of `py/src/esr/cli/paths.py`):

```elixir
defmodule Esr.Paths do
  def esrd_home, do: System.get_env("ESRD_HOME") || Path.expand("~/.esrd")
  def current_instance, do: System.get_env("ESR_INSTANCE", "default")
  def runtime_home, do: Path.join(esrd_home(), current_instance())
  def capabilities_yaml, do: Path.join(runtime_home(), "capabilities.yaml")
  def adapters_yaml, do: Path.join(runtime_home(), "adapters.yaml")
  def workspaces_yaml, do: Path.join(runtime_home(), "workspaces.yaml")
  def commands_compiled_dir, do: Path.join([runtime_home(), "commands", ".compiled"])
  def admin_queue_dir, do: Path.join(runtime_home(), "admin_queue")
end
```

**All three** Elixir sites that hardcode `"default"` are migrated to call `Esr.Paths.*` (single definition, no drift with Python):

| File | Line | Current | Becomes |
|---|---|---|---|
| `runtime/lib/esr/application.ex` | 84 | `Path.join([esrd_home, "default", "workspaces.yaml"])` | `Esr.Paths.workspaces_yaml()` |
| `runtime/lib/esr/application.ex` | 119 | `Path.join([esrd_home, "default", "adapters.yaml"])` | `Esr.Paths.adapters_yaml()` |
| `runtime/lib/esr/capabilities/supervisor.ex` | 31 | `Path.join([esrd_home, "default", "capabilities.yaml"])` (`default_path/0`) | `Esr.Paths.capabilities_yaml()` |
| `runtime/lib/esr/topology/registry.ex` | 133 | `Path.join([..., ".esrd", "default", "commands", ".compiled"])` | `Esr.Paths.commands_compiled_dir()` |

Under `ESR_INSTANCE=dev`, all four sites route to `$ESRD_HOME/dev/…` consistently. Under default (env unset), behavior is identical to today.

**Adapter-side**: `adapters/feishu/src/esr_feishu/adapter.py:205-208` also hardcodes `Path(esrd_home) / "default" / "capabilities.yaml"`. Migrate it to import and call `esr.cli.paths.capabilities_yaml_path()` (or move those helpers into a shared `esr.paths` module accessible from adapters — either works; the migration is one line).

Refactor the 8 real code sites (docstring references at lines 289, 325, 455, 514, 823 are unchanged):

| Line | Current | Becomes |
|---|---|---|
| 290 | `Path(...) / ".esrd" / "default" / "adapters.yaml"` | `paths.adapters_yaml_path()` |
| 343 | same | `paths.adapters_yaml_path()` |
| 389-390 | `Path(...) / ".esrd" / "default" / "commands" / ".compiled" / "feishu-app-session.yaml"` | `paths.commands_compiled_dir() / "feishu-app-session.yaml"` |
| 834 | `... / "commands" / ".compiled"` | `paths.commands_compiled_dir()` |
| 947 | same | `paths.commands_compiled_dir()` |
| 1251 | `... / "workspaces.yaml"` | `paths.workspaces_yaml_path()` |
| 1281 | same | `paths.workspaces_yaml_path()` |
| 1295 | same | `paths.workspaces_yaml_path()` |

**Ordering note**: the new helpers (`current_instance`, `runtime_home`, `adapters_yaml_path`, etc.) MUST be defined **above** the existing `capabilities_yaml_path` in `paths.py` so that the rewritten `capabilities_yaml_path` can reference `runtime_home()`. Otherwise Python's name-resolution-at-call-time is fine, but linting / type-checkers may complain.

### 5.2 `esr admin submit` — the core primitive

A low-level CLI command the other admin commands wrap:

```bash
esr admin submit <kind> [--arg K=V]... [--wait] [--timeout=30s]
```

Behavior:

1. Generate a ULID for the command.
2. Compose a YAML file under `paths.admin_queue_dir() / "pending" / "<ulid>.yaml"`:

   ```yaml
   id: 01ARZ3NDEKTSV4RRFFQ69G5FAV
   kind: notify            # or reload / register_adapter / session_new / etc.
   submitted_by: ou_local  # principal_id; from $ESR_OPERATOR_PRINCIPAL_ID or $USER fallback
   submitted_at: 2026-04-21T05:00:00Z
   args:
     to: ou_admin
     text: "hello"
   ```
   Atomic: write to `<ulid>.yaml.tmp`, then `os.rename` to `<ulid>.yaml`.
3. If `--wait`: poll `paths.admin_queue_dir() / "completed" / "<ulid>.yaml"` (success) or `…/failed/<ulid>.yaml` (failure) every 200ms up to `--timeout`. Read result, print, exit 0/1.
4. If no `--wait`: exit 0 immediately after rename.

Atomicity via `rename(2)` — no file locks, no race with the watcher. The watcher only reads files with non-temp names.

### 5.3 CLI commands built on `esr admin submit`

Each is a thin wrapper that does local UX (parsing, prompting if interactive) and shells to `esr admin submit <kind> --arg …`.

**`esr reload [--acknowledge-breaking] [--dry-run]`**:
- Resolve env from `ESRD_HOME`.
- Submit kind=`reload`, args include `acknowledge_breaking: bool`, `dry_run: bool`.
- `--wait` by default with 60s timeout (reload takes 10–30s).
- On completion print the new port + success/fail.

**`esr notify --type=breaking|info|reload-complete --since=<sha> --details=<text> [--to=<open_id>]`**:
- Submit kind=`notify`, args include type, since, details, target.
- No wait by default (fire-and-forget).

**`esr adapter feishu create-app --name <NAME> --target-env prod|dev`**:
- **Local interactive UX** (stays in CLI):
  - Compose pre-filled `backend_oneclick` URL (scopes + events).
  - Print URL.
  - `click.prompt("粘贴 App ID")` and `click.prompt("粘贴 App Secret", hide_input=True)`.
  - Validate by calling `tenant_access_token` locally via lark_oapi once.
- On successful validation: submit kind=`register_adapter`, args include `type: feishu`, `name`, `app_id`, `app_secret`.
- Wait with 30s timeout.
- On completion, the Dispatcher has written `adapters.yaml` + `.env.local` and hot-loaded the adapter; CLI prints "Adapter '<name>' registered and online."

**`esr cap grant <principal> <permission>` / `esr cap revoke <principal> <permission>` (migration)**:
- Existing CLI behavior (direct ruamel.yaml write to `capabilities.yaml`) is kept for rollout compatibility.
- New `--via-admin` flag submits via the dispatcher instead.
- After the spec's Phase DI-8 lands, the direct-write path is deprecated and removed in a follow-up (§13).

### 5.4 Client-side auto-reconnect audit

Touch list (review + fix; no new modules):

- `py/src/esr/ipc/adapter_runner.py` — verify WS reconnect with exponential backoff + port-file re-read on each attempt.
- `py/src/esr/ipc/handler_worker.py` — same.
- `adapters/cc_mcp/src/esr_cc_mcp/channel.py:141` — change the default from hardcoded `ws://127.0.0.1:4001` to "read `$ESRD_HOME/default/esrd.port` then fall back". Add reconnect loop on disconnect.

Expected outcome: after `launchctl kickstart`, clients see WS close, wait ~200ms, re-read port file (new port), reconnect. Normal operation resumes within 10–30s.

## 6. Elixir runtime additions

### 6.1 `Esr.Admin.Supervisor`

OTP Supervisor. Starts and supervises the Admin subsystem's three long-lived GenServers. Strategy: `:rest_for_one` (if the Dispatcher dies, restart it; if the Watcher dies, just restart the Watcher).

```elixir
defmodule Esr.Admin.Supervisor do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Esr.Admin.Dispatcher, []},
      {Esr.Admin.CommandQueue.Watcher, []},
    ]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

Started from `Esr.Application.start/2` AFTER `Esr.Capabilities.Supervisor` (depends on it) and AFTER `Esr.Workspaces.Registry` (depends on it for adapter-registration cross-checks).

### 6.2 `Esr.Admin.Dispatcher` (the brain)

GenServer. Receives commands via **two async paths (both cast)**:

- `GenServer.cast({:execute, command, {:reply_to, target}})` from `Esr.Admin.CommandQueue.Watcher` (CLI queue; `target` = `{:file, completed_path}` so the Dispatcher serializes result back to the file-based queue — CLI polls the file).
- `GenServer.cast({:execute, command, {:reply_to, target}})` from `Esr.Routing.SessionRouter` (Feishu path; `target` = `{:pid, router_pid, ref}` so the Dispatcher `send`s `{:command_result, ref, result}` back when the Task completes, and Router emits a Feishu reply at that point).

**Critical: both paths are fire-and-forget for the caller.** `GenServer.call` is never used between Router and Dispatcher because commands run inside `Task.start` and may take up to 30s+ (reload is especially pathological — `launchctl kickstart` kills the beam mid-call, guaranteeing the reply never arrives). The correlation-ref + reply-message pattern is the only structurally-correct option.

Execution flow (inside `handle_cast({:execute, command, reply_to}, state)`):

1. Parse command kind + args.
2. Call `Esr.Capabilities.has?(command.submitted_by, required_permission(command.kind))`. If false: synchronously emit result `{:error, %{type: "unauthorized"}}` via `emit_result/3`, bypass Task. Move queue file pending → failed immediately.
3. **Move queue file** `pending/<id>.yaml` → `processing/<id>.yaml` synchronously (in Dispatcher process, before Task.start). This gives the Dispatcher a consistent view of in-flight commands across restarts.
4. `Task.start(fn -> run_and_report(command, reply_to, self_pid) end)` — Task runs `Esr.Admin.Commands.<Kind>.execute(command)`, then sends `{:command_result, command.id, result}` to Dispatcher pid.
5. On receiving `{:command_result, id, result}` in `handle_info/2`:
   - Move queue file `processing/<id>.yaml` → `completed/<id>.yaml` or `failed/<id>.yaml`.
   - Call `emit_result(reply_to, id, result)`:
     - For `{:file, path}` targets: write the result onto the completed/failed file (already moved).
     - For `{:pid, router_pid, ref}` targets: `send(router_pid, {:command_result, ref, result})`.
6. Emit telemetry: `[:esr, :admin, :command_executed]` or `[:esr, :admin, :command_failed]` with kind, submitted_by, duration, result.

`required_permission(kind)` map — used by step 2:

| Command kind | Required permission |
|---|---|
| `notify` | `notify.send` |
| `reload` | `runtime.reload` |
| `register_adapter` | `adapter.register` |
| `session_new` | `session.create` |
| `session_switch` | `session.switch` |
| `session_end` | `session.end` |
| `session_list` | `session.list` |
| `grant` | `cap.manage` |
| `revoke` | `cap.manage` |

These permissions are **declared by the Admin subsystem itself** via `Esr.Admin.permissions/0` (literal callback body; registered on boot by the existing Permissions.Bootstrap pattern):

```elixir
defmodule Esr.Admin do
  @behaviour Esr.Handler   # reuses the @optional_callbacks permissions: 0

  def permissions do
    [
      "notify.send",
      "runtime.reload",
      "adapter.register",
      "session.create",
      "session.switch",
      "session.end",
      "session.list",
      "cap.manage"
    ]
  end
end
```

These do not clash with handler-declared permissions of the same name (e.g., handlers/feishu_app declares `session.create` for Feishu-originated use); the Permissions.Registry merges duplicate declarations idempotently.

### 6.3 `Esr.Admin.CommandQueue.Watcher`

GenServer. On init, subscribes `FileSystem` watcher on `paths.admin_queue_dir() / "pending"`.

On file-created event:

1. **Filter**: ignore any path whose basename ends in `.tmp` (CLI atomic-write staging files; §5.2 writes `<ulid>.yaml.tmp` then renames to `<ulid>.yaml`). Ignore any path whose extension is not `.yaml`.
2. **Debounce 50ms** so the post-rename `file_created` event and any residual writes coalesce.
3. Read and parse `<ulid>.yaml` (malformed YAML → move to `failed/` with a parse-error result, emit telemetry, continue).
4. `GenServer.cast(Esr.Admin.Dispatcher, {:execute, command, {:reply_to, {:file, completed_path}}})`.

On boot (init/1), scans `pending/` for leftover commands from prior runs and re-submits each via the same cast path. Dispatcher is started *before* Watcher in `Esr.Admin.Supervisor` (`:rest_for_one` with Dispatcher as first child, per §6.1) so the cast always lands on a live process.

On boot, also scans `processing/` for stale commands (>10 min old — crash mid-execution): those files are moved to `pending/` for re-submission (idempotent commands) or to `failed/` (if file carries a `retry_count >= max_retries` field).

### 6.4 `Esr.Admin.Commands.*` — one module per command kind

Each is a pure function module (not a GenServer) called by the Dispatcher inside `Task.start`. The function signature:

```elixir
@callback execute(command :: map()) :: {:ok, result :: map()} | {:error, error :: map()}
```

Sketch of each:

- **`Notify`**: read the running feishu adapter's state (or post to its channel) → emit `reply` directive with `receive_id` + `text`. Result: `{:ok, %{delivered_at: ts}}`.
- **`Reload`**: read `last_reload.yaml`, run `git log` to find breaking commits. If unacknowledged → return `{:error, %{reason: "unacknowledged_breaking", commits: [...]}}`. Otherwise `Task.start(fn -> System.cmd("launchctl", ["kickstart", "-k", "gui/#{uid}/com.ezagent.esrd-dev"]) end)`, update `last_reload.yaml`, return `{:ok, %{reloaded: true}}`.
- **`RegisterAdapter`**: append entry to `adapters.yaml` via `Esr.Yaml.Writer`, write secret to `.env.local`, call `Esr.WorkerSupervisor.ensure_adapter/4` (existing API — idempotent, on-demand adapter subprocess start; already used by `Esr.Topology.Instantiator` at runtime so post-boot dynamic starts already work). If `type=feishu`, also call the equivalent of `restore_feishu_app_session/1` to bootstrap the proxy binding. Result: `{:ok, %{adapter_id: ..., running: true}}`. **Scope**: this is a few-line wiring on top of existing `Esr.WorkerSupervisor` infrastructure — no Supervisor migration needed (earlier v2 draft incorrectly proposed `AdapterHub.Supervisor` DynamicSupervisor migration; removed).
- **`Session.New`**: shell out to `esr-branch.sh new <branch>` (via Task — Dispatcher is not blocked), parse JSON, append to `branches.yaml`, update `routing.yaml` for the submitter. Result: `{:ok, %{branch, port, worktree_path}}`.
- **`Session.Switch`**: update `routing.yaml`. Result: `{:ok, %{active_branch}}`.
- **`Session.End`**: send cleanup-check to CC via `session.signal_cleanup` tool (30s soft timeout → interactive prompt), on success shell out to `esr-branch.sh end <branch>`, remove from `branches.yaml` + `routing.yaml`. Result: `{:ok, %{branch, cleaned: true}}` or `{:error, %{reason: "worktree_dirty", details: [...]}}`.
- **`Session.List`**: read `routing.yaml` + `branches.yaml`, return per-principal summary.
- **`Cap.Grant` / `Cap.Revoke`**: write `capabilities.yaml` via `Esr.Yaml.Writer`; rely on the **existing** `Esr.Capabilities.Watcher` (`runtime/lib/esr/capabilities/watcher.ex:32-40`) fs_event to reload the in-memory snapshot. No new `add_grant`/`remove_grant` API is introduced — Grants remains file-driven to avoid drift between ETS and file. Result: `{:ok, %{principal, permission, action}}`.

### 6.5 `Esr.Routing.SessionRouter`

GenServer. Handles non-admin Feishu messages by dispatching to the currently-routed target; handles admin Feishu slash commands by forwarding to `Esr.Admin.Dispatcher`.

State:

```elixir
defstruct routing: %{},   # principal_id → %{active: branch, targets: %{branch => %{esrd_url, cc_session_id}}}
            branches: %{}  # branch_name → %{esrd_url, worktree_path, status}
```

Responsibilities:

1. **Non-command messages**: look up `routing[principal_id].active` → forward the envelope to the target esrd (or to the current esrd's `feishu_thread_proxy` if active is local).
2. **Slash commands**: parse into `%Command{kind, args, submitted_by}`, allocate a `ref = make_ref()`, store `{ref, envelope}` in Router state (for knowing where to reply), and `GenServer.cast(Esr.Admin.Dispatcher, {:execute, command, {:reply_to, {:pid, self_pid, ref}}})`. When `{:command_result, ref, result}` arrives in `handle_info/2`, emit a Feishu `reply` directive summarizing the result. No `GenServer.call` — long-running commands would time out and reload would kill the caller mid-call.
3. **`p2p_chat_create` event**: for new users, auto-submit a `session_new` command (see §7.2).
4. **`routing.yaml` fs_watch**: reload on change (Dispatcher writes, Router reads — separation of read/write).
5. **`branches.yaml` fs_watch**: same.

Parser recognizes:

- `/new-session <branch> [--new-worktree]` → `session_new`
- `/switch-session <branch>` → `session_switch`
- `/end-session <branch> [--force]` → `session_end`
- `/sessions` or `/list-sessions` → `session_list`
- `/reload [--acknowledge-breaking]` → `reload`

### 6.6 `routing.yaml` schema

Path: `$ESRD_HOME/default/routing.yaml` (each runtime has its own).

```yaml
version: 1
principals:
  ou_6b11faf8e93aedfb9d3857b9cc23b9e7:
    active: dev
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

For prod, this file usually has one principal with one active target. The prod routing is still needed because different users of ESR 助手 each get their own CC session.

### 6.7 `branches.yaml` schema

Path: `$ESRD_HOME/default/branches.yaml` (only populated on dev esrd).

```yaml
version: 1
branches:
  dev:
    esrd_home: /Users/h2oslabs/.esrd-dev
    worktree_path: /Users/h2oslabs/Workspace/esr/.claude/worktrees/dev
    port: 54321
    spawned_at: 2026-04-21T00:00:00Z
    status: running
    kind: permanent
  feature-foo:
    esrd_home: /tmp/esrd-feature-foo
    worktree_path: /Users/h2oslabs/Workspace/esr/.claude/worktrees/feature-foo
    port: 54399
    spawned_at: 2026-04-21T05:30:00Z
    status: running
    kind: ephemeral
```

The `dev` entry is bootstrapped at install time by `install.sh`; `Admin.Commands.Session.New` writes ephemeral entries.

### 6.8 `admin_queue/` directory layout

Path: `$ESRD_HOME/default/admin_queue/`

```
admin_queue/
  pending/
    01ARZ3NDEKTSV4RRFFQ69G5FAV.yaml    # watcher picks up
  processing/
    01ARZ3NDHBAJB6...yaml              # dispatcher moved here after cast
  completed/
    01ARZ3NDH5...yaml                  # retained N days for audit (see §9.6)
  failed/
    01ARZ3NDH8...yaml                  # retained N days for audit
```

Each command file content:

```yaml
id: 01ARZ3NDEKTSV4RRFFQ69G5FAV
kind: register_adapter
submitted_by: ou_6b11faf8...
submitted_at: 2026-04-21T05:00:00Z
args:
  type: feishu
  name: "ESR 开发助手"
  app_id: cli_xxx
  app_secret: redacted_at_rest   # written then scrubbed post-execute (§9.7)
result:                            # only present in completed/failed
  ok: true
  data: { ... kind-specific ... }
completed_at: 2026-04-21T05:00:01Z
duration_ms: 842
```

### 6.9 CC cleanup-check tool primitive

New MCP tool `session.signal_cleanup` callable by CC via MCP bridge. CC uses this to signal worktree state before `/end-session` completes. Same design as v1 spec; no changes.

Payload shape:

```json
{
  "session_id": "ou_xxx-feature-foo",
  "worktree_path": "/Users/h2oslabs/.../.claude/worktrees/feature-foo",
  "status": "CLEANED | DIRTY | UNPUSHED | STASHED",
  "details": { ... }
}
```

The Dispatcher's `Session.End` command waits for this signal (30s soft timeout); times out are surfaced to the submitter with a prompt choice (force / wait / cancel).

## 7. Data flows

### 7.1 Cold start (prod or dev esrd)

```
launchd (RunAtLoad=true)
  → esrd-launchd.sh
    → (optional) pre-select port OR set PORT=0
    → exec mix phx.server
  → Esr.Application.start/2
    → Esr.Permissions.Registry (populated from handler permissions/0)
    → Esr.Capabilities.Supervisor (loads capabilities.yaml)
    → Esr.Workspaces.Registry (loads workspaces.yaml)
    → Esr.AdapterHub.Registry (reads adapters.yaml — may be empty; no adapters start if empty)
    → Esr.Routing.Supervisor → SessionRouter (loads routing.yaml, branches.yaml)
    → Esr.Admin.Supervisor → Dispatcher + CommandQueue.Watcher
      → Watcher scans pending/ for orphan commands and re-submits each
    → Esr.Launchd.PortWriter writes esrd.port (post-bind path)
  → Phoenix Endpoint listening; esrd.port stable; Admin dispatcher alive
```

Note: if `adapters.yaml` is empty (first-run install), no Feishu adapter is running. That's OK — Admin is still functional and can accept `register_adapter` commands.

### 7.2 `p2p_chat_create` → auto session_new

(Prerequisite: the Feishu adapter gains a new event handler — today it only registers `p2_im_message_receive_v1`. See §11.2 for the adapter.py modification near line 663.)

```
New user ou_alice creates P2P chat with ESR 开发助手
  → Feishu adapter (post-DI-10 patch) emits inbound_event (event_type="p2p_chat_create")
  → Esr.Routing.SessionRouter.handle_event/2
    → submits command kind=session_new, submitted_by=ou_alice, args={branch: "dev", auto: true}
    → Admin.Dispatcher authorizes (needs session.create)
      → has: run Commands.Session.New
      → no: return unauthorized
    → Commands.Session.New:
        updates routing.yaml: ou_alice.active = dev, targets.dev = {...}
    → sends {:command_result, ref, result} to Router via send(router_pid, …)
  → Router emits a reply directive: "欢迎。已连接 dev 环境的 ou_alice-dev session。"
```

### 7.3 `/new-session feature/foo --new-worktree` via Feishu

```
User ou_linyilun sends /new-session feature/foo --new-worktree
  → Esr.Routing.SessionRouter parses → ref=make_ref(), GenServer.cast(Dispatcher, {:execute, session_new_cmd, {:reply_to, {:pid, self, ref}}})
  → Dispatcher authorize (session.create) → spawn Task with Commands.Session.New.execute/1
    → Task: System.cmd("scripts/esr-branch.sh", ["new", "feature/foo", ...])
    → parses JSON: port=54399, worktree_path=...
    → Task: append to branches.yaml + update routing.yaml for ou_linyilun
    → Task: send {:command_result, id, {:ok, %{branch: "feature-foo", port: 54399}}} to Dispatcher
  → Dispatcher moves queue file to completed/
    → Task: send {:command_result, ref, {:ok, %{branch, port, worktree_path}}} to Router
  → Router receives in handle_info/2, matches ref, emits Feishu reply:
      "feature/foo worktree ready at <worktree_path>; port <port>.
       在终端运行 `cd <worktree_path> && cc open .` 启动对应的 CC session
       (或继续在已绑定的 CC 里用 /new-session 创建新绑定)."
```

**CC spawn UX note**: the Dispatcher does NOT spawn a CC process — the user starts CC in the worktree directory themselves. The Router's reply includes the exact command they need. Auto-spawning via the cc_tmux adapter is tracked in §13 Future Work as the next UX improvement.

### 7.4 `/switch-session dev`

Pure routing.yaml update. Dispatcher's `Session.Switch` is synchronous (no Task needed):

```
/switch-session dev
  → Router parse → Dispatcher → Commands.Session.Switch (sync, <10ms)
    → update routing.yaml: ou_linyilun.active = "dev"
  → reply "切换到 dev"
```

### 7.5 `/end-session feature/foo` with CC cleanup coordination

```
/end-session feature/foo
  → Router → Dispatcher → Task with Commands.Session.End
    → Dispatcher sends cleanup-check via MCP tool to CC at /tmp/esrd-feature-foo
    → waits for session.signal_cleanup response (30s soft timeout)
    → CC runs git status/log/stash; responds with status
  [case: CLEANED]
    → Task: System.cmd("scripts/esr-branch.sh", ["end", "feature/foo"])
    → Task: remove from branches.yaml + routing.yaml prune
    → return {:ok, %{branch, cleaned: true}}
  [case: DIRTY or UNPUSHED or STASHED]
    → return {:error, %{reason: "worktree_<kind>", details: [...]}}
    → Router emits reply listing details + suggesting /commit / /push / /stash or /end-session --force
  [case: 30s timeout]
    → Router emits interactive prompt "check 未完成，[强制关闭]/[再等]/[取消]"
    → user choice → re-enqueues as appropriate
```

### 7.6 `/reload` with breaking-change safety gate

```
Admin sends /reload in ESR 开发助手
  → Router → Dispatcher → Commands.Reload
    → read last_reload.yaml; git log <last_sha>..HEAD for breaking markers
    → breaking commits + !acknowledge_breaking → return {:error, %{reason: "unacknowledged_breaking", commits: [...]}}
  → Router replies "⚠️ 2 commits require acknowledgment: {...} — re-send /reload --acknowledge-breaking"

[user re-sends /reload --acknowledge-breaking]
  → Router → Dispatcher → Commands.Reload with acknowledge_breaking=true
    → Task.start: System.cmd("launchctl", ["kickstart", "-k", "gui/$UID/com.ezagent.esrd-dev"])
    → [dev esrd process killed externally — this Dispatcher's process dies here]
  → User's current Feishu WS session drops; after launchd restart, new dev esrd reads routing.yaml and adapter reconnects
  → Router in new esrd reloads from yaml; user's next message routes normally
```

A reload-completion notification is emitted via `esr notify --type=reload-complete` by the new dispatcher after boot (queued via admin_queue/pending).

### 7.7 `esr notify` from CLI (git post-merge hook)

```
git merge completes
  → .git/hooks/post-merge fires
  → scans git log for breaking commits
  → has commits → esr notify --type=breaking --since=<prev> --details='<commits>'
    → CLI: generates ULID, writes admin_queue/pending/<ulid>.yaml:
        kind: notify, submitted_by: ou_local, args: {type: breaking, to: <admin list>, details: ...}
    → CLI exits (no --wait)
  → dev esrd's CommandQueue.Watcher fs_watch fires
  → Dispatcher → Commands.Notify → emit reply directive via existing Feishu adapter → Feishu DM delivered
  → Dispatcher moves file to completed/
```

### 7.8 `esr adapter feishu create-app` (first-time setup)

```
User runs: esr adapter feishu create-app --name "ESR 开发助手" --target-env dev
  → CLI (local):
    - generates pre-filled backend_oneclick URL
    - print URL
    - click.prompt app_id
    - click.prompt app_secret (hidden)
    - locally validates: lark_oapi Client(app_id, app_secret).get_tenant_access_token()
    - if 200 OK → proceed; else print error, exit 1
  → CLI: writes admin_queue/pending/<ulid>.yaml:
      kind: register_adapter
      submitted_by: ou_local
      args: {type: feishu, name: "ESR 开发助手", app_id, app_secret}
  → CLI: --wait (60s timeout) — polls completed/failed
  → dev esrd's CommandQueue.Watcher fs_watch fires
  → Dispatcher → Commands.RegisterAdapter
    - capability check: adapter.register
    - append to adapters.yaml
    - write app_secret to .env.local
    - call Esr.AdapterHub.Registry.hot_load(...)
    - Feishu adapter starts; connects to Lark WS
  → Dispatcher moves to completed/, CLI polls see it
  → CLI prints "Adapter 'ESR 开发助手' registered and online." exit 0
```

Key: **the esrd was already running** (launchd started it on install). `adapters.yaml` was empty so no Feishu adapter was active. Admin accepts the register command without requiring a Feishu adapter to be running — only the capability check + file write + hot_load.

### 7.9 `esr cap grant` via Admin (migration path)

```
esr cap grant ou_alice workspace:dev/msg.send --via-admin
  → CLI writes admin_queue/pending/<ulid>.yaml:
      kind: grant, args: {principal: ou_alice, permission: "workspace:dev/msg.send"}
  → Dispatcher → Commands.Cap.Grant
    - capability check: cap.manage
    - write capabilities.yaml (via Esr.Yaml.Writer; comments NOT preserved)
  → existing Esr.Capabilities.Watcher fs_event fires → reloads into Grants ETS
  → CLI --wait completes
```

## 8. Breaking-change notification

### 8.1 Conventional Commits detection

Markers (either triggers "breaking"):
- Subject line: `<type>(<scope>)!: <message>` (the `!` before `:`)
- Commit body: any line matching `^BREAKING CHANGE: `

Detection:
```bash
git log <since>..HEAD --grep='^[^:]*!:' --grep='^BREAKING CHANGE:' --format='%h|%s|%an|%ae'
```

### 8.2 `post-merge` git hook

Installed by `install.sh` into the dev worktree at `.git/hooks/post-merge`. Content:

```bash
#!/usr/bin/env bash
set -u
repo_root="$(git rev-parse --show-toplevel)"
[[ "$repo_root" != *"/esr"* ]] && exit 0
prev_head="$(git rev-parse HEAD@{1} 2>/dev/null || echo '')"
[[ -z "$prev_head" ]] && exit 0
breaking="$(git log "$prev_head"..HEAD --grep='^[^:]*!:' --grep='^BREAKING CHANGE:' --format='%h %s')"
if [[ -n "$breaking" ]]; then
  esr notify --type=breaking --since="$prev_head" --details="$breaking" || true
fi
```

The `|| true` ensures a notify failure never blocks the merge. Note the hook triggers `esr notify` which goes through the admin queue — so it works even if the esrd is mid-reload (queued, picked up after restart).

### 8.3 `last_reload.yaml` schema

Path: `$ESRD_HOME/default/last_reload.yaml` (managed by `Esr.Admin.Commands.Reload`).

```yaml
version: 1
last_reload_sha: a1b2c3d4
last_reload_ts: 2026-04-21T03:00:00Z
by: ou_6b11faf8...
acknowledged_breaking:
  - a1b2c3d4
  - ef012345
```

## 9. Error handling

### 9.1 Port collision

Pre-selection race window: if fallback path (§3.1 option 2) is in play, `mix phx.server` crashes with `:eaddrinuse`. launchd (`ThrottleInterval=10`) restarts after 10s. Self-healing.

### 9.2 Orphan `/tmp/esrd-*` processes

On dev esrd boot, `Esr.Routing.SessionRouter.init/1` scans `/tmp/esrd-*/`:
- Pid exists + alive → adopt into branches.yaml if missing.
- Pid dead/absent → clean up directory, prune branches.yaml.

### 9.3 Orphan admin queue commands

On boot, `Esr.Admin.CommandQueue.Watcher` scans `pending/` for leftover commands:
- Re-submits each to Dispatcher.
- Commands are idempotent-intended (session_new on an already-existing branch returns ok without re-spawning, grant of an already-held permission is a no-op, etc.) — commands must declare their idempotency in Touch §11.

### 9.4 Dispatcher crashes mid-command

If Dispatcher dies during a Task-running command:
- `Esr.Admin.Supervisor` restarts it.
- The Task continues and eventually sends `{:command_result, id, ...}` to the NEW Dispatcher pid (via `Process.whereis`).
- Command file is in `processing/`; new Dispatcher moves to completed/ or failed/ on receiving result.
- Worst case (Task also dies): file left in `processing/`. A boot-time sweep moves stale entries (>10 min old) back to `pending/` for re-submission, or to `failed/` if max retries reached.

### 9.5 CC WS reconnect

Triggered by WS close event (normal close after `launchctl kickstart` or network blip). Exponential backoff: 200ms, 400ms, 800ms… capped at 5s. Each attempt re-reads `$ESRD_HOME/default/esrd.port`. Max reconnect window: 2 minutes.

### 9.6 Completed/failed file retention

`admin_queue/completed/` and `failed/` retain files 14 days (configurable via plist env `ESR_ADMIN_QUEUE_RETENTION_DAYS`). A nightly `Esr.Admin.CommandQueue.Janitor` task (started by `Admin.Supervisor`) removes older entries.

### 9.7 Secrets in queue files

`register_adapter` submissions include `app_secret` in plain text. After successful execution, `Commands.RegisterAdapter` overwrites the `args.app_secret` field in the completed queue file with the literal string `"[redacted_post_exec]"` before moving to `completed/`. Before redaction the file is 0600-chmodded.

### 9.8 Feishu credential drift

Adapter on startup calls `tenant_access_token`; 4xx → adapter logs error and exits; launchd restart after throttle. Operator re-runs `esr adapter feishu create-app` to refresh creds.

### 9.9 git worktree conflict

If `/new-session feature/foo --new-worktree` and `feature/foo` already has a worktree: `esr-branch.sh new` returns `{ok: false, error: "worktree_exists"}`. Router replies with suggestion to `/switch-session` or force-end.

## 10. Acceptance criteria

- [ ] `scripts/esrd.sh --port=54321 …` respects override; absence picks a random free port and writes `esrd.port`.
- [ ] Two LaunchAgents (`com.ezagent.esrd` + `com.ezagent.esrd-dev`) coexist, each on its own port.
- [ ] `esr cap list` (existing CLI) works under `ESRD_HOME=~/.esrd-dev esr cap list`.
- [ ] `esr adapter feishu create-app --name "…" --target-env dev` goes through Admin queue; after completion, the new adapter is live (visible in `esr cap list` declared permissions, accepting Feishu messages).
- [ ] New user's first DM to ESR 开发助手 auto-creates `<open_id>-dev` session via Admin command.
- [ ] `/new-session feature/foo --new-worktree` goes through Router → Dispatcher → Commands.Session.New → worktree + esrd + routing.yaml + branches.yaml.
- [ ] `/switch-session dev` is O(10ms); only routing.yaml change.
- [ ] `/end-session feature/foo` sends cleanup-check; clean state → closes and removes worktree; dirty state → prompts.
- [ ] `/end-session` with CC unresponsive >30s → interactive prompt.
- [ ] `/reload` without breaking commits → launchctl kickstart; client reconnects <30s.
- [ ] `/reload` with unacknowledged breaking → lists commits, does not reload until --acknowledge-breaking passed.
- [ ] post-merge hook triggers `esr notify` → Admin queue → DM delivered.
- [ ] `last_reload.yaml` updated after each successful reload.
- [ ] dev esrd reboot adopts or cleans orphan `/tmp/esrd-*/` and orphan admin_queue `pending/` commands.
- [ ] Feishu credentials rotation via re-running `create-app` → new adapter replaces old, queue-backed.
- [ ] Admin authorization: a principal without `adapter.register` fails `esr adapter feishu create-app` with queue file in `failed/` and `error.type="unauthorized"`.
- [ ] Every admin command produces exactly one telemetry event (`[:esr, :admin, :command_executed]` or `:command_failed`) — verified via a test harness that `:telemetry.attach`-es a counter before dispatching a known-kind command.
- [ ] Secrets in **any terminal-state queue file** (`completed/`, `failed/`) are redacted to `"[redacted_post_exec]"` — pending/ and processing/ files are 0600-chmodded but retain plaintext (window is bounded to command execution duration).
- [ ] After `launchctl kickstart`, a client reconnects and the next round-trip message is acknowledged within 60s (bounded assertion replaces "<30s" timing-dependent claim).

## 11. Touch list

### 11.1 New files

**Shell**:
- `scripts/esrd-launchd.sh`
- `scripts/esr-branch.sh`
- `scripts/launchd/com.ezagent.esrd.plist`
- `scripts/launchd/com.ezagent.esrd-dev.plist`
- `scripts/launchd/install.sh`
- `scripts/launchd/uninstall.sh`
- `scripts/hooks/post-merge` (template installed by install.sh)

**Python**:
- `py/src/esr/cli/admin.py` (new command group `esr admin submit` + helpers)
- `py/src/esr/cli/reload.py`
- `py/src/esr/cli/notify.py`
- `py/src/esr/cli/adapter/__init__.py`
- `py/src/esr/cli/adapter/feishu.py`
- `py/tests/test_cli_admin_submit.py`
- `py/tests/test_cli_reload.py`
- `py/tests/test_cli_notify.py`
- `py/tests/test_cli_adapter_feishu.py`

**Elixir — Admin**:
- `runtime/lib/esr/admin.ex` (public API)
- `runtime/lib/esr/admin/supervisor.ex`
- `runtime/lib/esr/admin/dispatcher.ex`
- `runtime/lib/esr/admin/command_queue/watcher.ex`
- `runtime/lib/esr/admin/command_queue/janitor.ex`
- `runtime/lib/esr/admin/commands/notify.ex`
- `runtime/lib/esr/admin/commands/reload.ex`
- `runtime/lib/esr/admin/commands/register_adapter.ex`
- `runtime/lib/esr/admin/commands/session/new.ex`
- `runtime/lib/esr/admin/commands/session/switch.ex`
- `runtime/lib/esr/admin/commands/session/end.ex`
- `runtime/lib/esr/admin/commands/session/list.ex`
- `runtime/lib/esr/admin/commands/cap/grant.ex`
- `runtime/lib/esr/admin/commands/cap/revoke.ex`
- `runtime/lib/esr/yaml/writer.ex` — **YAML writer (NOT comment-preserving)**. No Hex library provides a ruamel.yaml equivalent, and building one is out of scope. This writer uses the existing `:yaml_elixir` + `:yamerl` parsers to load, applies the mutation, and re-emits with stable key ordering but **drops comments on write**. Operator guide warns against comment-critical annotations in files Dispatcher writes (`adapters.yaml`, `capabilities.yaml`, `routing.yaml`, `branches.yaml`, `last_reload.yaml`). User-visible docstrings in `capabilities.yaml.example` are in the example file only; the installed `capabilities.yaml` is treated as data not documentation. A future follow-up may shell out to Python/ruamel for comment preservation if operator pain demands it.
- `runtime/test/esr/admin/dispatcher_test.exs`
- `runtime/test/esr/admin/command_queue/watcher_test.exs`
- `runtime/test/esr/admin/commands/*_test.exs` (one per command)

**Elixir — Routing**:
- `runtime/lib/esr/routing.ex`
- `runtime/lib/esr/routing/supervisor.ex`
- `runtime/lib/esr/routing/session_router.ex`
- `runtime/test/esr/routing/session_router_test.exs`

**Elixir — launchd support**:
- `runtime/lib/esr/launchd.ex`
- `runtime/lib/esr/launchd/port_writer.ex` (post-bind port file writer)

**Docs**:
- `docs/operations/dev-prod-isolation.md` (operator guide, post-implementation)
- `docs/futures/docker-isolation.md` (stub authored during DI-14 capturing why this is deferred + sketch)

### 11.2 Modified files

- `scripts/esrd.sh` — add `--port` + port pre-selection fallback
- `py/src/esr/cli/main.py` — add `--instance` + `--esrd-home` global options on the `cli` group; register new command groups (`admin`, `reload`, `notify`, `adapter`); refactor 7 hardcoded paths to `paths.*` helpers
- `py/src/esr/cli/paths.py` — remove hardcoded `"default"` segment from `capabilities_yaml_path()`; add `current_instance()`, `runtime_home()`, `adapters_yaml_path()`, `workspaces_yaml_path()`, `commands_compiled_dir()`, `admin_queue_dir()`
- `runtime/lib/esr/application.ex` — replace hardcoded `"default"` at lines 78 and 113 with `System.get_env("ESR_INSTANCE", "default")`; add `Esr.Launchd.PortWriter`, `Esr.Routing.Supervisor`, `Esr.Admin.Supervisor` to supervision tree (in that order AFTER Capabilities + Workspaces)
- `py/src/esr/ipc/adapter_runner.py` — audit + fix reconnect + port-file re-read
- `py/src/esr/ipc/handler_worker.py` — same
- `adapters/cc_mcp/src/esr_cc_mcp/channel.py:141` — read port from port file + reconnect loop
- `adapters/feishu/src/esr_feishu/adapter.py` — (a) lines 205-208: replace `Path(esrd_home) / "default" / "capabilities.yaml"` with `esr.cli.paths.capabilities_yaml_path()` (or equivalent shared-SDK helper); (b) near line 663: add `register_p2_im_chat_access_event_bot_p2p_chat_create_v1` handler; emit `inbound_event` with `event_type="p2p_chat_create"`
- `runtime/lib/esr/peer_server.ex` — register `session.signal_cleanup` MCP tool at lines 762-825 (the `build_emit_for_tool/3` region)
- `runtime/lib/esr/adapter_hub/registry.ex` — unchanged.
- `runtime/lib/esr/adapter_hub/supervisor.ex` — unchanged (earlier v2 draft mistakenly proposed a DynamicSupervisor migration here; removed).
- `runtime/lib/esr/worker_supervisor.ex` — `Commands.RegisterAdapter` calls the existing `ensure_adapter/4` (already idempotent, already used by `Esr.Topology.Instantiator` for runtime starts). Minor wiring only.
- `runtime/lib/esr/capabilities/supervisor.ex:31` — `default_path/0` hardcodes `"default"`; replace with `Esr.Paths.capabilities_yaml()`.
- `runtime/lib/esr/topology/registry.ex:133` — hardcodes `"default"` in commands compiled dir path; replace with `Esr.Paths.commands_compiled_dir()`.
- `runtime/lib/esr/paths.ex` — **new** (introduced under Modified because it lives in runtime/lib/esr/, adding a small module to existing namespace). Full module defined in §5.1.2.

### 11.3 Dependencies

**New Python dep**: `python-ulid>=3.0` in `py/pyproject.toml` for `esr admin submit` ULID generation (cryptographically random 80-bit tail + ms-precision timestamp; collision probability negligible for our rates). Already-installed Python deps (`click`, `ruamel.yaml`, `lark_oapi`) are sufficient for everything else.

**No new Elixir deps**. Existing `:yaml_elixir`, `:yamerl`, `:file_system`, `:jason`, `:telemetry` cover the Elixir side.

## 12. Sequencing (for writing-plans)

Phase ordering respects dependency topology:

- **Phase DI-1** — Shell + port-file base: `esrd.sh --port`, `esrd-launchd.sh`, `Esr.Launchd.PortWriter`. Testable in isolation.
- **Phase DI-2** — Python CLI paths refactor: `paths.py` helpers + migrate 7 hardcoded sites. Unit tests.
- **Phase DI-3** — Client-side reconnect audit + fix: adapter_runner / handler_worker / cc_mcp channel.
- **Phase DI-4** — launchd plists + install.sh + uninstall.sh. Manual smoke test of prod + dev coexistence.
- **Phase DI-5** — `Esr.Admin.Supervisor` + `Dispatcher` + `CommandQueue.Watcher` scaffolding + `admin_queue/` layout. No commands yet; dispatcher logs "unknown kind" for all inputs. Test the mechanics.
- **Phase DI-6** — `Esr.Yaml.Writer` (comment-preserving Elixir YAML writer). Unit test.
- **Phase DI-7** — `esr admin submit` CLI primitive + `Admin.Commands.Notify` (simplest command, exercises the end-to-end pipeline).
- **Phase DI-8** — `Admin.Commands.RegisterAdapter` + `esr adapter feishu create-app` CLI (first-use scenario).
- **Phase DI-9** — `Esr.Routing.Supervisor` + `SessionRouter` (parser only, forwards to Dispatcher).
- **Phase DI-10** — `Admin.Commands.Session.{New,Switch,End,List}` + `esr-branch.sh` lifecycle + branches.yaml + orphan adoption.
- **Phase DI-11** — `session.signal_cleanup` MCP tool + `Session.End` full flow with CC cleanup coordination + 30s timeout UX.
- **Phase DI-12** — `Admin.Commands.Reload` + `esr reload` CLI + `last_reload.yaml` + breaking-change safety gate.
- **Phase DI-13** — post-merge git hook template + install into dev worktree.
- **Phase DI-14** — E2E acceptance scenarios + operator docs.

Phases DI-1 through DI-7 produce a working prod esrd + dev esrd pair with admin notification (no branching / no sessions yet). DI-8 adds adapter registration. DI-9+ layer the dev-workflow features.

## 13. Future work

- **`Esr.Reload.BlueGreen`** (separate spec): true zero-downtime reload via double-binding, connection migration, atomic cutover. Target when the 10–30s reconnect gap becomes a product problem.
- **Migrate existing `esr cap grant/revoke`** CLI to admin-queue path (remove `--via-admin` flag, make queue the only path). Clean rollout after DI-8 stabilizes.
- **`esr --instance` ergonomics polish**: this spec already ships `--instance` / `--esrd-home` global flags. Future work is purely UX — better help text, tab-completion, per-shell wrappers. The env var `$ESR_INSTANCE` remains a first-class surface; it is NOT retired.
- **Docker isolation**: `docs/futures/docker-isolation.md` — for users running completely different ESR code versions in parallel.
- **Branch esrd auto-sleep**: idle >N minutes → pause the esrd.
- **Explicit capability delegation**: tracked in `docs/futures/explicit-capability-delegation.md`. Relevant here because per-session capability restriction strengthens the multi-user story.
- **Cross-app user-to-user messaging handler**: `docs/futures/cross-workspace-messaging-handler.md` — enables "Alice via App1 pings Bob via App2" flows.
- **HTTP admin endpoint**: expose `Esr.Admin.Dispatcher` over an HTTP API (localhost + token) for external tooling beyond CLI. Requires auth design.
- **Admin audit dashboard**: read `admin_queue/completed/` + `failed/` retention data, render a per-principal activity view. Out of runtime scope.
