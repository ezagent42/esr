# ESR Dev/Prod Isolation — Operator Guide

**Audience:** operators running ESR on macOS who want a dev esrd alongside prod so they can iterate on middleware code without touching the production bot.
**Status:** shipped in `feature/dev-prod-isolation` (phases DI-1..DI-14).
**Design spec:** `docs/superpowers/specs/2026-04-21-esr-dev-prod-isolation-design.md`.

This guide walks through install, daily ops, creds rotation, and troubleshooting for the two-esrd setup (prod at `~/.esrd/`, dev at `~/.esrd-dev/`), both supervised by launchd.

---

## 1. Pre-install checklist

Before running `install.sh`, verify the following:

- **OS**: macOS (this guide uses launchd; Linux-with-systemd would need an analogous unit; see `docs/futures/docker-isolation.md` for the alternative).
- **Elixir**: 1.19+ (`elixir --version`). Older versions lack the OTP 28 compatibility shims used in `Esr.Paths`.
- **Python**: 3.14 via [`uv`](https://github.com/astral-sh/uv) (`uv --version`). The runtime is not tied to a specific patch level; `.tool-versions` or `.python-version` pins are honoured if present.
- **Python dependencies** (installed into `py/.venv` by `uv sync`):
  - `click >= 8.1`
  - `ruamel.yaml` (YAML round-trip for `capabilities.yaml` edits)
  - `lark_oapi` (Feishu API SDK — required by the `create-app` wizard)
  - `python-ulid >= 3.0` (admin command IDs)
  - `pyyaml` (runtime YAML read path — faster than ruamel when comments are unnecessary)
- **git**: 2.30+ with `git worktree` support (used by `/new-session --new-worktree`).
- **Optional but recommended**: `fswatch` or the `:file_system` package's native backend. The `FileSystem` hex dep brings the macOS FSEvents adapter on its own; no separate install needed.

Verify with::

    cd /path/to/esr
    elixir --version
    uv --version
    uv sync --project py      # installs Python deps
    cd runtime && mix deps.get

---

## 2. Install (both environments)

Run the installer from the repo root::

    bash scripts/launchd/install.sh --env=both

This will:

1. Substitute `__HOME__`, `__ESRD_HOME__`, `__REPO_DIR__` into the two plist templates under `scripts/launchd/`.
2. Copy the materialised plists to `~/Library/LaunchAgents/com.ezagent.esrd.plist` and `~/Library/LaunchAgents/com.ezagent.esrd-dev.plist`.
3. `launchctl bootstrap gui/$UID <plist>` each.
4. Wait up to ~10s for each esrd to write its `esrd.port` file (readiness signal).
5. For the dev esrd, install the `.git/hooks/post-merge` template into the dev worktree (if the dev worktree exists at `${HOME}/Workspace/esr/.worktrees/dev`; otherwise skipped with a warning).

If you only want one env, use `--env=prod` or `--env=dev`.

Confirm both are live::

    launchctl list | grep com.ezagent
    cat ~/.esrd/default/esrd.port
    cat ~/.esrd-dev/default/esrd.port

You should see two different decimal ports.

---

## 3. Create the two Feishu apps

ESR supports (in fact, recommends) running **two** Feishu apps — one for production ("ESR 助手"), one for development ("ESR 开发助手"). Operators interact with each via a different DM thread; the apps don't see each other's traffic.

### 3.1 Prod app

    uv run --project py python -m esr.cli.main adapter feishu create-app \
      --name "ESR 助手" --target-env prod

The wizard will:

1. Print a pre-filled `backend_oneclick` launcher URL with ESR's canonical scopes + event subscriptions encoded as query params.
2. Ask you to open that URL in a browser and one-click create the app.
3. Prompt for the freshly-minted **App ID** + **App Secret** (secret is hidden input).
4. Validate the pair against Feishu's `tenant_access_token/internal` endpoint — any 4xx surfaces as `Feishu 凭证验证失败` before the queue is touched.
5. Submit a `register_adapter` admin command to the **prod** queue (`~/.esrd/default/admin_queue/pending/`).
6. Wait up to 60s for the dispatcher to write the completed counterpart, then exit 0.

### 3.2 Dev app

Same command, different `--target-env`::

    uv run --project py python -m esr.cli.main adapter feishu create-app \
      --name "ESR 开发助手" --target-env dev

This writes into the **dev** queue (`~/.esrd-dev/default/admin_queue/pending/`) and produces a live adapter visible via::

    ESRD_HOME=~/.esrd-dev uv run --project py python -m esr.cli.main cap list

Both apps can share a Feishu tenant; they differ only in the app_id + app_secret.

---

## 4. Daily ops

### 4.1 View logs

Per-esrd stdout/stderr is captured under the instance's `logs/` dir::

    tail -f ~/.esrd/default/logs/launchd-stdout.log
    tail -f ~/.esrd-dev/default/logs/launchd-stdout.log

Application-level logs (from inside the Phoenix runtime) land under the same dir — grep for `[error]` or `[warn]`.

### 4.2 Restart an esrd

Two paths:

**launchctl kickstart** (preferred — keeps launchd supervision)::

    launchctl kickstart -k gui/$UID/com.ezagent.esrd        # prod
    launchctl kickstart -k gui/$UID/com.ezagent.esrd-dev    # dev

**esr reload** (through the admin queue — picks up breaking-change markers, writes `last_reload.yaml`)::

    # From inside the prod-supervised esrd's runtime_home, or with ESRD_HOME set:
    ESRD_HOME=~/.esrd uv run --project py python -m esr.cli.main reload

`esr reload` refuses if the post-merge hook flagged any breaking commits in the merged range; pass `--acknowledge-breaking` after reviewing.

### 4.3 Change capabilities

Live edits without an esrd restart::

    ESRD_HOME=~/.esrd-dev uv run --project py python -m esr.cli.main \
      cap grant ou_USER workspace:dev-proj/msg.send

    ESRD_HOME=~/.esrd-dev uv run --project py python -m esr.cli.main \
      cap revoke ou_USER workspace:dev-proj/msg.send

The `Esr.Capabilities.Watcher` picks up file changes via mtime within ~1 s — no restart required.

### 4.4 Session / branch lifecycle (dev only)

These are typed into a Feishu DM with the **dev** bot (the prod bot does not honour them)::

    /new-session feature/foo --new-worktree
    /switch-session feature/foo
    /sessions
    /end-session feature/foo

Under the hood, the `Esr.Routing.SessionRouter` parses these and casts to `Esr.Admin.Dispatcher`, which shells `scripts/esr-branch.sh` (git-worktree + ephemeral esrd at `/tmp/esrd-<branch>/`) and updates `routing.yaml` + `branches.yaml`.

### 4.5 Inspect the admin queue

    ls ~/.esrd-dev/default/admin_queue/pending/     # submitted, awaiting Dispatcher
    ls ~/.esrd-dev/default/admin_queue/processing/  # Dispatcher pulled, Task running
    ls ~/.esrd-dev/default/admin_queue/completed/   # result: ok
    ls ~/.esrd-dev/default/admin_queue/failed/      # result: error (unauthorized / bad args / etc.)

Terminal-state files (`completed/` and `failed/`) are auto-reaped after 14 days by `Esr.Admin.CommandQueue.Janitor`.

---

## 5. Credentials rotation

To rotate a Feishu app's secret (say, after a suspected leak), simply re-run the wizard with the same `--name` and the new secret::

    uv run --project py python -m esr.cli.main adapter feishu create-app \
      --name "ESR 开发助手" --target-env dev
    # Paste the new app_id (same as before if only the secret rotated) + new app_secret.

The admin dispatcher's `RegisterAdapter` command is **idempotent on `name`** — it overwrites the `instances.<name>` entry in `adapters.yaml` and rewrites `.env.local`'s `FEISHU_APP_SECRET_<UPPERCASE_NAME>=...` line in place. The live adapter subprocess is restarted under the new credentials without a full esrd reload.

All submissions go through the admin queue, so you get a completed-with-timestamp record of every rotation under `admin_queue/completed/`. Secrets on the terminal-state queue files are redacted to `[redacted_post_exec]` automatically (dispatcher-side, before the YAML is serialised to disk).

---

## 6. Cleanup / uninstall

    bash scripts/launchd/uninstall.sh --env=both

This will `launchctl bootout` each label and remove the two plists from `~/Library/LaunchAgents/`. The `ESRD_HOME` directories (`~/.esrd/`, `~/.esrd-dev/`) are **not** removed — operators often want to keep the logs + capabilities state for post-mortem. Delete them manually if you really mean to wipe::

    rm -rf ~/.esrd ~/.esrd-dev

The dev worktree's `.git/hooks/post-merge` is not touched by `uninstall.sh`; remove it by hand if you want to stop the breaking-change DM flow::

    rm ~/Workspace/esr/.worktrees/dev/.git/hooks/post-merge

---

## 7. Troubleshooting

### 7.1 "Port file not found" (`esrd.port` absent)

**Symptom:** `cat ~/.esrd/default/esrd.port` returns `No such file or directory`.

**Likely causes:**

- The esrd never started. `launchctl list | grep esrd` should return non-empty; if not, inspect `~/.esrd/default/logs/launchd-stderr.log` for the crash reason (missing dep, bad config).
- The Phoenix `Endpoint` failed to bind (port already in use from a previous manual `mix phx.server`). Kill the stray process: `lsof -iTCP -sTCP:LISTEN -P | grep beam`.
- launchd's `ThrottleInterval` (10s) suppressed respawn after a crash loop. Wait 10s then `launchctl kickstart -k ...`.

**Fix:** `launchctl kickstart -k gui/$UID/com.ezagent.esrd` and watch the log file; if it still fails, `launchctl bootout ...` + `launchctl bootstrap ...` with the plist path to force a clean restart.

### 7.2 Reconnect failure (CC session drops after reload)

**Symptom:** after `launchctl kickstart -k` or `esr reload`, the Feishu adapter and CC session show "Connection refused" in `launchd-stderr.log`.

**Likely causes:**

- `esrd.port` was cached by the client process that started before the reload. The `resolve_url` resolver (in `py/src/_ipc_common/url.py`) is designed to re-read the file on every reconnect; if it's stale, the client's retry loop has been short-circuited.
- The new esrd bound a different port AND it wrote the port file AFTER the client tried its first reconnect. The exponential-backoff schedule (200ms → 5s, capped) should recover within ~30s.

**Fix:** wait 60s; if still disconnected, restart the client manually (e.g. close and reopen the Feishu DM). The admin queue will replay any pending `msg_received` work when the peer comes back.

### 7.3 Dispatcher stuck commands

**Symptom:** a command file sits in `admin_queue/processing/` for minutes.

**Likely causes:**

- The Task running the command crashed mid-execution (e.g. `git worktree add` aborted with a permission error).
- The Dispatcher process itself was restarted (rare, but possible under a SIGKILL).

**Fix:** the `Admin.CommandQueue.Watcher`'s `scan_stale_processing/0` sweep (runs on every Watcher boot) moves any `processing/*.yaml` older than 10 minutes back to `pending/` — next Dispatcher pickup replays the command. To force-recover without waiting for the next restart::

    launchctl kickstart -k gui/$UID/com.ezagent.esrd-dev

If a SPECIFIC command is wedging the Dispatcher, delete its `processing/<id>.yaml` file. Admin commands are all idempotent by contract (§9.3 of the spec), so skipping a single command is safe.

### 7.4 "Unauthorized" reply to a slash command

**Symptom:** typing `/new-session foo` into the dev DM replies `❌ 无权限执行 session.create (请联系管理员授权)`.

**Likely cause:** the sender's Feishu `open_id` isn't in `capabilities.yaml` with the `session.create` permission, OR the workspace inferred from the chat isn't in the grant's scope.

**Fix:**

    ESRD_HOME=~/.esrd-dev uv run --project py python -m esr.cli.main \
      cap grant ou_USER workspace:dev-proj/session.create

(Wildcards work: `workspace:*/session.create` grants every workspace; `*` grants everything.) The watcher picks up the change within a second; retry the slash command.

### 7.5 Post-merge hook misfires

**Symptom:** you see a Feishu DM "⚠ breaking commits since last reload …" after every `git pull`, even when there are no `!:` commits.

**Likely cause:** the hook is running in a repo where `git log HEAD@{1}..HEAD` returns a large range (e.g. first `git pull` after a fresh clone). The hook's built-in guard requires `HEAD@{1}` to resolve, which it won't on a fresh clone, so first-run should be silent — if it's NOT silent, `HEAD@{1}` is pointing at something unexpected.

**Fix:** inspect with `git log HEAD@{1}..HEAD --grep='^[^:]*!:' --grep='^BREAKING CHANGE:'`. If the range is too wide, manually set a sensible `last_reload.yaml`::

    cat > ~/.esrd-dev/default/last_reload.yaml <<EOF
    last_reload_sha: <current-sha>
    last_reload_ts: 2026-04-20T00:00:00Z
    by: ou_operator
    acknowledged_breaking: []
    EOF

The hook uses `HEAD@{1}` (reflog), not `last_reload.yaml`, so this fix only helps `esr reload`; the hook itself will re-fire after every merge. If that's noisy, `rm ~/Workspace/esr/.worktrees/dev/.git/hooks/post-merge`.

### 7.6 Queue file stuck in `pending/` (not processing)

**Symptom:** a file lives under `pending/<id>.yaml` for more than ~5 s and never migrates.

**Likely causes:**

- The `CommandQueue.Watcher` GenServer isn't alive. `ps -ef | grep beam` should show the esrd process; if not, the esrd crashed.
- The FileSystem backend didn't fire for the atomic rename (rare on macOS; more common on bind-mounted volumes). The Watcher's on-boot `scan_pending_orphans/1` picks up any orphan on the next esrd restart.

**Fix:** `launchctl kickstart -k gui/$UID/com.ezagent.esrd-dev` forces a restart, which triggers the orphan sweep and replays the pending command.

---

## 8. File layout reference

    ~/.esrd/                           # prod
      default/
        esrd.port                      # bound port, written on boot
        esrd.pid                       # pid of the mix phx.server process
        capabilities.yaml              # who holds which permission
        adapters.yaml                  # registered adapter instances
        .env.local                     # FEISHU_APP_SECRET_* envs (0600)
        workspaces.yaml                # chat-id → workspace-name map
        routing.yaml                   # per-principal active branch + target
        branches.yaml                  # registered ephemeral esrd branches
        last_reload.yaml               # last reload sha + ts + acknowledgements
        admin_queue/
          pending/<ULID>.yaml          # submitted, awaiting Dispatcher
          processing/<ULID>.yaml       # Dispatcher pulled, Task running
          completed/<ULID>.yaml        # result: ok (with redacted secrets)
          failed/<ULID>.yaml           # result: error (unauthorized / etc)
        logs/
          launchd-stdout.log
          launchd-stderr.log

    ~/.esrd-dev/                       # dev — same layout

    /tmp/esrd-<branch>/                # ephemeral per-branch esrd (spun up by /new-session)
      default/
        esrd.port                      # random free port
        ...                            # (same sub-tree as above, scoped to branch)

    ~/Library/LaunchAgents/
      com.ezagent.esrd.plist           # prod LaunchAgent
      com.ezagent.esrd-dev.plist       # dev LaunchAgent

---

*End of dev/prod isolation operator guide.*
