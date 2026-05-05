# Phase 2 Complete — Slash / CLI Unification

**Date:** 2026-05-05
**Spec:** `docs/superpowers/specs/2026-05-05-slash-cli-repl-elixir-native.md`

Phase 2 closes with this note. Below is the final PR map + verification
that PR-2.7's "runtime.exs reads `enabled_plugins`" requirement is met
(it landed earlier as Track 0 Task 0.5 and has been live ever since).

## PR map

| PR | # | Subject | Outcome |
|---|---|---|---|
| PR-2.0 | #193 | Delete voice plugin | -1577 LOC |
| PR-2.1 | #194 | `/admin/slash_schema.json` schema dump | New endpoint |
| PR-2.2 | #195 | `Esr.Slash.ReplyTarget` behaviour + 4 impls | DI keystone |
| PR-2.3a | #196 | Extract `CleanupRendezvous` + `QueueResult` | 2 new modules |
| PR-2.3b-1 | #197 | Real `QueueFile.respond/3` | Replaced stub |
| PR-2.4 | #198 | Rename `Esr.Admin.Commands.*` → `Esr.Commands.*` | 62 files |
| PR-2.3b-2 | #199 | Delete `Esr.Admin.Dispatcher` | -440 LOC |
| PR-2.5 | #200 | `Esr.Cli.Main` escript skeleton | `esr` binary |
| PR-2.6 | #201 | escript subcommands (daemon, admin submit, notify) | full operator surface |
| PR-2.7 | n/a | runtime.exs reads `plugins.yaml` | already done in Track 0 (verification only) |
| PR-2.8 | this | dev-guide.md update + Phase 2 close note | docs |

## What's true after Phase 2

1. **Single dispatch path.** `Esr.Entity.SlashHandler.dispatch/2,3`
   (chat) and `dispatch_command/2` (admin queue) both run through the
   same execute pipeline + `Esr.Slash.ReplyTarget` reply abstraction.
   No `Esr.Admin.Dispatcher` named GenServer exists.

2. **Plugin-agnostic CLI.** `esr` escript reads
   `/admin/slash_schema.json` (PR-2.1) and the admin queue files
   (PR-2.3b's QueueFile). It contains zero plugin- or command-
   specific knowledge — schema fragment from a plugin manifest
   is automatically reflected in `esr help` and `esr exec`.

3. **DI at every reply boundary.** Future REPL (PR-2.8 was scoped
   only as docs in this run), HTTP endpoint, or any new transport
   can plug in as a new `ReplyTarget` impl without touching
   SlashHandler or any command module.

4. **Cleanup-signal rendezvous is generic.** `Esr.Slash.CleanupRendezvous`
   serves any callsite needing a session_id → task_pid waiter
   (today: `BranchEnd`; tomorrow: any plugin's async-ack pattern).

5. **Boot ordering enforced via supervision tree.**
   `Esr.Slash.HandlerBootstrap` is a supervision child placed before
   `Esr.Admin.Supervisor` so the Watcher's orphan-recovery sweep
   always finds SlashHandler alive.

## PR-2.7 verification (runtime.exs reads `plugins.yaml`)

Track 0 Task 0.5 already wired this. Confirming the live state:

```elixir
# runtime/config/runtime.exs (lines 32–46)
plugins_yaml_path =
  Path.join(System.get_env("ESRD_HOME") || ...,
    Path.join(System.get_env("ESR_INSTANCE", "default"), "plugins.yaml"))

config :esr, :enabled_plugins, Esr.Plugin.EnabledList.read(plugins_yaml_path)
```

`Esr.Application.start/2`'s `load_enabled_plugins/0` (still post-start)
fans out from the `:enabled_plugins` config to register plugin
contributions. e2e scenario 08 (`08_plugin_core_only.sh`) gates this
end-to-end (`/plugin list` returns the expected snapshot).

There's nothing for PR-2.7 to do beyond confirming the gate is green,
which it has been across every Phase 2 PR commit.

## Net delta

- **LOC**: ~+200 net (Phase 2 prioritized contract clarity over LOC
  reduction; voice-delete carried the bulk of the deletes).
- **New modules**: `Esr.Slash.{ReplyTarget, ReplyTarget.{ChatPid, IO,
  QueueFile, WS}, CleanupRendezvous, QueueResult, HandlerBootstrap}`,
  `Esr.Cli.Main`, `EsrWeb.SlashSchemaController`.
- **Deleted modules**: `Esr.Admin.Dispatcher`, `Esr.Pools`, all voice
  modules.

## What's deferred to Phase 3

- Plugin physical migration (move feishu/cc_mcp module trees into
  `runtime/lib/esr/plugins/<name>/`).
- HTTP MCP transport (decouple cc_mcp lifecycle from claude tmux).
- `Esr.Entity.Agent.PlatformProxyRegistry` (replace AgentSpawner
  inline logic).

## What's deferred to Phase 4

- `Esr.Admin.*` namespace cleanup (move CommandQueue.Watcher to
  `Esr.Slash.QueueWatcher`).
- Python CLI residue: `cli/main.py`'s 31 click commands either ported
  or deleted.
- `permissions_registry.json` cross-language dump cleanup.
