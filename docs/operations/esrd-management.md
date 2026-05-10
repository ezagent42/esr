# esrd Management — esrd.sh vs launchd

**Audience:** operators running ESR on macOS who need to start, stop, restart, or recover an esrd instance.
**Status:** current as of 2026-05-10.
**Companion (Chinese):** [esrd-management.zh_cn.md](esrd-management.zh_cn.md).

ESR has **two** lifecycle managers for the runtime daemon (`esrd`). Knowing which one is in charge of your instance is the difference between a clean stop and a cycle of zombie BEAMs.

---

## 1. The two managers

| Manager | Backing artifact | Lifecycle policy | When to use |
|---|---|---|---|
| `scripts/esrd.sh` | `$ESRD_HOME/<instance>/esrd.pid` (pidfile) | One-shot start; manual stop; no auto-restart | Ad-hoc dev sessions on a machine where you do NOT want a permanent agent |
| launchd (`launchctl`) | `~/Library/LaunchAgents/com.ezagent.esrd-<instance>.plist` | KeepAlive=true: launchd auto-respawns on crash and on `kill` | Standing dev/prod environments — the supported default for `--env=dev` and `--env=prod` |

The two are **not** coordinated. If both could be active for the same instance, the launchd-spawned BEAM owns the port and the pidfile written by `esrd.sh` would refer to a different (now-dead) process.

In practice the launchd installer (`scripts/launchd/install.sh`) is the canonical path; `esrd.sh` is a fallback for environments without launchd or for tests (it remains the primary tool used by `tests/e2e/scenarios/*` via `ESRD_CMD_OVERRIDE`).

---

## 2. Detect which manager is active

Run these in order. The first one that prints output is your manager.

```bash
# 1. launchd-loaded?
launchctl list | grep com.ezagent.esrd

# 2. launchd plist file present (loaded or not)?
ls ~/Library/LaunchAgents/com.ezagent.esrd*.plist 2>/dev/null

# 3. esrd.sh pidfile present?
ls ~/.esrd*/*/esrd.pid 2>/dev/null
```

If `(1)` returns a line for your instance, **launchd owns it** — do not use `esrd.sh stop` (see §5).
If only `(3)` returns, you're on the pidfile path.

> Since 2026-05-10 `esrd.sh stop` itself performs detection step (1)+(2) and refuses if launchd is in charge. The detection prints the right command for you.

---

## 3. Standard ops — pick the right tool

### 3.1 Start

| Manager | Command |
|---|---|
| launchd (one-time install) | `scripts/launchd/install.sh --env=<dev\|prod\|both>` |
| launchd (after install — service is auto-started by KeepAlive) | n/a — already running |
| esrd.sh | `scripts/esrd.sh start --instance=<name>` |

### 3.2 Stop

| Manager | Command | Effect |
|---|---|---|
| launchd | `scripts/launchd/uninstall.sh --env=<dev\|prod\|both>` | full unload; removes plist file; data at `$ESRD_HOME` preserved |
| launchd (temporary) | *not supported by design* — KeepAlive=true means launchd will respawn | use uninstall.sh |
| esrd.sh | `scripts/esrd.sh stop --instance=<name>` | SIGTERM the pidfile pid; SIGKILL after 2 s; rm pidfile |
| esrd.sh on launchd-managed instance | (refused with pointer to launchd) | safety: avoids the kill/respawn race |

### 3.3 Restart

| Manager | Command |
|---|---|
| launchd | `launchctl kickstart -k gui/$UID/com.ezagent.esrd-<instance>` |
| launchd (via the same CLI) | `scripts/esrd.sh stop --instance=<i> --launchd-restart` (delegates to launchctl) |
| esrd.sh | `scripts/esrd.sh stop --instance=<i> && scripts/esrd.sh start --instance=<i>` |

### 3.4 Status

| Manager | Command |
|---|---|
| launchd | `launchctl list \| grep com.ezagent.esrd-<instance>` (last column = exit status; 0 = running clean) |
| esrd.sh | `scripts/esrd.sh status --instance=<name>` |

---

## 4. Troubleshooting

### "I stopped esrd but it came back"

You almost certainly have a launchd plist installed for this instance. Symptom: `ps aux | grep mix\ phx.server` shows a fresh PID seconds after your `esrd.sh stop`. KeepAlive=true is the cause.

```bash
# Confirm:
launchctl list | grep com.ezagent.esrd

# Fix (full stop):
scripts/launchd/uninstall.sh --env=dev   # or prod, or both
```

### "Test runs left zombie BEAMs"

`mix test` and `iex -S mix` use `:exec.run_link/2` for OS children. If the BEAM is hard-killed (`kill -9` from a hung shell, terminal disconnect, OOM), the linked exec-port disconnects and the OS child re-parents to init. The 2026-05-10 cleanup (see §6) found 198 zombie BEAMs of this shape.

Mitigations now in place:
- `runtime/test/test_helper.exs` registers a `System.at_exit/1` hook that walks `:exec.which_children/0` and `stop_and_wait/2`'s every child with a 2-second SIGTERM grace.
- `esrd.sh stop` refuses on launchd-managed instances (avoids the kill/respawn race).

If you find new zombies despite the above:

```bash
# Inventory:
ps -eo pid,ppid,command | grep -E 'beam.*phx.server|feishu_adapter_runner'

# Wholesale cleanup of orphaned BEAMs (init-parented, no controlling tty).
# Use only when there's no live esrd you care about, OR target by ppid=1.
# (esrd-dev under launchd has ppid=1 too — check the launchctl list first.)
ps -eo pid,ppid,command | awk '$2 == 1 && /mix phx.server/ { print $1 }' | xargs -n1 kill -TERM
```

### "esrd.sh start prints 'already running' but I can't reach it"

The pidfile is stale and points at a now-dead PID, but the path-of-least-resistance check passed because some other process now occupies that PID number. Workaround:

```bash
rm "$ESRD_HOME/<instance>/esrd.pid"
scripts/esrd.sh start --instance=<instance>
```

---

## 5. Why `esrd.sh stop` refuses on launchd-managed instances

Before 2026-05-10, `esrd.sh stop` would happily SIGTERM the BEAM whose pid was in the pidfile. That BEAM was sometimes a launchd-spawned process; launchd's `KeepAlive=true` immediately respawned it. The operator saw `esrd[<i>] stopped` and assumed success — then their next operation (start, port probe, smoke-* cleanup) raced against the respawn and produced anything from confused logs to actual zombie processes.

The fix: `cmd_stop` now calls `is_launchd_managed` (plist file + `launchctl list` entry) and short-circuits with a pointer to the right tool. Operators who want the old "kick the running launchd-managed process" behaviour can pass `--launchd-restart` and the script will delegate to `launchctl kickstart -k`.

See the commit "chore(scripts): esrd.sh stop detects launchd-managed instance" for the implementation.

---

## 6. Reference: 2026-05-10 zombie BEAM cleanup incident

State observed:

- 198 zombie BEAMs (all running `mix phx.server` or `mix test` test BEAMs in the background)
- 78 orphan `feishu_adapter_runner` python sidecars (each = 1 zombie BEAM's child via the erlexec exec-port)
- Process hierarchy of each leak: `BEAM (init-owned) → erlexec exec-port → python sidecar`

Root cause: months of test runs and dev sessions whose BEAMs were never cleanly exited. Hard-kills (terminal close, `kill -9`, OOM) bypass erlexec's `:kill_timeout` and orphan the exec-port. Sidecars then orphan to init.

Cleanup sequence used:

```bash
ps -eo pid,ppid,command | awk '$2 == 1 && /mix (phx.server|test)/ { print $1 }' | xargs -r kill -TERM
sleep 5
ps -eo pid,ppid,command | awk '$2 == 1 && /mix (phx.server|test)/ { print $1 }' | xargs -r kill -KILL
```

Result: 1 BEAM remaining (the live launchd-managed esrd-dev that the user was using to test Feishu).

Preventive fixes that landed in the same window:
1. ExUnit `System.at_exit/1` hook in `runtime/test/test_helper.exs` — kills exec-children before the test BEAM exits.
2. `esrd.sh stop` launchd detection — refuses pidfile-stop on launchd-managed instances (this commit).
3. This document.

---

## 7. See also

- `docs/operations/dev-prod-isolation.md` — full dev/prod two-esrd setup walkthrough
- `docs/notes/erlexec-migration.md` — why `Esr.OSProcess` uses erlexec + the cleanup-on-BEAM-exit guarantee that test_helper.exs now backs up
- `docs/notes/erlexec-worker-lifecycle.md` — PR-21β retro on the previous orphan-process incident (8x orphans, motivated migration off `spawn_worker.sh`)
- `scripts/launchd/install.sh` / `scripts/launchd/uninstall.sh` — the canonical launchd entry points
- `scripts/esrd.sh` — the pidfile-based fallback (now launchd-aware)
